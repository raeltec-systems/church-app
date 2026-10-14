import assert from 'node:assert/strict';
import { test } from 'node:test';

import { isFictionalInboxPhone, leaks, totalCounts } from './inbox.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900810', '+447700900819']) assert.equal(isFictionalInboxPhone(p), true);
  for (const p of ['+447700900809', '+447700900820', '+12025550810', '447700900810']) assert.equal(isFictionalInboxPhone(p), false);
});

test('worker counts add up across racing runs', () => {
  assert.deepEqual(totalCounts([{ claimed: 2, delivered: 2 }, { claimed: 1, delivered: 1, failed: 0 }, {}]),
    { claimed: 3, delivered: 3, obsolete: 0, ineligible: 0, failed: 0 });
});

test('leaks lists only the values found in the text', () => {
  assert.deepEqual(leaks('{"delivered":1}', ['secret', 'member-1', null]), []);
  assert.deepEqual(leaks('x member-1 y', ['secret', 'member-1']), ['member-1']);
});
