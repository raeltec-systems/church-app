import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  COUNT_KEYS, DEPARTMENT, OTHER_DEPARTMENT, RETREAT, SUNDAY, YOUTH, boardDuty, done, isFictionalLinksPhone, namesDuties, refused,
} from './content-event-duty-links.mjs';

test('only the reserved fictional block +44 7700 900291-900299 is used', () => {
  for (const p of ['+447700900291', '+447700900295', '+447700900299']) assert.equal(isFictionalLinksPhone(p), true);
  for (const p of ['+447700900290', '+447700900300', '+12025550291', '447700900291']) assert.equal(isFictionalLinksPhone(p), false);
});

test('names are SYNTHETIC and the count read carries counts only', () => {
  for (const t of [DEPARTMENT, OTHER_DEPARTMENT, SUNDAY, YOUTH, RETREAT]) assert.match(t, /^SYNTHETIC /);
  assert.equal(DEPARTMENT, 'SYNTHETIC Preaching Rota');
  assert.deepEqual([...COUNT_KEYS].sort(), COUNT_KEYS);
  assert.ok(!COUNT_KEYS.some((k) => /name|member|title/.test(k)));
});

test('a duty, rota, department or review key anywhere is caught', () => {
  assert.equal(namesDuties({ events: [{ title: 'x', starts_at: 'y' }] }), false);
  assert.equal(namesDuties({ events: [{ title: 'x', linked_duties: 1 }] }), true);
  assert.equal(namesDuties({ event: { rota: null } }), true);
  assert.equal(namesDuties([{ a: [{ department_id: 1 }] }]), true);
  assert.equal(namesDuties(null), false);
});

test('answers, refusals and the board lookup', () => {
  assert.equal(done({ status: 200, data: {} }), true);
  assert.equal(done({ status: 200, code: 'conflict' }), false);
  const r = { code: 'validation_failed', field_errors: { event_ref: 'not_published' } };
  assert.equal(refused(r, 'validation_failed', 'event_ref', 'not_published'), true);
  assert.equal(refused(r, 'validation_failed', 'event_ref', 'other'), false);
  const board = { departments: [{ duties: [{ occurrence_id: 'a' }, { occurrence_id: 'b', reviews: [1] }] }] };
  assert.deepEqual(boardDuty(board, 'b'), { occurrence_id: 'b', reviews: [1] });
  assert.equal(boardDuty(board, 'c'), null);
});
