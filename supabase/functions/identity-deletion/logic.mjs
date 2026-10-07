// Pure rules of the identity-deletion Edge Function (story 2.11, AD-14, AD-19).
// Shared by the Deno function and the Node tests: no imports, no I/O, no logging.

export const MAX_BODY_BYTES = 1024;
export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
/** A 1.9 system credential (the worker's, purpose identity_deletion). Never stored or logged here. */
export const CREDENTIAL_RE = /^sysc_(local|staging|production)_[A-Za-z0-9_-]{43}$/;

/**
 * Validates the worker's body: {action: "auth_delete", deletion_id}. Returns {ok: true, value}
 * or {ok: false, error} with a coarse code safe to return and log (never a value).
 */
export function parseBody(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return { ok: false, error: 'invalid_body' };
  if (body.action !== 'auth_delete') return { ok: false, error: 'invalid_action' };
  if (Object.keys(body).some((k) => !['action', 'deletion_id'].includes(k))) return { ok: false, error: 'unknown_field' };
  if (typeof body.deletion_id !== 'string' || !UUID_RE.test(body.deletion_id)) return { ok: false, error: 'invalid_deletion_id' };
  return { ok: true, value: body };
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

/**
 * Headers for a platform key: a legacy JWT key goes in both `apikey` and `Authorization`; a new
 * `sb_publishable_`/`sb_secret_` key only in `apikey` (the gateway maps it to its role).
 */
export function keyHeaders(key) {
  const headers = { apikey: key };
  if (typeof key === 'string' && key.startsWith('eyJ')) headers.authorization = `Bearer ${key}`;
  return headers;
}

/**
 * What the Auth Admin user deletion did, as far as the function can tell:
 *   2xx -> deleted; 404 -> absent (already gone); other 4xx -> rejected;
 *   5xx, 408, 429, no response -> unknown.
 * The database decides from its own check that the Auth user is absent; this is only a claim.
 */
export function classifyDeleteResult(status) {
  if (typeof status !== 'number') return 'unknown';
  if (status >= 200 && status < 300) return 'deleted';
  if (status === 404) return 'absent';
  if (status === 408 || status === 429) return 'unknown';
  if (status >= 400 && status < 500) return 'rejected';
  return 'unknown';
}

/** The worker-facing outcome of the fence answer (no account id ever leaves the function). */
export function beginOutcome(data) {
  if (data?.proceed === true && typeof data.auth_user_id === 'string' && UUID_RE.test(data.auth_user_id)) return 'proceed';
  if (typeof data?.reason === 'string' && /^[a-z][a-z0-9_]{0,62}$/.test(data.reason)) return data.reason;
  return 'refused';
}

/** The worker-facing outcome of the completion step. */
export function completeOutcome(data) {
  return ['done', 'retry', 'not_next', 'not_found'].includes(data?.outcome) ? data.outcome : 'retry';
}

/** A system-route envelope for one allowlisted command (no expected_revision). */
export function systemEnvelope(command, payload, requestId) {
  return { version: 1, command, request_id: requestId, payload };
}
