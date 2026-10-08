import assert from 'node:assert/strict';
import { test } from 'node:test';

import { isFictionalRoutingPhone, leaks, syntheticDeviceToken } from './routing.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900890', '+447700900899']) assert.equal(isFictionalRoutingPhone(p), true);
  for (const p of ['+447700900889', '+447700900900', '447700900890', '+12025550890']) assert.equal(isFictionalRoutingPhone(p), false);
});

test('synthetic device tokens have the stored shape and differ each time', () => {
  const a = syntheticDeviceToken();
  assert.match(a, /^[A-Za-z0-9_:.-]+$/);
  assert.ok(a.length >= 20 && a.length <= 4096);
  assert.notEqual(a, syntheticDeviceToken());
});

test('leaks lists only the values found in the text', () => {
  assert.deepEqual(leaks('{"delivered":1}', ['secret', null]), []);
  assert.deepEqual(leaks('x member-1 y', ['secret', 'member-1']), ['member-1']);
});
