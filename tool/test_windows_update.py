"""Exercise the production Dart/PowerShell handoff in an isolated installation."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
POWERSHELL = Path(os.environ.get('SystemRoot', 'C:/Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
DART = os.environ.get('FLUTIFY_TEST_DART') or shutil.which('dart')
if DART and Path(DART).suffix.lower() == '.bat':
    DART = str(Path(DART).parent / 'cache/dart-sdk/bin/dart.exe')


@unittest.skipUnless(os.name == 'nt' and DART, 'Requires Windows and Dart')
class WindowsUpdateTest(unittest.TestCase):
    def setUp(self):
        (ROOT / 'build').mkdir(exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix='flutify-update-', dir=ROOT / 'build'))
        # Exercise spaces, Unicode and shell metacharacters in every path.
        self.operation = self.root / "更新 & user's [files]" / 'operation'
        self.operation.mkdir(parents=True)
        self.target = self.operation.parent / 'program files'
        self.target.mkdir()
        (self.target / 'Flutify.exe').write_bytes(b'original application')
        self.script = self.operation / 'update.ps1'
        shutil.copyfile(ROOT / 'assets/updates/windows_update.ps1', self.script)
        self.package = self.operation / 'setup.exe'
        compiler = self.operation / 'compile.ps1'
        compiler.write_text('''param([string]$Output)
$ErrorActionPreference = 'Stop'
Add-Type -OutputAssembly $Output -OutputType WindowsApplication -TypeDefinition @'
using System;
using System.IO;
class Installer {
    static void Main(string[] args) {
        File.WriteAllLines(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "installed.txt"), args);
    }
}
'@
''', encoding='utf-8')
        compiled = self.root / 'fixture.exe'
        self.ps(compiler, '-Output', str(compiled))
        shutil.copyfile(compiled, self.package)
        self.plan = self.operation / 'plan.json'
        self.data = dict(target=str(self.target), package=str(self.package),
                         checksum=hashlib.sha256(self.package.read_bytes()).hexdigest(),
                         processId=os.getpid(), installer=True)
        self.write_plan()
        self.parent = None

    def tearDown(self):
        (self.operation / 'cancelled').write_text('cancelled')
        if self.parent and self.parent.poll() is None:
            self.parent.communicate(b'exit\n', timeout=15)
        # Keep fixtures for failed-test diagnostics; no live installation touched.

    def ps(self, script, *args):
        result = subprocess.run([str(POWERSHELL), '-NoProfile', '-NonInteractive',
                                 '-ExecutionPolicy', 'Bypass', '-File', str(script), *args],
                                capture_output=True, creationflags=subprocess.CREATE_NO_WINDOW,
                                timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        return result

    def write_plan(self):
        self.plan.write_text(json.dumps(self.data, ensure_ascii=False), encoding='utf-8')

    def wait_for(self, name):
        deadline = time.monotonic() + 25
        path = self.operation / name
        while not path.exists() and time.monotonic() < deadline:
            if self.parent and self.parent.poll() is not None and name == 'commit':
                self.fail(self.parent.communicate()[1].decode(errors='replace'))
            time.sleep(.1)
        self.assertTrue(path.exists(), f'Missing {name}; files: {list(self.operation.iterdir())}')
        return path

    def start_parent(self):
        self.parent = subprocess.Popen([DART, str(ROOT / 'tool/fixtures/windows_update_driver.dart'),
                                        str(self.script), str(self.plan)],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       creationflags=subprocess.CREATE_NO_WINDOW)

    def test_installer_waits_for_parent_and_survives_its_exit(self):
        self.start_parent()
        self.wait_for('commit')
        self.assertIsNone(self.parent.poll())
        self.assertFalse((self.operation / 'installed.txt').exists())
        stdout, stderr = self.parent.communicate(b'exit\n', timeout=15)
        self.assertEqual(self.parent.returncode, 0, stderr.decode(errors='replace'))
        self.assertIn(b'ready', stdout)
        self.wait_for('success')
        arguments = (self.operation / 'installed.txt').read_text(encoding='utf-8-sig').splitlines()
        self.assertEqual(arguments, ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/DIR=' + str(self.target)])
        self.assertIn('Windows PowerShell 5.1', (self.operation / 'host.txt').read_text())

    def test_checksum_failure_does_not_commit_or_close_app(self):
        self.data['checksum'] = '0' * 64
        self.write_plan()
        self.start_parent()
        _, stderr = self.parent.communicate(b'exit\n', timeout=30)
        self.assertNotEqual(self.parent.returncode, 0)
        self.assertIn(b'Update SHA-256 mismatch', stderr)
        self.assertIn(b'Windows PowerShell 5.1', stderr)
        self.assertTrue((self.operation / 'cancelled').exists())
        self.assertFalse((self.operation / 'commit').exists())
        self.assertFalse((self.operation / 'installed.txt').exists())

    def test_portable_update_backs_up_replaces_and_restarts_after_exit(self):
        archive = self.operation / 'portable.zip'
        with zipfile.ZipFile(archive, 'w') as bundle:
            bundle.write(self.package, 'Flutify.exe')
            bundle.writestr('flutter_windows.dll', b'new runtime')
            bundle.writestr('data/icudtl.dat', b'new data')
        self.data.update(package=str(archive), installer=False,
                         checksum=hashlib.sha256(archive.read_bytes()).hexdigest())
        self.write_plan()
        self.start_parent()
        self.wait_for('commit')
        self.assertEqual((self.target / 'Flutify.exe').read_bytes(), b'original application')
        _, stderr = self.parent.communicate(b'exit\n', timeout=15)
        self.assertEqual(self.parent.returncode, 0, stderr.decode(errors='replace'))
        self.wait_for('success')
        deadline = time.monotonic() + 10
        while not (self.target / 'installed.txt').exists() and time.monotonic() < deadline:
            time.sleep(.1)
        error = self.operation / 'error.txt'
        self.assertTrue((self.target / 'installed.txt').exists(),
                        error.read_text(encoding='utf-8') if error.exists() else 'Updated application did not restart')
        self.assertEqual((self.target / 'Flutify.exe').read_bytes(), self.package.read_bytes())
        self.assertEqual((self.operation / 'backup/Flutify.exe').read_bytes(), b'original application')
        self.assertEqual((self.target / 'data/icudtl.dat').read_bytes(), b'new data')
        self.assertFalse((self.operation / 'error.txt').exists())

    def test_portable_restart_failure_restores_original_without_success(self):
        # The old app can run, but the replacement cannot. A failed restart
        # must restore the old executable and remove files added by the update.
        shutil.copyfile(self.package, self.target / 'Flutify.exe')
        archive = self.operation / 'portable.zip'
        with zipfile.ZipFile(archive, 'w') as bundle:
            bundle.writestr('Flutify.exe', b'not an executable')
            bundle.writestr('flutter_windows.dll', b'new runtime')
            bundle.writestr('data/icudtl.dat', b'new data')
        self.data.update(package=str(archive), installer=False,
                         checksum=hashlib.sha256(archive.read_bytes()).hexdigest())
        self.write_plan()
        self.start_parent()
        self.wait_for('commit')
        _, stderr = self.parent.communicate(b'exit\n', timeout=15)
        self.assertEqual(self.parent.returncode, 0, stderr.decode(errors='replace'))
        self.wait_for('error.txt')
        deadline = time.monotonic() + 10
        while not (self.target / 'installed.txt').exists() and time.monotonic() < deadline:
            time.sleep(.1)
        self.assertTrue((self.target / 'installed.txt').exists(), 'Original app did not restart')
        self.assertEqual((self.target / 'Flutify.exe').read_bytes(), self.package.read_bytes())
        self.assertFalse((self.target / 'flutter_windows.dll').exists())
        self.assertFalse((self.target / 'data/icudtl.dat').exists())
        self.assertFalse((self.operation / 'success').exists())

    def test_cancelled_helper_never_runs_installer(self):
        self.ps(self.script, '-PlanPath', str(self.plan), '-PrepareOnly')
        self.ps(self.script, '-PlanPath', str(self.plan), '-LaunchHelper')
        self.wait_for('waiting')
        (self.operation / 'cancelled').write_text('cancelled')
        # Commit after cancellation must still never apply this operation.
        (self.operation / 'commit').write_text('commit')
        time.sleep(1)
        self.assertFalse((self.operation / 'installed.txt').exists())


if __name__ == '__main__':
    (ROOT / 'build').mkdir(exist_ok=True)
    unittest.main()
