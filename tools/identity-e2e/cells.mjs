#!/usr/bin/env node
// Story 2.6 end-to-end on the LOCAL stack: confirm and transfer primary cell membership through
// real GoTrue phone sign-in (no SMS, no email) and the real Data API (PostgREST), proving the
// staff-web verify bullet at the API level:
//   * an Admin sets up two SYNTHETIC cells and makes one leader per cell (identity.grant_scope
//     with the Cells-registered `cell_leader` kind);
//   * an applicant asks for cell X, the Admin approves church membership (no cell yet), and the
//     leader of X confirms the cell as its leader: X's private fixture surface opens;
//   * the member asks to move to Y; the leader of X cannot confirm it, the leader of Y does: the
//     API shows exactly one primary cell (Y), X's private surface is denied at once on the same
//     session, Y's opens, the SYNTHETIC `cell_transferred` hook ran in the confirming transaction
//     (the hook's own row carries the same writing (sub)transaction id, xmin, as the new and the
//     ended membership rows, and the same transaction start time) and church membership (member id,
//     state, revision, grants) is unchanged;
//   * a "not sure" applicant reaches the Admin follow-up queue (no leader sees it) and the Admin
//     confirms them into a cell; the audit is content-free.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first).
// LOCAL only (exact origin), SYNTHETIC fictional numbers +44 7700 900260-900269. Evidence is
// redacted JSONL: statuses, codes and revisions; never tokens, passwords or numbers. Every user,
// application, member, link, grant, cell, request, membership, audit row, receipt and the hook
// registration it created is removed.
//
// Usage: node tools/identity-e2e/cells.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { amrMethods, EPOCH_WAIT_MS, localHttp, localKey, password, psql, runMain, sleep, startRun } from './harness.mjs';

/** The reserved fictional numbers this run uses (+44 7700 900260-900269). */
export function isFictionalCellsPhone(phone) {
  return /^\+44770090026[0-9]$/.test(phone);
}

/** Exactly one current primary cell, and it is [cellId]. */
export function singlePrimary(myCell, cellId) {
  return Boolean(myCell?.primary) && myCell.primary.cell_id === cellId;
}

/** Two rows were written by the same (sub)transaction: equal, non-empty xmin values. */
export function sameTransaction(xminA, xminB) {
  if (xminA == null || xminB == null || xminA === '' || xminB === '') return false;
  return String(xminA) === String(xminB);
}

const NAME_PREFIX = 'SYNTHETIC 2.6 E2E';

