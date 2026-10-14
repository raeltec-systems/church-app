import assert from 'node:assert/strict';
import { test } from 'node:test';

import { MY_CREDENTIALS_KEYS, isFictionalCredentialPhone, unexpectedKeys } from './credentials.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900330', '+447700900342', '+447700900349']) assert.equal(isFictionalCredentialPhone(p), true);
  for (const p of ['+447700900329', '+447700900350', '+12025550133', '+260970000330']) assert.equal(isFictionalCredentialPhone(p), false);
});

test('the member read may not carry a reason for the review', () => {
  const read = Object.fromEntries(MY_CREDENTIALS_KEYS.map((k) => [k, null]));
  assert.deepEqual(unexpectedKeys(read), []);
  assert.deepEqual(unexpectedKeys({ ...read, hold: {}, reason_code: 'lost_device' }), ['hold', 'reason_code']);
  assert.deepEqual(unexpectedKeys(null), []);
});
