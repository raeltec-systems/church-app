// Story 3.6: the push stage of the worker run, with the system route and the sender injected.
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { deviceResult, expirePush, parsePrepare, parsePushClaim, runPush } from './logic.mjs';

const ID = (n) => `00000000-0000-4000-8000-0000000360${String(n).padStart(2, '0')}`;
const TOKEN = (c) => `fcm-${c.repeat(40)}:APA91b`;
const MESSAGE = { notification_id: ID(90), item_id: ID(90), title: 'SYNTHETIC test reminder',
  body: 'A test reminder is waiting for you.', ttl_seconds: 600, expires_at_epoch: 1791000000 };
const send = (targets) => ({ outcome: 'send', message: MESSAGE, targets });
const claimOf = (jobs, extra = {}) => ({ jobs, claimed: jobs.length, reclaimed: 0, expired: 0, lease_seconds: 120,
  push_enabled: true, ...extra });
const job = (n) => ({ push_job_id: ID(n), lease_token: n });
const target = (n, c) => ({ device_id: ID(n), platform: 'android', token: TOKEN(c) });

function fakeSystem(answers) {
  const calls = [];
  const system = async (command, payload) => {
    calls.push({ command, payload });
    const a = answers[command];
    const v = typeof a === 'function' ? a(payload, calls) : a;
    if (v instanceof Error) throw v;
    return v;
  };
  return { calls, system };
}

test('claim and prepare answers are checked strictly; nothing malformed is sent', () => {
  assert.deepEqual(parsePushClaim(claimOf([job(1)])).jobs, [job(1)]);
  assert.equal(parsePushClaim({ ...claimOf([job(1)]), claimed: 2 }), null);
  assert.equal(parsePushClaim({ ...claimOf([]), push_enabled: 'yes' }), null);
  assert.deepEqual(parsePrepare(send([target(1, 'a')])).targets, [target(1, 'a')]);
  assert.equal(parsePrepare({ ...send([target(1, 'a')]), message: { ...MESSAGE, text: 'private body' } }), null,
    'a message with any other field is refused');
  assert.equal(parsePrepare(send([])), null);
  assert.equal(parsePrepare(send([{ ...target(1, 'a'), token: 'short' }])), null);
  assert.equal(parsePrepare(send(Array.from({ length: 11 }, (_, i) => target(i + 1, 'a')))), null);
  assert.deepEqual(deviceResult(target(1, 'a'), { result: 'accepted', provider_status: 200, token: TOKEN('a') }),
    { device_id: ID(1), result: 'accepted', provider_status: 200 }, 'the record never carries the token');
  assert.equal(deviceResult(target(1, 'a'), { result: 'delivered' }).result, 'transient',
    'anything but the four answers is transient, never delivered');
});

test('a run prepares, sends to every target and records per-device answers (counts only)', async () => {
  const { calls, system } = fakeSystem({
    'notifications.push_claim': claimOf([job(1), job(2), job(3)]),
    'notifications.push_prepare': (p) => (p.push_job_id === ID(1) ? send([target(11, 'a'), target(12, 'b')])
      : p.push_job_id === ID(2) ? { outcome: 'obsolete', finish_reason: 'push_disabled' } : send([target(13, 'c')])),
    'notifications.push_record': (p) => ({ outcome: p.results.some((r) => r.result === 'transient') ? 'retry' : 'accepted' }),
  });
  const sent = [];
  const sender = { send: async (t, m) => { sent.push([t.token, m.notification_id]);
    return t.token === TOKEN('b') ? { result: 'token_invalid', provider_status: 404, provider_code: 'UNREGISTERED', stop: false }
      : t.token === TOKEN('c') ? { result: 'transient', provider_status: 503, provider_code: 'UNAVAILABLE', stop: false }
        : { result: 'accepted', provider_status: 200, stop: false }; } };
  const counts = await runPush({ system, sender });
  assert.deepEqual(counts, { claimed: 3, reclaimed: 0, expired: 0, enabled: true,
    outcomes: { accepted: 1, obsolete: 1, retry: 1 }, sent: { accepted: 1, token_invalid: 1, transient: 1 },
    uncertain: 0, deferred: 0 });
  assert.deepEqual(sent.map(([, id]) => id), [ID(90), ID(90), ID(90)], 'every send carries the stable notification id');
  const records = calls.filter((c) => c.command === 'notifications.push_record').map((c) => c.payload);
  assert.deepEqual(records[0], { ...job(1), results: [
    { device_id: ID(11), result: 'accepted', provider_status: 200 },
    { device_id: ID(12), result: 'token_invalid', provider_status: 404, provider_code: 'UNREGISTERED' }] });
  assert.ok(!JSON.stringify(counts).includes('APA91') && !JSON.stringify(records).includes('APA91'),
    'no token in the answer or the record');
});

test('quota stops sending: the rest of the batch is released unused', async () => {
  const { calls, system } = fakeSystem({
    'notifications.push_claim': claimOf([job(1), job(2)]),
    'notifications.push_prepare': send([target(11, 'a'), target(12, 'b')]),
    'notifications.push_record': { outcome: 'retry' },
    'notifications.push_release': { released: true },
  });
  let sends = 0;
  const counts = await runPush({ system, sender: { send: async () => { sends += 1;
    return { result: 'transient', provider_status: 429, provider_code: 'QUOTA_EXCEEDED', stop: true }; } } });
  assert.equal(sends, 1, 'no further send after the quota answer');
  assert.equal(counts.stopped, 'provider_stop');
  assert.equal(counts.deferred, 1);
  assert.deepEqual(calls.filter((c) => c.command === 'notifications.push_release').map((c) => c.payload), [job(2)]);
  assert.deepEqual(calls.find((c) => c.command === 'notifications.push_record').payload.results,
    [{ device_id: ID(11), result: 'transient', provider_status: 429, provider_code: 'QUOTA_EXCEEDED' }]);
});

