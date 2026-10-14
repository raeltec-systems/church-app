import assert from 'node:assert/strict';
import { test } from 'node:test';

import { DEPARTMENT, dutyLink, firstAssignment, isFictionalDutiesPhone, refusedTableQuery } from './duties.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900960', '+447700900969']) assert.equal(isFictionalDutiesPhone(p), true);
  for (const p of ['+447700900959', '+447700900970', '+12025550960', '447700900960']) assert.equal(isFictionalDutiesPhone(p), false);
});

test('the department is the synthetic stand-in', () => {
  assert.match(DEPARTMENT, /^SYNTHETIC /);
});

test('the deep link matches the reminder contract', () => {
  assert.equal(dutyLink('42424242-4242-4242-8242-424242424242'), '/duties/assignments/42424242-4242-4242-8242-424242424242');
});

test('the first assignment is read defensively', () => {
  assert.equal(firstAssignment(null), null);
  assert.equal(firstAssignment({ positions: [] }), null);
  assert.deepEqual(firstAssignment({ positions: [{ assignment: { response: 'pending' } }] }), { response: 'pending' });
});

test('a refused table query is an error status without rows', () => {
  assert.equal(refusedTableQuery({ status: 406, json: { code: 'PGRST106' } }), true);
  assert.equal(refusedTableQuery({ status: 200, json: [] }), false);
  assert.equal(refusedTableQuery({ status: 404, json: [] }), false);
});
