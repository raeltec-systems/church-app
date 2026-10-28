import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  CELL, DEPARTMENT, OTHER_DEPARTMENT, candidate, churchInstant, churchSunday, isFictionalOverlapPhone, isLimited,
  oneAssigned,
} from './duties-overlaps.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900760', '+447700900769']) assert.equal(isFictionalOverlapPhone(p), true);
  for (const p of ['+447700900759', '+447700900770', '+12025550760', '447700900760']) {
    assert.equal(isFictionalOverlapPhone(p), false);
  }
});

test('departments and the cell are synthetic', () => {
  for (const n of [DEPARTMENT, OTHER_DEPARTMENT, CELL]) assert.match(n, /^SYNTHETIC /);
});

test('church Sundays and instants', () => {
  assert.equal(churchSunday(Date.parse('2099-01-07T10:00:00Z'), 0), '2099-01-11');
  assert.equal(churchInstant('2099-01-04', '00:30'), '2099-01-03T22:30:00.000Z');
});

test('a limited conflict carries only its owner kind and busy time', () => {
  assert.equal(isLimited({ visibility: 'limited', owner_kind: 'cell', from: 'a', to: 'b' }), true);
  assert.equal(isLimited({ visibility: 'limited', owner_kind: 'cell', from: 'a', to: 'b', duty_name: 'x' }), false);
  assert.equal(isLimited({ visibility: 'full', owner_kind: 'cell', from: 'a', to: 'b' }), false);
  assert.equal(isLimited(undefined), false);
});

test('exactly one assignment wins a race; the other is refused for the overlap', () => {
  const refusal = { status: 200, code: 'validation_failed', field_errors: { member_id: 'overlap', override_reason: 'required' } };
  assert.equal(oneAssigned([{ status: 200 }, refusal]), true);
  assert.equal(oneAssigned([{ status: 200 }, { status: 200 }]), false);
  assert.equal(oneAssigned([refusal, refusal]), false);
  assert.equal(oneAssigned([{ status: 200 }, { status: 200, code: 'conflict' }]), false);
});

test('candidates are read defensively', () => {
  assert.equal(candidate(null, 'x'), null);
  assert.deepEqual(candidate({ candidates: [{ member_id: 'x', n: 1 }] }, 'x'), { member_id: 'x', n: 1 });
});
