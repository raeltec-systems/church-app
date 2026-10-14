import assert from 'node:assert/strict';
import { test } from 'node:test';

import { DEPARTMENT, changedFields, firstPosition, isFictionalRevisionPhone, oneWinner } from './duties-revisions.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900980', '+447700900989']) assert.equal(isFictionalRevisionPhone(p), true);
  for (const p of ['+447700900979', '+447700900990', '+12025550980', '447700900980']) assert.equal(isFictionalRevisionPhone(p), false);
});

test('the department is synthetic', () => {
  assert.match(DEPARTMENT, /^SYNTHETIC /);
});

test('the changed fields of a stale refusal are read from its field errors', () => {
  assert.deepEqual(changedFields({ assignment_id: 'superseded', starts_at: 'changed', location: 'changed' }), ['location', 'starts_at']);
  assert.deepEqual(changedFields(null), []);
});

test('exactly one winner among concurrent edits', () => {
  assert.equal(oneWinner([{ status: 200 }, { status: 200, code: 'conflict' }]), true);
  assert.equal(oneWinner([{ status: 200 }, { status: 200 }]), false);
  assert.equal(oneWinner([{ status: 200, code: 'conflict' }, { status: 200, code: 'conflict' }]), false);
  assert.equal(oneWinner([{ status: 200 }, { status: 200, code: 'unavailable' }]), false);
});

test('the first position is read defensively', () => {
  assert.equal(firstPosition(null), null);
  assert.equal(firstPosition({ positions: [] }), null);
  assert.deepEqual(firstPosition({ positions: [{ slot_revision: 2 }] }), { slot_revision: 2 });
});
