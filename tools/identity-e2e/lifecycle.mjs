#!/usr/bin/env node
// Story 2.10 end-to-end on the LOCAL stack: hold, deactivate and restore membership with handover
// obligations, through real GoTrue (phone sign-in without SMS, refresh) and the real Data API:
//   * the last usable Admin cannot be removed;
//   * a login hold (identity.place_hold `login_disabled`) denies both of the member's devices at
//     once (sessions revoked, refresh refused); a fresh sign-in reaches only the generic help
//     answer; church membership, the confirmed cell and the SYNTHETIC fixture duty survive it;
//     another Admin's release lets a fresh sign-in in again;
//   * church deactivation denies both devices at once, ends the member's grants, invalidates an
//     issued staff-assisted recovery grant, records the fixture duty as a pending handover
//     obligation through the registered (SYNTHETIC) owner handover hook and tells the owner
//     lifecycle hooks in the same transaction; the member's own status says deactivated;
//   * the last responsible person for an owner's work cannot be deactivated until it is handed
//     over;
//   * a reviewed restoration by another Admin lets only a fresh sign-in in, with no grants
//     restored and the handover still pending;
//   * the last two Admins deactivating each other at the same time: exactly one succeeds.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on` (no SMS
// provider, hook, test OTP or SMS MFA), then `off` afterwards, and a database with no usable
// Admin (`npx supabase db reset` first). LOCAL only (exact origin), SYNTHETIC fictional numbers
// +44 7700 900520-900529. Evidence is redacted JSONL: statuses, codes, counts and booleans; never
// tokens, passwords or numbers. Everything it created is removed, including its hook
// registrations.
//
// Usage: node tools/identity-e2e/lifecycle.mjs [--evidence <file.jsonl>]
import { createHash, randomBytes, randomUUID } from 'node:crypto';

import { amrMethods, EPOCH_WAIT_MS, localHttp, localKey, password, psql, runMain, sleep, startRun } from './harness.mjs';

/** The reserved fictional numbers this run uses (+44 7700 900520-900529). */
export function isFictionalLifecyclePhone(phone) {
  return /^\+4477009005[2][0-9]$/.test(phone);
}

/** The only keys the member's own status may carry: never a reason, actor or obligation. */
export const MY_STATUS_KEYS = ['church_contact', 'deactivated'];

export function unexpectedStatusKeys(read) {
  return Object.keys(read ?? {}).filter((k) => !MY_STATUS_KEYS.includes(k)).sort();
}

/** A random 2.9 request code (no 0/O/1/I). */
export function requestCode() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  return [...randomBytes(8)].map((b) => alphabet[b % 32]).join('');
}

const NAME_PREFIX = 'SYNTHETIC 2.10 E2E';

const LIFECYCLE_EVENTS = ['access_hold_applied', 'access_hold_released', 'sessions_revoked', 'scope_revoked',
  'membership_deactivated', 'membership_restored'];

