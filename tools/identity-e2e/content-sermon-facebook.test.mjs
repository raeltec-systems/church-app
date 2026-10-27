import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  ACCEPTED_LINKS, NOTES, REFUSED_LINKS, SYNTHETIC_PHONES, isFictionalFacebookPhone, sermonInput,
} from './content-sermon-facebook.mjs';
import { PUBLIC_SERMON_KEYS } from './content-sermons.mjs';

test('only this run accepts its four reserved fictional UK phones', () => {
  assert.equal(new Set(SYNTHETIC_PHONES).size, 4);
  for (const phone of SYNTHETIC_PHONES) {
    assert.match(phone, /^\+44770090011[5-8]$/);
    assert.equal(isFictionalFacebookPhone(phone), true);
  }
  for (const phone of ['+447700900114', '+447700900119', '+447700900651', '447700900115', null]) {
    assert.equal(isFictionalFacebookPhone(phone), false);
  }
});

test('fixture input is synthetic and carries one video source at most', () => {
  const input = sermonInput();
  assert.match(input.title, /^SYNTHETIC /);
  assert.match(input.speaker, /^SYNTHETIC /);
  assert.match(input.notes, /^# SYNTHETIC /);
  assert.equal(input.youtube_video_id, null);
  assert.equal(input.facebook_video_url, null);
  assert.equal(NOTES, input.notes);
});

test('every accepted link normalises to the stored https://www.facebook.com or fb.watch form', () => {
  assert.equal(ACCEPTED_LINKS.length, 4);
  for (const [, normal] of ACCEPTED_LINKS) {
    assert.match(normal, /^https:\/\/(www\.facebook\.com\/([A-Za-z0-9][A-Za-z0-9.-]*\/videos\/\d+\/|watch\/\?v=\d+)|fb\.watch\/[A-Za-z0-9_-]+\/)$/);
  }
  assert.equal(ACCEPTED_LINKS.some(([link]) => link.includes('/watch/live/')), true, 'covers a live link');
  assert.equal(ACCEPTED_LINKS.some(([link]) => link.startsWith('https://fb.watch/')), true, 'covers fb.watch');
});

test('the refused corpus covers other hosts, malformed links and the page live address', () => {
  assert.equal(new Set(REFUSED_LINKS.map(([link]) => link)).size, REFUSED_LINKS.length);
  const reasons = new Set(REFUSED_LINKS.map(([, reason]) => reason));
  assert.deepEqual([...reasons].sort(), ['invalid', 'not_embeddable', 'not_facebook']);
  for (const token of ['youtube.com', 'evil.example', 'http:', 'user@', ':8443', 'javascript:', '/live/', '/share/']) {
    assert.equal(REFUSED_LINKS.some(([link]) => link.includes(token)), true, token);
  }
});

test('the public sermon projection names the Facebook link', () => {
  assert.equal(PUBLIC_SERMON_KEYS.includes('facebook_video_url'), true);
  assert.deepEqual(PUBLIC_SERMON_KEYS, [...PUBLIC_SERMON_KEYS].sort());
});
