import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  EDITION, PUBLIC_KEYS, churchThisSunday, isFictionalHymnPhone, savedItems, sortedKeys,
} from './content-hymn-lists.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900641', '+447700900649']) assert.equal(isFictionalHymnPhone(p), true);
  for (const p of ['+447700900640', '+447700900650', '+12025550181', '447700900641']) {
    assert.equal(isFictionalHymnPhone(p), false);
  }
});

test('the run names the built-in edition', () => {
  assert.equal(EDITION, 'bicc-tonga-2012');
});

test('this Sunday is the church-time Sunday (Africa/Lusaka, UTC+2)', () => {
  // Saturday 2099-01-03 21:59 UTC is still Saturday 23:59 in Lusaka: this Sunday is the 4th.
  assert.equal(churchThisSunday(Date.parse('2099-01-03T21:59:00Z')), '2099-01-04');
  // 22:00 UTC is Sunday 00:00 in Lusaka: still the 4th (today).
  assert.equal(churchThisSunday(Date.parse('2099-01-03T22:00:00Z')), '2099-01-04');
  // Sunday 21:59 UTC is 23:59 in Lusaka: still the 4th.
  assert.equal(churchThisSunday(Date.parse('2099-01-04T21:59:00Z')), '2099-01-04');
  // Sunday 22:00 UTC is Monday 00:00 in Lusaka: the coming Sunday, the 11th.
  assert.equal(churchThisSunday(Date.parse('2099-01-04T22:00:00Z')), '2099-01-11');
  // A Wednesday: the coming Sunday.
  assert.equal(churchThisSunday(Date.parse('2099-01-07T10:00:00Z')), '2099-01-11');
});

test('saved items are compared sorted and tolerate a refused read', () => {
  assert.deepEqual(savedItems({ favourites: [{ item: 'hymn-12' }, { item: 'chorus-3' }] }), ['chorus-3', 'hymn-12']);
  assert.deepEqual(savedItems(undefined), []);
  assert.deepEqual(savedItems({ code: 'forbidden' }), []);
});

test('the public projection keys are compared sorted', () => {
  assert.deepEqual(PUBLIC_KEYS, [...PUBLIC_KEYS].sort());
  assert.deepEqual(sortedKeys({ sunday: 1, edition: 2 }), ['edition', 'sunday']);
  assert.deepEqual(sortedKeys(undefined), []);
});
