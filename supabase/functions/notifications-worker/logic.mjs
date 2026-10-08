// Pure rules and the run loop of the notifications-worker Edge Function (story 3.4; AD-8,
// AD-17, AD-19). Shared by the Deno function and the Node tests: no imports, no I/O of its own
// (the system-route call and the clock are injected), no logging.

export const MAX_BODY_BYTES = 256;
export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
/** The worker's 1.9 system credential (Edge secret). Never logged or returned. */
export const CREDENTIAL_RE = /^sysc_(local|staging|production)_[A-Za-z0-9_-]{43}$/;
/** The scheduler's trigger token (Vault + Edge secret): it can only start one run. */
export const TRIGGER_RE = /^nwt_[0-9a-f]{64}$/;
/** Wall-clock budget of one run; the lease (from the claim) bounds it further. */
export const RUN_BUDGET_MS = 50_000;
/** Stop this long before the lease ends: one 10 s call plus a margin. */
export const LEASE_MARGIN_MS = 15_000;
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

/** The function's own configuration: both secrets well-formed, else null (fail closed). */
export function configFrom(env) {
  const credential = env?.credential;
  const trigger = env?.trigger;
  if (typeof credential !== 'string' || !CREDENTIAL_RE.test(credential)) return null;
  if (typeof trigger !== 'string' || !TRIGGER_RE.test(trigger)) return null;
  return { credential, trigger };
}

/** Constant-time string equality (same length required; the loop never exits early). */
export function constantTimeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const len = Math.max(a.length, b.length);
  let diff = a.length ^ b.length;
  for (let i = 0; i < len; i++) diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  return diff === 0;
}

