import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  A23_NUMBERS, COMMANDS, CRED_NUMBERS, LIMIT_NUMBERS, PERSONAS, POOL, PRINCIPALS, READS, STAGING_ORIGIN,
  assertPublishableKey, assertStagingOrigin, assertStateOutsideRepo, expectCommand, expectRead,
  isSuiteFictional, makePacer, probeEnvelope, redactEvidence, renderSummary,
} from './staging-suite.mjs';

test('only the exact staging origin is accepted', () => {
  assert.equal(assertStagingOrigin(STAGING_ORIGIN), STAGING_ORIGIN);
  assert.equal(assertStagingOrigin(`${STAGING_ORIGIN}/`), STAGING_ORIGIN);
  for (const bad of ['http://127.0.0.1:54321', 'https://szfyfezfvxyuvovnnakr.supabase.co', 'http://tmurpotfluignacfueki.supabase.co',
    'https://tmurpotfluignacfueki.supabase.co.evil.test', 'https://u:p@tmurpotfluignacfueki.supabase.co', `${STAGING_ORIGIN}/rest/v1`]) {
    assert.throws(() => assertStagingOrigin(bad), /refusing non-staging/, bad);
  }
});

test('every number the suite uses is fictional and the sets do not overlap', () => {
  assert.equal(isSuiteFictional('+12025550100'), true);
  assert.equal(isSuiteFictional('+12025550199'), true);
  assert.equal(isSuiteFictional('+12025550200'), false);
  assert.equal(isSuiteFictional('+260971234567'), false);
  const personas = Object.values(PERSONAS).map((p) => p.phone);
  const all = [...personas, ...POOL, ...LIMIT_NUMBERS, A23_NUMBERS[1], CRED_NUMBERS[2], CRED_NUMBERS[5]];
  assert.equal(new Set(all).size, all.length);
  assert.ok(all.every(isSuiteFictional));
  assert.ok(!all.includes('+12025550150'), 'the synthetic Admin is not a persona');
  assert.ok(!all.some((p) => /^\+120255501(7\d)$/.test(p)), '0170-0179 stay reserved for the owner rehearsal');
});

test('the state file must be outside the repository; keys must be publishable', () => {
  assert.throws(() => assertStateOutsideRepo('tools/identity-e2e/state.json'), /inside the repository/);
  assert.throws(() => assertStateOutsideRepo(''), /required/);
  assert.ok(assertStateOutsideRepo('/tmp/elsewhere/state.json'));
  assert.ok(assertPublishableKey('sb_publishable_abcDEF-123_x'));
  assert.throws(() => assertPublishableKey('sb_secret_abc'), /publishable/);
  assert.throws(() => assertPublishableKey('eyJhbGciOiJIUzI1NiJ9.e30.x'), /publishable/);
});

