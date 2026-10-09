#!/usr/bin/env node
// Notification worker, tracer step (story 3.1; AD-8, AD-19). A server-side process run by the
// restricted operator, never by a client. Entry 4 replaces it with the Cron-triggered Edge worker.
//
// It runs ONE `notifications.deliver_due` step through the 1.9 system route with a credential of
// the purpose `notifications_worker`: the database claims due pending jobs, rechecks each source
// and recipient, and writes exactly one inbox item per job. Running it again is always safe: a
// delivered, cancelled or obsolete job is never touched twice, and racing runs skip each other's
// rows. It holds no service-role key.
//
// Usage:
//   node tools/notifications/worker.mjs run-once [--limit <1..100>] [--evidence <file.jsonl>]
// Environment (server-side secret store; never in the repo):
//   SUPABASE_URL                            project API URL
//   SUPABASE_PUBLISHABLE_KEY                publishable key (the system route's role)
//   NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL  sysc_<env>_... of a principal with purpose
//                                           notifications_worker (or
//                                           NOTIFICATIONS_WORKER_CREDENTIAL_FILE)
// Output: one JSON line with counts only (claimed, delivered, obsolete, ineligible, failed); no
// member, source or job ids and never the credential.

import { randomUUID } from 'node:crypto';
import { appendFileSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const CREDENTIAL_RE = /^sysc_(local|staging|production)_[A-Za-z0-9_-]{43}$/;
export const COUNT_KEYS = ['claimed', 'delivered', 'obsolete', 'ineligible', 'failed'];

/** Parses `run-once [--limit n] [--evidence file]`; throws on anything else. */
export function parseArgs(argv) {
  const args = [...argv];
  if (args.shift() !== 'run-once') throw new Error('usage: worker.mjs run-once [--limit <1..100>] [--evidence <file>]');
  const out = { limit: undefined, evidence: undefined };
  while (args.length) {
    const flag = args.shift();
    const value = args.shift();
    if (value === undefined) throw new Error(`${flag} needs a value`);
    if (flag === '--limit') {
      const n = Number(value);
      if (!Number.isInteger(n) || n < 1 || n > 100) throw new Error('--limit must be an integer from 1 to 100');
      out.limit = n;
    } else if (flag === '--evidence') {
      out.evidence = value;
    } else {
      throw new Error(`unknown option ${flag}`);
    }
  }
  return out;
}

/** The credential from the environment or its file; refuses a malformed one without echoing it. */
export function readCredential(env = process.env, read = (p) => readFileSync(p, 'utf8')) {
  const raw = env.NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL
    ?? (env.NOTIFICATIONS_WORKER_CREDENTIAL_FILE ? read(env.NOTIFICATIONS_WORKER_CREDENTIAL_FILE) : '');
  const credential = String(raw ?? '').trim();
  if (!CREDENTIAL_RE.test(credential)) {
    throw new Error('NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL is missing or malformed');
  }
  return credential;
}

/** Keeps only the count fields of the step's answer (the actor block and anything else drop). */
export function countsOf(data) {
  const out = {};
  for (const k of COUNT_KEYS) {
    if (!Number.isInteger(data?.[k]) || data[k] < 0) throw new Error(`unexpected worker answer (${k})`);
    out[k] = data[k];
  }
  return out;
}

/** One deliver_due step over the system route. Refusals throw with the route's code only. */
export async function runOnce({ url, publishableKey, credential, limit, fetchImpl = globalThis.fetch, requestId = randomUUID() }) {
  if (!CREDENTIAL_RE.test(credential ?? '')) throw new Error('worker credential is missing or malformed');
  const res = await fetchImpl(`${url.replace(/\/+$/, '')}/rest/v1/rpc/system_command`, {
    method: 'POST',
    headers: { apikey: publishableKey, 'content-type': 'application/json', 'content-profile': 'api',
      'x-system-credential': credential },
    body: JSON.stringify({ version: 1, command: 'notifications.deliver_due', request_id: requestId,
      payload: limit === undefined ? {} : { limit } }),
  });
  const json = await res.json().catch(() => null);
  if (!res.ok || !json || json.code) throw new Error(`system route refused notifications.deliver_due: ${json?.code ?? `HTTP ${res.status}`}`);
  return { request_id: requestId, ...countsOf(json.data) };
}

async function main(argv) {
  const { limit, evidence } = parseArgs(argv);
  const url = (process.env.SUPABASE_URL ?? '').replace(/\/+$/, '');
  const publishableKey = process.env.SUPABASE_PUBLISHABLE_KEY ?? '';
  if (!url || !publishableKey) throw new Error('SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY are required');
  const credential = readCredential();
  const result = await runOnce({ url, publishableKey, credential, limit });
  const line = JSON.stringify({ at: new Date().toISOString(), step: 'notifications.deliver_due', ...result });
  console.log(line);
  if (evidence) appendFileSync(evidence, `${line}\n`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch((e) => { console.error(`worker: ${e.message}`); process.exitCode = 1; });
}
