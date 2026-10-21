#!/usr/bin/env node
// Story 5.10: the synthetic cell pilot rehearsal. It runs a cell's programme loop through the public
// API (real GoTrue phone sign-in, no SMS, and the Data API) with `SYNTHETIC Shikoswe Cell` and
// `SYNTHETIC Estates C5/C7 Cell` (marked "(pilot)"), a leader, an assistant, app members M and O and
// an accountless member X, and no chat anywhere:
//
//   P10 a published programme asks each person for an answer (M and O in My duties, X on the board)
//   P20 a time change (the meeting moves) asks again: M's earlier Accept is superseded by a new
//       pending answer once the leader republishes
//   P30 M's Cannot attend notice changes no answer and no attendance; the leader sees the warning
//   P40 X (no login) is Confirmed by leader, labelled as the leader's
//   P50 after the meeting: held, X stood in for M (a substitute is the actual leader), corrected
//       with a reason; the plan and the answers stay as they were
//   P60 nothing depends on chat (no chat table or function, and no dependency on the planned chat
//       module from the modules used here); nothing private reaches O
//
// LOCAL only (exact origin), SYNTHETIC fictional numbers +44 7700 900080-900089. Needs
// `node tools/auth-harness/local-phone-auth.mjs on` and a database with no usable Admin
// (`npx supabase db reset` first). The meeting is moved into the past directly in the database
// before P50 (the stand-in for time passing). Evidence is redacted JSONL. Everything it created is
// removed. The owner's walkthrough on staging is docs/runbooks/cells-guides.md.
//
// Usage: node tools/identity-e2e/cells-pilot.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { cellsCleanupSql } from './cells-cleanup.mjs';
import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';
import { weekdayInTwoDays } from './cells-meetings.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 5.10 pilot';
export const SHIKOSWE = 'SYNTHETIC Shikoswe Cell (pilot)';
export const ESTATES = 'SYNTHETIC Estates C5/C7 Cell (pilot)';
export const DEPARTMENT = 'SYNTHETIC Ushers (pilot)';
const VENUE = 'SYNTHETIC 12 Shikoswe Road';
const TOPIC = 'SYNTHETIC Rooted in love';
const NOTE = 'SYNTHETIC leader-only away that week';
const REASON = 'SYNTHETIC leader-only said yes on the phone';