async function main() {
  const { log, check, finish } = startRun();
  const keys = localKey();
  const http = localHttp(keys);
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const refresh = (rt) => http('POST', '/auth/v1/token?grant_type=refresh_token', { body: { refresh_token: rt } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const envelope = (fn, token, cmd, expected, payload) =>
    rpc(fn, token, { version: 1, command: cmd, request_id: randomUUID(), expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const summary = async (token) => {
    const r = await rpc('identity_my_member_summary', token);
    return { status: r.status, detail: r.json?.details ?? null };
  };

  const people = {
    admin: { phone: '+447700900520', name: `${NAME_PREFIX} Admin A` },
    admin2: { phone: '+447700900521', name: `${NAME_PREFIX} Admin B` },
    held: { phone: '+447700900522', name: `${NAME_PREFIX} Held` },
    leaving: { phone: '+447700900523', name: `${NAME_PREFIX} Leaving` },
    sole: { phone: '+447700900524', name: `${NAME_PREFIX} Sole` },
  };
  for (const p of Object.values(people)) {
    if (!isFictionalLifecyclePhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  }
  const users = new Set();
  const digits = Object.values(people).map((p) => `'${p.phone.slice(1)}'`).join(',');
  const unhook = () => psql(`
    delete from app.contract_lifecycle_hooks where module = 'fixture'
       and event in (${LIFECYCLE_EVENTS.map((e) => `'${e}'`).join(',')});
    delete from app.identity_handover_hooks where module = 'fixture';`);
  const cleanup = () => {
    const ids = [...users].map((u) => `'${u}'`);
    const byUser = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    return psql(`
    create temp table gone_users as select u.id from auth.users u where ${byUser} u.phone in (${digits});
    create temp table gone_members as
      select m.member_id from app.identity_members m where m.display_name like '${NAME_PREFIX}%';
    create temp table gone_cells as select c.cell_id from app.cells_cells c where c.name like '${NAME_PREFIX}%';
    delete from app.fixture_lifecycle_calls c where c.member_id in (select member_id from gone_members);
    delete from app.fixture_duties d where d.member_id in (select member_id from gone_members);
    delete from app.identity_handover_obligations o where o.member_id in (select member_id from gone_members);
    delete from app.identity_membership_lifecycle e
     where e.member_id in (select member_id from gone_members) or e.actor_member_id in (select member_id from gone_members);
    delete from app.identity_recovery_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_recovery_operations o where o.member_id in (select member_id from gone_members);
    create temp table gone_requests as
      select g.recovery_request_id from app.identity_recovery_grants g where g.member_id in (select member_id from gone_members)
      union select r.recovery_request_id from app.identity_recovery_requests r where r.claimed_phone in (${Object.values(people).map((p) => `'${p.phone}'`).join(',')});
    delete from app.identity_recovery_grants g where g.member_id in (select member_id from gone_members);
    delete from app.identity_recovery_cases c where c.member_id in (select member_id from gone_members);
    delete from app.identity_recovery_requests r where r.recovery_request_id in (select recovery_request_id from gone_requests);
    delete from app.identity_credential_review_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.cells_membership_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members)
        or a.cell_id in (select cell_id from gone_cells);
    with gone_memberships as (
      delete from app.cells_memberships m
       where m.member_id in (select member_id from gone_members) or m.cell_id in (select cell_id from gone_cells)
      returning m.membership_id)
    delete from app.cells_membership_requests r
     where r.member_id in (select member_id from gone_members) or r.requested_cell_id in (select cell_id from gone_cells);
    delete from app.cells_member_states s where s.member_id in (select member_id from gone_members);
    delete from app.cells_signup_options o where o.cell_id in (select cell_id from gone_cells);
    delete from app.identity_access_audit a
     where a.target_member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_grants g where g.member_id in (select member_id from gone_members);
    delete from app.identity_grant_sets s where s.member_id in (select member_id from gone_members);
    delete from app.identity_binding_history h using app.identity_account_links l
     where h.link_id = l.link_id and (l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users));
    delete from app.identity_credential_events e using app.identity_account_links l
     where e.link_id = l.link_id and (l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users));
    delete from app.identity_holds h where h.member_id in (select member_id from gone_members);
    delete from app.identity_account_links l
     where l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users);
    delete from app.identity_members m where m.member_id in (select member_id from gone_members);
    delete from app.cells_cells c where c.cell_id in (select cell_id from gone_cells);
    delete from app.cmd_receipts r where r.actor_id in (select id from gone_users);
    delete from auth.users u where u.id in (select id from gone_users);
    select count(*) from auth.users u where ${byUser} u.phone in (${digits});`);
  };

  const settings = await http('GET', '/auth/v1/settings');
  if (settings.json?.external?.phone !== true) {
    throw new Error('the local phone provider is off: run `node tools/auth-harness/local-phone-auth.mjs on` first');
  }
  const marker = psql(`select coalesce((select environment from app.platform_environment), '')`);
  let marked = false;
  if (marker === '') {
    psql(`select app.platform_set_environment('local', 'identity-lifecycle-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('L00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });
  if (Number(psql(`select app.identity_usable_admin_count()`)) !== 0) {
    throw new Error('the local database already has a usable Admin; run `npx supabase db reset` first');
  }
  if (Number(psql(`select (select count(*) from app.contract_lifecycle_hooks where module = 'fixture')
                        + (select count(*) from app.identity_handover_hooks)`)) !== 0) {
    throw new Error('a fixture lifecycle or handover hook is already registered');
  }

  try {
    const { admin, admin2, held, leaving, sole } = people;
    psql(`${LIFECYCLE_EVENTS.map((e) => `select app.contract_register_lifecycle_hook('fixture', '${e}', 'app.fixture_record_lifecycle(jsonb)'::regprocedure);`).join('\n')}
          select app.identity_register_handover_hook('fixture', 'app.fixture_report_handover(jsonb)'::regprocedure);`);
    const calls = (p) => psql(`select coalesce(string_agg(event, ',' order by call_id), '') from app.fixture_lifecycle_calls where member_id = '${p.member}'`);
    const seeded = async (p) => {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: {
        phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'identity-lifecycle-e2e')`);
      return created.status;
    };
    // Two devices: the mobile app and the staff web client, each with its own session.
    const twoDevices = async (p) => {
      const mobile = await signIn(p.phone, p.password);
      const web = await signIn(p.phone, p.password);
      p.devices = [mobile.json, web.json];
      p.token = mobile.json?.access_token;
    };
    const devicesDenied = async (p) => {
      const out = [];
      for (const d of p.devices) {
        out.push({ summary: (await summary(d?.access_token)).status, refresh: (await refresh(d?.refresh_token)).status });
      }
      return out;
    };
    const fresh = async (p) => {
      await sleep(EPOCH_WAIT_MS);
      return (await signIn(p.phone, p.password)).json?.access_token;
    };
    const memberRev = (p) => Number(psql(`select revision from app.identity_members where member_id = '${p.member}'`));
    const lifecycle = (token, cmd, p, payload) =>
      envelope('identity_lifecycle_command', token, cmd, memberRev(p), { member_id: p.member, ...payload });
    const hold = (token, p, reason) =>
      envelope('identity_credential_command', token, 'identity.place_hold', memberRev(p), { member_id: p.member, reason_code: reason });
    const facts = (p) => psql(`select (select membership_state from app.identity_members where member_id = '${p.member}')
      || '|' || (select count(*) from app.cells_memberships where member_id = '${p.member}' and ended_at is null)
      || '|' || (select count(*) from app.fixture_duties where member_id = '${p.member}')`);

    // --------------------------------------------------------------- the last usable Admin
    await seeded(admin);
    psql(`select app.identity_bootstrap_admin('${admin.member}', 'israel')`);
    admin.token = (await signIn(admin.phone, admin.password)).json?.access_token;
    const lastAdmin = await lifecycle(admin.token, 'identity.deactivate_membership', admin, { reason_code: 'church_decision' });
    const stillAdmin = await rpc('identity_my_access', admin.token);
    check('L01-last-usable-admin-cannot-be-removed', amrMethods(admin.token).includes('password')
      && lastAdmin.code === 'forbidden' && lastAdmin.field_errors?.member_id === 'last_admin'
      && stillAdmin.json?.roles?.includes('admin'),
      { amr: amrMethods(admin.token), deactivate_last_admin: { code: lastAdmin.code, field_errors: lastAdmin.field_errors },
        still_admin: stillAdmin.json?.roles?.includes('admin') });

    await seeded(admin2);
    const b0 = await rpc('identity_my_access', (await signIn(admin2.phone, admin2.password)).json?.access_token);
    const gb = await envelope('identity_grant_command', admin.token, 'identity.grant_role', b0.json?.revision,
      { member_id: admin2.member, role: 'admin' });
    admin2.token = (await signIn(admin2.phone, admin2.password)).json?.access_token;
    check('L02-second-admin', gb.status === 200 && gb.data?.roles?.includes('admin'), { admin_role_granted: gb.code ?? 'ok' });

    // ----------------------------------------------------------------------------- login hold
    await seeded(held);
    const cx = await envelope('cells_command', admin.token, 'cells.create_cell', null,
      { name: `${NAME_PREFIX} Cell`, signup_label: `${NAME_PREFIX} Cell`, broad_area: 'SYNTHETIC North' });
    const cellId = cx.data?.cell_id;
    const option = ((await rpc('cells_signup_options', admin.token)).json?.options ?? []).find((o) => o.cell_id === cellId);
    const asked = await envelope('cells_command', admin.token, 'cells.request_change', 1,
      { cell_id: cellId, cell_revision: option?.revision, member_id: held.member });
    const confirmed = await envelope('cells_command', admin.token, 'cells.confirm_request', asked.revision,
      { request_id: asked.data?.open_request?.request_id });
    psql(`insert into app.fixture_duties (member_id, duty_kind) values ('${held.member}', 'fixture_door_duty')`);
    await twoDevices(held);
    const heldBefore = { facts: facts(held), mobile: (await summary(held.devices[0]?.access_token)).status,
      web: (await summary(held.devices[1]?.access_token)).status };
    const placed = await hold(admin.token, held, 'login_disabled');
    const heldDenied = await devicesDenied(held);
    const heldFresh = await fresh(held);
    const heldFreshSummary = await summary(heldFresh);
    const heldStatus = (await rpc('identity_my_membership_status', heldFresh)).json;
    const heldAfter = facts(held);
    check('L10-login-hold-denies-both-devices-and-keeps-facts', confirmed.status === 200 && Boolean(confirmed.data?.primary)
      && heldBefore.mobile === 200 && heldBefore.web === 200 && heldBefore.facts === 'approved|1|1'
      && placed.status === 200 && placed.data?.holds?.[0]?.reason_code === 'login_disabled'
      && placed.data?.holds?.[0]?.hold_kind === 'login'
      && heldDenied.every((d) => d.summary === 401 && d.refresh >= 400)
      && heldFreshSummary.status === 403 && heldFreshSummary.detail === 'review_required'
      && heldStatus?.deactivated === false && unexpectedStatusKeys(heldStatus).length === 0
      && heldAfter === heldBefore.facts && calls(held) === 'access_hold_applied,sessions_revoked',
      { cell_confirmed: Boolean(confirmed.data?.primary), before: heldBefore, hold: placed.data?.holds?.[0]?.hold_kind,
        devices_after_hold: heldDenied, fresh_sign_in: heldFreshSummary, own_status_deactivated: heldStatus?.deactivated,
        facts_after: heldAfter, lifecycle_hook_calls: calls(held) });
    const holdId = placed.data?.holds?.[0]?.hold_id;
    const selfRelease = await envelope('identity_credential_command', heldFresh, 'identity.release_hold', memberRev(held),
      { member_id: held.member, hold_id: holdId, identity_check: 'in_person' });
    const released = await envelope('identity_credential_command', admin2.token, 'identity.release_hold', memberRev(held),
      { member_id: held.member, hold_id: holdId, identity_check: 'in_person' });
    held.token = await fresh(held);
    const heldBack = await summary(held.token);
    check('L11-release-by-another-admin', selfRelease.code === 'forbidden' && released.status === 200
      && (released.data?.holds ?? []).length === 0 && heldBack.status === 200,
      { member_releases: selfRelease.code, release: released.code ?? 'ok', fresh_sign_in: heldBack.status });

    // ---------------------------------------------------------------------------- deactivation
    await seeded(leaving);
    const l0 = await rpc('identity_my_access', (await signIn(leaving.phone, leaving.password)).json?.access_token);
    const pastor = await envelope('identity_grant_command', admin.token, 'identity.grant_role', l0.json?.revision,
      { member_id: leaving.member, role: 'pastor' });
    psql(`insert into app.fixture_duties (member_id, duty_kind) values ('${leaving.member}', 'fixture_door_duty')`);
    // A pending staff-assisted recovery grant (2.9): the device's request (digest only), then the
    // Admin's case and grant through the API.
    const code = requestCode();
    const digest = createHash('sha256').update(`arg_${randomBytes(32).toString('base64url')}`).digest('hex');
    psql(`insert into app.identity_recovery_requests (request_code, claimed_phone, grant_digest, expires_at)
          values ('${code}', '${leaving.phone}', '${digest}', now() + interval '30 minutes')`);
    const opened = await envelope('identity_recovery_command', admin.token, 'identity.open_recovery_case', null,
      { member_id: leaving.member, identity_check: 'in_person', evidence: ['photo_id'] });
    const issued = await envelope('identity_recovery_command', admin.token, 'identity.issue_recovery_grant', opened.revision,
      { case_id: opened.data?.case_id, request_code: code });
    await twoDevices(leaving);
    const leavingBefore = [(await summary(leaving.devices[0]?.access_token)).status, (await summary(leaving.devices[1]?.access_token)).status];
    const memberTries = await lifecycle(held.token, 'identity.deactivate_membership', leaving, { reason_code: 'church_decision' });
    const deactivated = await lifecycle(admin.token, 'identity.deactivate_membership', leaving, { reason_code: 'member_request' });
    const leavingDenied = await devicesDenied(leaving);
    const leavingFresh = await fresh(leaving);
    const leavingSummary = await summary(leavingFresh);
    const leavingStatus = (await rpc('identity_my_membership_status', leavingFresh)).json;
    const grantsLeft = Number(psql(`select count(*) from app.identity_grants where member_id = '${leaving.member}' and revoked_at is null`));
    const caseRead = ((await rpc('identity_admin_recovery_cases', admin.token)).json?.cases ?? []).find((c) => c.case_id === opened.data?.case_id);
    const lifecycleRead = (await rpc('identity_admin_membership_lifecycle', admin.token)).json;
    const handover = (lifecycleRead?.handovers ?? []).find((h) => h.member_id === leaving.member);
    check('L20-deactivation-denies-records-handover-and-invalidates-grant', pastor.status === 200
      && issued.status === 200 && issued.data?.grant?.state === 'issued'
      && leavingBefore.every((s) => s === 200) && memberTries.code === 'forbidden'
      && deactivated.status === 200 && deactivated.data?.membership_state === 'deactivated'
      && leavingDenied.every((d) => d.summary === 401 && d.refresh >= 400)
      && leavingSummary.status === 403 && leavingSummary.detail === 'not_linked'
      && leavingStatus?.deactivated === true && unexpectedStatusKeys(leavingStatus).length === 0
      && grantsLeft === 0 && caseRead?.grant?.state === 'cancelled'
      && handover?.obligation_kind === 'fixture_door_duty' && handover?.owner_module === 'fixture'
      && (lifecycleRead?.deactivated ?? []).some((d) => d.member_id === leaving.member && d.reason_code === 'member_request')
      && calls(leaving) === 'scope_revoked,membership_deactivated,sessions_revoked',
      { grant_before: issued.data?.grant?.state, devices_before: leavingBefore, member_tries: memberTries.code,
        deactivate: deactivated.data?.membership_state, devices_after: leavingDenied, fresh_sign_in: leavingSummary,
        own_status: leavingStatus, grants_left: grantsLeft, recovery_grant_after: caseRead?.grant?.state ?? null,
        handover: { kind: handover?.obligation_kind, owner: handover?.owner_module },
        lifecycle_hook_calls: calls(leaving) });

    // ------------------------------------------------------------ last responsible person
    await seeded(sole);
    psql(`insert into app.fixture_duties (member_id, duty_kind, sole_responsible) values ('${sole.member}', 'fixture_custody', true)`);
    const refused = await lifecycle(admin.token, 'identity.deactivate_membership', sole, { reason_code: 'moved_away' });
    const soleSessions = Number(psql(`select count(*) from auth.sessions where user_id = '${sole.user}'`));
    const soleState = facts(sole);
    psql(`update app.fixture_duties set sole_responsible = false where member_id = '${sole.member}'`); // the owner handed over
    const accepted = await lifecycle(admin.token, 'identity.deactivate_membership', sole, { reason_code: 'moved_away' });
    check('L21-last-responsible-needs-a-handover', refused.code === 'conflict'
      && refused.field_errors?.member_id === 'handover_required' && soleState === 'approved|0|1'
      && accepted.status === 200 && accepted.data?.membership_state === 'deactivated',
      { first: { code: refused.code, field_errors: refused.field_errors }, unchanged: soleState, sessions_before: soleSessions,
        after_handover: accepted.data?.membership_state });

    // ------------------------------------------------------------------- reviewed restoration
    const noCheck = await lifecycle(admin2.token, 'identity.restore_membership', leaving, {});
    const restored = await lifecycle(admin2.token, 'identity.restore_membership', leaving, { identity_check: 'in_person' });
    const duringDeactivation = await summary(leavingFresh);
    const back = await fresh(leaving);
    const backSummary = await summary(back);
    const backAccess = (await rpc('identity_my_access', back)).json;
    const stillPending = ((await rpc('identity_admin_membership_lifecycle', admin.token)).json?.handovers ?? [])
      .some((h) => h.member_id === leaving.member);
    check('L30-reviewed-restoration', noCheck.code === 'validation_failed' && restored.status === 200
      && restored.data?.membership_state === 'approved' && duringDeactivation.status === 401
      && backSummary.status === 200 && (backAccess?.roles ?? []).length === 0 && stillPending
      && calls(leaving).endsWith('membership_restored'),
      { without_identity_check: noCheck.code, restore: restored.data?.membership_state,
        session_from_deactivation: duringDeactivation.status, fresh_sign_in: backSummary.status,
        roles_after: backAccess?.roles ?? null, handover_still_pending: stillPending });

    // ------------------------------------- the last two Admins deactivate each other at once
    // Two concurrent sessions (separate PostgREST transactions): the identity authorizer
    // serialises Admin commands, so exactly one succeeds and one usable Admin remains.
    const [aOnB, bOnA] = await Promise.all([
      lifecycle(admin.token, 'identity.deactivate_membership', admin2, { reason_code: 'church_decision' }),
      lifecycle(admin2.token, 'identity.deactivate_membership', admin, { reason_code: 'church_decision' }),
    ]);
    const outcomes = [aOnB, bOnA].map((r) => (r.status === 200 && !r.code ? 'ok' : r.code));
    const usable = Number(psql(`select app.identity_usable_admin_count()`));
    // The loser is refused either by the last-Admin rule (`forbidden`, when it reads before the
    // winner commits) or because the winner's deactivation already ended its own session
    // (`unauthenticated`, when the winner commits first). Both are fail-closed refusals.
    check('L40-concurrent-deactivation-of-the-last-two-admins', outcomes.filter((o) => o === 'ok').length === 1
      && outcomes.filter((o) => o === 'forbidden' || o === 'unauthenticated').length === 1 && usable === 1,
      { outcomes: outcomes.sort(), usable_admins_after: usable });

    const sms = (await http('GET', '/auth/v1/settings')).json?.sms_provider ?? null;
    check('L99-no-sms', !sms, { sms_provider: sms });
  } finally {
    unhook();
    const left = cleanup();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'identity-lifecycle-e2e';
            delete from app.platform_environment_history where set_by = 'identity-lifecycle-e2e';`);
    }
    log('L100-cleanup', { users_left: Number(left), unmarked: marked });
  }
  finish();
}

runMain(import.meta.url, main);
