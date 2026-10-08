import assert from 'node:assert/strict';
import { test } from 'node:test';

import { isFictionalContractsPhone, isGenericSuperseded } from './source-contracts.mjs';

const generic = {
  item_id: 'i', reminder_kind: 'fixture_due', title: 'T', body: 'B',
  due_at: '2026-10-08T07:00:00.000000Z', delivered_at: '2026-10-08T07:00:01.000000Z',
  state: 'superseded', target: null,
};

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900840', '+447700900849']) assert.equal(isFictionalContractsPhone(p), true);
  for (const p of ['+447700900839', '+447700900850', '447700900840']) assert.equal(isFictionalContractsPhone(p), false);
});

test('a superseded answer is generic only with exactly the generic fields and no source values', () => {
  assert.equal(isGenericSuperseded(generic, ['source-1']), true);
  assert.equal(isGenericSuperseded({ ...generic, state: 'current' }, []), false);
  assert.equal(isGenericSuperseded({ ...generic, target: '/x/source-1' }, []), false);
  assert.equal(isGenericSuperseded({ ...generic, note: 'x' }, []), false);
  assert.equal(isGenericSuperseded({ ...generic, body: 'about source-1' }, ['source-1']), false);
  assert.equal(isGenericSuperseded(null, []), false);
});
