#!/usr/bin/env node
// Story 5.7 end-to-end on the LOCAL stack: Cannot attend notices through real GoTrue phone sign-in
// (no SMS) and the real Data API (PostgREST), proving the ticket's verify at the API level:
//   * a member with a part and one without send notices; the cell's leader and assistant get an
//     inbox notice each (generic text); the parts stay Awaiting or Accepted;
//   * the member changes the note and withdraws the notice; the leader is told each time;
//   * no attendance record exists; another member cannot read the notice or its note, change it or
//     withdraw it; the audit holds no note.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900050-900059. Evidence is redacted JSONL:
// statuses, codes, counts; never tokens, passwords, numbers, names or programme text. Everything it
// created is removed.
//
// Usage: node tools/identity-e2e/cells-absence.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { cellsCleanupSql } from './cells-cleanup.mjs';
import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';
import { weekdayInTwoDays } from './cells-meetings.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 5.7 E2E';
export const SHIKOSWE = 'SYNTHETIC Shikoswe Cell (5.7 E2E)';
export const ESTATES = 'SYNTHETIC Estates C5/C7 Cell (5.7 E2E)';
export const DEPARTMENT = 'SYNTHETIC Ushers (5.7 E2E)';
const VENUE = 'SYNTHETIC 12 Shikoswe Road';
const TOPIC = 'SYNTHETIC Rooted in love';
const NOTE = 'SYNTHETIC travelling for work';
const NOTE2 = 'SYNTHETIC back on Friday';

