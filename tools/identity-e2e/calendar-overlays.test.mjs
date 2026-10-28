import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  DEPARTMENT, ESTATES, SHIKOSWE, WINDOW_DAYS, isFictionalOverlayPhone, meetingKeys, onlyOwnMeetings, weekdayInTwoDays,
} from './calendar-overlays.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900941', '+447700900949']) assert.equal(isFictionalOverlayPhone(p), true);
  for (const p of ['+447700900940', '+447700900950', '+12025550941', '447700900941']) {
    assert.equal(isFictionalOverlayPhone(p), false);
  }
});

test('everything it creates is synthetic', () => {
  for (const name of [SHIKOSWE, ESTATES, DEPARTMENT]) assert.match(name, /^SYNTHETIC /);
  assert.equal(WINDOW_DAYS, 31);
});

test('the first meeting weekday is two church days ahead', () => {
  // Monday 2099-01-05 10:00 UTC (12:00 church time): Wednesday.
  assert.equal(weekdayInTwoDays(Date.parse('2099-01-05T10:00:00Z')), 3);
  // Saturday 2099-01-10 23:00 UTC (Sunday 01:00 church time): Tuesday.
  assert.equal(weekdayInTwoDays(Date.parse('2099-01-10T23:00:00Z')), 2);
});

test('only own meetings inside the window pass', () => {
  const now = Date.parse('2099-01-01T00:00:00Z');
  const until = now + 31 * 86_400_000;
  const m = (id, startDay) => ({
    meeting_id: id,
    starts_at: new Date(now + startDay * 86_400_000).toISOString(),
    ends_at: new Date(now + startDay * 86_400_000 + 3_600_000).toISOString(),
  });
  assert.equal(onlyOwnMeetings({ meetings: [m('a', 2), m('b', 9)] }, ['a', 'b'], ['x'], now, until), true);
  assert.equal(onlyOwnMeetings({ meetings: [m('a', 2), m('x', 9)] }, ['a', 'b', 'x'], ['x'], now, until), false,
    'another cell\'s meeting fails');
  assert.equal(onlyOwnMeetings({ meetings: [m('a', 40)] }, ['a'], [], now, until), false, 'outside the window fails');
  assert.equal(onlyOwnMeetings({ meetings: [m('a', -1)] }, ['a'], [], now, until), false, 'an ended meeting fails');
  assert.equal(onlyOwnMeetings({ meetings: [] }, ['a'], [], now, until), false, 'an empty answer proves nothing');
  assert.equal(onlyOwnMeetings(undefined, ['a'], [], now, until), false);
});

test('meeting keys are collected across meetings', () => {
  assert.equal(meetingKeys({ meetings: [{ b: 1, a: 2 }, { c: 3 }] }), 'a,b,c');
  assert.equal(meetingKeys(null), '');
});
