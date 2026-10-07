#!/usr/bin/env node
// Member deletion worker (story 2.11; AD-14, AD-19). A server-side process, run by the restricted
// operator or a server/CI scheduler, never by a client.
//
// It drives the database's deletion steps through the 1.9 system route with a credential of the
// purpose `identity_deletion`, appends the opaque journal entries to the independent 1.10 recovery
// journal BEFORE the database lets any destructive step run, and asks the Edge Function
// `identity-deletion` (the only holder of Auth Admin power) to delete the Auth user. It holds no
// service-role key. Every step is idempotent: stop it anywhere (Ctrl-C, a crash, --max-steps) and
// run it again; a journal entry appended but not yet acknowledged is found and acknowledged
// instead of being appended twice. The database acknowledges journal entries only in chain order
// (seq = its head + 1, chained hash, canonical hash), so entries other writers appended after its
// head are acknowledged first (identity.deletion_journal_catch_up).
//
// Usage:
//   node tools/identity-deletion/worker.mjs run [--deletion <uuid>] [--max-steps <n>]
//        [--journal-dir <dir>] [--function-url <url>] [--evidence <file.jsonl>]
// Environment (server-side secret store; never in the repo):
//   SUPABASE_URL                         project API URL
//   SUPABASE_PUBLISHABLE_KEY             publishable key (the system route's role)
//   IDENTITY_DELETION_SYSTEM_CREDENTIAL  sysc_<env>_... of a principal with purpose
//                                        identity_deletion (or IDENTITY_DELETION_CREDENTIAL_FILE)
//   Journal: --journal-dir / RECOVERY_JOURNAL_DIR (local create-only segments; default
//   .recovery-state/journal, the same journal the 1.10 rehearsal uses), or
//   RECOVERY_DRIVE_FOLDER_ID + RECOVERY_DRIVE_ACCESS_TOKEN (the owner's restricted Drive folder).
// Output: JSON lines with deletion ids, steps and outcome codes only (no names, numbers, account
// ids or credentials).