/** The reserved fictional numbers this run uses (+44 7700 900080-900089). */
export function isFictionalPilotPhone(phone) {
  return /^\+44770090008[0-9]$/.test(phone);
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
    admin: { phone: '+447700900080', name: `${NAME_PREFIX} Admin` },
    leader: { phone: '+447700900081', name: `${NAME_PREFIX} Leader S` },
    assistant: { phone: '+447700900082', name: `${NAME_PREFIX} Assistant S` },
    member: { phone: '+447700900083', name: `${NAME_PREFIX} Member S` },
    other: { phone: '+447700900084', name: `${NAME_PREFIX} Other S` },
    estatesLeader: { phone: '+447700900085', name: `${NAME_PREFIX} Leader E` },
    pastor: { phone: '+447700900086', name: `${NAME_PREFIX} Pastor` },
  };
  for (const p of Object.values(people)) if (!isFictionalPilotPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  const users = new Set();
  const cleanup = () => psql(cellsCleanupSql({
    namePrefix: NAME_PREFIX, shikoswe: SHIKOSWE, estates: ESTATES, department: DEPARTMENT,
    userIds: users, phones: Object.values(people).map((p) => p.phone),
  }));

  const settings = await http('GET', '/auth/v1/settings');
  if (settings.json?.external?.phone !== true) {
    throw new Error('the local phone provider is off: run `node tools/auth-harness/local-phone-auth.mjs on` first');
  }
  const marker = psql(`select coalesce((select environment from app.platform_environment), '')`);
  let marked = false;
  if (marker === '') {
    psql(`select app.platform_set_environment('local', 'cells-pilot')`);
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
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'cells-pilot')`);
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

    const M = meeting?.meeting_id;
    const myDuty = async (p, name) => ((await read('duties_my_duties', p.token)).json?.assignments ?? [])
      .find((a) => a.duty_name === name);
    const staff = async () => (await read('cells_programme', leader.token, { meeting_id: M })).json;
    const partOf = (st, label) => (st?.programme?.parts ?? []).find((pt) => pt.label === label);
    const dutyOf = (st, label) => (st?.duties ?? []).find((d) => d.part_id === partOf(st, label)?.part_id)
      ?.positions?.[0]?.assignment;

    // ------------------------------------------------------------------ P10 responses requested
    const s10 = await staff();
    const m10 = await myDuty(member, 'SYNTHETIC Opening prayer');
    const o10 = await myDuty(other, 'SYNTHETIC Bible study');
    const x10 = dutyOf(s10, 'SYNTHETIC Worship');
    check('P10-published-asks-each-person', m10?.response === 'pending' && o10?.response === 'pending'
      && x10?.response === 'pending',
      { member: m10?.response, other: o10?.response, no_login: x10?.response });

    // ------------------------------------------------------------------ P20 a time change asks again
    const accepted = await duties(member.token, 'duties.respond', m10?.revision,
      { assignment_id: m10?.assignment_id, response: 'accepted' });
    const shift = (iso, mins) => new Date(Date.parse(iso) + mins * 60_000).toISOString();
    const meetingRev = () => Number(psql(`select revision from app.cells_meetings where meeting_id = '${M}'`));
    const moved = await cells(leader.token, 'cells.move_meeting', meetingRev(),
      { meeting_id: M, starts_at: shift(meeting?.starts_at, 30), ends_at: shift(meeting?.ends_at, 30) });
    const told = (await read('cells_meeting_programme', member.token, { meeting_id: M })).json?.programme?.meeting_changed;
    const republished = await cells(leader.token, 'cells.publish_programme', (await staff())?.programme?.revision,
      { programme_id: P });
    const m20 = await myDuty(member, 'SYNTHETIC Opening prayer');
    const old = psql(`select assignment_state || '|' || response from app.duties_assignments where assignment_id = '${m10?.assignment_id}'`);
    check('P20-time-change-asks-for-fresh-answers', accepted.data?.response === 'accepted' && moved.status === 200
      && told === true && republished.data?.state === 'published' && m20?.response === 'pending'
      && m20?.assignment_id !== m10?.assignment_id && old === 'superseded|accepted',
      { moved: moved.status, members_told: told, new_answer: m20?.response, earlier: old });

    // ------------------------------------------------------------------ P30 Cannot attend
    const before30 = await myDuty(member, 'SYNTHETIC Opening prayer');
    const notice = await cells(member.token, 'cells.send_cannot_attend', null, { meeting_id: M, note: NOTE });
    const after30 = await myDuty(member, 'SYNTHETIC Opening prayer');
    const s30 = await staff();
    const warned = (s30?.absences ?? []).find((a) => a.member_id === member.member);
    const attendance = psql(`select count(*) from information_schema.tables where table_schema = 'app' and table_name like '%attendance%'`);
    check('P30-cannot-attend-changes-no-answer-or-attendance', notice.data?.state === 'open'
      && after30?.response === before30?.response && after30?.revision === before30?.revision
      && warned?.part_ids?.length === 1 && attendance === '0',
      { notice: notice.data?.state, answer_unchanged: after30?.revision === before30?.revision,
        leader_warned: warned?.part_ids?.length === 1, attendance_tables: Number(attendance) });

    // ------------------------------------------------------------------ P40 Confirmed by leader for X
    const x40 = dutyOf(s30, 'SYNTHETIC Worship');
    const confirmed = await duties(leader.token, 'duties.confirm_by_leader', x40?.revision,
      { assignment_id: x40?.assignment_id, channel: 'phone', reason: REASON });
    const x41 = dutyOf(await staff(), 'SYNTHETIC Worship');
    check('P40-no-login-confirmed-by-leader', confirmed.status === 200 && x41?.response === 'accepted'
      && x41?.response_provenance === 'leader',
      { confirmed: confirmed.status, answer: x41?.response, provenance: x41?.response_provenance });

    // ------------------------------------------------------------------ P50 after the meeting
    const planBefore = psql(`select string_agg(label || ':' || coalesce(assignee_member_id::text, '-'), ',' order by position)
                               from app.cells_programme_parts where programme_id = '${P}'`);
    psql(shiftSql(M, 3));
    const held = await cells(leader.token, 'cells.record_meeting_held', null, { meeting_id: M, held: true });
    const parts = Object.fromEntries((((await staff())?.programme?.parts) ?? []).map((pt) => [pt.label, pt.part_id]));
    const led = await cells(leader.token, 'cells.record_actual_leaders', held.revision, { meeting_id: M, parts: [
      { part_id: parts['SYNTHETIC Opening prayer'], leader: { member_id: accountless } },
      { part_id: parts['SYNTHETIC Worship'], leader: { member_id: accountless } },
      { part_id: parts['SYNTHETIC Bible study'], leader: { member_id: other.member } },
    ] });
    const corrected = await cells(assistant.token, 'cells.record_actual_leaders', led.revision, { meeting_id: M, parts: [
      { part_id: parts['SYNTHETIC Bible study'], leader: null, reason: 'SYNTHETIC leader-only it ran out of time' }] });
    const ref = JSON.parse(psql(`select app.cells_meeting_reference('${M}')::text`));
    const byPart = Object.fromEntries((ref?.actual_leaders ?? []).map((a) => [a.label, a]));
    const planAfter = psql(`select string_agg(label || ':' || coalesce(assignee_member_id::text, '-'), ',' order by position)
                              from app.cells_programme_parts where programme_id = '${P}'`);
    const m50 = await myDuty(member, 'SYNTHETIC Opening prayer');
    check('P50-substitute-is-the-actual-leader', held.data?.held === true && led.data?.changed === 3
      && corrected.data?.changed === 1 && byPart['SYNTHETIC Opening prayer']?.substitute === true
      && byPart['SYNTHETIC Worship']?.substitute === false && byPart['SYNTHETIC Bible study']?.kind === 'nobody'
      && planAfter === planBefore && m50?.response === after30?.response,
      { held: held.data?.held, substitute: byPart['SYNTHETIC Opening prayer']?.substitute,
        corrected: corrected.data?.changed, plan_unchanged: planAfter === planBefore, member_answer: m50?.response });

    // ------------------------------------------------------------------ P60 no chat; nothing private for O
    // Chat is only a planned optional module in the registry (the platform orchestration lists it):
    // no module the pilot uses depends on it, and it has no
    // tables, functions or links (its own epic, gated separately).
    const chat = psql(`select (select count(*) from app.contract_module_dependencies where to_module = 'chat'
                                and from_module in ('cells', 'duties', 'followups', 'notifications', 'identity'))
                            + (select count(*) from information_schema.tables where table_schema in ('app', 'api')
                                                                              and table_name like '%chat%')
                            + (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                                where n.nspname in ('app', 'api') and p.proname like 'chat%')`);
    const oRead = await read('cells_meeting_programme', other.token, { meeting_id: M });
    const oStaff = await read('cells_programme', other.token, { meeting_id: M });
    const oDuties = JSON.stringify((await read('duties_my_duties', other.token)).json ?? {});
    const leak = [JSON.stringify(oRead.json ?? {}), oDuties].some((t) => t.includes('SYNTHETIC leader-only'));
    check('P60-no-chat-and-nothing-private-for-a-member', chat === '0' && oRead.status === 200 && oStaff.status === 403
      && !leak && !('record' in (oRead.json ?? {})),
      { chat_objects: Number(chat), member_read: oRead.status, staff_read: oStaff.status, leader_only_text_seen: leak });
  } finally {
    const left = cleanup();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'cells-pilot';
            delete from app.platform_environment_history where set_by = 'cells-pilot';`);
    }
    log('A99-cleanup', { users_left: Number(left), unmarked: marked,
      programmes_left: Number(psql(`select count(*) from app.cells_programmes p join app.cells_cells c using (cell_id)
                                    where c.name in ('${SHIKOSWE}', '${ESTATES}')`)) });
  }
  finish();
}

runMain(import.meta.url, main);
