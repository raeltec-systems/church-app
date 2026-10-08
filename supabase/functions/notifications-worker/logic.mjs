// Pure rules and the run loop of the notifications-worker Edge Function (story 3.4; AD-8,
// AD-17, AD-19). Shared by the Deno function and the Node tests: no imports, no I/O of its own
// (the system-route call and the clock are injected), no logging.

export const MAX_BODY_BYTES = 256;
export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
/** A 1.9 system credential of the purpose notifications_worker. Never stored or logged here. */
export const CREDENTIAL_RE = /^sysc_(local|staging|production)_[A-Za-z0-9_-]{43}$/;
/** Wall-clock budget of one run; the lease (from the claim) bounds it further. */
export const RUN_BUDGET_MS = 50_000;
/** Attempt outcomes the database may answer; anything else counts as `unexpected`. */
export const OUTCOMES = ['delivered', 'cancelled', 'finished', 'fenced', 'expired', 'obsolete',
  'ineligible', 'failed', 'exhausted', 'not_found'];

/**
 * The caller's body: empty, {} or {action: "run", limit?: 1..100}. Returns {ok, value} or
 * {ok: false, error} with a coarse code safe to return and log.
 */
export function parseBody(body) {
  if (body === null || body === undefined) return { ok: true, value: { action: 'run' } };
  if (typeof body !== 'object' || Array.isArray(body)) return { ok: false, error: 'invalid_body' };
  if (Object.keys(body).some((k) => !['action', 'limit'].includes(k))) return { ok: false, error: 'unknown_field' };
  if (body.action !== undefined && body.action !== 'run') return { ok: false, error: 'invalid_action' };
  if (body.limit !== undefined && !(Number.isInteger(body.limit) && body.limit >= 1 && body.limit <= 100)) {
    return { ok: false, error: 'invalid_limit' };
  }
  return { ok: true, value: { action: 'run', ...(body.limit === undefined ? {} : { limit: body.limit }) } };
}

/** The caller's system credential header, or null when missing or malformed. */
export function credentialFrom(header) {
  return typeof header === 'string' && CREDENTIAL_RE.test(header) ? header : null;
}

/** A Content-Length header that already announces more than MAX_BODY_BYTES (or is malformed). */
export function declaredTooLarge(header) {
  if (header === null || header === undefined) return false;
  if (!/^[0-9]{1,15}$/.test(String(header).trim())) return true;
  return Number(header) > MAX_BODY_BYTES;
}

/** Headers for a platform key (legacy JWT keys also go in Authorization). */
export function keyHeaders(key) {
  const headers = { apikey: key };
  if (typeof key === 'string' && key.startsWith('eyJ')) headers.authorization = `Bearer ${key}`;
  return headers;
}

/** A system-route envelope for one allowlisted command (no expected_revision). */
export function systemEnvelope(command, payload, requestId) {
  return { version: 1, command, request_id: requestId, payload };
}

/**
 * Validates a claim answer: {jobs: [{job_id, lease_token}], claimed, reclaimed, expired,
 * lease_seconds}. Returns the normalised answer or null.
 */
export function parseClaim(data) {
  if (!data || typeof data !== 'object' || !Array.isArray(data.jobs)) return null;
  for (const k of ['claimed', 'reclaimed', 'expired', 'lease_seconds']) {
    if (!Number.isInteger(data[k]) || data[k] < 0) return null;
  }
  const jobs = [];
  for (const j of data.jobs) {
    if (!j || typeof j.job_id !== 'string' || !UUID_RE.test(j.job_id)
        || !Number.isSafeInteger(j.lease_token) || j.lease_token < 1) return null;
    jobs.push({ job_id: j.job_id, lease_token: j.lease_token });
  }
  if (jobs.length !== data.claimed) return null;
  return { jobs, claimed: data.claimed, reclaimed: data.reclaimed, expired: data.expired,
    lease_seconds: data.lease_seconds };
}

/** The deadline of a run: the budget, but never past the lease minus a safety margin. */
export function runDeadline(startMs, leaseSeconds, budgetMs = RUN_BUDGET_MS) {
  const leaseMs = Math.max(0, leaseSeconds * 1000 - 5_000);
  return startMs + Math.min(budgetMs, leaseMs);
}

/**
 * One worker run: claim a batch, then attempt each leased job with its fencing token until the
 * deadline. `system(command, payload)` performs one system-route call and resolves to its `data`
 * or throws (a refusal or an unreachable route). A failed or uncertain attempt call is counted
 * `uncertain`: its lease lapses and a later run reclaims the job (the database fences the late
 * answer), so the logical outcome stays single. Jobs left when the deadline passes are counted
 * `deferred`. Returns counts only (no ids).
 */
export async function runOnce({ system, limit, now = () => Date.now(), budgetMs = RUN_BUDGET_MS }) {
  const start = now();
  const claim = parseClaim(await system('notifications.claim', limit === undefined ? {} : { limit }));
  if (!claim) throw new Error('unexpected_claim');
  const deadline = runDeadline(start, claim.lease_seconds, budgetMs);
  const outcomes = {};
  let uncertain = 0;
  let deferred = 0;
  for (const job of claim.jobs) {
    if (now() >= deadline) { deferred += 1; continue; }
    try {
      const data = await system('notifications.attempt', { job_id: job.job_id, lease_token: job.lease_token });
      const outcome = OUTCOMES.includes(data?.outcome) ? data.outcome : 'unexpected';
      outcomes[outcome] = (outcomes[outcome] ?? 0) + 1;
    } catch {
      uncertain += 1;
    }
  }
  return { claimed: claim.claimed, reclaimed: claim.reclaimed, expired: claim.expired,
    outcomes, uncertain, deferred };
}
