#!/usr/bin/env node
// System credentials and the system-route verification matrix (story 1.9, AD-19).
//
// A system credential is `sysc_<environment>_<43 base64url chars>` (256 random bits). It is
// minted here into the gitignored state dir (.ops-state/, or $OPS_STATE_DIR) with mode 0600 and
// is NEVER printed, logged or committed. A restricted operator registers only its sha256 digest
// in the target database (app.sys_register_credential, see
// docs/runbooks/system-access-and-operations.md).
//
// CLI:
//   node tools/ops/system-credential.mjs mint --env <env> [--force]   mint; prints digest only
//   node tools/ops/system-credential.mjs digest --env <env>           digest of the stored token
//   node tools/ops/system-credential.mjs forget --env <env>           delete the stored token
//   node tools/ops/system-credential.mjs matrix --env <env> [--out f] [--require-user-jwt]
//       Runs the HTTP matrix against the environment's system route and prints JSON lines.
//       Env: SUPABASE_PUBLISHABLE_KEY (required), SUPABASE_API_URL (local only; default from
//       config), SYSTEM_MATRIX_USER_JWT (a synthetic user's access token for the session case).

import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ENVIRONMENT_NAMES, loadEnvironments } from '../env/environments.mjs';

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
export const TOKEN_RE = /^sysc_(local|staging|production)_[A-Za-z0-9_-]{43}$/;
export const PROBE = 'system.synthetic_probe';

export function stateDir() {
  return process.env.OPS_STATE_DIR || join(REPO_ROOT, '.ops-state');
}

export function mintToken(env) {
  if (!ENVIRONMENT_NAMES.includes(env)) throw new Error(`unknown environment "${env}"`);
  return `sysc_${env}_${randomBytes(32).toString('base64url')}`;
}

export function digestOf(token) {
  if (!TOKEN_RE.test(token)) throw new Error('not a system credential');
  return createHash('sha256').update(token, 'utf8').digest('hex');
}

export function tokenEnvironment(token) {
  const m = TOKEN_RE.exec(token);
  return m ? m[1] : null;
}

function credentialPath(env) {
  return join(stateDir(), `${env}.credential`);
}

export function readStored(env) {
  const p = credentialPath(env);
  if (!existsSync(p)) return null;
  const token = readFileSync(p, 'utf8').trim();
  if (tokenEnvironment(token) !== env) throw new Error(`${p} does not hold a ${env} credential`);
  return token;
}

/** Removes every occurrence of known secrets from text before it is printed or saved. */
export function scrub(text, secrets) {
  let out = String(text);
  for (const s of secrets.filter(Boolean)) out = out.split(s).join('[redacted]');
  return out.replace(/sysc_(local|staging|production)_[A-Za-z0-9_-]{43}/g, 'sysc_$1_[redacted]');
}

function arg(argv, name, fallback = undefined) {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : fallback;
}

function apiUrlFor(env) {
  const envs = loadEnvironments();
  const configured = envs[env]?.supabase?.api_url;
  if (env === 'local') return process.env.SUPABASE_API_URL || configured;
  if (!configured) throw new Error(`${env}: no api_url configured (owner step for production)`);
  return configured;
}

// A JWT-shaped bearer that no project signed: PostgREST must refuse it before any SQL runs.
function forgedJwt() {
  const b = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  return `${b({ alg: 'HS256', typ: 'JWT' })}.${b({ role: 'service_role', sub: randomUUID() })}.${randomBytes(32).toString('base64url')}`;
}

