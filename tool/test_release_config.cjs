const { test } = require('node:test');
const assert = require('node:assert/strict');
const { releaseConfig, parseTag } = require('./release_config.cjs');

const HEAD = 'a'.repeat(40);
const OLD = 'b'.repeat(40);
const base = {
  GITHUB_EVENT_NAME: 'push', GITHUB_REF: 'refs/heads/main', GITHUB_REF_NAME: 'main',
  GITHUB_SHA: HEAD, GITHUB_RUN_NUMBER: '150', BASE_TAG: 'v0.18',
};
const PUBLISHED = '2026-11-10T08:00:00Z';
const release = (tag, publishedAt = PUBLISHED) => ({ tag, draft: false, publishedAt });
function deps({ releases = [], created = 0, tags = {}, asked = [] } = {}) {
  return {
    listReleases: () => releases,
    issuesCreatedSince: (time) => { asked.push(time); return created; },
    resolveTag: (tag) => tags[tag] ?? (releases.some((r) => r.tag === tag) ? OLD : null),
  };
}

test('tags carry the build number and the channel', () => {
  assert.deepEqual(parseTag('v0.18.150'), { tag: 'v0.18.150', base: '0.18', build: 150, channel: 'release' });
  assert.equal(parseTag('v0.18.150-beta').channel, 'beta');
  assert.equal(parseTag('v0.18.150-selftest').channel, 'self-test');
  for (const tag of ['v0.18', 'v0.14-beta', 'main', 'v0.18.1-rc', 'v1.2.3;echo bad', 'v0.18.150-selftest\nx=1']) {
    assert.equal(parseTag(tag), null);
  }
});

test('every push to main publishes a self-test build of that commit', () => {
  assert.deepEqual(releaseConfig(base, deps()), {
    build: 'true', publish: 'true', channel: 'self-test', tag: 'v0.18.150-selftest', label: 'v0.18.150-selftest',
    sha: HEAD, source: '', prerelease: 'true', latest: 'false', reason: '',
  });
  assert.equal(releaseConfig({ ...base, GITHUB_REF: 'refs/heads/feature' }, deps()).build, 'false');
  assert.equal(releaseConfig({ ...base, GITHUB_EVENT_NAME: 'pull_request' }, deps()).build, 'false');
});

test('beta is only produced from a published self-test build after manual confirmation', () => {
  const env = { ...base, GITHUB_EVENT_NAME: 'workflow_dispatch', CHANNEL: 'beta', SOURCE_TAG: 'v0.18.140-selftest' };
  const state = deps({ releases: [release('v0.18.140-selftest')] });
  assert.throws(() => releaseConfig(env, state), /manual confirmation/);
  assert.throws(() => releaseConfig({ ...env, CONFIRMED: 'false' }, state), /manual confirmation/);
  const config = releaseConfig({ ...env, CONFIRMED: 'true' }, state);
  assert.equal(config.tag, 'v0.18.150-beta');
  assert.equal(config.sha, OLD);
  assert.equal(config.source, 'v0.18.140-selftest');
  assert.equal(config.prerelease, 'true');
  for (const source of ['', 'v0.18.140', 'v0.18.140-beta', 'v0.18.141-selftest', 'main']) {
    assert.throws(() => releaseConfig({ ...env, CONFIRMED: 'true', SOURCE_TAG: source }, state));
  }
});

test('manual release promotes a beta build, never a self-test build', () => {
  const env = { ...base, GITHUB_EVENT_NAME: 'workflow_dispatch', CHANNEL: 'release', CONFIRMED: 'true' };
  const state = deps({ releases: [release('v0.18.140-selftest'), release('v0.18.145-beta')] });
  const config = releaseConfig({ ...env, SOURCE_TAG: 'v0.18.145-beta' }, state);
  assert.equal(config.tag, 'v0.18.150');
  assert.equal(config.prerelease, 'false');
  assert.equal(config.latest, 'true');
  assert.throws(() => releaseConfig({ ...env, SOURCE_TAG: 'v0.18.140-selftest' }, state));
  assert.throws(() => releaseConfig({ ...env, CHANNEL: 'nightly' }, state), /Unknown channel/);
});

test('the weekly run releases the newest beta only when no issue was opened after it was published', () => {
  const env = { ...base, GITHUB_EVENT_NAME: 'schedule' };
  const releases = [
    release('v0.18.120'), release('v0.18.130-beta', '2026-11-01T08:00:00Z'),
    release('v0.18.145-beta'), release('v0.18.148-selftest', '2026-11-12T08:00:00Z'),
  ];
  const asked = [];
  const config = releaseConfig(env, deps({ releases, asked }));
  assert.equal(config.tag, 'v0.18.150');
  assert.equal(config.source, 'v0.18.145-beta');
  assert.equal(config.sha, OLD);
  // 以最新 beta 的发布时间为界，不是更早的 beta 或更晚的 self-test
  assert.deepEqual(asked, [PUBLISHED]);

  const blocked = releaseConfig(env, deps({ releases, created: 1 }));
  assert.equal(blocked.build, 'false');
  assert.match(blocked.reason, /1 issue\(s\) opened since v0\.18\.145-beta/);
});

test('the weekly run does nothing without a new beta', () => {
  const env = { ...base, GITHUB_EVENT_NAME: 'schedule' };
  assert.equal(releaseConfig(env, deps()).build, 'false');
  assert.equal(releaseConfig(env, deps({ releases: [release('v0.18.140-selftest')] })).build, 'false');
  assert.equal(releaseConfig(env, deps({ releases: [release('v0.18.145-beta'), release('v0.18.147')] })).build, 'false');
  assert.equal(releaseConfig(env, deps({ releases: [release('v0.18.145-beta', null)] })).build, 'false');
  assert.equal(releaseConfig(env, deps({ releases: [{ ...release('v0.18.145-beta'), draft: true }] })).build, 'false');
});

test('bad run numbers, base tags and conflicting tags are rejected', () => {
  assert.throws(() => releaseConfig({ ...base, GITHUB_RUN_NUMBER: '' }, deps()));
  assert.throws(() => releaseConfig({ ...base, BASE_TAG: 'v0.18.1' }, deps()));
  assert.throws(() => releaseConfig(base, deps({ tags: { 'v0.18.150-selftest': OLD } })), /another commit/);
  assert.equal(releaseConfig(base, deps({ tags: { 'v0.18.150-selftest': HEAD } })).build, 'true');
});
