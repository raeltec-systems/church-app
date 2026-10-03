// harness-recovery: harness-only Edge Function for story 1.3 (AD-20 fenced
// assisted reset). Deployed ONLY to bic-kafue-auth-test (szfyfezfvxyuvovnnakr)
// with verify_jwt on. It is the only holder of Auth Admin power in the
// harness; the service key comes from the platform environment and is never
// returned, logged or stored.
//
// Caller authentication, in order:
//   1. Platform verify_jwt (signature).
//   2. Own project only: SUPABASE_URL, the JWT issuer/ref and any requested
//      project/URL must be this project.
//   3. Harness operator token (x-harness-operator), checked by digest.
//   4. Per action: member/operator actions use the anon key (the member has
//      no session); staff actions need a live trusted password session
//      (1.2 predicate) of an enrolled staff account.
//
// Nothing here logs request bodies. Responses never contain a password, a
// grant secret, a digest or a token.

import {
  INJECTIONS,
  OWN_REF,
  OWN_URL,
  UUID_RE,
  HEX64_RE,
  authErrorCode,
  buildOutcome,
  classifyCaller,
  decodeJwtPayload,
  isOwnProjectUrl,
  requestTargetsOtherProject,
  requiredCaller,
  sha256Hex,
  syntheticEmail,
} from './logic.mjs';

const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';

type Json = Record<string, unknown>;

function reply(status: number, body: Json): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
  });
}

async function call(path: string, init: { method?: string; bearer: string; apikey: string; body?: unknown }) {
  const res = await fetch(OWN_URL + path, {
    method: init.method ?? 'POST',
    headers: {
      apikey: init.apikey,
      authorization: `Bearer ${init.bearer}`,
      ...(init.body !== undefined ? { 'content-type': 'application/json' } : {}),
    },
    body: init.body !== undefined ? JSON.stringify(init.body) : undefined,
  });
  const text = await res.text();
  let json: unknown = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  return { status: res.status, json: json as Json | null };
}

async function rpc(name: string, args: Json): Promise<Json> {
  const r = await call(`/rest/v1/rpc/${name}`, { bearer: SERVICE_KEY, apikey: SERVICE_KEY, body: args });
  if (r.status !== 200 || r.json === null) throw new Error(`rpc_failed:${name}:${r.status}`);
  return r.json;
}

async function requireStaff(bearer: string): Promise<string | null> {
  const user = await call('/auth/v1/user', { method: 'GET', bearer, apikey: ANON_KEY });
  const uid = user.status === 200 ? (user.json?.id as string | undefined) : undefined;
  if (!uid) return null;
  const who = await call('/rest/v1/rpc/harness_whoami', { bearer, apikey: ANON_KEY, body: {} });
  if (who.status !== 200 || who.json?.trusted_password_session !== true) return null;
  const staff = await call('/rest/v1/rpc/harness_rc_is_staff', {
    bearer: SERVICE_KEY,
    apikey: SERVICE_KEY,
    body: { p_uid: uid },
  });
  return staff.status === 200 && staff.json === (true as unknown) ? uid : null;
}

async function applyPassword(uid: string, password: string) {
  try {
    const r = await call(`/auth/v1/admin/users/${uid}`, {
      method: 'PUT',
      bearer: SERVICE_KEY,
      apikey: SERVICE_KEY,
      body: { password },
    });
    return { adminStatus: r.status, adminThrew: false, errorCode: r.status === 200 ? null : authErrorCode(r.json) };
  } catch {
    return { adminStatus: null, adminThrew: true, errorCode: null };
  }
}

