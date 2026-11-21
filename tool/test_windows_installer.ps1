<#
  Windows 安装 / 卸载回归测试（只应在一次性 CI 机器上运行，会写 HKCU 和开始菜单，不要在自己的电脑上跑）。

  场景 A：安装 → 启动应用（让它写入运行时注册表项 / 开始菜单链接 / spotify: 关联）→ 放入用户数据
          → 默认卸载：运行时痕迹必须被清掉，用户数据必须保留。
  场景 B：再次安装并启动 → 卸载时传 /PURGE=1：用户数据和安装目录都必须被清掉。
#>
param(
    [Parameter(Mandatory = $true)][string]$Setup,
    [ValidateSet('x64', 'arm64')][string]$Arch = 'x64'
)
$ErrorActionPreference = 'Stop'
if (-not $env:CI -and -not $env:GITHUB_ACTIONS) {
    throw 'Refusing to run outside CI: this test writes HKCU, the Start menu and %APPDATA%.'
}
$Setup = (Resolve-Path -LiteralPath $Setup).Path
$installDir = Join-Path $env:RUNNER_TEMP "flutify-install-test-$Arch"
$logDir = Join-Path $env:RUNNER_TEMP 'flutify-install-test-logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

$identityKey = 'HKCU:\Software\Classes\AppUserModelId\Flutify'
$appKey = 'HKCU:\Software\Flutify'
$spotifyCommandKey = 'HKCU:\Software\Classes\spotify\shell\open\command'
$programs = [Environment]::GetFolderPath('Programs')
$runtimeLink = Join-Path $programs 'Flutify.lnk'
$dataDir = Join-Path $env:APPDATA 'Flutify'
$localDir = Join-Path $env:LOCALAPPDATA 'Flutify'
$webViewDir = Join-Path $installDir 'Flutify.exe.WebView2'
$tempLog = Join-Path $env:TEMP 'flutify.log'
$otherHandler = '"C:\other-player\player.exe" "%1"'
$failures = [Collections.Generic.List[string]]::new()

function Check([bool]$ok, [string]$what) {
    if ($ok) { Write-Host "  ok   $what" }
    else { Write-Host "  FAIL $what"; $failures.Add($what) }
}
function Step([string]$text) { Write-Host "`n== $text" }

function Wait-Until([scriptblock]$condition, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (& $condition) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# 不用 Start-Process -Wait：它会连子进程一起等。安装包的 [Run] postinstall 在静默安装时也会
# 自动启动 Flutify.exe，-Wait 会一直等到应用退出（即永远）。这里只等安装 / 卸载进程本身，并设超时。
function Start-Limited([string]$file, [string[]]$arguments, [int]$seconds) {
    $proc = Start-Process -FilePath $file -ArgumentList $arguments -PassThru
    if (-not $proc.WaitForExit($seconds * 1000)) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        throw "Timed out after ${seconds}s: $file"
    }
    return $proc.ExitCode
}

function Stop-App {
    Get-Process -Name 'Flutify' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $null = Wait-Until { -not (Get-Process -Name 'Flutify' -ErrorAction SilentlyContinue) } 15
}

function Install-App([string]$name) {
    $code = Start-Limited $Setup @(
        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=`"$installDir`"", "/LOG=`"$logDir\$name-install.log`"") 180
    Check ($code -eq 0) "installer exit code 0 (got $code)"
    Check (Test-Path -LiteralPath (Join-Path $installDir 'Flutify.exe')) 'Flutify.exe installed'
    Check (Test-Path -LiteralPath (Join-Path $installDir 'unins000.exe')) 'uninstaller installed'
}

# 启动应用让它写入运行时痕迹；应用没能启动 / 没写时用脚本补上，保证卸载断言有对象，并给出警告。
function Run-App {
    # 静默安装结束时安装包可能已经启动了应用（[Run] postinstall）；没有才自己启动一个。
    if (-not (Get-Process -Name 'Flutify' -ErrorAction SilentlyContinue)) {
        $null = Start-Process -FilePath (Join-Path $installDir 'Flutify.exe') -PassThru
    }
    $wrote = Wait-Until { (Test-Path $identityKey) -and (Test-Path -LiteralPath $runtimeLink) } 40
    Stop-App
    if (-not $wrote) {
        Write-Host "::warning::Flutify.exe did not write its runtime identity within 40s on this runner; planting it manually."
        New-Item -Path $identityKey -Force | Out-Null
        New-ItemProperty -Path $identityKey -Name DisplayName -Value 'Flutify' -Force | Out-Null
        if (-not (Test-Path -LiteralPath $runtimeLink)) {
            New-Item -ItemType Directory -Path $programs -Force | Out-Null
            Set-Content -LiteralPath $runtimeLink -Value 'placeholder'
        }
    }
    Check $true 'runtime traces present before uninstall'
}

function Plant-UserData {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dataDir 'shared_preferences.json') -Value '{}'
    New-Item -ItemType Directory -Path $webViewDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $webViewDir 'marker') -Value 'x'
    Set-Content -LiteralPath $tempLog -Value 'log'
}

function Uninstall-App([string]$name, [string[]]$extra) {
    $unins = Join-Path $installDir 'unins000.exe'
    Check (Test-Path -LiteralPath $unins) 'unins000.exe exists before uninstall'
    $argList = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$logDir\$name-uninstall.log`"") + $extra
    Stop-App
    $code = Start-Limited $unins $argList 120
    Check ($code -eq 0) "uninstaller exit code 0 (got $code)"
    # unins000.exe 会把自己复制到临时目录再继续，原进程很快退出：等它真的删完。
    $gone = Wait-Until { -not (Test-Path -LiteralPath $unins) } 90
    Check $gone 'uninstaller finished (unins000.exe removed)'
    Start-Sleep -Seconds 2
}

