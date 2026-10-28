import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  DEPARTMENT, OTHER_DEPARTMENT, PRIVATE_TEXT, churchTen, entryOf, holdsOutcomeText, isFictionalOutcomesPhone,
  outcomeOf, trailValues,
} from './duties-outcomes.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900140', '+447700900149']) assert.equal(isFictionalOutcomesPhone(p), true);
  for (const p of ['+447700900139', '+447700900150', '+12025550140', '447700900140']) {
    assert.equal(isFictionalOutcomesPhone(p), false);
  }
});

test('the departments are synthetic stand-ins', () => {
  assert.equal(DEPARTMENT, 'SYNTHETIC Preaching Rota');
  assert.match(OTHER_DEPARTMENT, /^SYNTHETIC /);
  for (const t of PRIVATE_TEXT) assert.match(t, /^SYNTHETIC /);
});

test('outcome notes and reasons anywhere in an answer are caught', () => {
  assert.equal(holdsOutcomeText({ departments: [{ positions: [{ assignment: { outcome: null } }] }] }), false);
  assert.equal(holdsOutcomeText({ a: [{ trail: [{ note: 'SYNTHETIC 4.10 note A' }] }] }), true);
  assert.equal(holdsOutcomeText([{ reason: 'SYNTHETIC 4.10 reason: x' }]), true);
  assert.equal(holdsOutcomeText(null), false);
});

test('positions, entries and trails are found', () => {
  const answer = { departments: [{ positions: [{ assignment: { assignment_id: 'a1', outcome_state: 'unrecorded' } }, {}] }] };
  assert.equal(outcomeOf(answer, 'a1').outcome_state, 'unrecorded');
  assert.equal(outcomeOf(answer, 'none'), null);
  assert.equal(outcomeOf(null, 'a1'), null);
  assert.equal(entryOf({ entries: [{ assignment_id: 'e1' }] }, 'e1').assignment_id, 'e1');
  assert.equal(entryOf(null, 'e1'), null);
  assert.equal(trailValues({ trail: [{ outcome: 'no_show' }, { outcome: 'completed' }] }), 'no_show>completed');
  assert.equal(trailValues(null), '');
});

test('church 10:00 is 08:00 UTC (Africa/Lusaka, no daylight saving)', () => {
  assert.equal(churchTen('2026-10-14'), '2026-10-14T08:00:00Z');
});
