import assert from 'node:assert/strict';
import { test } from 'node:test';

import { ESTATES, SHIKOSWE, isFictionalYoureOnPhone } from './cells-youre-on.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900030', '+447700900039']) assert.equal(isFictionalYoureOnPhone(p), true);
  for (const p of ['+447700900029', '+447700900040', '+12025550130', '447700900030']) {
    assert.equal(isFictionalYoureOnPhone(p), false);
  }
});

test('the cells are synthetic', () => {
  assert.match(SHIKOSWE, /^SYNTHETIC /);
  assert.match(ESTATES, /^SYNTHETIC /);
});