// begin -> fenced dispatch -> Auth Admin set -> fenced completion. Auth Admin
// password update logs out every session of the account in the same Auth
// transaction (observed Auth version); the completion fence verifies that in
// the database rather than trusting this function's report.
async function runOp(op: Json, password: string, inject: string | undefined): Promise<Response> {
  const opId = op.op_id as string;
  const generation = op.generation as number;
  const uid = op.auth_user_id as string;

  const d = await rpc('harness_rc_dispatch', { p_op: opId, p_generation: generation });
  if (d.ok !== true) return reply(409, { status: 'obsolete', op_id: opId, code: 'conflict' });

  if (inject === 'late_apply') {
    // The caller gives up waiting (timeout) BEFORE Auth answers; Auth then
    // applies late and the real outcome arrives after the op is uncertain.
    await rpc('harness_rc_mark_uncertain', { p_op: opId, p_reason: 'injected_timeout' });
    const a = await applyPassword(uid, password);
    const late = await rpc('harness_rc_complete', {
      p_op: opId,
      p_generation: generation,
      p_outcome: { ...buildOutcome({ ...a, transport: 'ok' }), late: true },
    });
    return reply(202, { status: 'uncertain', op_id: opId, late_completion: late, admin_error: a.errorCode });
  }

  if (inject === 'delay_apply') {
    // Harness-only: hold the dispatched op open so a concurrent native
    // credential change can land between dispatch and the Admin call.
    await new Promise((r) => setTimeout(r, 4000));
  }
  const a = await applyPassword(uid, password);
  const outcome = buildOutcome({ ...a, transport: inject === 'lost_response' ? 'lost' : 'ok' });
  const c = await rpc('harness_rc_complete', { p_op: opId, p_generation: generation, p_outcome: outcome });
  if (inject === 'lost_response') {
    // The member's client never sees Auth's answer.
    return reply(504, { status: 'unknown', op_id: opId, code: 'unavailable', recorded: c.status });
  }
  return reply(c.status === 'succeeded' ? 200 : c.status === 'failed' ? 422 : 202, {
    status: c.status,
    op_id: opId,
    access_held: c.access_held,
    admin_error: a.errorCode,
  });
}

function str(v: unknown): string | null {
  return typeof v === 'string' && v.length > 0 && v.length <= 512 ? v : null;
}

