import assert from 'node:assert/strict';
import { test } from 'node:test';

import { isFictionalCellsPhone, sameTransaction, singlePrimary } from './cells.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900260', '+447700900264', '+447700900269']) assert.equal(isFictionalCellsPhone(p), true);
  for (const p of ['+447700900259', '+447700900270', '+12025550260', '+4477009002600']) assert.equal(isFictionalCellsPhone(p), false);
});

test('a single primary cell means the read names exactly that cell', () => {
  assert.equal(singlePrimary({ primary: { cell_id: 'y' } }, 'y'), true);
  assert.equal(singlePrimary({ primary: { cell_id: 'x' } }, 'y'), false);
  assert.equal(singlePrimary({ primary: null }, 'y'), false);
  assert.equal(singlePrimary(undefined, 'y'), false);
});

test('a hook call is in the same transaction when its row xmin equals the membership row xmin', () => {
  assert.equal(sameTransaction('812', '812'), true);
  assert.equal(sameTransaction('813', '812'), false);
  assert.equal(sameTransaction('', '812'), false);
  assert.equal(sameTransaction(null, '812'), false);
});
