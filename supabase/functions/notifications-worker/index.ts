// notifications-worker: the Cron-triggered notification worker (story 3.4; AD-8, AD-17, AD-19).
//
// The scheduler tick (app.notifications_scheduler_tick, run by pg_cron) posts here with a
// low-value TRIGGER token read from Supabase Vault. The trigger only starts one run: it is
// compared in constant time with this function's secret NOTIFICATIONS_WORKER_TRIGGER, and a
// missing or wrong trigger is 401 with nothing done. The worker's system credential (purpose
// notifications_worker) is this function's own secret NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL,
// set by the owner; it never enters the database, pg_net or Cron. All lease, fencing, recheck,
// retry and expiry rules live in the database (notifications.claim / attempt / release); a run
// is idempotent, so an extra trigger is harmless. One run at a time per instance (409 busy);
// concurrent instances are kept apart by the database's leases.
//
// Environment (server-side only; never returned or logged):
//   SUPABASE_URL, SUPABASE_ANON_KEY            provided by the platform
//   NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL     sysc_<env>_... (owner-set Edge secret)
//   NOTIFICATIONS_WORKER_TRIGGER               nwt_<64 hex> (the Vault trigger; owner-set Edge secret)
//
// POST {action?: "run", limit?: 1..100} with header x-worker-trigger
//   => 200 {claimed, reclaimed, expired, outcomes: {<outcome>: n}, uncertain, deferred}
//      401 unauthenticated (no or wrong trigger), 403 refused (the route refused the credential),
//      409 busy, 400 invalid body, 503 not configured or unavailable.
//
// Story 3.6: after the inbox stage, the PUSH stage sends member-push jobs through FCM HTTP v1
// (fcm.mjs), only when the owner's Firebase service account is set as the Edge secret
// NOTIFICATIONS_FCM_SERVICE_ACCOUNT (the console JSON, or its base64) and the operator switch
// push_enabled is on in the database. The database rechecks each push job right before the
// provider call and records the provider's per-device answers (acceptance, never delivery).
//   NOTIFICATIONS_FCM_SERVICE_ACCOUNT          owner-set Edge secret (optional; absent = push off)
//   NOTIFICATIONS_FCM_TEST_ENDPOINT            LOCAL ONLY: a fake FCM origin for the E2E; ignored
//                                              unless SUPABASE_URL is plain http (never hosted)
// The 200 answer gains `push`: {claimed, reclaimed, expired, enabled, outcomes, sent, uncertain,
// deferred, stopped?}, {state: "not_configured", reclaimed, expired} (no FCM credential: push
// jobs only expire) or {state: "unavailable"}.
//
// Logs carry counts and outcome codes only: never a body, credential, trigger, job or member id,
// device token, service-account field or notification text.

import {
  MAX_BODY_BYTES,
  configFrom,
  declaredTooLarge,
  keyHeaders,
  parseBody,
  runOnce,
  expirePush,
  runPush,
  systemEnvelope,
  triggerMatches,
} from './logic.mjs';
import { createFcmSender, fcmEndpoints, parseServiceAccount } from './fcm.mjs';

const SUPABASE_URL = (Deno.env.get('SUPABASE_URL') ?? '').replace(/\/+$/, '');
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const CONFIG = configFrom({
  credential: Deno.env.get('NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL') ?? '',
  trigger: Deno.env.get('NOTIFICATIONS_WORKER_TRIGGER') ?? '',
});
const CALL_TIMEOUT_MS = 10_000;
const FCM_ACCOUNT = parseServiceAccount(Deno.env.get('NOTIFICATIONS_FCM_SERVICE_ACCOUNT') ?? '');
const FCM_ENDPOINTS = FCM_ACCOUNT
  ? fcmEndpoints({ projectId: FCM_ACCOUNT.projectId, supabaseUrl: SUPABASE_URL,
    testEndpoint: Deno.env.get('NOTIFICATIONS_FCM_TEST_ENDPOINT') ?? '' })
  : null;