test('our configuration refused (OAuth, own token, sender mismatch): released unused, the run stops', async () => {
  for (const code of ['oauth_refused', 'provider_auth', 'sender_mismatch']) {
    const { calls, system } = fakeSystem({
      'notifications.push_claim': claimOf([job(1), job(2)]),
      'notifications.push_prepare': send([target(11, 'a')]),
      'notifications.push_release': { released: true },
    });
    const err = Object.assign(new Error(code), { code });
    const counts = await runPush({ system, sender: { send: async () => { throw err; } } });
    assert.equal(counts.stopped, code);
    assert.equal(counts.deferred, 2);
    assert.equal(calls.filter((c) => c.command === 'notifications.push_record').length, 0, 'no attempt, no retirement');
    assert.deepEqual(calls.filter((c) => c.command === 'notifications.push_release').map((c) => c.payload), [job(1), job(2)]);
  }
});

test('a provider outage stops the run after a few transient answers', async () => {
  const { calls, system } = fakeSystem({
    'notifications.push_claim': claimOf([job(1), job(2), job(3)]),
    'notifications.push_prepare': send([target(11, 'a'), target(12, 'b')]),
    'notifications.push_record': { outcome: 'retry' },
    'notifications.push_release': { released: true },
  });
  let sends = 0;
  const counts = await runPush({ system, sender: { send: async () => { sends += 1;
    return { result: 'transient', provider_status: 503, provider_code: 'UNAVAILABLE', stop: false }; } } });
  assert.equal(sends, 3);
  assert.equal(counts.stopped, 'provider_outage');
  assert.equal(counts.deferred, 1, 'the untouched job is released, its attempts not used up');
  assert.equal(calls.filter((c) => c.command === 'notifications.push_record').length, 2, 'what was sent is recorded');
});

test('sends stop before the lease ends; what was sent is recorded under the lease', async () => {
  let t = 0;
  const { calls, system } = fakeSystem({
    'notifications.push_claim': claimOf([job(1), job(2)], { lease_seconds: 60 }),
    'notifications.push_prepare': send([target(11, 'a'), target(12, 'b'), target(13, 'c')]),
    'notifications.push_record': { outcome: 'retry' },
    'notifications.push_release': { released: true },
  });
  // Lease 60 s: sending stops 25 s before its end (35 s). Each send takes 20 s.
  const counts = await runPush({ system, now: () => t, deadlineMs: 1e9,
    sender: { send: async () => { t += 20_000; return { result: 'accepted', provider_status: 200 }; } } });
  assert.equal(counts.sent.accepted, 2, 'sends at 0 and 20 s; none at 40 s');
  assert.equal(counts.stopped, 'lease_budget');
  assert.deepEqual(calls.find((c) => c.command === 'notifications.push_record').payload.results.map((r) => r.device_id),
    [ID(11), ID(12)]);
  assert.equal(counts.deferred, 1, 'the next job is released, not sent');
});

test('a lost system answer is uncertain; the deadline defers the rest', async () => {
  let t = 0;
  const { system } = fakeSystem({
    'notifications.push_claim': claimOf([job(1), job(2), job(3)]),
    'notifications.push_prepare': (p) => (p.push_job_id === ID(1) ? new Error('timeout') : send([target(11, 'a')])),
    'notifications.push_record': () => { t = 10_000_000; return { outcome: 'accepted' }; },
    'notifications.push_release': new Error('gone'),
  });
  const counts = await runPush({ system, sender: { send: async () => ({ result: 'accepted', provider_status: 200 }) },
    now: () => t });
  assert.deepEqual([counts.uncertain, counts.outcomes.accepted, counts.deferred], [1, 1, 1]);
});

test('a refused claim fails the run before anything is sent', async () => {
  const { calls, system } = fakeSystem({ 'notifications.push_claim': Object.assign(new Error('refused'), { code: 'refused' }) });
  await assert.rejects(runPush({ system, sender: { send: async () => assert.fail('nothing to send') } }), /refused/);
  assert.deepEqual(calls.map((c) => c.command), ['notifications.push_claim']);
  const malformed = fakeSystem({ 'notifications.push_claim': { jobs: 'x' } });
  await assert.rejects(runPush({ system: malformed.system, sender: {} }), /unexpected_claim/);
});

test('push off: the claim is made but leases nothing, so nothing is sent', async () => {
  const { calls, system } = fakeSystem({ 'notifications.push_claim': claimOf([], { push_enabled: false, expired: 2 }) });
  const counts = await runPush({ system, sender: { send: async () => assert.fail('nothing to send') } });
  assert.deepEqual(counts, { claimed: 0, reclaimed: 0, expired: 2, enabled: false, outcomes: {}, sent: {}, uncertain: 0, deferred: 0 });
  assert.deepEqual(calls, [{ command: 'notifications.push_claim', payload: {} }]);
});

test('no FCM credential: push jobs still expire (expire-only claim, nothing leased)', async () => {
  const { calls, system } = fakeSystem({ 'notifications.push_claim': claimOf([], { expired: 3, reclaimed: 1 }) });
  assert.deepEqual(await expirePush({ system }), { state: 'not_configured', reclaimed: 1, expired: 3 });
  assert.deepEqual(calls, [{ command: 'notifications.push_claim', payload: { expire_only: true } }]);
  const leased = fakeSystem({ 'notifications.push_claim': claimOf([job(1)]) });
  await assert.rejects(expirePush({ system: leased.system }), /unexpected_claim/, 'an expire-only claim must lease nothing');
});
