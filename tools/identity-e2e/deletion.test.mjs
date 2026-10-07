import assert from 'node:assert/strict';
import { test } from 'node:test';

import { buildEntry } from '../recovery/journal.mjs';
import { isFictionalDeletionPhone, opaqueEntryProblems } from './deletion.mjs';

const M = '00000000-0000-4000-8000-000000021101';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900620', '+447700900629', '+447700900639']) assert.equal(isFictionalDeletionPhone(p), true);
  for (const p of ['+447700900619', '+447700900640', '+12025550120', '+260970000620']) assert.equal(isFictionalDeletionPhone(p), false);
});

test('a journal entry is opaque: its kind\'s fields only, and no forbidden value', () => {
  const entry = buildEntry(null, { kind: 'deletion_manifest', subject: M, object: { bucket: 'identity-member', object_id: M } });
  assert.deepEqual(opaqueEntryProblems(entry, ['+447700900622', 'SYNTHETIC 2.11 E2E']), []);
  assert.ok(opaqueEntryProblems({ ...entry, display_name: 'x' }).length > 0);
  assert.ok(opaqueEntryProblems(entry, [M]).includes('carries a forbidden value'));
});
