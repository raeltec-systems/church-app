import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  DEPARTMENT, FROM_DUTY_KEYS, OTHER_DEPARTMENT, SCRIPTURE, STATUS_KEYS, TOPIC, done, isFictionalDraftsPhone, namesSender, refused,
} from './content-sermon-duty-drafts.mjs';

test('only the reserved fictional block +44 7700 900116-900121 is used', () => {
  for (const p of ['+447700900116', '+447700900119', '+447700900121']) assert.equal(isFictionalDraftsPhone(p), true);
  for (const p of ['+447700900115', '+447700900122', '+447700900111', '447700900116', '+12025550116']) {
    assert.equal(isFictionalDraftsPhone(p), false);
  }
});

test('names are SYNTHETIC and the reads carry no person', () => {
  for (const t of [DEPARTMENT, OTHER_DEPARTMENT, TOPIC, SCRIPTURE]) assert.match(t, /^SYNTHETIC /);
  assert.equal(DEPARTMENT, 'SYNTHETIC Preaching Rota');
  assert.deepEqual([...STATUS_KEYS].sort(), STATUS_KEYS);
  assert.deepEqual([...FROM_DUTY_KEYS].sort(), FROM_DUTY_KEYS);
  assert.ok(![...STATUS_KEYS, ...FROM_DUTY_KEYS].some((k) => /member|sent_by|account|speaker/.test(k)));
});

test('a sender anywhere is caught', () => {
  assert.equal(namesSender({ duty_name: 'x', sent_at: 'y' }), false);
  assert.equal(namesSender({ duty_name: 'x', sent_by: 'y' }), true);
  assert.equal(namesSender([{ a: [{ member_id: 1 }] }]), true);
  assert.equal(namesSender(null), false);
});

test('answers and refusals', () => {
  assert.equal(done({ status: 200, data: {} }), true);
  assert.equal(done({ status: 200, code: 'not_found' }), false);
  const r = { code: 'validation_failed', field_errors: { occurrence_id: 'no_topic' } };
  assert.equal(refused(r, 'validation_failed', 'occurrence_id', 'no_topic'), true);
  assert.equal(refused(r, 'validation_failed', 'occurrence_id', 'other'), false);
  assert.equal(refused({ code: 'not_found' }, 'not_found'), true);
});
