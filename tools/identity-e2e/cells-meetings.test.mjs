import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  ESTATES, SHIKOSWE, churchClock, isFictionalMeetingsPhone, meetingIds, sameIds, weekdayInTwoDays,
} from './cells-meetings.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900200', '+447700900209']) assert.equal(isFictionalMeetingsPhone(p), true);
  for (const p of ['+447700900199', '+447700900210', '+12025550200', '447700900200']) {
    assert.equal(isFictionalMeetingsPhone(p), false);
  }
});

test('the cells are synthetic', () => {
  assert.match(SHIKOSWE, /^SYNTHETIC /);
  assert.match(ESTATES, /^SYNTHETIC /);
});

test('meeting ids are read per cell and compared by occurrence date', () => {
  const board = { cells: [
    { cell_id: 'S', meetings: [{ occurrence_date: '2099-01-02', meeting_id: 'a' }, { occurrence_date: '2099-01-09', meeting_id: 'b' }] },
    { cell_id: 'E', meetings: [{ occurrence_date: '2099-01-02', meeting_id: 'x' }] },
  ] };
  const ids = meetingIds(board, 'S');
  assert.deepEqual(ids, { '2099-01-02': 'a', '2099-01-09': 'b' });
  assert.equal(sameIds(ids, { ...ids, '2099-01-16': 'c' }), true);
  assert.equal(sameIds(ids, { '2099-01-02': 'a', '2099-01-09': 'z' }), false);
  assert.equal(sameIds({}, {}), false, 'an empty board proves nothing');
  assert.deepEqual(meetingIds(undefined, 'S'), {});
});

test('the first meeting falls two church days ahead (ISO weekday, Monday = 1)', () => {
  // Saturday 2099-01-03 23:30 UTC is Sunday 01:30 in Lusaka; two days on is Tuesday.
  assert.equal(weekdayInTwoDays(Date.parse('2099-01-03T23:30:00Z')), 2);
  // Thursday 2099-01-08 10:00 UTC: two days on is Saturday.
  assert.equal(weekdayInTwoDays(Date.parse('2099-01-08T10:00:00Z')), 6);
  // Friday 2099-01-02 10:00 UTC: two days on is Sunday.
  assert.equal(weekdayInTwoDays(Date.parse('2099-01-02T10:00:00Z')), 7);
});

test('church clock reads Lusaka time', () => {
  assert.equal(churchClock('2099-01-02T16:00:00.000000Z'), '18:00');
});
