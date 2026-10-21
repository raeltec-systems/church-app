#!/usr/bin/env node
// Story 5.1 end-to-end on the LOCAL stack: a cell's weekly meetings through real GoTrue phone
// sign-in (no SMS) and the real Data API (PostgREST), proving the ticket's verify at the API level:
//   * an Admin sets a weekly schedule (church time, private venue and map pin) on a SYNTHETIC
//     Shikoswe cell; a leader cannot; twelve weeks of meetings are generated at 18:00 church time;
//   * meeting ids are stable across regeneration (reads and a second schedule save);
//   * the leader moves one meeting and cancels another; both keep their ids through regeneration;
//     the assistant and another cell's leader are refused; a replay answers its stored result;
//   * a confirmed member reads the next meeting with its venue on My cell; a member of the
//     SYNTHETIC Estates C5/C7 cell, an account without member access (a pending applicant has no
//     member link) and Admin-only access read no Shikoswe venue;
//   * direct table queries are refused and the audit holds no venue, names or numbers.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900200-900209. Evidence is redacted JSONL:
// statuses, codes, counts; never tokens, passwords, numbers or the venue. Everything it created is
// removed.
//
// Usage: node tools/identity-e2e/cells-meetings.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';
import { churchClock } from './duties-shared.mjs';

export { churchClock } from './duties-shared.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 5.1 E2E';
export const SHIKOSWE = 'SYNTHETIC Shikoswe Cell (5.1 E2E)';
export const ESTATES = 'SYNTHETIC Estates C5/C7 Cell (5.1 E2E)';
const VENUE = 'SYNTHETIC 12 Shikoswe Road';
const HALL = 'SYNTHETIC Church hall';

/** The reserved fictional numbers this run uses (+44 7700 900200-900209). */
export function isFictionalMeetingsPhone(phone) {
  return /^\+44770090020[0-9]$/.test(phone);
}

/** meeting_id by occurrence_date for one cell of an api.cells_meetings read. */
export function meetingIds(board, cellId) {
  const cell = (board?.cells ?? []).find((c) => c.cell_id === cellId);
  return Object.fromEntries((cell?.meetings ?? []).map((m) => [m.occurrence_date, m.meeting_id]));
}

/** Every key of `before` maps to the same id in `after`. */
export function sameIds(before, after) {
  const keys = Object.keys(before);
  return keys.length > 0 && keys.every((k) => after[k] === before[k]);
}

