import assert from 'node:assert/strict';
import { test } from 'node:test';

import { DEPARTMENT, ESTATES, SHIKOSWE, isFictionalRevisionsPhone } from './cells-programme-revisions.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900040', '+447700900049']) assert.equal(isFictionalRevisionsPhone(p), true);
  for (const p of ['+447700900039', '+447700900050', '+12025550140', '447700900040']) {
    assert.equal(isFictionalRevisionsPhone(p), false);
  }
});

test('the cells and the department are synthetic', () => {
  for (const name of [SHIKOSWE, ESTATES, DEPARTMENT]) assert.match(name, /^SYNTHETIC /);
});
