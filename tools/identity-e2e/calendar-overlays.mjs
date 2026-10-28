#!/usr/bin/env node
// Epic 6 entry 19 end-to-end on the LOCAL stack: the reads behind the Calendar's My duties and
// My cell overlays, through real GoTrue phone sign-in (no SMS) and the real Data API (PostgREST),
// proving the ticket's verify at the API level:
//   * two SYNTHETIC cells with weekly schedules; member M is confirmed in Shikoswe, member O in
//     Estates; an Admin cancels one Shikoswe meeting;
//   * a department leader publishes one duty to M and one to O;
//   * M's new Cells read (api.cells_my_meetings) lists only Shikoswe meetings that start within
//     31 days, the cancelled one marked, with no venue; O's lists only Estates meetings;
//   * M's 4.5 My duties read (api.duties_my_duties, unchanged) lists M's duty and not O's;
//   * a Pending applicant (an account without member access) and a guest (no session) are refused
//     the new read; api.cells_my_cell still answers the next meeting with its venue (unchanged);
//   * direct table queries stay refused.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900941-900949. Evidence is redacted JSONL:
// statuses, codes, counts; never tokens, passwords, numbers or the venue. Everything it created is
// removed.
//
// Usage: node tools/identity-e2e/calendar-overlays.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 6.19 E2E';
export const SHIKOSWE = 'SYNTHETIC Shikoswe Cell (6.19 E2E)';
export const ESTATES = 'SYNTHETIC Estates C5/C7 Cell (6.19 E2E)';
export const DEPARTMENT = 'SYNTHETIC Ushering (6.19 E2E)';
const VENUE = 'SYNTHETIC 12 Shikoswe Road';
const VENUE_E = 'SYNTHETIC 7 Estates Close';
export const WINDOW_DAYS = 31;

/** The reserved fictional numbers this run uses (+44 7700 900941-900949). */
export function isFictionalOverlayPhone(phone) {
  return /^\+44770090094[1-9]$/.test(phone);
}

/** The ISO weekday (1 = Monday) two church days after `nowMs`, so the first meeting is ahead. */
export function weekdayInTwoDays(nowMs) {
  const d = new Date(nowMs + 2 * 3_600_000 + 2 * 86_400_000).getUTCDay();
  return d === 0 ? 7 : d;
}

/**
 * The overlay answer holds only the caller's own cell: every meeting id is one of `ownIds`, none
 * is one of `otherIds`, every meeting starts before `untilMs` and has not ended at `nowMs`.
 */
export function onlyOwnMeetings(answer, ownIds, otherIds, nowMs, untilMs) {
  const meetings = answer?.meetings;
  if (!Array.isArray(meetings) || meetings.length === 0) return false;
  const own = new Set(ownIds);
  const other = new Set(otherIds);
  return meetings.every((m) => own.has(m.meeting_id) && !other.has(m.meeting_id)
    && Date.parse(m.starts_at) < untilMs && Date.parse(m.ends_at) > nowMs);
}

