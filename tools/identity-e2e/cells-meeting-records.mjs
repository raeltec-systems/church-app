#!/usr/bin/env node
// Story 5.8 end-to-end on the LOCAL stack: meeting records through real GoTrue phone sign-in (no SMS)
// and the real Data API (PostgREST), proving the ticket's verify at the API level:
//   * a meeting ahead cannot be recorded; once it has started the cell's leader marks it held and
//     another cell's leader is refused;
//   * the leader records a substitute for a planned part leader and the assistant corrects it with a
//     reason: the earlier record and its actor are kept; the plan and the duty responses are unchanged;
//   * a cancelled meeting cannot be marked held; the canonical meeting reference names the actual
//     leaders; members read nothing new.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900060-900069. Evidence is redacted JSONL:
// statuses, codes, counts; never tokens, passwords, numbers, names or programme text. Everything it
// created is removed (the meetings are moved into the past directly in the database first: the
// stand-in for time passing).
//
// Usage: node tools/identity-e2e/cells-meeting-records.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';
import { weekdayInTwoDays } from './cells-meetings.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 5.8 E2E';
export const SHIKOSWE = 'SYNTHETIC Shikoswe Cell (5.8 E2E)';
export const ESTATES = 'SYNTHETIC Estates C5/C7 Cell (5.8 E2E)';
export const DEPARTMENT = 'SYNTHETIC Ushers (5.8 E2E)';
const VENUE = 'SYNTHETIC 12 Shikoswe Road';
const TOPIC = 'SYNTHETIC Rooted in love';
const GUEST = 'SYNTHETIC Visiting Pastor';
const REASON = 'SYNTHETIC it was the visiting pastor';

/** The reserved fictional numbers this run uses (+44 7700 900060-900069). */
export function isFictionalRecordsPhone(phone) {
  return /^\+44770090006[0-9]$/.test(phone);
}

/** Moves a meeting (and, through its trigger, its programme) back by [days] (time passing). */
export function shiftSql(meetingId, days) {
  if (!/^[0-9a-f-]{36}$/.test(meetingId ?? '') || !Number.isInteger(days)) throw new Error('bad shift');
  const by = `interval '${days} days'`;
  return `update app.cells_meetings set starts_at = starts_at - ${by}, ends_at = ends_at - ${by},
            nominal_starts_at = nominal_starts_at - ${by}, nominal_ends_at = nominal_ends_at - ${by}
           where meeting_id = '${meetingId}'`;
}

