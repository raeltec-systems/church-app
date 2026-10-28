import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  PUBLIC_POSTER_KEYS, PUBLIC_SERIES_KEYS, PUBLIC_SERMON_KEYS, SERIES_TITLES, SERMON_TITLES,
  SUPPORTED_NOTES, SYNTHETIC_PHONES, UNSAFE_NOTES, findSeries, findSermon, isFictionalSermonPhone,
  isPublicCatalog, isPublicSeries, isPublicSermon, leaks, sermonInput, sortedKeys,
} from './content-sermons.mjs';

const series = () => ({ series_id: 'series', title: SERIES_TITLES[0], description: 'SYNTHETIC', alt_text: 'SYNTHETIC',
  poster: null, publication_revision: 1, published_at: '2026-10-25T10:00:00Z', offline_allowed: true });
const sermon = () => ({ sermon_id: 'sermon', title: SERMON_TITLES[0], speaker: 'SYNTHETIC speaker',
  sermon_date: '2026-10-25', scripture_reference: 'Genesis 1:1', notes: SUPPORTED_NOTES, series: series(),
  youtube_video_id: null, facebook_video_url: null, rights_revision: null, publication_revision: 1,
  published_at: '2026-10-25T10:00:00Z', offline_allowed: true });

test('only this run accepts its six reserved fictional UK phones', () => {
  assert.equal(new Set(SYNTHETIC_PHONES).size, 6);
  for (const phone of SYNTHETIC_PHONES) assert.equal(isFictionalSermonPhone(phone), true);
  for (const phone of ['+447700900650', '+447700900657', '+12025550651', '447700900651', null]) {
    assert.equal(isFictionalSermonPhone(phone), false);
  }
});

test('fixture names, speakers and body are synthetic and the video remains optional', () => {
  for (const title of [...SERIES_TITLES, ...SERMON_TITLES]) assert.match(title, /^SYNTHETIC /);
  const input = sermonInput();
  assert.match(input.speaker, /^SYNTHETIC /);
  assert.match(input.notes, /^# SYNTHETIC /);
  assert.equal(input.youtube_video_id, null);
  assert.equal(input.video_rights_id, null);
  assert.equal(input.series_id, null);
  assert.equal(sermonInput({ speaker: null }).speaker, null);
});

test('the exact public projection key sets are sorted', () => {
  for (const keys of [PUBLIC_SERMON_KEYS, PUBLIC_SERIES_KEYS, PUBLIC_POSTER_KEYS]) assert.deepEqual(keys, [...keys].sort());
  assert.deepEqual(sortedKeys({ title: 1, sermon_id: 2 }), ['sermon_id', 'title']);
  assert.deepEqual(sortedKeys(null), []);
});

test('the public catalog guard checks empty and nonempty canonical responses', () => {
  assert.equal(isPublicCatalog({ series: [], sermons: [], truncated: false }), true);
  assert.equal(isPublicCatalog({ series: [series()], sermons: [sermon()], truncated: false }), true);
  for (const value of [null, [], {}, { series: [], sermons: [], truncated: 'false' },
    { series: [], sermons: [], truncated: false, draft: {} }]) assert.equal(isPublicCatalog(value), false);
});

test('a withdrawn series can disappear while its public sermon remains', () => {
  const teaching = { ...sermon(), series: null };
  assert.equal(isPublicSermon(teaching), true);
  assert.equal(isPublicCatalog({ series: [], sermons: [teaching], truncated: false }), true);
  assert.equal(findSeries({ series: [] }, 'series'), undefined);
  assert.equal(findSermon({ sermons: [teaching] }, 'sermon'), teaching);
  assert.equal(findSermon(null, 'sermon'), undefined);
});

test('private or extra fields are caught at each nesting level', () => {
  assert.equal(isPublicSermon({ ...sermon(), saved_by: 'private' }), false);
  assert.equal(isPublicSermon({ ...sermon(), series: { ...series(), source: 'private' } }), false);
  assert.equal(isPublicSeries({ ...series(), poster: { path: 'p', media_type: 'image/png', height: 540, width: 960,
    rights_revision: 1, offline_allowed: true } }), true);
  assert.equal(isPublicSeries({ ...series(), poster: { path: 'p', media_type: 'image/png', height: 540, width: 960,
    rights_revision: 1, offline_allowed: true, asset_id: 'private' } }), false);
  const { notes, ...incomplete } = sermon();
  assert.equal(isPublicSermon(incomplete), false);
});

test('unsafe notes corpus covers HTML, images, unsafe schemes, hosts and unsupported link forms', () => {
  assert.equal(new Set(UNSAFE_NOTES).size, UNSAFE_NOTES.length);
  for (const token of ['<script>', '![image]', 'javascript:', 'http:', 'example.com', 'ebible.org.evil',
    'ebible.org@', 'user@ebible.org', ':443', '[reference][ref]', '<https:', '%65bible', ':8443']) {
    assert.equal(UNSAFE_NOTES.some((notes) => notes.includes(token)), true, token);
  }
  assert.match(SUPPORTED_NOTES, /\*\*faithful\*\*/);
  assert.match(SUPPORTED_NOTES, /https:\/\/ebible\.org\//);
});

test('leak detection returns only present nonempty strings', () => {
  assert.deepEqual(leaks('public saved_by private', ['saved_by', 'account_id', '', null, 4]), ['saved_by']);
});
