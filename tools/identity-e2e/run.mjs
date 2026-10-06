#!/usr/bin/env node
// Story 2.1 end-to-end on the LOCAL stack: phone/password sign-up and sign-in through native
// GoTrue (no SMS), then the live-access-checked read api.identity_my_member_summary.
//
// Preconditions: `npx supabase start`, migrations applied, and the local-only phone switch
//   node tools/auth-harness/local-phone-auth.mjs on
// Seeding and cleanup use psql in the local db container as the restricted operator.
// Only the exact local origin is accepted. SYNTHETIC fictional-range numbers only
// (+1 202 555 0170-0179 and +44 7700 900170-900179). Evidence is a redacted JSONL log: status
// codes, error codes, AMR method names and summary fields; never tokens or passwords.
//
// Usage: node tools/identity-e2e/run.mjs [--evidence <file.jsonl>]
import { execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { appendFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export const LOCAL_ORIGIN = 'http://127.0.0.1:54321';

/** Refuses anything but the exact local API origin. */
export function assertLocalOrigin(url) {
  const u = new URL(url);
  if (u.origin !== LOCAL_ORIGIN || u.username || u.password) {
    throw new Error(`refusing non-local target ${u.origin}`);
  }
  return u.origin;
}

/** Reserved fictional ranges used by this run. */
export function isFictional(phone) {
  return /^\+1202555017[0-9]$/.test(phone) || /^\+44770090017[0-9]$/.test(phone);
}

/** AMR method names from a JWT payload, without keeping the token. */
export function amrMethods(jwt) {
  const part = String(jwt ?? '').split('.')[1];
  if (!part) return [];
  try {
    const payload = JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));
    return Array.isArray(payload.amr) ? payload.amr.map((a) => a?.method) : [];
  } catch {
    return [];
  }
}

const SECRET_KEYS = /^(access_token|refresh_token|password|token|apikey|authorization)$/i;
/** Deep copy with secret-bearing keys redacted. */
export function redact(value) {
  if (Array.isArray(value)) return value.map(redact);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([k, v]) =>
      [k, SECRET_KEYS.test(k) ? '[redacted]' : redact(v)]));
  }
  return value;
}

function localKey() {
  const env = execFileSync('npx', ['supabase', 'status', '-o', 'env'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  const url = /^API_URL="([^"]+)"/m.exec(env)?.[1];
  const key = /^PUBLISHABLE_KEY="([^"]+)"/m.exec(env)?.[1];
  if (!url || !key) throw new Error('local stack is not running');
  return { origin: assertLocalOrigin(url), key };
}

function psql(sql) {
  const name = execFileSync('docker', ['ps', '--filter', 'name=supabase_db_', '--format', '{{.Names}}'], { encoding: 'utf8' }).trim().split('\n')[0];
  return execFileSync('docker', ['exec', '-i', name, 'psql', '-U', 'postgres', '-X', '-qtA', '-v', 'ON_ERROR_STOP=1', '-c', sql], { encoding: 'utf8' }).trim();
}

