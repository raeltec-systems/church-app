#!/usr/bin/env node
// Story 5.6 end-to-end on the LOCAL stack: programme revisions through real GoTrue phone sign-in (no
// SMS) and the real Data API (PostgREST), proving the ticket's verify at the API level:
//   * a notes-only revision keeps every answer (and members keep the last publish until it is out);
//   * a part's time change and a swapped person ask again only there: a new pending revision, the
//     earlier acceptance kept in history, no reminder left pending for it, a late answer to it
//     refused, the replaced person no longer on;
//   * the linked department duty is never changed and its department gets a review flag (label,
//     then time when the meeting moves);
//   * Admin alone cannot move a meeting with a published programme; the cell's leader moves it,
//     members are told, and publishing moves the part's duty with it; cancelling that meeting waits
//     for the programme, while another meeting is cancelled as before.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900040-900049. Evidence is redacted JSONL:
// statuses, codes, counts; never tokens, passwords, numbers, names or programme text. Everything it
// created is removed.
//
// Usage: node tools/identity-e2e/cells-programme-revisions.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';
import { weekdayInTwoDays } from './cells-meetings.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 5.6 E2E';
export const SHIKOSWE = 'SYNTHETIC Shikoswe Cell (5.6 E2E)';
export const ESTATES = 'SYNTHETIC Estates C5/C7 Cell (5.6 E2E)';
export const DEPARTMENT = 'SYNTHETIC Ushers (5.6 E2E)';
const VENUE = 'SYNTHETIC 12 Shikoswe Road';
const TOPIC = 'SYNTHETIC Rooted in love';

