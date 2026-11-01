import assert from 'node:assert/strict';
import { test } from 'node:test';
import { commandDone, samePrivateDraft, uuid, waiterQuery } from './content-sermon-duty-lock.mjs';
test('strict fixture UUIDs and numeric holder PIDs prevent SQL fragments', () => {
  assert.equal(uuid('00000000-0000-0000-0000-000000000001'), '00000000-0000-0000-0000-000000000001');
  for (const value of [undefined, "x'; select 1", '', '0000']) assert.throws(() => uuid(value));
  for (const pid of [0, -1, 1.1, '123', '1; select 1']) assert.throws(() => waiterQuery(pid));
  assert.match(waiterQuery(123), /held.pid = 123/);
  assert.match(waiterQuery(123), /not waiting.granted/);
  assert.match(waiterQuery(123), /a.wait_event = 'advisory'/);
});
test('a successful HTTP status is not enough for a command', () => {
  assert.equal(commandDone({ status: 200 }), true);
  assert.equal(commandDone({ status: 200, code: 'conflict' }), false);
  assert.equal(commandDone({ status: 403 }), false);
});
test('concurrency requires one created and one existing response for the same draft', () => {
  const a = { status: 200, data: { sermon_id: 'one', created: true } };
  const b = { status: 200, data: { sermon_id: 'one', created: false } };
  assert.equal(samePrivateDraft([a, b]), true);
  for (const answers of [[], [a], [a, a], [b, b], [a, { ...b, code: 'not_found' }],
    [a, { status: 200, data: { sermon_id: 'different', created: false } }]]) {
    assert.equal(samePrivateDraft(answers), false);
  }
});