import { randomUUID } from 'node:crypto';
import { appendFileSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { DriveJournal, DriveRestClient, LocalSegmentJournal } from '../recovery/journal.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
export const CREDENTIAL_RE = /^sysc_(local|staging|production)_[A-Za-z0-9_-]{43}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** Deep equality of the opaque fields that identify a journal entry (kind, subject, object). */
export function sameEntry(entry, fields) {
  if (!entry || !fields || entry.kind !== fields.kind) return false;
  if ((entry.subject ?? null) !== (fields.subject ?? null)) return false;
  const a = entry.object ?? null;
  const b = fields.object ?? null;
  if (a === null || b === null) return a === b;
  return a.bucket === b.bucket && a.object_id === b.object_id;
}

/** The entry already in the journal after `afterSeq` for these fields (appended before an interruption), if any. */
export function findJournaled(entries, fields, afterSeq = 0) {
  return (entries ?? []).find((e) => e && e.seq > afterSeq && sameEntry(e, fields)) ?? null;
}

/** Only opaque fields may go to the journal; refuses anything else the database might send. */
export function checkEntryFields(fields) {
  if (!fields || typeof fields !== 'object') throw new Error('no entry fields');
  const allowed = { access_revoked: ['kind', 'subject'], deletion_manifest: ['kind', 'subject', 'object'],
    deletion_completed: ['kind', 'object'] }[fields.kind];
  if (!allowed) throw new Error('unexpected journal kind');
  if (Object.keys(fields).some((k) => !allowed.includes(k))) throw new Error('unexpected journal field');
  if ('subject' in fields && !UUID_RE.test(fields.subject)) throw new Error('subject must be a uuid');
  if ('object' in fields) {
    const o = fields.object;
    if (!o || Object.keys(o).sort().join() !== 'bucket,object_id' || !['identity-member', 'auth-user'].includes(o.bucket)
        || !UUID_RE.test(o.object_id)) throw new Error('object must be {bucket, object_id}');
  }
  return fields;
}

/**
 * Drives one deletion until it is done, waits, fails a step, or `maxSteps` actions ran.
 * Dependencies: sys(command, payload) -> data, journal {list, append}, auth(deletionId) -> outcome.
 * Returns {deletion_id, result, steps: [...]}; result is done | wait:<reason> | stopped |
 * failed:<code>.
 */
export async function runDeletion({ deletionId, sys, journal, auth, maxSteps = 50, log = (line) => line }) {
  const steps = [];
  for (let i = 0; ; i++) {
    const next = (await sys('identity.deletion_next', { deletion_id: deletionId }))?.next;
    if (!next) return { deletion_id: deletionId, result: 'failed:not_found', steps };
    if (next.action === 'done') return { deletion_id: deletionId, result: 'done', steps };
    if (next.action === 'wait') return { deletion_id: deletionId, result: `wait:${next.reason}`, steps };
    if (i >= maxSteps) return { deletion_id: deletionId, result: 'stopped', steps, stopped_before: next.step };
    let outcome;
    if (next.action === 'journal') {
      const fields = checkEntryFields(next.entry);
      // The database acknowledges entries only in chain order after its head: first acknowledge
      // what other writers appended since (catch-up), stopping at an entry of ours appended
      // before an interruption; only then append a new one.
      const head = next.journal_head ?? { seq: 0 };
      const after = ((await journal.list()) ?? []).filter((e) => e && e.seq > head.seq);
      let existing = null;
      for (const e of after) {
        if (sameEntry(e, fields)) { existing = e; break; }
        const caught = await sys('identity.deletion_journal_catch_up', { entry: e });
        steps.push(log({ deletion_id: deletionId, step: next.step, action: 'catch_up', seq: e.seq,
          outcome: caught?.acked ? 'acked' : `refused_${caught?.reason ?? 'unknown'}` }));
        if (!caught?.acked) return { deletion_id: deletionId, result: `failed:${caught?.reason ?? 'unknown'}`, steps };
      }
      const entry = existing ?? await journal.append(fields);
      const ack = await sys('identity.deletion_journal_ack', { deletion_id: deletionId, step: next.step, entry });
      outcome = ack?.acked ? (existing ? 'acked_existing' : 'journaled') : `refused_${ack?.reason ?? 'unknown'}`;
      steps.push(log({ deletion_id: deletionId, step: next.step, action: 'journal', outcome, seq: entry.seq }));
      if (!ack?.acked) return { deletion_id: deletionId, result: `failed:${ack?.reason ?? 'unknown'}`, steps };
    } else if (next.action === 'auth') {
      outcome = await auth(deletionId);
      steps.push(log({ deletion_id: deletionId, step: next.step, action: 'auth', outcome }));
      if (outcome !== 'done') return { deletion_id: deletionId, result: `failed:auth_${outcome}`, steps };
    } else if (next.action === 'advance') {
      const r = await sys('identity.deletion_advance', { deletion_id: deletionId });
      outcome = r?.outcome ?? 'unknown';
      steps.push(log({ deletion_id: deletionId, step: next.step, action: 'advance', outcome, stores: r?.stores }));
      if (!['done', 'completed', 'incomplete', 'retry', 'waiting'].includes(outcome)) {
        return { deletion_id: deletionId, result: `failed:${outcome}`, steps };
      }
    } else {
      return { deletion_id: deletionId, result: `failed:unknown_action`, steps };
    }
  }
}

/** The system route client (publishable key + the worker's credential). */
export function systemClient({ url, publishableKey, credential, fetchImpl = globalThis.fetch }) {
  if (!CREDENTIAL_RE.test(credential ?? '')) throw new Error('IDENTITY_DELETION_SYSTEM_CREDENTIAL is missing or malformed');
  return async (command, payload) => {
    const res = await fetchImpl(`${url}/rest/v1/rpc/system_command`, {
      method: 'POST',
      headers: { apikey: publishableKey, 'content-type': 'application/json', 'content-profile': 'api',
        'x-system-credential': credential },
      body: JSON.stringify({ version: 1, command, request_id: randomUUID(), payload }),
    });
    const json = await res.json().catch(() => null);
    if (!res.ok || !json || json.code) throw new Error(`system route refused ${command}: ${json?.code ?? `HTTP ${res.status}`}`);
    return json.data;
  };
}

/** The Edge Function client: the account step. Network failures are `unreachable` (retried later). */
export function authClient({ functionUrl, publishableKey, credential, fetchImpl = globalThis.fetch }) {
  return async (deletionId) => {
    try {
      const res = await fetchImpl(functionUrl, {
        method: 'POST',
        headers: { apikey: publishableKey, 'content-type': 'application/json', 'x-system-credential': credential },
        body: JSON.stringify({ action: 'auth_delete', deletion_id: deletionId }),
      });
      const json = await res.json().catch(() => null);
      return typeof json?.outcome === 'string' ? json.outcome : `http_${res.status}`;
    } catch {
      return 'unreachable';
    }
  };
}

export function journalFrom({ journalDir, env = process.env }) {
  if (!journalDir && env.RECOVERY_DRIVE_FOLDER_ID && env.RECOVERY_DRIVE_ACCESS_TOKEN) {
    return new DriveJournal({ client: new DriveRestClient({ accessToken: env.RECOVERY_DRIVE_ACCESS_TOKEN }),
      folderId: env.RECOVERY_DRIVE_FOLDER_ID });
  }
  return new LocalSegmentJournal(resolve(journalDir ?? env.RECOVERY_JOURNAL_DIR
    ?? join(env.RECOVERY_STATE_DIR ?? join(ROOT, '.recovery-state'), 'journal')));
}

async function main(argv) {
  const args = [...argv];
  const opt = (name) => { const i = args.indexOf(name); if (i < 0) return undefined; const v = args[i + 1]; args.splice(i, 2); return v; };
  const deletion = opt('--deletion');
  const maxSteps = Number(opt('--max-steps') ?? 50);
  const journalDir = opt('--journal-dir');
  const evidence = opt('--evidence');
  const url = (process.env.SUPABASE_URL ?? '').replace(/\/+$/, '');
  const functionUrl = opt('--function-url') ?? `${url}/functions/v1/identity-deletion`;
  if (args[0] !== 'run') {
    console.error('usage: worker.mjs run [--deletion <uuid>] [--max-steps <n>] [--journal-dir <dir>] [--function-url <url>] [--evidence <file>]');
    process.exitCode = 2;
    return;
  }
  if (!url || !process.env.SUPABASE_PUBLISHABLE_KEY) throw new Error('SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY are required');
  if (deletion && !UUID_RE.test(deletion)) throw new Error('--deletion must be a uuid');
  if (!Number.isInteger(maxSteps) || maxSteps < 0) throw new Error('--max-steps must be a non-negative integer');
  const credential = (process.env.IDENTITY_DELETION_SYSTEM_CREDENTIAL
    ?? (process.env.IDENTITY_DELETION_CREDENTIAL_FILE ? readFileSync(process.env.IDENTITY_DELETION_CREDENTIAL_FILE, 'utf8') : '')).trim();
  const sys = systemClient({ url, publishableKey: process.env.SUPABASE_PUBLISHABLE_KEY, credential });
  const auth = authClient({ functionUrl, publishableKey: process.env.SUPABASE_PUBLISHABLE_KEY, credential });
  const journal = journalFrom({ journalDir });
  const log = (line) => {
    const out = { at: new Date().toISOString(), ...line };
    console.log(JSON.stringify(out));
    if (evidence) appendFileSync(evidence, `${JSON.stringify(out)}\n`);
    return out;
  };
  const ids = deletion ? [deletion]
    : ((await sys('identity.deletion_queue', {}))?.deletions ?? []).map((d) => d.deletion_id);
  let budget = maxSteps;
  for (const id of ids) {
    const r = await runDeletion({ deletionId: id, sys, journal, auth, maxSteps: budget, log });
    budget -= r.steps.length;
    log({ deletion_id: id, result: r.result, ...(r.stopped_before ? { stopped_before: r.stopped_before } : {}) });
  }
  log({ summary: true, deletions: ids.length });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch((e) => { console.error(`worker: ${e.message}`); process.exitCode = 1; });
}
