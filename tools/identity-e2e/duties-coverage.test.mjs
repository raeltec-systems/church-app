import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  DEPARTMENT, GENERIC_TEXT, HOUSEHOLD_PHONE, OTHER_DEPARTMENT, holdsPrivate, isFictionalCoveragePhone,
  isGenericItem, positionOf, summarize,
} from './duties-coverage.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900790', '+447700900799', HOUSEHOLD_PHONE]) assert.equal(isFictionalCoveragePhone(p), true);
  for (const p of ['+447700900789', '+447700900800', '+12025550790', '447700900790']) {
    assert.equal(isFictionalCoveragePhone(p), false);
  }
});

test('the departments are synthetic stand-ins', () => {
  assert.equal(DEPARTMENT, 'SYNTHETIC Preaching Rota');
  assert.match(OTHER_DEPARTMENT, /^SYNTHETIC /);
});

test('only the exact generic text of a kind passes', () => {
  for (const [kind, [title, body]] of Object.entries(GENERIC_TEXT)) {
    assert.equal(isGenericItem({ reminder_kind: kind, title, body }), true);
    assert.equal(isGenericItem({ reminder_kind: kind, title, body: `${body} SYNTHETIC Ruth` }), false);
    assert.ok(title.length <= 60 && body.length <= 160, kind);
    assert.doesNotMatch(title + body, /SYNTHETIC|[{}<>@]|\d{3}/);
  }
  assert.equal(isGenericItem({ reminder_kind: 'duty_starting', title: 'x', body: 'y' }), false);
  assert.equal(isGenericItem(null), false);
});

test('anything private in a coverage answer is caught', () => {
  const clean = { departments: [{ contact_routes: {}, positions: [
    { slot_id: 's', assignment: { assignment_id: 'a', confirmation: { channel: 'phone', reason: null } },
      follow_up: { task_id: null, last_attempt: { note: null } } }] }] };
  assert.equal(holdsPrivate(clean), false);
  assert.equal(holdsPrivate({ departments: [{ contact_routes: { m: [{ phone: '+447700900796' }] }, positions: [] }] }), true);
  const withReason = structuredClone(clean);
  withReason.departments[0].positions[0].assignment.confirmation.reason = 'x';
  assert.equal(holdsPrivate(withReason), true);
  const withTask = structuredClone(clean);
  withTask.departments[0].positions[0].follow_up.task_id = 't';
  assert.equal(holdsPrivate(withTask), true);
  const withNote = structuredClone(clean);
  withNote.departments[0].positions[0].follow_up.last_attempt.note = 'n';
  assert.equal(holdsPrivate(withNote), true);
  assert.equal(holdsPrivate({ departments: [{ name: 'SYNTHETIC household', positions: [] }] }), true);
  assert.equal(holdsPrivate(null), false);
});

test('positions are found by assignment or slot', () => {
  const c = { departments: [{ positions: [{ slot_id: 's1', assignment: { assignment_id: 'a1' } }, { slot_id: 's2' }] }] };
  assert.equal(positionOf(c, 'a1').slot_id, 's1');
  assert.equal(positionOf(c, 's2').slot_id, 's2');
  assert.equal(positionOf(c, 'none'), null);
  assert.equal(positionOf(null, 'a1'), null);
});

test('the pending summary is order independent', () => {
  assert.equal(summarize(['m:b', 'l:a']), 'l:a,m:b');
  assert.equal(summarize([]), '');
});
