#!/usr/bin/env node
// Story 4.5 end-to-end on the LOCAL stack: answering from My duties with a later decline and bulk
// acceptance, through real GoTrue phone sign-in (no SMS) and the real Data API (PostgREST),
// proving the ticket's verify at the API level:
//   * accept, decline and "Can't make it anymore" (duties.withdraw_acceptance) each change the
//     leader board at once (the later decline keeps the earlier acceptance time; confirmed drops);
//   * bulk acceptance (duties.accept_many) of three of four listed dates records exactly three;
//     a timeout retried under the same request id returns the stored result and records nothing
//     new; a selection with a date that changed is refused whole (nothing accepted);
//   * a real race: the member accepts three dates together while a leader moves one of them; in
//     every round either all three were accepted (and the moved one is asked again) or none was;
//     never a partial acceptance;
//   * refusals: someone else's assignment, a cell-owned (SYNTHETIC fixture) assignment, direct
//     table queries; receipts and audit rows hold no note text.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900560-900569. Evidence is redacted JSONL:
// statuses, codes, counts; never tokens, passwords or numbers. Everything it created is removed.
//
// Usage: node tools/identity-e2e/duties-responses.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';

const NAME_PREFIX = 'SYNTHETIC 4.5 E2E';
export const DEPARTMENT = 'SYNTHETIC Preaching Rota 4.5';
export const CELL = 'SYNTHETIC 4.5 E2E Cell';
const OPERATOR = 'israel';
const NOTE = 'SYNTHETIC: travelling that weekend';

/** The reserved fictional numbers this run uses (+44 7700 900560-900569). */
export function isFictionalResponsesPhone(phone) {
  return /^\+44770090056[0-9]$/.test(phone);
}

/** Church time (Africa/Lusaka) is UTC+02:00 all year. */
const CHURCH_OFFSET_MS = 2 * 3_600_000;

/** The church-local date (YYYY-MM-DD) of the k-th Sunday at least four days after `nowMs`. */
export function churchSunday(nowMs, k) {
  const local = new Date(nowMs + CHURCH_OFFSET_MS + 4 * 86_400_000);
  const day = local.getUTCDay();
  const first = new Date(Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate() + ((7 - day) % 7)));
  return new Date(first.getTime() + k * 7 * 86_400_000).toISOString().slice(0, 10);
}

/** The UTC instant of a church-local date and "HH:MM". */
export function churchInstant(date, hhmm) {
  return new Date(Date.parse(`${date}T${hhmm}:00Z`) - CHURCH_OFFSET_MS).toISOString();
}

/** The accept_many payload for assignments at the revisions the member saw. */
export function selection(items) {
  return { assignments: items.map(({ id, revision }) => ({ assignment_id: id, revision })) };
}

/**
 * One race round is consistent when the acceptance is all or nothing: the number of the selected
 * positions whose member answer was recorded as accepted (on any version) is 0 or all, and it is
 * all exactly when the bulk command succeeded.
 */
export function allOrNothing({ bulk, acceptedCount, selected }) {
  const ok = bulk?.status === 200 && !bulk?.code;
  return ok ? acceptedCount === selected : acceptedCount === 0 && bulk?.code === 'conflict';
}

