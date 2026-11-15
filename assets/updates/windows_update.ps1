param([Parameter(Mandatory=$true)][string]$PlanPath, [switch]$PrepareOnly, [switch]$LaunchHelper)
$ErrorActionPreference = 'Stop'
$operation = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($PlanPath))
$stage = Join-Path $operation 'stage'
$backup = Join-Path $operation 'backup'
$changed = [Collections.Generic.List[string]]::new()
$existed = @{}
$target = $null
$plan = $null

function Resolve-Child([string]$root, [string]$relative) {
    $base = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath((Join-Path $base $relative))
    if (!$resolved.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw 'Path escapes update directory' }
    return $resolved
}
function Assert-NoLinks([string]$path) {
    $current = [IO.Path]::GetFullPath($path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Updates cannot traverse a junction or symbolic link'
            }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}
function Assert-PackagePath([string]$name) {
    if ($name -match '(^[/\\]|:|[<>"|?*]|(^|[/\\])\.\.?([/\\]|$)|[. ]([/\\]|$))') { throw 'Unsafe ZIP entry' }
    if ($name -match '(^|[/\\])(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])([./\\]|$)') { throw 'Reserved ZIP entry' }
    # Only shipped program files. Never overwrite WebView profiles or music/cache.
    if ($name -notmatch '^(Flutify\.exe|flutify_cdm_bridge\.exe|[^/\\]+\.dll|native_assets\.json|LICENSE|THIRD_PARTY_NOTICES\.md|data[/\\](icudtl\.dat|app\.so|flutter_assets[/\\].+))$') {
        throw "Unexpected package entry: $name"
    }
}
function Start-Flutify([string]$directory) {
    # Start-Process resolves WorkingDirectory as a wildcard path in 5.1.
    # ProcessStartInfo preserves literal installation paths, including brackets.
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Join-Path $directory 'Flutify.exe'
    $info.WorkingDirectory = $directory
    $info.UseShellExecute = $true
    $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $process = [Diagnostics.Process]::Start($info)
    if ($process) { $process.Dispose() }
}

