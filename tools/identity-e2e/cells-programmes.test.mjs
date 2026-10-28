import assert from 'node:assert/strict';
import { test } from 'node:test';

import { ESTATES, SHIKOSWE, isFictionalProgrammesPhone, partCodes, partOf } from './cells-programmes.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900010', '+447700900019']) assert.equal(isFictionalProgrammesPhone(p), true);
  for (const p of ['+447700900009', '+447700900020', '+12025550110', '447700900010']) {
    assert.equal(isFictionalProgrammesPhone(p), false);
  }
});

test('the cells are synthetic', () => {
  assert.match(SHIKOSWE, /^SYNTHETIC /);
  assert.match(ESTATES, /^SYNTHETIC /);
});

test('a part carries its id only when it has one', () => {
  assert.deepEqual(partOf('A', '18:00', '18:10'),
    { label: 'A', start_time: '18:00', end_time: '18:10', assignee_member_id: null });
  assert.equal(partOf('A', '18:00', '18:10', 'm', 'p').part_id, 'p');
});

test('part refusals are read per index, other field errors ignored', () => {
  assert.deepEqual(partCodes({ 'parts.1': 'overlap', 'parts.0': 'outside_meeting', topic: 'too_long' }),
    ['0:outside_meeting', '1:overlap']);
  assert.deepEqual(partCodes(undefined), []);
  assert.deepEqual(partCodes({ parts: 'too_many' }), []);
});