// One sender per instance, so the OAuth access token is reused across runs until it expires.
const FCM_SENDER = FCM_ACCOUNT && FCM_ENDPOINTS
  ? createFcmSender({ account: FCM_ACCOUNT, endpoints: FCM_ENDPOINTS, fetch: (url: string, init: RequestInit) => timedOrThrow(url, init) })
  : null;
let running = false;

type Json = Record<string, unknown>;

function reply(status: number, body: Json): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
  });
}

function note(fields: Json) {
  console.log(JSON.stringify({ fn: 'notifications-worker', ...fields }));
}

class SystemRouteError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}

async function timed(url: string, init: RequestInit): Promise<Response | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), CALL_TIMEOUT_MS);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

// The provider transport: like timed(), but a failure rejects (the adapter maps it).
async function timedOrThrow(url: string, init: RequestInit): Promise<Response> {
  const res = await timed(url, init);
  if (!res) throw new Error('unreachable');
  return res;
}

// One allowlisted system command with the worker's credential; refusals throw a coarse code.
function systemWith(credential: string) {
  return async (command: string, payload: Json): Promise<Json> => {
    const res = await timed(`${SUPABASE_URL}/rest/v1/rpc/system_command`, {
      method: 'POST',
      headers: {
        ...keyHeaders(ANON_KEY),
        'content-type': 'application/json',
        'content-profile': 'api',
        'x-system-credential': credential,
      },
      body: JSON.stringify(systemEnvelope(command, payload, crypto.randomUUID())),
    });
    if (!res || !res.ok) {
      if (res) await res.body?.cancel();
      throw new SystemRouteError('unavailable');
    }
    const json = await res.json().catch(() => null) as Json | null;
    if (!json || typeof json !== 'object') throw new SystemRouteError('unavailable');
    if (typeof json.code === 'string') {
      throw new SystemRouteError(['unauthenticated', 'forbidden'].includes(json.code) ? 'refused' : 'unavailable');
    }
    if (typeof json.data !== 'object' || json.data === null) throw new SystemRouteError('unavailable');
    return json.data as Json;
  };
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return reply(405, { outcome: 'invalid' });
  if (!SUPABASE_URL || !ANON_KEY || !CONFIG) {
    note({ outcome: 'not_configured' });
    return reply(503, { outcome: 'unavailable' });
  }
  if (!triggerMatches(req.headers.get('x-worker-trigger'), CONFIG.trigger)) {
    note({ outcome: 'unauthenticated' });
    return reply(401, { outcome: 'unauthenticated' });
  }
  if (declaredTooLarge(req.headers.get('content-length'))) return reply(413, { outcome: 'invalid' });
  let parsed;
  try {
    const raw = await req.text();
    parsed = raw.length > MAX_BODY_BYTES
      ? { ok: false, error: 'too_large' }
      : parseBody(raw.trim() === '' ? null : JSON.parse(raw));
  } catch {
    parsed = { ok: false, error: 'invalid_body' };
  }
  if (!parsed.ok) {
    note({ outcome: parsed.error });
    return reply(400, { outcome: 'invalid', reason: parsed.error });
  }
  if (running) {
    note({ outcome: 'busy' });
    return reply(409, { outcome: 'busy' });
  }
  running = true;
  try {
    const system = systemWith(CONFIG.credential);
    const limit = (parsed.value as Json).limit as number | undefined;
    const started = Date.now();
    const counts = await runOnce({ system, limit });
    let push: Json;
    try {
      // Without the FCM credential pending push jobs still expire (nothing is leased or sent).
      push = FCM_SENDER
        ? await runPush({ system, sender: FCM_SENDER, limit, deadlineMs: started + 50_000 })
        : await expirePush({ system });
    } catch {
      push = { state: 'unavailable' };
    }
    note({ outcome: 'ran', ...counts, push });
    return reply(200, { ...counts, push });
  } catch (e) {
    const code = e instanceof SystemRouteError ? e.code : 'unavailable';
    note({ outcome: code });
    return reply(code === 'refused' ? 403 : 503, { outcome: code });
  } finally {
    running = false;
  }
});
