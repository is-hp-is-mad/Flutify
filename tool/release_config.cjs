// 决定本次 Build 运行要不要编译、发到哪个通道、打什么标签。
//
// 三个通道（每次编译都发布，区别只在通道）：
// - self-test：推送到 main 自动发，开发者自测用；
// - beta：某个 self-test 版经人工确认没问题后，手动运行工作流提升；
// - release：正式版。每周一定时运行，最新 beta 发布之后没有任何新开的 issue 才自动发；也可手动提升。
//
// 「实质版本号」= 本工作流的运行号（GITHUB_RUN_NUMBER），每编译一次加一，三个通道共用一个序列，
// 写在标签的第三段：v0.18.135-selftest / v0.18.140-beta / v0.18.151。客户端只会从低号更新到高号。
// self-test 的后缀故意让旧版客户端解析不了，旧的测试版用户不会被带到自测版上。
const { execFileSync } = require('node:child_process');
const { appendFileSync, readFileSync } = require('node:fs');
const { join } = require('node:path');

const TAG = /^v(\d+)\.(\d+)\.(\d+)(?:-(beta|selftest))?$/;
const SUFFIX = { 'self-test': '-selftest', beta: '-beta', release: '' };

function parseTag(tag) {
  const match = TAG.exec(tag || '');
  if (!match) return null;
  return {
    tag,
    base: `${match[1]}.${match[2]}`,
    build: Number(match[3]),
    channel: match[4] === 'selftest' ? 'self-test' : match[4] || 'release',
  };
}


function skip(reason) {
  return { build: 'false', publish: 'false', reason };
}

function releaseConfig(env, deps) {
  const build = Number(env.GITHUB_RUN_NUMBER);
  if (!Number.isInteger(build) || build <= 0) throw new Error('Missing workflow run number.');
  const baseMatch = /^v(\d+\.\d+)$/.exec(env.BASE_TAG || '');
  if (!baseMatch) throw new Error('AppInfo release tag must look like v0.18.');
  let base = baseMatch[1];
  let channel;
  let sha = env.GITHUB_SHA;
  let source = '';

  const published = () => deps.listReleases().filter((r) => !r.draft);
  const promote = (from) => {
    if (env.CONFIRMED !== 'true') {
      throw new Error(`Promoting to ${channel} requires ticking the manual confirmation that ${from} was tested.`);
    }
    const parsed = parseTag((env.SOURCE_TAG || '').trim());
    if (!parsed || parsed.channel !== from) {
      throw new Error(`source_tag must be a published ${from} tag.`);
    }
    if (!published().some((r) => r.tag === parsed.tag)) {
      throw new Error(`${parsed.tag} is not a published release.`);
    }
    const commit = deps.resolveTag(parsed.tag);
    if (!commit) throw new Error(`Cannot resolve ${parsed.tag}.`);
    base = parsed.base;
    sha = commit;
    source = parsed.tag;
  };

  if (env.GITHUB_EVENT_NAME === 'push') {
    if (env.GITHUB_REF !== 'refs/heads/main') return skip('Only pushes to main are built.');
    channel = 'self-test';
  } else if (env.GITHUB_EVENT_NAME === 'workflow_dispatch') {
    channel = env.CHANNEL || 'self-test';
    if (channel === 'beta') promote('self-test');
    else if (channel === 'release') promote('beta');
    else if (channel !== 'self-test') throw new Error(`Unknown channel ${channel}.`);
  } else if (env.GITHUB_EVENT_NAME === 'schedule') {
    channel = 'release';
    const releases = published().map((r) => ({ ...r, parsed: parseTag(r.tag) })).filter((r) => r.parsed);
    const newest = (name) => releases
      .filter((r) => r.parsed.channel === name)
      .sort((a, b) => b.parsed.build - a.parsed.build)[0];
    const beta = newest('beta');
    const stable = newest('release');
    if (!beta || (stable && stable.parsed.build > beta.parsed.build)) {
      return skip('No beta newer than the current release.');
    }
    // 发布之后新开的 issue 都算，不管现在是否已关闭：有人报过问题就留给人来判断
    if (!/^\d{4}-\d{2}-\d{2}T[\d:.]+Z$/.test(beta.publishedAt || '')) {
      return skip(`${beta.tag} has no publication time.`);
    }
    const created = deps.issuesCreatedSince(beta.publishedAt);
    if (created > 0) {
      return skip(`${created} issue(s) opened since ${beta.tag} was published; not releasing.`);
    }
    const commit = deps.resolveTag(beta.tag);
    if (!commit) throw new Error(`Cannot resolve ${beta.tag}.`);
    base = beta.parsed.base;
    sha = commit;
    source = beta.tag;
  } else {
    return skip(`Event ${env.GITHUB_EVENT_NAME} does not build.`);
  }

  if (!/^[0-9a-f]{7,40}$/.test(sha || '')) throw new Error('Invalid commit.');
  const tag = `v${base}.${build}${SUFFIX[channel]}`;
  const existing = deps.resolveTag(tag);
  if (existing && existing !== sha) throw new Error(`Tag ${tag} points to another commit.`);
  return {
    build: 'true',
    publish: 'true',
    channel,
    tag,
    label: tag,
    sha,
    source,
    prerelease: String(channel !== 'release'),
    latest: String(channel === 'release'),
    reason: '',
  };
}

if (require.main === module) {
  const repo = process.env.GITHUB_REPOSITORY;
  const gh = (args) => execFileSync('gh', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] });
  let releases;
  const appInfo = readFileSync(join(__dirname, '../lib/core/constants/app_info.dart'), 'utf8');
  const config = releaseConfig(
    { ...process.env, BASE_TAG: (/defaultValue: '(v[\d.]+)'/.exec(appInfo) || [])[1] },
    {
      resolveTag: (tag) => {
        try {
          return execFileSync('git', ['rev-parse', '--verify', `refs/tags/${tag}^{commit}`], {
            encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
          }).trim();
        } catch { return null; }
      },
      listReleases: () => releases ??= JSON.parse(gh(['api', `repos/${repo}/releases?per_page=100`]))
        .map((r) => ({ tag: r.tag_name, draft: r.draft, publishedAt: r.published_at })),
      issuesCreatedSince: (time) => Number(gh([
        'api', '-X', 'GET', 'search/issues', '-f', `q=repo:${repo} is:issue created:>${time}`, '--jq', '.total_count',
      ])),
    },
  );
  appendFileSync(process.env.GITHUB_OUTPUT,
    Object.entries(config).map(([key, value]) => `${key}=${value}\n`).join(''));
  const summary = config.build === 'true'
    ? `Channel ${config.channel}, tag ${config.tag}, commit ${config.sha}${config.source ? `, promoted from ${config.source}` : ''}`
    : `Not building: ${config.reason}`;
  console.log(summary);
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${summary}\n`);
}

module.exports = { releaseConfig, parseTag };
