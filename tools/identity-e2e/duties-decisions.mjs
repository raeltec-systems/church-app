#!/usr/bin/env node
// Story 4.16 end-to-end on the LOCAL stack: the owner's epic 4 decisions through real GoTrue phone
// sign-in (no SMS), the real Data API (PostgREST) and the real worker script
// (tools/notifications/worker.mjs):
//   * item 7: a change to a SYNTHETIC event linked to department duties flags them for review and
//     sends one "Duty needs review" notice per department and change to each reachable leader and
//     deputy (a held deputy and the Admin role alone get none); the worker delivers it; a second
//     change sends a fresh one; with the Q2 policy unavailable the flags are kept and the notice is
//     skipped and audited;
//   * item 8: a member removed from the department leaves a vacated position whose coarse reason
//     only the department's leaders and deputies read (coverage queue and board); the Admin role
//     alone and another department's leader read none;
//   * item 10: revoking the scope of a department's last reachable leader or deputy is refused
//     `handover_required` (nothing changes) until another reachable leader is granted, and a
//     deputy may go while the leader stays.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900720-900729. Evidence is redacted JSONL:
// statuses, codes, counts and states; never tokens, passwords, numbers, the credential or names.
// Every user, member, grant, department, duty, flag, event, job, item and receipt it created is
// removed; the run's credential is revoked and its principal disabled; the Q2 fixture zone is
// restored.
//
// Usage: node tools/identity-e2e/duties-decisions.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';
import { jsonLiteral, notificationsWorker, sessionClaims } from './duties-shared.mjs';

export { jsonLiteral, sessionClaims } from './duties-shared.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 4.16 E2E';
export const DEPARTMENT = 'SYNTHETIC Preaching Rota';
export const OTHER_DEPARTMENT = 'SYNTHETIC 4.16 E2E Ushers';
/** The coarse vacancy reason codes (story 4.16); never free text. */
export const VACANCY_REASONS = ['removed_from_department', 'member_inactive', 'member_deleted'];
/** The review notice's fixed contract (generic text, deep link to the board's reviews). */
export const REVIEW_NOTICE = { title: 'Duty needs review', link: '/duties/leader/reviews' };

/** The reserved fictional numbers this run uses (+44 7700 900720-900729). */
export function isFictionalDecisionsPhone(phone) {
  return /^\+44770090072[0-9]$/.test(phone);
}

/** A command answer that went through (no refusal code). */
export function done(r) {
  return r?.status === 200 && !r.code;
}

/** A refusal with this code and, when given, this field error. */
export function refused(r, code, field, value) {
  return r?.code === code && (!field || r.field_errors?.[field] === value);
}

/** The coverage position of a slot. */
export function coveragePosition(answer, slotId) {
  for (const d of answer?.departments ?? []) {
    for (const p of d.positions ?? []) if (p.slot_id === slotId) return p;
  }
  return null;
}

/** The newest history entry of an occurrence's (only) position on the leader board. */
export function boardHistory(board, occurrenceId) {
  for (const d of board?.departments ?? []) {
    for (const o of d.duties ?? []) {
      if (o.occurrence_id !== occurrenceId) continue;
      const h = o.positions?.[0]?.history ?? [];
      return [...h].sort((a, b) => String(b.ended_at).localeCompare(String(a.ended_at)))[0] ?? null;
    }
  }
  return null;
}

/** Is a value one of the coarse reason codes (or null: not shown)? Anything else is a leak. */
export function coarseOrNull(value) {
  return value === null || value === undefined || VACANCY_REASONS.includes(value);
}

/** The ISO start of church date `ymd` at 10:00 Africa/Lusaka (UTC+2, no daylight saving). */
export function churchTen(ymd) {
  return `${ymd}T08:00:00Z`;
}

