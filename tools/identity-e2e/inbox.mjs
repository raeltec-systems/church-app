#!/usr/bin/env node
// Story 3.1 end-to-end on the LOCAL stack: a SYNTHETIC due reminder reaches the durable inbox
// through real GoTrue phone sign-in (no SMS), the real Data API (PostgREST), the 1.9 system route
// and the real worker script (tools/notifications/worker.mjs) with a local credential of the
// purpose `notifications_worker`:
//   * member A runs the synthetic source command (fixture.reminder_create, due now); the source and
//     its job are written in one transaction; repeating the command (same request id) returns the
//     stored result and adds no job;
//   * one worker run turns the job into exactly one inbox item that A reads; a second run adds
//     nothing; two workers racing over three due jobs of member B still give three items;
//   * a cancelled reminder and a future one never become items;
//   * member B, an unlinked account and a signed-out caller see none of A's items.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. LOCAL only (exact origin), SYNTHETIC fictional numbers +44 7700 900810-900819.
// Evidence is redacted JSONL: statuses, codes, counts; never tokens, passwords, numbers or the
// credential. Every user, member, link, reminder, job, item and receipt it created is removed; the
// run's credential is revoked and its principal disabled (content-free sys_audit rows stay).
//
// Usage: node tools/identity-e2e/inbox.mjs [--evidence <file.jsonl>]
import { execFile } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 3.1 E2E';

/** The reserved fictional numbers this run uses (+44 7700 900810-900819). */
export function isFictionalInboxPhone(phone) {
  return /^\+44770090081[0-9]$/.test(phone);
}

/** Sums the counts of several worker runs. */
export function totalCounts(runs) {
  const out = { claimed: 0, delivered: 0, obsolete: 0, ineligible: 0, failed: 0 };
  for (const r of runs) for (const k of Object.keys(out)) out[k] += Number(r?.[k] ?? 0);
  return out;
}

/** A worker's stdout is content-free: none of the given values appear in it. */
export function leaks(text, values) {
  return values.filter((v) => v && String(text).includes(String(v)));
}

