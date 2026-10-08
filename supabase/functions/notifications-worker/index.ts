// notifications-worker: the Cron-triggered notification worker (story 3.4; AD-8, AD-17, AD-19).
//
// The scheduler tick (app.notifications_scheduler_tick, run by pg_cron) posts here with the
// worker's system credential, read from Supabase Vault at that moment. The function holds NO
// credential of its own and no service-role key: it forwards the caller's `x-system-credential`
// (purpose notifications_worker) to the 1.9 system route, so only a caller the database
// authenticates gets anything done. All lease, fencing, recheck, retry and expiry rules live in
// the database (notifications.claim / notifications.attempt); this function is transport.
//
// Environment (platform-provided; never returned or logged): SUPABASE_URL, SUPABASE_ANON_KEY.
//
// POST {action?: "run", limit?: 1..100} with header x-system-credential
//   => 200 {claimed, reclaimed, expired, outcomes: {<outcome>: n}, uncertain, deferred}
//      401 unauthenticated (no or malformed credential), 403 refused (the route refused it),
//      400 invalid body, 503 unavailable.
//
// Logs carry counts and outcome codes only: never a body, credential, token, job or member id.

import {
  MAX_BODY_BYTES,
  credentialFrom,
  declaredTooLarge,
  keyHeaders,
  parseBody,
  runOnce,
  systemEnvelope,
} from './logic.mjs';

const SUPABASE_URL = (Deno.env.get('SUPABASE_URL') ?? '').replace(/\/+$/, '');
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const CALL_TIMEOUT_MS = 10_000;

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

// One allowlisted system command with the caller's credential; refusals throw a coarse code.
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
  if (!SUPABASE_URL || !ANON_KEY) {
    note({ outcome: 'not_configured' });
    return reply(503, { outcome: 'unavailable' });
  }
  const credential = credentialFrom(req.headers.get('x-system-credential'));
  if (!credential) {
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
  try {
    const counts = await runOnce({ system: systemWith(credential), limit: (parsed.value as Json).limit as number | undefined });
    note({ outcome: 'ran', ...counts });
    return reply(200, counts);
  } catch (e) {
    const code = e instanceof SystemRouteError ? e.code : 'unavailable';
    note({ outcome: code });
    return reply(code === 'refused' ? 403 : 503, { outcome: code });
  }
});