/** The ISO weekday (1 = Monday) two church days after `nowMs`, so the first meeting is ahead. */
export function weekdayInTwoDays(nowMs) {
  const d = new Date(nowMs + 2 * 3_600_000 + 2 * 86_400_000).getUTCDay();
  return d === 0 ? 7 : d;
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
  const cells = (token, cmd, expected, payload, requestId) => envelope('cells_command', token, cmd, expected, payload, requestId);
  const read = async (fn, token) => {
    const r = await rpc(fn, token);
    return { status: r.status, json: r.json, detail: r.json?.details ?? null };
  };

  const people = {
    admin: { phone: '+447700900200', name: `${NAME_PREFIX} Admin` },
    leader: { phone: '+447700900201', name: `${NAME_PREFIX} Leader S` },
    assistant: { phone: '+447700900202', name: `${NAME_PREFIX} Assistant S` },
    member: { phone: '+447700900203', name: `${NAME_PREFIX} Member S` },
    estates: { phone: '+447700900204', name: `${NAME_PREFIX} Member E` },
    estatesLeader: { phone: '+447700900205', name: `${NAME_PREFIX} Leader E` },
    pending: { phone: '+447700900206', name: `${NAME_PREFIX} Pending`, noLink: true },
  };
  for (const p of Object.values(people)) if (!isFictionalMeetingsPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
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
       or g.scope_id in (select cell_id from gone_cells);
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
    psql(`select app.platform_set_environment('local', 'cells-meetings-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('M00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  try {
    const { admin, leader, assistant, member, estates, estatesLeader, pending } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      if (!p.noLink) p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'cells-meetings-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    check('M01-members-signed-in-by-phone', Object.values(people).every((p) => amrMethods(p.token).includes('password')),
      { amr: amrMethods(admin.token) });

    // ------------------------------------------------------------------ setup: cells, roles, members
    const made = [];
    for (const [name, label] of [[SHIKOSWE, 'SYNTHETIC Shikoswe'], [ESTATES, 'SYNTHETIC Estates C5/C7']]) {
      made.push(await cells(admin.token, 'cells.create_cell', null, { name, signup_label: label, broad_area: 'SYNTHETIC Kafue' }));
    }
    const S = made[0].data?.cell_id;
    const E = made[1].data?.cell_id;
    const overview = async () => (await read('cells_admin_overview', admin.token)).json;
    let ov = await overview();
    const grantsRev = (p) => ov?.members?.find((m) => m.member_id === p.member)?.grants_revision;
    const grants = [];
    for (const [p, kind, cell] of [[leader, 'cell_leader', S], [assistant, 'cell_assistant', S], [estatesLeader, 'cell_leader', E]]) {
      grants.push(await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantsRev(p),
        { member_id: p.member, scope_kind: kind, scope_id: cell }));
    }
    const place = async (p, cell) => {
      ov = await overview();
      const row = ov?.members?.find((m) => m.member_id === p.member);
      const option = ov?.cells?.find((c) => c.cell_id === cell);
      const asked = await cells(admin.token, 'cells.request_change', row?.cell_revision,
        { member_id: p.member, cell_id: cell, cell_revision: option?.signup_revision });
      return cells(admin.token, 'cells.confirm_request', asked.revision, { request_id: asked.data?.open_request?.request_id });
    };
    const placed = [await place(member, S), await place(estates, E)];
    check('M02-cells-roles-and-confirmed-members', made.every((m) => m.status === 200) && grants.every((g) => g.status === 200)
      && placed[0].data?.primary?.cell_id === S && placed[1].data?.primary?.cell_id === E,
      { cells: made.map((m) => m.status), grants: grants.map((g) => g.status), placed: placed.map((p) => p.status) });

    // ------------------------------------------------------------------ the weekly schedule (Admin)
    const weekday = weekdayInTwoDays(Date.now());
    const schedule = { cell_id: S, weekday, start_time: '18:00', end_time: '19:30', venue: VENUE,
      map_pin: { lat: -15.77123, lng: 28.18456 } };
    ov = await overview();
    const cellRev = () => ov?.cells?.find((c) => c.cell_id === S)?.revision;
    const byLeader = await cells(leader.token, 'cells.set_schedule', cellRev(), schedule);
    const set1 = await cells(admin.token, 'cells.set_schedule', cellRev(), schedule);
    const board = async (p) => (await read('cells_meetings', p.token));
    const b1 = (await board(leader)).json;
    const ids1 = meetingIds(b1, S);
    const meetings1 = b1?.cells?.find((c) => c.cell_id === S)?.meetings ?? [];
    check('M10-admin-sets-the-weekly-schedule-in-church-time', byLeader.code === 'forbidden' && set1.status === 200
      && meetings1.length >= 12 && meetings1.length <= 13
      && meetings1.every((m) => churchClock(m.starts_at) === '18:00' && churchClock(m.ends_at) === '19:30')
      && meetings1.every((m) => { const d = new Date(`${m.occurrence_date}T00:00:00Z`).getUTCDay(); return (d === 0 ? 7 : d) === weekday; }),
      { leader_refused: byLeader.code, set: set1.status, meetings: meetings1.length,
        all_at_18_church_time: meetings1.every((m) => churchClock(m.starts_at) === '18:00') });

    // Regeneration: two more reads and an unchanged schedule save keep every id.
    const ids2 = meetingIds((await board(assistant)).json, S);
    ov = await overview();
    const set2 = await cells(admin.token, 'cells.set_schedule', cellRev(), { ...schedule, venue: undefined, map_pin: undefined });
    const ids3 = meetingIds((await board(leader)).json, S);
    check('M11-meeting-ids-stable-across-regeneration', sameIds(ids1, ids2) && sameIds(ids1, ids3) && set2.status === 200,
      { meetings: Object.keys(ids1).length, after_read: sameIds(ids1, ids2), after_resave: sameIds(ids1, ids3) });

    // ------------------------------------------------------------------ move one, cancel another
    const second = meetings1[1];
    const third = meetings1[2];
    const shift = (iso, h) => new Date(Date.parse(iso) + h * 3_600_000).toISOString();
    const movePayload = { meeting_id: second.meeting_id, starts_at: shift(second.starts_at, 24), ends_at: shift(second.ends_at, 24), venue: HALL };
    const byAssistant = await cells(assistant.token, 'cells.move_meeting', second.revision, movePayload);
    const byOther = await cells(estatesLeader.token, 'cells.move_meeting', second.revision, movePayload);
    const moveRequest = randomUUID();
    const moved = await cells(leader.token, 'cells.move_meeting', second.revision, movePayload, moveRequest);
    const replay = await cells(leader.token, 'cells.move_meeting', second.revision, movePayload, moveRequest);
    const cancelled = await cells(leader.token, 'cells.cancel_meeting', third.revision, { meeting_id: third.meeting_id });
    check('M20-leader-moves-one-and-cancels-another', byAssistant.code === 'forbidden' && byOther.code === 'forbidden'
      && moved.status === 200 && moved.data?.state === 'moved' && moved.data?.meeting_id === second.meeting_id
      && moved.data?.venue === HALL && JSON.stringify(replay.data) === JSON.stringify(moved.data)
      && cancelled.status === 200 && cancelled.data?.state === 'cancelled' && cancelled.data?.meeting_id === third.meeting_id,
      { assistant: byAssistant.code, other_cell_leader: byOther.code, moved: moved.data?.state, replay_same: JSON.stringify(replay.data) === JSON.stringify(moved.data),
        cancelled: cancelled.data?.state });

    const b4 = (await board(leader)).json;
    const ids4 = meetingIds(b4, S);
    const after = (id) => (b4?.cells?.find((c) => c.cell_id === S)?.meetings ?? []).find((m) => m.meeting_id === id);
    check('M21-exceptions-keep-their-ids-through-regeneration', sameIds(ids1, ids4)
      && after(second.meeting_id)?.state === 'moved' && after(third.meeting_id)?.state === 'cancelled',
      { same_ids: sameIds(ids1, ids4), moved_state: after(second.meeting_id)?.state, cancelled_state: after(third.meeting_id)?.state });

    // ------------------------------------------------------------------ who sees the venue
    const mine = async (p) => read('cells_my_cell', p.token);
    const m1 = await mine(member);
    const next = m1.json?.meetings?.next;
    check('M30-confirmed-member-reads-the-next-meeting-and-venue', m1.status === 200 && next?.meeting_id === meetings1[0].meeting_id
      && next?.venue === VENUE && next?.map_pin?.lat === -15.77123 && churchClock(next?.starts_at) === '18:00',
      { status: m1.status, is_first_meeting: next?.meeting_id === meetings1[0].meeting_id, venue_shown: next?.venue === VENUE,
        pin_shown: Boolean(next?.map_pin) });

    const e1 = await mine(estates);
    const p1 = await mine(pending);
    const a1 = await mine(admin);
    const adminBoard = (await board(admin)).json?.cells?.find((c) => c.cell_id === S);
    const estatesBoard = await board(estates);
    const noVenue = (r) => !JSON.stringify(r.json ?? {}).includes(VENUE);
    check('M31-others-read-no-shikoswe-venue', e1.status === 200 && e1.json?.meetings === null && noVenue(e1)
      && p1.status >= 400 && noVenue(p1) && a1.status === 200 && a1.json?.meetings === null && noVenue(a1)
      && adminBoard?.schedule?.venue === null && adminBoard?.schedule?.venue_set === true
      && adminBoard?.meetings?.every((m) => m.venue === null) && estatesBoard.status === 403,
      { estates_member: e1.json?.meetings ?? null, pending_applicant: p1.status, admin_my_cell: a1.json?.meetings ?? null,
        admin_board_venue: adminBoard?.schedule?.venue ?? null, admin_venue_set: adminBoard?.schedule?.venue_set,
        estates_member_staff_read: estatesBoard.status });

    // ------------------------------------------------------------------ direct tables and audit
    const tables = [];
    for (const t of ['cells_meeting_schedules', 'cells_meetings', 'cells_meeting_audit']) {
      for (const profile of ['app', 'api']) {
        const r = await http('GET', `/rest/v1/${t}?select=*`, { token: leader.token, profile });
        tables.push({ t, profile, status: r.status, refused: r.status >= 400 && !Array.isArray(r.json) });
      }
    }
    check('M40-direct-table-queries-refused', tables.every((x) => x.refused),
      { statuses: tables.map((x) => `${x.profile}.${x.t}:${x.status}`) });
    const auditText = psql(`select coalesce(string_agg(a::text, ' '), '') from app.cells_meeting_audit a
                             where a.cell_id = '${S}'`);
    const leaked = [VENUE, HALL, ...Object.values(people).map((p) => p.phone.slice(1)), ...Object.values(people).map((p) => p.name)]
      .filter((v) => auditText.includes(v));
    check('M50-audit-content-free', leaked.length === 0 && auditText.length > 0, { leaked_values: leaked.length,
      actions: psql(`select string_agg(distinct action, ',' order by action) from app.cells_meeting_audit where cell_id = '${S}'`) });
  } finally {
    const left = cleanup();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'cells-meetings-e2e';
            delete from app.platform_environment_history where set_by = 'cells-meetings-e2e';`);
    }
    log('M99-cleanup', { users_left: Number(left), unmarked: marked,
      meetings_left: Number(psql(`select count(*) from app.cells_meetings m join app.cells_cells c using (cell_id)
                                  where c.name in ('${SHIKOSWE}', '${ESTATES}')`)) });
  }
  finish();
}

runMain(import.meta.url, main);
