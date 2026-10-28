import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  CANONICAL_BOOKS, PUBLIC_CHAPTER_KEYS, SYNTHETIC_PHONES, TRANSLATION_CODES,
  isFictionalBiblePhone, nextAvailableChapter, sortedKeys, syntheticVerseRows,
} from './content-bible.mjs';

test('the local fixture uses only its reserved synthetic phone numbers', () => {
  for (const phone of SYNTHETIC_PHONES) assert.equal(isFictionalBiblePhone(phone), true);
  for (const phone of ['+447700900880', '+447700900884', '+12025550161', '447700900881']) {
    assert.equal(isFictionalBiblePhone(phone), false);
  }
});

test('Bible E2E data contains only clearly marked synthetic verses', () => {
  for (const code of TRANSLATION_CODES) {
    const rows = syntheticVerseRows(code, 'GEN', 1, 3);
    assert.deepEqual(rows.map((row) => row.verse), [1, 2, 3]);
    assert.ok(rows.every((row) => row.text.startsWith(`SYNTHETIC ${code} GEN 1 verse `)));
    assert.ok(rows.every((row) => /\(6\.6 E2E\)$/.test(row.text)));
  }
  for (const input of [
    ['NASB', 'GEN', 1, 1],
    ['KJV', 'GEN', 0, 1],
    ['WEB', 'NOPE', 1, 1],
    ['WEB', 'GEN', 1, 201],
  ]) assert.throws(() => syntheticVerseRows(...input), TypeError);
});

test('canonical order includes all 66 Protestant books once', () => {
  assert.equal(CANONICAL_BOOKS.length, 66);
  assert.equal(new Set(CANONICAL_BOOKS).size, 66);
  assert.equal(CANONICAL_BOOKS[0], 'GEN');
  assert.equal(CANONICAL_BOOKS.at(-1), 'REV');
});

test('available chapter navigation sorts canonically without mutating the projection', () => {
  const refs = [
    { book_id: 'EXO', chapter: 1 },
    { book_id: 'GEN', chapter: 2 },
    { book_id: 'GEN', chapter: 1 },
    { book_id: '1JN', chapter: 1 },
    { book_id: '2JN', chapter: 1 },
  ];
  const before = structuredClone(refs);
  assert.deepEqual(nextAvailableChapter(refs, { book_id: 'GEN', chapter: 1 }), { book_id: 'GEN', chapter: 2 });
  assert.deepEqual(nextAvailableChapter(refs, { book_id: 'GEN', chapter: 2 }), { book_id: 'EXO', chapter: 1 });
  assert.deepEqual(nextAvailableChapter(refs, { book_id: '1JN', chapter: 1 }), { book_id: '2JN', chapter: 1 });
  assert.equal(nextAvailableChapter(refs, { book_id: 'GEN', chapter: 1 }, -1), null);
  assert.equal(nextAvailableChapter(refs, { book_id: 'REV', chapter: 1 }), null);
  assert.deepEqual(refs, before);
});

test('the anonymous chapter projection stays explicit and has no private fields', () => {
  assert.deepEqual(PUBLIC_CHAPTER_KEYS, [...PUBLIC_CHAPTER_KEYS].sort());
  assert.deepEqual(sortedKeys(Object.fromEntries(PUBLIC_CHAPTER_KEYS.map((key) => [key, null]))), PUBLIC_CHAPTER_KEYS);
  assert.deepEqual(sortedKeys(undefined), []);
  assert.ok(PUBLIC_CHAPTER_KEYS.includes('offline_allowed'));
  for (const privateField of ['saved_by_member', 'rights_id', 'draft_revision_no', 'audit']) {
    assert.equal(PUBLIC_CHAPTER_KEYS.includes(privateField), false);
  }
});