async function main() {
  const { log, check, finish } = startRun();
  const keys = localKey();
  const http = localHttp(keys);
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const envelope = (fn, token, cmd, expected, payload, requestId = randomUUID()) =>
    rpc(fn, token, { version: 1, command: cmd, request_id: requestId, expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const duties = (token, cmd, expected, payload, requestId) => envelope('duties_command', token, cmd, expected, payload, requestId);
  const read = async (fn, token, body = {}) => {
    const r = await rpc(fn, token, body);
    return { status: r.status, json: r.json };
  };

  const people = {
    admin: { phone: '+447700900560', name: `${NAME_PREFIX} Admin` },
    leader: { phone: '+447700900561', name: `${NAME_PREFIX} Leader` },
    member: { phone: '+447700900562', name: `${NAME_PREFIX} Member M` },
    other: { phone: '+447700900563', name: `${NAME_PREFIX} Member O` },
  };
  for (const p of Object.values(people)) if (!isFictionalResponsesPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
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
      select d.department_id from app.duties_departments d where d.name = '${DEPARTMENT}';
    create temp table gone_cells as select c.cell_id from app.cells_cells c where c.name = '${CELL}';
    create temp table gone_occurrences as
      select o.occurrence_id from app.duties_occurrences o
       where o.department_id in (select department_id from gone_departments)
          or o.cell_id in (select cell_id from gone_cells);
    create temp table gone_assignments as
      select a.assignment_id from app.duties_assignments a
        join app.duties_slots s on s.slot_id = a.slot_id
       where s.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.notifications_inbox_items i where i.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_attempts a using app.notifications_jobs j
     where a.job_id = j.job_id and (j.recipient_member_id in (select member_id from gone_members)
                                    or j.source_id in (select assignment_id from gone_assignments));
    delete from app.notifications_push_jobs p where p.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_direct_contact_needs n where n.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_jobs j where j.recipient_member_id in (select member_id from gone_members)
       or j.source_id in (select assignment_id from gone_assignments);
    delete from app.duties_audit a where a.department_id in (select department_id from gone_departments)
       or a.occurrence_id in (select occurrence_id from gone_occurrences)
       or a.actor_member_id in (select member_id from gone_members);
    delete from app.duties_slot_revisions r where r.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_assignments a where a.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_slots s where s.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_occurrences o where o.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_series r where r.department_id in (select department_id from gone_departments);
    delete from app.duties_department_members dm where dm.department_id in (select department_id from gone_departments);
    delete from app.identity_access_audit a
     where a.target_member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_grants g where g.member_id in (select member_id from gone_members)
       or g.scope_id in (select department_id from gone_departments) or g.scope_id in (select cell_id from gone_cells);
    delete from app.duties_departments d where d.department_id in (select department_id from gone_departments);
    delete from app.cells_cells c where c.cell_id in (select cell_id from gone_cells);
    delete from app.identity_grant_sets s where s.member_id in (select member_id from gone_members);
    delete from app.identity_holds h where h.member_id in (select member_id from gone_members);
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
    psql(`select app.platform_set_environment('local', 'duties-responses-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('V00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  try {
    const { admin, leader, member, other } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'duties-responses-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    check('V01-members-signed-in-by-phone', Object.values(people).every((p) => amrMethods(p.token).includes('password')),
      { amr: amrMethods(admin.token) });

    // -------------------------------------------------------------- setup
    const dCreated = await duties(admin.token, 'duties.create_department', null, { name: DEPARTMENT });
    const dId = dCreated.data?.department_id;
    const grantsRev = (p) => Number(psql(`select revision from app.identity_grant_sets where member_id = '${p.member}'`));
    const granted = await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantsRev(leader),
      { member_id: leader.member, scope_kind: 'department_leader', scope_id: dId });
    const addTo = async (m) => duties(admin.token, 'duties.add_member',
      Number(psql(`select revision from app.duties_departments where department_id = '${dId}'`)),
      { department_id: dId, member_id: m });
    const added = [await addTo(member.member), await addTo(other.member)];
    check('V02-department-leader-and-members', dCreated.status === 200 && granted.status === 200 && !granted.code
      && added.every((a) => a.status === 200 && !a.code),
      { granted: granted.code ?? granted.status, added: added.map((a) => a.code ?? a.status) });

    const now = Date.now();
    const publish = (who, k, from = '10:00', to = '11:00') => {
      const date = churchSunday(now, k);
      return duties(leader.token, 'duties.publish_duty', null, {
        department_id: dId, member_id: who, duty_name: `SYNTHETIC Sunday duty ${k}`,
        starts_at: churchInstant(date, from), ends_at: churchInstant(date, to),
        response_deadline: new Date(Date.parse(churchInstant(date, from)) - 86_400_000).toISOString() });
    };
    const board = async () => (await read('duties_leader_board', leader.token)).json?.departments
      ?.find((d) => d.department_id === dId)?.duties ?? [];
    const position = (b, occurrenceId) => b.find((x) => x.occurrence_id === occurrenceId)?.positions?.[0]?.assignment;
    const mine = async () => (await read('duties_my_duties', member.token)).json?.assignments ?? [];

    // -------------------------------------------------------------- accept, decline, later decline
    const d0 = await publish(member.member, 0);
    const d1 = await publish(member.member, 1);
    const accepted = await duties(member.token, 'duties.respond', 1, { assignment_id: d0.data?.assignment_id, response: 'accepted' });
    const afterAccept = position(await board(), d0.data?.occurrence_id);
    check('V10-accept-shows-at-once', accepted.data?.response === 'accepted' && afterAccept?.response === 'accepted',
      { answer: accepted.data?.response ?? accepted.code, board: afterAccept?.response });

    const declined = await duties(member.token, 'duties.respond', 1,
      { assignment_id: d1.data?.assignment_id, response: 'declined', note: NOTE });
    const afterDecline = position(await board(), d1.data?.occurrence_id);
    check('V11-decline-shows-at-once-with-note', declined.data?.response === 'declined'
      && afterDecline?.response === 'declined' && afterDecline?.note === NOTE && afterDecline?.prior_accepted_at === null,
      { answer: declined.data?.response ?? declined.code, board: afterDecline?.response });

    const notMine = await duties(other.token, 'duties.withdraw_acceptance', 2, { assignment_id: d0.data?.assignment_id });
    const byLeader = await duties(leader.token, 'duties.withdraw_acceptance', 2, { assignment_id: d0.data?.assignment_id });
    const withdrawn = await duties(member.token, 'duties.withdraw_acceptance', 2,
      { assignment_id: d0.data?.assignment_id, note: NOTE });
    const afterWithdraw = position(await board(), d0.data?.occurrence_id);
    const myView = (await mine()).find((a) => a.assignment_id === d0.data?.assignment_id);
    const jobs = psql(`select coalesce(string_agg(job_state, ',' order by enqueued_at), '') from app.notifications_jobs
      where source_type = 'duties_assignment' and source_id = '${d0.data?.assignment_id}'`);
    check('V12-later-decline-reopens-coverage-at-once', notMine.code === 'not_found' && byLeader.code === 'not_found'
      && withdrawn.data?.response === 'declined' && withdrawn.data?.withdrawn === true
      && afterWithdraw?.response === 'declined' && typeof afterWithdraw?.prior_accepted_at === 'string'
      && typeof myView?.prior_accepted_at === 'string' && !jobs.includes('pending'),
      { other_member: notMine.code, leader: byLeader.code, answer: withdrawn.data?.response ?? withdrawn.code,
        board: afterWithdraw?.response, board_prior: Boolean(afterWithdraw?.prior_accepted_at), jobs });

    const pendingWithdraw = await duties(member.token, 'duties.withdraw_acceptance', 2, { assignment_id: d1.data?.assignment_id });
    check('V13-only-an-acceptance-can-be-withdrawn', pendingWithdraw.code === 'conflict'
      && pendingWithdraw.field_errors?.assignment_id === 'responded',
      { code: pendingWithdraw.code, field_errors: pendingWithdraw.field_errors });

    // -------------------------------------------------------------- bulk: three of four
    const four = [];
    for (const k of [2, 3, 4, 5]) four.push(await publish(member.member, k));
    const pick = four.slice(0, 3).map((p) => ({ id: p.data?.assignment_id, revision: 1 }));
    const bulkId = randomUUID();
    const bulk = await duties(member.token, 'duties.accept_many', null, selection(pick), bulkId);
    const b2 = await board();
    const answers = four.map((p) => position(b2, p.data?.occurrence_id)?.response);
    check('V20-bulk-accepts-exactly-the-selected-three', bulk.status === 200 && bulk.data?.count === 3
      && JSON.stringify(answers) === JSON.stringify(['accepted', 'accepted', 'accepted', 'pending']),
      { status: bulk.status, count: bulk.data?.count, answers });

    const auditBefore = Number(psql(`select count(*) from app.duties_audit where command_request_id = '${bulkId}'`));
    const replay = await duties(member.token, 'duties.accept_many', null, selection(pick), bulkId);
    const auditAfter = Number(psql(`select count(*) from app.duties_audit where command_request_id = '${bulkId}'`));
    check('V21-timeout-retry-under-the-same-request-id', JSON.stringify(replay) === JSON.stringify(bulk)
      && auditBefore === 3 && auditAfter === 3,
      { same: JSON.stringify(replay) === JSON.stringify(bulk), audit: [auditBefore, auditAfter] });

    const stale = await duties(member.token, 'duties.accept_many', null, selection([
      { id: four[3].data?.assignment_id, revision: 1 }, { id: four[0].data?.assignment_id, revision: 1 }]));
    const fourth = position(await board(), four[3].data?.occurrence_id)?.response;
    check('V22-a-changed-date-refuses-the-whole-selection', stale.code === 'conflict'
      && stale.field_errors?.assignments === 'changed'
      && stale.field_errors?.[`assignment:${four[0].data?.assignment_id}`] === 'responded' && fourth === 'pending',
      { code: stale.code, named: Object.keys(stale.field_errors ?? {}).length, fourth });

    // -------------------------------------------------------------- the race
    const rounds = [];
    for (const base of [6, 9, 12]) {
      const three = [];
      for (const k of [base, base + 1, base + 2]) three.push(await publish(member.member, k));
      const moved = three[1];
      const movedDate = churchSunday(now, base + 1);
      const occRev = Number(psql(`select revision from app.duties_occurrences where occurrence_id = '${moved.data?.occurrence_id}'`));
      const [bulkRace, revise] = await Promise.all([
        duties(member.token, 'duties.accept_many', null,
          selection(three.map((p) => ({ id: p.data?.assignment_id, revision: 1 })))),
        duties(leader.token, 'duties.revise_duty', occRev, {
          occurrence_id: moved.data?.occurrence_id, starts_at: churchInstant(movedDate, '09:00'),
          ends_at: churchInstant(movedDate, '11:00'),
          response_deadline: new Date(Date.parse(churchInstant(movedDate, '09:00')) - 86_400_000).toISOString() }),
      ]);
      const slots = three.map((p) => `'${p.data?.slot_id}'`).join(',');
      // Accepted member answers recorded on any version of the three positions.
      const acceptedCount = Number(psql(`select count(distinct slot_id) from app.duties_assignments
        where slot_id in (${slots}) and response = 'accepted'`));
      const movedNow = psql(`select response from app.duties_assignments
        where slot_id = '${moved.data?.slot_id}' and assignment_state = 'current'`);
      rounds.push({ bulk: bulkRace.code ?? 'ok', revise: revise.code ?? revise.data?.change,
        acceptedCount, movedNow,
        ok: allOrNothing({ bulk: bulkRace, acceptedCount, selected: 3 })
          && revise.status === 200 && !revise.code && movedNow === 'pending' });
    }
    check('V30-bulk-versus-leader-edit-never-partial', rounds.every((r) => r.ok),
      { rounds: rounds.map(({ bulk, revise, acceptedCount, movedNow }) => ({ bulk, revise, acceptedCount, movedNow })) });

    // -------------------------------------------------------------- refusals
    const cellId = psql(`insert into app.cells_cells (name, broad_area, is_synthetic, created_by)
      values ('${CELL}', 'SYNTHETIC area', true, 'duties-responses-e2e') returning cell_id`);
    const cellDate = churchSunday(now, 20);
    const cellAssignment = psql(`with o as (insert into app.duties_occurrences (cell_id, duty_name, starts_at, ends_at,
                                                        created_by_member, created_by_account)
                     values ('${cellId}', 'SYNTHETIC cell part', '${churchInstant(cellDate, '18:00')}', '${churchInstant(cellDate, '19:00')}',
                             '${leader.member}', '${leader.user}') returning occurrence_id),
               s as (insert into app.duties_slots (occurrence_id, position_no, position_name)
                     select occurrence_id, 1, 'Prayer' from o returning slot_id)
          insert into app.duties_assignments (slot_id, member_id, response_deadline, assigned_by_member, assigned_by_account)
          select slot_id, '${member.member}', '${churchInstant(cellDate, '17:00')}', '${leader.member}', '${leader.user}' from s
          returning assignment_id`);
    const cellRespond = await duties(member.token, 'duties.respond', 1, { assignment_id: cellAssignment, response: 'accepted' });
    const cellBulk = await duties(member.token, 'duties.accept_many', null, selection([{ id: cellAssignment, revision: 1 }]));
    const cellListed = (await mine()).some((a) => a.assignment_id === cellAssignment);
    const tables = [];
    for (const t of ['duties_assignments', 'duties_audit']) {
      for (const profile of ['app', 'api']) {
        const r = await http('GET', `/rest/v1/${t}?select=*`, { token: member.token, profile });
        tables.push({ t, profile, status: r.status, refused: r.status >= 400 && !Array.isArray(r.json) });
      }
    }
    check('V40-cell-owned-and-tables-refused', cellRespond.code === 'not_found' && cellBulk.code === 'not_found'
      && !cellListed && tables.every((x) => x.refused),
      { respond: cellRespond.code, bulk: cellBulk.code, listed: cellListed,
        tables: tables.map((x) => `${x.profile}.${x.t}:${x.status}`) });

    const leaks = Number(psql(`select (select count(*) from app.cmd_receipts where result::text like '%travelling that weekend%')
      + (select count(*) from app.duties_audit a where a::text like '%travelling that weekend%')
      + (select count(*) from app.notifications_jobs j where j::text like '%travelling that weekend%')`));
    const withdrawals = Number(psql(`select count(*) from app.duties_audit where action = 'acceptance_withdrawn'
      and department_id = '${dId}'`));
    check('V41-notes-stay-out-of-receipts-audit-and-jobs', leaks === 0 && withdrawals === 1, { leaks, withdrawals });
  } finally {
    const left = cleanup();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'duties-responses-e2e';
            delete from app.platform_environment_history where set_by = 'duties-responses-e2e';`);
    }
    log('V99-cleanup', { users_left: Number(left), unmarked: marked,
      departments_left: Number(psql(`select count(*) from app.duties_departments where name = '${DEPARTMENT}'`)),
      cells_left: Number(psql(`select count(*) from app.cells_cells where name = '${CELL}'`)) });
  }
  finish();
}

runMain(import.meta.url, main);
