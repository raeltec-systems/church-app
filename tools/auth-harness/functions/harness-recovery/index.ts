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
//      (1.2 predicate) of a staff account enrolled out of band.
//
// Nothing here logs request bodies. Responses never contain a password, a
// grant secret, a digest or a token. Server-side logs carry coarse codes only.

import {
  HEX64_RE,
  INJECTIONS,
  OWN_REF,
  OWN_URL,
  PROVISION_ROLES,
  SYNTHETIC_EMAIL_RE,
  TAG_RE,
  UUID_RE,
  authErrorCode,
  buildOutcome,
  classifyCaller,
  decodeJwtPayload,
  fetchWithTimeout,
  isOwnProjectUrl,
  requestTargetsOtherProject,
  requiredCaller,
  sha256Hex,
  syntheticEmail,
} from './logic.mjs';

const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const CALL_TIMEOUT_MS = 10_000;
const LATE_APPLY_DELAY_MS = 8_000;

type Json = Record<string, unknown>;
declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

function reply(status: number, body: Json): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
  });
}

async function call(path: string, init: { method?: string; bearer: string; apikey: string; body?: unknown }) {
  const res = await fetchWithTimeout(fetch, OWN_URL + path, {
    method: init.method ?? 'POST',
    headers: {
      apikey: init.apikey,
      authorization: `Bearer ${init.bearer}`,
      ...(init.body !== undefined ? { 'content-type': 'application/json' } : {}),
    },
    body: init.body !== undefined ? JSON.stringify(init.body) : undefined,
  }, CALL_TIMEOUT_MS);
  const text = await res.text();
  let json: unknown = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  return { status: res.status, json: json as Json | null };
}

class RpcError extends Error {}

async function rpc(name: string, args: Json): Promise<Json> {
  const r = await call(`/rest/v1/rpc/${name}`, { bearer: SERVICE_KEY, apikey: SERVICE_KEY, body: args });
  if (r.status !== 200 || r.json === null) {
    console.error(`harness-recovery rpc_failed ${name} ${r.status}`);
    throw new RpcError('rpc_failed');
  }
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

// Auth Admin password set. On the observed Auth version this also logs out
// every session of the account in the same Auth transaction; the database
// verifies that independently before accepting success or reconciliation.
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
    // Network error or CALL_TIMEOUT_MS elapsed: the outcome is unknown.
    return { adminStatus: null, adminThrew: true, errorCode: null };
  }
}