/** One SQL text that runs an owner operation as the caller (their session claims). */
export function ownerCallSql(claims, fn, input) {
  if (!/^[a-z_]+$/.test(fn)) throw new Error('unexpected function name');
  return `begin;
do $d$ begin perform set_config('request.jwt.claims', ${jsonLiteral(claims).replace('::jsonb', '')}, true); end $d$;
create function pg_temp.try(p_fn text, p_input jsonb) returns jsonb language plpgsql as $f$
declare r jsonb; v_state text; v_msg text; v_detail text;
begin
  begin
    execute format('select app.%I($1)', p_fn) into r using p_input;
    return r;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail;
    if v_state = 'PCMD1' then return jsonb_build_object('code', v_msg) || coalesce(v_detail::jsonb, '{}'::jsonb); end if;
    return jsonb_build_object('sqlstate', v_state);
  end;
end $f$;
select pg_temp.try('${fn}', ${jsonLiteral(input)});
commit;`;
}

/** The first JSON line of psql's output. */
export function firstJson(out) {
  const line = String(out).split('\n').find((l) => l.trim().startsWith('{'));
  return line ? JSON.parse(line) : null;
}

async function main() {
  const { log, check, finish } = startRun();
  const keys = localKey();
  const { origin, key } = keys;
  const http = localHttp(keys);
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const read = async (fn, token, body = {}) => (await rpc(fn, token, body)).json;
  const envelope = (fn, token, cmd, expected, payload) =>
    rpc(fn, token, { version: 1, command: cmd, request_id: randomUUID(), expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const duty = (token, cmd, expected, payload) => envelope('duties_command', token, cmd, expected, payload);
  const owner = (p, fn, input) => firstJson(psql(ownerCallSql(sessionClaims(p.token), fn, input)));
  const HOUR = 3_600_000;
  const DAY = 24 * HOUR;
  const churchDate = (ms) => new Date(Date.now() + ms + 2 * HOUR).toISOString().slice(0, 10);

  const people = {
    admin: { phone: '+447700900720', name: `${NAME_PREFIX} Admin` },
    leader: { phone: '+447700900721', name: `${NAME_PREFIX} Leader L` },
    deputy: { phone: '+447700900722', name: `${NAME_PREFIX} Deputy P` },
    held: { phone: '+447700900723', name: `${NAME_PREFIX} Deputy H` },
    sole: { phone: '+447700900724', name: `${NAME_PREFIX} Leader K` },
    member: { phone: '+447700900725', name: `${NAME_PREFIX} Member M` },
    spare: { phone: '+447700900726', name: `${NAME_PREFIX} Member J` },
  };
  for (const p of Object.values(people)) if (!isFictionalDecisionsPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  const users = new Set();
  const digits = Object.values(people).map((p) => `'${p.phone.slice(1)}'`).join(',');
  const cleanup = () => {
    const ids = [...users].map((u) => `'${u}'`);
    const byUser = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    return psql(`
    create temp table gone_users as select u.id from auth.users u where ${byUser} u.phone in (${digits});
    create temp table gone_members as
      select m.member_id from app.identity_members m where m.display_name like '${NAME_PREFIX}%';
    create temp table gone_departments as
      select d.department_id from app.duties_departments d where d.name in ('${DEPARTMENT}', '${OTHER_DEPARTMENT}');
    create temp table gone_occurrences as
      select o.occurrence_id from app.duties_occurrences o where o.department_id in (select department_id from gone_departments);
    create temp table gone_assignments as
      select a.assignment_id from app.duties_assignments a join app.duties_slots s on s.slot_id = a.slot_id
       where s.occurrence_id in (select occurrence_id from gone_occurrences);
    create temp table gone_flags as
      select f.flag_id from app.duties_review_flags f where f.occurrence_id in (select occurrence_id from gone_occurrences);
    create temp table gone_jobs as
      select j.job_id from app.notifications_jobs j
       where j.recipient_member_id in (select member_id from gone_members)
          or j.source_id in (select assignment_id from gone_assignments)
          or j.source_id in (select flag_id from gone_flags);
    delete from app.notifications_push_jobs p where p.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_attempts a where a.job_id in (select job_id from gone_jobs);
    delete from app.notifications_direct_contact_needs n where n.job_id in (select job_id from gone_jobs);
    update app.notifications_jobs j set snoozed_from_item_id = null where j.job_id in (select job_id from gone_jobs);
    delete from app.notifications_inbox_items i where i.job_id in (select job_id from gone_jobs)
       or i.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_jobs j where j.job_id in (select job_id from gone_jobs);
    delete from app.notifications_schedules s where s.source_id in (select assignment_id from gone_assignments)
       or s.recipient_member_id in (select member_id from gone_members);
    delete from app.duties_contact_attempts t where t.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_coverage_cases c where c.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_contact_needs n where n.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_audit a where a.department_id in (select department_id from gone_departments)
       or a.occurrence_id in (select occurrence_id from gone_occurrences)
       or a.actor_member_id in (select member_id from gone_members) or a.member_id in (select member_id from gone_members);
    delete from app.duties_slot_revisions r where r.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_assignments a where a.assignment_id in (select assignment_id from gone_assignments);
    -- Review flags go with their occurrences (the only way they are removed).
    delete from app.duties_slots s where s.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_occurrences o where o.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_department_members dm where dm.department_id in (select department_id from gone_departments);
    delete from app.fixture_events e where e.title like '${NAME_PREFIX}%';
    delete from app.identity_handover_obligations o where o.member_id in (select member_id from gone_members);
    delete from app.identity_access_audit a
     where a.target_member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_grants g where g.member_id in (select member_id from gone_members)
       or g.scope_id in (select department_id from gone_departments);
    delete from app.duties_departments d where d.department_id in (select department_id from gone_departments);
    delete from app.identity_contact_routes r where r.member_id in (select member_id from gone_members);
    delete from app.identity_grant_sets s where s.member_id in (select member_id from gone_members);
    delete from app.identity_holds h where h.member_id in (select member_id from gone_members);
    delete from app.identity_credential_review_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_binding_history h using app.identity_account_links l
     where h.link_id = l.link_id and (l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users));
    delete from app.identity_credential_events e using app.identity_account_links l
     where e.link_id = l.link_id and (l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users));
    delete from app.identity_account_links l
     where l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users);
    delete from app.identity_members m where m.member_id in (select member_id from gone_members);
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
    psql(`select app.platform_set_environment('local', 'duties-decisions-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('D00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  const run = randomUUID().slice(0, 8);
  const { principal, credentialId, worker } = notificationsWorker({ origin, key, operator: OPERATOR,
    principalName: `notifications-worker-decisions-${run}`, label: `duties decisions e2e ${run}` });
  const zone = psql(`select fixture_value ->> 'zone' from app.policy_gates where gate = 'q2_church_time'`);
  const setZone = (z) => psql(`update app.policy_gates set fixture_value = fixture_value || jsonb_build_object('zone', '${z}')
    where gate = 'q2_church_time'`);
  const grantRevision = (m) => Number(psql(`select revision from app.identity_grant_sets where member_id = '${m}'`));
  const departmentRevision = (d) => Number(psql(`select revision from app.duties_departments where department_id = '${d}'`));
  const occRevision = (o) => Number(psql(`select revision from app.duties_occurrences where occurrence_id = '${o}'`));
  const slotOf = (id) => psql(`select slot_id from app.duties_assignments where assignment_id = '${id}'`);
  const holds = (m, kind, scope) => psql(`select exists (select 1 from app.identity_grants where member_id = '${m}'
    and scope_kind = '${kind}' and scope_id = '${scope}' and revoked_at is null)`) === 't';
  const notices = (m) => Number(psql(`select count(*) from app.notifications_jobs where recipient_member_id = '${m}'
    and source_type = 'duties_review' and reminder_kind = 'duty_review_flagged'`));
  const revoke = (p, kind, scope) => envelope('identity_grant_command', people.admin.token, 'identity.revoke_scope',
    grantRevision(p.member), { member_id: p.member, scope_kind: kind, scope_id: scope });
  const grant = (p, kind, scope) => envelope('identity_grant_command', people.admin.token, 'identity.grant_scope',
    grantRevision(p.member), { member_id: p.member, scope_kind: kind, scope_id: scope });

  try {
    const { admin, leader, deputy, held, sole, member, spare } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'duties-decisions-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    check('D01-members-signed-in-by-phone', Object.values(people).every((p) => amrMethods(p.token).includes('password')),
      { amr: amrMethods(admin.token) });

    // ------------------------------------------------------- setup
    const dept = await duty(admin.token, 'duties.create_department', null, { name: DEPARTMENT });
    const dept2 = await duty(admin.token, 'duties.create_department', null, { name: OTHER_DEPARTMENT });
    const departmentId = dept.data?.department_id;
    const otherId = dept2.data?.department_id;
    const setup = [];
    for (const [p, kind, d] of [[leader, 'department_leader', departmentId], [deputy, 'department_deputy', departmentId],
      [held, 'department_deputy', departmentId], [sole, 'department_leader', otherId]]) {
      setup.push((await grant(p, kind, d)).code ?? 'done');
    }
    for (const [m, d] of [[leader.member, departmentId], [member.member, departmentId], [sole.member, otherId]]) {
      setup.push((await duty(admin.token, 'duties.add_member', departmentRevision(d), { department_id: d, member_id: m })).code ?? 'done');
    }
    setup.push((await envelope('identity_credential_command', admin.token, 'identity.place_hold',
      Number(psql(`select revision from app.identity_members where member_id = '${held.member}'`)),
      { member_id: held.member, reason_code: 'login_disabled' })).code ?? 'done');
    for (const p of [leader, deputy, sole]) p.token = (await signIn(p.phone, p.password)).json?.access_token;
    psql(`select app.contract_register_source_type('fixture', 'fixture_event', 'app.fixture_event_check(jsonb)'::regprocedure)
           where not exists (select 1 from app.contract_source_types where source_type = 'fixture_event');
          select app.duties_register_link_source('fixture', 'fixture_event', 'event')
           where not exists (select 1 from app.duties_link_sources where source_type = 'fixture_event');`);
    const eventId = psql(`insert into app.fixture_events (title) values ('${NAME_PREFIX} Event') returning event_id`);
    const publish = async (who, days, by = leader, d = departmentId) => duty(by.token, 'duties.publish_duty', null, {
      department_id: d, member_id: who, duty_name: `Duty ${days}`, location: 'SYNTHETIC hall',
      starts_at: churchTen(churchDate(days * DAY)) });
    const pubs = { EV1: await publish(member.member, 10), EV2: await publish(member.member, 11),
      EV3: await publish(sole.member, 12, sole, otherId), VR: await publish(member.member, 13) };
    const occ = Object.fromEntries(Object.entries(pubs).map(([k, r]) => [k, r.data?.occurrence_id]));
    const asg = Object.fromEntries(Object.entries(pubs).map(([k, r]) => [k, r.data?.assignment_id]));
    for (const [k, by] of [['EV1', leader], ['EV2', leader], ['EV3', sole]]) {
      setup.push((await duty(by.token, 'duties.revise_duty', occRevision(occ[k]), { occurrence_id: occ[k], event_ref: eventId })).data?.change
        ?? 'refused');
    }
    check('D02-departments-leaders-hold-and-linked-duties', done(dept) && done(dept2)
      && setup.every((s) => s === 'done' || s === 'reference') && Object.values(pubs).every(done),
      { setup, published: Object.values(pubs).map((r) => r.code ?? 'done') });

    // ------------------------------------------------------- item 7: the mismatch notice
    const flag1 = owner(admin, 'fixture_event_changed', { event_id: eventId, changed: ['time'] });
    const counts1 = [leader, deputy, sole, held, admin, member].map((p) => notices(p.member));
    check('D10-one-review-notice-per-department-to-reachable-leaders-and-deputies', flag1?.flagged === 3
      && JSON.stringify(counts1) === JSON.stringify([1, 1, 1, 0, 0, 0])
      && Number(psql(`select count(distinct source_id) from app.notifications_jobs where source_type = 'duties_review'
           and recipient_member_id in ('${leader.member}', '${deputy.member}')`)) === 1,
      { flagged: flag1?.flagged ?? flag1?.code ?? null, notices: { leader: counts1[0], deputy: counts1[1], other_department_leader: counts1[2],
        held_deputy: counts1[3], admin_role_alone: counts1[4], member: counts1[5] } });
    const runA = await worker();
    const dInbox = ((await read('notifications_my_inbox', deputy.token))?.items ?? []).filter((i) => i.reminder_kind === 'duty_review_flagged');
    const contract = psql(`select title || '|' || link from app.contract_reminder_contracts
      where source_type = 'duties_review' and reminder_kind = 'duty_review_flagged'`);
    const board = await read('duties_leader_board', deputy.token);
    const reviewsOpen = (board?.departments ?? []).flatMap((d) => d.duties ?? []).filter((o) => (o.reviews ?? []).length > 0).length;
    check('D11-the-worker-delivers-the-generic-notice-with-its-deep-link', runA.exit === 0 && dInbox.length === 1
      && dInbox[0]?.title === REVIEW_NOTICE.title && contract === `${REVIEW_NOTICE.title}|${REVIEW_NOTICE.link}` && reviewsOpen === 2
      && !JSON.stringify(dInbox).includes(NAME_PREFIX),
      { worker: runA.exit, deputy_items: dInbox.length, title: dInbox[0]?.title ?? null, link: contract.split('|')[1] ?? null,
        board_duties_to_review: reviewsOpen });
    const flag2 = owner(admin, 'fixture_event_changed', { event_id: eventId, changed: ['place'] });
    const counts2 = [leader, deputy, sole, held].map((p) => notices(p.member));
    check('D12-a-second-change-sends-a-fresh-notice-per-department', flag2?.flagged === 3
      && JSON.stringify(counts2) === JSON.stringify([2, 2, 2, 0]),
      { flagged: flag2?.flagged ?? null, notices: counts2 });
    setZone('Mars/Base');
    const before3 = Number(psql(`select count(*) from app.notifications_jobs where source_type = 'duties_review'`));
    const flag3 = owner(admin, 'fixture_event_changed', { event_id: eventId, changed: ['label'] });
    const after3 = Number(psql(`select count(*) from app.notifications_jobs where source_type = 'duties_review'`));
    const skipped = Number(psql(`select count(*) from app.duties_audit where action = 'reminders_skipped'
      and code = 'policy_unavailable' and department_id in ('${departmentId}', '${otherId}')`));
    setZone(zone);
    check('D13-q2-closed-keeps-the-flags-and-audits-the-skipped-notice', flag3?.flagged === 3 && after3 === before3 && skipped === 2,
      { flagged: flag3?.flagged ?? null, notices_added: after3 - before3, skipped_audits: skipped });

    // ------------------------------------------------------- item 8: the vacancy reason
    const removed = await duty(admin.token, 'duties.remove_member', departmentRevision(departmentId),
      { department_id: departmentId, member_id: member.member });
    const from = churchDate(9 * DAY);
    const to = churchDate(15 * DAY);
    const cov = (p) => read('duties_coverage', p.token, { from_date: from, to_date: to });
    const slot = slotOf(asg.VR);
    const reasonFor = async (p) => (coveragePosition(await cov(p), slot)?.vacated?.reason ?? null);
    const reasons = { leader: await reasonFor(leader), deputy: await reasonFor(deputy), admin: await reasonFor(admin) };
    const otherSees = coveragePosition(await cov(sole), slot);
    const lHist = boardHistory(await read('duties_leader_board', leader.token), occ.VR);
    const aHist = boardHistory(await read('duties_leader_board', admin.token), occ.VR);
    check('D20-the-vacancy-reason-reaches-only-the-departments-leaders-and-deputies', done(removed)
      && reasons.leader === 'removed_from_department' && reasons.deputy === 'removed_from_department' && reasons.admin === null
      && otherSees === null && lHist?.vacancy_reason === 'removed_from_department' && aHist?.end_reason === 'vacated'
      && aHist?.vacancy_reason === null && [reasons.leader, reasons.deputy, reasons.admin].every(coarseOrNull),
      { removed: removed.code ?? 'done', coverage_reason: reasons, other_department_leader_sees_position: otherSees !== null,
        board_reason_leader: lHist?.vacancy_reason ?? null, board_reason_admin: aHist?.vacancy_reason ?? null });

    // ------------------------------------------------------- item 10: last-leader protection on revocation
    const kRevision = grantRevision(sole.member);
    const refusedK = await revoke(sole, 'department_leader', otherId);
    check('D30-revoking-the-last-reachable-leader-is-refused-until-handover', refused(refusedK, 'conflict', 'member_id', 'handover_required')
      && holds(sole.member, 'department_leader', otherId) && grantRevision(sole.member) === kRevision,
      { revoke: refusedK.code ?? 'done', field: refusedK.field_errors?.member_id ?? null, still_holds: holds(sole.member, 'department_leader', otherId),
        revision_unchanged: grantRevision(sole.member) === kRevision });
    const granted = await grant(spare, 'department_leader', otherId);
    const allowedK = await revoke(sole, 'department_leader', otherId);
    check('D31-with-another-reachable-leader-the-revocation-is-allowed', done(granted) && done(allowedK)
      && !holds(sole.member, 'department_leader', otherId),
      { leader_given: granted.code ?? 'done', revoke: allowedK.code ?? 'done', still_holds: holds(sole.member, 'department_leader', otherId) });
    const deputyGone = await revoke(deputy, 'department_deputy', departmentId);
    const leaderKept = await revoke(leader, 'department_leader', departmentId);
    check('D32-a-deputy-may-go-while-the-leader-stays-the-last-may-not', done(deputyGone)
      && refused(leaderKept, 'conflict', 'member_id', 'handover_required') && holds(leader.member, 'department_leader', departmentId),
      { deputy_revoke: deputyGone.code ?? 'done', last_leader_revoke: leaderKept.code ?? 'done',
        held_deputy_counts: false, leader_still_holds: holds(leader.member, 'department_leader', departmentId) });

    // ------------------------------------------------------- tables refused
    const tableQuery = (await http('GET', '/rest/v1/duties_review_flags?select=*', { token: leader.token, profile: 'app' })).status;
    check('D90-tables-refused', tableQuery >= 400, { table_query: tableQuery });
  } finally {
    setZone(zone || 'Africa/Lusaka');
    const left = cleanup();
    psql(`select app.sys_revoke_credential('${credentialId}', '${OPERATOR}'); select app.sys_disable_principal('${principal}', '${OPERATOR}');`);
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'duties-decisions-e2e';
            delete from app.platform_environment_history where set_by = 'duties-decisions-e2e';`);
    }
    log('D99-cleanup', { users_left: Number(left), credential_revoked: true, principal_disabled: true, unmarked: marked,
      departments_left: Number(psql(`select count(*) from app.duties_departments where name in ('${DEPARTMENT}', '${OTHER_DEPARTMENT}')`)),
      members_left: Number(psql(`select count(*) from app.identity_members where display_name like '${NAME_PREFIX}%'`)),
      events_left: Number(psql(`select count(*) from app.fixture_events where title like '${NAME_PREFIX}%'`)) });
  }
  finish();
}

runMain(import.meta.url, main);
