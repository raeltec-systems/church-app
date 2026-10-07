#!/usr/bin/env node
// Story 2.9 end-to-end on the LOCAL stack: staff-assisted recovery with a single-use grant,
// through real GoTrue (phone sign-in without SMS, Auth Admin password update), the real Data API
// (PostgREST), the 1.9 system route and the real Edge Function identity-assisted-recovery served
// by `supabase functions serve` (started and stopped here). The verify bullet's adversarial
// cases:
//   * a valid grant works once, every older session ends and a fresh password sign-in is needed;
//   * an unused grant after reissue, a direct password change, an unlink, an expired grant and a
//     cross-member presentation all fail closed (cross-member burns the grant);
//   * concurrent redemption of one grant: exactly one succeeds;
//   * an uncertain (lost) Auth result and a late Auth apply keep the account held, block relinking
//     and new grants until an Admin reconciles; the next successful reset then lets an Admin
//     release the hold;
//   * a lost-device hold stays through the reset; a dispute hold refuses recovery;
//   * no password, grant secret or digest appears in staff responses, function responses or the
//     logs of the function, GoTrue, PostgREST, Kong and Postgres.
// The uncertain/late rows drive the function's own fenced steps through the system route with the
// run's credential (no fault-injection code exists in the function).
//
// Needs the local phone switch (`node tools/auth-harness/local-phone-auth.mjs on`, then `off`),
// the edge-runtime image, and a database with no usable Admin (`npx supabase db reset` first).
// LOCAL only (exact origin); SYNTHETIC fictional numbers +44 7700 900430-900449. Evidence is
// redacted JSONL: statuses, codes and booleans only. Everything it created is removed, except the
// content-free system-route audit rows and the revoked credential and disabled principal of the
// run (append-only operator journal, as in 1.9).
//
// Usage: node tools/identity-e2e/assisted.mjs [--evidence <file.jsonl>]
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { appendFileSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { amrMethods, assertLocalOrigin, redact } from './run.mjs';

/** The reserved fictional numbers this run uses (+44 7700 900430-900449). */
export function isFictionalAssistedPhone(phone) {
  return /^\+4477009004[34][0-9]$/.test(phone);
}

/** A grant secret as the member device creates it, and its digest. */
export function newGrantSecret() {
  return `arg_${randomBytes(32).toString('base64url')}`;
}
export function digestOf(secret) {
  return createHash('sha256').update(secret, 'utf8').digest('hex');
}

/** Values found in a text (the leak scan). */
export function findLeaks(text, values) {
  return values.filter((v) => typeof v === 'string' && v.length >= 6 && text.includes(v));
}

const NAME_PREFIX = 'SYNTHETIC 2.9 E2E';
const EPOCH_WAIT_MS = 6500; // the 2.2 trust-epoch margin is 5 s
const FN = '/functions/v1/identity-assisted-recovery';
const CONTAINERS = ['supabase_auth_church-app', 'supabase_rest_church-app', 'supabase_kong_church-app',
  'supabase_db_church-app'];

function localKey() {
  const env = execFileSync('npx', ['supabase', 'status', '-o', 'env'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  const url = /^API_URL="([^"]+)"/m.exec(env)?.[1];
  const key = /^PUBLISHABLE_KEY="([^"]+)"/m.exec(env)?.[1];
  const secret = /^SECRET_KEY="([^"]+)"/m.exec(env)?.[1];
  const service = /^SERVICE_ROLE_KEY="([^"]+)"/m.exec(env)?.[1];
  if (!url || !key || !secret || !service) throw new Error('local stack is not running');
  return { origin: assertLocalOrigin(url), key, secret, service };
}