async function main() {
  const { log, check, finish } = startRun();
  const keys = localKey();
  const http = localHttp(keys);
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const envelope = (fn, token, cmd, expected, payload) =>
    rpc(fn, token, { version: 1, command: cmd, request_id: randomUUID(), expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const cells = (token, cmd, expected, payload) => envelope('cells_command', token, cmd, expected, payload);
  const duties = (token, cmd, expected, payload) => envelope('duties_command', token, cmd, expected, payload);
  const read = async (fn, token, body = {}) => {
    const r = await rpc(fn, token, body);
    return { status: r.status, json: r.json, detail: r.json?.details ?? null };
  };

  const people = {
    admin: { phone: '+447700900060', name: `${NAME_PREFIX} Admin` },
    leader: { phone: '+447700900061', name: `${NAME_PREFIX} Leader S` },
    assistant: { phone: '+447700900062', name: `${NAME_PREFIX} Assistant S` },
    member: { phone: '+447700900063', name: `${NAME_PREFIX} Member S` },
    other: { phone: '+447700900064', name: `${NAME_PREFIX} Other S` },
    estatesLeader: { phone: '+447700900065', name: `${NAME_PREFIX} Leader E` },
    pastor: { phone: '+447700900066', name: `${NAME_PREFIX} Pastor` },
  };
  for (const p of Object.values(people)) if (!isFictionalRecordsPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
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
    create temp table gone_cells as
      select c.cell_id from app.cells_cells c where c.name in ('${SHIKOSWE}', '${ESTATES}');
    create temp table gone_meetings as
      select m.meeting_id from app.cells_meetings m where m.cell_id in (select cell_id from gone_cells);
    create temp table gone_occurrences as
      select o.occurrence_id from app.duties_occurrences o
       where o.department_id in (select department_id from gone_departments)
          or o.cell_id in (select cell_id from gone_cells);
    create temp table gone_assignments as
      select a.assignment_id from app.duties_assignments a join app.duties_slots s on s.slot_id = a.slot_id
       where s.occurrence_id in (select occurrence_id from gone_occurrences);
    create temp table gone_jobs as
      select j.job_id from app.notifications_jobs j
       where j.recipient_member_id in (select member_id from gone_members)
          or j.source_id in (select assignment_id from gone_assignments)
          or j.source_id in (select meeting_id from gone_meetings);
    delete from app.notifications_push_jobs p where p.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_attempts a where a.job_id in (select job_id from gone_jobs);
    delete from app.notifications_direct_contact_needs n where n.job_id in (select job_id from gone_jobs);
    update app.notifications_jobs j set snoozed_from_item_id = null where j.job_id in (select job_id from gone_jobs);
    delete from app.notifications_inbox_items i where i.job_id in (select job_id from gone_jobs)
       or i.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_jobs j where j.job_id in (select job_id from gone_jobs);
    delete from app.notifications_schedules s where s.source_id in (select assignment_id from gone_assignments)
       or s.source_id in (select meeting_id from gone_meetings)
       or s.recipient_member_id in (select member_id from gone_members);
    delete from app.duties_contact_attempts t where t.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_coverage_cases c where c.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_contact_needs n where n.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_audit a where a.department_id in (select department_id from gone_departments)
       or a.occurrence_id in (select occurrence_id from gone_occurrences)
       or a.actor_member_id in (select member_id from gone_members);
    delete from app.duties_slot_revisions r where r.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_assignments a where a.assignment_id in (select assignment_id from gone_assignments);
    -- Part links and review flags go with their slots and occurrences (the only way they are removed).
    delete from app.duties_slots s where s.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_occurrences o where o.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_series r where r.department_id in (select department_id from gone_departments);
    delete from app.duties_department_members dm where dm.department_id in (select department_id from gone_departments);
    delete from app.cells_actual_leaders a where a.cell_id in (select cell_id from gone_cells);
    delete from app.cells_meeting_record_history h where h.cell_id in (select cell_id from gone_cells);
    delete from app.cells_meeting_records r where r.cell_id in (select cell_id from gone_cells);
    delete from app.cells_absence_audit a where a.cell_id in (select cell_id from gone_cells)
       or a.actor_member_id in (select member_id from gone_members);
    delete from app.cells_absence_notices n where n.cell_id in (select cell_id from gone_cells);
    delete from app.notifications_jobs j where j.source_type = 'cells_absence_notice'
       and j.job_id not in (select a.job_id from app.notifications_attempts a)
       and j.source_id not in (select n.notice_id from app.cells_absence_notices n);
    delete from app.cells_programme_projections pr where pr.cell_id in (select cell_id from gone_cells);
    delete from app.cells_programme_audit a where a.cell_id in (select cell_id from gone_cells)
       or a.actor_member_id in (select member_id from gone_members);
    delete from app.cells_programme_parts pt
     where pt.programme_id in (select p.programme_id from app.cells_programmes p where p.cell_id in (select cell_id from gone_cells));
    delete from app.cells_programmes p where p.cell_id in (select cell_id from gone_cells);
    delete from app.cells_meeting_contact_needs n where n.meeting_id in (select meeting_id from gone_meetings);
    delete from app.cells_reminders_audit a where a.cell_id in (select cell_id from gone_cells)
       or a.actor_member_id in (select member_id from gone_members);
    delete from app.cells_meeting_audit a where a.cell_id in (select cell_id from gone_cells)
       or a.actor_member_id in (select member_id from gone_members);
    delete from app.cells_meetings m where m.cell_id in (select cell_id from gone_cells);
    delete from app.cells_meeting_schedules s where s.cell_id in (select cell_id from gone_cells);
    delete from app.cells_membership_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members)
        or a.cell_id in (select cell_id from gone_cells);
    -- Memberships and requests reference each other: one statement deletes both.
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
    delete from app.identity_grants g where g.member_id in (select member_id from gone_members)
       or g.scope_id in (select department_id from gone_departments) or g.scope_id in (select cell_id from gone_cells);
    delete from app.duties_departments d where d.department_id in (select department_id from gone_departments);
    delete from app.cells_cells c where c.cell_id in (select cell_id from gone_cells);
    delete from app.identity_contact_routes r where r.member_id in (select member_id from gone_members);
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
    psql(`select app.platform_set_environment('local', 'cells-meeting-records-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('A00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  try {
    const { admin, leader, assistant, member, other, estatesLeader, pastor } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'cells-meeting-records-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    const accountless = psql(`insert into app.identity_members (display_name, membership_state, is_synthetic)
      values ('${NAME_PREFIX} Accountless A', 'approved', true) returning member_id`);
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    check('A01-members-signed-in-by-phone', Object.values(people).every((p) => amrMethods(p.token).includes('password')),
      { amr: amrMethods(admin.token) });

    // ------------------------------------------------------------------ setup
    const S = (await cells(admin.token, 'cells.create_cell', null,
      { name: SHIKOSWE, signup_label: 'SYNTHETIC Shikoswe', broad_area: 'SYNTHETIC Kafue' })).data?.cell_id;
    const E = (await cells(admin.token, 'cells.create_cell', null,
      { name: ESTATES, signup_label: 'SYNTHETIC Estates', broad_area: 'SYNTHETIC Estates' })).data?.cell_id;
    let ov = (await read('cells_admin_overview', admin.token)).json;
    const grantsRev = (memberId) => ov?.members?.find((m) => m.member_id === memberId)?.grants_revision;
    const grants = [];
    for (const [p, kind, scope] of [[leader, 'cell_leader', S], [assistant, 'cell_assistant', S], [estatesLeader, 'cell_leader', E]]) {
      grants.push(await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantsRev(p.member),
        { member_id: p.member, scope_kind: kind, scope_id: scope }));
      ov = (await read('cells_admin_overview', admin.token)).json;
    }
    grants.push(await envelope('identity_grant_command', admin.token, 'identity.grant_role', grantsRev(pastor.member),
      { member_id: pastor.member, role: 'pastor' }));
    const place = async (memberId, cell) => {
      ov = (await read('cells_admin_overview', admin.token)).json;
      const row = ov?.members?.find((m) => m.member_id === memberId);
      const asked = await cells(admin.token, 'cells.request_change', row?.cell_revision,
        { member_id: memberId, cell_id: cell, cell_revision: ov?.cells?.find((c) => c.cell_id === cell)?.signup_revision });
      return cells(admin.token, 'cells.confirm_request', asked.revision, { request_id: asked.data?.open_request?.request_id });
    };
    const placed = [await place(member.member, S), await place(other.member, S), await place(accountless, S)];
    for (const p of [leader, assistant, estatesLeader, pastor]) p.token = (await signIn(p.phone, p.password)).json?.access_token;
    ov = (await read('cells_admin_overview', admin.token)).json;
    const set = await cells(admin.token, 'cells.set_schedule', ov?.cells?.find((c) => c.cell_id === S)?.revision,
      { cell_id: S, weekday: weekdayInTwoDays(Date.now()), start_time: '18:00', end_time: '19:30', venue: VENUE });
    const meeting = (await read('cells_meetings', leader.token)).json?.cells?.find((c) => c.cell_id === S)?.meetings?.[0];
    const created = await cells(leader.token, 'cells.create_programme', null, { meeting_id: meeting?.meeting_id });
    const P = created.data?.programme_id;
    const saved = await cells(leader.token, 'cells.save_programme', created.revision, {
      programme_id: P, topic: TOPIC, parts: [
        { label: 'SYNTHETIC Opening prayer', start_time: '18:00', end_time: '18:10', assignee_member_id: member.member },
        { label: 'SYNTHETIC Worship', start_time: '18:10', end_time: '18:30', assignee_member_id: accountless },
        { label: 'SYNTHETIC Bible study', start_time: '18:30', end_time: '19:00', assignee_member_id: other.member },
      ] });
    const published = await cells(leader.token, 'cells.publish_programme', saved.revision, { programme_id: P });
    check('A02-a-published-programme', [S, E].every(Boolean) && grants.every((g) => g.status === 200)
      && placed.every((p) => p.status === 200) && set.status === 200 && published.data?.state === 'published',
      { grants: grants.map((g) => g.status), placed: placed.map((p) => p.status), published: published.data?.state });

    // ------------------------------------------------------------------ before and after the start
    const M = meeting?.meeting_id;
    const record = (p, cmd, expected, payload) => cells(p.token, cmd, expected, { meeting_id: M, ...payload });
    const myDuty = async (p, name) => ((await read('duties_my_duties', p.token)).json?.assignments ?? [])
      .find((a) => a.duty_name === name);
    const memberDuty = await myDuty(member, 'SYNTHETIC Opening prayer');
    const accepted = await duties(member.token, 'duties.respond', memberDuty?.revision,
      { assignment_id: memberDuty?.assignment_id, response: 'accepted' });
    const otherBefore = await myDuty(other, 'SYNTHETIC Bible study');
    const planBefore = psql(`select string_agg(label || ':' || coalesce(assignee_member_id::text, '-'), ',' order by position)
                               from app.cells_programme_parts where programme_id = '${P}'`);
    const early = await record(leader, 'cells.record_meeting_held', null, { held: true });
    psql(shiftSql(M, 3));
    const otherCell = await record(estatesLeader, 'cells.record_meeting_held', null, { held: true });
    const held = await record(leader, 'cells.record_meeting_held', null, { held: true });
    check('A10-held-once-started-other-cell-refused', accepted.data?.response === 'accepted'
      && early.code === 'validation_failed'
      && JSON.stringify(early).includes('not_started')
      && otherCell.code === 'forbidden' && held.data?.held === true && held.revision === 1,
      { before_start: early.code, other_cell: otherCell.code, held: held.data?.held });

    // ------------------------------------------------------------------ actual leaders
    const parts = Object.fromEntries((published.data?.parts ?? (await read('cells_programme', leader.token,
      { meeting_id: M })).json?.programme?.parts ?? []).map((pt) => [pt.label, pt.part_id]));
    const leaders = await record(leader, 'cells.record_actual_leaders', held.revision, { parts: [
      { part_id: parts['SYNTHETIC Opening prayer'], leader: { member_id: member.member } },
      { part_id: parts['SYNTHETIC Bible study'], leader: { member_id: accountless } },
    ] });
    const staff = (await read('cells_programme', leader.token, { meeting_id: M })).json;
    const actual = Object.fromEntries((staff?.record?.actual ?? []).map((a) => [a.part_id, a]));
    check('A20-substitute-recorded', leaders.data?.changed === 2 && staff?.status === 'held'
      && actual[parts['SYNTHETIC Opening prayer']]?.substitute === false
      && actual[parts['SYNTHETIC Bible study']]?.substitute === true,
      { changed: leaders.data?.changed, status: staff?.status,
        substitutes: (staff?.record?.actual ?? []).filter((a) => a.substitute).length });

    // ------------------------------------------------------------------ a correction keeps the earlier record
    const noReason = await record(assistant, 'cells.record_actual_leaders', leaders.revision, { parts: [
      { part_id: parts['SYNTHETIC Bible study'], leader: { name: GUEST } }] });
    const corrected = await record(assistant, 'cells.record_actual_leaders', leaders.revision, { parts: [
      { part_id: parts['SYNTHETIC Bible study'], leader: { name: GUEST }, reason: REASON }] });
    const trail = psql(`select string_agg(leader_kind || ':' || (superseded_at is null)::text || ':' ||
                          case recorded_by_member when '${leader.member}' then 'leader'
                                                  when '${assistant.member}' then 'assistant' else 'other' end,
                          ',' order by recorded_at, superseded_at nulls last)
                          from app.cells_actual_leaders where part_id = '${parts['SYNTHETIC Bible study']}'`);
    const otherAfter = await myDuty(other, 'SYNTHETIC Bible study');
    const memberAfter = await myDuty(member, 'SYNTHETIC Opening prayer');
    const planAfter = psql(`select string_agg(label || ':' || coalesce(assignee_member_id::text, '-'), ',' order by position)
                              from app.cells_programme_parts where programme_id = '${P}'`);
    const outcomes = psql(`select count(*) from app.duties_outcomes o
                            where o.assignment_id in ('${memberDuty?.assignment_id}', '${otherBefore?.assignment_id}')`);
    check('A30-correction-keeps-earlier-plan-and-duties-unchanged', noReason.code === 'validation_failed'
      && corrected.data?.changed === 1 && trail === 'member:false:leader,guest:true:assistant'
      && planAfter === planBefore && memberAfter?.response === 'accepted' && memberAfter?.revision === accepted.data?.revision
      && otherAfter?.response === otherBefore?.response && otherAfter?.revision === otherBefore?.revision && outcomes === '0',
      { without_reason: noReason.code, changed: corrected.data?.changed, trail, plan_unchanged: planAfter === planBefore,
        member_part: memberAfter?.response, other_part: otherAfter?.response, duty_outcomes: Number(outcomes) });

    // ------------------------------------------------------------------ cancelled, the reference, who reads
    const later = (await read('cells_meetings', leader.token)).json?.cells?.find((c) => c.cell_id === S)?.meetings
      ?.find((m) => m.meeting_id !== M && m.state === 'scheduled');
    const cancelled = await cells(leader.token, 'cells.cancel_meeting', later?.revision, { meeting_id: later?.meeting_id });
    psql(shiftSql(later?.meeting_id, 21));
    const heldCancelled = await cells(leader.token, 'cells.record_meeting_held', null,
      { meeting_id: later?.meeting_id, held: true });
    const ref = JSON.parse(psql(`select app.cells_meeting_reference('${M}')::text`));
    const memberRead = (await read('cells_meeting_programme', member.token, { meeting_id: M })).json;
    const otherCellRead = await read('cells_programme', estatesLeader.token, { meeting_id: M });
    const board = (await read('cells_meetings', leader.token)).json?.cells?.find((c) => c.cell_id === S);
    const studied = (ref?.actual_leaders ?? []).find((a) => a.part_id === parts['SYNTHETIC Bible study']);
    check('A40-cancelled-refused-reference-and-reads', cancelled.status === 200
      && JSON.stringify(heldCancelled).includes('cancelled') && heldCancelled.code === 'validation_failed'
      && ref?.status === 'held' && studied?.kind === 'guest' && studied?.substitute === true
      && !JSON.stringify(ref).includes(REASON)
      && memberRead && !('record' in memberRead) && otherCellRead.status === 403
      && (board?.recent ?? []).some((m) => m.meeting_id === M && m.status === 'held'),
      { cancelled_held: heldCancelled.code, reference_status: ref?.status, reference_part: studied?.kind,
        member_reads_record: Boolean(memberRead && 'record' in memberRead), other_cell_read: otherCellRead.status,
        board_recent: (board?.recent ?? []).map((m) => m.status) });
  } finally {
    const left = cleanup();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'cells-meeting-records-e2e';
            delete from app.platform_environment_history where set_by = 'cells-meeting-records-e2e';`);
    }
    log('A99-cleanup', { users_left: Number(left), unmarked: marked,
      programmes_left: Number(psql(`select count(*) from app.cells_programmes p join app.cells_cells c using (cell_id)
                                    where c.name in ('${SHIKOSWE}', '${ESTATES}')`)) });
  }
  finish();
}

runMain(import.meta.url, main);
