// Shared LOCAL-stack harness for the identity end-to-end runs (tools/identity-e2e/*.mjs).
// Story 2.13 moved these helpers out of the eleven runs, which each carried an identical copy:
// the exact-local-origin guard, the local keys, psql in the local db container, the redacted
// JSONL evidence reporter, the Data API / Auth HTTP client and the main-module guard.
// Only the exact local origin is accepted; evidence lines are redacted (never tokens, passwords
// or emails).
import { execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { appendFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export const LOCAL_ORIGIN = 'http://127.0.0.1:54321';

/** The 2.2 trust-epoch margin is 5 s; a run waits this long before a new epoch counts. */
export const EPOCH_WAIT_MS = 6500;
/** Local Auth max_frequency is 1 s per address. */
export const RESEND_WAIT_MS = 1200;

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Refuses anything but the exact local API origin. */
export function assertLocalOrigin(url) {
  const u = new URL(url);
  if (u.origin !== LOCAL_ORIGIN || u.username || u.password) {
    throw new Error(`refusing non-local target ${u.origin}`);
  }
  return u.origin;
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

const SECRET_KEYS = /^(access_token|refresh_token|password|token|apikey|authorization|hashed_token|token_hash|email_otp|action_link|email)$/i;
/** Deep copy with secret-bearing keys redacted. */
export function redact(value) {
  if (Array.isArray(value)) return value.map(redact);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([k, v]) =>
      [k, SECRET_KEYS.test(k) ? '[redacted]' : redact(v)]));
  }
  return value;
}

/**
 * The running local stack's origin and keys. With `admin: false` only the publishable key is
 * required and returned (a run that never uses the secret or service-role key).
 */
export function localKey({ admin = true } = {}) {
  const env = execFileSync('npx', ['supabase', 'status', '-o', 'env'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  const url = /^API_URL="([^"]+)"/m.exec(env)?.[1];
  const key = /^PUBLISHABLE_KEY="([^"]+)"/m.exec(env)?.[1];
  if (!admin) {
    if (!url || !key) throw new Error('local stack is not running');
    return { origin: assertLocalOrigin(url), key };
  }
  const secret = /^SECRET_KEY="([^"]+)"/m.exec(env)?.[1];
  const service = /^SERVICE_ROLE_KEY="([^"]+)"/m.exec(env)?.[1];
  if (!url || !key || !secret || !service) throw new Error('local stack is not running');
  return { origin: assertLocalOrigin(url), key, secret, service };
}

/** The local Supabase db container's name. */
export function dbContainer() {
  return execFileSync('docker', ['ps', '--filter', 'name=supabase_db_', '--format', '{{.Names}}'], { encoding: 'utf8' }).trim().split('\n')[0];
}

/**
 * Runs SQL as postgres in the local db container, unaligned tuples only. psql's stderr goes to
 * this process's stderr unless `captureStderr` is set (then it rides on the thrown error).
 */
export function psql(sql, { captureStderr = false } = {}) {
  const args = ['exec', '-i', dbContainer(), 'psql', '-U', 'postgres', '-X', '-qtA', '-v', 'ON_ERROR_STOP=1', '-c', sql];
  const options = { encoding: 'utf8' };
  if (captureStderr) options.stdio = ['ignore', 'pipe', 'pipe'];
  return execFileSync('docker', args, options).trim();
}

/** A fresh synthetic password (never logged). */
export const password = () => `Synthetic-${randomBytes(12).toString('base64url')}`;

/**
 * Starts a run: parses `--evidence <file.jsonl>` (truncating the file), and returns the redacted
 * JSONL `log`, the `check` verdict recorder, the `results` list and `finish`, which prints the
 * `passed/total` summary and sets a failing exit code.
 */
export function startRun(argv = process.argv) {
  const evidenceIdx = argv.indexOf('--evidence');
  const evidence = evidenceIdx > 0 ? argv[evidenceIdx + 1] : null;
  if (evidence) writeFileSync(evidence, '');
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
  const finish = () => {
    const failed = results.filter((r) => !r.ok);
    console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
    if (failed.length) {
      console.log(`FAILED: ${failed.map((f) => f.step).join(', ')}`);
      process.exitCode = 1;
    }
  };
  return { evidence, results, log, check, finish };
}

/**
 * An HTTP client for the local stack. Per call: `token` (Bearer), `admin` (secret key and
 * service role), `profile` (Accept-/Content-Profile), extra `headers`, `xff` (X-Forwarded-For)
 * and `sink` (collects the raw response text). `redirect: 'manual'` also returns `location`;
 * `onText(text, { token })` sees every raw response.
 */
export function localHttp({ origin, key, secret, service }, { redirect, onText } = {}) {
  return async function http(method, path, { token, body, profile, admin, headers: extra, xff, sink } = {}) {
    const headers = { apikey: admin ? secret : key, 'Content-Type': 'application/json', ...(extra ?? {}) };
    if (admin) headers.Authorization = `Bearer ${service}`;
    else if (token) headers.Authorization = `Bearer ${token}`;
    if (profile) headers[method === 'GET' ? 'Accept-Profile' : 'Content-Profile'] = profile;
    if (xff !== undefined) headers['X-Forwarded-For'] = xff;
    const init = { method, headers, body: body ? JSON.stringify(body) : undefined };
    if (redirect) init.redirect = redirect;
    const res = await fetch(`${origin}${path}`, init);
    const text = await res.text();
    if (sink) sink.push(text);
    if (onText) onText(text, { token });
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { /* non-JSON */ }
    return redirect ? { status: res.status, json, location: res.headers.get('location') } : { status: res.status, json };
  };
}

/** Runs `main` when the module at `metaUrl` is the entry point; an error fails the run. */
export function runMain(metaUrl, main) {
  if (process.argv[1] === fileURLToPath(metaUrl)) {
    main().catch((e) => {
      console.error(e.message);
      process.exitCode = 1;
    });
  }
}
