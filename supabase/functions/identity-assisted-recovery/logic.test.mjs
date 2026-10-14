// Offline tests for the identity-assisted-recovery rules (story 2.9).
// Run: node --test supabase/functions/identity-assisted-recovery/logic.test.mjs
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import {
  classifyAuthResult,
  clientIp,
  clientKey,
  declaredTooLarge,
  digestHex,
  keyHeaders,
  leaks,
  parseBody,
  redeemOutcome,
  requestOutcome,
  systemEnvelope,
} from './logic.mjs';

const SECRET = `arg_${'A'.repeat(43)}`;
const DIGEST = 'a'.repeat(64);

test('parseBody accepts exactly the documented shapes', () => {
  assert.equal(parseBody({ action: 'request', phone_username: '+447700900430', grant_digest: DIGEST }).ok, true);
  assert.equal(parseBody({ action: 'status', grant_digest: DIGEST }).ok, true);
  assert.equal(parseBody({ action: 'redeem', phone_username: '+447700900430', grant_secret: SECRET, password: 'long enough' }).ok, true);
});

test('parseBody refuses unknown fields, bad values and forged identities', () => {
  const cases = [
    [null, 'invalid_body'],
    [[], 'invalid_body'],
    [{ action: 'issue' }, 'invalid_action'],
    [{ action: 'status', grant_digest: DIGEST, member_id: 'x' }, 'unknown_field'],
    [{ action: 'redeem', phone_username: '+447700900430', grant_secret: SECRET, password: 'long enough', auth_user_id: 'x' }, 'unknown_field'],
    [{ action: 'request', phone_username: '0977123456', grant_digest: DIGEST }, 'invalid_phone_username'],
    [{ action: 'request', phone_username: '+447700900430', grant_digest: 'XYZ' }, 'invalid_grant_digest'],
    [{ action: 'redeem', phone_username: '+447700900430', grant_secret: 'arg_short', password: 'long enough' }, 'invalid_grant'],
    [{ action: 'redeem', phone_username: '+447700900430', grant_secret: SECRET, password: 'short' }, 'password_length'],
    [{ action: 'redeem', phone_username: '+447700900430', grant_secret: SECRET, password: 'x'.repeat(73) }, 'password_length'],
    [{ action: 'redeem', phone_username: '+447700900430', grant_secret: SECRET, password: 12345678 }, 'invalid_password'],
  ];
  for (const [body, error] of cases) assert.deepEqual(parseBody(body), { ok: false, error }, JSON.stringify(body));
});

test('the password limit counts UTF-8 bytes (bcrypt uses at most 72)', () => {
  assert.equal(parseBody({ action: 'redeem', phone_username: '+447700900430', grant_secret: SECRET, password: 'é'.repeat(36) }).ok, true);
  assert.equal(parseBody({ action: 'redeem', phone_username: '+447700900430', grant_secret: SECRET, password: 'é'.repeat(37) }).ok, false);
});

test('digestHex is the sha256 of the secret (what the device sent)', async () => {
  assert.equal(await digestHex(SECRET), createHash('sha256').update(SECRET, 'utf8').digest('hex'));
});

test('Auth Admin results: only 2xx is applied, refusals are rejected, the rest unknown', () => {
  assert.equal(classifyAuthResult(200), 'applied');
  assert.equal(classifyAuthResult(422), 'rejected');
  assert.equal(classifyAuthResult(400), 'rejected');
  assert.equal(classifyAuthResult(401), 'rejected');
  assert.equal(classifyAuthResult(408), 'unknown');
  assert.equal(classifyAuthResult(429), 'unknown');
  assert.equal(classifyAuthResult(500), 'unknown');
  assert.equal(classifyAuthResult(504), 'unknown');
  assert.equal(classifyAuthResult(null), 'unknown');
});

test('member outcomes never say more than the database decided', () => {
  assert.equal(redeemOutcome('succeeded'), 'succeeded');
  assert.equal(redeemOutcome('failed'), 'password_rejected');
  assert.equal(redeemOutcome('uncertain'), 'uncertain');
  assert.equal(redeemOutcome('obsolete'), 'uncertain');
  assert.equal(requestOutcome({ accepted: true, request_code: 'ABCDEFGH' }), 'received');
  assert.equal(requestOutcome({ accepted: false, reason: 'rate_limited' }), 'rate_limited');
  assert.equal(requestOutcome({ accepted: false, reason: 'invalid' }), 'refused');
  assert.equal(requestOutcome({ accepted: false, reason: 'unsupported' }), 'unavailable');
  assert.equal(requestOutcome(null), 'unavailable');
});

