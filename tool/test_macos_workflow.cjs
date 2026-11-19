const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');

const workflow = readFileSync(join(__dirname, '../.github/workflows/build.yml'), 'utf8');

function job(name) {
  const start = workflow.indexOf(`\n  ${name}:`);
  assert.notEqual(start, -1, `Missing ${name} job`);
  const content = workflow.slice(start + 1);
  const next = content.slice(1).search(/^  [a-z][a-z0-9_-]*:/m);
  return next === -1 ? content : content.slice(0, next + 1);
}

test('macOS builds using the validated build label; its tests run as a parallel sharded job', () => {
  const macos = job('macos');
  assert.match(macos, /needs: prepare/);
  assert.match(macos, /BUILD_LABEL: \$\{\{ needs\.prepare\.outputs\.label \}\}/);
  // flutter test 不在打包 job 的关键路径上，见 macos-tests
  assert.doesNotMatch(macos, /flutter test/);
  const tests = job('macos-tests');
  assert.match(tests, /needs: prepare/);
  assert.match(tests, /runs-on: macos-latest/);
  assert.match(tests, /shard: \[1, 2\]/);
  assert.match(tests, /flutter test --total-shards 2 --shard-index/);
  assert.match(tests, /if: needs\.prepare\.outputs\.run_tests == 'true'/);
  assert.match(macos, /flutter build macos --release/);
  assert.match(macos, /Flutify-\$\{BUILD_LABEL\}-macos\.zip/);
  assert.match(macos, /--keepParent build\/macos\/Build\/Products\/Release\/Flutify\.app/);
  assert.match(macos, /name: macos/);
});

test('Linux tests, builds and packages a .deb and a portable tarball using the validated build label', () => {
  const linux = job('linux');
  assert.match(linux, /needs: prepare/);
  assert.match(linux, /BUILD_LABEL: \$\{\{ needs\.prepare\.outputs\.label \}\}/);
  assert.match(linux, /flutter test/);
  assert.match(linux, /flutter build linux --release/);
  assert.match(linux, /tool\/package_linux_deb\.sh/);
  assert.match(linux, /tool\/package_linux_tarball\.sh/);
  assert.match(linux, /name: linux/);
});

test('release waits for all platforms and includes their packages in checksums', () => {
  const release = job('release');
  assert.match(release, /needs: \[prepare, android, windows, macos, macos-tests, linux\]/);
  assert.match(release, /pattern: '\{android,windows-\*,macos,linux\}'/);
  assert.match(release, /merge-multiple: true/);
  assert.match(release, /android-universal\.apk macos\.zip linux-x64\.deb linux-x64\.tar\.gz; do/);
  assert.match(release, /-eq 11/);
  assert.match(release, /sha256sum Flutify-\*/);
});
