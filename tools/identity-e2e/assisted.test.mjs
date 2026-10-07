import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { test } from 'node:test';

import { digestOf, findLeaks, isFictionalAssistedPhone, newGrantSecret } from './assisted.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900430', '+447700900441', '+447700900449']) assert.equal(isFictionalAssistedPhone(p), true);
  for (const p of ['+447700900429', '+447700900450', '+12025550143', '+260970000430']) assert.equal(isFictionalAssistedPhone(p), false);
});

test('a grant secret has the device format and its digest is sha256 hex', () => {
  const s = newGrantSecret();
  assert.match(s, /^arg_[A-Za-z0-9_-]{43}$/);
  assert.equal(digestOf(s), createHash('sha256').update(s, 'utf8').digest('hex'));
  assert.notEqual(newGrantSecret(), s);
});

test('the leak scan finds secrets and ignores short values', () => {
  const s = newGrantSecret();
  assert.deepEqual(findLeaks(`log ${s} end`, [s, 'abc']), [s]);
  assert.deepEqual(findLeaks('clean', [s]), []);
});
