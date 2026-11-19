const { test } = require('node:test');
const assert = require('node:assert/strict');
const { existsSync, readFileSync } = require('node:fs');
const { join } = require('node:path');

const read = (path) => readFileSync(join(__dirname, '..', path), 'utf8').replace(/\r\n/g, '\n');
const workflow = () => read('.github/workflows/build.yml');

function job(name) {
  const source = workflow();
  const start = source.indexOf(`\n  ${name}:`);
  assert.notEqual(start, -1, `Missing ${name} job`);
  const rest = source.slice(start + 1);
  const next = rest.slice(1).search(/^  [a-z][a-z0-9_-]*:/m);
  return next === -1 ? rest : rest.slice(0, next + 1);
}

test('self-test.yml is merged into unified build.yml', () => {
  assert.equal(existsSync(join(__dirname, '..', '.github/workflows/self-test.yml')), false);
});

test('unified build.yml runs on push, main PRs, schedule, and manual dispatch, never tag pushes or pull_request_target', () => {
  const source = workflow();
  assert.match(source, /on:\n  push:/);
  assert.match(source, /pull_request:\n    branches: \[main\]/);
  assert.match(source, /  schedule:/);
  assert.match(source, /  workflow_dispatch:/);
  assert.doesNotMatch(source, /tags:|pull_request_target:|workflow_run:/);
});

test('unified build.yml keeps least-privilege read-only top-level permissions and elevates only prepare/release', () => {
  const source = workflow();
  assert.match(source, /permissions:\n  contents: read\n\nenv:/);
  assert.doesNotMatch(source, /write-all|secrets: inherit/);
  const writeMatches = source.match(/contents: write/g) || [];
  assert.equal(writeMatches.length, 1);
  const release = job('release');
  assert.match(release, /if: needs\.prepare\.outputs\.publish == 'true'/);
  assert.match(release, /contents: write/);
  const checkouts = source.match(/uses: actions\/checkout@v4/g) || [];
  assert.ok(checkouts.length > 0);
  assert.equal((source.match(/persist-credentials: false/g) || []).length, checkouts.length);
});

test('auto-runs skip tests; manual and scheduled runs execute tests and publish', () => {
  const prepare = job('prepare');
  assert.match(prepare, /if: github\.event_name == 'workflow_dispatch' \|\| github\.event_name == 'schedule'/);
  assert.match(prepare, /use_release_signing: \$\{\{ steps\.config\.outputs\.use_release_signing \}\}/);
  assert.match(job('android'), /if: needs\.prepare\.outputs\.run_tests == 'true'/);
  assert.match(job('windows'), /if: needs\.prepare\.outputs\.run_tests == 'true'/);
  assert.match(job('macos'), /if: needs\.prepare\.outputs\.run_tests == 'true'/);
  assert.match(job('linux'), /if: needs\.prepare\.outputs\.run_tests == 'true'/);
});

test('Android uses fixed signing secrets only when use_release_signing is true and disposable key otherwise', () => {
  const android = job('android');
  assert.match(android, /if: needs\.prepare\.outputs\.use_release_signing == 'true'/);
  assert.match(android, /secrets\.ANDROID_KEYSTORE_BASE64/);
  assert.match(android, /secrets\.ANDROID_SIGNING_CERT_SHA256/);
  assert.match(android, /if: needs\.prepare\.outputs\.use_release_signing != 'true'/);
  assert.match(android, /bash tool\/create_self_test_android_key\.sh/);
  assert.match(android, /python3 tool\/verify_android_apks\.py build\/app\/outputs\/flutter-apk/);
  assert.match(android, /rm -f "\$RUNNER_TEMP\/flutify-beta\.jks" "\$RUNNER_TEMP\/flutify-self-test\.p12"/);
  const gradle = read('android/app/build.gradle.kts');
  assert.match(gradle, /check\(releaseSigningReady\)/);
  assert.match(gradle, /signingConfig = signingConfigs\.getByName\("release"\)/);
});

test('macOS retains the validated SDK, runs titlebar hit-testing when testing, and never requests distribution signing', () => {
  const macos = job('macos');
  assert.match(workflow(), /FLUTTER_VERSION_MACOS: '3\.44\.9'/);
  assert.match(macos, /flutter-version: \$\{\{ env\.FLUTTER_VERSION_MACOS \}\}/);
  assert.match(job('macos-tests'), /flutter-version: \$\{\{ env\.FLUTTER_VERSION_MACOS \}\}/);
  assert.match(job('macos-tests'), /flutter test/);
  assert.match(macos, /swiftc macos\/Runner\/TrafficLightAligner\.swift tool\/test_macos_titlebar\.swift/);
  assert.match(macos, /flutter build macos --release/);
  assert.doesNotMatch(macos, /notarytool|import-codesign/);
});

test('Windows builds both native architectures and verifies their bundles', () => {
  const windows = job('windows');
  assert.match(windows, /arch: x64\n\s+runner: windows-latest/);
  assert.match(windows, /arch: arm64\n\s+runner: windows-11-arm/);
  assert.match(windows, /559ffa3f75e7402d65a8def9c28389a9b2e6fe42/);
  assert.match(windows, /windows_arm64/);
  assert.match(windows, /flutter build windows --release/);
  assert.doesNotMatch(windows, /FLUTIFY_NATIVE_WIDEVINE/);
  assert.match(windows, /python tool\/verify_windows_arch\.py/);
  assert.match(windows, /tool\/verify_windows_runtime\.ps1/);
});