test('key headers: a JWT key also authorizes, a new-format key only identifies', () => {
  assert.deepEqual(keyHeaders('eyJabc'), { apikey: 'eyJabc', authorization: 'Bearer eyJabc' });
  assert.deepEqual(keyHeaders('sb_publishable_x'), { apikey: 'sb_publishable_x' });
});

test('the system envelope carries no expected_revision and no actor', () => {
  const env = systemEnvelope('identity.assisted_reset_begin', { grant_digest: DIGEST }, 'r');
  assert.deepEqual(Object.keys(env).sort(), ['command', 'payload', 'request_id', 'version']);
});

test('leaks finds secrets in text', () => {
  assert.deepEqual(leaks(`x ${SECRET} y`, [SECRET, 'other-secret']), [SECRET]);
  assert.deepEqual(leaks('nothing here', [SECRET]), []);
});

test('the function never logs or returns a body value', () => {
  const src = readFileSync(new URL('./index.ts', import.meta.url), 'utf8');
  const logs = [...src.matchAll(/console\.(log|error|warn|info)\(([^;]*)\);/g)].map((m) => m[2]);
  assert.equal(logs.length, 1, 'one log call');
  assert.match(logs[0], /JSON\.stringify\(\{ fn: 'identity-assisted-recovery', action, outcome \}\)/);
  assert.doesNotMatch(src, /reply\([^)]*(password|grant_secret|grant_digest|auth_user_id|operation_id)/);
});

test('a declared body over 4096 bytes (or a malformed length) is refused before reading', () => {
  assert.equal(declaredTooLarge(null), false);
  assert.equal(declaredTooLarge('120'), false);
  assert.equal(declaredTooLarge('4096'), false);
  assert.equal(declaredTooLarge('4097'), true);
  assert.equal(declaredTooLarge('-1'), true);
  assert.equal(declaredTooLarge('1e9'), true);
});

test('the function caps the bytes it reads and never buffers the whole body first', () => {
  const src = readFileSync(new URL('./index.ts', import.meta.url), 'utf8');
  assert.doesNotMatch(src, /req\.(text|json|arrayBuffer|blob|formData)\(/);
  assert.match(src, /declaredTooLarge\(req\.headers\.get\('content-length'\)\)/);
  assert.match(src, /total > MAX_BODY_BYTES/);
});

test('the client IP is the first x-forwarded-for hop, else unknown (null)', () => {
  assert.equal(clientIp('203.0.113.7, 172.18.0.1'), '203.0.113.7');
  assert.equal(clientIp(' 2001:DB8::1 , 10.0.0.1'), '2001:db8::1');
  assert.equal(clientIp('203.0.113.007'), '203.0.113.7');
  for (const bad of [null, undefined, '', 'not-an-ip, 172.18.0.1', '999.1.1.1', 'a'.repeat(50), 'unknown']) {
    assert.equal(clientIp(bad), null, String(bad));
  }
});

test('client keys are keyed hashes: same IP same key, other IP other key, one shared unknown key', async () => {
  const secret = 'sysc_local_' + 'A'.repeat(43);
  const a = await clientKey('203.0.113.7', secret);
  assert.match(a, /^[0-9a-f]{64}$/);
  assert.equal(await clientKey('203.0.113.7', secret), a);
  assert.notEqual(await clientKey('203.0.113.8', secret), a);
  assert.notEqual(await clientKey('203.0.113.7', secret + 'x'), a, 'keyed by the secret');
  assert.equal(await clientKey(clientIp('garbage'), secret), await clientKey(clientIp(null), secret));
  assert.notEqual(a, createHash('sha256').update('203.0.113.7').digest('hex'), 'not a plain hash of the IP');
});

test('the function never logs or returns the client IP', () => {
  const src = readFileSync(new URL('./index.ts', import.meta.url), 'utf8');
  assert.doesNotMatch(src, /note\([^)]*(client|forwarded)/i);
  assert.doesNotMatch(src, /reply\([^)]*(client|forwarded)/i);
});
