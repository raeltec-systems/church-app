import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  SEARCH_KEYS, SYNTHETIC_PHONES, WORD, churchInstant, idsOf, isFictionalSearchPhone, isSearchAnswer, leaks,
} from './content-search.mjs';

test('only this run accepts its four reserved fictional UK phones', () => {
  assert.equal(new Set(SYNTHETIC_PHONES).size, 4);
  for (const phone of SYNTHETIC_PHONES) {
    assert.match(phone, /^\+44770090057[5-8]$/);
    assert.equal(isFictionalSearchPhone(phone), true);
  }
  for (const phone of ['+447700900574', '+447700900579', '+447700900115', '447700900575', null]) {
    assert.equal(isFictionalSearchPhone(phone), false);
  }
});

test('the search word is one plain word', () => {
  assert.match(WORD, /^[A-Za-z]{8,}$/);
});

test('a search answer has exactly five keys and lists of at most ten', () => {
  const ok = { query: 'x y', sermons: [], events: [{ event_id: 'e' }], announcements: [], truncated: false };
  assert.equal(isSearchAnswer(ok), true);
  assert.deepEqual(SEARCH_KEYS, [...SEARCH_KEYS].sort());
  assert.equal(isSearchAnswer({ ...ok, extra: 1 }), false);
  assert.equal(isSearchAnswer({ ...ok, events: Array(11).fill({}) }), false);
  assert.equal(isSearchAnswer({ ...ok, truncated: 'no' }), false);
  assert.equal(isSearchAnswer(null), false);
  assert.deepEqual(idsOf(ok, 'events', 'event_id'), ['e']);
  assert.deepEqual(idsOf(undefined, 'events', 'event_id'), []);
});

test('leaks names only what is present', () => {
  assert.deepEqual(leaks('{"title":"SYNTHETIC"}', ['SYNTHETIC', 'saved_by', null]), ['SYNTHETIC']);
});

test('church instants are whole UTC hours two hours behind Lusaka', () => {
  const at = churchInstant(7, 9);
  assert.match(at, /^\d{4}-\d{2}-\d{2}T07:00:00Z$/);
  assert.ok(Date.parse(at) > Date.now());
});
