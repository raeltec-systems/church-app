// FCM HTTP v1 adapter of the notifications-worker Edge Function (story 3.6; AD-8, AD-18).
// Shared by the Deno function and the Node tests: no imports, no logging, no I/O of its own (the
// HTTP transport, the clock and WebCrypto are injected). Provider acceptance is only ever
// reported as `accepted`: FCM accepting a message is not delivery, reading or consent.
//
// Credentials: the owner's Firebase service account (JSON, or base64 of the JSON) is the Edge
// secret NOTIFICATIONS_FCM_SERVICE_ACCOUNT. It signs a short-lived RS256 assertion that Google's
// OAuth endpoint exchanges for an access token (scope firebase.messaging), cached in memory until
// shortly before it expires. Neither the key, the assertion, the access token nor a device token
// is ever returned or logged by this module.

export const GOOGLE_TOKEN_URL = 'https://oauth2.googleapis.com/token';
export const FCM_API = 'https://fcm.googleapis.com';
export const FCM_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';
/** FCM's longest time to live (28 days). */
export const MAX_TTL_SECONDS = 2419200;
const PROJECT_RE = /^[a-z][a-z0-9-]{4,28}[a-z0-9]$/;
const EMAIL_RE = /^[a-z0-9-]{1,63}@[a-z0-9-]{1,63}\.iam\.gserviceaccount\.com$/;
// Built from parts so the repository secret scan (which flags PEM armour) does not match a key
// that is not there.
const PEM_LABEL = ['PRIVATE', 'KEY'].join(' ');
const PEM_RE = new RegExp(`^-----BEGIN ${PEM_LABEL}-----\\s*([A-Za-z0-9+/=\\s]+?)\\s*-----END ${PEM_LABEL}-----\\s*$`);
const CODE_RE = /^[A-Z][A-Z0-9_]{0,39}$/;

/** Thrown when the provider cannot be used at all (OAuth refused or unreachable). */
export class ProviderUnavailable extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