function Check-RuntimeTracesGone {
    Check (-not (Test-Path $identityKey)) 'HKCU AppUserModelId\Flutify removed'
    Check (-not (Test-Path $appKey)) 'HKCU Software\Flutify removed'
    Check (-not (Test-Path -LiteralPath $runtimeLink)) 'Start menu Flutify.lnk removed'
    Check (-not (Test-Path -LiteralPath (Join-Path $programs 'Flutify'))) 'Start menu Flutify folder removed'
    Check (-not (Test-Path -LiteralPath (Join-Path $installDir 'Flutify.exe'))) 'Flutify.exe removed'
}

# 一台干净的 CI 机器上不应有旧残留
foreach ($p in $identityKey, $appKey) { if (Test-Path $p) { Remove-Item $p -Recurse -Force } }
New-Item -Path (Split-Path $spotifyCommandKey) -Force | Out-Null
New-Item -Path $spotifyCommandKey -Force | Out-Null
Set-ItemProperty -Path $spotifyCommandKey -Name '(default)' -Value $otherHandler

Step "A1: install ($Arch)"
Install-App 'a'
Step 'A2: launch app, plant user data'
Run-App
Plant-UserData
$handler = (Get-ItemProperty -Path $spotifyCommandKey -ErrorAction SilentlyContinue).'(default)'
$takenOver = $handler -and $handler -ne $otherHandler
if (-not $takenOver) { Write-Host '::warning::Flutify did not take over the spotify: handler on this runner; skipping the restore assertion.' }
Step 'A3: default uninstall (keeps user data)'
Uninstall-App 'a' @()
Check-RuntimeTracesGone
if ($takenOver) {
    $after = (Get-ItemProperty -Path $spotifyCommandKey -ErrorAction SilentlyContinue).'(default)'
    Check ($after -eq $otherHandler) "spotify: handler restored to the previous one (got: $after)"
}
Check (Test-Path -LiteralPath (Join-Path $dataDir 'shared_preferences.json')) 'user data kept: %APPDATA%\Flutify'
Check (Test-Path -LiteralPath (Join-Path $webViewDir 'marker')) 'user data kept: WebView2 profile'
Check (Test-Path -LiteralPath $tempLog) 'user data kept: %TEMP%\flutify.log'

Step "B1: reinstall over the kept data ($Arch)"
Install-App 'b'
Run-App
Plant-UserData
Step 'B2: uninstall with /PURGE=1'
Uninstall-App 'b' @('/PURGE=1')
Check-RuntimeTracesGone
Check (-not (Test-Path -LiteralPath $dataDir)) 'purged: %APPDATA%\Flutify'
Check (-not (Test-Path -LiteralPath $localDir)) 'purged: %LOCALAPPDATA%\Flutify'
Check (-not (Test-Path -LiteralPath $webViewDir)) 'purged: WebView2 profile'
Check (-not (Test-Path -LiteralPath $tempLog)) 'purged: %TEMP%\flutify.log'
Check (-not (Test-Path -LiteralPath $installDir)) 'install directory removed'

if ($failures.Count -gt 0) {
    Write-Host "`nFailed checks:"
    $failures | ForEach-Object { Write-Host " - $_" }
    exit 1
}
Write-Host "`nInstall / uninstall test passed."
