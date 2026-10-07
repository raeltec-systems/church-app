import assert from 'node:assert/strict';
import { test } from 'node:test';

import { MY_STATUS_KEYS, isFictionalLifecyclePhone, requestCode, unexpectedStatusKeys } from './lifecycle.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900520', '+447700900524', '+447700900529']) assert.equal(isFictionalLifecyclePhone(p), true);
  for (const p of ['+447700900519', '+447700900530', '+12025550120', '+260970000520']) assert.equal(isFictionalLifecyclePhone(p), false);
});

test('the member status may not carry a reason, an actor or an obligation', () => {
  const read = Object.fromEntries(MY_STATUS_KEYS.map((k) => [k, null]));
  assert.deepEqual(unexpectedStatusKeys(read), []);
  assert.deepEqual(unexpectedStatusKeys({ ...read, reason_code: 'church_decision', obligations: [] }), ['obligations', 'reason_code']);
  assert.deepEqual(unexpectedStatusKeys(null), []);
});

test('request codes use the 2.9 alphabet', () => {
  for (let i = 0; i < 50; i++) assert.match(requestCode(), /^[A-HJ-NP-Z2-9]{8}$/);
});
