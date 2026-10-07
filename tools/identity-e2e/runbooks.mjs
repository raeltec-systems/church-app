#!/usr/bin/env node
// Story 2.12 rehearsal of the restricted identity support runbooks (docs/runbooks/identity-support.md)
// on the LOCAL stack, with SYNTHETIC records, through real GoTrue (phone sign-in without SMS), the
// real Data API, Mailpit, the real Edge Functions (identity-assisted-recovery, identity-deletion,
// served here) and the real deletion worker. Each runbook is followed as the support staff
// (staff web calls), the member (mobile calls) and the restricted operator (operator procedures)
// would follow it:
//
//   RB1 first-Admin setup                         RB5 holds, disputes and credential review
//   RB2 applications, linking and reclaim         RB6 deactivation and handover
//   RB3 email recovery                            RB7 deletion
//   RB4 staff-assisted recovery                   RB8 identity-checked last-Admin fallback
//
// and proves the ticket's three properties:
//   * no step's output shows a password or a usable grant, code, link or token to anyone but its
//     holder (every staff answer, operator output, worker output and the evidence file is scanned);
//   * an Admin-only support account reaches no care or finance fixture (nor a cell-private one);
//   * the last-Admin fallback restores Admin access without a credential shortcut: no password,
//     session, token or Auth row is created or changed by the operator; the new Admin signs in
//     with their own password and the unreachable Admin is helped back through RB4.
//
// Needs the local phone switch (`node tools/auth-harness/local-phone-auth.mjs on`; no SMS provider,
// hook, test OTP or SMS MFA; `off` afterwards), the edge-runtime image, and a database with no
// usable Admin (`npx supabase db reset` first). LOCAL only (exact origin). Fictional numbers
// +44 7700 900700-900719 and @example.test addresses only. Evidence is redacted JSONL: statuses,
// codes, counts and booleans; never tokens, passwords, codes or numbers. Everything it created is
// removed; append-only rows stay (the operator journal, sys_audit, the recovery journal and its
// acknowledgements), as in the other identity E2Es.
//
// Usage: node tools/identity-e2e/runbooks.mjs [--evidence <file.jsonl>]
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import { appendFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { digestOf, findLeaks, newGrantSecret } from './assisted.mjs';
import { MAILPIT, MOBILE_EMAIL_CONFIRMED, MOBILE_RECOVERY, codeFrom, pkcePair, redirectFacts } from './recovery.mjs';
import { amrMethods, assertLocalOrigin, redact } from './run.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const NAME_PREFIX = 'SYNTHETIC 2.12 RB';
const OPERATOR = 'israel';
const EPOCH_WAIT_MS = 6500; // the 2.2 trust-epoch margin is 5 s
const RESEND_WAIT_MS = 1200; // local max_frequency is 1 s per address
const ASSISTED_FN = '/functions/v1/identity-assisted-recovery';
const DELETION_FN = '/functions/v1/identity-deletion';

/** The reserved fictional numbers this rehearsal uses (+44 7700 900700-900719). */
export function isFictionalRunbookPhone(phone) {
  return /^\+4477009007[01][0-9]$/.test(phone);
}

/** The secret parts of an emailed Auth link: the whole link and its token parameters. */
export function linkSecrets(link) {
  if (!link) return [];
  const out = [link];
  try {
    const u = new URL(link);
    for (const k of ['token', 'token_hash', 'code']) {
      const v = u.searchParams.get(k);
      if (v) out.push(v);
    }
  } catch { /* not a URL */ }
  return out;
}

/** The Auth facts the operator must never change; returns the names of those that differ. */
export const AUTH_FACTS = ['encrypted_password', 'updated_at', 'last_sign_in_at', 'phone', 'email', 'banned_until',
  'sessions', 'refresh_tokens', 'one_time_tokens', 'mfa_factors'];
export function changedAuthFacts(before, after) {
  return AUTH_FACTS.filter((k) => JSON.stringify(before?.[k] ?? null) !== JSON.stringify(after?.[k] ?? null));
}

function localKey() {
  const env = execFileSync('npx', ['supabase', 'status', '-o', 'env'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  const url = /^API_URL="([^"]+)"/m.exec(env)?.[1];
  const key = /^PUBLISHABLE_KEY="([^"]+)"/m.exec(env)?.[1];
  const secret = /^SECRET_KEY="([^"]+)"/m.exec(env)?.[1];
  const service = /^SERVICE_ROLE_KEY="([^"]+)"/m.exec(env)?.[1];
  if (!url || !key || !secret || !service) throw new Error('local stack is not running');
  return { origin: assertLocalOrigin(url), key, secret, service };
}

