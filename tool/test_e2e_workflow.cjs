const { test } = require('node:test');
const assert = require('node:assert/strict');
const { existsSync, readFileSync } = require('node:fs');
const { join } = require('node:path');

const read = (path) => readFileSync(join(__dirname, '..', path), 'utf8').replace(/\r\n/g, '\n');
const buildWorkflow = () => read('.github/workflows/build.yml');
const instaboxScript = () => read('tool/instabox_android_e2e.py');

function job(source, name) {
  const start = source.indexOf(`\n  ${name}:`);
  assert.notEqual(start, -1, `Missing ${name} job`);
  const rest = source.slice(start + 1);
  const next = rest.slice(1).search(/^  [a-z][a-z0-9_-]*:/m);
  return next === -1 ? rest : rest.slice(0, next + 1);
}

test('E2E pipeline is merged into build.yml after self-test release publish', () => {
  assert.equal(
    existsSync(join(__dirname, '..', '.github/workflows/e2e-full-test.yml')),
    false,
    'Standalone e2e-full-test.yml should be merged into build.yml',
  );
  const source = buildWorkflow();
  for (const jobName of [
    'prepare',
    'android',
    'windows',
    'macos',
    'linux',
    'release',
    'e2e-windows',
    'e2e-linux',
    'e2e-macos',
    'e2e-android',
    'e2e-summary',
  ]) {
    job(source, jobName);
  }
});

test('desktop E2E jobs reuse self-test release artifacts and package per-OS reports', () => {
  const source = buildWorkflow();

  const win = job(source, 'e2e-windows');
  assert.match(win, /needs: \[prepare, release\]/);
  assert.match(win, /needs\.prepare\.outputs\.channel == 'self-test'/);
  assert.match(win, /name: windows-x64/);
  assert.match(win, /Flutify\.exe/);
  assert.match(win, /--self-test-e2e=/);
  assert.match(win, /Compress-Archive/);
  assert.match(win, /flutify-e2e-windows-x64\.zip/);
  assert.match(win, /tool\/render_e2e_report\.py e2e_out\/windows --fail-on-error/);

  const linux = job(source, 'e2e-linux');
  assert.match(linux, /needs: \[prepare, release\]/);
  assert.match(linux, /needs\.prepare\.outputs\.channel == 'self-test'/);
  assert.match(linux, /xvfb-run/);
  assert.match(linux, /--mock --self-test-e2e=/);
  assert.match(linux, /flutify-e2e-linux-x64\.zip/);
  assert.match(linux, /tool\/render_e2e_report\.py e2e_out\/linux --fail-on-error/);

  const macos = job(source, 'e2e-macos');
  assert.match(macos, /needs: \[prepare, release\]/);
  assert.match(macos, /needs\.prepare\.outputs\.channel == 'self-test'/);
  assert.match(macos, /Flutify\.app\/Contents\/MacOS\/Flutify/);
  assert.match(macos, /--mock --self-test-e2e=/);
  assert.match(macos, /flutify-e2e-macos\.zip/);
  assert.match(macos, /tool\/render_e2e_report\.py e2e_out\/macos --fail-on-error/);
});

test('android E2E reuses InstaBox, upgrades via Settings without uninstalling, and never destroys the box', () => {
  const source = buildWorkflow();
  const android = job(source, 'e2e-android');
  assert.match(android, /needs: \[prepare, release\]/);
  assert.match(android, /needs\.prepare\.outputs\.channel == 'self-test'/);
  assert.match(android, /concurrency:\n\s+group: instabox-android-e2e\n\s+cancel-in-progress: false/);
  assert.match(android, /INSTABOX_API_KEY: \$\{\{ secrets\.INSTABOX_API_KEY \}\}/);
  assert.match(android, /flutify-e2e-android/);
  assert.match(android, /python3 tool\/instabox_android_e2e\.py run/);
  assert.match(android, /if: always\(\) && env\.INSTABOX_API_KEY != ''/);
  assert.match(android, /python3 tool\/instabox_android_e2e\.py cleanup/);
  assert.doesNotMatch(android, /instabox rm|adb uninstall|--delete-after/);
  assert.match(android, /flutify-e2e-android\.zip/);
  assert.match(android, /tool\/render_e2e_report\.py e2e_out\/android --fail-on-error/);

  const script = instaboxScript();
  assert.match(script, /adb shell am start -W -n .*--ez flutify_mock true --es flutify_e2e auto/);
  assert.match(script, /REQUEST_INSTALL_PACKAGES/);
  assert.match(script, /drive_settings_upgrade/);
  assert.doesNotMatch(script, /"adb",\s*"uninstall"|adb uninstall|"instabox",\s*"rm"/);
});
