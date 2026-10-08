import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  configFrom,
  constantTimeEqual,
  declaredTooLarge,
  keyHeaders,
  parseBody,
  parseClaim,
  runDeadline,
  runOnce,
  systemEnvelope,
  triggerMatches,
} from './logic.mjs';

const ID = (n) => `00000000-0000-4000-8000-0000000340${String(n).padStart(2, '0')}`;
const TRIGGER = `nwt_${'ab'.repeat(32)}`;
const CRED = `sysc_staging_${'A'.repeat(43)}`;
const claimOf = (jobs, extra = {}) => ({
  jobs, claimed: jobs.length, reclaimed: 0, expired: 0, lease_seconds: 120, ...extra,
});

test('the body is empty, {} or {action: run, limit?}', () => {
  assert.deepEqual(parseBody(null), { ok: true, value: { action: 'run' } });
  assert.deepEqual(parseBody({}), { ok: true, value: { action: 'run' } });
  assert.deepEqual(parseBody({ action: 'run', limit: 5 }), { ok: true, value: { action: 'run', limit: 5 } });
  assert.equal(parseBody([]).error, 'invalid_body');
  assert.equal(parseBody('run').error, 'invalid_body');
  assert.equal(parseBody({ action: 'drain' }).error, 'invalid_action');
  assert.equal(parseBody({ limit: 0 }).error, 'invalid_limit');
  assert.equal(parseBody({ limit: 101 }).error, 'invalid_limit');
  assert.equal(parseBody({ limit: 1.5 }).error, 'invalid_limit');
  assert.equal(parseBody({ action: 'run', member_id: ID(1) }).error, 'unknown_field');
});

test('the function needs both of its secrets well-formed (fail closed)', () => {
  assert.deepEqual(configFrom({ credential: CRED, trigger: TRIGGER }), { credential: CRED, trigger: TRIGGER });
  assert.equal(configFrom({ credential: '', trigger: TRIGGER }), null);
  assert.equal(configFrom({ credential: CRED, trigger: '' }), null);
  assert.equal(configFrom({ credential: `sysc_dev_${'A'.repeat(43)}`, trigger: TRIGGER }), null);
  assert.equal(configFrom({ credential: CRED, trigger: CRED }), null, 'a credential is not a trigger');
  assert.equal(configFrom(undefined), null);
});

test('only the configured trigger starts a run, compared in constant time', () => {
  assert.equal(triggerMatches(TRIGGER, TRIGGER), true);
  assert.equal(triggerMatches(`nwt_${'ab'.repeat(31)}ac`, TRIGGER), false);
  assert.equal(triggerMatches(null, TRIGGER), false);
  assert.equal(triggerMatches('', TRIGGER), false);
  assert.equal(triggerMatches(CRED, TRIGGER), false);
  assert.equal(triggerMatches(TRIGGER.toUpperCase(), TRIGGER), false);
  assert.equal(constantTimeEqual('abc', 'abc'), true);
  assert.equal(constantTimeEqual('abc', 'abd'), false);
  assert.equal(constantTimeEqual('abc', 'abcd'), false);
  assert.equal(constantTimeEqual('', ''), true);
  assert.equal(constantTimeEqual(null, 'a'), false);
});

test('size, key headers and the envelope', () => {
  assert.equal(declaredTooLarge(null), false);
  assert.equal(declaredTooLarge('100'), false);
  assert.equal(declaredTooLarge('257'), true);
  assert.equal(declaredTooLarge('12x'), true);
  assert.deepEqual(keyHeaders('sb_publishable_x'), { apikey: 'sb_publishable_x' });
  assert.deepEqual(keyHeaders('eyJabc'), { apikey: 'eyJabc', authorization: 'Bearer eyJabc' });
  assert.deepEqual(systemEnvelope('notifications.claim', {}, ID(1)),
    { version: 1, command: 'notifications.claim', request_id: ID(1), payload: {} });
});

test('a claim answer is checked strictly', () => {
  assert.deepEqual(parseClaim(claimOf([{ job_id: ID(1), lease_token: 7, extra: 'x' }])).jobs,
    [{ job_id: ID(1), lease_token: 7 }]);
  assert.equal(parseClaim(null), null);
  assert.equal(parseClaim({ jobs: [] }), null);
  assert.equal(parseClaim(claimOf([{ job_id: 'x', lease_token: 1 }])), null);
  assert.equal(parseClaim(claimOf([{ job_id: ID(1), lease_token: 0 }])), null);
  assert.equal(parseClaim(claimOf([{ job_id: ID(1), lease_token: 1 }], { claimed: 2 })), null);
});

test('the run deadline stops one call plus a margin before the lease ends', () => {
  assert.equal(runDeadline(0, 120), 50_000);
  assert.equal(runDeadline(0, 30), 15_000);
  assert.equal(runDeadline(0, 10), 0);
});

test('a run claims, then attempts each job with its own token, and reports counts only', async () => {
  const calls = [];
  const system = async (command, payload) => {
    calls.push([command, payload]);
    if (command === 'notifications.claim') {
      return claimOf([{ job_id: ID(1), lease_token: 11 }, { job_id: ID(2), lease_token: 12 },
        { job_id: ID(3), lease_token: 13 }, { job_id: ID(4), lease_token: 14 }], { reclaimed: 1, expired: 2 });
    }
    if (payload.job_id === ID(2)) throw new Error('unreachable');
    if (payload.job_id === ID(3)) return { outcome: 'surprise' };
    return { outcome: payload.lease_token === 11 ? 'delivered' : 'fenced' };
  };
  const result = await runOnce({ system, limit: 10 });
  assert.deepEqual(calls[0], ['notifications.claim', { limit: 10 }]);
  assert.deepEqual(calls.slice(1).map(([c, p]) => [c, p.job_id, p.lease_token]),
    [['notifications.attempt', ID(1), 11], ['notifications.attempt', ID(2), 12],
      ['notifications.attempt', ID(3), 13], ['notifications.attempt', ID(4), 14]]);
  assert.deepEqual(result, { claimed: 4, reclaimed: 1, expired: 2,
    outcomes: { delivered: 1, unexpected: 1, fenced: 1 }, uncertain: 1, deferred: 0 });
  assert.ok(!JSON.stringify(result).includes(ID(1).slice(0, 20)));
});

test('jobs past the deadline are released unused (a failed release just lapses)', async () => {
  let t = 0;
  const calls = [];
  const system = async (command, payload) => {
    calls.push([command, payload?.job_id]);
    t += 20_000;
    if (command === 'notifications.release' && payload.job_id === ID(4)) throw new Error('unreachable');
    if (command === 'notifications.release') return { released: true };
    return command === 'notifications.claim'
      ? claimOf([{ job_id: ID(1), lease_token: 1 }, { job_id: ID(2), lease_token: 2 },
        { job_id: ID(3), lease_token: 3 }, { job_id: ID(4), lease_token: 4 }])
      : { outcome: 'delivered' };
  };
  const result = await runOnce({ system, now: () => t });
  assert.deepEqual(result.outcomes, { delivered: 2 });
  assert.equal(result.deferred, 2);
  assert.deepEqual(calls.filter(([c]) => c === 'notifications.release').map(([, id]) => id), [ID(3), ID(4)]);
});

test('a refused or malformed claim fails the run', async () => {
  await assert.rejects(runOnce({ system: async () => { throw new Error('refused'); } }), /refused/);
  await assert.rejects(runOnce({ system: async () => ({ jobs: 'x' }) }), /unexpected_claim/);
});