async function main() {
  const evidenceIdx = process.argv.indexOf('--evidence');
  const evidence = evidenceIdx > 0 ? process.argv[evidenceIdx + 1] : null;
  if (evidence) writeFileSync(evidence, '');
  const { origin, key } = localKey();
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
  async function http(method, path, { token, body, profile } = {}) {
    const headers = { apikey: key, 'Content-Type': 'application/json' };
    if (token) headers.Authorization = `Bearer ${token}`;
    if (profile) headers[method === 'GET' ? 'Accept-Profile' : 'Content-Profile'] = profile;
    const res = await fetch(`${origin}${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
    const text = await res.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { /* non-JSON */ }
    return { status: res.status, json };
  }
  const password = () => `Synthetic-${randomBytes(12).toString('base64url')}`;
  const signUp = (phone, pw) => http('POST', '/auth/v1/signup', { body: { phone, password: pw } });
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const read = (token) => http('POST', '/rest/v1/rpc/identity_my_member_summary', { token, body: {}, profile: 'api' });
  const err = (r) => ({ status: r.status, code: r.json?.error_code ?? r.json?.message, detail: r.json?.details, msg: r.json?.msg });

  const A = '+12025550171', B = '+12025550172', C = '+447700900171', U = '+12025550179';
  for (const p of [A, B, C, U]) if (!isFictional(p)) throw new Error(`not fictional: ${p}`);
  const digits = [A, B, C, U].map((p) => `'${p.slice(1)}'`).join(',');
  const cleanup = () => psql(`
    delete from app.identity_binding_history h using app.identity_account_links l, auth.users u
     where h.link_id = l.link_id and l.auth_user_id = u.id and u.phone in (${digits});
    with gone as (delete from app.identity_account_links l using auth.users u
                   where l.auth_user_id = u.id and u.phone in (${digits}) returning l.member_id)
    delete from app.identity_members m using gone where m.member_id = gone.member_id;
    delete from auth.users where phone in (${digits});
    select count(*) from auth.users where phone in (${digits});`);

  const marker = psql(`select coalesce((select environment from app.platform_environment), '')`);
  let marked = false;
  if (marker === '') {
    psql(`select app.platform_set_environment('local', 'identity-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('E00-precondition', { settings: await http('GET', '/auth/v1/settings').then((r) => ({
    status: r.status, phone: r.json?.external?.phone, phone_autoconfirm: r.json?.phone_autoconfirm,
    sms_provider: r.json?.sms_provider })), leftover_users_removed: cleanup() });

  const startedAt = new Date().toISOString();
  try {
    const pwA = password();
    const up = await signUp(A, pwA);
    check('E10-phone-signup', up.status === 200 && amrMethods(up.json?.access_token).includes('password'),
      { status: up.status, amr: amrMethods(up.json?.access_token), stored_phone: up.json?.user?.phone });

    const r0 = await read(up.json?.access_token);
    check('E11-read-before-link', r0.status === 403 && r0.json?.details === 'not_linked', err(r0));

    const userA = psql(`select id from auth.users where phone = '${A.slice(1)}'`);
    psql(`select app.identity_seed_synthetic_link('${userA}', 'SYNTHETIC E2E Member', 'identity-e2e')`);
    log('E12-operator-seeded-link', { approved_phone: psql(`select approved_phone from app.identity_account_links where auth_user_id = '${userA}'`) });

    const r1 = await read(up.json?.access_token);
    check('E13-read-after-link', r1.status === 200 && r1.json?.display_name === 'SYNTHETIC E2E Member',
      { status: r1.status, summary: r1.json && { ...r1.json, member_id: '[uuid]' } });

    const s2 = await signIn(A, pwA);
    const r2 = await read(s2.json?.access_token);
    check('E14-second-device-sign-in', s2.status === 200 && r2.status === 200,
      { status: s2.status, amr: amrMethods(s2.json?.access_token), read_status: r2.status });

    const wrong = await signIn(A, password());
    const unknown = await signIn(U, password());
    check('E15-generic-credential-errors', wrong.status === 400 && unknown.status === 400
      && wrong.json?.error_code === unknown.json?.error_code && wrong.json?.msg === unknown.json?.msg,
      { wrong: err(wrong), unknown: err(unknown) });

    const dup = await signUp(A, password());
    check('E16-duplicate-username-refused', dup.status === 422 && !dup.json?.access_token, err(dup));

    const nopw = await http('POST', '/auth/v1/signup', { body: { phone: B } });
    check('E17-passwordless-signup-refused', nopw.status >= 400 && !nopw.json?.access_token, err(nopw));

    const otp = await http('POST', '/auth/v1/otp', { body: { phone: B, create_user: true } });
    const bUser = psql(`select count(*) from auth.users where phone = '${B.slice(1)}'`);
    const bLinked = psql(`select count(*) from app.identity_account_links l join auth.users u on u.id = l.auth_user_id where u.phone = '${B.slice(1)}'`);
    check('E18-phone-otp-no-sms-no-tokens-no-link', otp.status >= 400 && !otp.json?.access_token && bLinked === '0',
      { ...err(otp), f1_user_rows: Number(bUser), linked: Number(bLinked) });

    const pwC = password();
    const upC = await signUp(C, pwC);
    const rC = await read(upC.json?.access_token);
    check('E19-uk-number-unlinked-denied', upC.status === 200 && rC.status === 403 && rC.json?.details === 'not_linked',
      { signup_status: upC.status, stored_phone: upC.json?.user?.phone, read: err(rC) });

    const anon = await read(null);
    check('E20-signed-out-denied', anon.status === 401, err(anon));

    const direct = await http('GET', '/rest/v1/identity_members', { token: s2.json?.access_token, profile: 'app' });
    const directApi = await http('GET', '/rest/v1/identity_account_links', { token: s2.json?.access_token, profile: 'api' });
    check('E21-direct-table-query-denied', direct.status === 406 && directApi.status === 404,
      { app_schema: direct.status, api_schema: directApi.status });

    const out = await http('POST', '/auth/v1/logout?scope=local', { token: s2.json?.access_token });
    const r3 = await read(s2.json?.access_token);
    const r4 = await read(up.json?.access_token);
    check('E22-signed-out-session-denied-other-session-kept', r3.status === 401 && r3.json?.details === 'untrusted_session' && r4.status === 200,
      { logout_status: out.status, revoked_read: err(r3), other_session_read: r4.status });

    const activity = psql(`select last_member_activity_at is not null from app.identity_account_links where auth_user_id = '${userA}'`);
    check('E23-activity-recorded-only-after-grant', activity === 't', { activity_recorded: activity === 't' });
  } finally {
    const smsLines = execFileSync('docker', ['logs', '--since', startedAt, 'supabase_auth_church-app'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    const sent = smsLines.split('\n').filter((l) => /sms/i.test(l) && !/Unable to get SMS provider|sms_provider|missing/i.test(l));
    check('E98-no-sms-sent', sent.length === 0, { sms_send_lines: sent.length });
    const left = cleanup();
    if (marked) psql(`delete from app.platform_environment where set_by = 'identity-e2e'; delete from app.platform_environment_history where set_by = 'identity-e2e';`);
    check('E99-cleanup', left === '0', { synthetic_users_left: Number(left) });
  }
  const failed = results.filter((r) => !r.ok);
  console.log(failed.length ? `FAIL: ${failed.map((r) => r.step).join(', ')}` : `PASS: ${results.length} checks`);
  process.exit(failed.length ? 1 : 0);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((e) => {
    console.error(`identity-e2e: ${e.message}`);
    process.exit(1);
  });
}
