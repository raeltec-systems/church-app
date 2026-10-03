// Dependency-free helpers for the story 1.2 Auth provider harness.
// Talks to native GoTrue (/auth/v1) and PostgREST (/rest/v1) endpoints directly.
// Nothing here may write a usable credential (JWT, refresh token, link token,
// OTP or password) to evidence: every evidence record passes through scrub().

import { createHash } from 'node:crypto';

const SECRET_KEYS = new Set([
  'access_token',
  'refresh_token',
  'provider_token',
  'provider_refresh_token',
  'token',
  'token_hash',
  'otp',
  'auth_code',
  'password',
  'new_password',
  'nonce',
  'apikey',
  'authorization',
  'confirmation_token',
  'recovery_token',
  'email_change_token_new',
  'email_change_token_current',
  'phone_change_token',
  'reauthentication_token',
  // story 1.3: member-held grant secrets, their digests and the operator token
  'grant',
  'grant_secret',
  'grant_digest',
  'operator',
  'operator_token',
  'x-harness-operator',
  // MFA enrolment responses (TOTP secret / QR / otpauth URI)
  'secret',
  'qr_code',
  'uri',
]);

const JWT_RE = /eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g;
const PUBLISHABLE_RE = /sb_(publishable|secret)_[A-Za-z0-9_-]+/g;
const QUERY_SECRET_RE =
  /([?&#](?:access_token|refresh_token|token|token_hash|code|provider_token)=)[^&#\s"]+/g;

/** The only Auth host the harness may talk to (isolated auth-test project). */
export const ALLOWED_HOST = 'szfyfezfvxyuvovnnakr.supabase.co';

/**
 * Parse a URL and require it to be exactly the isolated auth-test project over
 * https (no userinfo, no custom port). Returns the normalized origin. Substring
 * checks are not used: `https://<ref>.attacker.example` must fail.
 */
export function assertAllowedOrigin(value, what = 'URL') {
  let u;
  try {
    u = new URL(String(value));
  } catch {
    throw new Error(`${what} is not a valid URL`);
  }
  if (u.protocol !== 'https:' || u.hostname !== ALLOWED_HOST || u.port !== '' ||
      u.username !== '' || u.password !== '') {
    throw new Error(`${what} must be https://${ALLOWED_HOST} (the isolated auth-test project)`);
  }
  return u.origin;
}

/** Short stable digest used to correlate ids across evidence without exposing them. */
export function tag(value) {
  if (value === null || value === undefined || value === '') return null;
  return 'h:' + createHash('sha256').update(String(value)).digest('hex').slice(0, 10);
}

/** Mask an email or phone so evidence shows shape, not the full identifier. */
export function maskIdentifier(value) {
  if (!value) return value;
  const s = String(value);
  const at = s.indexOf('@');
  if (at > 0) {
    const local = s.slice(0, at);
    const plus = local.indexOf('+');
    const visible = plus >= 0 ? local.slice(plus) : local.slice(0, 1) + '…';
    return '…' + visible + s.slice(at);
  }
  return s.length > 4 ? '…' + s.slice(-4) : '…';
}

function scrubString(s) {
  return s
    .replace(/hg_[A-Za-z0-9_-]{20,}/g, '[redacted-grant]')
    .replace(/ho_[A-Za-z0-9_-]{20,}/g, '[redacted-operator]')
    .replace(JWT_RE, '[redacted-jwt]')
    .replace(PUBLISHABLE_RE, '[redacted-key]')
    .replace(QUERY_SECRET_RE, '$1[redacted]');
}

/** Recursively redact secret-bearing keys and any token-shaped strings. */
export function scrub(value) {
  if (typeof value === 'string') return scrubString(value);
  if (Array.isArray(value)) return value.map(scrub);
  if (value && typeof value === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(value)) {
      if (SECRET_KEYS.has(k.toLowerCase())) {
        out[k] = v === null || v === undefined || v === '' ? v : '[redacted]';
      } else {
        out[k] = scrub(v);
      }
    }
    return out;
  }
  return value;
}

function b64urlJson(part) {
  return JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));
}

