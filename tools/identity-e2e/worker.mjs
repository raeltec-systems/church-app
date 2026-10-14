#!/usr/bin/env node
// Story 3.4 end-to-end on the LOCAL stack: the leased and fenced notification worker through the
// real Data API (PostgREST), the 1.9 system route, the Edge Function notifications-worker served
// by `supabase functions serve` (started and stopped here), Supabase Vault, pg_net and pg_cron:
//   * two workers claim one batch at the same time: disjoint leases, one item per job;
//   * a worker killed mid-lease: its lease lapses, another worker reclaims with a higher fencing
//     token, the late attempt with the stale token is fenced, one item;
//   * a job cancelled after the claim, a source revised after enqueue, a revoked recipient grant,
//     an expired job (at the claim and at the attempt) and a transient failure each end in one
//     logical outcome with every attempt recorded;
//   * the Edge Function holds the worker credential as its own secret (env file here) and starts
//     a run only for the scheduler trigger: no, malformed or wrong trigger, or a credential in
//     its place, is 401 and starts nothing; a revoked worker credential is 403;
//   * pg_cron runs the worker with no client involved: the tick reads the trigger from Vault and
//     posts to the Edge Function with pg_net; the inbox item appears; the scheduler is one named
//     job and is removed afterwards; no system credential is ever in the database.
//
// Needs the local phone switch (`node tools/auth-harness/local-phone-auth.mjs on`, then `off`),
// the edge-runtime image and a reset database. LOCAL only (exact origin), SYNTHETIC fictional
// numbers +44 7700 900870-900879. Evidence is redacted JSONL: statuses, outcome codes and counts;
// never tokens, passwords, numbers or credentials. Everything it created is removed: users,
// members, reminders, jobs, attempts, items, runs, receipts, the Vault secret and the Cron job;
// the worker policy is restored; credentials are revoked and principals disabled (content-free
// sys_audit rows stay).
//
// Usage: node tools/identity-e2e/worker.mjs [--evidence <file.jsonl>]
import { execFileSync, spawn } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { amrMethods, localHttp, localKey, password, psql, runMain, sleep, startRun } from './harness.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 3.4 E2E';
const FN = '/functions/v1/notifications-worker';
/** The Edge Function as the database container reaches it (pg_net runs inside it). */
export const IN_NETWORK_URL = 'http://kong:8000/functions/v1/notifications-worker';
const DEFAULT_POLICY = { lease_seconds: 120, batch_max: 25, max_attempts: 5, backoff_base_seconds: 60,
  backoff_max_seconds: 3600, default_ttl_seconds: 604800, worker_url: null };

/** The reserved fictional numbers this run uses (+44 7700 900870-900879). */
export function isFictionalWorkerPhone(phone) {
  return /^\+44770090087[0-9]$/.test(phone);
}

/** The lease token of one job in a claim answer (or null). */
export function tokenOf(claim, jobId) {
  return claim?.jobs?.find((j) => j.job_id === jobId)?.lease_token ?? null;
}

/** True when two claim answers lease no job twice. */
export function disjoint(a, b) {
  const ids = new Set((a?.jobs ?? []).map((j) => j.job_id));
  return (b?.jobs ?? []).every((j) => !ids.has(j.job_id));
}

/** A system credential of the local environment (only its digest is registered). */
export const newCredential = () => `sysc_local_${randomBytes(32).toString('base64url')}`;

/** A well-formed scheduler trigger that is not the configured one. */
export const newTrigger = () => `nwt_${randomBytes(32).toString('hex')}`;

