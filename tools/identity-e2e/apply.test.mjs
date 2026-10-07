import assert from 'node:assert/strict';
import { test } from 'node:test';

import { isFictionalApplyPhone, unsafeOptionKeys } from './apply.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+12025550181', '+12025550182', '+447700900181']) assert.equal(isFictionalApplyPhone(p), true);
  for (const p of ['+12025550183', '+12025550100', '+447700900182', '+99900000001']) assert.equal(isFictionalApplyPhone(p), false);
});

test('a chooser option may carry only the safe projection keys', () => {
  assert.deepEqual(unsafeOptionKeys([{ cell_id: 'x', label: 'l', broad_area: 'a', revision: 1 }]), []);
  assert.deepEqual(unsafeOptionKeys([{ cell_id: 'x', label: 'l', leader_phone: 'p', members: [] }]), ['leader_phone', 'members']);
  assert.deepEqual(unsafeOptionKeys(undefined), []);
});