/**
 * Decode (NOT verify) a JWT and keep only what evidence needs: header alg/kid/typ
 * and the session-trust claims. sub/session_id become digests.
 * Signature trust is proven separately by the server-side probe, which only
 * sees claims PostgREST has already verified.
 */
export function summarizeJwt(jwt) {
  if (typeof jwt !== 'string' || jwt.split('.').length !== 3) return null;
  const [h, p] = jwt.split('.');
  const header = b64urlJson(h);
  const c = b64urlJson(p);
  return {
    header: { alg: header.alg, kid: header.kid ?? null, typ: header.typ },
    claims: {
      iss: c.iss,
      aud: c.aud,
      role: c.role,
      aal: c.aal,
      amr: c.amr ?? null,
      sub: tag(c.sub),
      session_id: tag(c.session_id),
      is_anonymous: c.is_anonymous,
      has_email_claim: Boolean(c.email),
      has_phone_claim: Boolean(c.phone),
      lifetime_s: c.exp && c.iat ? c.exp - c.iat : null,
    },
  };
}

/** Decode a JWT payload (no verification); null when not a JWT. */
export function decodeJwtPayloadNode(jwt) {
  if (typeof jwt !== 'string' || jwt.split('.').length !== 3) return null;
  try {
    return b64urlJson(jwt.split('.')[1]);
  } catch {
    return null;
  }
}

/** Client-side mirror of the AMR half of harness.trusted_password_session(). */
export function amrHasPassword(amr) {
  return Array.isArray(amr) && amr.some((e) => e && e.method === 'password');
}

/**
 * Parse a Supabase Auth email link (/auth/v1/verify with token, type and redirect_to query parameters).
 * Returns the pieces needed to call /verify ourselves without following the redirect.
 */
export function parseVerifyLink(link) {
  const u = new URL(String(link).trim());
  assertAllowedOrigin(u.href, 'verify link');
  if (u.pathname !== '/auth/v1/verify') {
    throw new Error('not a Supabase /auth/v1/verify link');
  }
  const token = u.searchParams.get('token');
  const type = u.searchParams.get('type');
  if (!token || !type) throw new Error('verify link lacks token or type');
  return { origin: u.origin, token, type, redirectTo: u.searchParams.get('redirect_to') };
}

/**
 * Parse the redirect Location returned by GET /verify. Implicit flow puts the
 * session (or an error) in the fragment; PKCE would put ?code= in the query.
 */