function psql(sql) {
  return execFileSync('docker', ['exec', '-i', 'supabase_db_church-app', 'psql', '-U', 'postgres', '-X', '-qtA',
    '-v', 'ON_ERROR_STOP=1', '-c', sql], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const evidenceIdx = process.argv.indexOf('--evidence');
  const evidence = evidenceIdx > 0 ? process.argv[evidenceIdx + 1] : null;
  if (evidence) writeFileSync(evidence, '');
  const { origin, key, secret, service } = localKey();
  const startedAt = new Date().toISOString();
  const results = [];
  const log = (step, data) => {
    const line = { step, target: 'LOCAL', at: new Date().toISOString(), ...redact(data) };
    if (evidence) appendFileSync(evidence, JSON.stringify(line) + '\n');
    console.log(JSON.stringify(line));
  };
  const check = (step, ok, data) => {
    results.push({ step, ok });
    log(step, { verdict: ok ? 'pass' : 'FAIL', ...data });
  };
  // Everything a staff member or a member device received, for the leak scan.
  const staffTexts = [];
  const deviceTexts = [];
  async function http(method, path, { token, body, profile, admin, sink } = {}) {
    const headers = { apikey: admin ? secret : key, 'Content-Type': 'application/json' };
    if (admin) headers.Authorization = `Bearer ${service}`;
    else if (token) headers.Authorization = `Bearer ${token}`;
    if (profile) headers[method === 'GET' ? 'Accept-Profile' : 'Content-Profile'] = profile;
    const res = await fetch(`${origin}${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
    const text = await res.text();
    if (sink) sink.push(text);
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { /* non-JSON */ }
    return { status: res.status, json };
  }
  const password = () => `Synthetic-${randomBytes(12).toString('base64url')}`;
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const refresh = (rt) => http('POST', '/auth/v1/token?grant_type=refresh_token', { body: { refresh_token: rt } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api', sink: staffTexts });
  const envelope = (fn, token, cmd, expected, payload) =>
    rpc(fn, token, { version: 1, command: cmd, request_id: randomUUID(), expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const summary = async (token) => {
    const r = await http('POST', '/rest/v1/rpc/identity_my_member_summary', { token, body: {}, profile: 'api' });
    return { status: r.status, detail: r.json?.details ?? null };
  };
  // The member device: the real function, as the mobile adapter calls it (publishable key only).
  const fn = async (body) => {
    const r = await http('POST', FN, { body, sink: deviceTexts });
    return { status: r.status, ...(r.json ?? {}) };
  };

  const run = randomBytes(4).toString('hex');
  const people = {
    admin: { phone: '+447700900430' },
    happy: { phone: '+447700900431' },
    reissue: { phone: '+447700900432' },
    direct: { phone: '+447700900433' },
    unlinked: { phone: '+447700900434' },
    concurrent: { phone: '+447700900435' },
    owner: { phone: '+447700900436' },
    victim: { phone: '+447700900437' },
    uncertain: { phone: '+447700900438' },
    lost: { phone: '+447700900439' },
    disputed: { phone: '+447700900440' },
    expired: { phone: '+447700900441' },
  };
  for (const [k, p] of Object.entries(people)) {
    if (!isFictionalAssistedPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
    p.name = `${NAME_PREFIX} ${k}`;
  }
  const digits = Object.values(people).map((p) => `'${p.phone.slice(1)}'`).join(',');
  const secrets = []; // every grant secret and password this run created (must never leak)
  const digests = []; // every digest (never in staff answers or logs)
  const codes = []; // every request code (never in staff answers)

  const cleanup = () => psql(`
    create temp table gone_users as select u.id from auth.users u where u.phone in (${digits});
    create temp table gone_members as
      select m.member_id from app.identity_members m where m.display_name like '${NAME_PREFIX}%';
    delete from app.identity_recovery_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_recovery_operations o where o.member_id in (select member_id from gone_members);
    delete from app.identity_recovery_grants g where g.member_id in (select member_id from gone_members);
    delete from app.identity_recovery_cases c where c.member_id in (select member_id from gone_members);
    delete from app.identity_recovery_requests r where r.claimed_phone in (${Object.values(people).map((p) => `'${p.phone}'`).join(',')});
    delete from app.identity_recovery_audit a where a.member_id is null and a.action in ('request_received', 'request_refused')
       and a.occurred_at >= '${startedAt}';
    delete from app.identity_credential_review_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_membership_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_access_audit a
     where a.target_member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_grants g where g.member_id in (select member_id from gone_members);
    delete from app.identity_grant_sets s where s.member_id in (select member_id from gone_members);
    delete from app.identity_binding_history h using app.identity_account_links l
     where h.link_id = l.link_id and (l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users));
    delete from app.identity_credential_events e using app.identity_account_links l
     where e.link_id = l.link_id and (l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users));
    delete from app.identity_holds h where h.member_id in (select member_id from gone_members);
    delete from app.identity_account_links l
     where l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users);
    delete from app.identity_members m where m.member_id in (select member_id from gone_members);
    delete from app.cmd_receipts r where r.actor_id in (select id from gone_users);
    delete from auth.users u where u.id in (select id from gone_users);
    select count(*) from auth.users u where u.phone in (${digits});`);

  const settings = await http('GET', '/auth/v1/settings');
  if (settings.json?.external?.phone !== true) {
    throw new Error('the local phone provider is off: run `node tools/auth-harness/local-phone-auth.mjs on` first');
  }
  const marker = psql(`select coalesce((select environment from app.platform_environment), '')`);
  if (marker === '') psql(`select app.platform_set_environment('local', 'identity-assisted-e2e')`);
  else if (marker !== 'local') throw new Error(`local database is marked ${marker}`);
  const leftovers = cleanup();
  if (Number(psql(`select app.identity_usable_admin_count()`)) !== 0) {
    throw new Error('the local database already has a usable Admin; run `npx supabase db reset` first');
  }

  // The run's system principal and credential (only the digest is registered).
  const credential = `sysc_local_${randomBytes(32).toString('base64url')}`;
  const principal = psql(`select app.sys_create_principal('identity-assisted-e2e-${run}', 'identity_assisted_recovery', 'israel')`);
  const credentialId = JSON.parse(psql(`select app.sys_register_credential('${principal}', '${digestOf(credential)}',
    'assisted e2e ${run}', interval '2 hours', 'israel')`)).credential_id;
  const envDir = mkdtempSync(join(tmpdir(), 'assisted-e2e-'));
  const envFile = join(envDir, 'functions.env');
  writeFileSync(envFile, `IDENTITY_RECOVERY_SYSTEM_CREDENTIAL=${credential}\n`, { mode: 0o600 });
  let serveLog = '';
  const serve = spawn('npx', ['supabase', 'functions', 'serve', '--env-file', envFile],
    { stdio: ['ignore', 'pipe', 'pipe'], detached: true });
  serve.stdout.on('data', (d) => { serveLog += d; });
  serve.stderr.on('data', (d) => { serveLog += d; });
  const sys = async (command, payload) => {
    const res = await fetch(`${origin}/rest/v1/rpc/system_command`, {
      method: 'POST',
      headers: { apikey: key, 'Content-Type': 'application/json', 'Content-Profile': 'api', 'x-system-credential': credential },
      body: JSON.stringify({ version: 1, command, request_id: randomUUID(), payload }),
    });
    return (await res.json())?.data ?? null;
  };

  try {
    const deadline = Date.now() + 90_000;
    for (;;) {
      const probe = await fetch(`${origin}${FN}`, { method: 'POST', headers: { apikey: key, 'Content-Type': 'application/json' }, body: '{}' })
        .then((r) => r.status).catch(() => 0);
      if (probe === 400) break;
      if (Date.now() > deadline) throw new Error('the Edge Function did not start (is the edge-runtime image present?)');
      await sleep(1000);
    }
    log('A00-precondition', { settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
      leftover_users_removed: leftovers, function_served: true, verify_jwt: false });

    const seeded = async (p) => {
      p.password = password();
      secrets.push(p.password);
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'identity-assisted-e2e')`);
      const s = await signIn(p.phone, p.password);
      p.token = s.json?.access_token;
      p.refresh = s.json?.refresh_token;
    };
    const memberRev = (p) => Number(psql(`select revision from app.identity_members where member_id = '${p.member}'`));
    const recCmd = (cmd, expected, payload, token = people.admin.token) => envelope('identity_recovery_command', token, cmd, expected, payload);
    const cases = async () => (await rpc('identity_admin_recovery_cases', people.admin.token)).json?.cases ?? [];
    const caseOf = async (p) => (await cases()).find((c) => c.member_id === p.member && c.case_state === 'open');
    // The member device: a new secret, a request through the function; the code is shown to staff.
    const deviceRequest = async (p) => {
      const s = newGrantSecret();
      secrets.push(s);
      digests.push(digestOf(s));
      const r = await fn({ action: 'request', phone_username: p.phone, grant_digest: digestOf(s) });
      if (r.request_code) codes.push(r.request_code);
      return { secret: s, code: r.request_code, outcome: r.outcome };
    };
    const openCase = (p) => recCmd('identity.open_recovery_case', null,
      { member_id: p.member, identity_check: 'in_person', evidence: ['photo_id', 'known_in_person'] });
    const issue = async (p, code) => {
      const c = await caseOf(p);
      return recCmd('identity.issue_recovery_grant', c?.revision, { case_id: c?.case_id, request_code: code });
    };
    const ready = async (p) => {
      await openCase(p);
      const d = await deviceRequest(p);
      const issued = await issue(p, d.code);
      return { ...d, issued };
    };
    const redeem = (phone, s, pw) => {
      secrets.push(pw);
      return fn({ action: 'redeem', phone_username: phone, grant_secret: s, password: pw });
    };
    const openHolds = (p) => psql(`select coalesce(string_agg(coalesce(reason_code, reason), ',' order by placed_at), '')
                                     from app.identity_holds where member_id = '${p.member}' and released_at is null`);

    const { admin, happy, reissue, direct, unlinked, concurrent, owner, victim, uncertain, lost, disputed, expired } = people;
    await seeded(admin);
    psql(`select app.identity_bootstrap_admin('${admin.member}', 'israel')`);
    admin.token = (await signIn(admin.phone, admin.password)).json?.access_token;
    const access = await rpc('identity_my_access', admin.token);
    check('A01-admin-signed-in-by-phone', amrMethods(admin.token).includes('password') && access.json?.roles?.includes('admin'),
      { amr: amrMethods(admin.token), roles: access.json?.roles });

    // ------------------------------------------------------------------ happy path, once, fresh sign-in
    await seeded(happy);
    const second = await signIn(happy.phone, happy.password); // another device
    const opened = await openCase(happy);
    const memberOpens = await recCmd('identity.open_recovery_case', null,
      { member_id: admin.member, identity_check: 'in_person', evidence: ['photo_id'] }, happy.token);
    const d1 = await deviceRequest(happy);
    const waiting = await fn({ action: 'status', grant_digest: digestOf(d1.secret) });
    const issued = await issue(happy, d1.code);
    const readyStatus = await fn({ action: 'status', grant_digest: digestOf(d1.secret) });
    const newPw = password();
    const redeemed = await redeem(happy.phone, d1.secret, newPw);
    const replay = await redeem(happy.phone, d1.secret, password());
    const oldSession = await summary(happy.token);
    const oldRefresh = await refresh(second.json?.refresh_token);
    const oldPassword = await signIn(happy.phone, happy.password);
    await sleep(EPOCH_WAIT_MS);
    const fresh = await signIn(happy.phone, newPw);
    const after = await summary(fresh.json?.access_token);
    const closed = (await cases()).find((c) => c.case_id === opened.data?.case_id);
    check('A10-valid-grant-works-once-fresh-sign-in', opened.status === 200 && memberOpens.code === 'forbidden'
      && d1.outcome === 'received' && /^[A-HJ-NP-Z2-9]{8}$/.test(d1.code ?? '') && waiting.outcome === 'waiting'
      && issued.status === 200 && issued.data?.grant?.state === 'issued' && readyStatus.outcome === 'ready'
      && redeemed.outcome === 'succeeded' && replay.outcome === 'rejected'
      && oldSession.status === 401 && oldRefresh.status >= 400 && oldPassword.status === 400
      && fresh.status === 200 && amrMethods(fresh.json?.access_token).includes('password') && after.status === 200
      && closed?.case_state === 'completed' && closed?.operation?.state === 'succeeded' && openHolds(happy) === '',
      { open: opened.status, member_opens: memberOpens.code, request: d1.outcome, status_before: waiting.outcome,
        issue: issued.data?.grant?.state, status_after_issue: readyStatus.outcome, redeem: redeemed.outcome,
        replay: replay.outcome, old_session: oldSession, old_refresh: oldRefresh.status, old_password_sign_in: oldPassword.status,
        fresh_sign_in: fresh.status, fresh_amr: amrMethods(fresh.json?.access_token), fresh_summary: after.status,
        case_state: closed?.case_state, operation: closed?.operation?.state, holds_left: openHolds(happy) });
    happy.password = newPw;

    // ------------------------------------------------------------------ unused grant after reissue
    await seeded(reissue);
    const g1 = await ready(reissue);
    const g2 = await deviceRequest(reissue);
    const reissued = await issue(reissue, g2.code);
    const oldGrant = await redeem(reissue.phone, g1.secret, password());
    const newGrant = await redeem(reissue.phone, g2.secret, password());
    check('A11-unused-grant-after-reissue-fails', g1.issued.status === 200 && reissued.status === 200
      && oldGrant.outcome === 'rejected' && newGrant.outcome === 'succeeded',
      { first_issue: g1.issued.status, reissue: reissued.status, old_grant: oldGrant.outcome, new_grant: newGrant.outcome });

    // ------------------------------------------------------------------ direct password change
    await seeded(direct);
    const gd = await ready(direct);
    const changedPw = password();
    secrets.push(changedPw);
    const putUser = await http('PUT', '/auth/v1/user', { token: direct.token, body: { password: changedPw } });
    const afterDirect = await redeem(direct.phone, gd.secret, password());
    check('A12-direct-password-change-kills-the-grant', gd.issued.status === 200 && putUser.status === 200
      && afterDirect.outcome === 'rejected',
      { issue: gd.issued.status, direct_put_user: putUser.status, redeem: afterDirect.outcome });

    // ------------------------------------------------------------------ unlink (relink/deactivation)
    await seeded(unlinked);
    const gu = await ready(unlinked);
    const unlink = await envelope('identity_review_command', admin.token, 'identity.unlink_account', memberRev(unlinked),
      { member_id: unlinked.member, reason: 'account_lost' });
    const afterUnlink = await redeem(unlinked.phone, gu.secret, password());
    check('A13-unlinked-account-grant-fails', gu.issued.status === 200 && unlink.status === 200
      && afterUnlink.outcome === 'rejected',
      { issue: gu.issued.status, unlink: unlink.status, redeem: afterUnlink.outcome });

    // ------------------------------------------------------------------ concurrent redemption
    await seeded(concurrent);
    const gc = await ready(concurrent);
    const tries = Array.from({ length: 6 }, () => password());
    const outcomes = await Promise.all(tries.map((pw) => redeem(concurrent.phone, gc.secret, pw)));
    const winners = outcomes.map((o, i) => (o.outcome === 'succeeded' ? i : -1)).filter((i) => i >= 0);
    await sleep(EPOCH_WAIT_MS);
    const signIns = await Promise.all(tries.map((pw) => signIn(concurrent.phone, pw).then((r) => r.status)));
    const ops = Number(psql(`select count(*) from app.identity_recovery_operations where member_id = '${concurrent.member}'`));
    check('A14-concurrent-redemption-exactly-one', winners.length === 1
      && outcomes.filter((o) => o.outcome === 'rejected').length === tries.length - 1
      && signIns.filter((s) => s === 200).length === 1 && signIns[winners[0]] === 200 && ops === 1,
      { outcomes: outcomes.map((o) => o.outcome), password_sign_ins: signIns, operations: ops });

    // ------------------------------------------------------------------ cross-member use (burned)
    await seeded(owner);
    await seeded(victim);
    const go = await ready(owner);
    // The victim's case cannot bind a request sent from another member's number.
    await openCase(victim);
    const ownerRequest = await deviceRequest(owner);
    const crossIssue = await issue(victim, ownerRequest.code);
    const cross = await redeem(victim.phone, go.secret, password());
    const afterBurn = await redeem(owner.phone, go.secret, password());
    const victimSignIn = await signIn(victim.phone, victim.password);
    check('A15-cross-member-use-fails-and-burns', go.issued.status === 200
      && crossIssue.field_errors?.request_code === 'mismatch' && cross.outcome === 'rejected'
      && afterBurn.outcome === 'rejected' && victimSignIn.status === 200
      && psql(`select grant_state from app.identity_recovery_grants where member_id = '${owner.member}'`) === 'burned',
      { issue: go.issued.status, issue_other_members_request: crossIssue.code, issue_field_errors: crossIssue.field_errors,
        cross_member_redeem: cross.outcome, owner_after_burn: afterBurn.outcome, victim_password_still_works: victimSignIn.status });

    // ------------------------------------------------------------------ uncertain and late Auth result
    await seeded(uncertain);
    const gx = await ready(uncertain);
    const begun = await sys('identity.assisted_reset_begin', { phone_username: uncertain.phone, grant_digest: digestOf(gx.secret) });
    const dispatched = await sys('identity.assisted_reset_dispatch', { operation_id: begun?.operation_id });
    const lostAnswer = await sys('identity.assisted_reset_complete', { operation_id: begun?.operation_id, auth_result: 'unknown' });
    await sleep(EPOCH_WAIT_MS);
    const heldOld = await signIn(uncertain.phone, uncertain.password);
    const heldSummary = await summary(heldOld.json?.access_token);
    const latePw = password();
    secrets.push(latePw);
    const lateApply = await http('PUT', `/auth/v1/admin/users/${dispatched?.auth_user_id}`, { admin: true, body: { password: latePw } });
    const lateAnswer = await sys('identity.assisted_reset_complete', { operation_id: begun?.operation_id, auth_result: 'applied' });
    await sleep(EPOCH_WAIT_MS);
    const lateSignIn = await signIn(uncertain.phone, latePw);
    const lateSummary = await summary(lateSignIn.json?.access_token);
    const noNewGrant = await (async () => {
      const d = await deviceRequest(uncertain);
      return issue(uncertain, d.code);
    })();
    const unlinkU = await envelope('identity_review_command', admin.token, 'identity.unlink_account', memberRev(uncertain),
      { member_id: uncertain.member, reason: 'account_lost' });
    let relink;
    try {
      psql(`select app.identity_seed_synthetic_link('${uncertain.user}', '${uncertain.name} relink', 'identity-assisted-e2e')`);
      relink = 'linked';
    } catch (e) {
      relink = /recovery_unresolved|PCMD1|conflict/.test(String(e.stderr ?? e.message)) ? 'refused' : 'error';
    }
    const uc = (await cases()).find((c) => c.member_id === uncertain.member && c.case_state === 'open');
    const reconciled = await recCmd('identity.reconcile_recovery_operation', uc?.revision,
      { case_id: uc?.case_id, identity_check: 'in_person' });
    check('A16-uncertain-and-late-results-keep-the-account-held', begun?.accepted === true && dispatched?.proceed === true
      && lostAnswer?.outcome === 'uncertain' && heldOld.status === 200 && heldSummary.status === 403
      && heldSummary.detail === 'review_required' && lateApply.status === 200 && lateAnswer?.late === true
      && lateSignIn.status === 200 && lateSummary.status === 403 && noNewGrant.field_errors?.case_id === 'recovery_unresolved'
      && unlinkU.status === 200 && relink === 'refused' && uc?.operation?.state === 'uncertain'
      && reconciled.status === 200 && reconciled.data?.operation?.state === 'reconciled'
      && openHolds(uncertain) === 'assisted_reset_operation',
      { begin: begun?.accepted, dispatch: dispatched?.proceed, lost_response: lostAnswer?.outcome,
        old_password_sign_in: heldOld.status, held_read: heldSummary, late_auth_apply: lateApply.status,
        late_completion_recorded_only: lateAnswer?.late, late_password_sign_in: lateSignIn.status, late_read: lateSummary.status,
        new_grant_while_uncertain: noNewGrant.field_errors, unlink_allowed: unlinkU.status, relink_while_unresolved: relink,
        case_operation: uc?.operation?.state, reconcile: reconciled.data?.operation?.state, holds: openHolds(uncertain) });
    let relinkAfter;
    try {
      psql(`select app.identity_seed_synthetic_link('${uncertain.user}', '${uncertain.name} relinked', 'identity-assisted-e2e')`);
      relinkAfter = 'linked';
    } catch {
      relinkAfter = 'refused';
    }
    check('A17-relink-possible-after-reconcile', relinkAfter === 'linked', { relink_after_reconcile: relinkAfter });

    // ------------------------------------------------------------------ lost-device hold, dispute hold
    await seeded(lost);
    const hold = await envelope('identity_credential_command', admin.token, 'identity.place_hold', memberRev(lost),
      { member_id: lost.member, reason_code: 'lost_device' });
    const holdId = hold.data?.holds?.[0]?.hold_id;
    const earlyRelease = await envelope('identity_credential_command', admin.token, 'identity.release_hold', memberRev(lost),
      { member_id: lost.member, hold_id: holdId, identity_check: 'in_person' });
    const gl = await ready(lost);
    const lostPw = password();
    const lostRedeem = await redeem(lost.phone, gl.secret, lostPw);
    await sleep(EPOCH_WAIT_MS);
    const lostHeld = await summary((await signIn(lost.phone, lostPw)).json?.access_token);
    const release = await envelope('identity_credential_command', admin.token, 'identity.release_hold', memberRev(lost),
      { member_id: lost.member, hold_id: holdId, identity_check: 'in_person' });
    await sleep(EPOCH_WAIT_MS);
    const lostAfter = await summary((await signIn(lost.phone, lostPw)).json?.access_token);
    await seeded(disputed);
    await envelope('identity_credential_command', admin.token, 'identity.place_hold', memberRev(disputed),
      { member_id: disputed.member, reason_code: 'ownership_dispute' });
    const disputedCase = await openCase(disputed);
    check('A18-holds-stay-through-the-reset', hold.status === 200 && earlyRelease.field_errors?.hold_id === 'password_reset_required'
      && lostRedeem.outcome === 'succeeded' && lostHeld.status === 403 && release.status === 200 && lostAfter.status === 200
      && disputedCase.field_errors?.member_id === 'disputed',
      { lost_device_hold: hold.status, release_before_reset: earlyRelease.field_errors, assisted_reset: lostRedeem.outcome,
        read_after_reset: lostHeld, release_after_reset: release.status, read_after_release: lostAfter.status,
        dispute_hold_open_case: disputedCase.field_errors });

    // ------------------------------------------------------------------ expired grant
    await seeded(expired);
    const ge = await ready(expired);
    psql(`update app.identity_recovery_grants set issued_at = issued_at - interval '1 hour', expires_at = now() - interval '1 second'
           where member_id = '${expired.member}' and grant_state = 'issued'`);
    const expiredStatus = await fn({ action: 'status', grant_digest: digestOf(ge.secret) });
    const expiredRedeem = await redeem(expired.phone, ge.secret, password());
    check('A19-expired-grant-fails', ge.issued.status === 200 && expiredStatus.outcome === 'closed' && expiredRedeem.outcome === 'rejected',
      { issue: ge.issued.status, status: expiredStatus.outcome, redeem: expiredRedeem.outcome });

    // ------------------------------------------------------------------ no leakage anywhere
    const staffText = staffTexts.join('\n');
    const deviceText = deviceTexts.join('\n');
    const logs = { function: serveLog };
    for (const c of CONTAINERS) logs[c] = dockerLogs(startedAt, c);
    const logLeaks = Object.fromEntries(Object.entries(logs).map(([k, v]) =>
      [k, findLeaks(v, [...secrets, ...digests]).length]));
    const staffLeaks = findLeaks(staffText, [...secrets, ...digests, ...codes]).length;
    const deviceLeaks = findLeaks(deviceText, [...secrets, ...digests]).length;
    const dbLeaks = Number(psql(`select count(*) from (
        select row_to_json(a)::text t from app.identity_recovery_audit a
        union all select row_to_json(c)::text from app.identity_recovery_cases c
        union all select row_to_json(o)::text from app.identity_recovery_operations o
        union all select row_to_json(s)::text from app.sys_audit s
        union all select row_to_json(r)::text from app.sys_receipts r) x
       where ${[...secrets].map((s) => `t like '%${s.replace(/'/g, "''")}%'`).join(' or ')}`));
    check('A20-no-password-or-usable-grant-leaks', staffLeaks === 0 && deviceLeaks === 0 && dbLeaks === 0
      && Object.values(logLeaks).every((n) => n === 0) && logs.function.includes('identity-assisted-recovery'),
      { values_checked: secrets.length + digests.length, staff_answers: staffLeaks, device_answers: deviceLeaks,
        database_rows: dbLeaks, logs: logLeaks, function_log_lines: (logs.function.match(/"fn":"identity-assisted-recovery"/g) ?? []).length });
  } finally {
    try { process.kill(-serve.pid, 'SIGINT'); } catch { /* already gone */ }
    await sleep(3000);
    try { process.kill(-serve.pid, 'SIGKILL'); } catch { /* already gone */ }
    try { execFileSync('docker', ['rm', '-f', 'supabase_edge_runtime_church-app'], { stdio: 'ignore' }); } catch { /* not running */ }
    rmSync(envDir, { recursive: true, force: true });
    psql(`select app.sys_revoke_credential('${credentialId}', 'israel'); select app.sys_disable_principal('${principal}', 'israel');`);
    const left = cleanup();
    log('A99-cleanup', { users_left: Number(left), credential_revoked: true, principal_disabled: true });
  }
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  if (failed.length) {
    console.log(`FAILED: ${failed.map((f) => f.step).join(', ')}`);
    process.exitCode = 1;
  }
}

// `docker logs` replays the container's stdout and stderr on the matching streams; read both.
function dockerLogs(since, container) {
  const r = spawnSync('docker', ['logs', '--since', since, container], { encoding: 'utf8', maxBuffer: 64 << 20 });
  return `${r.stdout ?? ''}${r.stderr ?? ''}`;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((e) => {
    console.error(e.message);
    process.exitCode = 1;
  });
}