/** The reserved fictional numbers this run uses (+44 7700 900040-900049). */
export function isFictionalRevisionsPhone(phone) {
  return /^\+44770090004[0-9]$/.test(phone);
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
    admin: { phone: '+447700900041', name: `${NAME_PREFIX} Admin` },
    leader: { phone: '+447700900042', name: `${NAME_PREFIX} Leader S` },
    member: { phone: '+447700900043', name: `${NAME_PREFIX} Member S` },
    other: { phone: '+447700900044', name: `${NAME_PREFIX} Other S` },
    deptLeader: { phone: '+447700900045', name: `${NAME_PREFIX} Department Leader` },
  };
  for (const p of Object.values(people)) if (!isFictionalRevisionsPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
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
    psql(`select app.platform_set_environment('local', 'cells-programme-revisions-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('V00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  try {
    const { admin, leader, member, other, deptLeader } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'cells-programme-revisions-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    const accountless = psql(`insert into app.identity_members (display_name, membership_state, is_synthetic)
      values ('${NAME_PREFIX} Accountless A', 'approved', true) returning member_id`);
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    check('V01-members-signed-in-by-phone', Object.values(people).every((p) => amrMethods(p.token).includes('password')),
      { amr: amrMethods(admin.token) });

    // ------------------------------------------------------------------ setup
    const S = (await cells(admin.token, 'cells.create_cell', null,
      { name: SHIKOSWE, signup_label: 'SYNTHETIC Shikoswe', broad_area: 'SYNTHETIC Kafue' })).data?.cell_id;
    const D = (await duties(admin.token, 'duties.create_department', null, { name: DEPARTMENT })).data?.department_id;
    let ov = (await read('cells_admin_overview', admin.token)).json;
    const grantsRev = (memberId) => ov?.members?.find((m) => m.member_id === memberId)?.grants_revision;
    const grants = [];
    for (const [p, kind, scope] of [[leader, 'cell_leader', S], [deptLeader, 'department_leader', D]]) {
      grants.push(await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantsRev(p.member),
        { member_id: p.member, scope_kind: kind, scope_id: scope }));
      ov = (await read('cells_admin_overview', admin.token)).json;
    }
    const deptRev = () => Number(psql(`select revision from app.duties_departments where department_id = '${D}'`));
    const added = await duties(admin.token, 'duties.add_member', deptRev(), { department_id: D, member_id: deptLeader.member });
    const place = async (memberId, cell) => {
      ov = (await read('cells_admin_overview', admin.token)).json;
      const row = ov?.members?.find((m) => m.member_id === memberId);
      const asked = await cells(admin.token, 'cells.request_change', row?.cell_revision,
        { member_id: memberId, cell_id: cell, cell_revision: ov?.cells?.find((c) => c.cell_id === cell)?.signup_revision });
      return cells(admin.token, 'cells.confirm_request', asked.revision, { request_id: asked.data?.open_request?.request_id });
    };
    const placed = [await place(member.member, S), await place(other.member, S), await place(accountless, S)];
    for (const p of [leader, deptLeader]) p.token = (await signIn(p.phone, p.password)).json?.access_token;
    ov = (await read('cells_admin_overview', admin.token)).json;
    const set = await cells(admin.token, 'cells.set_schedule', ov?.cells?.find((c) => c.cell_id === S)?.revision,
      { cell_id: S, weekday: weekdayInTwoDays(Date.now()), start_time: '18:00', end_time: '19:30', venue: VENUE });
    const meetings = (await read('cells_meetings', leader.token)).json?.cells?.find((c) => c.cell_id === S)?.meetings ?? [];
    const meeting = meetings[0];
    const dept = await duties(deptLeader.token, 'duties.publish_duty', null, {
      department_id: D, member_id: deptLeader.member, duty_name: 'SYNTHETIC Evening ushering',
      starts_at: meeting?.starts_at, ends_at: meeting?.ends_at });
    const deptRevision = () => psql(`select revision from app.duties_occurrences where department_id = '${D}'`);
    const deptBefore = deptRevision();
    const created = await cells(leader.token, 'cells.create_programme', null, { meeting_id: meeting?.meeting_id });
    const P = created.data?.programme_id;
    const slot = (await read('cells_programme', leader.token, { meeting_id: meeting?.meeting_id })).json?.linkable?.[0]?.slot_id;
    let revision = created.revision;
    const save = async (parts, extra = {}) => {
      const r = await cells(leader.token, 'cells.save_programme', revision, { programme_id: P, topic: TOPIC, parts, ...extra });
      if (r.revision) revision = r.revision;
      return r;
    };
    const publish = async () => {
      const r = await cells(leader.token, 'cells.publish_programme', revision, { programme_id: P });
      if (r.revision) revision = r.revision;
      return r;
    };
    const s1 = await save([
      { label: 'SYNTHETIC Opening prayer', start_time: '18:00', end_time: '18:10', assignee_member_id: member.member },
      { label: 'SYNTHETIC Worship', start_time: '18:10', end_time: '18:30', assignee_member_id: other.member },
      { label: 'SYNTHETIC Ushering', start_time: '18:30', end_time: '19:00', linked_slot_id: slot },
    ], { study_notes: 'SYNTHETIC first notes' });
    const p1 = await publish();
    const partIds = (s1.data?.parts ?? []).map((x) => x.part_id);
    const myDuty = async (p, name) => ((await read('duties_my_duties', p.token)).json?.assignments ?? [])
      .find((a) => a.duty_name === name);
    const respond = (p, d, response) => duties(p.token, 'duties.respond', d?.revision, { assignment_id: d?.assignment_id, response });
    const m1 = await myDuty(member, 'SYNTHETIC Opening prayer');
    const o1 = await myDuty(other, 'SYNTHETIC Worship');
    const answers = [await respond(member, m1, 'accepted'), await respond(other, o1, 'accepted')];
    check('V02-published-and-accepted', [S, D, P, slot].every(Boolean) && grants.every((g) => g.status === 200)
      && added.status === 200 && placed.every((p) => p.status === 200) && set.status === 200 && dept.status === 200
      && p1.data?.state === 'published' && answers.every((a) => a.data?.response === 'accepted'),
      { published: p1.data?.state, answers: answers.map((a) => a.data?.response) });

    // ------------------------------------------------------------------ notes only
    const parts = (o) => [
      { part_id: partIds[0], label: 'SYNTHETIC Opening prayer', start_time: o.start ?? '18:00', end_time: '18:10', assignee_member_id: member.member },
      { part_id: partIds[1], label: 'SYNTHETIC Worship', start_time: '18:10', end_time: '18:30', assignee_member_id: o.worship ?? other.member },
      { part_id: partIds[2], label: o.usherLabel ?? 'SYNTHETIC Ushering', start_time: '18:30', end_time: '19:00', linked_slot_id: slot },
    ];
    const notesSave = await save(parts({}), { study_notes: 'SYNTHETIC changed notes', scripture: 'John 15' });
    const beforePublish = (await read('cells_meeting_programme', member.token, { meeting_id: meeting?.meeting_id })).json;
    await publish();
    const m2 = await myDuty(member, 'SYNTHETIC Opening prayer');
    check('V10-notes-only-keeps-answers', notesSave.data?.unpublished_changes === true && beforePublish?.programme?.scripture === null
      && m2?.assignment_id === m1?.assignment_id && m2?.response === 'accepted',
      { waited_for_publish: beforePublish?.programme?.scripture === null, same_assignment: m2?.assignment_id === m1?.assignment_id,
        response: m2?.response });

    // ------------------------------------------------------------------ material: time and a swapped person
    await save(parts({ start: '18:02', worship: accountless }));
    const material = await publish();
    const m3 = await myDuty(member, 'SYNTHETIC Opening prayer');
    const late = await respond(member, m2, 'declined');
    const oldJobs = psql(`select count(*) from app.notifications_jobs where source_id = '${m2?.assignment_id}' and job_state = 'pending'`);
    const oldState = psql(`select assignment_state || '|' || response from app.duties_assignments where assignment_id = '${m2?.assignment_id}'`);
    const otherNow = await myDuty(other, 'SYNTHETIC Worship');
    check('V20-material-change-asks-again-only-there', material.data?.state === 'published' && m3?.response === 'pending'
      && m3?.assignment_id !== m2?.assignment_id && oldState === 'superseded|accepted' && oldJobs === '0'
      && late.code === 'conflict' && !otherNow,
      { new_pending: m3?.response, history: oldState, stale_reminders: Number(oldJobs), late_answer: late.code,
        replaced_person_still_on: Boolean(otherNow) });

    // ------------------------------------------------------------------ department mismatch
    const flagged = await (async () => { await save(parts({ start: '18:02', worship: accountless, usherLabel: 'SYNTHETIC Ushers at the door' })); return publish(); })();
    const flags = psql(`select coalesce(string_agg(f.changed::text, ';'), '') from app.duties_review_flags f
                          join app.duties_occurrences o using (occurrence_id) where o.department_id = '${D}' and f.cleared_at is null`);
    check('V30-department-duty-unchanged-with-a-mismatch', JSON.stringify(flagged.data?.duties?.[2]?.flagged) === '["label"]'
      && flags.includes('label') && deptRevision() === deptBefore,
      { flagged: flagged.data?.duties?.[2]?.flagged, open_flags: flags.length > 0, department_revision_unchanged: deptRevision() === deptBefore });

    // ------------------------------------------------------------------ the meeting moves; another is cancelled
    const shift = (iso, mins) => new Date(Date.parse(iso) + mins * 60_000).toISOString();
    const meetingRev = () => Number(psql(`select revision from app.cells_meetings where meeting_id = '${meeting?.meeting_id}'`));
    const byAdmin = await cells(admin.token, 'cells.move_meeting', meetingRev(),
      { meeting_id: meeting?.meeting_id, starts_at: shift(meeting?.starts_at, 30), ends_at: shift(meeting?.ends_at, 30) });
    const moved = await cells(leader.token, 'cells.move_meeting', meetingRev(),
      { meeting_id: meeting?.meeting_id, starts_at: shift(meeting?.starts_at, 30), ends_at: shift(meeting?.ends_at, 30) });
    const told = (await read('cells_meeting_programme', member.token, { meeting_id: meeting?.meeting_id })).json?.programme?.meeting_changed;
    const staffRead = (await read('cells_programme', leader.token, { meeting_id: meeting?.meeting_id })).json;
    revision = staffRead?.programme?.revision;
    const republished = await publish();
    const m4 = await myDuty(member, 'SYNTHETIC Opening prayer');
    const cancelThis = await cells(leader.token, 'cells.cancel_meeting', meetingRev(), { meeting_id: meeting?.meeting_id });
    const another = meetings[1];
    const cancelAnother = await cells(leader.token, 'cells.cancel_meeting', another?.revision, { meeting_id: another?.meeting_id });
    check('V40-move-reconciled-and-another-cancelled', byAdmin.field_errors?.meeting_id === 'programme_published'
      && moved.status === 200 && told === true && staffRead?.programme?.meeting_changed === true
      && republished.data?.state === 'published' && Date.parse(m4?.starts_at) === Date.parse(shift(meeting?.starts_at, 32))
      && JSON.stringify(republished.data?.duties?.[2]?.flagged) === '["time"]'
      && cancelThis.field_errors?.meeting_id === 'programme_published' && cancelAnother.data?.state === 'cancelled'
      && deptRevision() === deptBefore,
      { admin_move: byAdmin.field_errors?.meeting_id ?? null, leader_move: moved.status, members_told: told,
        part_moved_with_meeting: Date.parse(m4?.starts_at) === Date.parse(shift(meeting?.starts_at, 32)),
        department_flag: republished.data?.duties?.[2]?.flagged, cancel_this: cancelThis.field_errors?.meeting_id ?? null,
        cancel_another: cancelAnother.data?.state });
  } finally {
    const left = cleanup();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'cells-programme-revisions-e2e';
            delete from app.platform_environment_history where set_by = 'cells-programme-revisions-e2e';`);
    }
    log('V99-cleanup', { users_left: Number(left), unmarked: marked,
      programmes_left: Number(psql(`select count(*) from app.cells_programmes p join app.cells_cells c using (cell_id)
                                    where c.name in ('${SHIKOSWE}', '${ESTATES}')`)) });
  }
  finish();
}

runMain(import.meta.url, main);
