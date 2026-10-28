import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  CELL, DEPARTMENT, allOrNothing, churchInstant, churchSunday, isFictionalResponsesPhone, raceOrder, selection,
} from './duties-responses.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900560', '+447700900569']) assert.equal(isFictionalResponsesPhone(p), true);
  for (const p of ['+447700900559', '+447700900570', '+12025550560', '447700900560']) {
    assert.equal(isFictionalResponsesPhone(p), false);
  }
});

test('the department and the cell are synthetic', () => {
  for (const n of [DEPARTMENT, CELL]) assert.match(n, /^SYNTHETIC /);
});

test('church Sundays and instants', () => {
  assert.equal(churchSunday(Date.parse('2099-01-07T10:00:00Z'), 0), '2099-01-11');
  assert.equal(churchInstant('2099-01-04', '00:30'), '2099-01-03T22:30:00.000Z');
});

test('a selection carries each date at the revision the member saw', () => {
  assert.deepEqual(selection([{ id: 'a', revision: 1 }, { id: 'b', revision: 3 }]), {
    assignments: [{ assignment_id: 'a', revision: 1 }, { assignment_id: 'b', revision: 3 }],
  });
});

test('a race round is all or nothing', () => {
  assert.equal(allOrNothing({ bulk: { status: 200 }, acceptedCount: 3, selected: 3 }), true);
  assert.equal(allOrNothing({ bulk: { status: 200, code: 'conflict' }, acceptedCount: 0, selected: 3 }), true);
  assert.equal(allOrNothing({ bulk: { status: 200 }, acceptedCount: 2, selected: 3 }), false);
  assert.equal(allOrNothing({ bulk: { status: 200, code: 'conflict' }, acceptedCount: 1, selected: 3 }), false);
  assert.equal(allOrNothing({ bulk: { status: 200, code: 'unavailable' }, acceptedCount: 0, selected: 3 }), false);
  assert.equal(allOrNothing({ bulk: undefined, acceptedCount: 0, selected: 3 }), false);
});

test('each race round names the order it took', () => {
  assert.equal(raceOrder({ bulk: { status: 200 }, acceptedCount: 3, selected: 3 }), 'bulk_first');
  assert.equal(raceOrder({ bulk: { status: 200, code: 'conflict' }, acceptedCount: 0, selected: 3 }), 'edit_first');
  assert.equal(raceOrder({ bulk: { status: 200 }, acceptedCount: 2, selected: 3 }), 'partial');
  assert.equal(raceOrder({ bulk: { status: 200, code: 'conflict' }, acceptedCount: 1, selected: 3 }), 'partial');
});
