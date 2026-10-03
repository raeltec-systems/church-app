import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { digestOf, judge, mintToken, scrub, tokenEnvironment, TOKEN_RE } from './system-credential.mjs';
import { findSecrets } from '../ci/secret-patterns.mjs';

const CLI = fileURLToPath(new URL('./system-credential.mjs', import.meta.url));

test('minted credentials are environment-prefixed, 256-bit and caught by the secret scan', () => {
  for (const env of ['local', 'staging', 'production']) {
    const t = mintToken(env);
    assert.match(t, TOKEN_RE);
    assert.equal(tokenEnvironment(t), env);
    assert.equal(Buffer.from(t.slice(`sysc_${env}_`.length), 'base64url').length, 32);
    assert.equal(findSecrets(t)[0].rule, 'system_credential');
  }
  assert.notEqual(mintToken('local'), mintToken('local'));
  assert.throws(() => mintToken('prod'));
});

test('digest is sha256 hex of the whole token (environment included)', () => {
  const body = 'A'.repeat(43);
  assert.match(digestOf(`sysc_local_${body}`), /^[0-9a-f]{64}$/);
  assert.notEqual(digestOf(`sysc_local_${body}`), digestOf(`sysc_staging_${body}`));
  assert.throws(() => digestOf('sysc_local_short'));
});

test('scrub removes stored secrets and any credential-shaped value', () => {
  const t = mintToken('staging');
  const out = scrub(`a ${t} b jwt.x.y c`, ['jwt.x.y']);
  assert.ok(!out.includes(t) && !out.includes('jwt.x.y'));
  assert.match(out, /sysc_staging_\[redacted\]/);
});

test('the matrix judge accepts only the expected outcome per case', () => {
  const ctx = { env: 'local', requestId: 'r1', principalId: 'p1' };
  const actor = { kind: 'system', system_principal_id: 'p1', job_id: 'r1', initiating_member_id: null };
  const ok = { status: 200, body: { request_id: 'r1', revision: 1, data: { environment: 'local', actor } } };
  assert.equal(judge('valid_credential', ok, ctx), true);
  assert.equal(judge('valid_credential', { ...ok, body: { ...ok.body, data: { ...ok.body.data, environment: 'staging' } } }, ctx), false);
  assert.equal(judge('user_jwt_with_valid_credential', ok, ctx), false, 'a session that succeeds fails the matrix');
  assert.equal(judge('user_jwt_with_valid_credential', { status: 200, body: { code: 'forbidden' } }, ctx), true);
  assert.equal(judge('wrong_environment_credential_staging', { status: 200, body: { code: 'unauthenticated' } }, ctx), true);
  assert.equal(judge('wrong_environment_credential_staging', ok, ctx), false);
  const forged = { status: 200, body: { data: { actor: { system_principal_id: 'forged', initiating_member_id: null } } } };
  assert.equal(judge('forged_actor_headers', forged, ctx), false);
  assert.equal(judge('forged_jwt_bearer', { status: 401, body: {} }, ctx), true);
  assert.equal(judge('unknown_case', ok, ctx), false);
});

test('mint stores the token 0600 in the state dir and prints only the digest', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ops-state-'));
  const env = { ...process.env, OPS_STATE_DIR: dir };
  const out = execFileSync('node', [CLI, 'mint', '--env', 'local'], { env }).toString();
  const token = readFileSync(join(dir, 'local.credential'), 'utf8').trim();
  assert.ok(!out.includes(token));
  assert.equal(JSON.parse(out).digest, digestOf(token));
  assert.equal(statSync(join(dir, 'local.credential')).mode & 0o777, 0o600);
  assert.throws(() => execFileSync('node', [CLI, 'mint', '--env', 'local'], { env, stdio: 'pipe' }));
});