async function main() {
  const { log, check, finish } = startRun();
  const keys = localKey();
  const http = localHttp(keys);
  const signUp = (phone, pw) => http('POST', '/auth/v1/signup', { body: { phone, password: pw } });
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const envelope = (fn, token, cmd, expected, payload, requestId = randomUUID()) =>
    rpc(fn, token, { version: 1, command: cmd, request_id: requestId, expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const cells = (token, cmd, expected, payload) => envelope('cells_command', token, cmd, expected, payload);
  const review = (token, cmd, expected, payload) => envelope('identity_review_command', token, cmd, expected, payload);
  const err = (r) => ({ status: r.status, code: r.json?.code ?? r.json?.message, detail: r.json?.details });
  const myCell = async (token) => (await rpc('cells_my_cell', token)).json;
  const privateRead = async (token, cellId) => {
    const r = await rpc('cells_private_fixture_read', token, { cell_id: cellId });
    return { status: r.status, detail: r.json?.details ?? null };
  };
  const summary = async (token) => {
    const r = await rpc('identity_my_member_summary', token);
    return { status: r.status, member_id: r.json?.member_id, membership_state: r.json?.membership_state };
  };

  const people = {
    admin: { phone: '+447700900260', name: `${NAME_PREFIX} Admin` },
    leaderX: { phone: '+447700900261', name: `${NAME_PREFIX} Leader X` },
    leaderY: { phone: '+447700900262', name: `${NAME_PREFIX} Leader Y` },
    member: { phone: '+447700900263', name: `${NAME_PREFIX} Moving Member` },
    unsure: { phone: '+447700900264', name: `${NAME_PREFIX} Not Sure` },
  };
  for (const p of Object.values(people)) if (!isFictionalCellsPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  const users = new Set();
  const digits = Object.values(people).map((p) => `'${p.phone.slice(1)}'`).join(',');
  const cleanup = () => {
    const ids = [...users].map((u) => `'${u}'`);
    const byUser = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    return psql(`
    delete from app.contract_lifecycle_hooks h where h.event = 'cell_transferred' and h.module = 'fixture';
    create temp table gone_users as select u.id from auth.users u where ${byUser} u.phone in (${digits});
    create temp table gone_members as
      select m.member_id from app.identity_members m where m.display_name like '${NAME_PREFIX}%';
    create temp table gone_cells as select c.cell_id from app.cells_cells c where c.name like '${NAME_PREFIX}%';
    create temp table gone_apps as
      select a.application_id from app.identity_membership_applications a
       where a.auth_user_id in (select id from gone_users) or a.full_name like '${NAME_PREFIX}%';
    delete from app.fixture_lifecycle_calls c where c.member_id in (select member_id from gone_members);
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
    delete from app.identity_membership_audit a
     where a.application_id in (select application_id from gone_apps)
        or a.member_id in (select member_id from gone_members)
        or a.actor_member_id in (select member_id from gone_members)
        or a.target_account_id in (select id from gone_users);
    delete from app.identity_member_provenance p
     where p.member_id in (select member_id from gone_members) or p.application_id in (select application_id from gone_apps);
    delete from app.identity_application_events e where e.application_id in (select application_id from gone_apps);
    delete from app.identity_membership_applications a where a.application_id in (select application_id from gone_apps);
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
    psql(`select app.platform_set_environment('local', 'identity-cells-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('C00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });
  if (Number(psql(`select app.identity_usable_admin_count()`)) !== 0) {
    throw new Error('the local database already has a usable Admin; run `npx supabase db reset` first');
  }

  try {
    const { admin, leaderX, leaderY, member, unsure } = people;

    // Staff accounts: synthetic phone accounts linked by the operator; the Admin is bootstrapped.
    for (const p of [admin, leaderX, leaderY]) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'identity-cells-e2e')`);
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}', 'israel')`);
    for (const p of [admin, leaderX, leaderY]) p.token = (await signIn(p.phone, p.password)).json?.access_token;
    const adminAccess = await rpc('identity_my_access', admin.token);
    check('C01-admin-signed-in-by-phone', amrMethods(admin.token).includes('password') && adminAccess.json?.roles?.includes('admin'),
      { amr: amrMethods(admin.token), roles: adminAccess.json?.roles });

    // ------------------------------------------------------------------ Admin cell setup + leaders
    const deniedSetup = await cells(leaderX.token, 'cells.create_cell', null,
      { name: `${NAME_PREFIX} Cell X`, signup_label: `${NAME_PREFIX} X`, broad_area: 'SYNTHETIC North' });
    const cx = await cells(admin.token, 'cells.create_cell', null,
      { name: `${NAME_PREFIX} Cell X`, signup_label: `${NAME_PREFIX} X`, broad_area: 'SYNTHETIC North' });
    const cy = await cells(admin.token, 'cells.create_cell', null,
      { name: `${NAME_PREFIX} Cell Y`, signup_label: `${NAME_PREFIX} Y`, broad_area: 'SYNTHETIC South' });
    const X = cx.data?.cell_id;
    const Y = cy.data?.cell_id;
    check('C10-admin-creates-cells', deniedSetup.code === 'forbidden' && Boolean(X) && Boolean(Y) && cx.data?.listed === true,
      { non_admin: deniedSetup.code, created: [cx.revision, cy.revision], listed: cx.data?.listed });
    const grantLeader = async (p, cellId) => {
      const mine = await rpc('identity_my_access', p.token);
      return envelope('identity_grant_command', admin.token, 'identity.grant_scope', mine.json?.revision,
        { member_id: p.member, scope_kind: 'cell_leader', scope_id: cellId });
    };
    const gx = await grantLeader(leaderX, X);
    const gy = await grantLeader(leaderY, Y);
    const xAccess = await rpc('identity_my_access', leaderX.token);
    check('C11-leaders-are-scope-grants', gx.status === 200 && gy.status === 200
      && xAccess.json?.scopes?.some((s) => s.scope_kind === 'cell_leader' && s.scope_id === X),
      { grant_x: gx.code ?? gx.revision, grant_y: gy.code ?? gy.revision, leader_x_scopes: xAccess.json?.scopes?.map((s) => s.scope_kind) });

    // ------------------------------------------------- application with cell X, church approval
    const signUpApplicant = async (p) => {
      p.password = password();
      const up = await signUp(p.phone, p.password);
      p.token = up.json?.access_token;
      p.user = up.json?.user?.id;
      if (p.user) users.add(p.user);
      return up;
    };
    await signUpApplicant(member);
    const options = (await rpc('cells_signup_options', member.token)).json?.options ?? [];
    const optX = options.find((o) => o.cell_id === X);
    const sent = await envelope('identity_application_command', member.token, 'identity.submit_application', null, {
      full_name: member.name, cell_choice: { choice: 'cell', cell_id: X, cell_revision: optX?.revision },
      privacy_notice_version: 'draft-2026-10-07' });
    const approved = await review(admin.token, 'identity.approve_application', sent.revision,
      { application_id: sent.data?.application_id, identity_check: 'in_person' });
    member.member = approved.data?.member_id;
    await sleep(EPOCH_WAIT_MS);
    member.token = (await signIn(member.phone, member.password)).json?.access_token;
    const mine0 = await myCell(member.token);
    check('C20-church-approval-is-not-cell-confirmation', Boolean(optX) && sent.data?.cell_status === 'requested'
      && approved.data?.church_status === 'approved' && mine0?.primary === null
      && mine0?.open_request?.state === 'pending' && mine0?.open_request?.cell_id === X,
      { chooser_lists_x: Boolean(optX), church_status: approved.data?.church_status, primary: mine0?.primary ?? null,
        open_request: { state: mine0?.open_request?.state, kind: mine0?.open_request?.kind, origin: mine0?.open_request?.origin } });

    // ---------------------------------------------------------- the leader of X confirms the cell
    const qx = (await rpc('cells_leader_queue', leaderX.token)).json;
    const qy = (await rpc('cells_leader_queue', leaderY.token)).json;
    const reqX = qx?.cells?.find((c) => c.cell_id === X)?.requests?.find((r) => r.member_id === member.member);
    const before = await privateRead(member.token, X);
    check('C21-leader-sees-request-for-own-cell-only', Boolean(reqX) && reqX.kind === 'join'
      && !(qy?.cells?.flatMap((c) => c.requests) ?? []).some((r) => r.member_id === member.member)
      && before.status === 403 && before.detail === 'not_granted',
      { leader_x_request: reqX?.kind, leader_y_sees_it: (qy?.cells?.flatMap((c) => c.requests) ?? []).length, private_x_before: before });
    const wrongLeader = await cells(leaderY.token, 'cells.confirm_request', reqX?.member_revision, { request_id: reqX?.request_id });
    const confirmed = await cells(leaderX.token, 'cells.confirm_request', reqX?.member_revision, { request_id: reqX?.request_id });
    const px1 = await privateRead(member.token, X);
    const py1 = await privateRead(member.token, Y);
    check('C22-leader-confirms-cell', wrongLeader.code === 'forbidden' && confirmed.status === 200
      && singlePrimary(confirmed.data, X) && px1.status === 200 && py1.status === 403,
      { other_leader: wrongLeader.code, primary_is_x: singlePrimary(confirmed.data, X), private_x: px1.status, private_y: py1.status });

    // --------------------------------------------------------------- change request and transfer
    const mine1 = await myCell(member.token);
    const optY = ((await rpc('cells_signup_options', member.token)).json?.options ?? []).find((o) => o.cell_id === Y);
    const asked = await cells(member.token, 'cells.request_change', mine1?.revision, { cell_id: Y, cell_revision: optY?.revision });
    const pyAsked = await privateRead(member.token, Y);
    check('C30-member-requests-change', asked.status === 200 && asked.data?.open_request?.kind === 'change'
      && singlePrimary(asked.data, X) && pyAsked.status === 403,
      { kind: asked.data?.open_request?.kind, still_in_x: singlePrimary(asked.data, X), private_y_while_requested: pyAsked.status });

    psql(`select app.contract_register_lifecycle_hook('fixture', 'cell_transferred', 'app.fixture_record_lifecycle(jsonb)'::regprocedure)`);
    const church0 = await summary(member.token);
    const grants0 = (await rpc('identity_my_access', member.token)).json?.revision;
    const memberRev0 = psql(`select revision || ':' || membership_state from app.identity_members where member_id = '${member.member}'`);
    const reqY = (await rpc('cells_leader_queue', leaderY.token)).json?.cells?.find((c) => c.cell_id === Y)?.requests
      ?.find((r) => r.member_id === member.member);
    const oldLeader = await cells(leaderX.token, 'cells.confirm_request', reqY?.member_revision, { request_id: reqY?.request_id });
    const moved = await cells(leaderY.token, 'cells.confirm_request', reqY?.member_revision, { request_id: reqY?.request_id });
    const px2 = await privateRead(member.token, X);
    const py2 = await privateRead(member.token, Y);
    const mine2 = await myCell(member.token);
    const current = psql(`select count(*) from app.cells_memberships where member_id = '${member.member}' and ended_at is null`);
    const ended = psql(`select coalesce(string_agg(end_reason, ','), '') from app.cells_memberships where member_id = '${member.member}' and ended_at is not null`);
    check('C31-new-leader-confirms-transfer', oldLeader.code === 'forbidden' && moved.status === 200 && singlePrimary(moved.data, Y),
      { old_cell_leader: oldLeader.code, primary_is_y: singlePrimary(moved.data, Y), revision: moved.revision });
    check('C32-one-primary-old-denied-new-opens', singlePrimary(mine2, Y) && mine2?.open_request === null && current === '1'
      && ended === 'transferred' && px2.status === 403 && px2.detail === 'not_granted' && py2.status === 200,
      { primary_is_y: singlePrimary(mine2, Y), current_primary_rows: Number(current), old_membership: ended,
        private_x_same_session: px2, private_y: py2.status });
    const hook = psql(`select coalesce(string_agg(c.event || ':' || c.identity_revision || ':' || c.xmin::text || ':' || m.xmin::text || ':' || o.xmin::text || ':' || (c.called_at = m.started_at)::text, ','), '')
      from app.fixture_lifecycle_calls c
      join app.cells_memberships m on m.member_id = c.member_id and m.ended_at is null
      join app.cells_memberships o on o.member_id = c.member_id and o.ended_at is not null
     where c.member_id = '${member.member}'`);
    const [event, hookRevision, hookXmin, newXmin, oldXmin, sameStart] = hook.split(':');
    check('C33-transfer-hook-ran-in-same-transaction', hook.split(',').length === 1 && event === 'cell_transferred'
      && Number(hookRevision) === moved.revision && sameTransaction(hookXmin, newXmin) && sameTransaction(hookXmin, oldXmin)
      && sameStart === 'true',
      { calls: hook ? hook.split(',').length : 0, event, hook_revision: Number(hookRevision), cells_revision: moved.revision,
        same_transaction_as_new_row: sameTransaction(hookXmin, newXmin), same_transaction_as_ended_row: sameTransaction(hookXmin, oldXmin),
        same_transaction_start_time: sameStart === 'true' });
    const church1 = await summary(member.token);
    const grants1 = (await rpc('identity_my_access', member.token)).json?.revision;
    const memberRev1 = psql(`select revision || ':' || membership_state from app.identity_members where member_id = '${member.member}'`);
    check('C34-church-membership-unchanged', church0.status === 200 && church1.status === 200
      && church1.member_id === church0.member_id && church1.member_id === member.member
      && church1.membership_state === 'approved' && memberRev1 === memberRev0 && grants1 === grants0,
      { member_id_kept: church1.member_id === member.member, membership_state: church1.membership_state,
        member_revision_kept: memberRev1 === memberRev0, grants_revision_kept: grants1 === grants0 });

    // ----------------------------------------------------------------- the Admin follow-up queue
    await signUpApplicant(unsure);
    const sentU = await envelope('identity_application_command', unsure.token, 'identity.submit_application', null,
      { full_name: unsure.name, cell_choice: { choice: 'not_sure' }, privacy_notice_version: 'draft-2026-10-07' });
    const approvedU = await review(admin.token, 'identity.approve_application', sentU.revision,
      { application_id: sentU.data?.application_id, identity_check: 'established_relationship' });
    unsure.member = approvedU.data?.member_id;
    const overview = (await rpc('cells_admin_overview', admin.token)).json;
    const follow = overview?.requests?.find((r) => r.member_id === unsure.member);
    const leaderCells = [
      ...((await rpc('cells_leader_queue', leaderX.token)).json?.cells ?? []),
      ...((await rpc('cells_leader_queue', leaderY.token)).json?.cells ?? []),
    ];
    const leaderSees = leaderCells.flatMap((c) => c.requests).some((r) => r.member_id === unsure.member);
    const leaderOverview = await rpc('cells_admin_overview', leaderX.token);
    const resolved = await cells(admin.token, 'cells.confirm_request', follow?.member_revision, { request_id: follow?.request_id, cell_id: X });
    check('C40-admin-follow-up-queue', follow?.follow_up === true && follow?.choice === 'not_sure' && !leaderSees
      && leaderOverview.status === 403 && resolved.status === 200 && singlePrimary(resolved.data, X),
      { follow_up: follow?.follow_up, choice: follow?.choice, any_leader_sees_it: leaderSees, leader_reads_overview: err(leaderOverview),
        admin_resolved_into_x: singlePrimary(resolved.data, X) });

    // -------------------------------------------------------------------------- audit content
    const auditText = psql(`select coalesce(string_agg(a::text, ' '), '') from app.cells_membership_audit a`);
    const leaked = [...Object.values(people).map((p) => p.phone.slice(1)), ...Object.values(people).map((p) => p.name), NAME_PREFIX]
      .filter((v) => auditText.includes(v));
    check('C50-audit-content-free', leaked.length === 0 && auditText.length > 0, { leaked_values: leaked.length,
      actions: psql(`select string_agg(distinct action, ',' order by action) from app.cells_membership_audit`) });
  } finally {
    const left = cleanup();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'identity-cells-e2e';
            delete from app.platform_environment_history where set_by = 'identity-cells-e2e';`);
    }
    log('C99-cleanup', { users_left: Number(left), unmarked: marked,
      hooks_left: Number(psql(`select count(*) from app.contract_lifecycle_hooks where event = 'cell_transferred'`)) });
  }
  finish();
}

runMain(import.meta.url, main);
