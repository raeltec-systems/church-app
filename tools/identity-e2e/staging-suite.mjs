#!/usr/bin/env node
// Story 2.14: the closing identity suite against HOSTED STAGING (`tmurpotfluignacfueki`) through
// the public API only (Auth, Data API, the assisted-recovery Edge Function), with the publishable
// key and synthetic accounts. It needs no owner secret: no service-role or secret key, no system
// credential, no SQL. It runs:
//
//   setup     stable synthetic personas (sign-up, application, Admin approval, grants, a login
//             hold, a deactivation) converged idempotently from a state file
//   matrix    every principal (signed out, guest, applicant, member, Admin x2, Pastor, Media,
//             cell leader, cell assistant, two combined-role members, held, deactivated) against
//             every `api` read and every command name, with the exact expected status/detail or
//             envelope code. Admin probes carry payloads that must fail validation: nothing changes.
//   flows     registration and application, review (details, approve, reject, link existing),
//             grants with immediate effect, cells (leader confirmation and transfer), a reviewed
//             phone-username change (approve, reject, withdraw), holds, login hold, deactivation
//             and restoration, deletion requests (member and staff routes) and their denial
//   security  the entry 2 alternate-route cases that need no email or Auth Admin power
//   recovery  the entry 9 staff-assisted cases (single use, reissue, direct password change,
//             cross-member burn, concurrent redemption, lost-device hold, deactivation, unlink),
//             the per-number and per-client limits and the forged x-forwarded-for check, paced
//             to the function's limits (10 attempts per client per 10 minutes, 5 per number per hour)
//
// Email steps (recovery email, forgot password, reset-gate canary), the deletion worker, Auth
// Admin-only routes (magic link, ban) and the operator's SQL (lead pastor) are owner or local-only
// steps; they are listed in the summary, never attempted.
//
// Guards: the origin must be exactly the staging project; every phone number is in the
// fictional +1 202 555 0100-0199 range; names start with `SYNTHETIC `; the state file (personas
// and their passwords) must live OUTSIDE the repository and is written mode 0600; evidence is
// redacted JSONL (never a token, password, grant secret or digest, request code, phone or email).
//
// Usage:
//   STAGING_PUBLISHABLE_KEY=sb_publishable_... \
//   STAGING_SUITE_STATE=/path/outside/repo/staging-suite-state.json \
//   STAGING_SUITE_ADMIN=/path/outside/repo/admin.json   # {"pw": "..."} of the synthetic Admin
//   node tools/identity-e2e/staging-suite.mjs [--phases setup,matrix,flows,security,recovery]
//        [--evidence <file.jsonl>] [--summary <file.md>] [--origin <url>]
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { appendFileSync, existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

import { EPOCH_WAIT_MS, amrMethods, sleep } from './harness.mjs';

export const STAGING_ORIGIN = 'https://tmurpotfluignacfueki.supabase.co';
export const ADMIN_PHONE = '+12025550150';
const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');

/** Refuses anything but the exact staging API origin. */
export function assertStagingOrigin(url) {
  const u = new URL(url);
  if (u.origin !== STAGING_ORIGIN || u.username || u.password || (u.pathname !== '/' && u.pathname !== '')) {
    throw new Error(`refusing non-staging target ${u.origin}`);
  }
  return u.origin;
}

/** The fictional range this suite may use: +1 202 555 0100-0199. */
export function isSuiteFictional(phone) {
  return /^\+120255501\d\d$/.test(phone);
}

/** The persona state (with passwords) must never be inside the repository. */
export function assertStateOutsideRepo(path, repoRoot = REPO_ROOT) {
  if (!path) throw new Error('STAGING_SUITE_STATE is required (a file outside the repository)');
  const abs = resolve(path);
  const root = resolve(repoRoot);
  if (abs === root || abs.startsWith(root + sep)) throw new Error('refusing a state file inside the repository');
  return abs;
}

/** Only a publishable key is accepted. */
export function assertPublishableKey(key) {
  if (!/^sb_publishable_[A-Za-z0-9_-]+$/.test(key ?? '')) throw new Error('STAGING_PUBLISHABLE_KEY must be an sb_publishable_ key');
  return key;
}

const SECRET_KEYS = /^(access_token|refresh_token|password|pw|token|apikey|authorization|grant_secret|grant_digest|secret|digest|request_code|phone|phone_username|email|recovery_email|approved_phone|new_phone|current_phone)$/i;
/** Deep copy with secret- or contact-bearing keys redacted. */
export function redactEvidence(value) {
  if (Array.isArray(value)) return value.map(redactEvidence);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, SECRET_KEYS.test(k) ? '[redacted]' : redactEvidence(v)]));
  }
  if (typeof value === 'string' && /^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\./.test(value)) return '[redacted]';
  return value;
}

// ------------------------------------------------------------------------------------- numbers
const n = (last) => `+12025550${String(last).padStart(3, '0')}`;
/** Stable personas: label -> number and what they are. */
export const PERSONAS = {
  alt: { phone: n(100), kind: 'member' },
  alt2: { phone: n(162), kind: 'member' },
  adm2: { phone: n(101), kind: 'member', roles: ['admin'] },
  guest: { phone: n(102), kind: 'guest' },
  appl: { phone: n(103), kind: 'applicant' },
  mem: { phone: n(104), kind: 'member' },
  pastor: { phone: n(105), kind: 'member', roles: ['pastor'] },
  media: { phone: n(106), kind: 'member', roles: ['media'] },
  leader: { phone: n(107), kind: 'member', scopes: [['cell_leader', 'market']] },
  asst: { phone: n(108), kind: 'member', scopes: [['cell_assistant', 'market']] },
  combo_apm: { phone: n(109), kind: 'member', roles: ['admin', 'pastor', 'media'] },
  combo_pml: { phone: n(110), kind: 'member', roles: ['pastor', 'media'], scopes: [['cell_leader', 'hilltop']] },
  held: { phone: n(111), kind: 'held' },
  deact: { phone: n(112), kind: 'deactivated' },
  credA: { phone: n(113), kind: 'member' },
  credB: { phone: n(114), kind: 'member' },
  credC: { phone: n(163), kind: 'member' },
  credD: { phone: n(164), kind: 'member' },
  life: { phone: n(116), kind: 'member' },
  rec1: { phone: n(117), kind: 'member' },
  rec2: { phone: n(118), kind: 'member' },
  cellm: { phone: n(119), kind: 'member' },
  rec3: { phone: n(184), kind: 'member' },
};
/** Credential subjects rotate: each run makes 3 change requests and the server allows 5 per account per 24 h. */
export const CRED_SUBJECTS = ['credA', 'credB', 'credC', 'credD'];
/** The phone-username change moves a credential subject among these numbers (two always free). */
export const CRED_NUMBERS = [n(113), n(114), n(115), n(163), n(164), n(165)];
/** One-way subjects (deletion, rejection, link-existing) come from this pool. */
export const POOL = [...Array.from({ length: 30 }, (_, i) => n(120 + i)), n(180), n(181), n(182), n(183)];
/** Numbers with no account: the per-number (A23) and per-client (A24) limit checks. */
export const LIMIT_NUMBERS = Array.from({ length: 11 }, (_, i) => n(185 + i));
/** A23 alternates between two no-account numbers (5 requests per number per hour). */
export const A23_NUMBERS = [n(185), n(198)];
export const DIRECT_PHONE_TARGET = n(196);
export const UNKNOWN_NUMBER = n(197);
for (const p of [...Object.values(PERSONAS).map((x) => x.phone), ...CRED_NUMBERS, ...POOL, ...LIMIT_NUMBERS, ...A23_NUMBERS,
  DIRECT_PHONE_TARGET, UNKNOWN_NUMBER, ADMIN_PHONE]) {
  if (!isSuiteFictional(p)) throw new Error(`not fictional: ${p}`);
}

export const CELLS = {
  riverside: '00000000-0000-4000-c000-00000000c241',
  hilltop: '00000000-0000-4000-c000-00000000c242',
  market: '00000000-0000-4000-c000-00000000c243',
};

// ---------------------------------------------------------------------- the permission matrix
/** Matrix principals: how the server sees each one. */
export const PRINCIPALS = {
  anon: { outcome: 'anon' },
  guest: { outcome: 'not_linked' },
  appl: { outcome: 'not_linked' },
  mem: { outcome: 'granted', roles: [] },
  admin: { outcome: 'granted', roles: ['admin'] },
  adm2: { outcome: 'granted', roles: ['admin'] },
  pastor: { outcome: 'granted', roles: ['pastor'] },
  media: { outcome: 'granted', roles: ['media'] },
  leader: { outcome: 'granted', roles: [], cellScope: 'market' },
  asst: { outcome: 'granted', roles: [], cellScope: 'market' },
  combo_apm: { outcome: 'granted', roles: ['admin', 'pastor', 'media'] },
  combo_pml: { outcome: 'granted', roles: ['pastor', 'media'], cellScope: 'hilltop' },
  held: { outcome: 'review_required' },
  deact: { outcome: 'deactivated' },
};

const ADMIN_READS = ['identity_admin_application_queue', 'identity_admin_credential_queue', 'identity_admin_deletions',
  'identity_admin_member_grants', 'identity_admin_member_search', 'identity_admin_membership_lifecycle',
  'identity_admin_recovery_cases', 'identity_admin_recovery_email_queue', 'cells_admin_overview'];
/** Every `api` read with its arguments. */
export const READS = {
  ...Object.fromEntries(ADMIN_READS.map((r) => [r, {}])),
  identity_my_access: {},
  identity_my_member_summary: {},
  cells_my_cell: {},
  cells_leader_queue: {},
  cells_private_fixture_read: { cell_id: CELLS.market },
  fixture_scoped_read_care: { fn: 'fixture_scoped_read', args: { scope_kind: 'fixture_care', scope_id: '00000000-0000-4000-b000-000000e21401' } },
  fixture_scoped_read_finance: { fn: 'fixture_scoped_read', args: { scope_kind: 'fixture_finance', scope_id: '00000000-0000-4000-b000-000000e21402' } },
  identity_my_application: {},
  cells_signup_options: {},
  identity_my_credentials: {},
  identity_my_recovery_email: {},
  identity_my_membership_status: {},
};

const denial = (p) => {
  if (p.outcome === 'anon') return { status: 401 };
  if (p.outcome === 'review_required') return { status: 403, detail: 'review_required' };
  return { status: 403, detail: 'not_linked' };
};

/** The exact expected answer of a read for a principal: {status, detail?}. */
export function expectRead(p, read) {
  if (p.outcome === 'anon') return { status: 401 };
  const granted = p.outcome === 'granted';
  const roles = p.roles ?? [];
  if (ADMIN_READS.includes(read)) {
    if (!granted) return denial(p);
    return roles.includes('admin') ? { status: 200 } : { status: 403, detail: 'not_granted' };
  }
  switch (read) {
    case 'identity_my_access':
    case 'identity_my_member_summary':
    case 'cells_my_cell':
      return granted ? { status: 200 } : denial(p);
    case 'cells_leader_queue':
      if (!granted) return denial(p);
      return p.cellScope ? { status: 200 } : { status: 403, detail: 'not_granted' };
    case 'cells_private_fixture_read':
      if (!granted) return denial(p);
      return p.cellScope === 'market' ? { status: 200 } : { status: 403, detail: 'not_granted' };
    case 'fixture_scoped_read_care':
    case 'fixture_scoped_read_finance':
      return granted ? { status: 403, detail: 'not_granted' } : denial(p);
    case 'identity_my_application':
    case 'cells_signup_options':
      if (granted || p.outcome === 'not_linked') return { status: 200 };
      if (p.outcome === 'review_required') return { status: 403, detail: 'review_required' };
      return { status: 403, detail: 'not_applicant' };
    case 'identity_my_credentials':
    case 'identity_my_recovery_email':
      return granted || p.outcome === 'review_required' ? { status: 200 } : denial(p);
    case 'identity_my_membership_status':
      return { status: 200 };
    default:
      throw new Error(`no expectation for ${read}`);
  }
}