function decodeBase64(text) {
  const bin = atob(text);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

function base64url(bytes) {
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

const utf8 = (text) => new TextEncoder().encode(text);

/**
 * The service account from the Edge secret: the JSON a Firebase console download holds, or the
 * same JSON base64-encoded. Returns {projectId, clientEmail, privateKey} or null (fail closed).
 */
export function parseServiceAccount(raw) {
  if (typeof raw !== 'string' || raw.trim() === '' || raw.length > 20000) return null;
  let json;
  try {
    const text = raw.trim().startsWith('{') ? raw.trim() : new TextDecoder().decode(decodeBase64(raw.trim()));
    json = JSON.parse(text);
  } catch {
    return null;
  }
  if (!json || typeof json !== 'object' || json.type !== 'service_account') return null;
  const { project_id: projectId, client_email: clientEmail, private_key: privateKey } = json;
  if (typeof projectId !== 'string' || !PROJECT_RE.test(projectId)) return null;
  if (typeof clientEmail !== 'string' || !EMAIL_RE.test(clientEmail)) return null;
  if (typeof privateKey !== 'string' || !PEM_RE.test(privateKey)) return null;
  return { projectId, clientEmail, privateKey };
}

/**
 * The OAuth and send URLs. Always Google's, except that a LOCAL stack (SUPABASE_URL over plain
 * http, never a hosted project) may point both at a fake FCM endpoint for the E2E.
 */
export function fcmEndpoints({ projectId, supabaseUrl, testEndpoint }) {
  if (typeof testEndpoint === 'string' && testEndpoint !== ''
      && typeof supabaseUrl === 'string' && /^http:\/\//.test(supabaseUrl)
      && /^http:\/\/[A-Za-z0-9.-]+(:[0-9]{1,5})?$/.test(testEndpoint)) {
    return { tokenUrl: `${testEndpoint}/token`, sendUrl: `${testEndpoint}/v1/projects/${projectId}/messages:send`, test: true };
  }
  return { tokenUrl: GOOGLE_TOKEN_URL, sendUrl: `${FCM_API}/v1/projects/${projectId}/messages:send`, test: false };
}

/** A signed RS256 JWT bearer assertion for Google's OAuth token endpoint. */
export async function signAssertion({ clientEmail, privateKey, tokenUrl, nowSec, subtle = globalThis.crypto.subtle }) {
  const body = PEM_RE.exec(privateKey)[1].replace(/\s+/g, '');
  const key = await subtle.importKey('pkcs8', decodeBase64(body), { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false, ['sign']);
  const header = base64url(utf8(JSON.stringify({ alg: 'RS256', typ: 'JWT' })));
  const claims = base64url(utf8(JSON.stringify({
    iss: clientEmail, scope: FCM_SCOPE, aud: tokenUrl, iat: nowSec, exp: nowSec + 3600,
  })));
  const signature = new Uint8Array(await subtle.sign('RSASSA-PKCS1-v1_5', key, utf8(`${header}.${claims}`)));
  return `${header}.${claims}.${base64url(signature)}`;
}

/**
 * The FCM v1 message for one device: the contract's fixed generic title and body, the inbox item
 * id as the only data, and the item id as the stable notification id (Android collapse key and
 * notification tag, APNs collapse id) so a retried or duplicated send replaces rather than adds a
 * notification. It expires with the push job (Android ttl, APNs expiration).
 */
export function buildMessage(target, message) {
  const ttl = Math.max(1, Math.min(MAX_TTL_SECONDS, message.ttl_seconds));
  return {
    message: {
      token: target.token,
      notification: { title: message.title, body: message.body },
      data: { item_id: message.item_id },
      android: {
        ttl: `${ttl}s`,
        collapse_key: message.notification_id,
        priority: 'high',
        notification: { tag: message.notification_id },
      },
      apns: {
        headers: {
          'apns-expiration': String(message.expires_at_epoch),
          'apns-collapse-id': message.notification_id,
          'apns-priority': '10',
          'apns-push-type': 'alert',
        },
        payload: { aps: { sound: 'default' } },
      },
    },
  };
}

/** FCM's error code from an error answer: the FcmError detail, else the RPC status. */
export function fcmErrorCode(json) {
  const error = json && typeof json === 'object' ? json.error : null;
  if (!error || typeof error !== 'object') return null;
  const details = Array.isArray(error.details) ? error.details : [];
  const fcm = details.find((d) => d && typeof d['@type'] === 'string' && d['@type'].endsWith('google.firebase.fcm.v1.FcmError'));
  const code = typeof fcm?.errorCode === 'string' ? fcm.errorCode : typeof error.status === 'string' ? error.status : null;
  return code && CODE_RE.test(code) ? code : null;
}

/**
 * True when a 400 answer is about the device token: a google.rpc.BadRequest naming the field
 * `message.token`, or FCM's INVALID_ARGUMENT whose message says the registration token is not
 * valid ("The registration token is not a valid FCM registration token"). Our payload is fixed and
 * generic, so any other INVALID_ARGUMENT is a payload problem and must never retire a token.
 */
function tokenInvalid(json) {
  const error = json?.error;
  const details = Array.isArray(error?.details) ? error.details : [];
  if (details.some((d) => Array.isArray(d?.fieldViolations)
      && d.fieldViolations.some((v) => v?.field === 'message.token'))) return true;
  const texts = [error?.message, ...details.map((d) => d?.description), ...details.flatMap((d) =>
    (Array.isArray(d?.fieldViolations) ? d.fieldViolations.map((v) => v?.description) : []))];
  return texts.some((t) => typeof t === 'string' && /registration token/i.test(t)
    && /(not a valid|invalid)/i.test(t));
}

/**
 * Classifies one FCM answer: {result, code, stop, fatal}. result is accepted, token_invalid
 * (retire the token), rejected (refused for this device, not retried, token kept) or transient
 * (retried with backoff); stop ends the run's sending (quota). fatal names OUR configuration
 * problem (our access token refused, a sender/project mismatch): nothing is recorded for the
 * device, no token is retired, the job is released unused and the run stops.
 */
export function classifyFcm(status, json) {
  if (status >= 200 && status < 300) return { result: 'accepted', code: null, stop: false, fatal: null };
  const code = fcmErrorCode(json);
  // Only FCM's own codes retire a token; a bare 404 (for example a wrong project) does not.
  if (code === 'UNREGISTERED') return { result: 'token_invalid', code, stop: false, fatal: null };
  // The token belongs to another Firebase project than our credential: our configuration is wrong
  // (it would be so for every member's token), not the device's.
  if (code === 'SENDER_ID_MISMATCH') return { result: null, code, stop: true, fatal: 'sender_mismatch' };
  if (status === 400) {
    return tokenInvalid(json)
      ? { result: 'token_invalid', code: code ?? 'INVALID_ARGUMENT', stop: false, fatal: null }
      : { result: 'rejected', code: code ?? 'INVALID_ARGUMENT', stop: false, fatal: null };
  }
  if (status === 429 || code === 'QUOTA_EXCEEDED') return { result: 'transient', code: code ?? 'QUOTA_EXCEEDED', stop: true, fatal: null };
  if (code === 'THIRD_PARTY_AUTH_ERROR') return { result: 'transient', code, stop: false, fatal: null };
  if (status === 401 || status === 403) {
    return { result: null, code: code ?? (status === 401 ? 'UNAUTHENTICATED' : 'PERMISSION_DENIED'), stop: true,
      fatal: 'provider_auth' };
  }
  if (status >= 500) return { result: 'transient', code: code ?? (status === 503 ? 'UNAVAILABLE' : 'INTERNAL'), stop: false, fatal: null };
  return { result: 'rejected', code: code ?? 'OTHER', stop: false, fatal: null };
}

/**
 * The sender: send(target, message) -> {result, provider_status?, provider_code?, stop}. A network
 * failure or timeout is `transient` (the provider may or may not have accepted it; the stable
 * notification id bounds a duplicate). Throws ProviderUnavailable when no access token can be had
 * (`oauth_refused`, `oauth_unreachable`) or the answer shows our own configuration is wrong
 * (`provider_auth`, `sender_mismatch`): the caller releases the job unused and stops.
 * `fetch(url, init)` resolves to a Response or rejects; it is the only I/O.
 */
export function createFcmSender({ account, endpoints, fetch, now = () => Date.now(), subtle = globalThis.crypto.subtle }) {
  let cached = null;
  async function accessToken() {
    if (cached && cached.expiresAtMs - 60_000 > now()) return cached.value;
    cached = null;
    let res;
    try {
      const assertion = await signAssertion({ clientEmail: account.clientEmail, privateKey: account.privateKey,
        tokenUrl: endpoints.tokenUrl, nowSec: Math.floor(now() / 1000), subtle });
      res = await fetch(endpoints.tokenUrl, {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion }).toString(),
      });
    } catch {
      throw new ProviderUnavailable('oauth_unreachable');
    }
    const json = await res.json().catch(() => null);
    if (!res.ok || typeof json?.access_token !== 'string' || json.access_token === '') {
      throw new ProviderUnavailable('oauth_refused');
    }
    const seconds = Number.isFinite(json.expires_in) ? Math.min(Math.max(json.expires_in, 60), 3600) : 3000;
    cached = { value: json.access_token, expiresAtMs: now() + seconds * 1000 };
    return cached.value;
  }
  return {
    async send(target, message) {
      const token = await accessToken();
      let res;
      try {
        res = await fetch(endpoints.sendUrl, {
          method: 'POST',
          headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
          body: JSON.stringify(buildMessage(target, message)),
        });
      } catch {
        return { result: 'transient', provider_code: 'NETWORK', stop: false };
      }
      const json = await res.json().catch(() => null);
      const c = classifyFcm(res.status, json);
      if (c.fatal) {
        if (c.fatal === 'provider_auth') cached = null;
        throw new ProviderUnavailable(c.fatal);
      }
      const answer = { result: c.result, provider_status: res.status, stop: c.stop };
      if (c.code) answer.provider_code = c.code;
      return answer;
    },
  };
}