try {
    if ($LaunchHelper) {
        # Windows PowerShell 5.1 can exit without executing a script when
        # started with DETACHED_PROCESS (Dart ProcessStartMode.detached).
        # Start-Process creates an independent, hidden Windows process instead.
        # Quote individual path arguments because ArgumentList joins its array.
        $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', ('"' + $PSCommandPath + '"'), '-PlanPath', ('"' + $PlanPath + '"'))
        Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -WindowStyle Hidden
        exit 0
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.File]::WriteAllText((Join-Path $operation 'host.txt'),
        ('Windows PowerShell ' + $PSVersionTable.PSVersion + ' (' + $PSHOME + ')'))
    # Dart writes JSON as UTF-8 without a BOM; Windows PowerShell otherwise
    # decodes it using the system ANSI code page, corrupting non-ASCII paths.
    $plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $target = [IO.Path]::GetFullPath($plan.target).TrimEnd('\')
    if ($target -eq [IO.Path]::GetPathRoot($target).TrimEnd('\')) { throw 'Refusing a drive root' }
    Assert-NoLinks $target
    Assert-NoLinks $operation
    if (!(Test-Path -LiteralPath (Join-Path $target 'Flutify.exe') -PathType Leaf)) { throw 'Flutify installation missing' }
    # Use the runtime directly: inherited PSModulePath values from PowerShell 7
    # or other hosts can prevent 5.1 from finding the Get-FileHash script module.
    $hash = [Security.Cryptography.SHA256]::Create()
    $packageStream = [IO.File]::OpenRead($plan.package)
    try {
        $checksum = [BitConverter]::ToString($hash.ComputeHash($packageStream)).Replace('-', '')
    } finally {
        $packageStream.Dispose()
        $hash.Dispose()
    }
    if ($checksum -ne $plan.checksum) { throw 'Update SHA-256 mismatch' }
    if ($PrepareOnly) {
        if (!$plan.installer) {
            [IO.Directory]::CreateDirectory($stage) | Out-Null
            $zip = [IO.Compression.ZipFile]::OpenRead($plan.package)
            try {
                $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                [long]$expanded = 0
                foreach ($entry in $zip.Entries) {
                    if (!$entry.Name) { continue }
                    $name = $entry.FullName.Replace('/', '\')
                    Assert-PackagePath $name
                    if (!$seen.Add($name)) { throw 'Duplicate ZIP entry' }
                    $expanded += $entry.Length
                    if ($expanded -gt 4GB -or $seen.Count -gt 50000) { throw 'Oversized ZIP' }
                    $dest = Resolve-Child $stage $name
                    Assert-NoLinks (Resolve-Child $target $name)
                    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest)) | Out-Null
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $false)
                }
                if (!$seen.Contains('Flutify.exe') -or !$seen.Contains('flutter_windows.dll') -or !$seen.Contains('data\icudtl.dat')) {
                    throw 'Incomplete portable package'
                }
            } finally { $zip.Dispose() }
        }
        # Check write access before asking the application to exit.
        $probe = Join-Path $target ('.flutify-update-' + [Guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, '')
        Remove-Item -LiteralPath $probe
        [IO.File]::WriteAllText((Join-Path $operation 'prepared'), 'prepared')
        exit 0
    }
    if (!(Test-Path -LiteralPath (Join-Path $operation 'prepared'))) { throw 'Update was not prepared' }
    # Take a process handle before announcing readiness, avoiding PID reuse.
    $parent = Get-Process -Id $plan.processId -ErrorAction Stop
    [IO.File]::WriteAllText((Join-Path $operation 'waiting'), 'waiting')
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (!(Test-Path -LiteralPath (Join-Path $operation 'commit'))) {
        if ((Test-Path -LiteralPath (Join-Path $operation 'cancelled')) -or [DateTime]::UtcNow -gt $deadline) { exit 0 }
        Start-Sleep -Milliseconds 100
    }
    if (Test-Path -LiteralPath (Join-Path $operation 'cancelled')) { exit 0 }
    if (!$parent.WaitForExit(120000)) { throw 'Application did not close; update cancelled' }
    if (Test-Path -LiteralPath (Join-Path $operation 'cancelled')) { exit 0 }
    if ($plan.installer) {
        # Silent install skips the MIT license/wizard prompts and updates in place,
        # then relaunches Flutify (since flutify.iss [Run] uses skipifsilent).
        $install = Start-Process -FilePath $plan.package -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ('/DIR="' + $target + '"')) -PassThru -Wait
        if ($install.ExitCode -ne 0) { throw "Installer exited with code $($install.ExitCode)" }
        Start-Flutify $target
    } else {
        $files = @(Get-ChildItem -LiteralPath $stage -Recurse -File)
        # Back up every affected file before modifying even one of them.
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($stage.Length + 1)
            Assert-PackagePath $relative
            $dest = Resolve-Child $target $relative
            Assert-NoLinks $dest
            $existed[$relative] = Test-Path -LiteralPath $dest -PathType Leaf
            if ($existed[$relative]) {
                $saved = Resolve-Child $backup $relative
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($saved)) | Out-Null
                Copy-Item -LiteralPath $dest -Destination $saved
            }
        }
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($stage.Length + 1)
            $dest = Resolve-Child $target $relative
            Assert-NoLinks $dest
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest)) | Out-Null
            $changed.Add($relative)
            Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
        }
        Start-Flutify $target
    }
    [IO.File]::WriteAllText((Join-Path $operation 'success'), 'success')
} catch {
    $failure = $_.Exception.Message + "`n" + $_.ScriptStackTrace
    # Only revert paths touched by this operation. User data is never enumerated
    # for deletion; backups remain available if rollback itself fails.
    $rollbackErrors = [Collections.Generic.List[string]]::new()
    foreach ($relative in $changed) {
        try {
            $dest = Resolve-Child $target $relative
            Assert-NoLinks $dest
            if ($existed[$relative]) {
                Copy-Item -LiteralPath (Resolve-Child $backup $relative) -Destination $dest -Force
            } elseif (Test-Path -LiteralPath $dest -PathType Leaf) {
                Remove-Item -LiteralPath $dest -Force
            }
        } catch { $rollbackErrors.Add($_.Exception.Message) }
    }
    $details = $failure + "`n" + ($rollbackErrors -join "`n")
    [IO.File]::WriteAllText((Join-Path $operation 'error.txt'), $details)
    [Console]::Error.WriteLine($details)
    if (!$PrepareOnly -and $target -and $changed.Count -gt 0 -and $rollbackErrors.Count -eq 0) {
        Start-Flutify $target
    }
    exit 1
}