const ADMIN_COMMANDS = {
  identity_grant_command: ['identity.grant_role', 'identity.revoke_role', 'identity.grant_scope', 'identity.revoke_scope'],
  identity_review_command: ['identity.approve_application', 'identity.link_application', 'identity.request_application_details',
    'identity.reject_application', 'identity.create_member', 'identity.unlink_account', 'identity.reclaim_phone_username'],
  identity_recovery_email_command: ['identity.approve_recovery_email', 'identity.reject_recovery_email'],
  identity_credential_command: ['identity.approve_credential_change', 'identity.reject_credential_change', 'identity.place_hold',
    'identity.release_hold', 'identity.restore_credentials', 'identity.accept_credentials'],
  identity_recovery_command: ['identity.open_recovery_case', 'identity.issue_recovery_grant', 'identity.cancel_recovery_case',
    'identity.reconcile_recovery_operation'],
  identity_lifecycle_command: ['identity.deactivate_membership', 'identity.restore_membership'],
  identity_deletion_command: ['identity.request_member_deletion'],
};
const MEMBER_COMMANDS = {
  identity_recovery_email_command: ['identity.propose_recovery_email'],
  identity_credential_command: ['identity.request_credential_change'],
  identity_deletion_command: ['identity.request_my_deletion'],
};
const WITHDRAW_COMMANDS = {
  identity_recovery_email_command: ['identity.withdraw_recovery_email'],
  identity_credential_command: ['identity.withdraw_credential_change'],
};
const APPLICATION_COMMANDS = { identity_application_command: ['identity.submit_application', 'identity.correct_application'] };
const CELLS_COMMANDS = { cells_command: ['cells.create_cell', 'cells.update_cell', 'cells.request_change', 'cells.confirm_request',
  'cells.decline_request', 'cells.cancel_request'] };
const FIXTURE_COMMANDS = { fixture_counter_command: ['fixture_counter.create', 'fixture_counter.increment'] };
/** The system route (anon may call it): no user session and no missing credential gets through. */
const SYSTEM_COMMANDS = { system_command: ['identity.deletion_queue', 'identity.assisted_recovery_status'] };
/** Commands whose expected_revision is null (creates). */
const NULL_REVISION = new Set(['identity.create_member', 'identity.reclaim_phone_username', 'identity.open_recovery_case',
  'identity.propose_recovery_email', 'identity.request_credential_change', 'identity.request_my_deletion',
  'identity.submit_application', 'cells.create_cell', 'fixture_counter.create', 'identity.deletion_queue',
  'identity.assisted_recovery_status']);

const flat = (groups, group) => Object.entries(groups).flatMap(([fn, cmds]) => cmds.map((cmd) => ({ fn, cmd, group })));
/** Every command name the `api` schema accepts, with its endpoint and access group. */
export const COMMANDS = [
  ...flat(ADMIN_COMMANDS, 'admin'), ...flat(MEMBER_COMMANDS, 'member'), ...flat(WITHDRAW_COMMANDS, 'withdraw'),
  ...flat(APPLICATION_COMMANDS, 'application'), ...flat(CELLS_COMMANDS, 'cells'), ...flat(FIXTURE_COMMANDS, 'fixture'),
  ...flat(SYSTEM_COMMANDS, 'system'),
];

/** The probe payload: unknown fields only, so an authorised caller is refused by validation. */
export function probePayload(cmd) {
  return cmd === 'identity.request_my_deletion' ? { confirm: 'matrix_probe_not_a_confirmation' } : { matrix_probe: true };
}
export function probeEnvelope(cmd) {
  return { version: 1, command: cmd, request_id: randomUUID(), expected_revision: NULL_REVISION.has(cmd) ? null : 1, payload: probePayload(cmd) };
}

/** The exact expected envelope code (or HTTP 401 for a signed-out caller). */
export function expectCommand(p, { group, cmd }) {
  // The system route: the publishable key alone reaches the credential check (no credential:
  // unauthenticated); any user session is refused outright (forbidden, user_session_rejected).
  if (group === 'system') return { code: p.outcome === 'anon' ? 'unauthenticated' : 'forbidden' };
  if (p.outcome === 'anon') return { status: 401 };
  const granted = p.outcome === 'granted';
  const roles = p.roles ?? [];
  switch (group) {
    case 'admin': return { code: granted && roles.includes('admin') ? 'validation_failed' : 'forbidden' };
    case 'member': return { code: granted ? 'validation_failed' : 'forbidden' };
    case 'withdraw': return { code: granted ? 'validation_failed' : 'forbidden' };
    case 'application': return { code: p.outcome === 'not_linked' ? 'validation_failed' : 'forbidden' };
    // Any live member passes the cells authorizer; creating or editing a cell is Admin-only and
    // checked before the payload, the request commands check their capacity after validation.
    case 'cells':
      if (['cells.create_cell', 'cells.update_cell'].includes(cmd)) return { code: granted && roles.includes('admin') ? 'validation_failed' : 'forbidden' };
      return { code: granted ? 'validation_failed' : 'forbidden' };
    case 'fixture': return { code: 'forbidden' };
    default: throw new Error(`no expectation for ${group}`);
  }
}

/** A sliding-window pacer (count per window), persisted in the state between runs. */
export function makePacer(times, { limit, windowMs, marginMs = 15000, now = () => Date.now() }) {
  return {
    times,
    /** Milliseconds to wait before `count` more events fit in the window. */
    waitFor(count) {
      const t = now();
      const live = times.filter((x) => x > t - windowMs).sort((a, b) => a - b);
      times.splice(0, times.length, ...live);
      if (count > limit) throw new Error(`cannot fit ${count} events in a window of ${limit}`);
      const excess = live.length + count - limit;
      if (excess <= 0) return 0;
      return live[excess - 1] + windowMs + marginMs - t;
    },
    record(count = 1) { for (let i = 0; i < count; i += 1) times.push(now()); },
  };
}

// --------------------------------------------------------------------------------------- run
function parseArgs(argv) {
  const get = (flag) => { const i = argv.indexOf(flag); return i > 0 ? argv[i + 1] : null; };
  return {
    phases: (get('--phases') ?? 'setup,matrix,flows,security,recovery').split(','),
    evidence: get('--evidence'),
    summary: get('--summary'),
    origin: get('--origin') ?? STAGING_ORIGIN,
  };
}

