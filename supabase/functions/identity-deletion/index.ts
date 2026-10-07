// identity-deletion: the Auth Admin step of a full member deletion (story 2.11; AD-14, AD-19).
//
// The deletion worker (tools/identity-deletion/worker.mjs) calls this function for one deletion's
// `auth_account` step. The function holds Auth Admin power through the platform-provided
// SUPABASE_SERVICE_ROLE_KEY and NO credential of its own: it forwards the worker's
// `x-system-credential` (purpose identity_deletion) to the 1.9 system route, so only a caller
// the database authenticates gets anything done, and it deletes only the account the database
// returns for that deletion (never an id from the request).
//
// Environment (server-side only, never returned or logged):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY  provided by the platform
//
// POST {action: "auth_delete", deletion_id} with header x-system-credential:
//   identity.deletion_auth_begin (fence)  -> Auth Admin DELETE /admin/users/<id>
//   -> identity.deletion_auth_complete (the database checks the Auth user is absent)
//   => {outcome: done | retry | <wait reason> | not_next | not_found | refused | unavailable}
//
// Logs carry the outcome code only: never a body, credential, token or account id.

import {
  MAX_BODY_BYTES,
  beginOutcome,
  classifyDeleteResult,
  completeOutcome,
  credentialFrom,
  declaredTooLarge,
  keyHeaders,
  parseBody,
  systemEnvelope,
} from './logic.mjs';

const SUPABASE_URL = (Deno.env.get('SUPABASE_URL') ?? '').replace(/\/+$/, '');
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const CALL_TIMEOUT_MS = 10_000;

type Json = Record<string, unknown>;

function reply(status: number, body: Json): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
  });
}

function note(outcome: string) {
  console.log(JSON.stringify({ fn: 'identity-deletion', action: 'auth_delete', outcome }));
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

class SystemRouteError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}

// One allowlisted system command with the caller's credential; refusals come back as data.
async function system(credential: string, command: string, payload: Json): Promise<Json> {
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
  if (!res || !res.ok) throw new SystemRouteError(res ? 'unavailable' : 'unavailable');
  const json = await res.json().catch(() => null) as Json | null;
  if (!json || typeof json !== 'object') throw new SystemRouteError('unavailable');
  if (typeof json.code === 'string') {
    throw new SystemRouteError(['unauthenticated', 'forbidden'].includes(json.code) ? 'refused' : 'unavailable');
  }
  if (typeof json.data !== 'object' || json.data === null) throw new SystemRouteError('unavailable');
  return json.data as Json;
}

async function deleteAuthUser(authUserId: string): Promise<string> {
  const res = await timed(`${SUPABASE_URL}/auth/v1/admin/users/${encodeURIComponent(authUserId)}`, {
    method: 'DELETE',
    headers: { ...keyHeaders(SERVICE_KEY), 'content-type': 'application/json' },
    body: JSON.stringify({ should_soft_delete: false }),
  });
  if (res) await res.body?.cancel();
  return classifyDeleteResult(res?.status ?? null);
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return reply(405, { outcome: 'invalid' });
  if (!SUPABASE_URL || !ANON_KEY || !SERVICE_KEY) {
    note('not_configured');
    return reply(503, { outcome: 'unavailable' });
  }
  const credential = credentialFrom(req.headers.get('x-system-credential'));
  if (!credential) {
    note('unauthenticated');
    return reply(401, { outcome: 'unauthenticated' });
  }
  if (declaredTooLarge(req.headers.get('content-length'))) return reply(413, { outcome: 'invalid' });
  let parsed;
  try {
    const raw = await req.text();
    parsed = raw.length > MAX_BODY_BYTES ? { ok: false, error: 'too_large' } : parseBody(JSON.parse(raw));
  } catch {
    parsed = { ok: false, error: 'invalid_body' };
  }
  if (!parsed.ok) {
    note(parsed.error);
    return reply(400, { outcome: 'invalid', reason: parsed.error });
  }
  const deletionId = (parsed.value as Json).deletion_id as string;
  try {
    const begun = await system(credential, 'identity.deletion_auth_begin', { deletion_id: deletionId });
    const fence = beginOutcome(begun);
    if (fence !== 'proceed') {
      note(fence);
      return reply(200, { outcome: fence });
    }
    const result = await deleteAuthUser(begun.auth_user_id as string);
    let outcome: string;
    try {
      outcome = completeOutcome(await system(credential, 'identity.deletion_auth_complete',
        { deletion_id: deletionId, auth_result: result }));
    } catch {
      // Not recorded: the step stays pending and the worker retries (the database checks the
      // Auth user is absent before it counts the step as done).
      outcome = 'retry';
    }
    note(outcome);
    return reply(200, { outcome });
  } catch (e) {
    const code = e instanceof SystemRouteError ? e.code : 'unavailable';
    note(code);
    return reply(code === 'refused' ? 403 : 503, { outcome: code });
  }
});
