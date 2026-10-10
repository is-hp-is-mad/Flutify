const { test } = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join, dirname } = require('node:path');
const { titlebarScope } = require('./self_test_scope.cjs');

const base = '1'.repeat(40);
const head = '2'.repeat(40);
const pr = (baseSha = base, headSha = head) => ({
  pull_request: { base: { sha: baseSha }, head: { sha: headSha } },
});
const push = (ref = 'refs/heads/feature/android') => ({
  ref, before: base, after: head, repository: { default_branch: 'main' },
});
const files = (...paths) => () => paths.map((path) => `${path}\0`).join('');

test('Android and shared Dart changes do not need the independent Swift titlebar test', () => {
  const result = titlebarScope('pull_request', pr(), files(
    'android/app/src/main/kotlin/MainActivity.kt',
    'lib/providers/playback_provider.dart',
    'lib/ui/screens/player/full_player_sheet.dart',
    'test/ui/player_card_navigation_test.dart',
    'pubspec.lock', 'assets/cover.png', 'docs/ANDROID_PLAYER_POLISH.md',
  ));
  assert.equal(result.run, false);
});

test('native macOS, test-harness and CI changes require the titlebar test', () => {
  for (const path of [
    'macos/Runner/TrafficLightAligner.swift', 'macos/Runner/MainFlutterWindow.swift',
    'macos/Runner.xcodeproj/project.pbxproj', 'tool/test_macos_titlebar.swift',
    'tool/test_macos_drag_region.swift', '.github/workflows/self-test.yml',
    '.github/actions/setup/action.yml', 'tool/self_test_scope.cjs',
    'tool/test_self_test_scope.cjs', 'tool/test_self_test_workflow.cjs',
  ]) {
    assert.equal(titlebarScope('pull_request', pr(), files(path)).run, true, path);
  }
});

test('PR scope uses the entire merge-base diff; push scope includes every pushed commit', () => {
  const ranges = [];
  const diff = (range) => { ranges.push(range); return ''; };
  assert.equal(titlebarScope('pull_request', pr(), diff).run, false);
  assert.equal(titlebarScope('push', push(), diff).run, false);
  assert.deepEqual(ranges, [`${base}...${head}`, `${base}..${head}`]);
});

test('main, default-branch and manual runs retain full native coverage', () => {
  const noDiff = () => { throw new Error('must not inspect paths'); };
  assert.equal(titlebarScope('push', push('refs/heads/main'), noDiff).run, true);
  assert.equal(titlebarScope('push', {
    ...push('refs/heads/trunk'), repository: { default_branch: 'trunk' },
  }, noDiff).run, true);
  assert.equal(titlebarScope('workflow_dispatch', {}, noDiff).run, true);
});

test('missing history, invalid SHAs, new branches and unknown events run conservatively', () => {
  let calls = 0;
  const diff = () => { calls++; throw new Error('missing history'); };
  for (const event of [pr('', head), pr(base, 'bad-sha'), pr('0'.repeat(40), head)]) {
    assert.equal(titlebarScope('pull_request', event, diff).run, true);
  }
  assert.equal(titlebarScope('push', { ...push(), before: '0'.repeat(40) }, diff).run, true);
  assert.equal(titlebarScope('pull_request', {}, diff).run, true);
  assert.equal(titlebarScope('unexpected', {}, diff).run, true);
  assert.equal(calls, 0);
  assert.equal(titlebarScope('pull_request', pr(), diff).run, true);
  assert.equal(calls, 1);
  assert.equal(titlebarScope('pull_request', pr(), () => 'truncated/path').run, true);
});

test('pushes without reliable branch metadata retain native coverage', () => {
  for (const event of [
    { ...push(), ref: undefined },
    { ...push(), repository: undefined },
    { ...push(), repository: { default_branch: '' } },
    push('refs/tags/v1'),
  ]) {
    assert.equal(titlebarScope('push', event, files('android/source.txt')).run, true);
  }
});

test('NUL-separated paths support spaces/newlines and do not use substring matching', () => {
  assert.equal(titlebarScope('pull_request', pr(), files(
    'android/macOS notes.swift', 'docs/note\nmacos/fake.swift',
  )).run, false);
  assert.equal(titlebarScope('pull_request', pr(), files('macos/a\nb.swift')).run, true);
  assert.equal(titlebarScope('pull_request', pr(), files()).run, false);
});

test('CLI detects changes in a real repository, including renames and deletions', (t) => {
  const repo = mkdtempSync(join(tmpdir(), 'flutify-ci-scope-'));
  t.after(() => rmSync(repo, { recursive: true, force: true }));
  const git = (...args) => execFileSync('git', args, { cwd: repo, encoding: 'utf8' }).trim();
  const file = (path, content) => {
    mkdirSync(dirname(join(repo, path)), { recursive: true });
    writeFileSync(join(repo, path), content);
  };
  const commit = () => { git('add', '.'); git('commit', '-qm', 'fixture'); return git('rev-parse', 'HEAD'); };
  const cli = (event, eventName = 'pull_request') => {
    const eventPath = join(repo, '.git', 'event.json');
    const outputPath = join(repo, '.git', 'scope-output');
    writeFileSync(eventPath, typeof event === 'string' ? event : JSON.stringify(event));
    writeFileSync(outputPath, '');
    execFileSync(process.execPath, [join(__dirname, 'self_test_scope.cjs')], {
      cwd: repo,
      env: { ...process.env, GITHUB_EVENT_NAME: eventName,
        GITHUB_EVENT_PATH: eventPath, GITHUB_OUTPUT: outputPath },
      stdio: 'pipe',
    });
    return readFileSync(outputPath, 'utf8').trim();
  };

  git('init', '-q');
  git('config', 'user.name', 'CI fixture');
  git('config', 'user.email', 'ci@example.invalid');
  file('macos/Runner/Native.swift', 'native\n');
  file('android/source.txt', 'base\n');
  const initial = commit();
  file('android/source.txt', 'android only\n');
  const android = commit();
  assert.equal(cli(pr(initial, android)), 'macos_titlebar=false');
  git('mv', 'macos/Runner/Native.swift', 'android/Native.swift');
  const moved = commit();
  assert.equal(cli(pr(android, moved)), 'macos_titlebar=true');
  file('android/source.txt', 'last commit is unrelated\n');
  const last = commit();
  assert.equal(cli(pr(initial, last)), 'macos_titlebar=true');
  assert.equal(cli({ ...push(), before: initial, after: last }, 'push'), 'macos_titlebar=true');
  assert.equal(cli(pr(last, last)), 'macos_titlebar=false');
  assert.equal(cli(pr(base, head)), 'macos_titlebar=true');
  assert.equal(cli('{broken json'), 'macos_titlebar=true');

  file('macos/Runner/Other.swift', 'other native\n');
  const beforeDelete = commit();
  git('rm', 'macos/Runner/Other.swift');
  assert.equal(cli(pr(beforeDelete, commit())), 'macos_titlebar=true');

  // Native changes on the base branch alone must not widen an Android-only PR.
  git('checkout', '-q', '--detach', initial);
  file('macos/Runner/Native.swift', 'upstream native change\n');
  const upstream = commit();
  assert.equal(cli(pr(upstream, android)), 'macos_titlebar=false');
  assert.equal(cli(pr(upstream, last)), 'macos_titlebar=true');
});
