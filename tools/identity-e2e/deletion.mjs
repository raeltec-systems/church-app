#!/usr/bin/env node
// Story 2.11 end-to-end on the LOCAL stack: delete a member fully through a resumable workflow,
// through real GoTrue (phone sign-in without SMS), the real Data API, the 1.9 system route, the
// real worker (tools/identity-deletion/worker.mjs), the Edge Function identity-deletion served by
// `supabase functions serve` (started and stopped here) and the 1.10 recovery journal:
//   * the last usable Admin cannot delete their own account;
//   * a member deletes their account in the app: both devices are denied at once and a password
//     sign-in fails at Auth from that first step;
//   * the worker is interrupted (--max-steps), resumed after a crash between a journal append and
//     its acknowledgement (no duplicate entry), after the Edge Function was unreachable, and after
//     the Auth user had already gone (idempotent retry); every step's attempts and outcome are
//     recorded; completion comes only after every store is checked; a second run changes nothing;
//   * an Admin deletes an accountless member on the staff route (no account steps), and is refused
//     for a member who can use the app;
//   * the journal holds only opaque identifiers, and the database acknowledgements match it;
//   * a backup taken BEFORE a member's deletion, restored into an isolated database after the
//     deletion completed, lands held (private access closed); reconciling it replays the deletion
//     (the member's data and a simulated restored Auth row are erased) before the hold lifts.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on` (no SMS
// provider, hook, test OTP or SMS MFA), then `off` afterwards, the edge-runtime image, and a
// database with no usable Admin (`npx supabase db reset` first). LOCAL only (exact origin),
// SYNTHETIC fictional numbers +44 7700 900620-900639. Evidence is redacted JSONL: statuses, codes,
// counts and booleans; never tokens, passwords, numbers or names. Everything it created in the
// database is removed except the append-only journal acknowledgements (the journal itself is
// append-only); the run's credential is revoked and its principal disabled.
//
// Usage: node tools/identity-e2e/deletion.mjs [--evidence <file.jsonl>]
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { appendFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { LocalSegmentJournal, validateEntry, verifyJournal } from '../recovery/journal.mjs';
import { requestCode } from './lifecycle.mjs';
import { amrMethods, assertLocalOrigin, redact } from './run.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const FN = '/functions/v1/identity-deletion';
const ISOLATED = 'bic-deletion-isolated';
const NAME_PREFIX = 'SYNTHETIC 2.11 E2E';
const OPERATOR = 'israel';
const EPOCH_WAIT_MS = 6500; // the 2.2 trust-epoch margin is 5 s

/** The reserved fictional numbers this run uses (+44 7700 900620-900639). */
export function isFictionalDeletionPhone(phone) {
  return /^\+4477009006[23][0-9]$/.test(phone);
}

/** Journal entry keys are exactly those of its kind, and every value is opaque. */
export function opaqueEntryProblems(entry, forbidden = []) {
  const problems = validateEntry(entry);
  const text = JSON.stringify(entry);
  for (const f of forbidden) if (f && text.includes(f)) problems.push('carries a forbidden value');
  return problems;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function localKey() {
  const env = execFileSync('npx', ['supabase', 'status', '-o', 'env'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  const url = /^API_URL="([^"]+)"/m.exec(env)?.[1];
  const key = /^PUBLISHABLE_KEY="([^"]+)"/m.exec(env)?.[1];
  const secret = /^SECRET_KEY="([^"]+)"/m.exec(env)?.[1];
  const service = /^SERVICE_ROLE_KEY="([^"]+)"/m.exec(env)?.[1];
  if (!url || !key || !secret || !service) throw new Error('local stack is not running');
  return { origin: assertLocalOrigin(url), key, secret, service };
}

const dbContainer = () => execFileSync('docker', ['ps', '--filter', 'name=supabase_db_', '--format', '{{.Names}}'], { encoding: 'utf8' }).trim().split('\n')[0];
function psqlIn(container, db, sql) {
  return execFileSync('docker', ['exec', '-i', container, 'psql', '-U', 'postgres', '-d', db, '-X', '-qtA', '-v', 'ON_ERROR_STOP=1'],
    { input: sql, encoding: 'utf8', maxBuffer: 256 << 20 }).trim();
}
const psql = (sql) => psqlIn(dbContainer(), 'postgres', sql);
const jsonLiteral = (v) => {
  const t = JSON.stringify(v);
  if (t.includes('$j$')) throw new Error('unquotable');
  return `$j$${t}$j$::jsonb`;
};

