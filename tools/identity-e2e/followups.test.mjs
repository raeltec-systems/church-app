import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  DEPARTMENT, PRIVATE_KEYS, PURPOSE, SOURCE_TYPE, findTask, hasPrivateKey, isFictionalFollowupsPhone, refusedTableQuery,
} from './followups.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900220', '+447700900229']) assert.equal(isFictionalFollowupsPhone(p), true);
  for (const p of ['+447700900219', '+447700900230', '+12025550220', '447700900220']) assert.equal(isFictionalFollowupsPhone(p), false);
});

test('the department and the source are the synthetic stand-ins', () => {
  assert.match(DEPARTMENT, /^SYNTHETIC /);
  assert.equal(SOURCE_TYPE, 'fixture_followup');
  assert.equal(PURPOSE, 'synthetic_check_in');
});

test('a routing task with any private key is flagged', () => {
  assert.equal(hasPrivateKey({ task_id: 't', state: 'open', due_at: 'x', owner: {} }), false);
  for (const k of PRIVATE_KEYS) assert.equal(hasPrivateKey({ task_id: 't', [k]: null }), true);
  assert.equal(hasPrivateKey(null), false);
});

test('a task is found by id, defensively', () => {
  assert.equal(findTask(null, 'a'), null);
  assert.deepEqual(findTask([{ task_id: 'a', state: 'open' }], 'a'), { task_id: 'a', state: 'open' });
  assert.equal(findTask([{ task_id: 'b' }], 'a'), null);
});

test('a refused table query is an error status without rows', () => {
  assert.equal(refusedTableQuery({ status: 406, json: { code: 'PGRST106' } }), true);
  assert.equal(refusedTableQuery({ status: 200, json: [] }), false);
  assert.equal(refusedTableQuery({ status: 404, json: [] }), false);
});
