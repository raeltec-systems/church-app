import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { test } from 'node:test';

import { codeFrom, isFictionalRecoveryPhone, pkcePair, redirectFacts } from './recovery.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900280', '+447700900284', '+447700900289']) assert.equal(isFictionalRecoveryPhone(p), true);
  for (const p of ['+447700900279', '+447700900290', '+12025550180', '+260970000280']) assert.equal(isFictionalRecoveryPhone(p), false);
});

test('a PKCE pair is a base64url verifier and its S256 challenge', () => {
  const { verifier, challenge } = pkcePair(Buffer.alloc(32, 7));
  assert.match(verifier, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(challenge, createHash('sha256').update(verifier).digest('base64url'));
});

test('redirect facts keep the base and drop the code', () => {
  const mobile = redirectFacts('zm.bickafue.mobile://callback/auth/recovery?code=secret-code');
  assert.deepEqual(mobile, { base: 'zm.bickafue.mobile://callback/auth/recovery', has_code: true, error_code: null });
  assert.equal(JSON.stringify(mobile).includes('secret-code'), false);
  const web = redirectFacts('http://127.0.0.1:3000/?code=secret-code#/auth/recovery');
  assert.deepEqual(web, { base: 'http://127.0.0.1:3000/#/auth/recovery', has_code: true, error_code: null });
  const reused = redirectFacts('zm.bickafue.mobile://callback/auth/recovery?error=access_denied&error_code=otp_expired#error=access_denied&error_code=otp_expired');
  assert.deepEqual(reused, { base: 'zm.bickafue.mobile://callback/auth/recovery', has_code: false, error_code: 'otp_expired' });
  assert.deepEqual(redirectFacts(null), { base: null, has_code: false, error_code: null });
});

test('the code is read from the query, never from the route fragment', () => {
  assert.equal(codeFrom('http://127.0.0.1:3000/?code=abc#/auth/recovery'), 'abc');
  assert.equal(codeFrom('http://127.0.0.1:3000/#/auth/recovery?code=abc'), null);
  assert.equal(codeFrom(undefined), null);
});
