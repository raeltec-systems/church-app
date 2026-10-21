import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  DEPARTMENT, ESTATES, SHIKOSWE, isFictionalPublishPhone, leaksPrivate, partStates, withoutPublication,
} from './cells-programme-publish.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900020', '+447700900029']) assert.equal(isFictionalPublishPhone(p), true);
  for (const p of ['+447700900019', '+447700900030', '+12025550120', '447700900020']) {
    assert.equal(isFictionalPublishPhone(p), false);
  }
});

test('the cells and the department are synthetic', () => {
  for (const name of [SHIKOSWE, ESTATES, DEPARTMENT]) assert.match(name, /^SYNTHETIC /);
});

test('a member read leaking a private field is caught', () => {
  assert.equal(leaksPrivate({ programme: { parts: [{ label: 'A', leader: 'B' }] } }), false);
  assert.equal(leaksPrivate({ programme: { study_notes: 'x' } }), true);
  assert.equal(leaksPrivate({ parts: [{ response: 'pending' }] }), true);
  assert.equal(leaksPrivate(undefined), false);
});

test('the published copy compares to the preview without its publication fields', () => {
  assert.deepEqual(withoutPublication({ topic: 'T', parts: [], revision: 3, published_at: 'x', meeting_changed: false }), { topic: 'T', parts: [] });
  assert.equal(withoutPublication(null), null);
});

test('part states read the owned position, the link, or open', () => {
  assert.deepEqual(partStates({ duties: [
    { positions: [{ kind: 'owned', position_key: 'lead', assignment: { response: 'pending' } }] },
    { positions: [{ kind: 'owned', position_key: 'lead', assignment: null }] },
    { positions: [{ kind: 'linked', position_key: 'department' }] },
  ] }), ['pending', 'open', 'linked']);
  assert.deepEqual(partStates(undefined), []);
});