Deno.serve(async (req: Request) => {
  try {
    if (!isOwnProjectUrl(Deno.env.get('SUPABASE_URL') ?? '') || !SERVICE_KEY || !ANON_KEY) {
      return reply(500, { code: 'wrong_project' });
    }
    if (req.method !== 'POST') return reply(405, { code: 'validation_failed' });
    const body = (await req.json().catch(() => null)) as Json | null;
    if (!body || typeof body !== 'object' || Array.isArray(body)) return reply(400, { code: 'validation_failed' });
    if (requestTargetsOtherProject(body)) return reply(400, { code: 'wrong_project', own_ref: OWN_REF });

    const bearer = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
    const caller = classifyCaller(decodeJwtPayload(bearer));
    if (!caller) return reply(401, { code: 'unauthenticated', reason: 'foreign_or_unsupported_token' });

    const operator = req.headers.get('x-harness-operator') ?? '';
    if (operator.length < 32 || operator.length > 128) return reply(401, { code: 'unauthenticated', reason: 'operator_required' });
    const opOk = await rpc('harness_rc_check_operator', { p_digest: await sha256Hex(operator) });
    if (opOk !== (true as unknown)) return reply(401, { code: 'unauthenticated', reason: 'operator_required' });

    const action = str(body.action) ?? '';
    const need = requiredCaller(action);
    if (!need) return reply(400, { code: 'validation_failed' });
    if (need !== caller) return reply(403, { code: 'forbidden', reason: `requires_${need}` });

    const inject = body.inject === undefined ? undefined : str(body.inject) ?? '';
    if (inject !== undefined && !INJECTIONS.has(inject)) return reply(400, { code: 'validation_failed' });

    switch (action) {
      case 'provision': {
        // Synthetic plus-address account, confirmed by Admin (no email sent).
        const password = str(body.password);
        const role = body.role === 'staff' ? 'staff' : body.role === 'member' ? 'member' : null;
        if (!password || !role) return reply(400, { code: 'validation_failed' });
        const email = syntheticEmail(String(body.tag));
        const created = await call('/auth/v1/admin/users', {
          bearer: SERVICE_KEY,
          apikey: SERVICE_KEY,
          body: { email, password, email_confirm: true },
        });
        if (created.status !== 200 || !created.json?.id) {
          return reply(created.status === 422 ? 409 : 502, { code: 'conflict', auth_error: authErrorCode(created.json) });
        }
        const enrolled = await rpc('harness_rc_enroll', { p_uid: created.json.id, p_role: role });
        return reply(200, { auth_user_id: created.json.id, ...enrolled });
      }
      case 'request': {
        const digest = str(body.grant_digest);
        if (!digest || !HEX64_RE.test(digest)) return reply(400, { code: 'validation_failed' });
        const r = await rpc('harness_rc_request', { p_digest: digest });
        return reply(r.ok === true ? 200 : 409, r);
      }
      case 'redeem': {
        const grant = str(body.grant);
        const password = str(body.password);
        const login = str(body.login_email);
        if (!grant || !password || !login) return reply(400, { code: 'validation_failed' });
        const begun = await rpc('harness_rc_begin', { p_digest: await sha256Hex(grant), p_login_email: login });
        if (begun.ok !== true) return reply(begun.code === 'conflict' ? 409 : 403, { code: begun.code });
        if (inject === 'stop_after_begin') return reply(202, { status: 'pending', op_id: begun.op_id });
        return await runOp(begun, password, inject);
      }
      case 'resume': {
        const grant = str(body.grant);
        const password = str(body.password);
        const opId = str(body.op_id);
        if (!grant || !password || !opId || !UUID_RE.test(opId)) return reply(400, { code: 'validation_failed' });
        const op = await rpc('harness_rc_resume', { p_op: opId, p_digest: await sha256Hex(grant) });
        if (op.ok !== true) return reply(403, { code: op.code });
        return await runOp(op, password, inject);
      }
      default: {
        const staff = await requireStaff(bearer);
        if (!staff) return reply(403, { code: 'forbidden', reason: 'staff_trusted_session_required' });
        const uuidOrNull = (v: unknown) => (typeof v === 'string' && UUID_RE.test(v) ? v : null);
        let r: Json;
        if (action === 'issue') {
          r = await rpc('harness_rc_issue', {
            p_staff: staff,
            p_request_ref: uuidOrNull(body.request_ref),
            p_case_id: str(body.case_id) ?? 'harness-case',
            p_member_id: uuidOrNull(body.member_id),
            p_uid: uuidOrNull(body.auth_user_id),
            p_link_revision: Number(body.link_revision),
            p_ttl_s: Number(body.ttl_s ?? 900),
          });
        } else if (action === 'relink') {
          r = await rpc('harness_rc_relink', {
            p_staff: staff,
            p_uid: uuidOrNull(body.auth_user_id),
            p_member_id: uuidOrNull(body.member_id),
            p_expected_link_revision: Number(body.expected_link_revision),
          });
        } else if (action === 'hold') {
          r = await rpc('harness_rc_hold', { p_staff: staff, p_uid: uuidOrNull(body.auth_user_id), p_on: body.on === true });
        } else if (action === 'observe') {
          // Read-only DB state of the synthetic harness accounts (digests only).
          const obs = await rpc('harness_rc_observe', {
            p_tag_prefix: str(body.tag_prefix),
            p_since: str(body.since) ?? '-infinity',
          });
          return reply(200, { ok: true, observation: obs });
        } else if (action === 'reconcile') {
          r = await rpc('harness_rc_reconcile', { p_staff: staff, p_op: uuidOrNull(body.op_id), p_note: str(body.note) });
        } else {
          r = await rpc('harness_rc_replay_complete', { p_staff: staff, p_op: uuidOrNull(body.op_id) });
        }
        return reply(r.ok === true ? 200 : r.code === 'forbidden' ? 403 : r.code === 'not_found' ? 404 : 409, r);
      }
    }
  } catch (e) {
    // Only a coarse reason; never request content.
    const msg = e instanceof Error ? e.message : '';
    return reply(500, { code: 'unavailable', reason: msg.startsWith('rpc_failed:') ? msg : 'internal' });
  }
});
