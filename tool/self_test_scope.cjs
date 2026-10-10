// Scope only the standalone Swift titlebar test. Flutter quality/build jobs
// remain unconditional because Android-facing changes can touch shared code.
const { execFileSync } = require('node:child_process');
const { readFileSync, appendFileSync } = require('node:fs');

const nativeInput = (path) => path.startsWith('macos/')
  || /^tool\/test_macos_[^/]+\.swift$/.test(path)
  || path.startsWith('.github/workflows/')
  || path.startsWith('.github/actions/')
  || ['tool/self_test_scope.cjs', 'tool/test_self_test_scope.cjs',
    'tool/test_self_test_workflow.cjs'].includes(path);
const validSha = (sha) => typeof sha === 'string'
  && /^[0-9a-f]{40}$/i.test(sha) && !/^0+$/.test(sha);
const gitDiff = (range) => execFileSync('git', [
  'diff', '--name-only', '--no-renames', '-z', range, '--',
], { encoding: 'utf8', timeout: 10000, maxBuffer: 8 * 1024 * 1024,
  stdio: ['ignore', 'pipe', 'pipe'] });

function titlebarScope(eventName, event, diff = gitDiff) {
  const full = (reason) => ({ run: true, reason });
  if (eventName === 'workflow_dispatch') return full('manual full verification');
  if (eventName === 'push' && (event?.ref === 'refs/heads/main'
    || (event?.repository?.default_branch
      && event.ref === `refs/heads/${event.repository.default_branch}`))) {
    return full('main/default-branch full verification');
  }

  let base, head, separator;
  if (eventName === 'pull_request') {
    base = event?.pull_request?.base?.sha;
    head = event?.pull_request?.head?.sha;
    separator = '...'; // All PR changes, not just the latest pushed commit.
  } else if (eventName === 'push') {
    if (typeof event?.ref !== 'string' || !/^refs\/heads\/.+$/.test(event.ref)
      || typeof event?.repository?.default_branch !== 'string'
      || !event.repository.default_branch) {
      return full('unknown branch metadata; retaining native coverage');
    }
    base = event?.before;
    head = event?.after;
    separator = '..';
  } else {
    return full('unknown event; retaining native coverage');
  }
  if (!validSha(base) || !validSha(head)) {
    return full('new branch or missing comparison SHAs; retaining native coverage');
  }
  try {
    // NUL delimiters preserve unusual paths. Disabling rename detection makes
    // moves out of macos/ visible as deletions as well as additions.
    const raw = diff(`${base}${separator}${head}`);
    if (raw && !raw.endsWith('\0')) throw new Error('incomplete path list');
    const paths = raw.split('\0').filter(Boolean);
    const run = paths.some(nativeInput);
    return { run, reason: run ? 'native macOS, harness or CI inputs changed'
      : `no standalone macOS inputs among ${paths.length} changed paths` };
  } catch {
    return full('unable to inspect complete diff; retaining native coverage');
  }
}

if (require.main === module) {
  let result;
  try {
    result = titlebarScope(process.env.GITHUB_EVENT_NAME,
      JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, 'utf8')));
  } catch {
    result = { run: true, reason: 'unable to read event; retaining native coverage' };
  }
  console.log(`macOS native titlebar: ${result.run ? 'run' : 'skip'} (${result.reason})`);
  if (process.env.GITHUB_OUTPUT) {
    appendFileSync(process.env.GITHUB_OUTPUT, `macos_titlebar=${result.run}\n`);
  }
}

module.exports = { titlebarScope };
