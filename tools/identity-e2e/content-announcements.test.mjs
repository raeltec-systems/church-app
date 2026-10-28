import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  BODY_MARK, NOTICE_BODY, NOTICE_TITLE, PINNED, PUBLIC_KEYS, UNPINNED, isFictionalAnnouncementPhone, leaks,
  sortedKeys, syntheticDeviceToken, titlesOf,
} from './content-announcements.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900681', '+447700900689']) assert.equal(isFictionalAnnouncementPhone(p), true);
  for (const p of ['+447700900680', '+447700900690', '+447700900100', '+12025550681', '447700900681']) {
    assert.equal(isFictionalAnnouncementPhone(p), false);
  }
});

test('the announcements are synthetic', () => {
  for (const t of [PINNED, UNPINNED, BODY_MARK]) assert.match(t, /^SYNTHETIC/);
});

test('the notice text is the generic contract text, without the announcement', () => {
  assert.equal(NOTICE_TITLE, 'Church announcement');
  assert.doesNotMatch(NOTICE_BODY, /SYNTHETIC|Choir|Harvest/);
});

test('the public projection keys are compared sorted', () => {
  assert.deepEqual(PUBLIC_KEYS, [...PUBLIC_KEYS].sort());
  assert.deepEqual(sortedKeys({ title: 1, announcement_id: 2 }), ['announcement_id', 'title']);
  assert.deepEqual(sortedKeys(undefined), []);
});

test('titles come in the order of the read', () => {
  assert.deepEqual(titlesOf({ announcements: [{ title: 'a' }, { title: 'b' }] }), ['a', 'b']);
  assert.deepEqual(titlesOf(null), []);
});

test('leaks names only the values found', () => {
  assert.deepEqual(leaks('one two', ['two', 'three', '', null]), ['two']);
});

test('device tokens are synthetic and distinct', () => {
  const a = syntheticDeviceToken();
  assert.match(a, /^synthetic-[A-Za-z0-9_-]+:APA91b$/);
  assert.notEqual(a, syntheticDeviceToken());
});
