// Pure guards for the harness-recovery Edge Function (story 1.3).
// Shared by the Deno function and the Node offline tests: no imports, no I/O.

export const OWN_REF = 'szfyfezfvxyuvovnnakr';
export const OWN_URL = `https://${OWN_REF}.supabase.co`;
export const OWN_ISSUER = `${OWN_URL}/auth/v1`;

/** The function serves only its own project: exact https origin, no path tricks. */
export function isOwnProjectUrl(value) {
  if (typeof value !== 'string' || value === '') return false;
  let u;
  try {
    u = new URL(value);
  } catch {
    return false;
  }
  return u.protocol === 'https:' && u.hostname === `${OWN_REF}.supabase.co` && u.port === '' &&
    u.username === '' && u.password === '' && (u.pathname === '/' || u.pathname === '');
}

/** Refuse any request that names another project or URL. */
export function requestTargetsOtherProject(body) {
  if (!body || typeof body !== 'object') return false;
  for (const k of ['project_ref', 'project', 'ref']) {
    if (k in body && body[k] !== OWN_REF) return true;
  }
  for (const k of ['url', 'supabase_url', 'target_url']) {
    if (k in body && !isOwnProjectUrl(body[k])) return true;
  }
  return false;
}

function b64urlDecode(part) {
  const s = part.replace(/-/g, '+').replace(/_/g, '/');
  const pad = s.length % 4 === 0 ? '' : '='.repeat(4 - (s.length % 4));
  return atob(s + pad);
}

/**
 * Decode (not verify) the bearer JWT's payload. The platform's verify_jwt has
 * already checked the signature; this only reads claims for the project and
 * role checks below.
 */
export function decodeJwtPayload(jwt) {
  if (typeof jwt !== 'string') return null;
  const parts = jwt.split('.');
  if (parts.length !== 3) return null;
  try {
    return JSON.parse(b64urlDecode(parts[1]));
  } catch {
    return null;
  }
}

/**
 * Classify a verified bearer: the project's legacy anon key ('anon'), or a
 * user session JWT issued by this project's Auth ('user'). Anything else,
 * including service_role and tokens of other projects, is null (refused).
 */
export function classifyCaller(claims) {
  if (!claims || typeof claims !== 'object') return null;
  if (claims.role === 'anon' && claims.ref === OWN_REF && claims.iss === 'supabase' && !claims.sub) {
    return 'anon';
  }
  if (claims.role === 'authenticated' && claims.iss === OWN_ISSUER && typeof claims.sub === 'string' &&
      typeof claims.session_id === 'string') {
    return 'user';
  }
  return null;
}

export const MEMBER_ACTIONS = new Set(['request', 'redeem', 'resume']);
export const STAFF_ACTIONS = new Set(['issue', 'relink', 'hold', 'reconcile', 'replay_complete', 'observe']);
export const OPERATOR_ACTIONS = new Set(['provision']);
export const INJECTIONS = new Set(['stop_after_begin', 'lost_response', 'late_apply', 'delay_apply']);

/** Which caller kind each action requires. */
export function requiredCaller(action) {
  if (MEMBER_ACTIONS.has(action) || OPERATOR_ACTIONS.has(action)) return 'anon';
  if (STAFF_ACTIONS.has(action)) return 'user';
  return null;
}

export const TAG_RE = /^[a-z0-9][a-z0-9-]{0,23}$/;
export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const HEX64_RE = /^[0-9a-f]{64}$/;

/** Synthetic owner-approved plus-address for a harness tag (never a free-form address). */
export function syntheticEmail(tag) {
  if (!TAG_RE.test(String(tag))) throw new Error('validation_failed');
  return `israelmuyoba+bicauth-${tag}@gmail.com`;
}

export async function sha256Hex(text) {
  const data = new TextEncoder().encode(String(text));
  const buf = await crypto.subtle.digest('SHA-256', data);
  return Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, '0')).join('');
}

/**
 * Turn the Auth Admin response into the outcome the DB completion fence
 * evaluates. The DB, not this function, decides success, and it verifies
 * session revocation itself (no pre-dispatch session may remain live).
 */
export function buildOutcome({ adminStatus, adminThrew, transport }) {
  const applied = !adminThrew && adminStatus === 200;
  return {
    admin_status: adminThrew ? null : adminStatus,
    applied,
    transport: adminThrew ? 'lost' : transport === 'lost' ? 'lost' : 'ok',
  };
}

/** Keep only an Auth error's code: never its body, which may echo input. */
export function authErrorCode(json) {
  if (!json || typeof json !== 'object') return null;
  return typeof json.error_code === 'string' ? json.error_code : typeof json.code === 'string' ? json.code : null;
}
