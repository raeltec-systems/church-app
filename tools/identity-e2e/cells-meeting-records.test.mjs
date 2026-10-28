import assert from 'node:assert/strict';
import { test } from 'node:test';

import { ESTATES, SHIKOSWE, isFictionalRecordsPhone, shiftSql } from './cells-meeting-records.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900060', '+447700900069']) assert.equal(isFictionalRecordsPhone(p), true);
  for (const p of ['+447700900059', '+447700900070', '+12025550160', '447700900060']) {
    assert.equal(isFictionalRecordsPhone(p), false);
  }
});

test('the cells are synthetic', () => {
  assert.match(SHIKOSWE, /^SYNTHETIC /);
  assert.match(ESTATES, /^SYNTHETIC /);
});

test('a shift takes a meeting id and whole days only', () => {
  assert.match(shiftSql('82828282-8282-4282-8282-828282828282', 3), /interval '3 days'/);
  assert.throws(() => shiftSql("x'; drop table y; --", 3));
  assert.throws(() => shiftSql('82828282-8282-4282-8282-828282828282', 1.5));
});
