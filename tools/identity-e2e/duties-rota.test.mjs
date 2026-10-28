import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  DEPARTMENT, churchClock, churchInstant, churchSunday, isFictionalRotaPhone, oneWinner, seriesOccurrences,
} from './duties-rota.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900740', '+447700900749']) assert.equal(isFictionalRotaPhone(p), true);
  for (const p of ['+447700900739', '+447700900750', '+12025550740', '447700900740']) assert.equal(isFictionalRotaPhone(p), false);
});

test('the department is synthetic', () => {
  assert.match(DEPARTMENT, /^SYNTHETIC /);
});

test('church Sundays are church-local dates at least four days ahead', () => {
  // Saturday 2099-01-03 23:30 UTC is already Sunday 01:30 in Lusaka; +4 days is Thursday the 8th.
  const now = Date.parse('2099-01-03T23:30:00Z');
  assert.equal(churchSunday(now, 0), '2099-01-11');
  assert.equal(churchSunday(now, 1), '2099-01-18');
  // A Wednesday in church time: +4 days is the Sunday itself.
  assert.equal(churchSunday(Date.parse('2099-01-07T10:00:00Z'), 0), '2099-01-11');
});

test('church time converts across the UTC date boundary', () => {
  assert.equal(churchInstant('2099-01-04', '00:30'), '2099-01-03T22:30:00.000Z');
  assert.equal(churchClock('2099-01-03T22:30:00.000Z'), '00:30');
});

test('exactly one winner among concurrent commands', () => {
  assert.equal(oneWinner([{ status: 200 }, { status: 200, code: 'conflict' }]), true);
  assert.equal(oneWinner([{ status: 200 }, { status: 200 }]), false);
  assert.equal(oneWinner([{ status: 200, code: 'conflict' }, { status: 200, code: 'conflict' }]), false);
});

test('series occurrences are read defensively', () => {
  assert.deepEqual(seriesOccurrences(null, 'x'), []);
  assert.deepEqual(seriesOccurrences({ departments: [{ series: [{ series_id: 'x', occurrences: [1] }] }] }, 'x'), [1]);
});
