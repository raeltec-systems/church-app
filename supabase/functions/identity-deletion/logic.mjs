// Pure rules of the identity-deletion Edge Function (story 2.11, AD-14, AD-19).
// Shared by the Deno function and the Node tests: only imports runtime-neutral shared primitives,
// with no I/O or logging.

import {
  SYSTEM_CREDENTIAL_RE,
  UUID_RE,
  credentialFrom as sharedCredentialFrom,
  declaredTooLarge as sharedDeclaredTooLarge,
  keyHeaders,
  systemEnvelope,
} from '../_shared/system_access.mjs';

export const MAX_BODY_BYTES = 1024;
export { UUID_RE };
/** A 1.9 system credential (the worker's, purpose identity_deletion). Never stored or logged here. */
export const CREDENTIAL_RE = SYSTEM_CREDENTIAL_RE;

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
export const credentialFrom = sharedCredentialFrom;
export const declaredTooLarge = (header) => sharedDeclaredTooLarge(header, MAX_BODY_BYTES);
export { keyHeaders, systemEnvelope };

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
