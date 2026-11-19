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
const AFTER_24H = Date.parse(PUBLISHED) + 24 * 60 * 60 * 1000;
const release = (tag, publishedAt = PUBLISHED) => ({ tag, draft: false, publishedAt });
function deps({ releases = [], created = 0, tags = {}, asked = [], now = AFTER_24H } = {}) {
  return {
    listReleases: () => releases,
    issuesCreatedSince: (time) => { asked.push(time); return created; },
    resolveTag: (tag) => tags[tag] ?? (releases.some((r) => r.tag === tag) ? OLD : null),
    now: () => now,
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

test('auto-runs (push/PR) only build (no publish, no tests); manual dispatch publishes self-test + runs tests', () => {
  assert.deepEqual(releaseConfig(base, deps()), {
    build: 'true', publish: 'false', run_tests: 'false', use_release_signing: 'true',
    channel: 'self-test', tag: 'v0.18.150-selftest', label: 'v0.18.150-selftest',
    sha: HEAD, source: '', prerelease: 'true', latest: 'false', reason: '',
  });
  assert.deepEqual(
    releaseConfig({ ...base, GITHUB_EVENT_NAME: 'workflow_dispatch', CHANNEL: 'self-test' }, deps()),
    {
      build: 'true', publish: 'true', run_tests: 'true', use_release_signing: 'true',
      channel: 'self-test', tag: 'v0.18.150-selftest', label: 'v0.18.150-selftest',
      sha: HEAD, source: '', prerelease: 'true', latest: 'false', reason: '',
    },
  );
  const feature = releaseConfig({ ...base, GITHUB_REF: 'refs/heads/feature' }, deps());
  assert.equal(feature.build, 'true');
  assert.equal(feature.publish, 'false');
  assert.equal(feature.run_tests, 'false');
  assert.equal(feature.use_release_signing, 'false');

  const pr = releaseConfig({ ...base, GITHUB_EVENT_NAME: 'pull_request' }, deps());
  assert.equal(pr.build, 'true');
  assert.equal(pr.publish, 'false');
  assert.equal(pr.run_tests, 'false');
  assert.equal(pr.use_release_signing, 'false');
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
  const tags = { 'v0.18.120': 'c'.repeat(40) };
  const asked = [];
  const config = releaseConfig(env, deps({ releases, tags, asked }));
  assert.equal(config.tag, 'v0.18.150');
  assert.equal(config.source, 'v0.18.145-beta');
  assert.equal(config.sha, OLD);
  // 以最新 beta 的发布时间为界，不是更早的 beta 或更晚的 self-test
  assert.deepEqual(asked, [PUBLISHED]);

  const blocked = releaseConfig(env, deps({ releases, tags, created: 1 }));
  assert.equal(blocked.build, 'false');
  assert.match(blocked.reason, /1 issue\(s\) opened since v0\.18\.145-beta/);

  const tooSoon = releaseConfig(env, deps({ releases, tags, now: AFTER_24H - 1 }));
  assert.equal(tooSoon.build, 'false');
  assert.match(tooSoon.reason, /less than 24h ago/);
});

test('the weekly run skips when there are no new commits since the last release', () => {
  const env = { ...base, GITHUB_EVENT_NAME: 'schedule' };
  const releases = [release('v0.18.120'), release('v0.18.145-beta')];
  const sameCommit = releaseConfig(env, deps({ releases }));
  assert.equal(sameCommit.build, 'false');
  assert.match(sameCommit.reason, /No new commits since v0\.18\.120/);

  const noAhead = releaseConfig(env, {
    ...deps({ releases, tags: { 'v0.18.120': 'c'.repeat(40) } }),
    commitsBetween: () => 0,
  });
  assert.equal(noAhead.build, 'false');
  assert.match(noAhead.reason, /No new commits since v0\.18\.120/);
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