function psqlRaw(sql) {
  const name = execFileSync('docker', ['ps', '--filter', 'name=supabase_db_', '--format', '{{.Names}}'], { encoding: 'utf8' }).trim().split('\n')[0];
  return execFileSync('docker', ['exec', '-i', name, 'psql', '-U', 'postgres', '-X', '-qtA', '-v', 'ON_ERROR_STOP=1', '-c', sql],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
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

  // What each party saw, for the leak scan.
  const staffTokens = new Set(); // sessions of support staff (Admins)
  const staffTexts = []; // every answer a staff session received
  const operatorTexts = []; // every operator procedure output and worker output
  const secrets = []; // passwords, grant secrets, digests, links, link codes, PKCE verifiers, member tokens, credentials
  const codes = []; // request codes: the member reads one out; staff answers never echo it
  const keep = (...v) => { for (const x of v) if (typeof x === 'string' && x) secrets.push(x); return v[0]; };

  const psql = (sql) => psqlRaw(sql);
  const operator = (sql) => { const out = psqlRaw(sql); operatorTexts.push(out); return out; };
  const operatorTry = (sql) => {
    try { return { ok: true, out: operator(sql) }; } catch (e) {
      const text = String(e.stderr ?? e.message);
      operatorTexts.push(text);
      return { ok: false, error: /ERROR:\s+([^\n]*)/.exec(text)?.[1] ?? 'error' };
    }
  };

  async function http(method, path, { token, body, profile, admin, xff } = {}) {
    const headers = { apikey: admin ? secret : key, 'Content-Type': 'application/json' };
    if (admin) headers.Authorization = `Bearer ${service}`;
    else if (token) headers.Authorization = `Bearer ${token}`;
    if (profile) headers[method === 'GET' ? 'Accept-Profile' : 'Content-Profile'] = profile;
    if (xff !== undefined) headers['X-Forwarded-For'] = xff;
    const res = await fetch(`${origin}${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined, redirect: 'manual' });
    const text = await res.text();
    if (token && staffTokens.has(token)) staffTexts.push(text);
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { /* non-JSON */ }
    return { status: res.status, json, location: res.headers.get('location') };
  }
  const password = () => keep(`Synthetic-${randomBytes(12).toString('base64url')}`);
  const signUp = (phone, pw) => http('POST', '/auth/v1/signup', { body: { phone, password: pw } });
  const signInRaw = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  // A sign-in on the person's own device. Member tokens are secrets; staff tokens are tracked.
  const signIn = async (p, { staff = false } = {}) => {
    const r = await signInRaw(p.phone, p.password);
    const t = r.json?.access_token;
    if (t) {
      if (staff) staffTokens.add(t);
      else keep(t, r.json?.refresh_token);
    }
    return { status: r.status, token: t, refresh: r.json?.refresh_token, json: r.json };
  };
  const refresh = (rt) => http('POST', '/auth/v1/token?grant_type=refresh_token', { body: { refresh_token: rt } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const envelope = (fn, token, cmd, expected, payload) =>
    rpc(fn, token, { version: 1, command: cmd, request_id: randomUUID(), expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const summary = async (token) => {
    const r = await rpc('identity_my_member_summary', token);
    return { status: r.status, detail: r.json?.details ?? null, member_id: r.json?.member_id ?? null };
  };
  const roles = async (token) => (await rpc('identity_my_access', token)).json?.roles ?? null;
  const ok = (r) => r?.status === 200 && !r.code;

  // Mailpit (the member's mailbox): the newest message to one address since a moment.
  async function mailTo(address, since, { waitMs = 5000 } = {}) {
    const deadline = Date.now() + waitMs;
    for (;;) {
      const r = await fetch(`${MAILPIT}/api/v1/search?query=${encodeURIComponent(`to:"${address}"`)}&limit=50`);
      const list = r.ok ? await r.json() : { messages: [] };
      const fresh = (list.messages || []).filter((m) => Date.parse(m.Created) >= since - 200)
        .sort((a, b) => Date.parse(b.Created) - Date.parse(a.Created));
      if (fresh.length) {
        const msg = await (await fetch(`${MAILPIT}/api/v1/message/${fresh[0].ID}`)).json();
        const text = `${msg.Text || ''}\n${(msg.HTML || '').replace(/&amp;/g, '&')}`;
        const link = text.match(/https?:\/\/[^\s"'<>)\]]+/g)?.find((l) => l.startsWith(`${origin}/auth/v1/verify?`)) ?? null;
        keep(...linkSecrets(link));
        return { link };
      }
      if (Date.now() > deadline) return null;
      await sleep(250);
    }
  }
  const openLink = async (link) => {
    if (!link?.startsWith(`${origin}/auth/v1/verify?`)) return { status: null, location: null };
    const res = await fetch(link, { redirect: 'manual' });
    const location = res.headers.get('location');
    keep(codeFrom(location));
    return { status: res.status, location };
  };

  const run = randomBytes(4).toString('hex');
  const people = {
    admin: { phone: '+447700900700', name: `${NAME_PREFIX} Admin A` },
    admin2: { phone: '+447700900701', name: `${NAME_PREFIX} Admin B` },
    applicant: { phone: '+447700900702', name: `${NAME_PREFIX} Applicant` },
    owner: { phone: '+447700900703', name: `${NAME_PREFIX} Accountless` }, // the squatter registers this number first
    emailer: { phone: '+447700900704', name: `${NAME_PREFIX} Email`, email: `synthetic-2-12-email-${run}@example.test` },
    helped: { phone: '+447700900705', name: `${NAME_PREFIX} Lost Device` },
    disputed: { phone: '+447700900706', name: `${NAME_PREFIX} Disputed` },
    changed: { phone: '+447700900707', name: `${NAME_PREFIX} Direct Change`, direct: '+447700900708' },
    leaving: { phone: '+447700900709', name: `${NAME_PREFIX} Leaving` },
    deleting: { phone: '+447700900710', name: `${NAME_PREFIX} Deleting` },
  };
  for (const p of Object.values(people)) {
    if (!isFictionalRunbookPhone(p.phone) || (p.direct && !isFictionalRunbookPhone(p.direct))) throw new Error(`not fictional: ${p.phone}`);
  }
  const allPhones = Object.values(people).flatMap((p) => [p.phone, p.direct]).filter(Boolean);
  const digits = allPhones.map((p) => `'${p.slice(1)}'`).join(',');
  const users = new Set();
  const members = new Set();
  const cells = new Set();
  const careId = randomUUID();
  const financeId = randomUUID();
  const LIFECYCLE_EVENTS = ['membership_deactivated', 'membership_restored'];

  const cleanup = () => {
    const ids = [...users].map((u) => `'${u}'`);
    const byUser = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    const mids = [...members].map((m) => `'${m}'`);
    const cids = [...cells].map((c) => `'${c}'`);
    return psqlRaw(`
    create temp table gone_users as select u.id from auth.users u
     where ${byUser} u.phone in (${digits}) or u.email like 'synthetic-2-12-%@example.test';
    create temp table gone_members as
      select m.member_id from app.identity_members m
       where m.display_name like '${NAME_PREFIX}%' ${mids.length ? `or m.member_id in (${mids.join(',')})` : ''};
    create temp table gone_cells as select c.cell_id from app.cells_cells c
     where c.name like '${NAME_PREFIX}%' ${cids.length ? `or c.cell_id in (${cids.join(',')})` : ''};
    create temp table gone_apps as
      select a.application_id from app.identity_membership_applications a
       where a.auth_user_id in (select id from gone_users) or a.member_id in (select member_id from gone_members)
          or a.full_name like '${NAME_PREFIX}%';
    create temp table gone_deletions as
      select d.deletion_id from app.identity_deletions d where d.member_id in (select member_id from gone_members);
    delete from app.identity_admin_fallbacks f where f.target_member_id in (select member_id from gone_members);
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
    delete from app.identity_recovery_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_recovery_operations o where o.member_id in (select member_id from gone_members);
    delete from app.identity_recovery_grants g where g.member_id in (select member_id from gone_members);
    delete from app.identity_recovery_cases c where c.member_id in (select member_id from gone_members);
    delete from app.identity_recovery_requests r where r.claimed_phone in (${allPhones.map((p) => `'${p}'`).join(',')});
    delete from app.identity_recovery_client_attempts c where c.at >= '${startedAt}';
    delete from app.identity_recovery_audit a where a.member_id is null
       and a.action in ('request_received', 'request_refused', 'grant_rejected') and a.occurred_at >= '${startedAt}';
    delete from app.identity_credential_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_credential_review_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_credential_changes c where c.member_id in (select member_id from gone_members);
    delete from app.identity_recovery_email_proposals p
     where p.member_id in (select member_id from gone_members) or p.auth_user_id in (select id from gone_users);
    delete from app.identity_phone_reclaims r where r.released_account_id in (select id from gone_users)
       or r.actor_member_id in (select member_id from gone_members);
    delete from app.identity_membership_audit a
     where a.application_id in (select application_id from gone_apps)
        or a.member_id in (select member_id from gone_members)
        or a.actor_member_id in (select member_id from gone_members)
        or a.target_account_id in (select id from gone_users);
    delete from app.identity_member_provenance p
     where p.member_id in (select member_id from gone_members) or p.application_id in (select application_id from gone_apps)
        or p.recorded_by_member in (select member_id from gone_members);
    delete from app.identity_contact_routes c
     where c.member_id in (select member_id from gone_members) or c.created_by_member in (select member_id from gone_members);
    delete from app.identity_application_events e where e.application_id in (select application_id from gone_apps);
    delete from app.identity_membership_applications a where a.application_id in (select application_id from gone_apps);
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
    delete from app.fixture_scope_targets t where t.scope_id in ('${careId}', '${financeId}');
    delete from app.cmd_receipts r where r.actor_id in (select id from gone_users);
    delete from auth.flow_state f where f.user_id in (select id from gone_users);
    delete from auth.users u where u.id in (select id from gone_users);
    select count(*) from auth.users u where ${byUser} u.phone in (${digits}) or u.email like 'synthetic-2-12-%@example.test';`);
  };
  const unhook = () => psqlRaw(`
    delete from app.contract_lifecycle_hooks where module = 'fixture'
       and event in (${LIFECYCLE_EVENTS.map((e) => `'${e}'`).join(',')});
    delete from app.identity_handover_hooks where module = 'fixture';`);
  const clearMail = async () => {
    const r = await fetch(`${MAILPIT}/api/v1/search?query=${encodeURIComponent('to:"example.test"')}&limit=500`).catch(() => null);
    const ids = r?.ok ? ((await r.json()).messages || []).filter((m) => (m.To || []).some((t) => /^synthetic-2-12-/.test(t.Address)))
      .map((m) => m.ID) : [];
    if (ids.length) await fetch(`${MAILPIT}/api/v1/messages`, { method: 'DELETE', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ IDs: ids }) });
    return ids.length;
  };

  // ------------------------------------------------------------------------- preconditions
  const settings = await http('GET', '/auth/v1/settings');
  if (settings.json?.external?.phone !== true) {
    throw new Error('the local phone provider is off: run `node tools/auth-harness/local-phone-auth.mjs on` first');
  }
  if (!(await fetch(`${MAILPIT}/api/v1/info`).then((r) => r.ok).catch(() => false))) {
    throw new Error('Mailpit is not reachable on 127.0.0.1:54324 (supabase start includes it)');
  }
  const marker = psqlRaw(`select coalesce((select environment from app.platform_environment), '')`);
  let marked = false;
  if (marker === '') {
    psqlRaw(`select app.platform_set_environment('local', 'identity-runbooks-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  const leftovers = cleanup();
  if (Number(psqlRaw(`select app.identity_usable_admin_count()`)) !== 0) {
    throw new Error('the local database already has a usable Admin; run `npx supabase db reset` first');
  }
  if (Number(psqlRaw(`select (select count(*) from app.contract_lifecycle_hooks where module = 'fixture')
                          + (select count(*) from app.identity_handover_hooks)`)) !== 0) {
    throw new Error('a fixture lifecycle or handover hook is already registered');
  }

  // The two server-side credentials the runbooks rely on (only the digests are registered).
  const assistedCredential = keep(`sysc_local_${randomBytes(32).toString('base64url')}`);
  const deletionCredential = keep(`sysc_local_${randomBytes(32).toString('base64url')}`);
  const assistedPrincipal = operator(`select app.sys_create_principal('identity-runbooks-assisted-${run}', 'identity_assisted_recovery', '${OPERATOR}')`);
  const assistedCredentialId = JSON.parse(operator(`select app.sys_register_credential('${assistedPrincipal}', '${digestOf(assistedCredential)}',
    'runbook rehearsal ${run}', interval '2 hours', '${OPERATOR}')`)).credential_id;
  const deletionPrincipal = operator(`select app.sys_create_principal('identity-runbooks-deletion-${run}', 'identity_deletion', '${OPERATOR}')`);
  const deletionCredentialId = JSON.parse(operator(`select app.sys_register_credential('${deletionPrincipal}', '${digestOf(deletionCredential)}',
    'runbook rehearsal ${run}', interval '2 hours', '${OPERATOR}')`)).credential_id;
  const envDir = mkdtempSync(join(tmpdir(), 'runbooks-e2e-'));
  const envFile = join(envDir, 'functions.env');
  writeFileSync(envFile, `IDENTITY_RECOVERY_SYSTEM_CREDENTIAL=${assistedCredential}\n`, { mode: 0o600 });
  let serveLog = '';
  const serve = spawn('npx', ['supabase', 'functions', 'serve', '--env-file', envFile], { stdio: ['ignore', 'pipe', 'pipe'], detached: true });
  serve.stdout.on('data', (d) => { serveLog += d; });
  serve.stderr.on('data', (d) => { serveLog += d; });
  const journalDir = join(resolve(process.env.RECOVERY_STATE_DIR ?? join(ROOT, '.recovery-state')), 'journal');
  // The restricted operator runs the deletion worker (no service-role key; the credential only).
  const worker = (args) => {
    const r = spawnSync('node', [join(ROOT, 'tools/identity-deletion/worker.mjs'), 'run', '--journal-dir', journalDir, ...args], {
      encoding: 'utf8',
      env: { ...process.env, SUPABASE_URL: origin, SUPABASE_PUBLISHABLE_KEY: key, IDENTITY_DELETION_SYSTEM_CREDENTIAL: deletionCredential },
    });
    operatorTexts.push(r.stdout ?? '', r.stderr ?? '');
    const lines = (r.stdout ?? '').split('\n').filter((l) => l.startsWith('{')).map((l) => JSON.parse(l));
    return { exit: r.status, result: lines.filter((l) => l.result).pop() ?? null };
  };
  // The member's phone, calling the assisted-recovery function (publishable key only).
  const ipFor = (phone) => `203.0.113.${Number(phone.slice(-3)) % 250}`;
  const assistedFn = async (body) => {
    const r = await http('POST', ASSISTED_FN, { body, xff: ipFor(body.phone_username ?? '+0') });
    return { status: r.status, ...(r.json ?? {}) };
  };

  try {
    for (const [path, up] of [[ASSISTED_FN, 400], [DELETION_FN, 401]]) {
      const deadline = Date.now() + 90_000;
      for (;;) {
        const probe = await fetch(`${origin}${path}`, { method: 'POST', headers: { apikey: key, 'Content-Type': 'application/json' }, body: '{}' })
          .then((r) => r.status).catch(() => 0);
        if (probe === up) break;
        if (Date.now() > deadline) throw new Error('the Edge Functions did not start (is the edge-runtime image present?)');
        await sleep(1000);
      }
    }
    log('R00-precondition', { settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
      leftover_users_removed: Number(leftovers), mail_cleared: await clearMail(), functions_served: true });

    const seeded = async (p) => {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      // The operator's synthetic seeding path (local/staging only; identity-access.md 2.1).
      p.member = psqlRaw(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'identity-runbooks-e2e')`);
      members.add(p.member);
      return created.status;
    };
    const memberRev = (p) => Number(psqlRaw(`select revision from app.identity_members where member_id = '${p.member}'`));
    const grantRev = (p) => Number(psqlRaw(`select revision from app.identity_grant_sets where member_id = '${p.member}'`));
    const onMember = (fn, cmd, p, payload, token) => envelope(fn, token, cmd, memberRev(p), { member_id: p.member, ...payload });
    const fresh = async (p, opts) => { await sleep(EPOCH_WAIT_MS); return signIn(p, opts); };
    const { admin, admin2, applicant, owner, emailer, helped, disputed, changed, leaving, deleting } = people;

    // ======================================================== RB1 first-Admin setup (operator)
    await seeded(admin);
    const beforeBootstrap = Number(psqlRaw(`select app.identity_usable_admin_count()`));
    const boot = operatorTry(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    const a1 = await signIn(admin, { staff: true });
    admin.token = a1.token;
    const adminRoles = await roles(admin.token);
    await seeded(admin2);
    const secondBoot = operatorTry(`select app.identity_bootstrap_admin('${admin2.member}', '${OPERATOR}')`);
    const b0 = await signIn(admin2, { staff: true });
    const g2 = await envelope('identity_grant_command', admin.token, 'identity.grant_role', grantRev(admin2), { member_id: admin2.member, role: 'admin' });
    admin2.token = (await signIn(admin2, { staff: true })).token;
    const audit1 = psqlRaw(`select count(*) from app.identity_access_audit where action = 'admin_bootstrapped' and operator = '${OPERATOR}' and target_member_id = '${admin.member}'`);
    check('R01-first-admin-bootstrap-then-second-admin-by-command', beforeBootstrap === 0 && boot.ok && /^[0-9a-f-]{36}$/.test(boot.out)
      && amrMethods(admin.token).includes('password') && adminRoles?.includes('admin')
      && !secondBoot.ok && /usable Admin exists/.test(secondBoot.error) && b0.status === 200
      && ok(g2) && g2.data?.roles?.includes('admin') && (await roles(admin2.token))?.includes('admin') && audit1 === '1',
      { usable_admins_before: beforeBootstrap, bootstrap_output_is_grant_id_only: /^[0-9a-f-]{36}$/.test(boot.out ?? ''),
        admin_roles: adminRoles, second_bootstrap_refused: !secondBoot.ok, second_admin_by_command: g2.code ?? 'ok', audited: Number(audit1) });

    // ============================== Admin-only support accounts reach no care or finance fixture
    psqlRaw(`insert into app.fixture_scope_targets (scope_kind, scope_id) values ('fixture_care', '${careId}'), ('fixture_finance', '${financeId}')`);
    const cx = await envelope('cells_command', admin.token, 'cells.create_cell', null,
      { name: `${NAME_PREFIX} Cell`, signup_label: `${NAME_PREFIX} Cell`, broad_area: 'SYNTHETIC North' });
    if (cx.data?.cell_id) cells.add(cx.data.cell_id);
    const privateReads = async (token) => ({
      care: (await rpc('fixture_scoped_read', token, { scope_kind: 'fixture_care', scope_id: careId })),
      finance: (await rpc('fixture_scoped_read', token, { scope_kind: 'fixture_finance', scope_id: financeId })),
      cell: (await rpc('cells_private_fixture_read', token, { cell_id: cx.data?.cell_id })),
    });
    const deniedAll = (r) => Object.values(r).every((x) => x.status === 403 && x.json?.details === 'not_granted');
    const shape = (r) => Object.fromEntries(Object.entries(r).map(([k, x]) => [k, `${x.status}:${x.json?.details ?? ''}`]));
    const supportReads = await privateReads(admin2.token);
    check('R02-admin-only-support-reaches-no-care-finance-or-cell-private-fixture', (await roles(admin2.token))?.join() === 'admin'
      && ok(cx) && deniedAll(supportReads), { support_roles: await roles(admin2.token), reads: shape(supportReads) });

    // ===================================================== RB2 applications, linking, reclaim
    applicant.password = password();
    const upA = await signUp(applicant.phone, applicant.password);
    applicant.user = upA.json?.user?.id;
    users.add(applicant.user);
    keep(upA.json?.access_token, upA.json?.refresh_token);
    const sentA = await envelope('identity_application_command', upA.json?.access_token, 'identity.submit_application', null,
      { full_name: applicant.name, cell_choice: { choice: 'not_sure' }, privacy_notice_version: 'draft-2026-10-07' });
    const queueA = (await rpc('identity_admin_application_queue', admin.token)).json?.applications ?? [];
    const inQueue = queueA.some((a) => a.application_id === sentA.data?.application_id);
    const noCheck = await envelope('identity_review_command', admin.token, 'identity.approve_application', sentA.revision,
      { application_id: sentA.data?.application_id });
    const approvedA = await envelope('identity_review_command', admin.token, 'identity.approve_application', sentA.revision,
      { application_id: sentA.data?.application_id, identity_check: 'in_person' });
    applicant.member = psqlRaw(`select coalesce((select member_id::text from app.identity_account_links
                                  where auth_user_id = '${applicant.user}' and link_state <> 'ended'), '')`);
    if (applicant.member) members.add(applicant.member);
    const staleA = await summary(upA.json?.access_token);
    const freshA = await fresh(applicant);
    applicant.token = freshA.token;
    const sumA = await summary(applicant.token);
    check('R10-application-approved-after-identity-check', ok(sentA) && inQueue && noCheck.code === 'validation_failed'
      && ok(approvedA) && staleA.status === 401 && sumA.status === 200,
      { submitted: sentA.code ?? 'ok', in_queue: inQueue, approve_without_check: noCheck.code, approve: approvedA.code ?? 'ok',
        application_session_after_approval: staleA.status, fresh_sign_in: sumA.status });

    // An accountless member record, a squatter on the person's number, the reclaim, the link.
    const created = await envelope('identity_review_command', admin.token, 'identity.create_member', null,
      { full_name: owner.name, consent_basis: 'in_person' });
    owner.member = created.data?.member_id;
    if (owner.member) members.add(owner.member);
    const squatter = { phone: owner.phone, password: password() };
    const upS = await signUp(squatter.phone, squatter.password);
    squatter.user = upS.json?.user?.id;
    users.add(squatter.user);
    keep(upS.json?.access_token, upS.json?.refresh_token);
    owner.password = password();
    const blocked = await signUp(owner.phone, owner.password);
    const reclaimed = await envelope('identity_review_command', admin.token, 'identity.reclaim_phone_username', null,
      { phone_username: owner.phone, identity_check: 'in_person', reason: 'registered_by_someone_else' });
    const squatterSignIn = await signInRaw(squatter.phone, squatter.password);
    const upO = await signUp(owner.phone, owner.password);
    owner.user = upO.json?.user?.id;
    users.add(owner.user);
    keep(upO.json?.access_token, upO.json?.refresh_token);
    const sentO = await envelope('identity_application_command', upO.json?.access_token, 'identity.submit_application', null,
      { full_name: owner.name, cell_choice: { choice: 'not_in_cell' }, privacy_notice_version: 'draft-2026-10-07' });
    const queueO = (await rpc('identity_admin_application_queue', admin.token)).json?.applications ?? [];
    const cand = queueO.find((a) => a.application_id === sentO.data?.application_id)?.candidates?.find((c) => c.member_id === owner.member);
    const ownerBeforeLink = await summary(upO.json?.access_token);
    const linked = await envelope('identity_review_command', admin.token, 'identity.link_application', sentO.revision,
      { application_id: sentO.data?.application_id, member_id: owner.member, identity_check: 'in_person' });
    const freshO = await fresh(owner);
    const sumO = await summary(freshO.token);
    check('R11-accountless-record-reclaim-and-explicit-link', ok(created) && created.data?.account === 'no_login'
      && blocked.status === 422 && ok(reclaimed) && reclaimed.data?.released === true && squatterSignIn.status === 400
      && upO.status === 200 && ok(sentO) && Boolean(cand) && ownerBeforeLink.status === 403 && ownerBeforeLink.detail === 'not_linked'
      && ok(linked) && sumO.status === 200 && sumO.member_id === owner.member,
      { record: created.data?.account, owner_sign_up_while_squatted: blocked.status, reclaim: reclaimed.data?.released ?? reclaimed.code,
        squatter_sign_in_after: squatterSignIn.status, staff_candidate_signals: cand?.signals ?? null,
        matching_name_alone_links_nothing: ownerBeforeLink.detail, link: linked.code ?? 'ok', same_member_after_link: sumO.member_id === owner.member });

    // ====================================================================== RB3 email recovery
    await seeded(emailer);
    emailer.token = (await signIn(emailer)).token;
    const proposed = await envelope('identity_recovery_email_command', emailer.token, 'identity.propose_recovery_email', null, { email: emailer.email });
    const pkceEmail = pkcePair();
    keep(pkceEmail.verifier);
    const askedAt = Date.now();
    const upd = await http('PUT', `/auth/v1/user?redirect_to=${encodeURIComponent(MOBILE_EMAIL_CONFIRMED)}`,
      { token: emailer.token, body: { email: emailer.email, code_challenge: pkceEmail.challenge, code_challenge_method: 's256' } });
    const confirmMail = await mailTo(emailer.email, askedAt);
    const confirmed = await openLink(confirmMail?.link);
    const queueE = (await rpc('identity_admin_recovery_email_queue', admin.token)).json?.proposals ?? [];
    const itemE = queueE.find((q) => q.proposal_id === proposed.data?.proposal_id);
    const approvedE = await envelope('identity_recovery_email_command', admin.token, 'identity.approve_recovery_email', itemE?.revision,
      { proposal_id: itemE?.proposal_id, identity_check: 'in_person' });
    const freshE = await fresh(emailer);
    const withEmail = await rpc('identity_my_member_summary', freshE.token);
    // Forgot password, on the member's own phone and mailbox; staff are not involved.
    const pkceReset = pkcePair();
    keep(pkceReset.verifier);
    await sleep(RESEND_WAIT_MS);
    const resetAt = Date.now();
    const rec = await http('POST', `/auth/v1/recover?redirect_to=${encodeURIComponent(MOBILE_RECOVERY)}`,
      { body: { email: emailer.email, code_challenge: pkceReset.challenge, code_challenge_method: 's256' } });
    const resetMail = await mailTo(emailer.email, resetAt);
    const resetOpen = await openLink(resetMail?.link);
    const exch = await http('POST', '/auth/v1/token?grant_type=pkce', { body: { auth_code: codeFrom(resetOpen.location), code_verifier: pkceReset.verifier } });
    keep(exch.json?.access_token, exch.json?.refresh_token);
    const recoverySummary = await summary(exch.json?.access_token);
    const oldPw = emailer.password;
    const newPw = password();
    const setPw = await http('PUT', '/auth/v1/user', { token: exch.json?.access_token, body: { password: newPw } });
    await http('POST', '/auth/v1/logout?scope=local', { token: exch.json?.access_token });
    emailer.password = newPw;
    const freshE2 = await fresh(emailer);
    const oldPwTry = await signInRaw(emailer.phone, oldPw);
    check('R20-email-added-approved-and-member-resets-alone', ok(proposed) && upd.status === 200 && Boolean(confirmMail?.link)
      && redirectFacts(confirmed.location).base === MOBILE_EMAIL_CONFIRMED && itemE?.verified === true && ok(approvedE)
      && withEmail.json?.has_recovery_email === true && rec.status === 200 && redirectFacts(resetOpen.location).has_code
      && exch.status === 200 && recoverySummary.status === 401 && setPw.status === 200
      && (await summary(freshE2.token)).status === 200 && oldPwTry.status === 400,
      { propose: proposed.code ?? 'ok', confirmation_mail: Boolean(confirmMail?.link), staff_saw_verified: itemE?.verified ?? null,
        approve: approvedE.code ?? 'ok', has_recovery_email: withEmail.json?.has_recovery_email ?? null,
        reset_link_to_member_mailbox: Boolean(resetMail?.link), recovery_session_private_read: recoverySummary.status,
        set_password: setPw.status, old_password: oldPwTry.status });

    // ========================= RB5 (lost device) + RB4 staff-assisted recovery + hold release
    await seeded(helped);
    const h1 = await signIn(helped);
    const h2 = await signIn(helped);
    const lost = await onMember('identity_credential_command', 'identity.place_hold', helped, { reason_code: 'lost_device' }, admin.token);
    const lostHold = lost.data?.holds?.[0];
    const deviceDenied = [(await summary(h1.token)).status, (await refresh(h2.refresh)).status];
    const releaseEarly = await onMember('identity_credential_command', 'identity.release_hold', helped,
      { hold_id: lostHold?.hold_id, identity_check: 'in_person' }, admin2.token);
    // The member's phone: a grant secret in memory, its digest to the function, a code on screen.
    const grantSecret = keep(newGrantSecret());
    keep(digestOf(grantSecret));
    const req = await assistedFn({ action: 'request', phone_username: helped.phone, grant_digest: digestOf(grantSecret) });
    if (req.request_code) codes.push(req.request_code);
    // The office: identity check in person, open the case, type the code the member reads out.
    const opened = await envelope('identity_recovery_command', admin.token, 'identity.open_recovery_case', null,
      { member_id: helped.member, identity_check: 'in_person', evidence: ['photo_id', 'known_in_person'] });
    const issued = await envelope('identity_recovery_command', admin.token, 'identity.issue_recovery_grant', opened.revision,
      { case_id: opened.data?.case_id, request_code: req.request_code });
    const status = await assistedFn({ action: 'status', grant_digest: digestOf(grantSecret) });
    const chosen = password();
    const redeemed = await assistedFn({ action: 'redeem', phone_username: helped.phone, grant_secret: grantSecret, password: chosen });
    const replay = await assistedFn({ action: 'redeem', phone_username: helped.phone, grant_secret: grantSecret, password: password() });
    helped.password = chosen;
    const afterReset = await fresh(helped);
    const stillHeld = await summary(afterReset.token);
    const released = await onMember('identity_credential_command', 'identity.release_hold', helped,
      { hold_id: lostHold?.hold_id, identity_check: 'in_person' }, admin2.token);
    const back = await fresh(helped);
    const caseRead = ((await rpc('identity_admin_recovery_cases', admin.token)).json?.cases ?? []).find((c) => c.case_id === opened.data?.case_id);
    check('R30-lost-device-hold-then-assisted-reset-then-release', ok(lost) && lostHold?.reason_code === 'lost_device'
      && deviceDenied[0] === 401 && deviceDenied[1] >= 400 && releaseEarly.field_errors?.hold_id === 'password_reset_required'
      && req.outcome === 'received' && ok(opened) && ok(issued) && status.outcome === 'ready' && redeemed.outcome === 'succeeded'
      && replay.outcome === 'rejected' && stillHeld.status === 403 && stillHeld.detail === 'review_required'
      && ok(released) && (await summary(back.token)).status === 200
      && caseRead?.case_state === 'completed' && caseRead?.operation?.state === 'succeeded',
      { hold: lostHold?.reason_code, devices_after_hold: deviceDenied, release_before_reset: releaseEarly.field_errors ?? releaseEarly.code,
        request: req.outcome, case: opened.code ?? 'ok', grant_state: issued.data?.grant?.state ?? issued.code, device_status: status.outcome,
        redeem: redeemed.outcome, replay: replay.outcome, after_reset_still_held: stillHeld.detail, release: released.code ?? 'ok',
        case_state: caseRead?.case_state, operation: caseRead?.operation?.state });

    // ====================================================== RB5 dispute hold, credential review
    await seeded(disputed);
    disputed.token = (await signIn(disputed)).token;
    const dHold = await onMember('identity_credential_command', 'identity.place_hold', disputed, { reason_code: 'ownership_dispute' }, admin.token);
    const dView = await summary(disputed.token);
    const dCase = await envelope('identity_recovery_command', admin.token, 'identity.open_recovery_case', null,
      { member_id: disputed.member, identity_check: 'in_person', evidence: ['photo_id'] });
    const dSelf = await onMember('identity_credential_command', 'identity.release_hold', disputed,
      { hold_id: dHold.data?.holds?.[0]?.hold_id, identity_check: 'in_person' }, disputed.token);
    const dRelease = await onMember('identity_credential_command', 'identity.release_hold', disputed,
      { hold_id: dHold.data?.holds?.[0]?.hold_id, identity_check: 'in_person' }, admin2.token);
    const dBack = await fresh(disputed);
    check('R31-dispute-hold-help-screen-only-released-by-admin', ok(dHold) && dHold.data?.holds?.[0]?.hold_kind === 'access_review'
      && dView.status === 403 && dView.detail === 'review_required' && dCase.field_errors?.member_id === 'disputed'
      && dSelf.code === 'forbidden' && ok(dRelease) && (await summary(dBack.token)).status === 200,
      { hold: dHold.data?.holds?.[0]?.hold_kind, member_sees: dView.detail, recovery_while_disputed: dCase.field_errors ?? dCase.code,
        member_releases: dSelf.code, release: dRelease.code ?? 'ok' });

    await seeded(changed);
    changed.token = (await signIn(changed)).token;
    const direct = await http('PUT', `/auth/v1/admin/users/${changed.user}`, { admin: true, body: { phone: changed.direct, phone_confirm: true } });
    const cView = await summary(changed.token);
    const credQueue = (await rpc('identity_admin_credential_queue', admin.token)).json;
    const inReview = (credQueue?.reviews ?? []).some((r) => r.member_id === changed.member);
    const restore = await onMember('identity_credential_command', 'identity.restore_credentials', changed, { identity_check: 'in_person' }, admin.token);
    const oldSession = await summary(changed.token);
    const directNumber = await signInRaw(changed.direct, changed.password);
    const cBack = await fresh(changed);
    check('R32-direct-auth-change-restored-by-credential-review', direct.status === 200 && [401, 403].includes(cView.status)
      && inReview && ok(restore) && oldSession.status === 401
      && directNumber.status === 400 && (await summary(cBack.token)).status === 200,
      { direct_auth_change: direct.status, member_sees: cView.detail, in_staff_review_queue: inReview, restore: restore.code ?? 'ok',
        old_session: oldSession.status, unapproved_number_sign_in: directNumber.status });

    // ============================================================ RB6 deactivation and handover
    psqlRaw(`${LIFECYCLE_EVENTS.map((e) => `select app.contract_register_lifecycle_hook('fixture', '${e}', 'app.fixture_record_lifecycle(jsonb)'::regprocedure);`).join('\n')}
          select app.identity_register_handover_hook('fixture', 'app.fixture_report_handover(jsonb)'::regprocedure);`);
    await seeded(leaving);
    const pastor = await envelope('identity_grant_command', admin.token, 'identity.grant_role', grantRev(leaving), { member_id: leaving.member, role: 'pastor' });
    psqlRaw(`insert into app.fixture_duties (member_id, duty_kind, sole_responsible) values ('${leaving.member}', 'fixture_custody', true)`);
    leaving.token = (await signIn(leaving)).token;
    const refused = await onMember('identity_lifecycle_command', 'identity.deactivate_membership', leaving, { reason_code: 'moved_away' }, admin.token);
    // The owning module hands the work over in its own workflow (the SYNTHETIC fixture owner here).
    psqlRaw(`update app.fixture_duties set sole_responsible = false where member_id = '${leaving.member}'`);
    const deactivated = await onMember('identity_lifecycle_command', 'identity.deactivate_membership', leaving, { reason_code: 'moved_away' }, admin.token);
    const lView = await summary(leaving.token);
    const lFresh = await fresh(leaving);
    const lStatus = (await rpc('identity_my_membership_status', lFresh.token)).json;
    const overview = (await rpc('identity_admin_membership_lifecycle', admin.token)).json;
    const handover = (overview?.handovers ?? []).find((h) => h.member_id === leaving.member);
    const restored = await onMember('identity_lifecycle_command', 'identity.restore_membership', leaving, { identity_check: 'in_person' }, admin2.token);
    const lBack = await fresh(leaving);
    check('R40-deactivation-waits-for-handover-and-restoration-is-reviewed', ok(pastor)
      && refused.field_errors?.member_id === 'handover_required' && ok(deactivated) && deactivated.data?.membership_state === 'deactivated'
      && lView.status === 401 && lStatus?.deactivated === true && Boolean(handover) && ok(restored)
      && (await summary(lBack.token)).status === 200 && (await roles(lBack.token))?.length === 0,
      { last_responsible: refused.field_errors ?? refused.code, deactivate: deactivated.data?.membership_state ?? deactivated.code,
        devices_after: lView.status, member_status_deactivated: lStatus?.deactivated ?? null, handover_recorded: Boolean(handover),
        restore: restored.code ?? 'ok', roles_after_restore: await roles(lBack.token) });

    // ======================================================================== RB7 deletion
    await seeded(deleting);
    const dl = await signIn(deleting);
    const asked = await envelope('identity_deletion_command', dl.token, 'identity.request_my_deletion', null, { confirm: 'delete_my_account' });
    const deletionId = psqlRaw(`select coalesce((select deletion_id::text from app.identity_deletions where member_id = '${deleting.member}'), '')`);
    const deniedAtOnce = await signInRaw(deleting.phone, deleting.password);
    const workerRun = worker(['--deletion', deletionId]);
    const listed = ((await rpc('identity_admin_deletions', admin.token)).json?.deletions ?? []).find((d) => d.deletion_id === deletionId);
    const authLeft = Number(psqlRaw(`select count(*) from auth.users where id = '${deleting.user}'`));
    check('R50-member-deletion-denies-at-once-and-the-worker-completes-it', ok(asked) && asked.data?.signed_out === true
      && deniedAtOnce.status >= 400 && workerRun.exit === 0 && workerRun.result?.result === 'done'
      && psqlRaw(`select deletion_state from app.identity_deletions where deletion_id = '${deletionId}'`) === 'completed'
      && Boolean(listed) && authLeft === 0,
      { request: asked.data?.deletion_state ?? asked.code, sign_in_after_request: deniedAtOnce.status,
        worker: workerRun.result?.result ?? workerRun.exit, staff_list_shows_it: Boolean(listed), auth_user_left: authLeft });

    // ============================================ RB8 the identity-checked last-Admin fallback
    // Admin B steps down: Admin A is the church's only Admin, and A has forgotten the password
    // and has no recovery email. Staff-assisted recovery for A needs another Admin.
    const stepDown = await envelope('identity_grant_command', admin.token, 'identity.revoke_role', grantRev(admin2), { member_id: admin2.member, role: 'admin' });
    const signedOut = await http('POST', '/auth/v1/logout?scope=global', { token: admin.token });
    staffTokens.delete(admin.token);
    const wrongPw = await signInRaw(admin.phone, 'Synthetic-not-the-password');
    const usable = Number(psqlRaw(`select app.identity_usable_admin_count()`));
    const nobodyElse = await envelope('identity_recovery_command', applicant.token, 'identity.open_recovery_case', null,
      { member_id: admin.member, identity_check: 'in_person', evidence: ['photo_id'] });
    const bootstrapRefused = operatorTry(`select app.identity_bootstrap_admin('${applicant.member}', '${OPERATOR}')`);
    const wrongReason = operatorTry(`select app.identity_admin_fallback_grant('${applicant.member}', 'in_person', 'no_usable_admin', 'owner-two', 'RB8-rehearsal-${run}', '${OPERATOR}')`);
    const unknownMember = operatorTry(`select app.identity_admin_fallback_grant('${randomUUID()}', 'in_person', 'admins_unreachable', 'owner-two', 'RB8-rehearsal-${run}', '${OPERATOR}')`);
    const noCheckGiven = operatorTry(`select app.identity_admin_fallback_grant('${applicant.member}', null, 'admins_unreachable', 'owner-two', 'RB8-rehearsal-${run}', '${OPERATOR}')`);
    const selfConfirmed = operatorTry(`select app.identity_admin_fallback_grant('${applicant.member}', 'in_person', 'admins_unreachable', '${OPERATOR}', 'RB8-rehearsal-${run}', '${OPERATOR}')`);
    check('R60-dead-end-without-the-fallback', ok(stepDown) && signedOut.status === 204 && wrongPw.status === 400 && usable === 1
      && nobodyElse.code === 'forbidden' && !bootstrapRefused.ok && !wrongReason.ok && !unknownMember.ok && !noCheckGiven.ok
      && !selfConfirmed.ok && /different person/.test(selfConfirmed.error ?? ''),
      { second_admin_stepped_down: stepDown.code ?? 'ok', admin_a_signed_out: signedOut.status, admin_a_cannot_sign_in: wrongPw.status,
        usable_admins_on_paper: usable, member_opens_case_for_admin_a: nobodyElse.code,
        bootstrap: bootstrapRefused.ok ? 'granted' : 'refused', fallback_with_wrong_reason: wrongReason.ok ? 'granted' : 'refused',
        fallback_unknown_member: unknownMember.ok ? 'granted' : 'refused', fallback_without_identity_check: noCheckGiven.ok ? 'granted' : 'refused',
        fallback_confirmed_by_the_operator_alone: selfConfirmed.ok ? 'granted' : 'refused' });

    // The named owners check the applicant's identity in person; the operator then runs the
    // fallback for that existing, linked member. Nothing about the applicant's Auth row changes.
    const authFacts = () => JSON.parse(psqlRaw(`select json_build_object(
      'encrypted_password', md5(u.encrypted_password), 'updated_at', u.updated_at, 'last_sign_in_at', u.last_sign_in_at,
      'phone', md5(coalesce(u.phone, '')), 'email', md5(coalesce(u.email, '')), 'banned_until', u.banned_until,
      'sessions', (select count(*) from auth.sessions s where s.user_id = u.id),
      'refresh_tokens', (select count(*) from auth.refresh_tokens r where r.user_id = u.id::text),
      'one_time_tokens', (select count(*) from auth.one_time_tokens t where t.user_id = u.id),
      'mfa_factors', (select count(*) from auth.mfa_factors f where f.user_id = u.id))
      from auth.users u where u.id = '${applicant.user}'`));
    const authBefore = authFacts();
    const fallback = operatorTry(`select app.identity_admin_fallback_grant('${applicant.member}', 'in_person', 'admins_unreachable', 'owner-two', 'RB8-rehearsal-${run}', '${OPERATOR}')`);
    const authAfter = authFacts();
    const fallbackOut = fallback.ok ? JSON.parse(fallback.out) : {};
    const outputKeys = Object.keys(fallbackOut).sort();
    const applicantOldSession = await roles(applicant.token); // the session they already had
    const newAdmin = await signIn(applicant, { staff: true });
    const newAdminRoles = await roles(newAdmin.token);
    const fallbackAudit = JSON.parse(psqlRaw(`select json_build_object(
      'access_audit', (select count(*) from app.identity_access_audit where action = 'admin_fallback_granted' and actor_kind = 'operator'
                         and operator = '${OPERATOR}' and target_member_id = '${applicant.member}'),
      'fallback_rows', (select json_agg(reason_code || ':' || identity_check || ':' || usable_admins_before || ':' || confirming_owner
                         || ':' || (case_reference = 'RB8-rehearsal-${run}')) from app.identity_admin_fallbacks
                         where target_member_id = '${applicant.member}'),
      'journal', (select count(*) from app.ops_operator_actions where action = 'admin_fallback_granted' and target_id = '${fallbackOut.grant_id ?? randomUUID()}'))`));
    check('R61-fallback-grants-admin-without-a-credential-shortcut', fallback.ok
      && outputKeys.join() === 'fallback_id,grant_id,member_id,reason_code,revision,usable_admins_before'
      && changedAuthFacts(authBefore, authAfter).length === 0 && applicantOldSession?.includes('admin')
      && newAdmin.status === 200 && amrMethods(newAdmin.token).includes('password') && newAdminRoles?.includes('admin')
      && fallbackAudit.access_audit === 1 && JSON.stringify(fallbackAudit.fallback_rows) === '["admins_unreachable:in_person:1:owner-two:true"]'
      && fallbackAudit.journal === 1,
      { fallback: fallback.ok ? 'granted' : fallback.error, output_keys: outputKeys,
        auth_facts_changed_by_operator: changedAuthFacts(authBefore, authAfter),
        existing_session_now_admin: applicantOldSession?.includes('admin') ?? false,
        own_password_sign_in: newAdmin.status, roles: newAdminRoles, audit: fallbackAudit });

    // The new Admin helps Admin A back through RB4: A's phone, the office, A's own new password.
    const aSecret = keep(newGrantSecret());
    keep(digestOf(aSecret));
    const aReq = await assistedFn({ action: 'request', phone_username: admin.phone, grant_digest: digestOf(aSecret) });
    if (aReq.request_code) codes.push(aReq.request_code);
    const aCase = await envelope('identity_recovery_command', newAdmin.token, 'identity.open_recovery_case', null,
      { member_id: admin.member, identity_check: 'in_person', evidence: ['photo_id', 'known_in_person'] });
    const aGrant = await envelope('identity_recovery_command', newAdmin.token, 'identity.issue_recovery_grant', aCase.revision,
      { case_id: aCase.data?.case_id, request_code: aReq.request_code });
    const aPw = password();
    const aRedeem = await assistedFn({ action: 'redeem', phone_username: admin.phone, grant_secret: aSecret, password: aPw });
    admin.password = aPw;
    const aBack = await fresh(admin, { staff: true });
    const aRoles = await roles(aBack.token);
    const fallbackReads = await privateReads(newAdmin.token);
    const roster = (await rpc('identity_admin_member_grants', aBack.token)).json?.members ?? [];
    const flagged = Object.fromEntries(roster.filter((m) => [admin.member, applicant.member].includes(m.member_id))
      .map((m) => [m.member_id === admin.member ? 'admin_a' : 'fallback_admin', m.admin_via_fallback]));
    check('R62-unreachable-admin-restored-through-assisted-recovery', aReq.outcome === 'received' && ok(aCase) && ok(aGrant)
      && aRedeem.outcome === 'succeeded' && aBack.status === 200 && aRoles?.includes('admin')
      && Number(psqlRaw(`select app.identity_usable_admin_count()`)) === 2 && deniedAll(fallbackReads)
      && flagged.fallback_admin === true && flagged.admin_a === false,
      { request: aReq.outcome, case: aCase.code ?? 'ok', grant_state: aGrant.data?.grant?.state ?? aGrant.code, redeem: aRedeem.outcome,
        admin_a_fresh_sign_in: aBack.status, admin_a_roles: aRoles, usable_admins_after: Number(psqlRaw(`select app.identity_usable_admin_count()`)),
        fallback_admin_private_reads: shape(fallbackReads), roles_and_access_shows_fallback: flagged });

    // ===================================================================== the leak scan
    const staffText = staffTexts.join('\n');
    const operatorText = operatorTexts.join('\n');
    const staffLeaks = findLeaks(staffText, [...secrets, ...codes]);
    const operatorLeaks = findLeaks(operatorText, [...secrets, ...codes]);
    const tokenShaped = (staffText.match(/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g) ?? []).length
      + (operatorText.match(/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g) ?? []).length;
    const hashShaped = (`${staffText}\n${operatorText}`.match(/\$2[aby]\$\d\d\$/g) ?? []).length;
    const serveLeaks = findLeaks(serveLog, secrets);
    // Control: the scan finds a planted value (a password and a request code inside an answer).
    const control = findLeaks(`{"x":"${secrets[secrets.length - 1]}","y":"${codes[0]}"}`, [...secrets, ...codes]).length;
    check('R90-no-password-grant-code-link-or-token-reaches-the-wrong-party', control === 2 && staffTexts.length > 20 && operatorTexts.length > 5
      && staffLeaks.length === 0 && operatorLeaks.length === 0 && tokenShaped === 0 && hashShaped === 0 && serveLeaks.length === 0,
      { scan_control_found: control, values_checked: secrets.length + codes.length, staff_answers_scanned: staffTexts.length, operator_outputs_scanned: operatorTexts.length,
        staff_leaks: staffLeaks.length, operator_leaks: operatorLeaks.length, token_shaped: tokenShaped, password_hash_shaped: hashShaped,
        function_log_leaks: serveLeaks.length });

    const sms = (await http('GET', '/auth/v1/settings')).json?.sms_provider ?? null;
    check('R99-no-sms', !sms, { sms_provider: sms });
  } finally {
    try { process.kill(-serve.pid, 'SIGINT'); } catch { /* already gone */ }
    await sleep(3000);
    try { process.kill(-serve.pid, 'SIGKILL'); } catch { /* already gone */ }
    try { execFileSync('docker', ['rm', '-f', 'supabase_edge_runtime_church-app'], { stdio: 'ignore' }); } catch { /* not running */ }
    rmSync(envDir, { recursive: true, force: true });
    psqlRaw(`select app.sys_revoke_credential('${assistedCredentialId}', '${OPERATOR}'); select app.sys_disable_principal('${assistedPrincipal}', '${OPERATOR}');
             select app.sys_revoke_credential('${deletionCredentialId}', '${OPERATOR}'); select app.sys_disable_principal('${deletionPrincipal}', '${OPERATOR}');`);
    unhook();
    const left = cleanup();
    const mailCleared = await clearMail();
    if (marked) {
      psqlRaw(`delete from app.platform_environment where set_by = 'identity-runbooks-e2e';
            delete from app.platform_environment_history where set_by = 'identity-runbooks-e2e';`);
    }
    log('R100-cleanup', { users_left: Number(left), mail_cleared: mailCleared, credentials_revoked: 2, unmarked: marked });
  }
  // The evidence itself must carry no secret, code, number or address.
  if (evidence) {
    const text = readFileSync(evidence, 'utf8');
    const leaks = findLeaks(text, [...secrets, ...codes, ...allPhones, ...allPhones.map((p) => p.slice(1)), people.emailer.email]);
    results.push({ step: 'R101-evidence-is-content-free', ok: leaks.length === 0 });
    log('R101-evidence-is-content-free', { verdict: leaks.length === 0 ? 'pass' : 'FAIL', leaks: leaks.length });
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
