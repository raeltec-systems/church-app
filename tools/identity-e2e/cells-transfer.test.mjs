import assert from 'node:assert/strict';
import { test } from 'node:test';

import { ESTATES, SHIKOSWE, isFictionalTransferPhone } from './cells-transfer.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900070', '+447700900079']) assert.equal(isFictionalTransferPhone(p), true);
  for (const p of ['+447700900069', '+447700900080', '+12025550170', '447700900070']) {
    assert.equal(isFictionalTransferPhone(p), false);
  }
});

test('the cells are synthetic', () => {
  assert.match(SHIKOSWE, /^SYNTHETIC /);
  assert.match(ESTATES, /^SYNTHETIC /);
});