export function parseRedirectLocation(location) {
  if (!location) return { kind: 'none' };
  const u = new URL(location);
  const frag = new URLSearchParams(u.hash.replace(/^#/, ''));
  const query = u.searchParams;
  const base = { redirect_origin: u.origin, redirect_path: u.pathname };
  if (frag.get('error') || query.get('error')) {
    const src = frag.get('error') ? frag : query;
    return {
      kind: 'error',
      ...base,
      error: src.get('error'),
      error_code: src.get('error_code'),
      error_description: src.get('error_description'),
    };
  }
  if (frag.get('access_token')) {
    return {
      kind: 'session',
      ...base,
      type: frag.get('type'),
      access_token: frag.get('access_token'),
      refresh_token: frag.get('refresh_token'),
      expires_in: Number(frag.get('expires_in')) || null,
    };
  }
  if (query.get('code')) return { kind: 'pkce_code', ...base };
  return { kind: 'no_session', ...base };
}

export class AuthClient {
  constructor({ url, apikey, fetchImpl = globalThis.fetch }) {
    if (!url || !apikey) throw new Error('SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY are required');
    // Only the origin is kept; any path/query on SUPABASE_URL is ignored.
    this.url = assertAllowedOrigin(url, 'SUPABASE_URL');
    this.apikey = apikey;
    this.fetch = fetchImpl;
  }

  async call(path, { method = 'GET', body, bearer, redirect = 'follow', headers = {} } = {}) {
    const res = await this.fetch(this.url + path, {
      method,
      redirect,
      headers: {
        apikey: this.apikey,
        ...(bearer ? { authorization: `Bearer ${bearer}` } : {}),
        ...(body !== undefined ? { 'content-type': 'application/json' } : {}),
        ...headers,
      },
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
    const text = await res.text();
    let json = null;
    try {
      json = text ? JSON.parse(text) : null;
    } catch {
      json = { non_json_body_length: text.length };
    }
    return { status: res.status, json, location: res.headers.get('location') };
  }

  health() { return this.call('/auth/v1/health'); }
  settings() { return this.call('/auth/v1/settings'); }
  signup(body) { return this.call('/auth/v1/signup', { method: 'POST', body }); }
  passwordGrant(body) {
    return this.call('/auth/v1/token?grant_type=password', { method: 'POST', body });
  }
  refresh(refreshToken) {
    return this.call('/auth/v1/token?grant_type=refresh_token', {
      method: 'POST',
      body: { refresh_token: refreshToken },
    });
  }
  otp(body) { return this.call('/auth/v1/otp', { method: 'POST', body }); }
  recover(body) { return this.call('/auth/v1/recover', { method: 'POST', body }); }
  verifyPost(body) { return this.call('/auth/v1/verify', { method: 'POST', body }); }
  verifyGet(token, type, redirectTo) {
    const q = new URLSearchParams({ token, type });
    if (redirectTo) q.set('redirect_to', redirectTo);
    return this.call(`/auth/v1/verify?${q}`, { redirect: 'manual' });
  }
  getUser(bearer) { return this.call('/auth/v1/user', { bearer }); }
  updateUser(bearer, body) { return this.call('/auth/v1/user', { method: 'PUT', body, bearer }); }
  logout(bearer, scope = 'local') {
    return this.call(`/auth/v1/logout?scope=${scope}`, { method: 'POST', bearer });
  }
  rpc(name, bearer) {
    return this.call(`/rest/v1/rpc/${name}`, { method: 'POST', body: {}, bearer });
  }
  /** Story 1.3: call the harness-only Edge Function. operator = harness operator token. */
  fn(name, body, { bearer, operator } = {}) {
    return this.call(`/functions/v1/${name}`, {
      method: 'POST',
      body,
      bearer,
      headers: operator ? { 'x-harness-operator': operator } : {},
    });
  }
}

const UUID_ANY_RE = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/g;

/** Scrub, then replace every UUID (account, member, grant, op, request ids) by its digest tag. */
export function tagUuids(value) {
  const walk = (v) => {
    if (typeof v === 'string') return v.replace(UUID_ANY_RE, (m) => tag(m));
    if (Array.isArray(v)) return v.map(walk);
    if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, walk(x)]));
    return v;
  };
  return walk(scrub(value));
}

/** Member-held grant secret ('hg_' + 32 random bytes) and operator token ('ho_' + 32 bytes). */
export const GRANT_SECRET_RE = /hg_[A-Za-z0-9_-]{20,}/g;
export const OPERATOR_TOKEN_RE = /ho_[A-Za-z0-9_-]{20,}/g;

export function sha256Hex(text) {
  return createHash('sha256').update(String(text)).digest('hex');
}

/** Reduce a GoTrue user object to non-secret evidence fields. */
export function summarizeUser(u) {
  if (!u || typeof u !== 'object' || !u.id) return u ? scrub(u) : u;
  return {
    id: tag(u.id),
    phone: maskIdentifier(u.phone || ''),
    phone_confirmed: Boolean(u.phone_confirmed_at),
    email: maskIdentifier(u.email || ''),
    email_confirmed: Boolean(u.email_confirmed_at),
    new_email: maskIdentifier(u.new_email || ''),
    identities: (u.identities || []).map((i) => ({ provider: i.provider, id: tag(i.id) })),
    app_metadata_providers: u.app_metadata?.providers ?? null,
    is_anonymous: u.is_anonymous,
  };
}

/** Summarize a session-bearing response (token grant, signup, verify redirect). */
export function summarizeSession(r) {
  if (!r) return null;
  return {
    jwt_summary: summarizeJwt(r.access_token),
    has_refresh_token: Boolean(r.refresh_token),
    expires_in: r.expires_in ?? null,
    user: r.user ? summarizeUser(r.user) : undefined,
  };
}
