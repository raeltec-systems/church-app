// Pure rules of the content-assets Edge Function (story 6.2; AD-2, AD-13, AD-19).
// Shared by the Deno function and the Node tests: only imports runtime-neutral shared primitives,
// with no I/O or logging.
//
// The server never trusts a declared type or file name: it measures the bytes. PNG, JPEG and WebP
// are recognised from their signatures and their dimensions read from their headers; anything else
// (SVG, HTML, a renamed text file) is refused before anything is stored.

import { UUID_RE, declaredTooLarge as sharedDeclaredTooLarge, keyHeaders } from '../_shared/system_access.mjs';

/** The largest body read at all; each purpose's own limit is checked by the database. */
export const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;
export const DRAFT_BUCKET = 'content-drafts';
export const PUBLIC_BUCKET = 'content-public';
/** How long a public object may be cached: a withdrawn file stops being served soon after removal. */
export const PUBLIC_CACHE_CONTROL = 'max-age=300';
export const PURPOSE_RE = /^[a-z][a-z0-9_]{0,40}$/;
export const DRAFT_PATH_RE = /^[0-9a-f-]{36}\.[a-z0-9]{2,5}$/;
export const PUBLIC_PATH_RE = /^[a-z][a-z0-9_]{0,30}\/[0-9a-f-]{36}\/r[0-9]{1,9}\/[a-z][a-z0-9_]{0,30}\.[a-z0-9]{2,5}$/;
export const OBJECT_KEY_RE = /^[A-Za-z0-9._][A-Za-z0-9._/-]{0,511}$/;
export const IMAGE_TYPES = ['image/png', 'image/jpeg', 'image/webp'];

export { UUID_RE, keyHeaders };
export const declaredTooLarge = (header) => sharedDeclaredTooLarge(header, MAX_UPLOAD_BYTES);

/** CORS for staff web (bearer-token auth, never cookies, so any origin may call). */
export const CORS_HEADERS = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'POST, GET, OPTIONS',
  'access-control-allow-headers': 'authorization, apikey, content-type, x-client-info',
  'access-control-max-age': '600',
};

/**
 * The request's action and parameters from its URL and method:
 *   POST ?action=upload&item_id=<uuid>&purpose=<purpose>
 *   POST ?action=sync
 *   GET  ?action=preview&asset_id=<uuid>
 * Returns {ok: true, value} or {ok: false, error} with a coarse code.
 */
export function parseRequest(method, url) {
  let params;
  try {
    params = new URL(url).searchParams;
  } catch {
    return { ok: false, error: 'invalid_url' };
  }
  const action = params.get('action');
  const keys = [...params.keys()];
  const only = (allowed) => keys.every((k) => allowed.includes(k));
  if (action === 'upload') {
    if (method !== 'POST') return { ok: false, error: 'method' };
    if (!only(['action', 'item_id', 'purpose'])) return { ok: false, error: 'unknown_parameter' };
    const itemId = params.get('item_id') ?? '';
    const purpose = params.get('purpose') ?? '';
    if (!UUID_RE.test(itemId)) return { ok: false, error: 'invalid_item_id' };
    if (!PURPOSE_RE.test(purpose)) return { ok: false, error: 'invalid_purpose' };
    return { ok: true, value: { action, itemId, purpose } };
  }
  if (action === 'sync') {
    if (method !== 'POST') return { ok: false, error: 'method' };
    if (!only(['action'])) return { ok: false, error: 'unknown_parameter' };
    return { ok: true, value: { action } };
  }
  if (action === 'preview') {
    if (method !== 'GET') return { ok: false, error: 'method' };
    if (!only(['action', 'asset_id'])) return { ok: false, error: 'unknown_parameter' };
    const assetId = params.get('asset_id') ?? '';
    if (!UUID_RE.test(assetId)) return { ok: false, error: 'invalid_asset_id' };
    return { ok: true, value: { action, assetId } };
  }
  return { ok: false, error: 'invalid_action' };
}

/** The caller's bearer token header value, or null (the function never reads the token). */
export function bearerFrom(header) {
  return typeof header === 'string' && /^Bearer [A-Za-z0-9._~+/=-]{20,8192}$/.test(header) ? header : null;
}

const u16be = (b, i) => (b[i] << 8) | b[i + 1];
const u32be = (b, i) => ((b[i] << 24) >>> 0) + (b[i + 1] << 16) + (b[i + 2] << 8) + b[i + 3];
const u16le = (b, i) => b[i] | (b[i + 1] << 8);
const u24le = (b, i) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16);
const ascii = (b, i, n) => String.fromCharCode(...b.subarray(i, i + n));

function png(b) {
  if (b.length < 33 || ascii(b, 12, 4) !== 'IHDR' || u32be(b, 8) !== 13) return { error: 'invalid_image' };
  const width = u32be(b, 16);
  const height = u32be(b, 20);
  return width > 0 && height > 0 ? { type: 'image/png', width, height } : { error: 'invalid_image' };
}

// Start-of-frame markers carry the dimensions; DHT (C4), JPG (C8) and DAC (CC) do not.
const SOF = new Set([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf]);

