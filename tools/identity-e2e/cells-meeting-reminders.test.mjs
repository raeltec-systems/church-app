import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  ESTATES, SHIKOSWE, containsNone, hoursBefore, isFictionalMeetingRemindersPhone, weekdayInThreeDays,
} from './cells-meeting-reminders.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900390', '+447700900399']) assert.equal(isFictionalMeetingRemindersPhone(p), true);
  for (const p of ['+447700900389', '+447700900400', '+12025550390', '447700900390']) {
    assert.equal(isFictionalMeetingRemindersPhone(p), false);
  }
});

test('the cells are synthetic', () => {
  assert.match(SHIKOSWE, /^SYNTHETIC /);
  assert.match(ESTATES, /^SYNTHETIC /);
});

test('the first meeting falls three church days ahead (ISO weekday, Monday = 1)', () => {
  // Friday 2099-01-02 10:00 UTC: three days on is Monday.
  assert.equal(weekdayInThreeDays(Date.parse('2099-01-02T10:00:00Z')), 1);
  // Saturday 2099-01-03 23:30 UTC is Sunday 01:30 in Lusaka: three days on is Wednesday.
  assert.equal(weekdayInThreeDays(Date.parse('2099-01-03T23:30:00Z')), 3);
});

test('a reminder offset is read in whole hours before the start', () => {
  assert.equal(hoursBefore('2099-01-01T16:00:00Z', '2099-01-02T16:00:00.000000Z'), 24);
  assert.equal(hoursBefore('2099-01-02T14:00:00Z', '2099-01-02T16:00:00Z'), 2);
});

test('payload scan finds a venue or name anywhere in the value', () => {
  assert.equal(containsNone({ a: [{ b: 'Cell meeting changed' }] }, ['SYNTHETIC 12 Shikoswe Road']), true);
  assert.equal(containsNone({ a: [{ b: 'at SYNTHETIC 12 Shikoswe Road' }] }, ['SYNTHETIC 12 Shikoswe Road']), false);
  assert.equal(containsNone(undefined, ['x']), true);
});
