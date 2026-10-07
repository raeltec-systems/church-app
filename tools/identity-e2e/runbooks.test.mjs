import assert from 'node:assert/strict';
import { test } from 'node:test';

import { AUTH_FACTS, changedAuthFacts, isFictionalRunbookPhone, linkSecrets } from './runbooks.mjs';

test('only the reserved fictional numbers of the rehearsal are accepted', () => {
  for (const p of ['+447700900700', '+447700900710', '+447700900719']) assert.equal(isFictionalRunbookPhone(p), true);
  for (const p of ['+447700900699', '+447700900720', '+12025550170', '+260970000700']) assert.equal(isFictionalRunbookPhone(p), false);
});

test('an emailed link yields the link and its token parameters as secrets', () => {
  const link = 'http://127.0.0.1:54321/auth/v1/verify?token=pkce_abc123def&type=recovery&redirect_to=x';
  assert.deepEqual(linkSecrets(link), [link, 'pkce_abc123def']);
  assert.deepEqual(linkSecrets(null), []);
  assert.deepEqual(linkSecrets('not a url'), ['not a url']);
});

test('any change to an Auth fact the operator must not touch is reported', () => {
  const before = Object.fromEntries(AUTH_FACTS.map((k) => [k, k === 'sessions' ? 1 : `v-${k}`]));
  assert.deepEqual(changedAuthFacts(before, { ...before }), []);
  assert.deepEqual(changedAuthFacts(before, { ...before, encrypted_password: 'other', sessions: 2 }),
    ['encrypted_password', 'sessions']);
  assert.deepEqual(changedAuthFacts(before, null).length, AUTH_FACTS.length);
});
