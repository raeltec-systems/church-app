// Story 4.14: helpers the Duties and Follow-ups E2Es (stories 4.1-4.13) had copied file by file:
// the run's notifications-worker principal and credential with a run-once runner, church-time
// dates (Africa/Lusaka, UTC+02:00 all year) and small answer predicates. Each script keeps
// re-exporting the names its offline test imports. Local stack only (the worker runs against the
// origin the caller's harness already checked).
import { execFile } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { psql } from './harness.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const CHURCH_OFFSET_MS = 2 * 3_600_000;

/**
 * Registers a `notifications_worker` principal named `principalName` with a fresh local credential
 * (only its digest is stored; `label` names the registration, valid two hours) and returns the
 * ids to revoke at cleanup plus `worker()`, which runs `tools/notifications/worker.mjs run-once`
 * against `origin` and answers its JSON summary line with `exit: 0`, or `{exit, error}`.
 */
export function notificationsWorker({ origin, key, principalName, label, operator }) {
  const credential = `sysc_local_${randomBytes(32).toString('base64url')}`;
  const principal = psql(`select app.sys_create_principal('${principalName}', 'notifications_worker', '${operator}')`);
  const credentialId = JSON.parse(psql(`select app.sys_register_credential('${principal}',
    '${createHash('sha256').update(credential).digest('hex')}', '${label}', interval '2 hours', '${operator}')`)).credential_id;
  const worker = async () => {
    try {
      const { stdout } = await promisify(execFile)('node', [join(ROOT, 'tools/notifications/worker.mjs'), 'run-once'], {
        encoding: 'utf8',
        env: { PATH: process.env.PATH, SUPABASE_URL: origin, SUPABASE_PUBLISHABLE_KEY: key, NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL: credential } });
      const line = stdout.split('\n').find((l) => l.startsWith('{'));
      return { exit: 0, ...(line ? JSON.parse(line) : {}) };
    } catch (e) {
      return { exit: e.code ?? 1, error: String(e.stderr ?? '').trim().slice(-160) };
    }
  };
  return { principal, credentialId, worker };
}

/** The church date (`YYYY-MM-DD`) of the k-th Sunday at least four days after `nowMs`. */
export function churchSunday(nowMs, k) {
  const local = new Date(nowMs + CHURCH_OFFSET_MS + 4 * 86_400_000);
  const day = local.getUTCDay();
  const first = new Date(Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate() + ((7 - day) % 7)));
  return new Date(first.getTime() + k * 7 * 86_400_000).toISOString().slice(0, 10);
}

/** The UTC instant (ISO, milliseconds) of a church-local date and `HH:MM`. */
export function churchInstant(date, hhmm) {
  return new Date(Date.parse(`${date}T${hhmm}:00Z`) - CHURCH_OFFSET_MS).toISOString();
}

/** The church `HH:MM` of an ISO instant. */
export function churchClock(iso) {
  return new Date(Date.parse(iso) + CHURCH_OFFSET_MS).toISOString().slice(11, 16);
}

/** Exactly one concurrent answer succeeded and every other one was a `conflict`. */
export function oneWinner(answers) {
  const ok = answers.filter((a) => a.status === 200 && !a.code).length;
  const conflicts = answers.filter((a) => a.code === 'conflict').length;
  return ok === 1 && conflicts === answers.length - 1;
}

/** A refused direct table query: an error status and no rows in the body. */
export function refusedTableQuery(r) {
  return r.status >= 400 && !Array.isArray(r.json);
}

/** The claims of a session token (no signature check: the server issued it in this run). */
export function sessionClaims(jwt) {
  const part = String(jwt ?? '').split('.')[1];
  if (!part) throw new Error('no session token');
  return JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));
}

/** A jsonb SQL literal of `value`, dollar-quoted. */
export function jsonLiteral(value) {
  const text = JSON.stringify(value);
  if (text.includes('$j$')) throw new Error('unexpected quote tag');
  return `$j$${text}$j$::jsonb`;
}

/** Rows as one sorted, comma-joined string (order-independent comparison). */
export function summarize(rows) {
  return [...rows].sort().join(',');
}

/** A predicate: an inbox item carries exactly the generic title and body of its reminder kind. */
export function genericItemCheck(genericText) {
  return (item) => {
    const text = genericText[item?.reminder_kind];
    return Boolean(text) && item.title === text[0] && item.body === text[1];
  };
}
