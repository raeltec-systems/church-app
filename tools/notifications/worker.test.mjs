import assert from 'node:assert/strict';
import { test } from 'node:test';

import { countsOf, parseArgs, readCredential, runOnce } from './worker.mjs';

const CRED = `sysc_local_${'A'.repeat(43)}`;

test('arguments: run-once with an optional bounded limit only', () => {
  assert.deepEqual(parseArgs(['run-once']), { limit: undefined, evidence: undefined });
  assert.deepEqual(parseArgs(['run-once', '--limit', '20', '--evidence', 'x.jsonl']), { limit: 20, evidence: 'x.jsonl' });
  for (const bad of [[], ['run'], ['run-once', '--limit', '0'], ['run-once', '--limit', '101'],
    ['run-once', '--limit', '1.5'], ['run-once', '--limit'], ['run-once', '--member', 'x']]) {
    assert.throws(() => parseArgs(bad));
  }
});

test('the credential comes from the environment or its file and is never echoed when malformed', () => {
  assert.equal(readCredential({ NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL: ` ${CRED}\n` }), CRED);
  assert.equal(readCredential({ NOTIFICATIONS_WORKER_CREDENTIAL_FILE: '/x' }, () => `${CRED}\n`), CRED);
  const leaked = 'sysc_local_short-secret';
  assert.throws(() => readCredential({ NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL: leaked }),
    (e) => !e.message.includes(leaked));
  assert.throws(() => readCredential({}));
});

test('only the counts of the answer are kept', () => {
  const data = { actor: { kind: 'system', system_principal_id: 'p' }, claimed: 2, delivered: 1, obsolete: 1,
    ineligible: 0, failed: 0, member_id: 'm' };
  assert.deepEqual(countsOf(data), { claimed: 2, delivered: 1, obsolete: 1, ineligible: 0, failed: 0 });
  assert.throws(() => countsOf({ claimed: 1 }));
  assert.throws(() => countsOf({ ...data, failed: -1 }));
});

test('one step over the system route with the worker credential', async () => {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    return { ok: true, status: 200, json: async () => ({ request_id: 'r', data: { actor: {}, claimed: 1, delivered: 1, obsolete: 0, ineligible: 0, failed: 0 }, revision: null }) };
  };
  const r = await runOnce({ url: 'http://127.0.0.1:54321/', publishableKey: 'pk', credential: CRED, limit: 5, fetchImpl, requestId: 'rid' });
  assert.deepEqual(r, { request_id: 'rid', claimed: 1, delivered: 1, obsolete: 0, ineligible: 0, failed: 0 });
  assert.equal(calls[0].url, 'http://127.0.0.1:54321/rest/v1/rpc/system_command');
  assert.equal(calls[0].init.headers['x-system-credential'], CRED);
  assert.equal(calls[0].init.headers['content-profile'], 'api');
  assert.equal(calls[0].init.headers.authorization, undefined);
  assert.deepEqual(JSON.parse(calls[0].init.body), { version: 1, command: 'notifications.deliver_due', request_id: 'rid', payload: { limit: 5 } });
});

test('a refusal throws with the route code only', async () => {
  const fetchImpl = async () => ({ ok: true, status: 200, json: async () => ({ code: 'forbidden', message: 'x' }) });
  await assert.rejects(runOnce({ url: 'http://h', publishableKey: 'pk', credential: CRED, fetchImpl }),
    /refused notifications\.deliver_due: forbidden/);
  await assert.rejects(runOnce({ url: 'http://h', publishableKey: 'pk', credential: 'bad', fetchImpl }));
});