async function complete(opId: string, generation: number, outcome: Json): Promise<Json> {
  try {
    return await rpc('harness_rc_complete', { p_op: opId, p_generation: generation, p_outcome: outcome });
  } catch {
    // Completion could not be recorded: never leave the op dispatched.
    await rpc('harness_rc_mark_uncertain', { p_op: opId, p_reason: 'completion_not_recorded' }).catch(() => null);
    return { status: 'uncertain', access_held: true };
  }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// begin -> fenced dispatch -> Auth Admin set -> fenced completion.
async function runOp(op: Json, password: string, inject: string | undefined): Promise<Response> {
  const opId = op.op_id as string;
  const generation = op.generation as number;
  const uid = op.auth_user_id as string;

  const d = await rpc('harness_rc_dispatch', { p_op: opId, p_generation: generation });
  if (d.ok !== true) return reply(409, { status: 'obsolete', op_id: opId, code: 'conflict' });

  if (inject === 'crash_after_dispatch') {
    // Harness-only: the worker dies after dispatch; nothing reaches Auth.
    return reply(202, { status: 'dispatched', op_id: opId, injected: 'crash_after_dispatch' });
  }

  if (inject === 'late_apply' || inject === 'late_apply_background') {
    // The caller gives up waiting (timeout) BEFORE Auth answers; Auth applies
    // later and the real outcome arrives after the op is uncertain (and, in
    // the background variant, possibly after staff reconciled it).
    await rpc('harness_rc_mark_uncertain', { p_op: opId, p_reason: 'injected_timeout' });
    const late = async () => {
      if (inject === 'late_apply_background') await sleep(LATE_APPLY_DELAY_MS);
      const a = await applyPassword(uid, password);
      return {
        admin_error: a.errorCode,
        completion: await complete(opId, generation, { ...buildOutcome({ ...a, transport: 'ok' }), late: true }),
      };
    };
    if (inject === 'late_apply_background' && typeof EdgeRuntime !== 'undefined') {
      EdgeRuntime.waitUntil(late().catch(() => null));
      return reply(202, { status: 'uncertain', op_id: opId, late_apply_in_ms: LATE_APPLY_DELAY_MS });
    }
    const r = await late();
    return reply(202, { status: 'uncertain', op_id: opId, late_completion: r.completion, admin_error: r.admin_error });
  }

  if (inject === 'delay_apply') {
    // Harness-only: hold the dispatched op open so a concurrent native
    // credential change can land between dispatch and the Admin call.
    await sleep(4000);
  }
  const a = await applyPassword(uid, password);
  const outcome = buildOutcome({ ...a, transport: inject === 'lost_response' ? 'lost' : 'ok' });
  const c = await complete(opId, generation, outcome);
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

function randomPassword(): string {
  const b = new Uint8Array(32);
  crypto.getRandomValues(b);
  return 'Rv!' + btoa(String.fromCharCode(...b)).replace(/[+/=]/g, '');
}

async function sourceHashes(): Promise<Json> {
  const out: Json = {};
  for (const f of ['index.ts', 'logic.mjs']) {
    try {
      out[f] = await sha256Hex(await Deno.readTextFile(new URL(`./${f}`, import.meta.url)));
    } catch {
      out[f] = 'unavailable';
    }
  }
  return out;
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
      case 'version':
        return reply(200, { own_ref: OWN_REF, source_sha256: await sourceHashes() });
      case 'provision': {
        // Synthetic plus-address account, confirmed by Admin (no email sent).
        // Members only: staff enrolment is out of band (sql/enroll_staff.sql).
        if (body.role === 'staff') return reply(403, { code: 'forbidden', reason: 'staff_enrolment_out_of_band' });
        const password = str(body.password);
        const role = typeof body.role === 'string' && PROVISION_ROLES.has(body.role) ? body.role : null;
        if (!password || !role || !TAG_RE.test(String(body.tag))) return reply(400, { code: 'validation_failed' });
        const email = syntheticEmail(String(body.tag));
        const created = await call('/auth/v1/admin/users', {
          bearer: SERVICE_KEY,
          apikey: SERVICE_KEY,
          body: { email, password, email_confirm: true },
        });
        if (created.status !== 200 || !created.json?.id) {
          return reply(created.status === 422 ? 409 : 502, { code: 'conflict', auth_error: authErrorCode(created.json) });
        }
        if (role === 'none') return reply(200, { auth_user_id: created.json.id, ok: true, role: 'none' });
        const enrolled = await rpc('harness_rc_enroll', { p_uid: created.json.id, p_role: 'member' });
        return reply(200, { auth_user_id: created.json.id, ...enrolled });
      }
      case 'request': {
        const digest = str(body.grant_digest);
        const claimed = str(body.claimed_login);
        if (!digest || !HEX64_RE.test(digest) || !claimed) return reply(400, { code: 'validation_failed' });
        const r = await rpc('harness_rc_request', { p_digest: digest, p_claimed_login: claimed });
        return reply(r.ok === true ? 200 : r.code === 'rate_limited' ? 429 : r.code === 'validation_failed' ? 400 : 409, r);
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
            p_expected_email: str(body.expected_email),
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
        } else if (action === 'expire_stuck') {
          r = await rpc('harness_rc_expire_stuck', { p_staff: staff, p_op: uuidOrNull(body.op_id) });
        } else if (action === 'reconcile') {
          const opId = uuidOrNull(body.op_id);
          const forcedReq = body.force_revoke === true;
          let forced: Json | undefined;
          if (forcedReq) {
            // The target is resolved and checked server-side from the op
            // (exists, uncertain, enrolled account) BEFORE any Auth Admin
            // call; a caller-supplied uid that differs is refused.
            if (body.auth_user_id !== undefined && !uuidOrNull(body.auth_user_id)) {
              return reply(400, { code: 'validation_failed' });
            }
            const t = await rpc('harness_rc_force_revoke_target', {
              p_staff: staff,
              p_op: opId,
              p_claimed_uid: body.auth_user_id === undefined ? null : uuidOrNull(body.auth_user_id),
            });
            if (t.ok !== true) return reply(t.code === 'forbidden' ? 403 : t.code === 'not_found' ? 404 : 409, t);
            // Revoke every session by setting an undisclosed random password;
            // the member then needs a new grant. The DB still verifies that no
            // pre-dispatch session is live.
            const a = await applyPassword(t.auth_user_id as string, randomPassword());
            forced = { admin_status: a.adminStatus, admin_error: a.errorCode };
          }
          r = await rpc('harness_rc_reconcile', { p_staff: staff, p_op: opId, p_note: str(body.note), p_forced: forcedReq });
          if (forced) r = { ...r, force_revoke: forced };
        } else if (action === 'instrument_delete_user') {
          // Harness instrumentation: Auth Admin deletion of a synthetic member.
          const uid = uuidOrNull(body.auth_user_id);
          if (!uid) return reply(400, { code: 'validation_failed' });
          const u = await call(`/auth/v1/admin/users/${uid}`, { method: 'GET', bearer: SERVICE_KEY, apikey: SERVICE_KEY });
          if (u.status !== 200 || !SYNTHETIC_EMAIL_RE.test(String(u.json?.email ?? ''))) {
            return reply(404, { code: 'not_found' });
          }
          const del = await call(`/auth/v1/admin/users/${uid}`, { method: 'DELETE', bearer: SERVICE_KEY, apikey: SERVICE_KEY });
          return reply(del.status === 200 ? 200 : 502, { ok: del.status === 200, admin_status: del.status });
        } else {
          r = await rpc('harness_rc_replay_complete', { p_staff: staff, p_op: uuidOrNull(body.op_id) });
        }
        return reply(r.ok === true ? 200 : r.code === 'forbidden' ? 403 : r.code === 'not_found' ? 404 : 409, r);
      }
    }
  } catch (e) {
    // Generic code only; the coarse reason (never request content) is logged.
    console.error(`harness-recovery unhandled ${e instanceof RpcError ? 'rpc_failed' : 'internal'}`);
    return reply(500, { code: 'unavailable' });
  }
});