/** True only when the caller's `x-worker-trigger` header is the configured trigger. */
export function triggerMatches(header, expected) {
  if (typeof header !== 'string' || !TRIGGER_RE.test(header)) return false;
  return constantTimeEqual(header, expected);
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

/** The deadline of a run: the budget, but never later than the lease minus the margin. */
export function runDeadline(startMs, leaseSeconds, budgetMs = RUN_BUDGET_MS) {
  const leaseMs = Math.max(0, leaseSeconds * 1000 - LEASE_MARGIN_MS);
  return startMs + Math.min(budgetMs, leaseMs);
}

/**
 * One worker run: claim a batch, then attempt each leased job with its fencing token until the
 * deadline. `system(command, payload)` performs one system-route call and resolves to its `data`
 * or throws (a refusal or an unreachable route). A failed or uncertain attempt call is counted
 * `uncertain`: if it did not commit, its lease lapses and the next claim counts the lapse and
 * reclaims the job (the database fences any late answer), so the logical outcome stays single.
 * Jobs left when the deadline passes are released unused (`deferred`; no attempt counted).
 * Returns counts only (no ids).
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
    if (now() >= deadline) {
      deferred += 1;
      try {
        await system('notifications.release', { job_id: job.job_id, lease_token: job.lease_token });
      } catch {
        // The lease lapses instead; the next claim counts it.
      }
      continue;
    }
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

// ------------------------------------------------------------------------------------------------
// Story 3.6: the push stage (after the inbox stage, only with the FCM secret configured)
// ------------------------------------------------------------------------------------------------

/** Push outcomes the database may answer (prepare and record); anything else is `unexpected`. */
export const PUSH_OUTCOMES = ['accepted', 'retry', 'failed', 'exhausted', 'obsolete', 'expired', 'fenced',
  'cancelled', 'finished', 'not_found'];
/** Provider answers per device. */
export const PUSH_RESULTS = ['accepted', 'token_invalid', 'rejected', 'transient'];
const TOKEN_RE = /^[A-Za-z0-9_:.-]{20,4096}$/;
const PROVIDER_CODE_RE = /^[A-Z][A-Z0-9_]{0,39}$/;

/**
 * Validates a push claim answer: {jobs: [{push_job_id, lease_token}], claimed, reclaimed, expired,
 * lease_seconds, push_enabled}. Returns the normalised answer or null.
 */
export function parsePushClaim(data) {
  if (!data || typeof data !== 'object' || !Array.isArray(data.jobs) || typeof data.push_enabled !== 'boolean') return null;
  for (const k of ['claimed', 'reclaimed', 'expired', 'lease_seconds']) {
    if (!Number.isInteger(data[k]) || data[k] < 0) return null;
  }
  const jobs = [];
  for (const j of data.jobs) {
    if (!j || typeof j.push_job_id !== 'string' || !UUID_RE.test(j.push_job_id)
        || !Number.isSafeInteger(j.lease_token) || j.lease_token < 1) return null;
    jobs.push({ push_job_id: j.push_job_id, lease_token: j.lease_token });
  }
  if (jobs.length !== data.claimed) return null;
  return { jobs, claimed: data.claimed, reclaimed: data.reclaimed, expired: data.expired,
    lease_seconds: data.lease_seconds, push_enabled: data.push_enabled };
}

/**
 * Validates a prepare answer of outcome `send`: the generic message (exactly notification_id,
 * item_id, title, body, ttl_seconds, expires_at_epoch) and 1..10 targets {device_id, platform,
 * token}. Returns {message, targets} or null; nothing malformed is ever sent.
 */
export function parsePrepare(data) {
  if (!data || data.outcome !== 'send') return null;
  const m = data.message;
  if (!m || typeof m !== 'object' || Object.keys(m).sort().join(',')
      !== 'body,expires_at_epoch,item_id,notification_id,title,ttl_seconds') return null;
  if (!UUID_RE.test(m.item_id ?? '') || !UUID_RE.test(m.notification_id ?? '')) return null;
  if (typeof m.title !== 'string' || typeof m.body !== 'string' || m.title === '' || m.title.length > 200
      || m.body.length > 500) return null;
  if (!Number.isSafeInteger(m.ttl_seconds) || m.ttl_seconds < 1 || !Number.isSafeInteger(m.expires_at_epoch)) return null;
  if (!Array.isArray(data.targets) || data.targets.length < 1 || data.targets.length > 10) return null;
  const targets = [];
  for (const t of data.targets) {
    if (!t || !UUID_RE.test(t.device_id ?? '') || !['android', 'ios'].includes(t.platform)
        || typeof t.token !== 'string' || !TOKEN_RE.test(t.token)) return null;
    targets.push({ device_id: t.device_id, platform: t.platform, token: t.token });
  }
  return {
    message: { notification_id: m.notification_id, item_id: m.item_id, title: m.title, body: m.body,
      ttl_seconds: m.ttl_seconds, expires_at_epoch: m.expires_at_epoch },
    targets,
  };
}

/** One device answer for notifications.push_record (no token, no text). */
export function deviceResult(target, answer) {
  const result = PUSH_RESULTS.includes(answer?.result) ? answer.result : 'transient';
  const out = { device_id: target.device_id, result };
  if (Number.isInteger(answer?.provider_status) && answer.provider_status >= 100 && answer.provider_status <= 599) {
    out.provider_status = answer.provider_status;
  }
  if (typeof answer?.provider_code === 'string' && PROVIDER_CODE_RE.test(answer.provider_code)) {
    out.provider_code = answer.provider_code;
  }
  return out;
}

/**
 * One push run: claim a batch of push jobs; for each, prepare (the database rechecks it now and
 * answers the generic message with the live targets), send to each target through `sender`,
 * then record the per-device answers. Provider acceptance is counted as `accepted`, never as
 * delivery. A quota answer or our own credential refused stops sending: the rest are released
 * unused. When the provider cannot be used at all (OAuth refused), the job is released and the
 * run stops (no attempt counted). A failed or uncertain system call is counted `uncertain`: the
 * lease lapses and the next claim counts it and sends again with the same notification id.
 * Returns counts only (no ids, tokens or text).
 */
export async function runPush({ system, sender, limit, now = () => Date.now(), deadlineMs }) {
  const start = now();
  const claim = parsePushClaim(await system('notifications.push_claim', limit === undefined ? {} : { limit }));
  if (!claim) throw new Error('unexpected_claim');
  const deadline = Math.min(deadlineMs ?? start + RUN_BUDGET_MS, runDeadline(start, claim.lease_seconds));
  const outcomes = {};
  const sent = {};
  let uncertain = 0;
  let deferred = 0;
  let stopped = null;
  const count = (bag, key) => { bag[key] = (bag[key] ?? 0) + 1; };
  const release = async (job) => {
    deferred += 1;
    try {
      await system('notifications.push_release', job);
    } catch {
      // The lease lapses instead; the next claim counts it.
    }
  };
  for (const job of claim.jobs) {
    if (stopped || now() >= deadline) {
      await release(job);
      continue;
    }
    let prep;
    try {
      prep = await system('notifications.push_prepare', job);
    } catch {
      uncertain += 1;
      continue;
    }
    if (prep?.outcome !== 'send') {
      count(outcomes, PUSH_OUTCOMES.includes(prep?.outcome) ? prep.outcome : 'unexpected');
      continue;
    }
    const parsed = parsePrepare(prep);
    if (!parsed) {
      count(outcomes, 'unexpected');
      await release(job);
      continue;
    }
    const results = [];
    for (const target of parsed.targets) {
      let answer;
      try {
        answer = await sender.send(target, parsed.message);
      } catch (e) {
        stopped = ['oauth_refused', 'oauth_unreachable'].includes(e?.code) ? e.code : 'provider_unavailable';
        break;
      }
      const r = deviceResult(target, answer);
      results.push(r);
      count(sent, r.result);
      if (answer?.stop) {
        stopped = 'provider_stop';
        break;
      }
    }
    if (results.length === 0) {
      await release(job);
      continue;
    }
    try {
      const rec = await system('notifications.push_record', { ...job, results });
      count(outcomes, PUSH_OUTCOMES.includes(rec?.outcome) ? rec.outcome : 'unexpected');
    } catch {
      uncertain += 1;
    }
  }
  return { claimed: claim.claimed, reclaimed: claim.reclaimed, expired: claim.expired, enabled: claim.push_enabled,
    outcomes, sent, uncertain, deferred, ...(stopped ? { stopped } : {}) };
}