/** The keys of every meeting of an overlay answer, sorted and joined. */
export function meetingKeys(answer) {
  const keys = new Set();
  for (const m of answer?.meetings ?? []) for (const k of Object.keys(m)) keys.add(k);
  return [...keys].sort().join(',');
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
  const cells = (token, cmd, expected, payload) => envelope('cells_command', token, cmd, expected, payload);
  const duties = (token, cmd, expected, payload) => envelope('duties_command', token, cmd, expected, payload);
  const read = async (fn, token) => {
    const r = await rpc(fn, token);
    return { status: r.status, json: r.json };
  };
  const DAY = 86_400_000;
  const at = (ms) => new Date(Date.now() + ms).toISOString();

  const people = {
    admin: { phone: '+447700900941', name: `${NAME_PREFIX} Admin` },
    leader: { phone: '+447700900942', name: `${NAME_PREFIX} Duty leader` },
    member: { phone: '+447700900943', name: `${NAME_PREFIX} Member M` },
    other: { phone: '+447700900944', name: `${NAME_PREFIX} Member O` },
    pending: { phone: '+447700900945', name: `${NAME_PREFIX} Pending`, noLink: true },
  };
  for (const p of Object.values(people)) if (!isFictionalOverlayPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  const users = new Set();
  const digits = Object.values(people).map((p) => `'${p.phone.slice(1)}'`).join(',');
  const cleanup = () => {
    const ids = [...users].map((u) => `'${u}'`);
    const byUser = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    return psql(`
    create temp table gone_users as select u.id from auth.users u where ${byUser} u.phone in (${digits});
    create temp table gone_members as
      select m.member_id from app.identity_members m where m.display_name like '${NAME_PREFIX}%';
    create temp table gone_cells as
      select c.cell_id from app.cells_cells c where c.name in ('${SHIKOSWE}', '${ESTATES}');
    create temp table gone_departments as
      select d.department_id from app.duties_departments d where d.name = '${DEPARTMENT}';
    create temp table gone_assignments as
      select a.assignment_id from app.duties_assignments a
        join app.duties_slots s on s.slot_id = a.slot_id
        join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
       where o.department_id in (select department_id from gone_departments);
    create temp table gone_jobs as
      select j.job_id from app.notifications_jobs j
       where j.recipient_member_id in (select member_id from gone_members)
          or j.source_id in (select assignment_id from gone_assignments)
          or j.source_id in (select m.meeting_id from app.cells_meetings m where m.cell_id in (select cell_id from gone_cells));
    delete from app.notifications_push_jobs p where p.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_attempts a where a.job_id in (select job_id from gone_jobs);
    delete from app.notifications_direct_contact_needs n where n.job_id in (select job_id from gone_jobs)
       or n.recipient_member_id in (select member_id from gone_members);
    update app.notifications_jobs j set snoozed_from_item_id = null where j.job_id in (select job_id from gone_jobs);
    delete from app.notifications_inbox_items i where i.job_id in (select job_id from gone_jobs)
       or i.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_jobs j where j.job_id in (select job_id from gone_jobs);
    delete from app.notifications_schedules s where s.recipient_member_id in (select member_id from gone_members)
       or s.source_id in (select assignment_id from gone_assignments)
       or s.source_id in (select m.meeting_id from app.cells_meetings m where m.cell_id in (select cell_id from gone_cells));
    delete from app.duties_contact_needs n where n.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_audit a where a.department_id in (select department_id from gone_departments)
       or a.actor_member_id in (select member_id from gone_members);
    delete from app.duties_slot_revisions r using app.duties_occurrences o
     where r.occurrence_id = o.occurrence_id and o.department_id in (select department_id from gone_departments);
    delete from app.duties_assignments a where a.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_slots s using app.duties_occurrences o
     where s.occurrence_id = o.occurrence_id and o.department_id in (select department_id from gone_departments);
    delete from app.duties_occurrences o where o.department_id in (select department_id from gone_departments);
    delete from app.duties_department_members dm where dm.department_id in (select department_id from gone_departments);
    delete from app.cells_meeting_contact_needs n
     where n.meeting_id in (select m.meeting_id from app.cells_meetings m where m.cell_id in (select cell_id from gone_cells));
    delete from app.cells_meeting_audit a where a.cell_id in (select cell_id from gone_cells)
       or a.actor_member_id in (select member_id from gone_members);
    delete from app.cells_meetings m where m.cell_id in (select cell_id from gone_cells);
    delete from app.cells_meeting_schedules s where s.cell_id in (select cell_id from gone_cells);
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
    delete from app.identity_grants g where g.member_id in (select member_id from gone_members)
       or g.scope_id in (select cell_id from gone_cells) or g.scope_id in (select department_id from gone_departments);
    delete from app.duties_departments d where d.department_id in (select department_id from gone_departments);
    delete from app.identity_grant_sets s where s.member_id in (select member_id from gone_members);
    delete from app.identity_holds h where h.member_id in (select member_id from gone_members);
    delete from app.identity_binding_history h using app.identity_account_links l
     where h.link_id = l.link_id and (l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users));
    delete from app.identity_credential_events e using app.identity_account_links l
     where e.link_id = l.link_id and (l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users));
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
    psql(`select app.platform_set_environment('local', 'calendar-overlays-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('O00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  try {
    const { admin, leader, member, other, pending } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      if (!p.noLink) p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'calendar-overlays-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    check('O01-members-signed-in-by-phone', Object.values(people).every((p) => amrMethods(p.token).includes('password')),
      { amr: amrMethods(admin.token) });

    // ------------------------------------------------------------------ cells, members, schedules
    const made = [];
    for (const [name, label] of [[SHIKOSWE, 'SYNTHETIC Shikoswe'], [ESTATES, 'SYNTHETIC Estates C5/C7']]) {
      made.push(await cells(admin.token, 'cells.create_cell', null, { name, signup_label: label, broad_area: 'SYNTHETIC Kafue' }));
    }
    const S = made[0].data?.cell_id;
    const E = made[1].data?.cell_id;
    const overview = async () => (await read('cells_admin_overview', admin.token)).json;
    let ov = await overview();
    const place = async (p, cell) => {
      ov = await overview();
      const row = ov?.members?.find((m) => m.member_id === p.member);
      const option = ov?.cells?.find((c) => c.cell_id === cell);
      const asked = await cells(admin.token, 'cells.request_change', row?.cell_revision,
        { member_id: p.member, cell_id: cell, cell_revision: option?.signup_revision });
      return cells(admin.token, 'cells.confirm_request', asked.revision, { request_id: asked.data?.open_request?.request_id });
    };
    const placed = [await place(member, S), await place(other, E)];
    const weekday = weekdayInTwoDays(Date.now());
    const schedules = [];
    for (const [cell, venue] of [[S, VENUE], [E, VENUE_E]]) {
      ov = await overview();
      const rev = ov?.cells?.find((c) => c.cell_id === cell)?.revision;
      schedules.push(await cells(admin.token, 'cells.set_schedule', rev,
        { cell_id: cell, weekday, start_time: '18:00', end_time: '19:30', venue }));
    }
    const board = (await read('cells_meetings', admin.token)).json;
    const idsOf = (cell) => (board?.cells?.find((c) => c.cell_id === cell)?.meetings ?? []).map((m) => m.meeting_id);
    const sMeetings = board?.cells?.find((c) => c.cell_id === S)?.meetings ?? [];
    const second = sMeetings[1];
    const cancelled = await cells(admin.token, 'cells.cancel_meeting', second?.revision, { meeting_id: second?.meeting_id });
    check('O02-cells-members-schedules-and-a-cancelled-meeting', made.every((m) => m.status === 200)
      && placed[0].data?.primary?.cell_id === S && placed[1].data?.primary?.cell_id === E
      && schedules.every((s) => s.status === 200) && idsOf(S).length >= 12 && idsOf(E).length >= 12
      && cancelled.status === 200 && cancelled.data?.state === 'cancelled',
      { cells: made.map((m) => m.status), placed: placed.map((p) => p.status), schedules: schedules.map((s) => s.status),
        meetings: [idsOf(S).length, idsOf(E).length], cancelled: cancelled.data?.state ?? cancelled.code });

    // ------------------------------------------------------------------ one duty each
    const department = await duties(admin.token, 'duties.create_department', null, { name: DEPARTMENT });
    const departmentId = department.data?.department_id;
    const dutyOverview = (await read('duties_admin_overview', admin.token)).json;
    const grantsRev = dutyOverview?.members?.find((m) => m.member_id === leader.member)?.grants_revision;
    const grant = await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantsRev,
      { member_id: leader.member, scope_kind: 'department_leader', scope_id: departmentId });
    const addM = await duties(admin.token, 'duties.add_member', 1, { department_id: departmentId, member_id: member.member });
    const addO = await duties(admin.token, 'duties.add_member', 2, { department_id: departmentId, member_id: other.member });
    const publish = (p, days) => duties(leader.token, 'duties.publish_duty', null, {
      department_id: departmentId, duty_name: 'SYNTHETIC Main door', starts_at: at(days * DAY),
      ends_at: at(days * DAY + 7_200_000), location: 'SYNTHETIC Main sanctuary', instructions: 'SYNTHETIC: arrive early.',
      member_id: p.member, response_deadline: at((days - 2) * DAY),
    });
    const dutyM = await publish(member, 10);
    const dutyO = await publish(other, 12);
    check('O03-one-duty-each', department.status === 200 && grant.status === 200 && addM.status === 200
      && addO.status === 200 && dutyM.status === 200 && dutyO.status === 200,
      { department: department.status, grant: grant.status, added: [addM.status, addO.status],
        published: [dutyM.status, dutyO.status], codes: [dutyM.code ?? null, dutyO.code ?? null] });

    // ------------------------------------------------------------------ the new Cells read
    const now = Date.now();
    const until = now + WINDOW_DAYS * DAY;
    const mineM = await read('cells_my_meetings', member.token);
    const mineO = await read('cells_my_meetings', other.token);
    const cancelledRow = (mineM.json?.meetings ?? []).find((m) => m.meeting_id === second?.meeting_id);
    const text = JSON.stringify(mineM.json ?? {}) + JSON.stringify(mineO.json ?? {});
    check('O10-member-reads-only-their-own-cell-meetings-for-the-month', mineM.status === 200
      && mineM.json?.cell_id === S && onlyOwnMeetings(mineM.json, idsOf(S), idsOf(E), now - 60_000, until + 60_000)
      && mineM.json.meetings.length >= 4 && mineM.json.meetings.length <= 5
      && cancelledRow?.state === 'cancelled',
      { status: mineM.status, own_cell: mineM.json?.cell_id === S, meetings: mineM.json?.meetings?.length ?? null,
        cancelled_marked: cancelledRow?.state ?? null });
    check('O11-other-member-reads-only-their-cell', mineO.status === 200 && mineO.json?.cell_id === E
      && onlyOwnMeetings(mineO.json, idsOf(E), idsOf(S), now - 60_000, until + 60_000),
      { status: mineO.status, own_cell: mineO.json?.cell_id === E, meetings: mineO.json?.meetings?.length ?? null });
    check('O12-no-venue-on-the-overlay-read', !text.includes(VENUE) && !text.includes(VENUE_E)
      && meetingKeys(mineM.json) === 'ends_at,meeting_id,occurrence_date,starts_at,state',
      { keys: meetingKeys(mineM.json) });

    // ------------------------------------------------------------------ the 4.5 My duties read
    const dutiesM = await read('duties_my_duties', member.token);
    const listed = (dutiesM.json?.assignments ?? []).map((a) => a.assignment_id);
    check('O20-member-reads-only-their-own-duties', dutiesM.status === 200
      && listed.includes(dutyM.data?.assignment_id) && !listed.includes(dutyO.data?.assignment_id)
      && (dutiesM.json?.assignments ?? []).every((a) => a.response === 'pending' || a.response === 'accepted'),
      { status: dutiesM.status, own: listed.includes(dutyM.data?.assignment_id), others: listed.includes(dutyO.data?.assignment_id) });

    // ------------------------------------------------------------------ refusals
    const pendingCells = await read('cells_my_meetings', pending.token);
    const pendingDuties = await read('duties_my_duties', pending.token);
    const guest = await read('cells_my_meetings', undefined);
    check('O30-pending-and-guest-are-refused', pendingCells.status >= 400 && pendingCells.status < 500
      && pendingDuties.status >= 400 && guest.status >= 400 && guest.status < 500
      && !JSON.stringify(pendingCells.json ?? {}).includes('meeting_id') && !JSON.stringify(guest.json ?? {}).includes('meeting_id'),
      { pending: pendingCells.status, pending_duties: pendingDuties.status, guest: guest.status });

    // ------------------------------------------------------------------ My cell unchanged
    const myCell = await read('cells_my_cell', member.token);
    check('O40-my-cell-unchanged', myCell.status === 200 && myCell.json?.meetings?.cell_id === S
      && myCell.json?.meetings?.next?.venue === VENUE && Array.isArray(myCell.json?.meetings?.cancelled),
      { status: myCell.status, next_has_venue: myCell.json?.meetings?.next?.venue === VENUE });

    const tables = [];
    for (const t of ['cells_meetings', 'cells_memberships', 'duties_assignments']) {
      for (const profile of ['app', 'api']) {
        const r = await http('GET', `/rest/v1/${t}?select=*`, { token: member.token, profile });
        tables.push({ t, profile, status: r.status, refused: r.status >= 400 && !Array.isArray(r.json) });
      }
    }
    check('O50-direct-table-queries-refused', tables.every((x) => x.refused),
      { statuses: tables.map((x) => `${x.profile}.${x.t}:${x.status}`) });
  } finally {
    const left = cleanup();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'calendar-overlays-e2e';
            delete from app.platform_environment_history where set_by = 'calendar-overlays-e2e';`);
    }
    log('O99-cleanup', { users_left: Number(left), unmarked: marked,
      cells_left: Number(psql(`select count(*) from app.cells_cells where name in ('${SHIKOSWE}', '${ESTATES}')`)),
      departments_left: Number(psql(`select count(*) from app.duties_departments where name = '${DEPARTMENT}'`)) });
  }
  finish();
}

runMain(import.meta.url, main);
