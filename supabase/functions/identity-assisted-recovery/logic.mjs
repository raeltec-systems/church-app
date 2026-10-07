// Pure rules of the identity-assisted-recovery Edge Function (story 2.9, AD-19, AD-20).
// Shared by the Deno function and the Node tests: no imports, no I/O, no logging.

export const PHONE_RE = /^\+[1-9][0-9]{7,14}$/;
/** The grant secret a member device creates: `arg_` + 32 random bytes, base64url. */
export const SECRET_RE = /^arg_[A-Za-z0-9_-]{43}$/;
export const DIGEST_RE = /^[0-9a-f]{64}$/;
export const PASSWORD_MIN_BYTES = 8;
/** bcrypt (GoTrue) uses at most 72 bytes; longer passwords are refused before the grant is used. */
export const PASSWORD_MAX_BYTES = 72;
export const MAX_BODY_BYTES = 4096;
/** A Content-Length header that already announces more than MAX_BODY_BYTES (or is malformed). */
export function declaredTooLarge(header) {
  if (header === null || header === undefined) return false;
  if (!/^[0-9]{1,15}$/.test(String(header).trim())) return true;
  return Number(header) > MAX_BODY_BYTES;
}

export const ACTIONS = new Set(['request', 'status', 'redeem']);

const KEYS = {
  request: ['action', 'phone_username', 'grant_digest'],
  status: ['action', 'grant_digest'],
  redeem: ['action', 'phone_username', 'grant_secret', 'password'],
};

/**
 * Validates a member device's body. Returns {ok: true, value} or {ok: false, error} where error
 * is a coarse code safe to return and log (never a value).
 */
export function parseBody(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return { ok: false, error: 'invalid_body' };
  const action = body.action;
  if (!ACTIONS.has(action)) return { ok: false, error: 'invalid_action' };
  const allowed = KEYS[action];
  if (Object.keys(body).some((k) => !allowed.includes(k))) return { ok: false, error: 'unknown_field' };
  if (allowed.includes('phone_username') &&
      (typeof body.phone_username !== 'string' || !PHONE_RE.test(body.phone_username))) {
    return { ok: false, error: 'invalid_phone_username' };
  }
  if (allowed.includes('grant_digest') &&
      (typeof body.grant_digest !== 'string' || !DIGEST_RE.test(body.grant_digest))) {
    return { ok: false, error: 'invalid_grant_digest' };
  }
  if (allowed.includes('grant_secret') &&
      (typeof body.grant_secret !== 'string' || !SECRET_RE.test(body.grant_secret))) {
    return { ok: false, error: 'invalid_grant' };
  }
  if (allowed.includes('password')) {
    if (typeof body.password !== 'string') return { ok: false, error: 'invalid_password' };
    const bytes = new TextEncoder().encode(body.password).length;
    if (bytes < PASSWORD_MIN_BYTES || bytes > PASSWORD_MAX_BYTES) return { ok: false, error: 'password_length' };
  }
  return { ok: true, value: body };
}

/** sha256 of the secret's UTF-8 bytes, lower-case hex (what the device sent as its digest). */
export async function digestHex(secret) {
  const buf = await globalThis.crypto.subtle.digest('SHA-256', new TextEncoder().encode(secret));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
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
 * What the Auth Admin password update did, as far as the function can tell:
 *   2xx                 -> applied
 *   4xx (refused input) -> rejected (Auth refused before changing anything)
 *   5xx, 408, 429, no response (timeout, network) -> unknown
 * The database decides the outcome from its own record; this is only the function's claim.
 */
export function classifyAuthResult(status) {
  if (typeof status !== 'number') return 'unknown';
  if (status >= 200 && status < 300) return 'applied';
  if (status === 408 || status === 429) return 'unknown';
  if (status >= 400 && status < 500) return 'rejected';
  return 'unknown';
}

/** The member-facing outcome of a completed operation. */
export function redeemOutcome(dbOutcome) {
  switch (dbOutcome) {
    case 'succeeded': return 'succeeded';
    case 'failed': return 'password_rejected';
    case 'uncertain': return 'uncertain';
    default: return 'uncertain';
  }
}

/** The member-facing outcome of a request refusal (neutral: never says whether an account exists). */
export function requestOutcome(data) {
  if (data?.accepted === true && typeof data.request_code === 'string') return 'received';
  if (data?.reason === 'rate_limited') return 'rate_limited';
  if (data?.reason === 'invalid') return 'refused';
  return 'unavailable';
}

/** A system-route envelope for one allowlisted command (no expected_revision). */
export function systemEnvelope(command, payload, requestId) {
  return { version: 1, command, request_id: requestId, payload };
}

/** Text that must never appear in a response or log line of this function. */
export function leaks(text, secrets) {
  return secrets.filter((s) => typeof s === 'string' && s.length >= 6 && text.includes(s));
}
