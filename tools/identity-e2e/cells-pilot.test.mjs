import assert from 'node:assert/strict';
import { test } from 'node:test';

import { ESTATES, SHIKOSWE, isFictionalPilotPhone } from './cells-pilot.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900080', '+447700900089']) assert.equal(isFictionalPilotPhone(p), true);
  for (const p of ['+447700900079', '+447700900090', '+12025550180', '447700900080']) {
    assert.equal(isFictionalPilotPhone(p), false);
  }
});

test('the pilot cells are the synthetic stand-ins', () => {
  assert.match(SHIKOSWE, /^SYNTHETIC Shikoswe Cell /);
  assert.match(ESTATES, /^SYNTHETIC Estates C5\/C7 Cell /);
});
