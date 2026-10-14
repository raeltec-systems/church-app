import assert from 'node:assert/strict';
import { test } from 'node:test';

import { isFictionalScreensPhone, isGenericSignal } from './inbox-screens.mjs';

const own = 'account:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const frame = (inner = {}, topic = `realtime:${own}`) => ({
  ref: null, event: 'broadcast', topic,
  payload: { event: 'inbox_changed', type: 'broadcast', meta: { id: '18a9f7ec-f6d6-487c-a74c-51725353aa91' }, payload: {}, ...inner },
});

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900930', '+447700900939']) assert.equal(isFictionalScreensPhone(p), true);
  for (const p of ['+447700900929', '+447700900940', '447700900930']) assert.equal(isFictionalScreensPhone(p), false);
});

test('a signal is generic only as an empty inbox_changed broadcast on the own topic', () => {
  assert.equal(isGenericSignal(frame(), ['item-1'], own), true);
  assert.equal(isGenericSignal(frame({ meta: undefined }), [], own), true);
  assert.equal(isGenericSignal(frame({ payload: { item_id: 'item-1' } }), [], own), false);
  assert.equal(isGenericSignal(frame({ payload: { kind: 'fixture_due' } }), [], own), false);
  assert.equal(isGenericSignal(frame({ payload: [] }), [], own), false);
  assert.equal(isGenericSignal(frame({ event: 'item_changed' }), [], own), false);
  assert.equal(isGenericSignal(frame({ meta: { id: 'x', source: 'fixture_reminder' } }), [], own), false);
  assert.equal(isGenericSignal(frame({ extra: 'x' }), [], own), false);
  assert.equal(isGenericSignal(frame({}, 'realtime:account:someone-else'), [], own), false);
  assert.equal(isGenericSignal({ ...frame(), event: 'presence_state' }, [], own), false);
  assert.equal(isGenericSignal(null, [], own), false);
});

test('a private value anywhere but the own topic fails the check', () => {
  assert.equal(isGenericSignal(frame(), ['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'], own), true, 'the topic is the subscriber\'s own');
  assert.equal(isGenericSignal(frame({ meta: { id: 'item-1' } }), ['item-1'], own), false);
});