test('evidence never carries tokens, passwords, grant secrets, codes, phones or emails', () => {
  const out = JSON.stringify(redactEvidence({ access_token: 'a', nested: [{ password: 'p', phone: '+12025550101', grant_secret: 's', request_code: 'ABCD2345',
    email: 'x@example.test', note: 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.sig', status: 200 }] }));
  for (const leak of ['"a"', '"p"', '+1202', '"s"', 'ABCD2345', 'example.test', 'eyJhbGci']) assert.ok(!out.includes(leak), leak);
  assert.ok(out.includes('200'));
});

test('the matrix covers every principal against every api read and command', () => {
  assert.equal(Object.keys(PRINCIPALS).length, 14);
  assert.equal(Object.keys(READS).length, 21); // 20 api reads, fixture_scoped_read twice (care, finance)
  assert.equal(COMMANDS.length, 43); // 41 user command names + 2 system-route probes
  for (const p of Object.values(PRINCIPALS)) {
    for (const r of Object.keys(READS)) assert.ok(expectRead(p, r).status);
    for (const c of COMMANDS) assert.ok(expectCommand(p, c));
  }
});

test('expected answers follow the access rules', () => {
  const { anon, guest, mem, admin, pastor, leader, combo_apm: apm, combo_pml: pml, held, deact } = PRINCIPALS;
  assert.deepEqual(expectRead(anon, 'identity_my_membership_status'), { status: 401 });
  assert.deepEqual(expectRead(guest, 'identity_admin_member_grants'), { status: 403, detail: 'not_linked' });
  assert.deepEqual(expectRead(pastor, 'identity_admin_member_grants'), { status: 403, detail: 'not_granted' });
  assert.deepEqual(expectRead(apm, 'identity_admin_member_grants'), { status: 200 });
  assert.deepEqual(expectRead(apm, 'fixture_scoped_read_care'), { status: 403, detail: 'not_granted' });
  assert.deepEqual(expectRead(admin, 'cells_private_fixture_read'), { status: 403, detail: 'not_granted' });
  assert.deepEqual(expectRead(leader, 'cells_private_fixture_read'), { status: 200 });
  assert.deepEqual(expectRead(pml, 'cells_private_fixture_read'), { status: 403, detail: 'not_granted' });
  assert.deepEqual(expectRead(pml, 'cells_leader_queue'), { status: 200 });
  assert.deepEqual(expectRead(held, 'identity_my_credentials'), { status: 200 });
  assert.deepEqual(expectRead(held, 'identity_my_access'), { status: 403, detail: 'review_required' });
  assert.deepEqual(expectRead(deact, 'identity_my_application'), { status: 403, detail: 'not_applicant' });
  assert.deepEqual(expectRead(deact, 'identity_my_membership_status'), { status: 200 });
  const admin1 = COMMANDS.find((c) => c.cmd === 'identity.place_hold');
  const apply = COMMANDS.find((c) => c.cmd === 'identity.submit_application');
  assert.deepEqual(expectCommand(apm, admin1), { code: 'validation_failed' });
  assert.deepEqual(expectCommand(pml, admin1), { code: 'forbidden' });
  assert.deepEqual(expectCommand(mem, apply), { code: 'forbidden' });
  assert.deepEqual(expectCommand(guest, apply), { code: 'validation_failed' });
  assert.deepEqual(expectCommand(anon, apply), { status: 401 });
  const sys = COMMANDS.find((c) => c.group === 'system');
  assert.deepEqual(expectCommand(anon, sys), { code: 'unauthenticated' });
  assert.deepEqual(expectCommand(admin, sys), { code: 'forbidden' });
  const createCell = COMMANDS.find((c) => c.cmd === 'cells.create_cell');
  const confirm = COMMANDS.find((c) => c.cmd === 'cells.confirm_request');
  assert.deepEqual(expectCommand(leader, createCell), { code: 'forbidden' });
  assert.deepEqual(expectCommand(admin, createCell), { code: 'validation_failed' });
  assert.deepEqual(expectCommand(mem, confirm), { code: 'validation_failed' });
});

test('probe envelopes can never succeed', () => {
  for (const c of COMMANDS) {
    const e = probeEnvelope(c.cmd);
    assert.equal(e.version, 1);
    assert.ok(e.payload.matrix_probe === true || e.payload.confirm === 'matrix_probe_not_a_confirmation');
    assert.ok(!('member_id' in e.payload));
  }
});

test('the pacer keeps a sliding window', () => {
  let t = 1_000_000;
  const times = [];
  const p = makePacer(times, { limit: 3, windowMs: 1000, marginMs: 0, now: () => t });
  assert.equal(p.waitFor(3), 0);
  p.record(3);
  assert.equal(p.waitFor(1), 1000);
  t += 400;
  assert.equal(p.waitFor(1), 600);
  t += 600;
  assert.equal(p.waitFor(3), 0);
  assert.throws(() => p.waitFor(4), /cannot fit/);
});

test('the summary marks mismatches and lists owner steps', () => {
  const md = renderSummary({ results: [{ step: 'A10', ok: true }, { step: 'M-read-x', ok: false }], findings: ['A24b'],
    matrixRows: [{ principal: 'mem', surface: 'identity_my_access', kind: 'read', got: { status: 200 }, ok: true },
      { principal: 'mem', surface: 'identity.place_hold', kind: 'command', got: { code: 'forbidden' }, ok: false }],
    ownerSteps: ['worker'] });
  assert.match(md, /1\/2 passed/);
  assert.match(md, /\*\*fb≠\*\*/);
  assert.match(md, /- worker/);
});
