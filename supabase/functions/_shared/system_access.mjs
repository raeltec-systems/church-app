// Pure request and credential primitives shared by Supabase Edge functions and Node tooling.
// Keep this module runtime-neutral: no Node, Deno, filesystem, network or function policy imports.

export const UUID_PATTERN = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
export const UUID_RE = new RegExp(`^${UUID_PATTERN}$`);

// Keep this unanchored source string for the repository secret scanner's public pattern API.
export const SYSTEM_CREDENTIAL_PATTERN = 'sysc_(local|staging|production)_[A-Za-z0-9_-]{43}';
export const SYSTEM_CREDENTIAL_RE = new RegExp(`^${SYSTEM_CREDENTIAL_PATTERN}$`);

/** A credential header value, or null when missing or malformed. */
export function credentialFrom(header) {
  return typeof header === 'string' && SYSTEM_CREDENTIAL_RE.test(header) ? header : null;
}

/** True when a Content-Length value is malformed or exceeds the supplied caller-owned limit. */
export function declaredTooLarge(header, maxBytes) {
  if (header === null || header === undefined) return false;
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 0) throw new TypeError('maxBytes must be a non-negative safe integer');
  if (!/^[0-9]{1,15}$/.test(String(header).trim())) return true;
  return Number(header) > maxBytes;
}

/** Headers for a platform key; legacy JWT keys also require Authorization. */
export function keyHeaders(key) {
  const headers = { apikey: key };
  if (typeof key === 'string' && key.startsWith('eyJ')) headers.authorization = `Bearer ${key}`;
  return headers;
}

/** A system-route envelope for one allowlisted command (no expected_revision). */
export function systemEnvelope(command, payload, requestId) {
  return { version: 1, command, request_id: requestId, payload };
}
