// TEST-027: fresh Claude OAuth state, including a CLI timeout with exit zero.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const repo = path.resolve(__dirname, '../..');
const valid = () => ({
  type: 'claude', access_token: 'test-access', refresh_token: 'test-refresh',
  expired: new Date(Date.now() + 3600000).toISOString(),
  last_refresh: new Date().toISOString(),
});

function runLogin({ initial, fresh, corrupt = false, dockerExit = 0 } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'cpa-login-test-'));
  fs.chmodSync(root, 0o700);
  try {
    for (const dir of ['scripts/lib', 'state/cpa/auths', 'bin']) {
      fs.mkdirSync(path.join(root, dir), { recursive: true, mode: 0o700 });
    }
    for (const file of ['scripts/cpa-claude-login.sh', 'scripts/lib/common.sh']) {
      fs.copyFileSync(path.join(repo, file), path.join(root, file));
    }
    fs.writeFileSync(path.join(root, 'state/cpa/config.yaml'), 'test: fixture\n');
    const authPath = path.join(root, 'state/cpa/auths/test.json');
    if (initial) fs.writeFileSync(authPath, JSON.stringify(initial), { mode: 0o600 });
    if (corrupt) fs.writeFileSync(authPath, '{invalid', { mode: 0o600 });
    const docker = `#!/usr/bin/env python3
import datetime, json, os, pathlib, sys
if '-claude-login' in sys.argv:
    if os.environ.get('CPA_TEST_FRESH'):
        auth = json.loads(os.environ['CPA_TEST_FRESH'])
        zone = datetime.timezone(datetime.timedelta(hours=8)) if os.environ.get('CPA_TEST_OFFSET') else datetime.timezone.utc
        now = datetime.datetime.now(zone)
        auth['last_refresh'] = now.isoformat()
        auth['expired'] = (now + datetime.timedelta(hours=1)).isoformat()
        pathlib.Path('state/cpa/auths/test.json').write_text(json.dumps(auth))
    else:
        print('OAuth callback timed out')
    sys.exit(int(os.environ['CPA_TEST_DOCKER_EXIT']))
sys.exit(0)
`;
    fs.writeFileSync(path.join(root, 'bin/docker'), docker, { mode: 0o700 });
    return spawnSync('script', ['--quiet', '--return', '--command',
      'bash "$CPA_TEST_LOGIN_SCRIPT"', '/dev/null'], {
      cwd: root, encoding: 'utf8', timeout: 10000,
      env: { PATH: `${path.join(root, 'bin')}:${process.env.PATH}`,
        CPA_TEST_LOGIN_SCRIPT: path.join(root, 'scripts/cpa-claude-login.sh'),
        CPA_TEST_FRESH: fresh ? JSON.stringify(fresh.auth) : '',
        CPA_TEST_OFFSET: fresh?.offset ? '1' : '',
        CPA_TEST_DOCKER_EXIT: String(dockerExit) },
    });
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

test('Claude login accepts newly refreshed UTC and offset OAuth state', () => {
  for (const offset of [false, true]) {
    const result = runLogin({ fresh: { auth: valid(), offset } });
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stdout, /Claude OAuth state is ready/);
  }
});

test('Claude login rejects old, invalid, and incomplete OAuth state after CLI exit zero', () => {
  const old = () => ({ ...valid(), last_refresh: new Date(Date.now() - 60000).toISOString() });
  const cases = [
    {}, { corrupt: true }, { initial: old() },
    { initial: { ...old(), expired: new Date(Date.now() - 1000).toISOString() } },
    { initial: { ...valid(), disabled: true } },
    { initial: { ...valid(), access_token: '' } },
    { initial: { ...valid(), refresh_token: '  ' } },
    { initial: { ...valid(), type: 'codex' } },
    { initial: { ...valid(), last_refresh: undefined } },
    { initial: { ...valid(), expired: 'invalid' } },
    { initial: { ...valid(), expired: new Date(Date.now() + 3600000).toISOString().slice(0, -1) } },
    { initial: { ...valid(), last_refresh: new Date().toISOString().slice(0, -1) } },
    { initial: { ...valid(), last_refresh: new Date(Date.now() + 3600000).toISOString() } },
    { initial: ['invalid'] },
  ];
  for (const fixture of cases) {
    const result = runLogin(fixture);
    assert.equal(result.status, 1, result.stderr + result.stdout);
    assert.match(result.stdout, /did not produce fresh, unexpired OAuth state/);
    assert.doesNotMatch(result.stdout, /Claude OAuth state is ready/);
  }
});

test('Claude login preserves a failed Docker exit', () => {
  const result = runLogin({ dockerExit: 7 });
  assert.equal(result.status, 7);
  assert.doesNotMatch(result.stdout, /Claude OAuth state is ready/);
});
