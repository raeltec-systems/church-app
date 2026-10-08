import assert from 'node:assert/strict';
import { test } from 'node:test';

import { IN_NETWORK_URL, disjoint, isFictionalWorkerPhone, newCredential, tokenOf } from './worker.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900870', '+447700900879']) assert.equal(isFictionalWorkerPhone(p), true);
  for (const p of ['+447700900869', '+447700900880', '447700900870']) assert.equal(isFictionalWorkerPhone(p), false);
});

test('lease tokens are read per job and leases compared for overlap', () => {
  const a = { jobs: [{ job_id: 'j1', lease_token: 3 }, { job_id: 'j2', lease_token: 4 }] };
  const b = { jobs: [{ job_id: 'j3', lease_token: 5 }] };
  assert.equal(tokenOf(a, 'j2'), 4);
  assert.equal(tokenOf(a, 'j3'), null);
  assert.equal(tokenOf(null, 'j1'), null);
  assert.equal(disjoint(a, b), true);
  assert.equal(disjoint(a, { jobs: [{ job_id: 'j1', lease_token: 9 }] }), false);
});

test('credentials are local-environment system credentials and the URL is the worker', () => {
  assert.match(newCredential(), /^sysc_local_[A-Za-z0-9_-]{43}$/);
  assert.notEqual(newCredential(), newCredential());
  assert.match(IN_NETWORK_URL, /^https?:\/\/[A-Za-z0-9._:-]+\/functions\/v1\/notifications-worker$/);
});
