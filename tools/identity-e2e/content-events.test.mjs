import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  HARVEST, PUBLIC_KEYS, churchDate, churchDayAt, findEvent, isFictionalContentPhone, sortedKeys,
} from './content-events.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900100', '+447700900109']) assert.equal(isFictionalContentPhone(p), true);
  for (const p of ['+447700900099', '+447700900110', '+12025550151', '447700900100']) {
    assert.equal(isFictionalContentPhone(p), false);
  }
});

test('the event is synthetic', () => {
  assert.match(HARVEST, /^SYNTHETIC /);
});

test('church days are Lusaka days (UTC+2)', () => {
  // 2099-01-03 23:30 UTC is already Sunday 4 January in Lusaka.
  const now = Date.parse('2099-01-03T23:30:00Z');
  assert.equal(churchDayAt(now, 0, '09:00'), '2099-01-04T07:00:00.000Z');
  assert.equal(churchDayAt(now, 1, '12:00'), '2099-01-05T10:00:00.000Z');
  assert.equal(churchDate('2099-01-04T22:30:00.000000Z'), '2099-01-05');
  assert.equal(churchDate('2099-01-04T21:59:00.000000Z'), '2099-01-04');
});

test('the public projection keys are compared sorted', () => {
  assert.deepEqual(PUBLIC_KEYS, [...PUBLIC_KEYS].sort());
  assert.deepEqual(sortedKeys({ title: 1, event_id: 2 }), ['event_id', 'title']);
  assert.deepEqual(sortedKeys(undefined), []);
});

test('an event is found by id in a list read', () => {
  const list = { events: [{ event_id: 'a', title: 'x' }, { event_id: 'b', title: 'y' }] };
  assert.equal(findEvent(list, 'b')?.title, 'y');
  assert.equal(findEvent(list, 'c'), undefined);
  assert.equal(findEvent(null, 'a'), undefined);
});