/** The expected outcome of each matrix case (pure; unit-tested). */
export function judge(name, res, ctx) {
  const b = res.body ?? {};
  const actor = b?.data?.actor;
  switch (name) {
    case 'valid_credential':
      return res.status === 200 && actor?.kind === 'system' && actor?.job_id === ctx.requestId
        && actor?.initiating_member_id === null && typeof actor?.system_principal_id === 'string'
        && Number.isInteger(b.revision) && b.data?.environment === ctx.env;
    case 'replay_same_request':
      return res.status === 200 && JSON.stringify(b) === JSON.stringify(ctx.valid);
    case 'changed_payload_same_request':
      return b.code === 'conflict';
    case 'no_credential':
    case 'malformed_credential':
    case 'unknown_credential_same_environment':
      return b.code === 'unauthenticated';
    case 'user_jwt_with_valid_credential':
      return b.code === 'forbidden';
    case 'forged_jwt_bearer':
      return res.status === 401;
    case 'forged_actor_envelope_field':
      return b.code === 'validation_failed' && b.field_errors?.actor === 'unknown_field';
    case 'forged_actor_payload_fields':
      return b.code === 'validation_failed'
        && ['system_principal_id', 'initiating_member_id', 'member_id', 'role']
          .every((k) => b.field_errors?.[k] === 'unknown_field');
    case 'forged_actor_headers':
      return res.status === 200 && actor?.system_principal_id === ctx.principalId
        && actor?.initiating_member_id === null;
    case 'command_not_allowlisted':
      return b.code === 'forbidden';
    case 'audit_table_not_exposed':
      return res.status === 406;
    default:
      if (name.startsWith('wrong_environment_credential_')) return b.code === 'unauthenticated';
      return false;
  }
}

async function call(url, { key, credential, bearer, envelope, headers = {}, method = 'POST', profile = 'api' }) {
  const h = { apikey: key, 'Content-Type': 'application/json', ...headers };
  if (method === 'POST') h['Content-Profile'] = profile; else h['Accept-Profile'] = profile;
  if (credential !== undefined) h['x-system-credential'] = credential;
  if (bearer) h.Authorization = `Bearer ${bearer}`;
  const r = await fetch(url, { method, headers: h, body: method === 'POST' ? JSON.stringify(envelope) : undefined });
  const text = await r.text();
  let body;
  try { body = JSON.parse(text); } catch { body = text; }
  return { status: r.status, body };
}

export async function runMatrix({ env, apiUrl, key, token, userJwt, requireUserJwt }) {
  const rpc = `${apiUrl}/rest/v1/rpc/system_command`;
  const probe = (requestId, payload = {}) => ({ version: 1, command: PROBE, request_id: requestId, payload });
  const lines = [];
  const ctx = { env };
  const record = (name, request, res, extra = {}) => {
    const pass = judge(name, res, ctx);
    lines.push({ case: name, request, http_status: res.status, body: res.body, pass, ...extra });
    return res;
  };
  const rid = () => randomUUID();

  ctx.requestId = rid();
  const valid = record('valid_credential', { credential: `${env} (registered)`, command: PROBE },
    await call(rpc, { key, credential: token, envelope: probe(ctx.requestId) }));
  ctx.valid = valid.body;
  ctx.principalId = valid.body?.data?.actor?.system_principal_id;
  record('replay_same_request', { credential: `${env} (registered)`, request_id: 'same as valid_credential' },
    await call(rpc, { key, credential: token, envelope: probe(ctx.requestId) }));
  record('changed_payload_same_request', { credential: `${env} (registered)`, payload: { sequence: 2 } },
    await call(rpc, { key, credential: token, envelope: probe(ctx.requestId, { sequence: 2 }) }));
  record('no_credential', { credential: 'none' }, await call(rpc, { key, envelope: probe(rid()) }));
  record('malformed_credential', { credential: `sysc_${env}_short` },
    await call(rpc, { key, credential: `sysc_${env}_short`, envelope: probe(rid()) }));
  const unknown = mintToken(env);
  record('unknown_credential_same_environment', { credential: `${env} (well-formed, never registered)` },
    await call(rpc, { key, credential: unknown, envelope: probe(rid()) }));
  // Never send another environment's real credential across environments: a freshly minted,
  // correctly prefixed, unregistered token proves the prefix binding without exposing one.
  for (const other of ENVIRONMENT_NAMES.filter((e) => e !== env)) {
    record(`wrong_environment_credential_${other}`,
      { credential: `${other} (freshly minted, well-formed, never registered)` },
      await call(rpc, { key, credential: mintToken(other), envelope: probe(rid()) }));
  }
  if (userJwt) {
    record('user_jwt_with_valid_credential', { credential: `${env} (registered)`, authorization: 'synthetic user session JWT' },
      await call(rpc, { key, credential: token, bearer: userJwt, envelope: probe(rid()) }));
  } else if (requireUserJwt) {
    lines.push({ case: 'user_jwt_with_valid_credential', pass: false, error: 'SYSTEM_MATRIX_USER_JWT not set' });
  } else {
    lines.push({ case: 'user_jwt_with_valid_credential', pass: null, skipped: 'SYSTEM_MATRIX_USER_JWT not set' });
  }
  record('forged_jwt_bearer', { credential: `${env} (registered)`, authorization: 'unsigned JWT claiming service_role' },
    await call(rpc, { key, credential: token, bearer: forgedJwt(), envelope: probe(rid()) }));
  const forgedId = '00000000-0000-4000-8000-0000000000cc';
  const memberId = '00000000-0000-4000-8000-0000000000bb';
  record('forged_actor_envelope_field', { credential: `${env} (registered)`, extra_envelope_key: 'actor' },
    await call(rpc, { key, credential: token, envelope: { ...probe(rid()), actor: { kind: 'system', system_principal_id: forgedId } } }));
  record('forged_actor_payload_fields', { credential: `${env} (registered)`, payload_keys: ['system_principal_id', 'initiating_member_id', 'member_id', 'role'] },
    await call(rpc, { key, credential: token, envelope: probe(rid(), { system_principal_id: forgedId, initiating_member_id: memberId, member_id: memberId, role: 'admin' }) }));
  record('forged_actor_headers', { credential: `${env} (registered)`, headers: ['x-system-principal', 'x-initiating-member', 'x-actor-role'] },
    await call(rpc, { key, credential: token, envelope: probe(rid()), headers: { 'x-system-principal': forgedId, 'x-initiating-member': memberId, 'x-actor-role': 'admin' } }));
  record('command_not_allowlisted', { credential: `${env} (registered)`, command: 'fixture_counter.increment' },
    await call(rpc, { key, credential: token, envelope: { version: 1, command: 'fixture_counter.increment', request_id: rid(), payload: {} } }));
  record('audit_table_not_exposed', { method: 'GET', path: 'rest/v1/sys_audit', profile: 'app' },
    await call(`${apiUrl}/rest/v1/sys_audit?select=*`, { key, method: 'GET', profile: 'app' }));
  return lines;
}

