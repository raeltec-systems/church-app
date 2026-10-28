import assert from 'node:assert/strict';
import { test } from 'node:test';

import { ESTATES, SHIKOSWE, isFictionalAbsencePhone } from './cells-absence.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900050', '+447700900059']) assert.equal(isFictionalAbsencePhone(p), true);
  for (const p of ['+447700900049', '+447700900060', '+12025550150', '447700900050']) {
    assert.equal(isFictionalAbsencePhone(p), false);
  }
});

test('the cells are synthetic', () => {
  assert.match(SHIKOSWE, /^SYNTHETIC /);
  assert.match(ESTATES, /^SYNTHETIC /);
});