function jpeg(b) {
  let i = 2;
  while (i + 3 < b.length) {
    if (b[i] !== 0xff) return { error: 'invalid_image' };
    while (b[i + 1] === 0xff && i + 2 < b.length) i++;
    const marker = b[i + 1];
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd8)) {
      i += 2;
      continue;
    }
    if (marker === 0xd9 || marker === 0xda) return { error: 'invalid_image' };
    const length = u16be(b, i + 2);
    if (length < 2) return { error: 'invalid_image' };
    if (SOF.has(marker)) {
      if (i + 8 >= b.length) return { error: 'invalid_image' };
      const height = u16be(b, i + 5);
      const width = u16be(b, i + 7);
      return width > 0 && height > 0 ? { type: 'image/jpeg', width, height } : { error: 'invalid_image' };
    }
    i += 2 + length;
  }
  return { error: 'invalid_image' };
}

function webp(b) {
  if (b.length < 30) return { error: 'invalid_image' };
  const chunk = ascii(b, 12, 4);
  if (chunk === 'VP8 ') {
    if (b[23] !== 0x9d || b[24] !== 0x01 || b[25] !== 0x2a) return { error: 'invalid_image' };
    const width = u16le(b, 26) & 0x3fff;
    const height = u16le(b, 28) & 0x3fff;
    return width > 0 && height > 0 ? { type: 'image/webp', width, height } : { error: 'invalid_image' };
  }
  if (chunk === 'VP8L') {
    if (b[20] !== 0x2f) return { error: 'invalid_image' };
    const bits = (b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24)) >>> 0;
    return { type: 'image/webp', width: (bits & 0x3fff) + 1, height: ((bits >>> 14) & 0x3fff) + 1 };
  }
  if (chunk === 'VP8X') {
    return { type: 'image/webp', width: u24le(b, 24) + 1, height: u24le(b, 27) + 1 };
  }
  return { error: 'invalid_image' };
}

/**
 * The image type and dimensions measured from the bytes: {type, width, height}, or {error}:
 * unsupported_type (not PNG, JPEG or WebP, whatever its name or declared type) or invalid_image
 * (the right signature but a header that cannot be read).
 */
export function sniffImage(bytes) {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes ?? []);
  if (b.length >= 8 && b[0] === 0x89 && ascii(b, 1, 3) === 'PNG' && b[4] === 0x0d && b[5] === 0x0a
      && b[6] === 0x1a && b[7] === 0x0a) return png(b);
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return jpeg(b);
  if (b.length >= 12 && ascii(b, 0, 4) === 'RIFF' && ascii(b, 8, 4) === 'WEBP') return webp(b);
  return { error: 'unsupported_type' };
}

/**
 * Whether the declared Content-Type contradicts the measured type. No declaration (or a generic
 * application/octet-stream) claims nothing; `image/jpg` is read as `image/jpeg`.
 */
export function declaredTypeMismatch(declared, measured) {
  const value = String(declared ?? '').split(';')[0].trim().toLowerCase();
  if (value === '' || value === 'application/octet-stream') return false;
  return (value === 'image/jpg' ? 'image/jpeg' : value) !== measured;
}

/** Lower-case hex SHA-256 of the bytes (Web Crypto: Deno and Node alike). */
export async function sha256Hex(bytes) {
  const digest = await globalThis.crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].map((x) => x.toString(16).padStart(2, '0')).join('');
}

/** A 1.4 command envelope for api.content_command (uploads are creates: expected null). */
export function commandEnvelope(command, payload, requestId) {
  return { version: 1, command, request_id: requestId, expected_revision: null, payload };
}

/**
 * The HTTP status and body for a refused command answer {code, field_errors}: unauthenticated 401,
 * forbidden 403, validation_failed 422 (413 when the only problem is the size), conflict 409,
 * anything else 503. Only codes and field codes leave the function.
 */
export function refusal(answer) {
  const code = typeof answer?.code === 'string' ? answer.code : 'unavailable';
  const fieldErrors = answer?.field_errors && typeof answer.field_errors === 'object' ? answer.field_errors : {};
  const fields = Object.fromEntries(Object.entries(fieldErrors)
    .filter(([k, v]) => /^[a-z][a-z0-9_]{0,62}$/.test(k) && typeof v === 'string' && /^[a-z][a-z0-9_]{0,62}$/.test(v)));
  if (code === 'unauthenticated') return { status: 401, body: { outcome: 'unauthenticated' } };
  if (code === 'forbidden') return { status: 403, body: { outcome: 'forbidden' } };
  if (code === 'validation_failed') {
    const sizeOnly = Object.keys(fields).length === 1 && fields.byte_size === 'too_large';
    return { status: sizeOnly ? 413 : 422, body: { outcome: 'refused', code, field_errors: fields } };
  }
  if (code === 'conflict') return { status: 409, body: { outcome: 'refused', code, field_errors: fields } };
  return { status: 503, body: { outcome: 'unavailable' } };
}

/** A sync plan from the database, keeping only well-formed entries (never acts on anything else). */
export function planFrom(data) {
  const place = Array.isArray(data?.place) ? data.place.filter((p) => p && typeof p === 'object'
    && PUBLIC_PATH_RE.test(p.public_path ?? '') && DRAFT_PATH_RE.test(p.draft_path ?? '')
    && IMAGE_TYPES.includes(p.media_type)) : [];
  // Anything in the public bucket outside the desired set goes, whatever its name, as long as it is
  // a plain object key (no traversal).
  const remove = Array.isArray(data?.remove)
    ? data.remove.filter((p) => typeof p === 'string' && OBJECT_KEY_RE.test(p) && !p.includes('..')) : [];
  const count = (v) => (Number.isSafeInteger(v) && v >= 0 ? v : 0);
  return { place, remove, waiting: count(data?.waiting), removals_pending: count(data?.removals_pending) };
}