async function main() {
  const evidenceIdx = process.argv.indexOf('--evidence');
  const evidence = evidenceIdx > 0 ? process.argv[evidenceIdx + 1] : null;
  if (evidence) writeFileSync(evidence, '');
  const { origin, key, secret, service } = localKey();
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
  async function http(method, path, { token, body, profile, admin, headers: extra } = {}) {
    const headers = { apikey: admin ? secret : key, 'Content-Type': 'application/json', ...(extra ?? {}) };
    if (admin) headers.Authorization = `Bearer ${service}`;
    else if (token) headers.Authorization = `Bearer ${token}`;
    if (profile) headers[method === 'GET' ? 'Accept-Profile' : 'Content-Profile'] = profile;
    const res = await fetch(`${origin}${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
    const text = await res.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { /* non-JSON */ }
    return { status: res.status, json };
  }
  const password = () => `Synthetic-${randomBytes(12).toString('base64url')}`;
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const refresh = (rt) => http('POST', '/auth/v1/token?grant_type=refresh_token', { body: { refresh_token: rt } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const envelope = (fn, token, cmd, expected, payload) =>
    rpc(fn, token, { version: 1, command: cmd, request_id: randomUUID(), expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const summary = async (token) => (await rpc('identity_my_member_summary', token)).status;

  const people = {
    admin: { phone: '+447700900620', name: `${NAME_PREFIX} Admin A` },
    admin2: { phone: '+447700900621', name: `${NAME_PREFIX} Admin B` },
    leaving: { phone: '+447700900622', name: `${NAME_PREFIX} Leaving`, email: 'synthetic-2-11-leaving@example.test' },
    leavingOld: { phone: '+447700900627', name: `${NAME_PREFIX} Leaving` },
    leavingNext: { phone: '+447700900626', name: `${NAME_PREFIX} Leaving` },
    app: { phone: '+447700900623', name: `${NAME_PREFIX} App user` },
    restored: { phone: '+447700900624', name: `${NAME_PREFIX} Restored` },
    accountless: { phone: '+447700900625', name: `${NAME_PREFIX} Accountless` },
  };
  for (const p of Object.values(people)) {
    if (!isFictionalDeletionPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  }
  const users = new Set();
  const members = new Set();
  const digits = Object.values(people).map((p) => `'${p.phone.slice(1)}'`).join(',');
  const LIFECYCLE_EVENTS = ['membership_deactivated', 'deletion_requested', 'sessions_revoked', 'member_deleted', 'scope_revoked'];
  const unhook = () => psql(`
    delete from app.contract_lifecycle_hooks where module = 'fixture'
       and event in (${LIFECYCLE_EVENTS.map((e) => `'${e}'`).join(',')});
    delete from app.identity_deletion_hooks where module = 'fixture';`);
  const cleanup = () => {
    const ids = [...users].map((u) => `'${u}'`);
    const byUser = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    const mids = [...members].map((m) => `'${m}'`);
    return psql(`
    create temp table gone_users as select u.id from auth.users u where ${byUser} u.phone in (${digits});
    create temp table gone_members as
      select m.member_id from app.identity_members m
       where m.display_name like '${NAME_PREFIX}%' ${mids.length ? `or m.member_id in (${mids.join(',')})` : ''};
    create temp table gone_cells as select c.cell_id from app.cells_cells c where c.name like '${NAME_PREFIX}%';
    create temp table gone_deletions as
      select d.deletion_id from app.identity_deletions d where d.member_id in (select member_id from gone_members);
    delete from app.identity_deletion_audit a where a.deletion_id in (select deletion_id from gone_deletions);
    delete from app.identity_deletion_steps s where s.deletion_id in (select deletion_id from gone_deletions);
    delete from app.identity_deletion_accounts a where a.deletion_id in (select deletion_id from gone_deletions);
    delete from app.identity_deletion_aggregates a where a.deletion_id in (select deletion_id from gone_deletions);
    delete from app.identity_deletions d where d.deletion_id in (select deletion_id from gone_deletions);
    delete from app.fixture_lifecycle_calls c where c.member_id in (select member_id from gone_members);
    delete from app.fixture_duties d where d.member_id in (select member_id from gone_members);
    delete from app.identity_handover_obligations o where o.member_id in (select member_id from gone_members);
    delete from app.identity_membership_lifecycle e
     where e.member_id in (select member_id from gone_members) or e.actor_member_id in (select member_id from gone_members);
    delete from app.identity_recovery_operations o where o.member_id in (select member_id from gone_members);
    delete from app.identity_member_provenance p
     where p.member_id in (select member_id from gone_members) or p.recorded_by_member in (select member_id from gone_members);
    delete from app.identity_recovery_grants g where g.member_id in (select member_id from gone_members);
    delete from app.identity_recovery_cases c where c.member_id in (select member_id from gone_members);
    delete from app.identity_credential_changes c where c.member_id in (select member_id from gone_members);
    delete from app.identity_recovery_email_proposals p where p.member_id in (select member_id from gone_members);
    delete from app.identity_phone_reclaims r where r.released_account_id in (select id from gone_users)
       or r.actor_member_id in (select member_id from gone_members);
    delete from app.identity_application_events e using app.identity_membership_applications a
     where e.application_id = a.application_id and (a.member_id in (select member_id from gone_members) or a.auth_user_id in (select id from gone_users));
    delete from app.identity_membership_applications a
     where a.member_id in (select member_id from gone_members) or a.auth_user_id in (select id from gone_users);
    delete from app.identity_recovery_requests r where r.claimed_phone in (${Object.values(people).map((p) => `'${p.phone}'`).join(',')});
    delete from app.identity_recovery_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_membership_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_member_provenance p
     where p.member_id in (select member_id from gone_members) or p.recorded_by_member in (select member_id from gone_members);
    delete from app.identity_contact_routes c
     where c.member_id in (select member_id from gone_members) or c.created_by_member in (select member_id from gone_members);
    delete from app.identity_credential_review_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.cells_membership_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members)
        or a.cell_id in (select cell_id from gone_cells);
    with gone_memberships as (
      delete from app.cells_memberships m
       where m.member_id in (select member_id from gone_members) or m.cell_id in (select cell_id from gone_cells)
      returning m.membership_id)
    delete from app.cells_membership_requests r
     where r.member_id in (select member_id from gone_members) or r.requested_cell_id in (select cell_id from gone_cells);
    delete from app.cells_member_states s where s.member_id in (select member_id from gone_members);
    delete from app.cells_signup_options o where o.cell_id in (select cell_id from gone_cells);
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
    delete from app.cells_cells c where c.cell_id in (select cell_id from gone_cells);
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
    psql(`select app.platform_set_environment('local', 'identity-deletion-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  const leftovers = cleanup();
  if (Number(psql(`select app.identity_usable_admin_count()`)) !== 0) {
    throw new Error('the local database already has a usable Admin; run `npx supabase db reset` first');
  }
  if (Number(psql(`select count(*) from app.identity_deletions`)) !== 0) {
    throw new Error('the local database already holds deletions; run `npx supabase db reset` first');
  }

  // The run's system principal and credential (only the digest is registered).
  const run = randomUUID().slice(0, 8);
  const credential = `sysc_local_${randomBytes(32).toString('base64url')}`;
  const principal = psql(`select app.sys_create_principal('identity-deletion-e2e-${run}', 'identity_deletion', '${OPERATOR}')`);
  const credentialId = JSON.parse(psql(`select app.sys_register_credential('${principal}',
    '${createHash('sha256').update(credential).digest('hex')}', 'deletion e2e ${run}', interval '2 hours', '${OPERATOR}')`)).credential_id;
  const stateDir = resolve(process.env.RECOVERY_STATE_DIR ?? join(ROOT, '.recovery-state'));
  const journalDir = join(stateDir, 'journal');
  const journal = new LocalSegmentJournal(journalDir);
  const work = mkdtempSync(join(tmpdir(), 'deletion-e2e-'));
  let serveLog = '';
  const serve = spawn('npx', ['supabase', 'functions', 'serve'], { stdio: ['ignore', 'pipe', 'pipe'], detached: true });
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
  // The real worker, as an operator runs it.
  const worker = (args) => {
    const r = spawnSync('node', [join(ROOT, 'tools/identity-deletion/worker.mjs'), 'run', '--journal-dir', journalDir, ...args], {
      encoding: 'utf8',
      env: { ...process.env, SUPABASE_URL: origin, SUPABASE_PUBLISHABLE_KEY: key, IDENTITY_DELETION_SYSTEM_CREDENTIAL: credential },
    });
    const lines = (r.stdout ?? '').split('\n').filter((l) => l.startsWith('{')).map((l) => JSON.parse(l));
    return { exit: r.status, lines, result: lines.filter((l) => l.result).pop() ?? null, stderr: (r.stderr ?? '').trim().slice(-200) };
  };
  const steps = (deletionId) => JSON.parse(psql(`select coalesce(json_object_agg(step, json_build_object('state', step_state, 'attempts', attempts, 'outcome', outcome)), '{}')
      from app.identity_deletion_steps where deletion_id = '${deletionId}'`));
  let isolated = false;

  try {
    const deadline = Date.now() + 90_000;
    for (;;) {
      const probe = await fetch(`${origin}${FN}`, { method: 'POST', headers: { apikey: key, 'Content-Type': 'application/json' }, body: '{}' })
        .then((r) => r.status).catch(() => 0);
      if (probe === 401) break;
      if (Date.now() > deadline) throw new Error('the Edge Function did not start (is the edge-runtime image present?)');
      await sleep(1000);
    }
    log('D00-precondition', { settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
      leftover_users_removed: leftovers, function_served: true, verify_jwt: false,
      journal_entries_before: ((await journal.list()) ?? []).length });

    psql(`${LIFECYCLE_EVENTS.map((e) => `select app.contract_register_lifecycle_hook('fixture', '${e}', 'app.fixture_record_lifecycle(jsonb)'::regprocedure);`).join('\n')}
          select app.identity_register_deletion_hook('fixture', 'app.fixture_erase_member(jsonb)'::regprocedure);`);
    const seeded = async (p) => {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'identity-deletion-e2e')`);
      members.add(p.member);
      return created.status;
    };
    const memberRev = (p) => Number(psql(`select revision from app.identity_members where member_id = '${p.member}'`));
    const deletionOf = (p) => psql(`select coalesce((select deletion_id::text from app.identity_deletions where member_id = '${p.member}'), '')`);
    const personal = (p) => Number(psql(`select
        (select count(*) from app.identity_account_links where member_id = '${p.member}' or auth_user_id = ${p.user ? `'${p.user}'` : 'null'})
      + (select count(*) from app.identity_contact_routes where member_id = '${p.member}')
      + (select count(*) from app.identity_member_provenance where member_id = '${p.member}')
      + (select count(*) from app.identity_holds where member_id = '${p.member}')
      + (select count(*) from app.cells_memberships where member_id = '${p.member}')
      + (select count(*) from app.cells_membership_requests where member_id = '${p.member}')
      + (select count(*) from app.cells_member_states where member_id = '${p.member}')
      + (select count(*) from app.identity_members where member_id = '${p.member}' and display_name <> 'Deleted member')`));
    const mine = (token) => envelope('identity_deletion_command', token, 'identity.request_my_deletion', null, { confirm: 'delete_my_account' });
    const staffDelete = (token, p) => envelope('identity_deletion_command', token, 'identity.request_member_deletion', memberRev(p),
      { member_id: p.member, identity_check: 'in_person' });
    const giveCell = async (adminToken, p, label) => {
      const cx = await envelope('cells_command', adminToken, 'cells.create_cell', null,
        { name: `${NAME_PREFIX} ${label}`, signup_label: `${NAME_PREFIX} ${label}`, broad_area: 'SYNTHETIC North' });
      const option = ((await rpc('cells_signup_options', adminToken)).json?.options ?? []).find((o) => o.cell_id === cx.data?.cell_id);
      // An application's "not sure" choice is already an open request (the Admin follow-up
      // queue): the Admin names the cell. Otherwise the Admin asks for one and confirms it.
      const follow = ((await rpc('cells_admin_overview', adminToken)).json?.requests ?? []).find((r) => r.member_id === p.member);
      let asked = { revision: follow?.member_revision, data: { open_request: { request_id: follow?.request_id } } };
      if (!follow) {
        asked = await envelope('cells_command', adminToken, 'cells.request_change', 1,
          { cell_id: cx.data?.cell_id, cell_revision: option?.revision, member_id: p.member });
      }
      const confirmed = await envelope('cells_command', adminToken, 'cells.confirm_request', asked.revision,
        { request_id: asked.data?.open_request?.request_id, ...(follow ? { cell_id: cx.data?.cell_id } : {}) });
      return Boolean(confirmed.data?.primary);
    };

    // ------------------------------------------------------------------- the last usable Admin
    const { admin, admin2, leaving, app: appUser, restored, accountless } = people;
    await seeded(admin);
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    admin.token = (await signIn(admin.phone, admin.password)).json?.access_token;
    const lastAdmin = await mine(admin.token);
    check('D01-last-usable-admin-cannot-delete-their-account', amrMethods(admin.token).includes('password')
      && lastAdmin.code === 'forbidden' && lastAdmin.field_errors?.member_id === 'last_admin' && deletionOf(admin) === '',
      { code: lastAdmin.code, field_errors: lastAdmin.field_errors });
    await seeded(admin2);
    const b0 = await rpc('identity_my_access', (await signIn(admin2.phone, admin2.password)).json?.access_token);
    await envelope('identity_grant_command', admin.token, 'identity.grant_role', b0.json?.revision, { member_id: admin2.member, role: 'admin' });
    admin2.token = (await signIn(admin2.phone, admin2.password)).json?.access_token;

    // ------------------------------------------- in-app deletion: denied from the first step
    // The member's history, through the real flows: an earlier account (linked, then unlinked as
    // lost, its number reclaimed), a new account that applies and is linked to the same member,
    // a staff-assisted recovery case and grant, a withdrawn sign-in change, a recovery-email
    // proposal with Auth's pending email change, a confirmed cell, a role.
    const old = people.leavingOld;
    old.password = password();
    const oldUser = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: old.phone, phone_confirm: true, password: old.password } });
    old.user = oldUser.json?.id;
    users.add(old.user);
    leaving.member = psql(`select app.identity_seed_synthetic_link('${old.user}', '${leaving.name}', 'identity-deletion-e2e')`);
    members.add(leaving.member);
    const unlinked = await envelope('identity_review_command', admin.token, 'identity.unlink_account', memberRev(leaving),
      { member_id: leaving.member, reason: 'account_lost' });
    const reclaimed = await envelope('identity_review_command', admin.token, 'identity.reclaim_phone_username', null,
      { phone_username: old.phone, identity_check: 'in_person', reason: 'registered_by_someone_else' });
    leaving.password = password();
    const up = await http('POST', '/auth/v1/signup', { body: { phone: leaving.phone, password: leaving.password } });
    leaving.user = up.json?.user?.id;
    users.add(leaving.user);
    const applied = await envelope('identity_application_command', up.json?.access_token, 'identity.submit_application', null,
      { full_name: leaving.name, cell_choice: { choice: 'not_sure' }, privacy_notice_version: 'draft-2026-10-07' });
    const linked = await envelope('identity_review_command', admin.token, 'identity.link_application', applied.revision,
      { application_id: applied.data?.application_id, member_id: leaving.member, identity_check: 'in_person' });
    await sleep(EPOCH_WAIT_MS);
    leaving.token = (await signIn(leaving.phone, leaving.password)).json?.access_token;
    const l0 = await rpc('identity_my_access', leaving.token);
    const pastor = await envelope('identity_grant_command', admin.token, 'identity.grant_role', l0.json?.revision,
      { member_id: leaving.member, role: 'pastor' });
    const code = requestCode();
    psql(`insert into app.identity_recovery_requests (request_code, claimed_phone, grant_digest, expires_at)
          values ('${code}', '${leaving.phone}', '${createHash('sha256').update(randomBytes(32)).digest('hex')}', now() + interval '30 minutes')`);
    const opened = await envelope('identity_recovery_command', admin.token, 'identity.open_recovery_case', null,
      { member_id: leaving.member, identity_check: 'in_person', evidence: ['photo_id'] });
    const issued = await envelope('identity_recovery_command', admin.token, 'identity.issue_recovery_grant', opened.revision,
      { case_id: opened.data?.case_id, request_code: code });
    const change = await envelope('identity_credential_command', leaving.token, 'identity.request_credential_change', null,
      { change_kind: 'phone_username', phone_username: people.leavingNext.phone });
    const withdrawn = await envelope('identity_credential_command', leaving.token, 'identity.withdraw_credential_change', change.revision,
      { change_id: change.data?.change_id });
    const proposed = await envelope('identity_recovery_email_command', leaving.token, 'identity.propose_recovery_email', null,
      { email: leaving.email });
    const emailChange = await http('PUT', '/auth/v1/user', { token: leaving.token, body: { email: leaving.email } });
    const hasCell = await giveCell(admin.token, leaving, 'North cell');
    const seededStores = JSON.parse(psql(`select json_build_object(
      'links', (select count(*) from app.identity_account_links where member_id = '${leaving.member}'),
      'applications', (select count(*) from app.identity_membership_applications where member_id = '${leaving.member}'),
      'application_events', (select count(*) from app.identity_application_events e join app.identity_membership_applications a using (application_id) where a.member_id = '${leaving.member}'),
      'binding_history', (select count(*) from app.identity_binding_history h join app.identity_account_links l using (link_id) where l.member_id = '${leaving.member}'),
      'credential_events', (select count(*) from app.identity_credential_events e join app.identity_account_links l using (link_id) where l.member_id = '${leaving.member}'),
      'reclaims', (select count(*) from app.identity_phone_reclaims where released_account_id = '${old.user}'),
      'recovery_requests', (select count(*) from app.identity_recovery_requests where request_code = '${code}'),
      'recovery_cases', (select count(*) from app.identity_recovery_cases where member_id = '${leaving.member}'),
      'recovery_grants', (select count(*) from app.identity_recovery_grants where member_id = '${leaving.member}'),
      'credential_changes', (select count(*) from app.identity_credential_changes where member_id = '${leaving.member}'),
      'proposals', (select count(*) from app.identity_recovery_email_proposals where member_id = '${leaving.member}'),
      'one_time_tokens', (select count(*) from auth.one_time_tokens where user_id = '${leaving.user}'),
      'admin_receipts', (select count(*) from app.cmd_receipts where actor_id = '${admin.user}' and result::text like '%${NAME_PREFIX} Leaving%'))`));
    // GoTrue's own audit log is not written on this stack; a SYNTHETIC entry stands in for one.
    const auditWritten = Number(psql(`select count(*) from auth.audit_log_entries where payload ->> 'actor_id' in ('${leaving.user}', '${old.user}')`));
    if (auditWritten === 0) {
      psql(`insert into auth.audit_log_entries (id, payload, created_at)
            values (gen_random_uuid(), json_build_object('actor_id', '${leaving.user}', 'action', 'login', 'actor_username', '${leaving.phone.slice(1)}'), now()),
                   (gen_random_uuid(), json_build_object('actor_id', '${admin.user}', 'action', 'user_modified', 'traits', json_build_object('user_id', '${old.user}', 'user_phone', '${old.phone.slice(1)}')), now())`);
    }
    const mobile = (await signIn(leaving.phone, leaving.password)).json;
    const web = (await signIn(leaving.phone, leaving.password)).json;
    const before = [await summary(mobile?.access_token), await summary(web?.access_token)];
    const requested = await mine(mobile?.access_token);
    leaving.deletion = deletionOf(leaving);
    const devices = [];
    for (const d of [mobile, web]) devices.push({ summary: await summary(d?.access_token), refresh: (await refresh(d?.refresh_token)).status });
    const freshTry = await signIn(leaving.phone, leaving.password);
    const accounts = JSON.parse(psql(`select coalesce(json_agg(auth_user_id order by account_no), '[]') from app.identity_deletion_accounts where deletion_id = '${leaving.deletion}'`));
    // A factor added to the earlier account afterwards must go with it too.
    psql(`insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, secret, created_at, updated_at)
          values (gen_random_uuid(), '${old.user}', 'synthetic', 'totp', 'unverified', 'JBSWY3DPEHPK3PXP', now(), now())`);
    const ok = (r) => r?.status === 200 && !r.code;
    check('D10-in-app-request-denies-at-once', ok(unlinked) && reclaimed.data?.released === true
      && ok(linked) && linked.data?.member_id === leaving.member && ok(pastor)
      && ok(issued) && ok(change) && ok(withdrawn) && ok(proposed)
      && emailChange.status === 200 && hasCell
      && Object.values(seededStores).every((n) => n > 0)
      && before.every((s) => s === 200)
      && ok(requested) && requested.data?.deletion_state === 'requested' && requested.data?.signed_out === true
      && !('display_name' in (requested.data ?? {}))
      && devices.every((d) => d.summary === 401 && d.refresh >= 400)
      && freshTry.status >= 400 && !freshTry.json?.access_token
      && accounts.length === 2 && accounts[0] === old.user && accounts[1] === leaving.user,
      { flows: { unlinked: ok(unlinked), released: reclaimed.data?.released ?? reclaimed.code ?? null, linked: ok(linked),
          linked_member: linked.data?.member_id === leaving.member, pastor: ok(pastor), grant_issued: ok(issued),
          change: ok(change), withdrawn: ok(withdrawn), proposed: ok(proposed), auth_email_change: emailChange.status,
          cell: hasCell, signed_out: requested.data?.signed_out ?? null },
        seeded_through_real_flows: seededStores, auth_audit_written_by_gotrue: auditWritten > 0,
        devices_before: before, request: requested.data?.deletion_state, devices_after: devices,
        password_sign_in: { status: freshTry.status, error_code: freshTry.json?.error_code ?? null },
        accounts_recorded: accounts.length, earlier_account_first: accounts[0] === old.user });

    // ------------------------------------------------------- the worker, interrupted and resumed
    const first = worker(['--deletion', leaving.deletion, '--max-steps', '2']);
    const afterFirst = steps(leaving.deletion);
    const stillDenied = await signIn(leaving.phone, leaving.password);
    check('D11-interrupted-after-two-steps', first.exit === 0 && first.result?.result === 'stopped'
      && first.result?.stopped_before === 'journal_manifest_account'
      && afterFirst.journal_access_revoked?.state === 'done' && afterFirst.journal_manifest_member?.state === 'done'
      && afterFirst.erase_identity?.state === 'pending' && personal(leaving) > 0
      && stillDenied.status >= 400 && !stillDenied.json?.access_token,
      { result: first.result?.result, stopped_before: first.result?.stopped_before,
        journal_steps: [afterFirst.journal_access_revoked?.state, afterFirst.journal_manifest_member?.state],
        erased_yet: personal(leaving) === 0, password_sign_in: stillDenied.status });

    // A crash right after the next append (the earlier account's manifest entry) and before its
    // acknowledgement.
    const next = (await sys('identity.deletion_next', { deletion_id: leaving.deletion }))?.next;
    const orphan = await journal.append(next.entry);
    const countBefore = ((await journal.list()) ?? []).length;
    // The Edge Function is unreachable for this run: the Auth step stops the worker, nothing changes.
    const down = worker(['--deletion', leaving.deletion, '--function-url', 'http://127.0.0.1:9/functions/v1/identity-deletion']);
    const afterDown = steps(leaving.deletion);
    const countAfter = ((await journal.list()) ?? []).length;
    const acked = down.lines.filter((l) => l.step === 'journal_manifest_account');
    check('D12-resume-acks-the-appended-entry-and-survives-an-unreachable-function', next?.step === 'journal_manifest_account'
      && next?.entry?.object?.object_id === old.user
      && acked[0]?.outcome === 'acked_existing' && acked[0]?.seq === orphan.seq
      && acked[1]?.outcome === 'journaled' && countAfter === countBefore + 1
      && down.result?.result === 'failed:auth_unreachable' && afterDown.auth_account?.state === 'pending'
      && (await http('GET', `/auth/v1/admin/users/${leaving.user}`, { admin: true })).status === 200
      && (await http('GET', `/auth/v1/admin/users/${old.user}`, { admin: true })).status === 200,
      { appended_before_crash: orphan.kind, resumed: acked.map((a) => a.outcome), journal_grew_by: countAfter - countBefore,
        result: down.result?.result, auth_step: afterDown.auth_account });

    // Resumed: the Edge Function deletes both Auth users through Auth Admin.
    const finish = worker(['--deletion', leaving.deletion]);
    const done = steps(leaving.deletion);
    const del = JSON.parse(psql(`select row_to_json(d) from app.identity_deletions d where deletion_id = '${leaving.deletion}'`));
    const accountRows = JSON.parse(psql(`select json_agg(json_build_object('kept', auth_user_id is not null, 'auth', auth_outcome, 'attempts', auth_attempts) order by account_no)
      from app.identity_deletion_accounts where deletion_id = '${leaving.deletion}'`));
    const authLeft = Number(psql(`select (select count(*) from auth.users where id in ('${leaving.user}', '${old.user}'))
      + (select count(*) from auth.identities where user_id in ('${leaving.user}', '${old.user}'))
      + (select count(*) from auth.sessions where user_id in ('${leaving.user}', '${old.user}'))
      + (select count(*) from auth.refresh_tokens where user_id in ('${leaving.user}', '${old.user}'))
      + (select count(*) from auth.one_time_tokens where user_id in ('${leaving.user}', '${old.user}'))
      + (select count(*) from auth.mfa_factors where user_id in ('${leaving.user}', '${old.user}'))
      + (select count(*) from auth.audit_log_entries where payload ->> 'actor_id' in ('${leaving.user}', '${old.user}')
           or payload -> 'traits' ->> 'user_id' in ('${leaving.user}', '${old.user}'))`));
    const identityLeft = JSON.parse(psql(`select json_build_object(
      'links', (select count(*) from app.identity_account_links where member_id = '${leaving.member}' or auth_user_id in ('${leaving.user}', '${old.user}')),
      'applications', (select count(*) from app.identity_membership_applications where member_id = '${leaving.member}' or auth_user_id in ('${leaving.user}', '${old.user}')),
      'application_events', (select count(*) from app.identity_application_events where actor_auth_user_id in ('${leaving.user}', '${old.user}')),
      'reclaims', (select count(*) from app.identity_phone_reclaims where released_account_id = '${old.user}'),
      'recovery_requests', (select count(*) from app.identity_recovery_requests where request_code = '${code}'),
      'recovery', (select count(*) from app.identity_recovery_cases where member_id = '${leaving.member}')
                  + (select count(*) from app.identity_recovery_grants where member_id = '${leaving.member}'),
      'changes_and_proposals', (select count(*) from app.identity_credential_changes where member_id = '${leaving.member}')
                  + (select count(*) from app.identity_recovery_email_proposals where member_id = '${leaving.member}'),
      'receipts', (select count(*) from app.cmd_receipts where actor_id in ('${leaving.user}', '${old.user}')
                     or aggregate_id = '${leaving.member}' or result::text like '%${NAME_PREFIX} Leaving%'))`));
    check('D13-resumed-to-completion-after-every-store-is-checked', finish.result?.result === 'done'
      && Object.values(done).every((s) => s.state === 'done') && done.auth_account?.outcome === 'deleted'
      && done.auth_account?.attempts === 2 && done.verify?.outcome === 'verified'
      && accountRows.every((a) => !a.kept && a.auth === 'deleted' && a.attempts === 1)
      && del.deletion_state === 'completed' && personal(leaving) === 0 && authLeft === 0
      && Object.values(identityLeft).every((n) => n === 0)
      && psql(`select membership_state || '|' || display_name from app.identity_members where member_id = '${leaving.member}'`) === 'deactivated|Deleted member'
      && psql(`select coalesce(string_agg(event, ',' order by call_id), '') from app.fixture_lifecycle_calls where member_id = '${leaving.member}'`)
         .endsWith('member_deleted'),
      { result: finish.result?.result, steps: Object.fromEntries(Object.entries(done).map(([k, v]) => [k, `${v.state}/${v.attempts}/${v.outcome}`])),
        accounts: accountRows, auth_rows_left: authLeft, identity_rows_left: identityLeft, personal_rows_left: personal(leaving) });
    const afterSignIn = await signIn(leaving.phone, leaving.password);
    const again = worker(['--deletion', leaving.deletion]);
    const queue = (await sys('identity.deletion_queue', {}))?.deletions ?? [];
    check('D14-idempotent-after-completion', afterSignIn.status >= 400 && !afterSignIn.json?.access_token
      && again.result?.result === 'done' && again.lines.filter((l) => l.action).length === 0
      && !queue.some((q) => q.deletion_id === leaving.deletion)
      && (await http('GET', `/auth/v1/admin/users/${leaving.user}`, { admin: true })).status === 404
      && (await http('GET', `/auth/v1/admin/users/${old.user}`, { admin: true })).status === 404,
      { password_sign_in: afterSignIn.status, second_run: again.result?.result, actions: again.lines.filter((l) => l.action).length,
        in_queue: queue.some((q) => q.deletion_id === leaving.deletion) });

    // --------------------------------------------------------------- staff route (no login)
    await seeded(appUser);
    const refused = await staffDelete(admin.token, appUser);
    const self = await staffDelete(admin.token, admin);
    const created = await envelope('identity_review_command', admin.token, 'identity.create_member', null,
      { full_name: accountless.name, consent_basis: 'in_person', contact_route: { phone: accountless.phone, belongs_to: 'member' } });
    accountless.member = created.data?.member_id;
    members.add(accountless.member);
    const byStaff = await staffDelete(admin2.token, accountless);
    accountless.deletion = byStaff.data?.deletion_id;
    const staffRun = worker(['--deletion', accountless.deletion]);
    const staffSteps = steps(accountless.deletion);
    const overview = (await rpc('identity_admin_deletions', admin.token)).json;
    check('D20-staff-deletes-an-accountless-member', refused.code === 'conflict' && refused.field_errors?.member_id === 'member_can_use_app'
      && self.code === 'forbidden' && created.data?.account === 'no_login'
      && byStaff.status === 200 && byStaff.data?.origin === 'staff_request' && byStaff.data?.had_account === false
      && staffRun.result?.result === 'done' && !('auth_account' in staffSteps) && personal(accountless) === 0
      && (overview?.deletions ?? []).filter((d) => [leaving.deletion, accountless.deletion].includes(d.deletion_id)
           && d.deletion_state === 'completed').length === 2,
      { app_user: refused.field_errors?.member_id, own_record: self.code, origin: byStaff.data?.origin,
        had_account: byStaff.data?.had_account, result: staffRun.result?.result, account_steps: 'auth_account' in staffSteps,
        admin_read_completed: (overview?.deletions ?? []).filter((d) => d.deletion_state === 'completed').length });

    // ------------------------------------------- the journal holds only opaque identifiers
    const entries = (await journal.list()) ?? [];
    const ids = [leaving.member, accountless.member, leaving.user, people.leavingOld.user];
    const ours = entries.filter((e) => ids.includes(e.subject) || ids.includes(e.object?.object_id));
    const forbidden = [leaving.phone, leaving.phone.slice(1), people.leavingOld.phone, people.leavingOld.phone.slice(1),
      accountless.phone, leaving.email, leaving.name, accountless.name, NAME_PREFIX];
    const acks = JSON.parse(psql(`select coalesce(json_agg(json_build_object('seq', seq, 'hash', entry_hash) order by seq), '[]') from app.rcv_journal_acks`));
    const ackMismatch = acks.filter((a) => entries[a.seq - 1]?.hash !== a.hash).length;
    check('D30-journal-holds-only-opaque-identifiers', ours.length === 10
      && ours.every((e) => opaqueEntryProblems(e, forbidden).length === 0) && ackMismatch === 0
      && ours.filter((e) => e.kind === 'deletion_completed').length === 4
      && ours.filter((e) => e.object?.bucket === 'auth-user').length === 4,
      { entries: ours.map((e) => e.kind), problems: ours.reduce((n, e) => n + opaqueEntryProblems(e, forbidden).length, 0),
        acknowledged: acks.length, acks_not_in_journal: ackMismatch });

    // ------------------------------- a restore replays the deletion before access opens
    await seeded(restored);
    const restoredCell = await giveCell(admin.token, restored, 'South cell');
    // Backup T1 (database bytes: app and api schemas), BEFORE the member asks for deletion.
    const backupId = `t1-${run}-SYNTHETIC`;
    const dump = execFileSync('docker', ['exec', dbContainer(), 'pg_dump', '-U', 'postgres', '--schema=app', '--schema=api'],
      { encoding: 'utf8', maxBuffer: 256 << 20 });
    const artifact = `${dump}\n\nset app.restore_in_progress = 'on';\nselect app.rcv_hold_after_restore('${backupId}', '${OPERATOR}');\nreset app.restore_in_progress;\n`;
    restored.token = (await signIn(restored.phone, restored.password)).json?.access_token;
    const askR = await mine(restored.token);
    restored.deletion = deletionOf(restored);
    const runR = worker(['--deletion', restored.deletion]);
    const cutoff = new Date().toISOString();
    const seal = await journal.append({ kind: 'seal', cutoff });
    // Restore T1 into an isolated database (same image, no network, no API in front of it).
    const image = execFileSync('docker', ['inspect', dbContainer(), '--format', '{{.Config.Image}}'], { encoding: 'utf8' }).trim();
    spawnSync('docker', ['rm', '-f', ISOLATED]);
    execFileSync('docker', ['run', '-d', '--name', ISOLATED, '--network', 'none', '--label', 'bic.recovery=isolated-SYNTHETIC',
      '-e', `POSTGRES_PASSWORD=${randomBytes(18).toString('hex')}`, image]);
    isolated = true;
    const ready = Date.now() + 240_000;
    for (;;) {
      const logs = spawnSync('docker', ['logs', ISOLATED], { encoding: 'utf8' });
      if (/init process complete/i.test(`${logs.stdout}${logs.stderr}`)
          && spawnSync('docker', ['exec', ISOLATED, 'pg_isready', '-U', 'postgres']).status === 0) {
        await sleep(1500);
        if (spawnSync('docker', ['exec', ISOLATED, 'psql', '-U', 'postgres', '-c', 'select 1']).status === 0) break;
      }
      if (Date.now() > ready) throw new Error('isolated container did not become ready');
      await sleep(2000);
    }
    const tdb = 'rcv_deletion';
    execFileSync('docker', ['exec', ISOLATED, 'createdb', '-U', 'postgres', tdb]);
    execFileSync('docker', ['exec', '-i', ISOLATED, 'psql', '-U', 'postgres', '-d', tdb, '-X', '-q', '-v', 'ON_ERROR_STOP=1', '--single-transaction'],
      { input: artifact, maxBuffer: 256 << 20 });
    const iso = (sql) => psqlIn(ISOLATED, tdb, sql);
    // The isolated target has no Auth service or schema (the artifact holds app and api only); a
    // restored Auth snapshot row for the account is simulated with a minimal table.
    const authSeeded = spawnSync('docker', ['exec', '-i', ISOLATED, 'psql', '-U', 'postgres', '-d', tdb, '-X', '-q', '-v', 'ON_ERROR_STOP=1'],
      { input: `create schema if not exists auth;
        create table if not exists auth.users (id uuid primary key, banned_until timestamptz);
        insert into auth.users (id) values ('${restored.user}');`, encoding: 'utf8' }).status === 0;
    const gateProbe = () => JSON.parse(iso(`begin;
      select app.policy_approve('private_access', '{"enabled": true}', '${OPERATOR}', 'E2E PROBE - rolled back');
      select json_build_object('private_access_if_approved', app.policy_is_open('private_access'));
      rollback;`).split('\n').filter((l) => l.startsWith('{')).pop());
    const factsIn = () => ({
      status: JSON.parse(iso('select app.rcv_recovery_status()')),
      member: iso(`select coalesce((select membership_state || '|' || (display_name = 'Deleted member')::text from app.identity_members where member_id = '${restored.member}'), 'absent')`),
      links: Number(iso(`select count(*) from app.identity_account_links where member_id = '${restored.member}'`)),
      cells: Number(iso(`select count(*) from app.cells_memberships where member_id = '${restored.member}'`)),
      auth_row: Number(iso(`select count(*) from auth.users where id = '${restored.user}'`)),
      deletion: iso(`select coalesce((select origin || '|' || deletion_state from app.identity_deletions where member_id = '${restored.member}'), 'none')`),
      gates_if_approved: gateProbe(),
    });
    const held = factsIn();
    const isoAcks = JSON.parse(iso(`select coalesce(json_agg(json_build_object('seq', seq, 'hash', entry_hash) order by seq), '[]') from app.rcv_journal_acks`));
    const all = (await journal.list()) ?? [];
    const verdict = verifyJournal(all, { cutoff, databaseAcks: isoAcks });
    const absent = [];
    let reconciled = null;
    let replayError = null;
    if (verdict.complete) {
      try {
        for (const e of all) {
          const res = JSON.parse(iso(`select app.rcv_apply_journal_entry(${jsonLiteral(e)}, '${OPERATOR}')`));
          if (res.delete_object && !absent.includes(res.delete_object.object_id)) absent.push(res.delete_object.object_id);
        }
        reconciled = JSON.parse(iso(`select app.rcv_complete_reconciliation('${held.status.restore_id}', ${verdict.head_seq}, '${verdict.head_hash}',
          array[${absent.map((a) => `'${a}'::uuid`).join(',')}]::uuid[], '${OPERATOR}')`));
      } catch (e) {
        replayError = String(e.message).split('\n').find((l) => /ERROR/.test(l)) ?? 'replay_failed';
      }
    }
    const after = factsIn();
    check('D40-restore-replays-the-deletion-before-access-opens', askR.status === 200 && restoredCell && runR.result?.result === 'done'
      && seal.kind === 'seal'
      && held.status.state === 'restored_held' && held.status.serving_hold === true
      && held.gates_if_approved.private_access_if_approved === false
      && held.member === 'approved|false' && held.links === 1 && held.cells === 1 && held.deletion === 'none'
      && verdict.complete && reconciled?.state === 'reconciled' && !replayError
      && after.status.serving_hold === false && after.gates_if_approved.private_access_if_approved === true
      && after.status.private_access_open === false
      && after.member === 'deactivated|true' && after.links === 0 && after.cells === 0
      && after.deletion === 'journal_replay|completed' && authSeeded && held.auth_row === 1 && after.auth_row === 0,
      { worker: runR.result?.result, journal_verdict: verdict.complete ? 'complete' : verdict.reason,
        restored_before_reconcile: { state: held.status.state, serving_hold: held.status.serving_hold,
          private_access_if_approved: held.gates_if_approved.private_access_if_approved, member: held.member,
          links: held.links, cells: held.cells, deletion: held.deletion, simulated_auth_row: authSeeded ? held.auth_row : 'not_seeded' },
        reconcile: reconciled?.state ?? replayError,
        after: { serving_hold: after.status.serving_hold, private_access_if_approved: after.gates_if_approved.private_access_if_approved,
          private_access_open: after.status.private_access_open, member: after.member, links: after.links, cells: after.cells,
          deletion: after.deletion, auth_row: after.auth_row } });

    // ------------------------------------------------------------------ no leakage anywhere
    const logLeaks = [leaving.phone, leaving.phone.slice(1), old.phone.slice(1), credential, leaving.user, old.user]
      .filter((v) => serveLog.includes(v)).length;
    // Every table of the app and auth schemas: no number, address or name of the deleted member,
    // and no deleted account id outside the journal acknowledgements (opaque, by design).
    const personalRe = [leaving.phone.slice(1), old.phone.slice(1), people.leavingNext.phone.slice(1), leaving.email,
      `${NAME_PREFIX} Leaving`, `${NAME_PREFIX} Restored`, restored.phone.slice(1)].join('|');
    const idRe = [leaving.user, old.user, restored.user].join('|');
    const tables = psql(`select string_agg(format('%I.%I', table_schema, table_name), ' ') from information_schema.tables
      where table_schema in ('app', 'auth') and table_type = 'BASE TABLE'`).split(' ');
    const hits = psql(tables.map((t) => `select '${t}' as t, count(*) as n from ${t} x where x::text ~ '${personalRe}'
        ${t === 'app.rcv_journal_acks' ? '' : `or x::text ~ '${idRe}'`}`).join(' union all ')
      .replace(/^/, 'select coalesce(string_agg(t || \':\' || n, \',\'), \'\') from (') + ') y where n > 0');
    check('D50-no-number-address-name-or-account-id-left-anywhere', logLeaks === 0 && hits === ''
      && serveLog.includes('"fn":"identity-deletion"'),
      { function_log_leaks: logLeaks, tables_scanned: tables.length, tables_with_leftovers: hits || 'none',
        function_log_lines: (serveLog.match(/"fn":"identity-deletion"/g) ?? []).length });

    // ------------------------------- the last two Admins delete themselves at the same moment
    // Two concurrent in-app requests (separate PostgREST transactions): the Admin role lock
    // serialises them, so exactly one succeeds and one usable Admin remains.
    const tA = (await signIn(admin.phone, admin.password)).json?.access_token;
    const tB = (await signIn(admin2.phone, admin2.password)).json?.access_token;
    const usableBefore = Number(psql(`select app.identity_usable_admin_count()`));
    const [selfA, selfB] = await Promise.all([mine(tA), mine(tB)]);
    const outcomes = [selfA, selfB].map((r) => (r.status === 200 && !r.code ? 'ok' : `${r.code}:${r.field_errors?.member_id ?? ''}`));
    const usableAfter = Number(psql(`select app.identity_usable_admin_count()`));
    check('D60-concurrent-self-deletion-of-the-last-two-admins', usableBefore === 2
      && outcomes.filter((o) => o === 'ok').length === 1 && outcomes.includes('forbidden:last_admin') && usableAfter === 1,
      { usable_before: usableBefore, outcomes: outcomes.sort(), usable_after: usableAfter });

    const sms = (await http('GET', '/auth/v1/settings')).json?.sms_provider ?? null;
    check('D99-no-sms', !sms, { sms_provider: sms });
  } finally {
    try { process.kill(-serve.pid, 'SIGINT'); } catch { /* already gone */ }
    await sleep(3000);
    try { process.kill(-serve.pid, 'SIGKILL'); } catch { /* already gone */ }
    try { execFileSync('docker', ['rm', '-f', 'supabase_edge_runtime_church-app'], { stdio: 'ignore' }); } catch { /* not running */ }
    if (isolated) spawnSync('docker', ['rm', '-f', ISOLATED]);
    rmSync(work, { recursive: true, force: true });
    psql(`select app.sys_revoke_credential('${credentialId}', '${OPERATOR}'); select app.sys_disable_principal('${principal}', '${OPERATOR}');`);
    unhook();
    const left = cleanup();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'identity-deletion-e2e';
            delete from app.platform_environment_history where set_by = 'identity-deletion-e2e';`);
    }
    log('D100-cleanup', { users_left: Number(left), credential_revoked: true, principal_disabled: true, isolated_removed: isolated,
      unmarked: marked, journal_and_acks_kept: 'append-only' });
  }
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  if (failed.length) {
    console.log(`FAILED: ${failed.map((f) => f.step).join(', ')}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((e) => {
    console.error(e.message);
    process.exitCode = 1;
  });
}