async function main(argv) {
  const [cmd, ...rest] = argv;
  const env = arg(rest, '--env');
  if (!ENVIRONMENT_NAMES.includes(env)) throw new Error('--env local|staging|production is required');
  if (cmd === 'mint') {
    const p = credentialPath(env);
    if (existsSync(p) && !rest.includes('--force')) throw new Error(`${p} exists; pass --force to replace it`);
    mkdirSync(stateDir(), { recursive: true, mode: 0o700 });
    const token = mintToken(env);
    writeFileSync(p, `${token}\n`, { mode: 0o600 });
    chmodSync(p, 0o600);
    console.log(JSON.stringify({ environment: env, digest: digestOf(token), stored_in: p }));
    return 0;
  }
  if (cmd === 'digest') {
    const token = readStored(env);
    if (!token) throw new Error(`no stored ${env} credential; run mint first`);
    console.log(digestOf(token));
    return 0;
  }
  if (cmd === 'forget') {
    rmSync(credentialPath(env), { force: true });
    console.log(`forgot the stored ${env} credential`);
    return 0;
  }
  if (cmd === 'matrix') {
    const token = readStored(env);
    if (!token) throw new Error(`no stored ${env} credential; run mint and register its digest first`);
    const key = process.env.SUPABASE_PUBLISHABLE_KEY;
    if (!key) throw new Error('SUPABASE_PUBLISHABLE_KEY is required');
    const userJwt = process.env.SYSTEM_MATRIX_USER_JWT || null;
    const lines = await runMatrix({ env, apiUrl: apiUrlFor(env), key, token, userJwt,
      requireUserJwt: rest.includes('--require-user-jwt') });
    const secrets = [token, userJwt, key];
    const out = scrub(lines.map((l) => JSON.stringify({ environment: env, ...l })).join('\n'), secrets);
    const file = arg(rest, '--out');
    if (file) writeFileSync(file, `${out}\n`);
    console.log(out);
    const failed = lines.filter((l) => l.pass === false).map((l) => l.case);
    console.error(failed.length ? `matrix: FAILED ${failed.join(', ')}` : `matrix: ${lines.filter((l) => l.pass).length} cases passed`);
    return failed.length ? 1 : 0;
  }
  console.error('usage: system-credential.mjs mint|digest|forget|matrix --env <env> [...]');
  return 2;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).then((code) => { process.exitCode = code; }, (err) => {
    console.error(`system-credential: ${scrub(err.message, [])}`);
    process.exitCode = 1;
  });
}
