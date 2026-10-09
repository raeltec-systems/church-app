#!/usr/bin/env node
// Story 2.3 end-to-end on the LOCAL stack: scoped roles with audited, immediate effect, through
// real GoTrue sessions and the real Data API (PostgREST). An Admin grants and revokes roles and
// scopes with api.identity_grant_command (1.4 envelope); sessions that are ALREADY signed in
// (a "mobile" session and a second "browser tab" of the same account) see each change on their
// very next protected call, with the same access token and no re-sign-in. Also: stale revision,
// replay, the last-Admin refusal, two Admins removing each other at the same time, a removed
// Admin's stale tab, an untrusted (magic-link) Admin session, and the SYNTHETIC care/finance
// fixture surfaces that combined-role and Admin-only members cannot reach.
//
// Sessions sign in through the verified email alias of synthetic phone accounts (AD-20: same
// account, same predicate as phone sign-in), so the CLI's phone gate need not be switched on.
// LOCAL only (exact origin), SYNTHETIC fictional numbers +1 202 555 0151-0156, emails
// @example.test. Evidence is redacted JSONL: statuses, codes, roles and revisions; never tokens,
// passwords or emails. Every user, link, member, grant, audit row and fixture target it created
// is removed at the end.
//
// Usage: node tools/identity-e2e/grants.mjs [--evidence <file.jsonl>]
import { randomBytes, randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

import { localHttp, localKey, password, psql, startRun } from './harness.mjs';

/** The reserved fictional numbers this run uses (+1 202 555 0151-0156). */
export function isFictionalGrantPhone(phone) {
  return /^\+1202555015[1-6]$/.test(phone);
}

const CARE_X = '00000000-0000-4000-b000-0000000e2301';
const CARE_Y = '00000000-0000-4000-b000-0000000e2302';
const FIN_X = '00000000-0000-4000-b000-0000000e2303';

async function main() {
  const { log, check, results } = startRun();
  const keys = localKey();
  const http = localHttp(keys);
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const myAccess = async (token) => {
    const r = await rpc('identity_my_access', token);
    return { status: r.status, roles: r.json?.roles, scopes: r.json?.scopes?.length, detail: r.json?.details };
  };
  const command = (token, cmd, expected, payload, requestId = randomUUID()) =>
    rpc('identity_grant_command', token, { version: 1, command: cmd, request_id: requestId, expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json, request_id: r.json?.request_id === requestId ? '[same]' : r.json?.request_id }));
  const scoped = (token, kind, id) => rpc('fixture_scoped_read', token, { scope_kind: kind, scope_id: id });
  const revisionOf = (member) => Number(psql(`select revision from app.identity_grant_sets where member_id = '${member}'`));

  const tag = randomBytes(4).toString('hex');
  const people = {
    A: { phone: '+12025550151', role: 'bootstrapped Admin (staff web)' },
    B: { phone: '+12025550152', role: 'member signed in on mobile and in a browser tab' },
    C: { phone: '+12025550153', role: 'combined Admin + Pastor + Media' },
    D: { phone: '+12025550154', role: 'Admin only' },
  };
  for (const p of Object.values(people)) if (!isFictionalGrantPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  const ours = `(u.email like 'synthetic-2-3-e2e-%@example.test')`;
  const cleanup = () => psql(`
    create temp table gone_members as
      select l.member_id from app.identity_account_links l join auth.users u on u.id = l.auth_user_id where ${ours};
    delete from app.identity_access_audit a using gone_members g
     where a.target_member_id = g.member_id or a.actor_member_id = g.member_id;
    delete from app.identity_grants g using gone_members m where g.member_id = m.member_id;
    delete from app.identity_grant_sets s using gone_members m where s.member_id = m.member_id;
    delete from app.identity_binding_history h using app.identity_account_links l, gone_members m
     where h.link_id = l.link_id and l.member_id = m.member_id;
    delete from app.identity_credential_events e using app.identity_account_links l, gone_members m
     where e.link_id = l.link_id and l.member_id = m.member_id;
    delete from app.identity_holds h using gone_members m where h.member_id = m.member_id;
    delete from app.identity_account_links l using gone_members m where l.member_id = m.member_id;
    delete from app.identity_members x using gone_members m where x.member_id = m.member_id;
    delete from app.cmd_receipts r using auth.users u where r.actor_id = u.id and ${ours};
    delete from auth.users u where ${ours};
    delete from app.fixture_scope_targets where scope_id in ('${CARE_X}', '${CARE_Y}', '${FIN_X}');
    select count(*) from auth.users u where ${ours};`);

  const marker = psql(`select coalesce((select environment from app.platform_environment), '')`);
  let marked = false;
  if (marker === '') {
    psql(`select app.platform_set_environment('local', 'identity-grants-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  const existingAdmins = Number(psql(`select app.identity_usable_admin_count()`));
  if (existingAdmins !== 0) throw new Error('the local database already has a usable Admin; reset it first');
  log('G00-precondition', { leftover_users_removed: cleanup(), usable_admins: existingAdmins });

  try {
    // Synthetic phone accounts with a verified synthetic email alias, linked by the operator.
    for (const [name, p] of Object.entries(people)) {
      p.email = `synthetic-2-3-e2e-${name.toLowerCase()}-${tag}@example.test`;
      p.password = password();
      const u = await http('POST', '/auth/v1/admin/users', { admin: true, body: {
        phone: p.phone, phone_confirm: true, email: p.email, email_confirm: true, password: p.password } });
      p.user = u.json?.id;
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', 'SYNTHETIC 2.3 E2E ${name}', 'identity-grants-e2e')`);
    }
    const signIn = async (p) => (await http('POST', '/auth/v1/token?grant_type=password', { body: { email: p.email, password: p.password } })).json?.access_token;
    const { A, B, C, D } = people;
    A.t = await signIn(A); C.t = await signIn(C); D.t = await signIn(D);
    const bMobile = await signIn(B);
    const bTab = await signIn(B);
    check('G01-sessions', [A.t, C.t, D.t, bMobile, bTab].every(Boolean), { signed_in: 5 });

    psql(`select app.identity_bootstrap_admin('${A.member}', 'israel')`);
    psql(`insert into app.fixture_scope_targets (scope_kind, scope_id) values
            ('fixture_care', '${CARE_X}'), ('fixture_care', '${CARE_Y}'), ('fixture_finance', '${FIN_X}')`);
    check('G02-operator-bootstrap', (await myAccess(A.t)).roles?.join() === 'admin',
      { a_access: await myAccess(A.t), audit: psql(`select action || ':' || actor_kind || ':' || operator from app.identity_access_audit where target_member_id = '${A.member}'`) });

    const before = [await myAccess(bMobile), await myAccess(bTab)];
    check('G10-member-starts-without-roles', before.every((r) => r.status === 200 && r.roles?.length === 0), { mobile: before[0], tab: before[1] });

    const list = await rpc('identity_admin_member_grants', A.t);
    const bRow = list.json?.members?.find((m) => m.member_id === B.member);
    check('G11-admin-lists-members', list.status === 200 && bRow?.account === 'app_account' && bRow?.grants?.revision === 1,
      { status: list.status, members: list.json?.members?.length, b_account: bRow?.account, b_revision: bRow?.grants?.revision,
        fields: bRow && Object.keys(bRow).sort() });

    const reqGrant = randomUUID();
    const g1 = await command(A.t, 'identity.grant_role', 1, { member_id: B.member, role: 'pastor' }, reqGrant);
    check('G12-admin-grants-pastor', g1.status === 200 && g1.revision === 2 && g1.data?.roles?.join() === 'pastor',
      { status: g1.status, revision: g1.revision, roles: g1.data?.roles });

    const after = [await myAccess(bMobile), await myAccess(bTab)];
    check('G13-signed-in-sessions-see-grant-at-next-call', after.every((r) => r.roles?.join() === 'pastor'),
      { mobile: after[0], tab: after[1], same_tokens_reused: true, re_sign_in: false });

    const audit = psql(`select action || ':' || actor_kind || ':' || (actor_member_id = '${A.member}') || ':' || (actor_account_id = '${A.user}')
                               || ':' || (request_id = '${reqGrant}') || ':' || role || ':' || revision_after
                          from app.identity_access_audit where target_member_id = '${B.member}' order by event_id`);
    const auditCols = psql(`select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
                             where table_schema = 'app' and table_name = 'identity_access_audit'`);
    check('G14-grant-audited-content-free', audit === 'role_granted:member:true:true:true:pastor:2' && !/name|phone|email|reason|note/.test(auditCols),
      { audit, columns: auditCols });

    const stale = await command(A.t, 'identity.grant_role', 1, { member_id: B.member, role: 'media' });
    check('G15-stale-tab-conflict', stale.status === 200 && stale.code === 'conflict' && stale.current_revision === 2,
      { code: stale.code, current_revision: stale.current_revision });

    const replay = await command(A.t, 'identity.grant_role', 1, { member_id: B.member, role: 'pastor' }, reqGrant);
    const changed = await command(A.t, 'identity.grant_role', 1, { member_id: B.member, role: 'media' }, reqGrant);
    check('G16-replay-and-changed-payload', replay.revision === 2 && replay.data?.roles?.join() === 'pastor' && changed.code === 'conflict',
      { replay_revision: replay.revision, changed_payload: changed.code });

    const r1 = await command(A.t, 'identity.revoke_role', 2, { member_id: B.member, role: 'pastor' });
    const afterRevoke = [await myAccess(bMobile), await myAccess(bTab)];
    check('G17-revoke-effective-at-next-call', r1.revision === 3 && afterRevoke.every((r) => r.roles?.length === 0),
      { revision: r1.revision, mobile: afterRevoke[0], tab: afterRevoke[1] });

    // B becomes Admin in its open browser tab, then loses it while the tab stays open.
    await command(A.t, 'identity.grant_role', 3, { member_id: B.member, role: 'admin' });
    const tabList = await rpc('identity_admin_member_grants', bTab);
    await command(A.t, 'identity.revoke_role', 4, { member_id: B.member, role: 'admin' });
    const tabListAfter = await rpc('identity_admin_member_grants', bTab);
    const tabCommand = await command(bTab, 'identity.grant_role', revisionOf(C.member), { member_id: C.member, role: 'media' });
    check('G18-removed-admin-stale-tab-rejected', tabList.status === 200 && tabListAfter.status === 403
      && tabListAfter.json?.details === 'not_granted' && tabCommand.code === 'forbidden',
      { while_admin: tabList.status, after_revoke: { status: tabListAfter.status, detail: tabListAfter.json?.details }, command: tabCommand.code });

    const last = await command(A.t, 'identity.revoke_role', revisionOf(A.member), { member_id: A.member, role: 'admin' });
    check('G19-last-admin-refused', last.code === 'forbidden' && last.field_errors?.role === 'unsupported'
      && (await myAccess(A.t)).roles?.join() === 'admin', { code: last.code, field_errors: last.field_errors });

    // Combined roles and Admin only: no care or finance fixture surface.
    for (const role of ['admin', 'pastor', 'media']) await command(A.t, 'identity.grant_role', revisionOf(C.member), { member_id: C.member, role });
    await command(A.t, 'identity.grant_role', revisionOf(D.member), { member_id: D.member, role: 'admin' });
    const cAccess = await myAccess(C.t);
    const denials = {
      combined_care: (await scoped(C.t, 'fixture_care', CARE_X)).status,
      combined_finance: (await scoped(C.t, 'fixture_finance', FIN_X)).status,
      admin_only_care: (await scoped(D.t, 'fixture_care', CARE_X)).status,
      admin_only_finance: (await scoped(D.t, 'fixture_finance', FIN_X)).status,
    };
    check('G20-combined-and-admin-only-reach-no-care-or-finance',
      cAccess.roles?.join() === 'admin,pastor,media' && Object.values(denials).every((s) => s === 403),
      { combined_roles: cAccess.roles, ...denials });

    // A scope works exactly, and its revocation is effective at the next call.
    const sg = await command(A.t, 'identity.grant_scope', revisionOf(B.member), { member_id: B.member, scope_kind: 'fixture_care', scope_id: CARE_X });
    const scopedNow = { x: (await scoped(bMobile, 'fixture_care', CARE_X)).status, y: (await scoped(bMobile, 'fixture_care', CARE_Y)).status,
      finance: (await scoped(bMobile, 'fixture_finance', FIN_X)).status };
    await command(A.t, 'identity.revoke_scope', revisionOf(B.member), { member_id: B.member, scope_kind: 'fixture_care', scope_id: CARE_X });
    const scopedAfter = (await scoped(bMobile, 'fixture_care', CARE_X)).status;
    check('G21-scope-exact-and-revocable', sg.status === 200 && scopedNow.x === 200 && scopedNow.y === 403 && scopedNow.finance === 403 && scopedAfter === 403,
      { granted: scopedNow, after_revoke: scopedAfter });

    // An Admin whose session is a magic-link (otp AMR) session cannot act.
    const link = await http('POST', '/auth/v1/admin/generate_link', { admin: true, body: { type: 'magiclink', email: A.email } });
    const otpToken = (await http('POST', '/auth/v1/verify', { body: { type: 'magiclink', token_hash: link.json?.hashed_token } })).json?.access_token;
    const otpCmd = await command(otpToken, 'identity.grant_role', revisionOf(D.member), { member_id: D.member, role: 'media' });
    check('G22-untrusted-admin-session-refused', otpCmd.code === 'unauthenticated', { code: otpCmd.code });

    // Two Admins (A and D; C too) remove each other at the same moment: never a deadlock, never
    // both, and a usable Admin always remains. Remove C first so A and D are the only two.
    await command(A.t, 'identity.revoke_role', revisionOf(C.member), { member_id: C.member, role: 'admin' });
    const [ad, da] = await Promise.all([
      command(A.t, 'identity.revoke_role', revisionOf(D.member), { member_id: D.member, role: 'admin' }),
      command(D.t, 'identity.revoke_role', revisionOf(A.member), { member_id: A.member, role: 'admin' }),
    ]);
    const outcomes = [ad.code ?? 'success', da.code ?? 'success'];
    check('G23-concurrent-mutual-removal-serialised', outcomes.filter((o) => o === 'success').length === 1
      && outcomes.includes('forbidden') && psql(`select app.identity_usable_admin_count()`) === '1',
      { a_removes_d: outcomes[0], d_removes_a: outcomes[1], usable_admins: Number(psql(`select app.identity_usable_admin_count()`)) });

    const lifecycle = psql(`select count(*) from app.identity_access_audit where action in ('role_revoked', 'scope_revoked')
                              and target_member_id in ('${A.member}', '${B.member}', '${C.member}', '${D.member}')`);
    check('G24-every-revocation-audited', Number(lifecycle) === 5, { revocations_audited: Number(lifecycle) });
  } finally {
    const left = cleanup();
    if (marked) psql(`delete from app.platform_environment where set_by = 'identity-grants-e2e'; delete from app.platform_environment_history where set_by = 'identity-grants-e2e';`);
    check('G99-cleanup', left === '0' && psql(`select app.identity_usable_admin_count()`) === '0',
      { synthetic_users_left: Number(left) });
  }
  const failed = results.filter((r) => !r.ok);
  console.log(failed.length ? `FAIL: ${failed.map((r) => r.step).join(', ')}` : `PASS: ${results.length} checks`);
  process.exit(failed.length ? 1 : 0);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((e) => {
    console.error(`identity-grants-e2e: ${e.message}`);
    process.exit(1);
  });
}