/** The reserved fictional numbers this run uses (+44 7700 900050-900059). */
export function isFictionalAbsencePhone(phone) {
  return /^\+44770090005[0-9]$/.test(phone);
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
    admin: { phone: '+447700900050', name: `${NAME_PREFIX} Admin` },
    leader: { phone: '+447700900051', name: `${NAME_PREFIX} Leader S` },
    assistant: { phone: '+447700900052', name: `${NAME_PREFIX} Assistant S` },
    member: { phone: '+447700900053', name: `${NAME_PREFIX} Member S` },
    other: { phone: '+447700900054', name: `${NAME_PREFIX} Other S` },
    estatesLeader: { phone: '+447700900055', name: `${NAME_PREFIX} Leader E` },
    pastor: { phone: '+447700900056', name: `${NAME_PREFIX} Pastor` },
  };
  for (const p of Object.values(people)) if (!isFictionalAbsencePhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
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
    psql(`select app.platform_set_environment('local', 'cells-absence-e2e')`);
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
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'cells-absence-e2e')`);
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

    // ------------------------------------------------------------------ send
    const send = (p, note) => cells(p.token, 'cells.send_cannot_attend', null,
      { meeting_id: meeting?.meeting_id, ...(note ? { note } : {}) });
    const myDuty = async (p, name) => ((await read('duties_my_duties', p.token)).json?.assignments ?? [])
      .find((a) => a.duty_name === name);
    const beforeMember = await myDuty(member, 'SYNTHETIC Opening prayer');
    const accepted = await duties(member.token, 'duties.respond', beforeMember?.revision,
      { assignment_id: beforeMember?.assignment_id, response: 'accepted' });
    const beforeOther = await myDuty(other, 'SYNTHETIC Bible study');
    const s1 = await send(member, NOTE);
    const s2 = await send(other);
    const notice = s1.data?.notice_id;
    const leaderJobs = psql(`select count(*) from app.notifications_jobs where source_type = 'cells_absence_notice'
                               and source_id = '${notice}' and reminder_kind = 'cells_absence_sent'
                               and recipient_member_id in ('${leader.member}', '${assistant.member}')`);
    const afterMember = await myDuty(member, 'SYNTHETIC Opening prayer');
    const afterOther = await myDuty(other, 'SYNTHETIC Bible study');
    check('A10-notices-sent-leaders-told-parts-untouched', accepted.data?.response === 'accepted'
      && s1.data?.state === 'open' && s1.data?.notified === 2 && s2.data?.state === 'open' && leaderJobs === '2'
      && afterMember?.response === 'accepted' && afterMember?.revision === accepted.data?.revision
      && afterOther?.response === 'pending' && afterOther?.revision === beforeOther?.revision,
      { sent: [s1.data?.state, s2.data?.state], leader_notices: Number(leaderJobs),
        member_part: afterMember?.response, other_part: afterOther?.response });

    // ------------------------------------------------------------------ who reads it
    const staff = (await read('cells_programme', leader.token, { meeting_id: meeting?.meeting_id })).json;
    const mine = (await read('cells_meeting_programme', member.token, { meeting_id: meeting?.meeting_id })).json;
    const otherRead = (await read('cells_meeting_programme', other.token, { meeting_id: meeting?.meeting_id })).json;
    const leaderSees = (staff?.absences ?? []).find((a) => a.member_id === member.member);
    const noAttendance = psql(`select count(*) from information_schema.tables where table_schema = 'app' and table_name like '%attendance%'`);
    check('A20-leader-reads-it-others-do-not', (staff?.absences ?? []).length === 2 && leaderSees?.note === NOTE
      && leaderSees?.part_ids?.length === 1 && mine?.my_absence?.note === NOTE
      && !JSON.stringify(otherRead ?? {}).includes(NOTE) && noAttendance === '0',
      { leader_reads: (staff?.absences ?? []).length, part_warning: leaderSees?.part_ids?.length,
        other_member_sees_note: JSON.stringify(otherRead ?? {}).includes(NOTE), attendance_tables: Number(noAttendance) });

    // ------------------------------------------------------------------ change and withdraw
    const byOther = await cells(other.token, 'cells.change_cannot_attend', 1, { notice_id: notice, note: 'not mine' });
    const changed = await cells(member.token, 'cells.change_cannot_attend', 1, { notice_id: notice, note: NOTE2 });
    // The leaders' inbox got it (stands in for the worker's delivery): a withdrawal is then announced.
    psql(`update app.notifications_jobs set job_state = 'delivered', finished_at = now(), processed_by_principal = gen_random_uuid()
           where source_id = '${notice}' and reminder_kind = 'cells_absence_sent' and job_state = 'pending'`);
    const otherWithdraw = await cells(other.token, 'cells.withdraw_cannot_attend', changed.revision, { notice_id: notice });
    const withdrawn = await cells(member.token, 'cells.withdraw_cannot_attend', changed.revision, { notice_id: notice });
    const told = psql(`select count(*) from app.notifications_jobs where source_id = '${notice}'
                         and reminder_kind = 'cells_absence_withdrawn'`);
    const staff2 = (await read('cells_programme', leader.token, { meeting_id: meeting?.meeting_id })).json;
    const auditText = psql(`select coalesce(string_agg(a::text, ' '), '') from app.cells_absence_audit a where a.notice_id = '${notice}'`);
    check('A30-change-and-withdraw', byOther.code === 'not_found' && changed.data?.note === NOTE2
      && otherWithdraw.code === 'not_found' && withdrawn.data?.state === 'withdrawn' && told === '2'
      && !(staff2?.absences ?? []).some((a) => a.member_id === member.member)
      && !auditText.includes(NOTE) && !auditText.includes(NOTE2) && auditText.length > 0,
      { other_change: byOther.code, changed: Boolean(changed.data?.note), other_withdraw: otherWithdraw.code,
        withdrawn: withdrawn.data?.state, leaders_told: Number(told), audit_holds_note: auditText.includes(NOTE) });
  } finally {
    const left = cleanup();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'cells-absence-e2e';
            delete from app.platform_environment_history where set_by = 'cells-absence-e2e';`);
    }
    log('A99-cleanup', { users_left: Number(left), unmarked: marked,
      programmes_left: Number(psql(`select count(*) from app.cells_programmes p join app.cells_cells c using (cell_id)
                                    where c.name in ('${SHIKOSWE}', '${ESTATES}')`)) });
  }
  finish();
}

runMain(import.meta.url, main);
