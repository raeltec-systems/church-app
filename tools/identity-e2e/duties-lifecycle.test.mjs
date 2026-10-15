import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  DEPARTMENT, OTHER_DEPARTMENT, REASON_CODES, churchTen, coverageCounts, coveragePosition, done, holdsReason,
  isFictionalLifecyclePhone,
} from './duties-lifecycle.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900470', '+447700900479']) assert.equal(isFictionalLifecyclePhone(p), true);
  for (const p of ['+447700900469', '+447700900480', '+12025550170', '447700900470']) {
    assert.equal(isFictionalLifecyclePhone(p), false);
  }
});

test('the departments are synthetic stand-ins', () => {
  assert.equal(DEPARTMENT, 'SYNTHETIC Preaching Rota');
  assert.match(OTHER_DEPARTMENT, /^SYNTHETIC /);
});

test('a lifecycle reason anywhere in an answer is caught', () => {
  assert.equal(holdsReason({ departments: [{ positions: [{ vacated: { since: '2026-10-15T08:00:00Z' } }] }] }), false);
  for (const code of REASON_CODES) assert.equal(holdsReason([{ end_reason: `x ${code} y` }]), true);
  assert.equal(holdsReason(null), false);
});

test('coverage positions and counts are found', () => {
  const answer = { departments: [{ department_id: 'd1', counts: { vacated: 2 }, positions: [{ slot_id: 's1', status: 'unfilled' }] }] };
  assert.equal(coveragePosition(answer, 's1').status, 'unfilled');
  assert.equal(coveragePosition(answer, 'none'), null);
  assert.equal(coveragePosition(null, 's1'), null);
  assert.equal(coverageCounts(answer, 'd1').vacated, 2);
  assert.equal(coverageCounts(answer, 'd2'), null);
});

test('a command went through only without a refusal code', () => {
  assert.equal(done({ status: 200, data: {} }), true);
  assert.equal(done({ status: 200, code: 'conflict' }), false);
  assert.equal(done({ status: 409, code: 'conflict' }), false);
  assert.equal(done(undefined), false);
});

test('church 10:00 is 08:00 UTC (Africa/Lusaka, no daylight saving)', () => {
  assert.equal(churchTen('2026-10-15'), '2026-10-15T08:00:00Z');
});
