import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  beginOutcome,
  classifyDeleteResult,
  completeOutcome,
  credentialFrom,
  declaredTooLarge,
  keyHeaders,
  parseBody,
  systemEnvelope,
} from './logic.mjs';

const ID = '00000000-0000-4000-8000-000000021101';

test('only {action: auth_delete, deletion_id} is accepted', () => {
  assert.deepEqual(parseBody({ action: 'auth_delete', deletion_id: ID }), { ok: true, value: { action: 'auth_delete', deletion_id: ID } });
  assert.equal(parseBody(null).error, 'invalid_body');
  assert.equal(parseBody([]).error, 'invalid_body');
  assert.equal(parseBody({ action: 'delete', deletion_id: ID }).error, 'invalid_action');
  assert.equal(parseBody({ action: 'auth_delete', deletion_id: ID, auth_user_id: ID }).error, 'unknown_field');
  assert.equal(parseBody({ action: 'auth_delete', deletion_id: '0000000A-0000-4000-8000-00000002110F' }).error, 'invalid_deletion_id');
  assert.equal(parseBody({ action: 'auth_delete' }).error, 'invalid_deletion_id');
});

test('the caller must present a well-formed system credential', () => {
  const ok = `sysc_local_${'A'.repeat(43)}`;
  assert.equal(credentialFrom(ok), ok);
  assert.equal(credentialFrom(`sysc_staging_${'b'.repeat(43)}`), `sysc_staging_${'b'.repeat(43)}`);
  for (const bad of [null, '', 'sysc_local_short', `sysc_dev_${'A'.repeat(43)}`, `Bearer ${ok}`, `${ok}x`]) {
    assert.equal(credentialFrom(bad), null);
  }
});

test('Auth Admin answers become claims; the database decides', () => {
  assert.equal(classifyDeleteResult(200), 'deleted');
  assert.equal(classifyDeleteResult(204), 'deleted');
  assert.equal(classifyDeleteResult(404), 'absent');
  assert.equal(classifyDeleteResult(400), 'rejected');
  assert.equal(classifyDeleteResult(422), 'rejected');
  for (const s of [408, 429, 500, 503, null, undefined]) assert.equal(classifyDeleteResult(s), 'unknown');
});

test('the fence answer never passes an account id on', () => {
  assert.equal(beginOutcome({ proceed: true, auth_user_id: ID }), 'proceed');
  assert.equal(beginOutcome({ proceed: true, auth_user_id: 'not-a-uuid' }), 'refused');
  assert.equal(beginOutcome({ proceed: false, reason: 'policy_gate_closed' }), 'policy_gate_closed');
  assert.equal(beginOutcome({ proceed: false, reason: 'Bad Reason' }), 'refused');
  assert.equal(beginOutcome(null), 'refused');
  assert.equal(completeOutcome({ outcome: 'done' }), 'done');
  assert.equal(completeOutcome({ outcome: 'anything' }), 'retry');
});

test('bodies, keys and envelopes', () => {
  assert.equal(declaredTooLarge(null), false);
  assert.equal(declaredTooLarge('512'), false);
  assert.equal(declaredTooLarge('4096'), true);
  assert.equal(declaredTooLarge('1e3'), true);
  assert.deepEqual(keyHeaders('sb_publishable_x'), { apikey: 'sb_publishable_x' });
  assert.deepEqual(keyHeaders('eyJabc'), { apikey: 'eyJabc', authorization: 'Bearer eyJabc' });
  assert.deepEqual(systemEnvelope('identity.deletion_auth_begin', { deletion_id: ID }, 'r'),
    { version: 1, command: 'identity.deletion_auth_begin', request_id: 'r', payload: { deletion_id: ID } });
});