async function main() {
  const args = parseArgs(process.argv);
  const origin = assertStagingOrigin(args.origin);
  const key = assertPublishableKey(process.env.STAGING_PUBLISHABLE_KEY);
  const statePath = assertStateOutsideRepo(process.env.STAGING_SUITE_STATE);
  const adminFile = assertStateOutsideRepo(process.env.STAGING_SUITE_ADMIN);
  const adminPw = JSON.parse(readFileSync(adminFile, 'utf8')).pw;
  if (!adminPw) throw new Error('STAGING_SUITE_ADMIN has no pw');

  const state = existsSync(statePath) ? JSON.parse(readFileSync(statePath, 'utf8')) : {};
  state.personas ??= {};
  state.pool ??= { used: [] };
  state.fn ??= { client: [], numbers: {} };
  state.auth ??= [];
  state.cred ??= {};
  state.limits ??= {};
  const save = () => {
    const tmp = `${statePath}.tmp`;
    writeFileSync(tmp, JSON.stringify(state), { mode: 0o600 });
    renameSync(tmp, statePath);
  };
  save();

  // ---- evidence
  if (args.evidence) writeFileSync(args.evidence, '');
  const results = [];
  const findings = [];
  const matrixRows = [];
  const log = (step, data) => {
    const line = { step, target: 'STAGING', at: new Date().toISOString(), ...redactEvidence(data) };
    if (args.evidence) appendFileSync(args.evidence, JSON.stringify(line) + '\n');
    if (!step.startsWith('M-')) console.log(JSON.stringify(line));
  };
  const check = (step, ok, data = {}) => {
    results.push({ step, ok: Boolean(ok) });
    log(step, { verdict: ok ? 'pass' : 'FAIL', ...data });
    return Boolean(ok);
  };
  const finding = (step, data) => { findings.push(step); log(step, { verdict: 'finding', ...data }); };

  // ---- HTTP
  const authPacer = makePacer(state.auth, { limit: 25, windowMs: 5 * 60_000, marginMs: 5000 });
  const http = async (method, path, { token, body, profile = 'api', headers = {} } = {}) => {
    const h = { apikey: key, 'Content-Type': 'application/json', ...headers };
    if (token) h.Authorization = `Bearer ${token}`;
    if (profile && path.startsWith('/rest/')) h[method === 'GET' ? 'Accept-Profile' : 'Content-Profile'] = profile;
    for (let attempt = 0; ; attempt += 1) {
      const res = await fetch(`${origin}${path}`, { method, headers: h, body: body === undefined ? undefined : JSON.stringify(body) });
      const text = await res.text();
      let json = null;
      try { json = text ? JSON.parse(text) : null; } catch { /* non-JSON */ }
      if (res.status === 429 && path.startsWith('/auth/') && attempt < 8) {
        log('auth-rate-limited-waiting', { path: path.split('?')[0], attempt });
        await sleep(60_000);
        continue;
      }
      return { status: res.status, json };
    }
  };
  const authCall = async (path, body) => {
    const wait = authPacer.waitFor(1);
    if (wait > 0) { log('auth-pacing', { wait_s: Math.round(wait / 1000) }); await sleep(wait); }
    authPacer.record(); save();
    return http('POST', path, { body });
  };
  const signIn = (phone, pw) => authCall('/auth/v1/token?grant_type=password', { phone, password: pw });
  const signUp = (phone, pw) => authCall('/auth/v1/signup', { phone, password: pw });
  const refresh = (rt) => http('POST', '/auth/v1/token?grant_type=refresh_token', { body: { refresh_token: rt } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body });
  const read = async (fn, token, body = {}) => {
    const r = await rpc(fn, token, body);
    // The body stays out of evidence lines (non-enumerable): only status and detail are logged.
    return Object.defineProperty({ status: r.status, detail: r.json?.details ?? undefined }, 'json', { value: r.json, enumerable: false });
  };
  const command = async (fn, token, cmd, expected, payload, requestId = randomUUID()) => {
    const r = await rpc(fn, token, { version: 1, command: cmd, request_id: requestId, expected_revision: expected ?? null, payload });
    return { status: r.status, ...(r.json ?? {}) };
  };
  const newPassword = () => `Synthetic-${randomBytes(15).toString('base64url')}`;
  const outcomeOf = (r) => (r?.code ? { code: r.code, field_errors: r.field_errors } : { ok: r?.status });

  // ---- the synthetic Admin (A) and personas
  const A = { label: 'admin', phone: ADMIN_PHONE, pw: adminPw };
  const tokenOf = async (p, { fresh = false } = {}) => {
    if (!fresh && p.token && Date.now() - p.tokenAt < 40 * 60_000) return p.token;
    const s = await signIn(p.phone, p.pw);
    p.token = s.json?.access_token; p.refresh = s.json?.refresh_token; p.tokenAt = Date.now();
    p.lastSignIn = s.status;
    return p.token;
  };
  const freshAfterEpoch = async (p) => { await sleep(EPOCH_WAIT_MS); return tokenOf(p, { fresh: true }); };
  const P = {};
  const persona = (label) => {
    if (P[label]) return P[label];
    const st = (state.personas[label] ??= { phone: PERSONAS[label]?.phone });
    P[label] = { label, st, get phone() { return st.phone; }, get pw() { return st.pw; }, get member() { return st.member; } };
    return P[label];
  };
  const signUpPersona = async (p) => {
    if (!isSuiteFictional(p.phone)) throw new Error('not fictional');
    p.st.pw = newPassword(); save();
    const up = await signUp(p.phone, p.st.pw);
    if (up.status !== 200 || !up.json?.access_token) throw new Error(`sign-up for ${p.label} failed: ${up.status} ${up.json?.error_code ?? ''}`);
    p.st.user = up.json?.user?.id; save();
    p.token = up.json.access_token; p.refresh = up.json.refresh_token; p.tokenAt = Date.now();
    return up;
  };
  const ensureAccount = async (p) => {
    if (!p.st.pw) return signUpPersona(p);
    await tokenOf(p, { fresh: true });
    if (!p.token) throw new Error(`persona ${p.label} cannot sign in (${p.lastSignIn}); fix the state file`);
    return null;
  };
  const adminToken = async () => tokenOf(A);
  const privacyVersion = async (token) => (await read('identity_my_application', token)).json?.privacy_notice?.version;
  const signupOption = async (token, cell) => ((await read('cells_signup_options', token)).json?.options ?? []).find((o) => o.cell_id === cell);
  const submitApplication = async (p, name, cell) => {
    const token = await tokenOf(p);
    const choice = cell ? { choice: 'cell', cell_id: cell, cell_revision: (await signupOption(token, cell))?.revision } : { choice: 'not_sure' };
    return command('identity_application_command', token, 'identity.submit_application', null,
      { full_name: name, cell_choice: choice, privacy_notice_version: await privacyVersion(token) });
  };
  const queueItem = async (applicationId) =>
    ((await read('identity_admin_application_queue', await adminToken())).json?.applications ?? []).find((a) => a.application_id === applicationId);
  const review = async (cmd, expected, payload, token) => command('identity_review_command', token ?? await adminToken(), cmd, expected, payload);
  const approve = async (applicationId) => {
    const item = await queueItem(applicationId);
    return review('identity.approve_application', item?.revision, { application_id: applicationId, identity_check: 'in_person' });
  };
  const memberRow = async (memberId) => {
    let after = {};
    for (let page = 0; page < 20; page += 1) {
      const r = (await read('identity_admin_member_search', await adminToken(), { query: null, ...after })).json;
      const hit = (r?.members ?? []).find((m) => m.member_id === memberId);
      if (hit) return hit;
      if (!r?.next) return null;
      after = { after_display_name: r.next.after_display_name, after_member_id: r.next.after_member_id };
    }
    return null;
  };
  const memberRevision = async (memberId) => (await memberRow(memberId))?.revision;
  const grantsRow = async (memberId) => {
    let after = {};
    for (let page = 0; page < 20; page += 1) {
      const r = (await read('identity_admin_member_grants', await adminToken(), after)).json;
      const hit = (r?.members ?? []).find((m) => m.member_id === memberId);
      if (hit) return hit;
      if (!r?.next) return null;
      after = { after_display_name: r.next.after_display_name, after_member_id: r.next.after_member_id };
    }
    return null;
  };
  const grant = (cmd, expected, payload, token) => command('identity_grant_command', token, cmd, expected, payload);
  const credCmd = (token, cmd, expected, payload) => command('identity_credential_command', token, cmd, expected, payload);
  const lifecycleCmd = (token, cmd, expected, payload) => command('identity_lifecycle_command', token, cmd, expected, payload);
  /** An open hold as Admin's Access reviews list it: {hold_id, member_id, member_revision, hold_kind, reason_code}. */
  const openHold = async (holdId) => ((await read('identity_admin_credential_queue', await adminToken())).json?.holds ?? [])
    .find((h) => h.hold_id === holdId);
  const lifecycleView = async () => (await read('identity_admin_membership_lifecycle', await adminToken())).json ?? {};

  /** Approved member with a usable session (applies and is approved when needed). */
  const ensureMember = async (p, name) => {
    await ensureAccount(p);
    let s = await read('identity_my_member_summary', p.token);
    if (s.status === 200) { p.st.member = s.json?.member_id; save(); return s; }
    if (s.detail !== 'not_linked') return s;
    if ((await read('identity_my_membership_status', p.token)).json?.deactivated) return s;
    const mine = (await read('identity_my_application', p.token)).json?.application;
    let appId = ['submitted', 'needs_details'].includes(mine?.application_state) ? mine.application_id : null;
    if (!appId) {
      const sent = await submitApplication(p, name, null);
      appId = sent.data?.application_id;
      if (!appId) throw new Error(`application for ${p.label} refused: ${sent.code}`);
    }
    const ok = await approve(appId);
    if (!ok.data?.member_id) throw new Error(`approval for ${p.label} refused: ${ok.code} ${JSON.stringify(ok.field_errors ?? {})}`);
    p.st.member = ok.data.member_id; save();
    await freshAfterEpoch(p);
    return read('identity_my_member_summary', p.token);
  };

  /** Converges a member's roles and scopes to the wanted set (never A's). */
  const convergeGrants = async (p, roles = [], scopes = []) => {
    const want = new Set([...roles.map((r) => `r:${r}`), ...scopes.map(([k, c]) => `s:${k}:${CELLS[c]}`)]);
    const row = await grantsRow(p.member);
    if (!row) throw new Error(`no grants row for ${p.label}`);
    let rev = row.grants?.revision;
    const have = new Set([...(row.grants?.roles ?? []).map((r) => `r:${r}`), ...(row.grants?.scopes ?? []).map((s) => `s:${s.scope_kind}:${s.scope_id}`)]);
    const changes = [];
    for (const g of have) if (!want.has(g)) changes.push(['revoke', g]);
    for (const g of want) if (!have.has(g)) changes.push(['grant', g]);
    for (const [op, g] of changes) {
      const [t, a, b] = g.split(':');
      const r = t === 'r'
        ? await grant(`identity.${op}_role`, rev, { member_id: p.member, role: a }, await adminToken())
        : await grant(`identity.${op}_scope`, rev, { member_id: p.member, scope_kind: a, scope_id: b }, await adminToken());
      if (r.code) throw new Error(`${op} ${g} for ${p.label}: ${r.code}`);
      rev = r.revision;
    }
    return changes.length;
  };

  const phase = (name) => args.phases.includes(name);
  const ownerSteps = [];

  // =============================================================================== setup
  await tokenOf(A, { fresh: true });
  const aAccess = await read('identity_my_access', A.token);
  if (!check('S00-synthetic-admin-signed-in', A.lastSignIn === 200 && amrMethods(A.token).includes('password') && aAccess.json?.roles?.includes('admin'),
    { sign_in: A.lastSignIn, amr: amrMethods(A.token), roles: aAccess.json?.roles })) throw new Error('the synthetic Admin cannot act');
  A.member = aAccess.json?.member_id;

  const setupPersonas = async () => {
    const out = {};
    for (const [label, def] of Object.entries(PERSONAS)) {
      const p = persona(label);
      if (def.kind === 'guest') { await ensureAccount(p); out[label] = 'guest'; continue; }
      if (def.kind === 'applicant') {
        await ensureAccount(p);
        const mine = (await read('identity_my_application', p.token)).json?.application;
        if (!['submitted', 'needs_details'].includes(mine?.application_state)) {
          const sent = await submitApplication(p, 'SYNTHETIC Suite Applicant', CELLS.market);
          if (sent.code) throw new Error(`applicant submission refused: ${sent.code}`);
        }
        out[label] = 'applicant';
        continue;
      }
      if (def.kind === 'held') {
        await ensureAccount(p);
        const s = await read('identity_my_member_summary', p.token);
        if (s.status === 200 || s.detail === 'not_linked') {
          await ensureMember(p, 'SYNTHETIC Suite Held');
          await convergeGrants(p);
          const placed = await credCmd(await adminToken(), 'identity.place_hold', await memberRevision(p.member),
            { member_id: p.member, reason_code: 'login_disabled' });
          if (placed.code) throw new Error(`login hold for held persona: ${placed.code}`);
          await freshAfterEpoch(p);
        }
        out[label] = 'held';
        continue;
      }
      if (def.kind === 'deactivated') {
        await ensureAccount(p);
        const st = (await read('identity_my_membership_status', p.token)).json;
        if (!st?.deactivated) {
          await ensureMember(p, 'SYNTHETIC Suite Deactivated');
          const d = await lifecycleCmd(await adminToken(), 'identity.deactivate_membership', await memberRevision(p.member),
            { member_id: p.member, reason_code: 'church_decision' });
          if (d.code) throw new Error(`deactivation for deact persona: ${d.code}`);
          await freshAfterEpoch(p);
        }
        out[label] = 'deactivated';
        continue;
      }
      let s = await ensureMember(p, `SYNTHETIC Suite ${label}`);
      // Heal a persona an interrupted earlier run left held or deactivated (reviewed Admin actions).
      if (s.status === 403 && s.detail === 'review_required' && p.member) {
        const queue = (await read('identity_admin_credential_queue', await adminToken())).json?.holds ?? [];
        for (const h of queue.filter((x) => x.member_id === p.member)) {
          const release = async (rev) => credCmd(await adminToken(), 'identity.release_hold', rev, { member_id: p.member, hold_id: h.hold_id, identity_check: 'in_person' });
          let r = await release(h.member_revision);
          if (r.field_errors?.hold_id === 'password_reset_required') {
            log('S02-heal-assisted-reset', { persona: label, ...(await assistedReset(p)) });
            r = await release((await openHold(h.hold_id))?.member_revision);
          }
          log('S02-heal-release-hold', { persona: label, outcome: outcomeOf(r) });
        }
        s = await read('identity_my_member_summary', await freshAfterEpoch(p));
      } else if (s.status === 403 && s.detail === 'not_linked' && p.member && (await read('identity_my_membership_status', p.token)).json?.deactivated) {
        const row = ((await lifecycleView()).deactivated ?? []).find((m) => m.member_id === p.member);
        const r = await lifecycleCmd(await adminToken(), 'identity.restore_membership', row?.member_revision ?? row?.revision, { member_id: p.member, identity_check: 'in_person' });
        log('S02-heal-restore-membership', { persona: label, outcome: outcomeOf(r) });
        s = await read('identity_my_member_summary', await freshAfterEpoch(p));
      }
      if (s.status !== 200) throw new Error(`persona ${label} has no member access: ${s.status} ${s.detail}`);
      out[label] = await convergeGrants(p, def.roles ?? [], def.scopes ?? []);
    }
    return out;
  };

  // ---- the assisted-recovery function (paced to its limits)
  const FN = `${origin}/functions/v1/identity-assisted-recovery`;
  const clientPacer = makePacer(state.fn.client, { limit: 10, windowMs: 10 * 60_000, marginMs: 20_000 });
  const reserve = async (count) => {
    const wait = clientPacer.waitFor(count);
    if (wait > 0) { log('function-pacing', { wait_s: Math.round(wait / 1000), attempts: count }); await sleep(wait); }
  };
  const fn = async (body, headers = {}, { counted = true, retry = true } = {}) => {
    for (let attempt = 0; ; attempt += 1) {
      if (counted) { clientPacer.record(); save(); }
      const res = await fetch(FN, { method: 'POST', headers: { apikey: key, 'content-type': 'application/json', ...headers }, body: JSON.stringify(body) });
      const j = await res.json().catch(() => null);
      if (j?.outcome === 'rate_limited' && retry && attempt === 0) {
        log('function-unexpected-rate-limit-waiting', { action: body.action });
        await sleep(10 * 60_000 + 20_000);
        continue;
      }
      return { status: res.status, ...(j ?? {}) };
    }
  };
  const secret = () => `arg_${randomBytes(32).toString('base64url')}`;
  const digest = (s) => createHash('sha256').update(s).digest('hex');
  // Per-number budget: 5 help requests per number per hour (persisted, so back-to-back runs wait).
  const request = async (phone) => {
    const numberPacer = makePacer((state.fn.numbers[phone] ??= []), { limit: 5, windowMs: 3600_000, marginMs: 20_000 });
    const wait = numberPacer.waitFor(1);
    if (wait > 0) { log('number-pacing', { wait_s: Math.round(wait / 1000) }); await sleep(wait); }
    numberPacer.record(); save();
    const s = secret();
    const r = await fn({ action: 'request', phone_username: phone, grant_digest: digest(s) });
    return { s, r };
  };
  const status = (s) => fn({ action: 'status', grant_digest: digest(s) }, {}, { counted: false });
  const redeem = (phone, s, pw) => fn({ action: 'redeem', phone_username: phone, grant_secret: s, password: pw });
  const recCmd = (cmd, expected, payload, token) => command('identity_recovery_command', token, cmd, expected, payload);
  const openCase = async (member) => {
    const cases = (await read('identity_admin_recovery_cases', await adminToken())).json?.cases ?? [];
    const open = cases.find((c) => c.member_id === member && c.case_state === 'open');
    if (open) return { case_id: open.case_id, revision: open.revision };
    const o = await recCmd('identity.open_recovery_case', null, { member_id: member, identity_check: 'in_person', evidence: ['known_in_person'] }, await adminToken());
    return { case_id: o.data?.case_id, revision: o.revision, code: o.code };
  };
  const issue = async (member, code) => {
    const c = await openCase(member);
    const ig = await recCmd('identity.issue_recovery_grant', c.revision, { case_id: c.case_id, request_code: code }, await adminToken());
    return { ...ig, case_id: c.case_id };
  };
  const cancelOpen = async (member) => {
    const cases = (await read('identity_admin_recovery_cases', await adminToken())).json?.cases ?? [];
    const open = cases.find((c) => c.member_id === member && c.case_state === 'open');
    if (open) await recCmd('identity.cancel_recovery_case', open.revision, { case_id: open.case_id, reason: 'opened_in_error' }, await adminToken());
  };
  /** Staff-assisted reset of a persona's password (heals a hold that needs the member's own reset). */
  const assistedReset = async (p) => {
    await reserve(2);
    const q = await request(p.phone);
    const g = await issue(p.member, q.r.request_code);
    const pw = newPassword();
    const r = await redeem(p.phone, q.s, pw);
    if (r.outcome === 'succeeded') { p.st.pw = pw; save(); }
    return { request: q.r.outcome, grant: g.data?.grant?.state ?? g.code, redeem: r.outcome };
  };

  if (phase('setup') || phase('matrix') || phase('flows') || phase('security') || phase('recovery')) {
    const converged = await setupPersonas();
    check('S01-personas-converged', true, { personas: Object.keys(converged).length, grant_changes: converged });
  }

  // =============================================================================== matrix
  if (phase('matrix')) {
    const tokens = { anon: null, admin: await adminToken() };
    for (const label of Object.keys(PRINCIPALS)) {
      if (label === 'anon' || label === 'admin') continue;
      tokens[label] = await tokenOf(persona(label), { fresh: true });
    }
    let cells = 0; let bad = 0;
    for (const [label, principal] of Object.entries(PRINCIPALS)) {
      const token = tokens[label];
      for (const [name, def] of Object.entries(READS)) {
        const fn = def.fn ?? name;
        const body = def.args ?? (def.cell_id ? { cell_id: def.cell_id } : {});
        const want = expectRead(principal, name);
        const got = await read(fn, token, body);
        const ok = got.status === want.status && (want.detail === undefined || got.detail === want.detail);
        cells += 1; if (!ok) bad += 1;
        matrixRows.push({ principal: label, surface: name, kind: 'read', want, got: { status: got.status, detail: got.detail }, ok });
        if (!ok) check(`M-read-${label}-${name}`, false, { want, got: { status: got.status, detail: got.detail } });
        else log(`M-read-${label}-${name}`, { verdict: 'pass', status: got.status, detail: got.detail });
      }
      for (const c of COMMANDS) {
        const want = expectCommand(principal, c);
        const r = await rpc(c.fn, token, probeEnvelope(c.cmd));
        const got = r.status === 200 ? { code: r.json?.code ?? 'success', field_errors: r.json?.field_errors } : { status: r.status };
        const ok = want.status ? got.status === want.status : got.code === want.code;
        cells += 1; if (!ok) bad += 1;
        matrixRows.push({ principal: label, surface: c.cmd, kind: 'command', fn: c.fn, want, got, ok });
        if (!ok) check(`M-cmd-${label}-${c.cmd}`, false, { want, got });
        else log(`M-cmd-${label}-${c.cmd}`, { verdict: 'pass', ...got });
      }
    }
    // Only Admin may grant; lead_pastor is the operator's alone; nothing an Admin holds reaches care/finance.
    check('M00-matrix', bad === 0, { principals: Object.keys(PRINCIPALS).length, reads: Object.keys(READS).length,
      commands: COMMANDS.length, cells, mismatches: bad });
    ownerSteps.push('Lead-pastor rows of the matrix: the role is designated only by the restricted operator (`app.identity_designate_lead_pastor`, SQL); the suite proves an Admin cannot grant it (G15).');
  }

  // =============================================================================== flows
  const poolNext = (purpose) => {
    const free = POOL.find((x) => !state.pool.used.some((u) => u.phone === x));
    if (!free) throw new Error('the fictional pool is exhausted: the owner deletes the pool Auth users (or runs the deletion worker) and clears state.pool');
    state.pool.used.push({ phone: free, purpose, at: new Date().toISOString() }); save();
    return free;
  };
  const poolPersona = (label, purpose) => {
    const p = { label, st: { phone: poolNext(purpose) } };
    Object.defineProperties(p, { phone: { get: () => p.st.phone }, pw: { get: () => p.st.pw }, member: { get: () => p.st.member } });
    state.personas[`${label}-${p.st.phone.slice(-3)}`] = p.st;
    return p;
  };

  if (phase('flows')) {
    const summary = (token) => read('identity_my_member_summary', token);
    const myAccess = (token) => read('identity_my_access', token);

    // ---------------------------------------------------------------- registration and review
    const sub = poolPersona('reg', 'registration, approval, member deletion');
    const up = await signUpPersona(sub);
    const before = await summary(sub.token);
    const mine0 = (await read('identity_my_application', sub.token)).json;
    check('R10-phone-password-registration', up.status === 200 && amrMethods(sub.token).includes('password')
      && before.status === 403 && before.detail === 'not_linked' && mine0?.accepting_applications === true && mine0?.application === null,
      { sign_up: up.status, amr: amrMethods(sub.token), member_read: before, accepting: mine0?.accepting_applications });
    const options = (await read('cells_signup_options', sub.token)).json?.options ?? [];
    const safeKeys = options.every((o) => Object.keys(o).every((k) => ['cell_id', 'label', 'broad_area', 'revision'].includes(k)));
    const sent = await submitApplication(sub, 'SYNTHETIC Suite Registration', CELLS.market);
    const afterApply = await summary(sub.token);
    check('R11-application-with-safe-cell-choice', sent.status === 200 && sent.data?.church_status === 'awaiting_approval'
      && sent.data?.cell_status === 'requested' && options.length >= 3 && safeKeys && afterApply.detail === 'not_linked',
      { church_status: sent.data?.church_status, cell_status: sent.data?.cell_status, options: options.length, safe_projection: safeKeys,
        member_read_while_pending: afterApply });
    const item = await queueItem(sent.data?.application_id);
    const ask = await review('identity.request_application_details', item?.revision, { application_id: sent.data?.application_id, requested: ['full_name'] });
    const mine1 = (await read('identity_my_application', sub.token)).json?.application;
    const corrected = await command('identity_application_command', sub.token, 'identity.correct_application', mine1?.revision,
      { application_id: sent.data?.application_id, full_name: 'SYNTHETIC Suite Registration Corrected' });
    check('R12-details-requested-and-corrected', ask.status === 200 && mine1?.church_status === 'details_requested'
      && mine1?.details_requested?.includes('full_name') && corrected.data?.church_status === 'awaiting_approval'
      && !('candidates' in (mine1 ?? {})),
      { ask: outcomeOf(ask), applicant_sees: mine1?.church_status, requested: mine1?.details_requested, corrected: corrected.data?.church_status });
    const approved = await approve(sent.data?.application_id);
    sub.st.member = approved.data?.member_id; save();
    const preApproval = await summary(sub.token);
    await freshAfterEpoch(sub);
    const granted = await summary(sub.token);
    const cell0 = (await read('cells_my_cell', sub.token)).json;
    check('R13-approval-links-and-needs-fresh-sign-in', approved.status === 200 && approved.data?.church_status === 'approved'
      && preApproval.status === 401 && granted.status === 200 && granted.json?.member_id === sub.member
      && cell0?.primary === null && cell0?.open_request?.cell_id === CELLS.market,
      { approve: approved.data?.church_status, pre_approval_session: preApproval, fresh_sign_in: granted.status,
        cell_primary: cell0?.primary ?? null, cell_request: cell0?.open_request ? { kind: cell0.open_request.kind, origin: cell0.open_request.origin } : null });

    // Rejection and the re-apply cooldown.
    const rej = poolPersona('rejected', 'rejected application');
    await signUpPersona(rej);
    const rSent = await submitApplication(rej, 'SYNTHETIC Suite Rejected', null);
    const rItem = await queueItem(rSent.data?.application_id);
    const rejected = await review('identity.reject_application', rItem?.revision, { application_id: rSent.data?.application_id, reason: 'contact_church_office' });
    const rMine = (await read('identity_my_application', rej.token)).json?.application;
    const again = await submitApplication(rej, 'SYNTHETIC Suite Rejected Again', null);
    check('R14-reject-and-cooldown', rejected.status === 200 && rMine?.church_status === 'not_approved'
      && rMine?.decision_reason === 'contact_church_office' && Boolean(rMine?.reapply_from) && again.code === 'rate_limited'
      && (await summary(rej.token)).detail === 'not_linked',
      { reject: outcomeOf(rejected), applicant_sees: rMine?.church_status, reason: rMine?.decision_reason, reapply_now: again.code });

    // An accountless member record, then an explicit link of a later account to it.
    const created = await review('identity.create_member', null, { full_name: 'SYNTHETIC Suite Accountless', consent_basis: 'in_person' });
    const noLogin = await memberRow(created.data?.member_id);
    const link = poolPersona('linked', 'link existing, staff-route deletion');
    await signUpPersona(link);
    const lSent = await submitApplication(link, 'SYNTHETIC Suite Accountless', null);
    const lItem = await queueItem(lSent.data?.application_id);
    const cand = lItem?.candidates?.find((c) => c.member_id === created.data?.member_id);
    const notYet = await summary(link.token);
    const linked = await review('identity.link_application', lItem?.revision,
      { application_id: lSent.data?.application_id, member_id: created.data?.member_id, identity_check: 'in_person' });
    link.st.member = created.data?.member_id; save();
    await freshAfterEpoch(link);
    const linkedSummary = await summary(link.token);
    const applicantView = JSON.stringify((await read('identity_my_application', link.token)).json ?? {});
    check('R15-accountless-member-then-explicit-link', created.status === 200 && noLogin?.account === 'no_login'
      && cand?.signals?.includes('same_name') && cand?.link_eligible === true && notYet.detail === 'not_linked'
      && linked.status === 200 && linkedSummary.status === 200 && linkedSummary.json?.member_id === created.data?.member_id
      && !applicantView.includes('candidates'),
      { created: outcomeOf(created), account: noLogin?.account, candidate_signals: cand?.signals, link_eligible: cand?.link_eligible,
        before_link: notYet, link: outcomeOf(linked), same_member_id: linkedSummary.json?.member_id === created.data?.member_id });

    // -------------------------------------------------------------- grants, immediate effect
    const mem = persona('mem');
    const s1 = await tokenOf(mem, { fresh: true });
    const s2 = (await signIn(mem.phone, mem.pw)).json?.access_token;
    const g0 = await myAccess(s1);
    const gMedia = await grant('identity.grant_role', g0.json?.revision, { member_id: mem.member, role: 'media' }, await adminToken());
    const seen = [await myAccess(s1), await myAccess(s2)];
    const gRevoke = await grant('identity.revoke_role', gMedia.revision, { member_id: mem.member, role: 'media' }, await adminToken());
    const gone = [await myAccess(s1), await myAccess(s2)];
    check('G10-grant-and-revoke-at-next-call', gMedia.status === 200 && seen.every((x) => x.json?.roles?.join() === 'media')
      && gRevoke.status === 200 && gone.every((x) => x.json?.roles?.length === 0),
      { grant: outcomeOf(gMedia), seen: seen.map((x) => x.json?.roles), revoke: outcomeOf(gRevoke), after: gone.map((x) => x.json?.roles), re_sign_in: false });
    const stale = await grant('identity.grant_role', g0.json?.revision, { member_id: mem.member, role: 'media' }, await adminToken());
    const rq = randomUUID();
    const gAdm = await command('identity_grant_command', await adminToken(), 'identity.grant_role', gRevoke.revision, { member_id: mem.member, role: 'admin' }, rq);
    const replay = await command('identity_grant_command', await adminToken(), 'identity.grant_role', gRevoke.revision, { member_id: mem.member, role: 'admin' }, rq);
    const changed = await command('identity_grant_command', await adminToken(), 'identity.grant_role', gRevoke.revision, { member_id: mem.member, role: 'media' }, rq);
    const tabWhile = await read('identity_admin_member_grants', s2);
    const gAdmOff = await grant('identity.revoke_role', gAdm.revision, { member_id: mem.member, role: 'admin' }, await adminToken());
    const tabAfter = await read('identity_admin_member_grants', s2);
    const tabCmd = await grant('identity.grant_role', 1, { member_id: persona('media').member, role: 'pastor' }, s2);
    check('G11-stale-replay-and-removed-admin-tab', stale.code === 'conflict' && Boolean(stale.current_revision)
      && gAdm.status === 200 && replay.revision === gAdm.revision && changed.code === 'conflict'
      && tabWhile.status === 200 && gAdmOff.status === 200 && tabAfter.status === 403 && tabAfter.detail === 'not_granted' && tabCmd.code === 'forbidden',
      { stale: stale.code, replay_same: replay.revision === gAdm.revision, changed_payload: changed.code, tab_while_admin: tabWhile.status,
        tab_after_revoke: tabAfter, tab_command: tabCmd.code });
    const aRev = (await myAccess(await adminToken())).json?.revision;
    const selfGrant = await grant('identity.grant_role', aRev, { member_id: A.member, role: 'media' }, await adminToken());
    const lead = await grant('identity.grant_role', gAdmOff.revision, { member_id: mem.member, role: 'lead_pastor' }, await adminToken());
    check('G12-self-grant-and-lead-pastor-refused', selfGrant.code === 'forbidden' && selfGrant.field_errors?.member_id === 'unsupported'
      && lead.code === 'forbidden' && lead.field_errors?.role === 'unsupported',
      { self_grant: outcomeOf(selfGrant), lead_pastor: outcomeOf(lead) });
    const combo = persona('combo_apm');
    const extra = (await signIn(combo.phone, combo.pw)).json;
    const out = await http('POST', '/auth/v1/logout?scope=local', { token: extra?.access_token });
    const signedOutCmd = await grant('identity.grant_role', 1, { member_id: mem.member, role: 'media' }, extra?.access_token);
    check('G13-signed-out-admin-session-refused', out.status === 204 && signedOutCmd.code === 'unauthenticated', { logout: out.status, command: signedOutCmd.code });

    // --------------------------------------------------------------------------------- cells
    const cm = persona('cellm');
    const cmTok = await tokenOf(cm, { fresh: true });
    let myCell = (await read('cells_my_cell', cmTok)).json;
    if (myCell?.open_request) {
      await command('cells_command', cmTok, 'cells.cancel_request', myCell.revision, { request_id: myCell.open_request.request_id });
      myCell = (await read('cells_my_cell', cmTok)).json;
    }
    const from = myCell?.primary?.cell_id ?? null;
    const target = from === CELLS.market ? CELLS.hilltop : CELLS.market;
    const targetLeader = persona(target === CELLS.market ? 'leader' : 'combo_pml');
    const otherLeader = persona(target === CELLS.market ? 'combo_pml' : 'leader');
    const opt = await signupOption(cmTok, target);
    const asked = await command('cells_command', cmTok, 'cells.request_change', myCell?.revision, { cell_id: target, cell_revision: opt?.revision });
    const qT = (await read('cells_leader_queue', await tokenOf(targetLeader))).json;
    const reqT = qT?.cells?.find((c) => c.cell_id === target)?.requests?.find((r) => r.member_id === cm.member);
    const qO = (await read('cells_leader_queue', await tokenOf(otherLeader))).json;
    const otherSees = (qO?.cells ?? []).flatMap((c) => c.requests ?? []).some((r) => r.member_id === cm.member);
    const notLeader = await command('cells_command', await tokenOf(persona('pastor')), 'cells.confirm_request', reqT?.member_revision, { request_id: reqT?.request_id });
    const wrongLeader = await command('cells_command', await tokenOf(otherLeader), 'cells.confirm_request', reqT?.member_revision, { request_id: reqT?.request_id });
    const beforeNew = await read('cells_private_fixture_read', cmTok, { cell_id: target });
    const confirmed = await command('cells_command', await tokenOf(targetLeader), 'cells.confirm_request', reqT?.member_revision, { request_id: reqT?.request_id });
    const newRead = await read('cells_private_fixture_read', cmTok, { cell_id: target });
    const oldRead = from ? await read('cells_private_fixture_read', cmTok, { cell_id: from }) : { status: 403, detail: 'not_granted' };
    const mineAfter = (await read('cells_my_cell', cmTok)).json;
    const churchStill = await summary(cmTok);
    check('C10-leader-confirms-and-transfer-ends-old-access', asked.status === 200 && Boolean(reqT) && !otherSees
      && notLeader.code === 'forbidden' && wrongLeader.code === 'forbidden' && beforeNew.status === 403
      && confirmed.status === 200 && mineAfter?.primary?.cell_id === target && newRead.status === 200
      && oldRead.status === 403 && churchStill.status === 200,
      { transfer: Boolean(from), request_kind: asked.data?.open_request?.kind, target_leader_sees: Boolean(reqT), other_leader_sees: otherSees,
        non_leader_confirm: notLeader.code, other_leader_confirm: wrongLeader.code, private_new_before: beforeNew.status,
        confirm: outcomeOf(confirmed), private_new_after: newRead.status, private_old_after: oldRead.status, church_membership: churchStill.status });
    const overview = (await read('cells_admin_overview', await adminToken())).json;
    const ovMember = overview?.members?.find((m) => m.member_id === cm.member);
    check('C11-admin-overview-shows-confirmed-cell', ovMember?.cell_id === target, { admin_overview_cell_matches: ovMember?.cell_id === target });

    // ----------------------------------------------------------- reviewed phone-username change
    const day = Date.now() - 24 * 3600_000;
    const pick = CRED_SUBJECTS.find((l) => (state.cred[l] ?? []).filter((t) => t > day).length <= 2);
    if (!pick) {
      check('K00-credential-budget', false, { reason: 'every credential subject used its 5 requests per 24 h; rerun later' });
    } else {
      const cs = persona(pick);
      await ensureMember(cs, `SYNTHETIC Suite ${pick}`);
      const used = new Set(CRED_SUBJECTS.map((l) => state.personas[l]?.phone));
      const free = CRED_NUMBERS.find((x) => !used.has(x));
      const t1 = await tokenOf(cs, { fresh: true });
      const k1 = await credCmd(t1, 'identity.request_credential_change', null, { change_kind: 'phone_username', phone_username: free });
      (state.cred[pick] ??= []).push(Date.now()); save();
      const pendingView = (await read('identity_my_credentials', t1)).json;
      const stillOk = await summary(t1);
      const qItem = ((await read('identity_admin_credential_queue', await adminToken())).json?.changes ?? []).find((c) => c.change_id === k1.data?.change_id);
      const selfApprove = await credCmd(t1, 'identity.approve_credential_change', qItem?.revision, { change_id: qItem?.change_id, identity_check: 'in_person' });
      const ok1 = await credCmd(await adminToken(), 'identity.approve_credential_change', qItem?.revision, { change_id: qItem?.change_id, identity_check: 'in_person' });
      const oldPhone = cs.phone;
      if (ok1.status === 200 && !ok1.code) { cs.st.phone = free; save(); }
      const oldSession = await summary(t1);
      const oldNumber = await signIn(oldPhone, cs.pw);
      await sleep(EPOCH_WAIT_MS);
      const t2 = await tokenOf(cs, { fresh: true });
      const s2v = await summary(t2);
      check('K10-phone-username-change-approved', k1.status === 200 && k1.data?.state === 'pending' && pendingView?.pending_change?.change_kind === 'phone_username'
        && stillOk.status === 200 && selfApprove.code === 'forbidden' && qItem?.phone_available === true
        && ok1.status === 200 && ok1.data?.state === 'approved' && oldSession.status === 401 && oldNumber.status === 400
        && s2v.status === 200 && s2v.json?.phone_username === free,
        { request: k1.data?.state ?? k1.code, access_while_pending: stillOk.status, member_self_approve: selfApprove.code,
          approve: ok1.data?.state ?? ok1.code, old_session: oldSession.status, old_number_sign_in: oldNumber.status,
          new_number_sign_in: cs.lastSignIn, new_username_bound: s2v.json?.phone_username === free, sms_sent: false });
      const k2 = await credCmd(t2, 'identity.request_credential_change', null, { change_kind: 'phone_username', phone_username: oldPhone });
      state.cred[pick].push(Date.now()); save();
      const q2 = ((await read('identity_admin_credential_queue', await adminToken())).json?.changes ?? []).find((c) => c.change_id === k2.data?.change_id);
      const rj = await credCmd(await adminToken(), 'identity.reject_credential_change', q2?.revision, { change_id: q2?.change_id, reason: 'identity_not_confirmed' });
      const afterReject = (await read('identity_my_credentials', t2)).json;
      const k3 = await credCmd(t2, 'identity.request_credential_change', null, { change_kind: 'phone_username', phone_username: oldPhone });
      state.cred[pick].push(Date.now()); save();
      const wd = await credCmd(t2, 'identity.withdraw_credential_change', k3.revision, { change_id: k3.data?.change_id });
      const afterWithdraw = (await read('identity_my_credentials', t2)).json;
      const still = await summary(t2);
      check('K11-reject-and-withdraw-change-nothing', k2.status === 200 && rj.status === 200 && !afterReject?.pending_change
        && k3.status === 200 && wd.status === 200 && !afterWithdraw?.pending_change && still.status === 200 && still.json?.phone_username === free,
        { reject: rj.data?.state ?? rj.code, withdraw: wd.data?.state ?? wd.code, username_unchanged: still.json?.phone_username === free });
    }

    // ------------------------------------------------------------------ holds and lifecycle
    const adm2 = persona('adm2');
    const life = persona('life');
    await ensureMember(life, 'SYNTHETIC Suite life');
    const lt = await tokenOf(life, { fresh: true });
    const h1 = await credCmd(await adminToken(), 'identity.place_hold', await memberRevision(life.member), { member_id: life.member, reason_code: 'security_concern' });
    const heldRead = await summary(lt);
    const heldCreds = (await read('identity_my_credentials', lt)).json;
    const holdId = h1.data?.holds?.[0]?.hold_id;
    const selfHold = await credCmd(await adminToken(), 'identity.place_hold', 1, { member_id: A.member, reason_code: 'security_concern' });
    const noCheck = await credCmd(await tokenOf(adm2), 'identity.release_hold', h1.revision, { member_id: life.member, hold_id: holdId });
    const rel = await credCmd(await tokenOf(adm2), 'identity.release_hold', h1.revision, { member_id: life.member, hold_id: holdId, identity_check: 'in_person' });
    const afterRelOld = await summary(lt);
    const afterRel = await summary(await freshAfterEpoch(life));
    check('H10-security-hold-help-only-then-reviewed-release', h1.status === 200 && heldRead.status === 403 && heldRead.detail === 'review_required'
      && heldCreds?.access === 'review_required' && !('phone_username' in (heldCreds ?? {})) && selfHold.code === 'forbidden'
      && noCheck.code === 'validation_failed' && rel.status === 200 && afterRelOld.status === 401 && afterRel.status === 200,
      { hold: h1.data?.holds?.[0]?.hold_kind ?? h1.code, held_session: heldRead, own_read_access: heldCreds?.access,
        own_read_has_username: 'phone_username' in (heldCreds ?? {}), admin_self_hold: selfHold.code, release_without_check: noCheck.code,
        release: outcomeOf(rel), session_opened_during_hold: afterRelOld.status, fresh_sign_in: afterRel.status });

    const la = await tokenOf(life, { fresh: true });
    const lb = (await signIn(life.phone, life.pw)).json;
    const lh = await credCmd(await adminToken(), 'identity.place_hold', await memberRevision(life.member), { member_id: life.member, reason_code: 'login_disabled' });
    const devA = await summary(la);
    const devB = await refresh(lb?.refresh_token);
    const lfresh = await summary(await freshAfterEpoch(life));
    const lstatus = (await read('identity_my_membership_status', life.token)).json;
    const lrel = await credCmd(await tokenOf(adm2), 'identity.release_hold', lh.revision, { member_id: life.member, hold_id: lh.data?.holds?.[0]?.hold_id, identity_check: 'in_person' });
    const lback = await summary(await freshAfterEpoch(life));
    check('L10-login-hold-revokes-both-devices', lh.status === 200 && lh.data?.holds?.[0]?.reason_code === 'login_disabled'
      && devA.status === 401 && devB.status >= 400 && lfresh.status === 403 && lfresh.detail === 'review_required'
      && lstatus?.deactivated === false && lrel.status === 200 && lback.status === 200,
      { hold: lh.data?.holds?.[0]?.reason_code ?? lh.code, device_a: devA.status, device_b_refresh: devB.status, fresh_sign_in: lfresh,
        deactivated: lstatus?.deactivated, release: outcomeOf(lrel), after_release: lback.status });

    const lr0 = await grantsRow(life.member);
    await grant('identity.grant_role', lr0?.grants?.revision, { member_id: life.member, role: 'media' }, await adminToken());
    const ld0 = await tokenOf(life, { fresh: true });
    const dc = await lifecycleCmd(await adminToken(), 'identity.deactivate_membership', await memberRevision(life.member), { member_id: life.member, reason_code: 'moved_away' });
    const dOld = await summary(ld0);
    const dFresh = await freshAfterEpoch(life);
    const dRead = await summary(dFresh);
    const dStatus = (await read('identity_my_membership_status', dFresh)).json;
    const dApply = await read('identity_my_application', dFresh);
    const view = await lifecycleView();
    const listed = (view.deactivated ?? []).find((m) => m.member_id === life.member);
    const restoreNoCheck = await lifecycleCmd(await tokenOf(adm2), 'identity.restore_membership', dc.revision, { member_id: life.member });
    const restored = await lifecycleCmd(await tokenOf(adm2), 'identity.restore_membership', dc.revision, { member_id: life.member, identity_check: 'in_person' });
    const rFresh = await freshAfterEpoch(life);
    const rRead = await summary(rFresh);
    const rRoles = (await myAccess(rFresh)).json?.roles;
    const notDeact = await lifecycleCmd(await tokenOf(adm2), 'identity.restore_membership', restored.revision, { member_id: life.member, identity_check: 'in_person' });
    check('L11-deactivate-and-reviewed-restore', dc.status === 200 && dOld.status === 401 && dRead.status === 403 && dRead.detail === 'not_linked'
      && dStatus?.deactivated === true && dApply.status === 403 && dApply.detail === 'not_applicant' && Boolean(listed)
      && restoreNoCheck.code === 'validation_failed' && restored.status === 200 && rRead.status === 200 && rRoles?.length === 0
      && notDeact.code === 'conflict' && notDeact.field_errors?.member_id === 'not_deactivated',
      { deactivate: outcomeOf(dc), old_session: dOld.status, fresh_sign_in: dRead, own_status_deactivated: dStatus?.deactivated,
        can_reapply: dApply, listed_for_restore: Boolean(listed), restore_without_check: restoreNoCheck.code, restore: outcomeOf(restored),
        after_restore: rRead.status, roles_after_restore: rRoles, restore_again: outcomeOf(notDeact) });

    // ------------------------------------------------------------------------------ deletion
    const canUse = await command('identity_deletion_command', await adminToken(), 'identity.request_member_deletion',
      await memberRevision(sub.member), { member_id: sub.member, identity_check: 'in_person' });
    const subTok = await tokenOf(sub, { fresh: true });
    const subRefresh = sub.refresh;
    const own = await command('identity_deletion_command', subTok, 'identity.request_my_deletion', null, { confirm: 'delete_my_account' });
    const afterOwn = await summary(subTok);
    const afterRefresh = await refresh(subRefresh);
    const afterSignIn = await signIn(sub.phone, sub.pw);
    const delView = (await read('identity_admin_deletions', await adminToken())).json;
    const myDel = delView?.deletions?.find((d) => d.member_id === sub.member);
    // The stale-revision answer carries the current revision; the second try meets the deletion guard.
    const restoreStale = await lifecycleCmd(await tokenOf(adm2), 'identity.restore_membership', 1, { member_id: sub.member, identity_check: 'in_person' });
    const restoreDeleted = restoreStale.current_revision
      ? await lifecycleCmd(await tokenOf(adm2), 'identity.restore_membership', restoreStale.current_revision, { member_id: sub.member, identity_check: 'in_person' })
      : restoreStale;
    check('D10-member-requests-own-deletion-access-ends', canUse.code === 'conflict' && canUse.field_errors?.member_id === 'member_can_use_app'
      && own.status === 200 && !own.code && afterOwn.status === 401 && afterRefresh.status >= 400 && afterSignIn.status === 400
      && Boolean(myDel) && restoreDeleted.field_errors?.member_id === 'deletion_requested',
      { staff_route_while_member_can_use_app: outcomeOf(canUse), request: outcomeOf(own), same_session_after: afterOwn.status,
        refresh_after: afterRefresh.status, password_sign_in_after: afterSignIn.status, sign_in_error: afterSignIn.json?.error_code,
        listed_for_admin: Boolean(myDel), deletion_steps: myDel?.steps?.map((s) => `${s.step}:${s.state}`), restore_attempt: outcomeOf(restoreDeleted) });

    const lh2 = await credCmd(await adminToken(), 'identity.place_hold', await memberRevision(link.member), { member_id: link.member, reason_code: 'login_disabled' });
    const sameAdmin = await command('identity_deletion_command', await adminToken(), 'identity.request_member_deletion', lh2.revision,
      { member_id: link.member, identity_check: 'in_person' });
    const second = await command('identity_deletion_command', await tokenOf(adm2), 'identity.request_member_deletion', lh2.revision,
      { member_id: link.member, identity_check: 'in_person' });
    const linkSignIn = await signIn(link.phone, link.pw);
    check('D11-staff-route-needs-a-second-admin', lh2.status === 200 && sameAdmin.code === 'conflict' && sameAdmin.field_errors?.member_id === 'second_admin_required'
      && second.status === 200 && !second.code && linkSignIn.status === 400,
      { hold: outcomeOf(lh2), same_admin: outcomeOf(sameAdmin), second_admin: outcomeOf(second), sign_in_after: linkSignIn.status });
    ownerSteps.push('Deletion erasure: run the deletion worker on staging (`tools/identity-deletion/worker.mjs run`, owner credential) and check that both suite deletions complete; the suite proves only the request and its denial of access.');
  }

  // ============================================================================= security
  if (phase('security')) {
    const alt = persona('alt');
    const wrong = await signIn(alt.phone, `${alt.pw}-wrong`);
    const unknown = await signIn(UNKNOWN_NUMBER, newPassword());
    check('X10-generic-credential-errors', wrong.status === 400 && unknown.status === 400
      && wrong.json?.error_code === unknown.json?.error_code, { wrong_password: [wrong.status, wrong.json?.error_code], unknown_number: [unknown.status, unknown.json?.error_code] });
    const dup = await signUp(alt.phone, newPassword());
    check('X11-duplicate-username-refused', dup.status >= 400 && !dup.json?.access_token, { status: dup.status, error: dup.json?.error_code });
    const nopw = await authCall('/auth/v1/signup', { phone: UNKNOWN_NUMBER });
    const anonymous = await authCall('/auth/v1/signup', {});
    check('X12-passwordless-and-anonymous-sign-up-refused', nopw.status >= 400 && !nopw.json?.access_token && anonymous.status >= 400 && !anonymous.json?.access_token,
      { passwordless: [nopw.status, nopw.json?.error_code], anonymous: [anonymous.status, anonymous.json?.error_code] });
    const otp = await http('POST', '/auth/v1/otp', { body: { phone: alt.phone, create_user: false } });
    const altOk = await read('identity_my_member_summary', await tokenOf(alt, { fresh: true }));
    check('X13-phone-otp-no-sms-no-session', otp.status >= 400 && !otp.json?.access_token && altOk.status === 200,
      { otp: [otp.status, otp.json?.error_code ?? otp.json?.msg], member_access_unchanged: altOk.status });
    const tblApp = await http('GET', '/rest/v1/identity_members?select=member_id', { token: alt.token, profile: 'app' });
    const tblApi = await http('GET', '/rest/v1/identity_members?select=member_id', { token: alt.token, profile: 'api' });
    check('X14-direct-table-query-denied', tblApp.status === 406 && tblApi.status === 404, { app_profile: tblApp.status, api_profile: tblApi.status });
    const rf = await refresh(alt.refresh);
    const rfRead = await read('identity_my_member_summary', rf.json?.access_token);
    check('X15-refresh-keeps-access', rf.status === 200 && amrMethods(rf.json?.access_token).includes('password') && rfRead.status === 200,
      { refresh: rf.status, amr: amrMethods(rf.json?.access_token), read: rfRead.status });
    const d1 = (await signIn(alt.phone, alt.pw)).json;
    const d2 = (await signIn(alt.phone, alt.pw)).json;
    const lo = await http('POST', '/auth/v1/logout?scope=local', { token: d1?.access_token });
    const d1r = await read('identity_my_member_summary', d1?.access_token);
    const d2r = await read('identity_my_member_summary', d2?.access_token);
    check('X16-local-sign-out-ends-only-that-session', lo.status === 204 && d1r.status === 401 && d1r.detail === 'untrusted_session' && d2r.status === 200,
      { logout: lo.status, signed_out_session: d1r, other_session: d2r.status });
    const [h, pl, sg] = String(d2?.access_token).split('.');
    const payload = JSON.parse(Buffer.from(pl, 'base64url').toString('utf8'));
    payload.role = 'service_role';
    const forged = `${h}.${Buffer.from(JSON.stringify(payload)).toString('base64url')}.${sg}`;
    const none = `${Buffer.from(JSON.stringify({ alg: 'none', typ: 'JWT' })).toString('base64url')}.${pl}.`;
    const fr = await read('identity_my_member_summary', forged);
    const nr = await read('identity_my_member_summary', none);
    check('X17-tampered-and-unsigned-jwt-refused', fr.status === 401 && nr.status === 401, { tampered: fr.status, alg_none: nr.status });
    // A stolen live session changes the phone username directly through Auth (phone_autoconfirm on,
    // no SMS): Auth accepts it, but the binding is not approved, so the account waits in access
    // review; the old number no longer signs in. An Admin restores the approved binding: Auth gets
    // the approved number back, every session is revoked, and only the approved number works.
    const direct = await http('PUT', '/auth/v1/user', { token: d2?.access_token, body: { phone: DIRECT_PHONE_TARGET } });
    const changingSession = await read('identity_my_member_summary', d2?.access_token);
    const oldNumberAfter = await signIn(alt.phone, alt.pw);
    const thief = (await signIn(DIRECT_PHONE_TARGET, alt.pw)).json;
    const thiefRead = await read('identity_my_member_summary', thief?.access_token);
    const thiefCreds = (await read('identity_my_credentials', thief?.access_token)).json;
    const rc = await credCmd(await adminToken(), 'identity.restore_credentials', await memberRevision(alt.member), { member_id: alt.member, identity_check: 'in_person' });
    const thiefAfter = await read('identity_my_member_summary', thief?.access_token);
    const directNumberAfter = await signIn(DIRECT_PHONE_TARGET, alt.pw);
    const approvedAfter = await read('identity_my_member_summary', await freshAfterEpoch(alt));
    check('X18-direct-phone-change-review-then-restore', direct.status === 200 && changingSession.status !== 200
      && oldNumberAfter.status === 400 && thiefRead.status === 403 && thiefRead.detail === 'review_required'
      && thiefCreds?.access === 'review_required' && !('phone_username' in (thiefCreds ?? {}))
      && rc.status === 200 && !rc.code && thiefAfter.status === 401 && directNumberAfter.status === 400 && approvedAfter.status === 200,
      { put_user_phone: direct.status, changing_session: changingSession, old_number_sign_in: oldNumberAfter.status,
        new_number_session: thiefRead, new_number_own_read: thiefCreds?.access, restore: outcomeOf(rc),
        new_number_session_after_restore: thiefAfter.status, new_number_sign_in_after_restore: directNumberAfter.status,
        approved_number_after_restore: approvedAfter.status, sms_sent: false });
    // Password change and global sign-out use a second persona: a direct password change is an
    // unreviewed one, and X18's restore on `alt` would then (correctly) keep a security hold.
    const alt2 = persona('alt2');
    const e1 = await tokenOf(alt2, { fresh: true });
    const e2 = (await signIn(alt2.phone, alt2.pw)).json;
    const pw2 = newPassword();
    const change = await http('PUT', '/auth/v1/user', { token: e2?.access_token, body: { password: pw2 } });
    if (change.status === 200) { alt2.st.pw = pw2; save(); }
    const e1r = await read('identity_my_member_summary', e1);
    const e2r = await read('identity_my_member_summary', e2?.access_token);
    const quick = await read('identity_my_member_summary', await tokenOf(alt2, { fresh: true }));
    const later = await read('identity_my_member_summary', await freshAfterEpoch(alt2));
    check('X19-password-change-needs-fresh-sign-in', change.status === 200 && e1r.status === 401 && e2r.status === 401
      && quick.status === 401 && quick.detail === 'untrusted_session' && later.status === 200,
      { change: change.status, other_session: e1r, changing_session: e2r, inside_margin: quick, after_margin: later.status });
    const g1 = (await signIn(alt2.phone, alt2.pw)).json;
    const g2 = (await signIn(alt2.phone, alt2.pw)).json;
    const go = await http('POST', '/auth/v1/logout?scope=global', { token: g1?.access_token });
    const g1r = await read('identity_my_member_summary', g1?.access_token);
    const g2r = await read('identity_my_member_summary', g2?.access_token);
    const g2f = await refresh(g2?.refresh_token);
    check('X20-global-sign-out-revokes-all', go.status === 204 && g1r.status === 401 && g2r.status === 401 && g2f.status >= 400,
      { logout: go.status, session_1: g1r.status, session_2: g2r.status, refresh_2: g2f.status });
    ownerSteps.push('Entry 2 cases that need email or Auth Admin power (local E2E `run.mjs` E32-E36, E40, E43, E44: magic-link, email-OTP and recovery sessions, direct email change, ban/unban, dormancy fixture) stay local-only or in the owner email run.');
  }

  // ============================================================================= recovery
  if (phase('recovery')) {
    const summary = (token) => read('identity_my_member_summary', token);
    const adm2 = persona('adm2');
    const rec1 = persona('rec1'); const rec2 = persona('rec2'); const rec3 = persona('rec3'); const life = persona('life');
    for (const p of [rec1, rec2, rec3, life]) { await ensureMember(p, `SYNTHETIC Suite ${p.label}`); await cancelOpen(p.member); }

    // A10: request, grant, single use, fresh sign-in; nothing secret reaches staff.
    await reserve(4);
    const old1 = await tokenOf(rec1, { fresh: true });
    const a = await request(rec1.phone);
    const ga = await issue(rec1.member, a.r.request_code);
    const staffText = JSON.stringify([ga, (await read('identity_admin_recovery_cases', await adminToken())).json]);
    const ready = await status(a.s);
    const wrongSecret = await redeem(rec1.phone, secret(), newPassword());
    const pwA = newPassword();
    const okA = await redeem(rec1.phone, a.s, pwA);
    if (okA.outcome === 'succeeded') { rec1.st.pw = pwA; save(); }
    const replayA = await redeem(rec1.phone, a.s, newPassword());
    const oldSess = await summary(old1);
    const fresh1 = await summary(await freshAfterEpoch(rec1));
    check('A10-grant-works-once-then-fresh-sign-in', a.r.outcome === 'received' && /^[A-Z2-9]{8}$/.test(a.r.request_code ?? '')
      && ga.status === 200 && ga.data?.grant?.state === 'issued' && !staffText.includes(a.s) && !staffText.includes(digest(a.s)) && !staffText.includes(a.r.request_code)
      && ready.outcome === 'ready' && wrongSecret.outcome === 'rejected' && okA.outcome === 'succeeded' && replayA.outcome === 'rejected'
      && oldSess.status === 401 && fresh1.status === 200,
      { request: a.r.outcome, grant: ga.data?.grant?.state ?? ga.code, staff_sees_secret_digest_or_code: false, status: ready.outcome,
        wrong_secret: wrongSecret.outcome, redeem: okA.outcome, replay: replayA.outcome, old_session: oldSess.status, fresh_sign_in: fresh1.status });
    const unknownReq = await request(LIMIT_NUMBERS[10]);
    log('A10b-unknown-number-neutral', { verdict: unknownReq.r.outcome === 'received' ? 'pass' : 'FAIL', outcome: unknownReq.r.outcome });
    results.push({ step: 'A10b-unknown-number-neutral', ok: unknownReq.r.outcome === 'received' });

    // A11: a reissued grant supersedes the unused one.
    await reserve(4);
    const b1 = await request(rec1.phone);
    const gb1 = await issue(rec1.member, b1.r.request_code);
    const b2 = await request(rec1.phone);
    const gb2 = await issue(rec1.member, b2.r.request_code);
    const oldGrant = await redeem(rec1.phone, b1.s, newPassword());
    const pwB = newPassword();
    const newGrant = await redeem(rec1.phone, b2.s, pwB);
    if (newGrant.outcome === 'succeeded') { rec1.st.pw = pwB; save(); }
    check('A11-reissue-supersedes-unused-grant', gb1.status === 200 && gb2.status === 200 && oldGrant.outcome === 'rejected' && newGrant.outcome === 'succeeded',
      { first_grant: gb1.data?.grant?.state ?? gb1.code, second_grant: gb2.data?.grant?.state ?? gb2.code, first_redeem: oldGrant.outcome, second_redeem: newGrant.outcome });

    // A12: a direct password change after issue kills the grant.
    await reserve(2);
    const c1 = await request(rec2.phone);
    const gc = await issue(rec2.member, c1.r.request_code);
    const pwC = newPassword();
    const put = await http('PUT', '/auth/v1/user', { token: await tokenOf(rec2, { fresh: true }), body: { password: pwC } });
    if (put.status === 200) { rec2.st.pw = pwC; save(); }
    const killed = await redeem(rec2.phone, c1.s, newPassword());
    await sleep(EPOCH_WAIT_MS);
    const stillPw = await signIn(rec2.phone, rec2.pw);
    check('A12-direct-password-change-kills-grant', gc.status === 200 && put.status === 200 && killed.outcome === 'rejected' && stillPw.status === 200,
      { grant: gc.data?.grant?.state ?? gc.code, direct_change: put.status, redeem: killed.outcome, own_password_still_works: stillPw.status });
    await cancelOpen(rec2.member);

    // A15: a grant presented with another member's number is burned.
    await reserve(3);
    const d = await request(rec2.phone);
    const gd = await issue(rec2.member, d.r.request_code);
    const cross = await redeem(rec1.phone, d.s, newPassword());
    const afterBurn = await redeem(rec2.phone, d.s, newPassword());
    const rec1Ok = await signIn(rec1.phone, rec1.pw);
    const rec2Ok = await signIn(rec2.phone, rec2.pw);
    check('A15-cross-member-use-burns-grant', gd.status === 200 && cross.outcome === 'rejected' && afterBurn.outcome === 'rejected'
      && rec1Ok.status === 200 && rec2Ok.status === 200,
      { grant: gd.data?.grant?.state ?? gd.code, other_number: cross.outcome, right_number_after: afterBurn.outcome, passwords_unchanged: [rec1Ok.status, rec2Ok.status] });
    await cancelOpen(rec2.member);

    // A14: two concurrent redemptions of one grant: exactly one wins.
    await reserve(3);
    const e = await request(rec3.phone);
    const ge = await issue(rec3.member, e.r.request_code);
    const pwE1 = newPassword(); const pwE2 = newPassword();
    const [w1, w2] = await Promise.all([redeem(rec3.phone, e.s, pwE1), redeem(rec3.phone, e.s, pwE2)]);
    const winner = w1.outcome === 'succeeded' ? pwE1 : w2.outcome === 'succeeded' ? pwE2 : null;
    if (winner) { rec3.st.pw = winner; save(); }
    await sleep(EPOCH_WAIT_MS);
    const winSignIn = await signIn(rec3.phone, rec3.pw);
    check('A14-concurrent-redemption-exactly-one', ge.status === 200 && [w1.outcome, w2.outcome].filter((o) => o === 'succeeded').length === 1
      && winSignIn.status === 200, { outcomes: [w1.outcome, w2.outcome].sort(), winner_password_works: winSignIn.status });

    // A18: a lost-device hold stays until the member's own reset, then a second Admin releases it.
    await reserve(2);
    const r3old = await tokenOf(rec3, { fresh: true });
    const lost = await credCmd(await adminToken(), 'identity.place_hold', await memberRevision(rec3.member), { member_id: rec3.member, reason_code: 'lost_device' });
    const lostOld = await summary(r3old);
    const lostFresh = await summary(await freshAfterEpoch(rec3));
    const early = await credCmd(await tokenOf(adm2), 'identity.release_hold', lost.revision, { member_id: rec3.member, hold_id: lost.data?.holds?.[0]?.hold_id, identity_check: 'in_person' });
    const f = await request(rec3.phone);
    const gf = await issue(rec3.member, f.r.request_code);
    const pwF = newPassword();
    const okF = await redeem(rec3.phone, f.s, pwF);
    if (okF.outcome === 'succeeded') { rec3.st.pw = pwF; save(); }
    const lostHoldNow = await openHold(lost.data?.holds?.[0]?.hold_id);
    const released = await credCmd(await tokenOf(adm2), 'identity.release_hold', lostHoldNow?.member_revision,
      { member_id: rec3.member, hold_id: lostHoldNow?.hold_id, identity_check: 'in_person' });
    const r3back = await summary(await freshAfterEpoch(rec3));
    check('A18-lost-device-hold-stays-through-reset-then-release', lost.status === 200 && lostOld.status === 401
      && lostFresh.status === 403 && lostFresh.detail === 'review_required'
      && early.code === 'conflict' && early.field_errors?.hold_id === 'password_reset_required'
      && gf.status === 200 && okF.outcome === 'succeeded' && released.status === 200 && r3back.status === 200,
      { hold: lost.data?.holds?.[0]?.hold_kind ?? lost.code, old_session: lostOld.status, fresh_during_hold: lostFresh,
        early_release: outcomeOf(early), grant_under_security_hold: gf.data?.grant?.state ?? gf.code, redeem: okF.outcome,
        release_after_reset: outcomeOf(released), after_release: r3back.status });

    // A22: deactivation ends an issued grant.
    await reserve(2);
    const g = await request(life.phone);
    const gg = await issue(life.member, g.r.request_code);
    const deact = await lifecycleCmd(await adminToken(), 'identity.deactivate_membership', await memberRevision(life.member), { member_id: life.member, reason_code: 'church_decision' });
    const dead = await redeem(life.phone, g.s, newPassword());
    const back = await lifecycleCmd(await tokenOf(adm2), 'identity.restore_membership', deact.revision, { member_id: life.member, identity_check: 'in_person' });
    const lifeOk = await summary(await freshAfterEpoch(life));
    check('A22-deactivation-ends-issued-grant', gg.status === 200 && deact.status === 200 && dead.outcome === 'rejected' && back.status === 200 && lifeOk.status === 200,
      { grant: gg.data?.grant?.state ?? gg.code, deactivate: outcomeOf(deact), redeem: dead.outcome, restore: outcomeOf(back), password_unchanged_sign_in: lifeOk.status });

    // A13: unlinking ends an issued grant; the account then rejoins the SAME member by an explicit link.
    await reserve(2);
    const h = await request(rec2.phone);
    const gh = await issue(rec2.member, h.r.request_code);
    const unl = await review('identity.unlink_account', await memberRevision(rec2.member), { member_id: rec2.member, reason: 'account_lost' });
    const unlinked = await redeem(rec2.phone, h.s, newPassword());
    await cancelOpen(rec2.member);
    const r2tok = await freshAfterEpoch(rec2);
    const reapply = await submitApplication(rec2, 'SYNTHETIC Suite rec2', null);
    const rItem = await queueItem(reapply.data?.application_id);
    const rc = rItem?.candidates?.find((c) => c.member_id === rec2.member);
    const relink = await review('identity.link_application', rItem?.revision, { application_id: reapply.data?.application_id, member_id: rec2.member, identity_check: 'in_person' });
    const r2back = await summary(await freshAfterEpoch(rec2));
    check('A13-unlink-ends-grant-and-explicit-relink-keeps-member', gh.status === 200 && unl.status === 200 && unlinked.outcome === 'rejected'
      && Boolean(r2tok) && reapply.status === 200 && rc?.link_eligible === true && relink.status === 200
      && r2back.status === 200 && r2back.json?.member_id === rec2.member,
      { grant: gh.data?.grant?.state ?? gh.code, unlink: outcomeOf(unl), redeem: unlinked.outcome, new_application: reapply.data?.church_status ?? reapply.code,
        candidate_signals: rc?.signals, link: outcomeOf(relink), same_member_id: r2back.json?.member_id === rec2.member });

    // A23 / A24: the per-number and per-client limits. A23 floods one number with no account; it
    // takes whichever of two numbers was not flooded in the last hour (per-number budget 5/h).
    state.limits.a23 ??= {};
    const a23Number = A23_NUMBERS.find((x) => Date.now() - (state.limits.a23[x] ?? 0) > 3600_000);
    if (!a23Number) {
      log('A23-A24-deferred', { verdict: 'deferred', reason: 'both A23 numbers were flooded less than an hour ago (per-number budget)' });
      ownerSteps.push('A23/A24 were deferred in this run (both A23 numbers used within the hour); see the earlier run.');
    } else {
      await reserve(6);
      const flood = await Promise.all(Array.from({ length: 6 }, () => fn({ action: 'request', phone_username: a23Number, grant_digest: digest(secret()) }, {}, { retry: false })));
      state.limits.a23[a23Number] = Date.now(); save();
      const outcomes = flood.map((x) => x.outcome);
      check('A23-per-number-limit-under-concurrency', outcomes.filter((o) => o === 'received').length === 5 && outcomes.filter((o) => o === 'rate_limited').length === 1,
        { outcomes: outcomes.sort() });
      await reserve(10);
      const ten = [];
      for (let i = 1; i <= 10; i += 1) ten.push((await fn({ action: 'request', phone_username: LIMIT_NUMBERS[i], grant_digest: digest(secret()) }, {}, { retry: false })).outcome);
      const eleventh = (await fetch(FN, { method: 'POST', headers: { apikey: key, 'content-type': 'application/json' },
        body: JSON.stringify({ action: 'request', phone_username: LIMIT_NUMBERS[2], grant_digest: digest(secret()) }) }).then((r) => r.json())).outcome;
      clientPacer.record(); save();
      const forged = (await fetch(FN, { method: 'POST', headers: { apikey: key, 'content-type': 'application/json', 'x-forwarded-for': '203.0.113.77' },
        body: JSON.stringify({ action: 'request', phone_username: LIMIT_NUMBERS[3], grant_digest: digest(secret()) }) }).then((r) => r.json())).outcome;
      check('A24-per-client-limit', ten.every((o) => o === 'received') && eleventh === 'rate_limited', { first_ten: ten, eleventh });
      if (forged === 'rate_limited') check('A24b-forged-x-forwarded-for-does-not-escape', true, { forged_first_hop: forged });
      else finding('A24b-forged-x-forwarded-for-escapes-the-per-client-bucket', { forged_first_hop: forged,
        note: 'the gateway appends to x-forwarded-for: per-number and church-wide limits still apply; record and add the optional WAF rule (runbook identity-access.md 2.9 Hosted step 4)' });
    }
    ownerSteps.push('Entry 9 cases that need the system credential or a 15-minute wait (local `assisted.mjs` A16 uncertain/late completion, A17 relink after reconcile, A19 expired grant, A21 cancel between begin and dispatch) stay local-only.');
  }

  // ============================================================================== summary
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed${findings.length ? `; findings: ${findings.join(', ')}` : ''}`);
  if (failed.length) { console.log(`FAILED: ${failed.map((f) => f.step).join(', ')}`); process.exitCode = 1; }
  if (args.summary) writeFileSync(args.summary, renderSummary({ results, findings, matrixRows, ownerSteps }));
}

const ABBR = { validation_failed: 'vf', forbidden: 'fb', unauthenticated: 'ua', conflict: 'cf', success: 'OK' };
/** The readable summary: section counts, the read and command matrices, owner/local-only items. */
export function renderSummary({ results, findings, matrixRows, ownerSteps }) {
  const lines = ['# Staging suite summary (generated by tools/identity-e2e/staging-suite.mjs)', ''];
  const passed = results.filter((r) => r.ok).length;
  lines.push(`Checks: ${passed}/${results.length} passed.${findings.length ? ` Findings: ${findings.join(', ')}.` : ''}`, '');
  lines.push('| Check | Verdict |', '|---|---|');
  for (const r of results.filter((x) => !x.step.startsWith('M-'))) lines.push(`| ${r.step} | ${r.ok ? 'pass' : 'FAIL'} |`);
  const principals = [...new Set(matrixRows.map((r) => r.principal))];
  const cell = (r) => {
    if (!r) return '';
    const v = r.kind === 'read'
      ? (r.got.status === 200 ? '200' : `${r.got.status}${r.got.detail ? ` ${r.got.detail.replace('not_granted', 'ng').replace('not_linked', 'nl').replace('review_required', 'rr').replace('not_applicant', 'na')}` : ''}`)
      : (r.got.status ? String(r.got.status) : ABBR[r.got.code] ?? r.got.code);
    return r.ok ? v : `**${v}≠**`;
  };
  if (matrixRows.length) {
    for (const kind of ['read', 'command']) {
      lines.push('', `## ${kind === 'read' ? 'Reads' : 'Commands'} (rows: surface; columns: principal)`, '');
      lines.push(`| ${kind === 'read' ? 'Read' : 'Command'} | ${principals.join(' | ')} |`, `|---|${principals.map(() => '---').join('|')}|`);
      for (const s of [...new Set(matrixRows.filter((r) => r.kind === kind).map((r) => r.surface))]) {
        lines.push(`| ${s} | ${principals.map((p) => cell(matrixRows.find((r) => r.kind === kind && r.surface === s && r.principal === p))).join(' | ')} |`);
      }
    }
    lines.push('', 'Legend: 200 / 401 / 403 with detail (ng not_granted, nl not_linked, rr review_required, na not_applicant); command envelope codes vf validation_failed (authorised, probe refused by validation, nothing changed), fb forbidden, ua unauthenticated. A cell marked ≠ differs from the expectation.');
  }
  if (ownerSteps.length) { lines.push('', '## Not run here (owner or local-only)', ''); for (const s of ownerSteps) lines.push(`- ${s}`); }
  return lines.join('\n') + '\n';
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((e) => {
    console.error(`staging-suite: ${e.message}`);
    process.exitCode = 1;
  });
}