async function main() {
  const { log, check, finish } = startRun();
  const keys = localKey();
  const { origin, key } = keys;
  const http = localHttp(keys);
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const reminder = (token, cmd, expected, payload, requestId = randomUUID()) =>
    rpc('fixture_reminder_command', token, { version: 1, command: cmd, request_id: requestId, expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const inbox = async (token) => {
    const r = await rpc('notifications_my_inbox', token);
    return { status: r.status, items: r.json?.items ?? null, code: r.json?.message ?? r.json?.code ?? null, detail: r.json?.details ?? null };
  };
  const utc = (ms) => new Date(ms).toISOString();

  const people = {
    a: { phone: '+447700900810', name: `${NAME_PREFIX} Member A` },
    b: { phone: '+447700900811', name: `${NAME_PREFIX} Member B` },
    unlinked: { phone: '+447700900812' },
  };
  for (const p of Object.values(people)) if (!isFictionalInboxPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  const users = new Set();
  const digits = Object.values(people).map((p) => `'${p.phone.slice(1)}'`).join(',');
  const cleanup = () => {
    const ids = [...users].map((u) => `'${u}'`);
    const byUser = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    return psql(`
    create temp table gone_users as select u.id from auth.users u where ${byUser} u.phone in (${digits});
    create temp table gone_members as
      select m.member_id from app.identity_members m where m.display_name like '${NAME_PREFIX}%';
    delete from app.notifications_inbox_items i where i.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_attempts a using app.notifications_jobs j
     where a.job_id = j.job_id and j.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_jobs j where j.recipient_member_id in (select member_id from gone_members);
    delete from app.fixture_reminder_sources s where s.member_id in (select member_id from gone_members);
    delete from app.identity_access_audit a
     where a.target_member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_grants g where g.member_id in (select member_id from gone_members);
    delete from app.identity_grant_sets s where s.member_id in (select member_id from gone_members);
    delete from app.identity_holds h where h.member_id in (select member_id from gone_members);
    delete from app.identity_binding_history h using app.identity_account_links l
     where h.link_id = l.link_id and (l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users));
    delete from app.identity_credential_events e using app.identity_account_links l
     where e.link_id = l.link_id and (l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users));
    delete from app.identity_account_links l
     where l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users);
    delete from app.identity_members m where m.member_id in (select member_id from gone_members);
    delete from app.cmd_receipts r where r.actor_id in (select id from gone_users);
    delete from auth.users u where u.id in (select id from gone_users);
    select count(*) from auth.users u where ${byUser} u.phone in (${digits});`);
  };

  const settings = await http('GET', '/auth/v1/settings');
  if (settings.json?.external?.phone !== true) {
    throw new Error('the local phone provider is off: run `node tools/auth-harness/local-phone-auth.mjs on` first');
  }
  const marker = psql(`select coalesce((select environment from app.platform_environment), '')`);
  let marked = false;
  if (marker === '') {
    psql(`select app.platform_set_environment('local', 'notifications-inbox-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('I00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  // The run's worker principal and credential (only the digest is registered).
  const run = randomUUID().slice(0, 8);
  const credential = `sysc_local_${randomBytes(32).toString('base64url')}`;
  const principal = psql(`select app.sys_create_principal('notifications-worker-e2e-${run}', 'notifications_worker', '${OPERATOR}')`);
  const credentialId = JSON.parse(psql(`select app.sys_register_credential('${principal}',
    '${createHash('sha256').update(credential).digest('hex')}', 'inbox e2e ${run}', interval '2 hours', '${OPERATOR}')`)).credential_id;
  const workerOut = [];
  // The real worker script, as the operator runs it.
  const worker = async (env = { NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL: credential }) => {
    try {
      const { stdout } = await promisify(execFile)('node', [join(ROOT, 'tools/notifications/worker.mjs'), 'run-once'], {
        encoding: 'utf8', env: { PATH: process.env.PATH, SUPABASE_URL: origin, SUPABASE_PUBLISHABLE_KEY: key, ...env } });
      workerOut.push(stdout);
      const line = stdout.split('\n').find((l) => l.startsWith('{'));
      return { exit: 0, ...(line ? JSON.parse(line) : {}) };
    } catch (e) {
      workerOut.push(`${e.stdout ?? ''}${e.stderr ?? ''}`);
      return { exit: e.code ?? 1, error: String(e.stderr ?? '').trim().slice(-160) };
    }
  };
  const jobStates = (sourceId) => psql(`select coalesce(string_agg(job_state, ',' order by enqueued_at), '') from app.notifications_jobs
    where source_type = 'fixture_reminder' and source_id = '${sourceId}'`);

  try {
    const { a, b, unlinked } = people;
    for (const p of [a, b]) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'notifications-inbox-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    unlinked.password = password();
    const up = await http('POST', '/auth/v1/signup', { body: { phone: unlinked.phone, password: unlinked.password } });
    unlinked.user = up.json?.user?.id;
    if (unlinked.user) users.add(unlinked.user);
    unlinked.token = up.json?.access_token;
    check('I01-members-signed-in-by-phone', [a, b].every((p) => amrMethods(p.token).includes('password')) && Boolean(unlinked.token),
      { amr: amrMethods(a.token) });

    // ------------------------------------------------------------ the synthetic source command
    const requestId = randomUUID();
    const due = utc(Date.now() - 60_000);
    const created = await reminder(a.token, 'fixture.reminder_create', null, { due_at: due }, requestId);
    const sourceA = created.data?.source_id;
    const replay = await reminder(a.token, 'fixture.reminder_create', null, { due_at: due }, requestId);
    check('I10-command-writes-source-and-job', created.status === 200 && created.revision === 1
      && created.data?.job_state === 'pending' && created.data?.job_created === true && jobStates(sourceA) === 'pending',
      { status: created.status, revision: created.revision, job_state: created.data?.job_state, jobs: jobStates(sourceA) });
    check('I11-repeated-command-adds-nothing', JSON.stringify(replay.data) === JSON.stringify(created.data)
      && replay.revision === created.revision && jobStates(sourceA) === 'pending',
      { same_result: JSON.stringify(replay.data) === JSON.stringify(created.data), jobs: jobStates(sourceA) });
    const before = await inbox(a.token);
    check('I12-nothing-before-the-worker', before.status === 200 && before.items?.length === 0, { status: before.status, items: before.items?.length });

    // ------------------------------------------------------------------------------- worker
    const first = await worker();
    const afterFirst = await inbox(a.token);
    check('I20-worker-delivers-one-item', first.exit === 0 && first.delivered === 1 && afterFirst.items?.length === 1
      && afterFirst.items?.[0]?.reminder_kind === 'fixture_due' && jobStates(sourceA) === 'delivered',
      { worker: { exit: first.exit, claimed: first.claimed, delivered: first.delivered }, items: afterFirst.items?.length,
        keys: Object.keys(afterFirst.items?.[0] ?? {}).sort(), jobs: jobStates(sourceA) });
    const second = await worker();
    const afterSecond = await inbox(a.token);
    check('I21-repeat-worker-adds-nothing', second.exit === 0 && second.delivered === 0 && afterSecond.items?.length === 1
      && afterSecond.items?.[0]?.item_id === afterFirst.items?.[0]?.item_id,
      { worker: { delivered: second.delivered }, items: afterSecond.items?.length });

    // ------------------------------------------------------------------- other callers see nothing
    const itemA = afterFirst.items?.[0]?.item_id;
    const bBefore = await inbox(b.token);
    const nobody = await http('POST', '/rest/v1/rpc/notifications_my_inbox', { body: {}, profile: 'api' });
    const notLinked = await inbox(unlinked.token);
    check('I30-others-see-nothing', bBefore.status === 200 && bBefore.items?.length === 0
      && [401, 403, 404].includes(nobody.status) && !JSON.stringify(nobody.json ?? '').includes(itemA)
      && notLinked.status === 403 && notLinked.detail === 'not_linked',
      { member_b: bBefore.items?.length, signed_out: nobody.status, unlinked: { status: notLinked.status, detail: notLinked.detail } });

    const page = (await rpc('notifications_my_inbox', a.token)).json;
    const half = await rpc('notifications_my_inbox', a.token, { after_item_id: itemA });
    check('I31-paging-cursor', page?.next === null && Array.isArray(page?.items) && half.status === 400,
      { next: page?.next ?? null, half_cursor: half.status });

    // ------------------------------------------------------------ cancelled and future reminders
    const toCancel = await reminder(a.token, 'fixture.reminder_create', null, { due_at: utc(Date.now() - 30_000) });
    const cancelled = await reminder(a.token, 'fixture.reminder_cancel', toCancel.revision, { source_id: toCancel.data?.source_id });
    const future = await reminder(a.token, 'fixture.reminder_create', null, { due_at: utc(Date.now() + 86_400_000) });
    const third = await worker();
    const afterCancel = await inbox(a.token);
    check('I40-cancelled-never-becomes-an-item', cancelled.status === 200 && cancelled.data?.cancelled_jobs === 1
      && jobStates(toCancel.data?.source_id) === 'cancelled' && afterCancel.items?.length === 1,
      { cancel: { status: cancelled.status, revision: cancelled.revision, cancelled_jobs: cancelled.data?.cancelled_jobs },
        jobs: jobStates(toCancel.data?.source_id), items: afterCancel.items?.length });
    check('I41-future-job-waits', third.delivered === 0 && jobStates(future.data?.source_id) === 'pending',
      { worker: { delivered: third.delivered }, jobs: jobStates(future.data?.source_id) });

    // ---------------------------------------------------------------- two workers racing
    for (let i = 0; i < 3; i++) await reminder(b.token, 'fixture.reminder_create', null, { due_at: utc(Date.now() - 10_000 - i) });
    const raced = await Promise.all([worker(), worker()]);
    const total = totalCounts(raced);
    const bAfter = await inbox(b.token);
    const aAfter = await inbox(a.token);
    const bItems = Number(psql(`select count(*) from app.notifications_inbox_items where recipient_member_id = '${b.member}'`));
    check('I50-racing-workers-one-item-per-job', raced.every((r) => r.exit === 0) && total.delivered === 3
      && bItems === 3 && bAfter.items?.length === 3 && !bAfter.items.some((i) => i.item_id === itemA)
      && aAfter.items?.length === 1,
      { per_worker: raced.map((r) => r.delivered), total_delivered: total.delivered, items_b: bItems, items_a: aAfter.items?.length });

    // ------------------------------------------------------------ the worker needs its credential
    const noCred = await worker({ NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL: `sysc_local_${randomBytes(32).toString('base64url')}` });
    check('I60-unknown-credential-refused', noCred.exit !== 0 && /unauthenticated/.test(noCred.error ?? ''), { exit: noCred.exit });
    const out = workerOut.join('\n');
    const leaked = leaks(out, [credential, a.member, b.member, a.user, b.user, sourceA, itemA, a.phone.slice(1)]);
    check('I61-worker-output-content-free', leaked.length === 0, { leaked_values: leaked.length, lines: workerOut.length });
  } finally {
    const left = cleanup();
    psql(`select app.sys_revoke_credential('${credentialId}', '${OPERATOR}'); select app.sys_disable_principal('${principal}', '${OPERATOR}');`);
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'notifications-inbox-e2e';
            delete from app.platform_environment_history where set_by = 'notifications-inbox-e2e';`);
    }
    log('I99-cleanup', { users_left: Number(left), credential_revoked: true, principal_disabled: true, unmarked: marked,
      jobs_left: Number(psql(`select count(*) from app.notifications_jobs`)),
      items_left: Number(psql(`select count(*) from app.notifications_inbox_items`)) });
  }
  finish();
}

runMain(import.meta.url, main);
