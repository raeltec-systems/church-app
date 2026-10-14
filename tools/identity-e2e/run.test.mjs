import { test } from 'node:test';
import assert from 'node:assert/strict';
import { amrMethods, assertLocalOrigin, isFictional, redact } from './run.mjs';

test('only the exact local origin is accepted', () => {
  assert.equal(assertLocalOrigin('http://127.0.0.1:54321'), 'http://127.0.0.1:54321');
  for (const u of ['https://tmurpotfluignacfueki.supabase.co', 'http://127.0.0.1:54322',
    'http://localhost:54321', 'http://user:pw@127.0.0.1:54321']) {
    assert.throws(() => assertLocalOrigin(u), u);
  }
});

test('only reserved fictional numbers are used', () => {
  assert.ok(isFictional('+12025550171'));
  assert.ok(isFictional('+447700900171'));
  for (const p of ['+12025550200', '+447700901171', '12025550171']) {
    assert.ok(!isFictional(p), p);
  }
});

test('amr methods are read without keeping the token', () => {
  const payload = Buffer.from(JSON.stringify({ amr: [{ method: 'password' }] })).toString('base64url');
  assert.deepEqual(amrMethods(`h.${payload}.s`), ['password']);
  assert.deepEqual(amrMethods(undefined), []);
  assert.deepEqual(amrMethods('not-a-jwt'), []);
});

test('secret-bearing keys are redacted at any depth', () => {
  assert.deepEqual(
    redact({ a: { access_token: 'x', ok: 1 }, password: 'p', list: [{ refresh_token: 'r' }] }),
    { a: { access_token: '[redacted]', ok: 1 }, password: '[redacted]', list: [{ refresh_token: '[redacted]' }] });
});

test('story 2.2: link tokens, email OTPs and emails are redacted too', () => {
  assert.deepEqual(
    redact({ hashed_token: 'h', token_hash: 't', email_otp: '123456', action_link: 'l', email: 'e', kinds: 'email' }),
    { hashed_token: '[redacted]', token_hash: '[redacted]', email_otp: '[redacted]', action_link: '[redacted]', email: '[redacted]', kinds: 'email' });
});
