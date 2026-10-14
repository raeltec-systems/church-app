import assert from 'node:assert/strict';
import { test } from 'node:test';

import { isFictionalReviewPhone, leakedStaffKeys } from './review.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+12025550190', '+12025550195', '+12025550199']) assert.equal(isFictionalReviewPhone(p), true);
  for (const p of ['+12025550189', '+12025550200', '+447700900190', '+99900000190']) assert.equal(isFictionalReviewPhone(p), false);
});

test('an applicant view must carry no staff-only review keys', () => {
  assert.deepEqual(leakedStaffKeys({ application_id: 'x', church_status: 'approved' }), []);
  assert.deepEqual(leakedStaffKeys({ candidates: [], member_id: 'm' }), ['candidates', 'member_id']);
  assert.deepEqual(leakedStaffKeys(undefined), []);
});
