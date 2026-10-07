// identity-assisted-recovery: staff-assisted password recovery (story 2.9; AD-19, AD-20).
//
// The ONLY holder of Auth Admin power for assisted recovery. It serves a member device that has
// no session (verify_jwt = false: the single-use grant authenticates the member) and talks to
// the database only through the 1.9 system route with its own purpose-bound credential.
//
// Environment (server-side only, never returned or logged):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY  provided by the platform
//   IDENTITY_RECOVERY_SYSTEM_CREDENTIAL  sysc_<env>_... of a principal with the purpose
//                                        identity_assisted_recovery (Edge Function secret)
//
// Actions (POST JSON):
//   request {phone_username, grant_digest}  -> {outcome: received, request_code, expires_at}
//                                              | rate_limited | refused | unavailable
//   status  {grant_digest}                  -> {outcome: waiting | ready | closed, expires_at?}
//   redeem  {phone_username, grant_secret, password}
//        -> begin (consume grant) -> dispatch (fence, hold) -> Auth Admin password update
//           -> complete (fenced)  => {outcome: succeeded | rejected | password_rejected |
//                                     uncertain | unavailable}
//
// The password is sent to Auth Admin only; the grant secret is hashed here and only its digest
// reaches the database. Responses carry outcome codes only. Logs carry the action and outcome
// code only: never a body, phone, secret, digest, password, token or account id.

import {
  MAX_BODY_BYTES,
  classifyAuthResult,
  declaredTooLarge,
  digestHex,
  keyHeaders,
  parseBody,
  redeemOutcome,
  requestOutcome,
  systemEnvelope,
} from './logic.mjs';

const SUPABASE_URL = (Deno.env.get('SUPABASE_URL') ?? '').replace(/\/+$/, '');
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const SYSTEM_CREDENTIAL = Deno.env.get('IDENTITY_RECOVERY_SYSTEM_CREDENTIAL') ?? '';
const CALL_TIMEOUT_MS = 10_000;

type Json = Record<string, unknown>;

function reply(status: number, body: Json): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
  });
}

function note(action: string, outcome: string) {
  // Coarse codes only (AD-13, AD-20: no password or usable grant in logs).
  console.log(JSON.stringify({ fn: 'identity-assisted-recovery', action, outcome }));
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

// The body as text, or null when it exceeds MAX_BODY_BYTES (reading stops there) or fails.
async function readCapped(req: Request): Promise<string | null> {
  if (!req.body) return '';
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > MAX_BODY_BYTES) {
        await reader.cancel();
        return null;
      }
      chunks.push(value);
    }
  } catch {
    return null;
  }
  const bytes = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) {
    bytes.set(c, at);
    at += c.byteLength;
  }
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch {
    return null;
  }
}

class SystemRouteError extends Error {}

// One allowlisted system command; refusals come back as data, errors throw.
async function system(command: string, payload: Json): Promise<Json> {
  const res = await timed(`${SUPABASE_URL}/rest/v1/rpc/system_command`, {
    method: 'POST',
    headers: {
      ...keyHeaders(ANON_KEY),
      'content-type': 'application/json',
      'content-profile': 'api',
      'x-system-credential': SYSTEM_CREDENTIAL,
    },
    body: JSON.stringify(systemEnvelope(command, payload, crypto.randomUUID())),
  });
  if (!res || !res.ok) throw new SystemRouteError(res ? `http_${res.status}` : 'no_response');
  const json = await res.json().catch(() => null) as Json | null;
  if (!json || typeof json !== 'object' || 'code' in json || typeof json.data !== 'object') {
    throw new SystemRouteError('refused');
  }
  return json.data as Json;
}

// The Auth Admin password update. Returns what the function can tell about it.
async function applyPassword(authUserId: string, password: string): Promise<string> {
  const res = await timed(`${SUPABASE_URL}/auth/v1/admin/users/${encodeURIComponent(authUserId)}`, {
    method: 'PUT',
    headers: { ...keyHeaders(SERVICE_KEY), 'content-type': 'application/json' },
    body: JSON.stringify({ password }),
  });
  if (res) await res.body?.cancel();
  return classifyAuthResult(res?.status ?? null);
}

async function redeem(body: Json): Promise<string> {
  const digest = await digestHex(body.grant_secret as string);
  const begun = await system('identity.assisted_reset_begin',
    { phone_username: body.phone_username, grant_digest: digest });
  if (begun.accepted !== true || typeof begun.operation_id !== 'string') return 'rejected';
  const operationId = begun.operation_id;
  const dispatched = await system('identity.assisted_reset_dispatch', { operation_id: operationId });
  if (dispatched.proceed !== true || typeof dispatched.auth_user_id !== 'string') return 'rejected';
  const authResult = await applyPassword(dispatched.auth_user_id, body.password as string);
  try {
    const done = await system('identity.assisted_reset_complete',
      { operation_id: operationId, auth_result: authResult });
    return redeemOutcome(done.outcome);
  } catch {
    // Not recorded: the operation stays dispatched, becomes `stuck` and the account stays held.
    return 'uncertain';
  }
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return reply(405, { outcome: 'invalid' });
  if (!SUPABASE_URL || !ANON_KEY || !SERVICE_KEY || !SYSTEM_CREDENTIAL) {
    note('any', 'not_configured');
    return reply(503, { outcome: 'unavailable' });
  }
  // Refuse a declared oversize body first, then read at most MAX_BODY_BYTES: an unbounded body
  // is never buffered.
  if (declaredTooLarge(req.headers.get('content-length'))) return reply(413, { outcome: 'invalid' });
  const raw = await readCapped(req);
  if (raw === null || raw.length === 0) return reply(400, { outcome: 'invalid' });
  let parsed;
  try {
    parsed = parseBody(JSON.parse(raw));
  } catch {
    parsed = { ok: false, error: 'invalid_body' };
  }
  if (!parsed.ok) {
    note('parse', parsed.error);
    return reply(400, { outcome: 'invalid', reason: parsed.error });
  }
  const body = parsed.value as Json;
  const action = body.action as string;
  try {
    if (action === 'request') {
      const data = await system('identity.assisted_recovery_request',
        { phone_username: body.phone_username, grant_digest: body.grant_digest });
      const outcome = requestOutcome(data);
      note(action, outcome);
      return reply(200, outcome === 'received'
        ? { outcome, request_code: data.request_code, expires_at: data.expires_at }
        : { outcome });
    }
    if (action === 'status') {
      const data = await system('identity.assisted_recovery_status', { grant_digest: body.grant_digest });
      const outcome = ['waiting', 'ready'].includes(data.state as string) ? data.state as string : 'closed';
      note(action, outcome);
      return reply(200, outcome === 'closed' ? { outcome } : { outcome, expires_at: data.expires_at });
    }
    const outcome = await redeem(body);
    note(action, outcome);
    return reply(200, { outcome });
  } catch (e) {
    note(action, e instanceof SystemRouteError ? 'unavailable' : 'error');
    return reply(503, { outcome: 'unavailable' });
  }
});