async function main() {
  const { log, check, finish } = startRun();
  const keys = localKey();
  const { origin, key } = keys;
  const http = localHttp(keys);
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const reminder = (token, cmd, expected, payload) =>
    rpc('fixture_reminder_command', token, { version: 1, command: cmd, request_id: randomUUID(), expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const inboxCount = async (token) => (await rpc('notifications_my_inbox', token)).json?.items?.length ?? null;
  const utc = (ms) => new Date(ms).toISOString();
  const sys = async (credential, command, payload) => {
    const res = await fetch(`${origin}/rest/v1/rpc/system_command`, {
      method: 'POST',
      headers: { apikey: key, 'Content-Type': 'application/json', 'Content-Profile': 'api', 'x-system-credential': credential },
      body: JSON.stringify({ version: 1, command, request_id: randomUUID(), payload }),
    });
    const json = await res.json().catch(() => null);
    return json?.data ?? { code: json?.code ?? `http_${res.status}` };
  };
  const edge = async (trigger, body = { action: 'run' }) => {
    const headers = { 'Content-Type': 'application/json' };
    if (trigger !== undefined) headers['x-worker-trigger'] = trigger;
    const res = await fetch(`${origin}${FN}`, { method: 'POST', headers, body: JSON.stringify(body) });
    const text = await res.text();
    edgeOut.push(text);
    let json = null;
    try { json = JSON.parse(text); } catch { /* not JSON */ }
    return { status: res.status, json };
  };
  const edgeOut = [];

  const people = { a: { phone: '+447700900870', name: `${NAME_PREFIX} Member A` } };
  for (const p of Object.values(people)) if (!isFictionalWorkerPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  const users = new Set();
  const digits = Object.values(people).map((p) => `'${p.phone.slice(1)}'`).join(',');
  const cleanup = () => {
    const ids = [...users].map((u) => `'${u}'`);
    const byUser = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    return psql(`
    create temp table gone_users as select u.id from auth.users u where ${byUser} u.phone in (${digits});
    create temp table gone_members as
      select m.member_id from app.identity_members m where m.display_name like '${NAME_PREFIX}%';
    delete from app.notifications_attempts a using app.notifications_jobs j
     where a.job_id = j.job_id and j.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_inbox_items i where i.recipient_member_id in (select member_id from gone_members);
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
  const resetScheduler = () => psql(`
    select app.notifications_scheduler_disable('${OPERATOR}');
    delete from vault.secrets where name in ('notifications_worker_trigger', 'notifications_worker_credential');
    select app.notifications_configure_worker('${JSON.stringify(DEFAULT_POLICY)}', '${OPERATOR}');`);

  const settings = await http('GET', '/auth/v1/settings');
  if (settings.json?.external?.phone !== true) {
    throw new Error('the local phone provider is off: run `node tools/auth-harness/local-phone-auth.mjs on` first');
  }
  const marker = psql(`select coalesce((select environment from app.platform_environment), '')`);
  let marked = false;
  if (marker === '') {
    psql(`select app.platform_set_environment('local', 'notifications-worker-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('W00-precondition', { leftover_users_removed: cleanup(), scheduler_reset: true, reset: resetScheduler() !== null });

  const run = randomUUID().slice(0, 8);
  const principals = [];
  const credentials = [];
  const revokedCredentials = new Set();
  const mint = (name, purpose) => {
    const credential = newCredential();
    const principal = psql(`select app.sys_create_principal('${name}-${run}', '${purpose}', '${OPERATOR}')`);
    const id = JSON.parse(psql(`select app.sys_register_credential('${principal}',
      '${createHash('sha256').update(credential).digest('hex')}', 'worker e2e ${run}', interval '2 hours', '${OPERATOR}')`)).credential_id;
    principals.push(principal);
    credentials.push(id);
    return credential;
  };
  const w1 = mint('notifications-worker-e2e-a', 'notifications_worker');
  const w2 = mint('notifications-worker-e2e-b', 'notifications_worker');
  const probe = mint('worker-e2e-probe', 'synthetic_probe');

  // The scheduler trigger is generated into Vault by the operator function; like the owner, the
  // run copies it (and the worker credential) into the function's secrets, here a 0600 env file.
  psql(`select app.notifications_scheduler_new_trigger('${OPERATOR}')`);
  const trigger = psql(`select decrypted_secret from vault.decrypted_secrets where name = 'notifications_worker_trigger'`);
  const work = mkdtempSync(join(tmpdir(), 'worker-e2e-'));
  const envFile = join(work, 'functions.env');
  writeFileSync(envFile, `NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL=${w1}\nNOTIFICATIONS_WORKER_TRIGGER=${trigger}\n`, { mode: 0o600 });
  let serveLog = '';
  const serve = spawn('npx', ['supabase', 'functions', 'serve', '--env-file', envFile], { stdio: ['ignore', 'pipe', 'pipe'], detached: true });
  serve.stdout.on('data', (d) => { serveLog += d; });
  serve.stderr.on('data', (d) => { serveLog += d; });

  const job = (sourceId) => psql(`select job_id from app.notifications_jobs where source_id = '${sourceId}' and job_state = 'pending'
    order by enqueued_at desc limit 1`);
  const state = (jobId) => psql(`select job_state || '|' || coalesce(finish_reason, cancel_reason, '-') from app.notifications_jobs where job_id = '${jobId}'`);
  const outcomes = (jobId) => psql(`select coalesce(string_agg(outcome, ',' order by attempted_at, attempt_id), '')
    from app.notifications_attempts where job_id = '${jobId}'`);
  const items = (jobId) => Number(psql(`select count(*) from app.notifications_inbox_items where job_id = '${jobId}'`));

  try {
    const deadline = Date.now() + 90_000;
    for (;;) {
      const probeStatus = await fetch(`${origin}${FN}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' })
        .then((r) => r.status).catch(() => 0);
      if (probeStatus === 401) break;
      if (Date.now() > deadline) throw new Error('the Edge Function did not start (is the edge-runtime image present?)');
      await sleep(1500);
    }
    const { a } = people;
    a.password = password();
    const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: a.phone, phone_confirm: true, password: a.password } });
    a.user = created.json?.id;
    users.add(a.user);
    a.member = psql(`select app.identity_seed_synthetic_link('${a.user}', '${a.name}', 'notifications-worker-e2e')`);
    a.token = (await signIn(a.phone, a.password)).json?.access_token;
    check('W01-member-signed-in-by-phone', amrMethods(a.token).includes('password'), { amr: amrMethods(a.token) });
    const due = async (offsetMs = -60_000) => {
      const r = await reminder(a.token, 'fixture.reminder_create', null, { due_at: utc(Date.now() + offsetMs) });
      return { source: r.data?.source_id, job: job(r.data?.source_id), revision: r.revision };
    };

    // ------------------------------------------------------------------ Edge authentication
    const runsBefore = Number(psql(`select count(*) from app.notifications_worker_runs`));
    const noTrigger = await edge(undefined);
    const malformed = await edge('nwt_short');
    const wrong = await edge(newTrigger());
    const credentialAsTrigger = await edge(w1);
    const probeAsTrigger = await edge(probe);
    const runsAfter = Number(psql(`select count(*) from app.notifications_worker_runs`));
    check('W02-edge-runs-only-for-the-trigger', [noTrigger, malformed, wrong, credentialAsTrigger, probeAsTrigger]
      .every((r) => r.status === 401) && runsAfter === runsBefore,
      { none: noTrigger.status, malformed: malformed.status, wrong: wrong.status, credential: credentialAsTrigger.status,
        other_credential: probeAsTrigger.status, claims_started: runsAfter - runsBefore });

    // ------------------------------------------------------------------ two workers, one batch
    const batch = [];
    for (let i = 0; i < 4; i++) batch.push(await due(-60_000 - i));
    const [c1, c2] = await Promise.all([sys(w1, 'notifications.claim', { limit: 3 }), sys(w2, 'notifications.claim', { limit: 3 })]);
    const raced = [];
    for (const [cred, c] of [[w1, c1], [w2, c2]]) {
      for (const j of c.jobs ?? []) raced.push((await sys(cred, 'notifications.attempt', j)).outcome);
    }
    const racedItems = batch.reduce((n, b) => n + items(b.job), 0);
    check('W10-racing-claims-are-disjoint', c1.claimed + c2.claimed === 4 && disjoint(c1, c2)
      && raced.length === 4 && raced.every((o) => o === 'delivered') && racedItems === 4 && await inboxCount(a.token) === 4,
      { claimed: [c1.claimed, c2.claimed], disjoint: disjoint(c1, c2), outcomes: raced, items: racedItems });

    // ------------------------------------------------------------------ killed mid-lease
    // The lease is at least 30 s; the run lets it lapse by moving its end into the past.
    const k = await due();
    const k1 = await sys(w1, 'notifications.claim', {});
    psql(`update app.notifications_jobs set lease_expires_at = now() - interval '1 second' where job_id = '${k.job}'`);
    const k2 = await sys(w2, 'notifications.claim', {});
    const late = await sys(w1, 'notifications.attempt', { job_id: k.job, lease_token: tokenOf(k1, k.job) });
    const won = await sys(w2, 'notifications.attempt', { job_id: k.job, lease_token: tokenOf(k2, k.job) });
    check('W20-killed-worker-reclaimed-and-fenced', k2.reclaimed === 1 && tokenOf(k2, k.job) > tokenOf(k1, k.job)
      && late.outcome === 'fenced' && won.outcome === 'delivered' && items(k.job) === 1
      && outcomes(k.job) === 'lapsed,fenced,delivered',
      { reclaimed: k2.reclaimed, higher_token: tokenOf(k2, k.job) > tokenOf(k1, k.job), late: late.outcome, winner: won.outcome,
        attempts: outcomes(k.job), items: items(k.job) });
    const stale = await sys(w2, 'notifications.attempt', { job_id: k.job, lease_token: tokenOf(k1, k.job) });
    check('W21-stale-token-fenced', stale.outcome === 'fenced' && items(k.job) === 1, { outcome: stale.outcome });

    // ------------------------------------------------------------------ rechecks after the claim
    const cancel = await due();
    const revised = await due();
    const revoked = await due();
    const expiring = await due();
    const cr = await sys(w1, 'notifications.claim', {});
    const cancelled = await reminder(a.token, 'fixture.reminder_cancel', cancel.revision, { source_id: cancel.source });
    psql(`update app.fixture_reminder_sources set revision = revision + 1 where source_id = '${revised.source}';
          update app.fixture_reminder_sources set recipient_revoked = true where source_id = '${revoked.source}';
          update app.notifications_jobs set expires_at = now() - interval '1 second' where job_id = '${expiring.job}';`);
    const attempt = (j) => sys(w1, 'notifications.attempt', { job_id: j.job, lease_token: tokenOf(cr, j.job) });
    const r = {
      cancelled: await attempt(cancel), revised: await attempt(revised), revoked: await attempt(revoked), expired: await attempt(expiring),
    };
    check('W30-cancelled-after-claim-never-dispatched', cancelled.status === 200 && r.cancelled.outcome === 'cancelled'
      && state(cancel.job) === 'cancelled|source_cancelled' && items(cancel.job) === 0,
      { outcome: r.cancelled.outcome, state: state(cancel.job), items: items(cancel.job) });
    check('W31-revised-after-enqueue-obsolete', r.revised.outcome === 'obsolete' && state(revised.job) === 'obsolete|source_changed'
      && items(revised.job) === 0, { outcome: r.revised.outcome, state: state(revised.job) });
    check('W32-revoked-grant-ineligible', r.revoked.outcome === 'ineligible' && state(revoked.job) === 'ineligible|recipient_ineligible'
      && items(revoked.job) === 0, { outcome: r.revoked.outcome, state: state(revoked.job) });
    const old = await due();
    psql(`update app.notifications_jobs set expires_at = now() - interval '1 second' where job_id = '${old.job}'`);
    const sweep = await sys(w1, 'notifications.claim', {});
    check('W33-expired-jobs-end-expired', r.expired.outcome === 'expired' && state(expiring.job) === 'obsolete|expired'
      && sweep.expired === 1 && sweep.claimed === 0 && state(old.job) === 'obsolete|expired' && items(old.job) + items(expiring.job) === 0,
      { at_attempt: r.expired.outcome, at_claim: { expired: sweep.expired, claimed: sweep.claimed }, states: [state(expiring.job), state(old.job)] });
    check('W34-one-attempt-row-each', [cancel, revised, revoked, expiring].every((j) => outcomes(j.job).split(',').length === 1),
      { attempts: [cancel, revised, revoked, expiring].map((j) => outcomes(j.job)) });

    // ------------------------------------------------------------------ transient failure and retry
    const flaky = await due();
    psql(`update app.fixture_reminder_sources set check_fault_until = now() + interval '1 hour' where source_id = '${flaky.source}'`);
    const f1 = await sys(w1, 'notifications.claim', {});
    const failed = await sys(w1, 'notifications.attempt', { job_id: flaky.job, lease_token: tokenOf(f1, flaky.job) });
    const backingOff = await sys(w2, 'notifications.claim', {});
    psql(`update app.fixture_reminder_sources set check_fault_until = null where source_id = '${flaky.source}';
          update app.notifications_jobs set last_failed_at = now() - interval '61 seconds' where job_id = '${flaky.job}';`);
    const f2 = await sys(w2, 'notifications.claim', {});
    const retried = await sys(w2, 'notifications.attempt', { job_id: flaky.job, lease_token: tokenOf(f2, flaky.job) });
    check('W40-transient-failure-retried-with-backoff', failed.outcome === 'failed' && backingOff.claimed === 0
      && retried.outcome === 'delivered' && outcomes(flaky.job) === 'failed,delivered' && items(flaky.job) === 1
      && psql(`select error_sqlstate from app.notifications_attempts where job_id = '${flaky.job}' and outcome = 'failed'`) === 'P0001',
      { first: failed.outcome, claimed_while_backing_off: backingOff.claimed, retry: retried.outcome, attempts: outcomes(flaky.job) });

    // ------------------------------------------------------------------ the Edge worker runs a batch
    const e1 = await due();
    const e2 = await due();
    const ran = await edge(trigger);
    check('W50-edge-worker-runs-a-batch', ran.status === 200 && ran.json?.claimed === 2 && ran.json?.outcomes?.delivered === 2
      && items(e1.job) === 1 && items(e2.job) === 1 && ran.json?.uncertain === 0,
      { status: ran.status, counts: ran.json });

    // ------------------------------------------------------------------ pg_cron runs it, app closed
    psql(`select app.notifications_configure_worker('{"worker_url": "${IN_NETWORK_URL}"}', '${OPERATOR}')`);
    const enabled = JSON.parse(psql(`select app.notifications_scheduler_enable('${OPERATOR}', '15 seconds')`));
    const cronJob = await due(-1_000);
    let cronItems = 0;
    const cronDeadline = Date.now() + 75_000;
    while (Date.now() < cronDeadline && cronItems === 0) {
      await sleep(2000);
      cronItems = items(cronJob.job);
    }
    const status = JSON.parse(psql(`select app.notifications_scheduler_status()`));
    const command = psql(`select command from cron.job where jobname = 'notifications-worker'`);
    check('W60-cron-runs-the-worker-with-the-app-closed', enabled.scheduler_jobs === 1 && cronItems === 1
      && state(cronJob.job) === 'delivered|delivered' && status.last_tick_outcome === 'sent'
      && command === 'select app.notifications_scheduler_tick()',
      { scheduler_jobs: enabled.scheduler_jobs, schedule: enabled.schedule, delivered: cronItems === 1,
        last_tick_outcome: status.last_tick_outcome, cron_runs: status.cron_runs_24h, command_has_secret: command.includes('sysc_') });
    const disabled = JSON.parse(psql(`select app.notifications_scheduler_disable('${OPERATOR}')`));
    check('W61-scheduler-removed', disabled.scheduler_jobs === 0, { scheduler_jobs: disabled.scheduler_jobs });
    const credentialInDb = Number(psql(`select (select count(*) from net.http_request_queue q where q.headers::text like '%sysc_%')
      + (select count(*) from vault.decrypted_secrets s where s.decrypted_secret like 'sysc_%')
      + (select count(*) from cron.job j where j.command like '%sysc_%' or j.command like '%nwt_%')`));
    check('W62-credential-never-in-the-database', credentialInDb === 0, { places_holding_a_credential: credentialInDb });

    // ------------------------------------------------------------------ a revoked credential is refused
    psql(`select app.sys_revoke_credential('${credentials[0]}', '${OPERATOR}')`);
    revokedCredentials.add(credentials[0]);
    const refused = await edge(trigger);
    check('W63-revoked-worker-credential-refused', refused.status === 403 && refused.json?.outcome === 'refused',
      { status: refused.status, outcome: refused.json?.outcome });

    // ------------------------------------------------------------------ content-free outputs
    const secrets = [w1, w2, probe, trigger, a.member, a.user, a.phone.slice(1), batch[0].job, batch[0].source];
    const out = edgeOut.join('\n');
    const leakedOut = secrets.filter((v) => out.includes(v)).length;
    const leakedLog = secrets.filter((v) => serveLog.includes(v)).length;
    const statusText = JSON.stringify(status);
    check('W70-edge-and-status-content-free', leakedOut === 0 && leakedLog === 0
      && !secrets.some((v) => statusText.includes(v)) && serveLog.includes('"fn":"notifications-worker"'),
      { leaked_in_responses: leakedOut, leaked_in_function_log: leakedLog,
        function_log_lines: (serveLog.match(/"fn":"notifications-worker"/g) ?? []).length });
  } finally {
    try { process.kill(-serve.pid, 'SIGINT'); } catch { /* already gone */ }
    await sleep(3000);
    try { process.kill(-serve.pid, 'SIGKILL'); } catch { /* already gone */ }
    try { execFileSync('docker', ['rm', '-f', 'supabase_edge_runtime_church-app'], { stdio: 'ignore' }); } catch { /* not running */ }
    rmSync(work, { recursive: true, force: true });
    resetScheduler();
    const left = cleanup();
    for (const id of credentials) if (!revokedCredentials.has(id)) psql(`select app.sys_revoke_credential('${id}', '${OPERATOR}')`);
    for (const p of principals) {
      psql(`select app.sys_disable_principal('${p}', '${OPERATOR}');
            delete from app.notifications_worker_runs where principal_id = '${p}';`);
    }
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'notifications-worker-e2e';
            delete from app.platform_environment_history where set_by = 'notifications-worker-e2e';`);
    }
    log('W99-cleanup', { users_left: Number(left), credentials_revoked: credentials.length, principals_disabled: principals.length,
      unmarked: marked, jobs_left: Number(psql(`select count(*) from app.notifications_jobs`)),
      attempts_left: Number(psql(`select count(*) from app.notifications_attempts`)),
      cron_jobs_left: Number(psql(`select count(*) from cron.job`)),
      vault_secrets_left: Number(psql(`select count(*) from vault.secrets
        where name in ('notifications_worker_trigger', 'notifications_worker_credential')`)),
      env_file_removed: true });
  }
  finish();
}

runMain(import.meta.url, main);
