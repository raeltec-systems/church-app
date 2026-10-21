#!/usr/bin/env node
// Story 5.9 end-to-end on the LOCAL stack: a transfer's effects through real GoTrue phone sign-in
// (no SMS) and the real Data API (PostgREST), proving the ticket's verify at the API level:
//   * a member with an accepted part and an open Cannot attend notice moves from SYNTHETIC
//     Shikoswe to SYNTHETIC Estates C5/C7: old-cell programme and venue reads are refused at once,
//     the new cell opens;
//   * the part is a gap, its duty ended (vacated) and released to the member, the old cell's leader
//     and assistant told; the notice closed; another member's part untouched;
//   * revoking the last leader of a cell with a programme published ahead is refused
//     (handover_required); a deletion check answers zero.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900070-900079. Evidence is redacted JSONL:
// statuses, codes, counts; never tokens, passwords, numbers, names or programme text. Everything it
// created is removed.
//
// Usage: node tools/identity-e2e/cells-transfer.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { cellsCleanupSql } from './cells-cleanup.mjs';
import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';
import { weekdayInTwoDays } from './cells-meetings.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 5.9 E2E';
export const SHIKOSWE = 'SYNTHETIC Shikoswe Cell (5.9 E2E)';
export const ESTATES = 'SYNTHETIC Estates C5/C7 Cell (5.9 E2E)';
export const DEPARTMENT = 'SYNTHETIC Ushers (5.9 E2E)';
const VENUE = 'SYNTHETIC 12 Shikoswe Road';
const TOPIC = 'SYNTHETIC Rooted in love';
const NOTE = 'SYNTHETIC away that week';

/** The reserved fictional numbers this run uses (+44 7700 900070-900079). */
export function isFictionalTransferPhone(phone) {
  return /^\+44770090007[0-9]$/.test(phone);
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
    admin: { phone: '+447700900070', name: `${NAME_PREFIX} Admin` },
    leader: { phone: '+447700900071', name: `${NAME_PREFIX} Leader S` },
    assistant: { phone: '+447700900072', name: `${NAME_PREFIX} Assistant S` },
    member: { phone: '+447700900073', name: `${NAME_PREFIX} Member S` },
    other: { phone: '+447700900074', name: `${NAME_PREFIX} Other S` },
    estatesLeader: { phone: '+447700900075', name: `${NAME_PREFIX} Leader E` },
    pastor: { phone: '+447700900076', name: `${NAME_PREFIX} Pastor` },
  };
  for (const p of Object.values(people)) if (!isFictionalTransferPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
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
    psql(`select app.platform_set_environment('local', 'cells-transfer-e2e')`);
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
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'cells-transfer-e2e')`);
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

    // ------------------------------------------------------------------ before the move
    const M = meeting?.meeting_id;
    const myDuty = async (p, name) => ((await read('duties_my_duties', p.token)).json?.assignments ?? [])
      .find((a) => a.duty_name === name);
    const mine = await myDuty(member, 'SYNTHETIC Opening prayer');
    const accepted = await duties(member.token, 'duties.respond', mine?.revision,
      { assignment_id: mine?.assignment_id, response: 'accepted' });
    const otherBefore = await myDuty(other, 'SYNTHETIC Bible study');
    const notice = await cells(member.token, 'cells.send_cannot_attend', null, { meeting_id: M, note: NOTE });
    const before = await read('cells_meeting_programme', member.token, { meeting_id: M });
    check('B10-before-the-move', accepted.data?.response === 'accepted' && notice.data?.state === 'open'
      && before.status === 200 && before.json?.meeting?.venue === VENUE,
      { accepted: accepted.data?.response, notice: notice.data?.state, programme_read: before.status });

    // ------------------------------------------------------------------ the move
    const moved = await place(member.member, E);
    member.token = (await signIn(member.phone, member.password)).json?.access_token;
    const oldRead = await read('cells_meeting_programme', member.token, { meeting_id: M });
    const myCell = (await read('cells_my_cell', member.token)).json;
    const oldVenue = JSON.stringify(myCell ?? {}).includes(VENUE);
    check('B20-old-cell-refused-new-cell-open', moved.status === 200 && oldRead.status === 403
      && myCell?.primary?.cell_id === E && !oldVenue,
      { moved: moved.status, old_programme_read: oldRead.status, new_cell: myCell?.primary?.cell_id === E,
        old_venue_shown: oldVenue });

    // ------------------------------------------------------------------ the part, its duty, the leaders
    const staff = (await read('cells_programme', leader.token, { meeting_id: M })).json;
    const parts = Object.fromEntries((staff?.programme?.parts ?? []).map((pt) => [pt.label, pt]));
    const duty = (staff?.duties ?? []).find((d) => d.part_id === parts['SYNTHETIC Opening prayer']?.part_id);
    const position = duty?.positions?.[0];
    const mineAfter = await myDuty(member, 'SYNTHETIC Opening prayer');
    const otherAfter = await myDuty(other, 'SYNTHETIC Bible study');
    const released = psql(`select count(*) from app.notifications_jobs where reminder_kind = 'duty_released'
                             and recipient_member_id = '${member.member}' and source_id = '${mine?.assignment_id}'`);
    const told = psql(`select count(*) from app.notifications_jobs where source_type = 'cells_programme'
                         and reminder_kind = 'cells_part_vacated' and source_id = '${P}'
                         and recipient_member_id in ('${leader.member}', '${assistant.member}')`);
    const ended = psql(`select assignment_state || ':' || end_reason from app.duties_assignments
                         where assignment_id = '${mine?.assignment_id}'`);
    check('B30-part-vacant-duty-released-leaders-told', parts['SYNTHETIC Opening prayer']?.assignee === null
      && parts['SYNTHETIC Bible study']?.assignee?.member_id === other.member
      && !position?.assignment && ended === 'superseded:vacated' && !mineAfter
      && otherAfter?.revision === otherBefore?.revision && released === '1' && told === '2'
      && staff?.programme?.revision > published.revision,
      { part: parts['SYNTHETIC Opening prayer']?.assignee === null ? 'gap' : 'kept', assignment: ended,
        member_sees_it: Boolean(mineAfter), other_part_unchanged: otherAfter?.revision === otherBefore?.revision,
        released: Number(released), leaders_told: Number(told) });

    // ------------------------------------------------------------------ the notice
    const closed = psql(`select notice_state || ':' || withdrawn_reason from app.cells_absence_notices
                          where notice_id = '${notice.data?.notice_id}'`);
    const waiting = psql(`select count(*) from app.notifications_jobs where source_type = 'cells_absence_notice'
                           and source_id = '${notice.data?.notice_id}' and job_state = 'pending'`);
    check('B40-notice-closed', closed === 'withdrawn:left_cell' && waiting === '0'
      && !(staff?.absences ?? []).some((a) => a.member_id === member.member),
      { notice: closed, waiting: Number(waiting) });

    // ------------------------------------------------------------------ handover and deletion
    const grantsOf = (m) => psql(`select revision from app.identity_grant_sets where member_id = '${m}'`);
    const dropAssistant = await envelope('identity_grant_command', admin.token, 'identity.revoke_scope',
      Number(grantsOf(assistant.member)), { member_id: assistant.member, scope_kind: 'cell_assistant', scope_id: S });
    const dropLeader = await envelope('identity_grant_command', admin.token, 'identity.revoke_scope',
      Number(grantsOf(leader.member)), { member_id: leader.member, scope_kind: 'cell_leader', scope_id: S });
    const stillLeads = psql(`select count(*) from app.identity_grants where member_id = '${leader.member}'
                              and scope_id = '${S}' and revoked_at is null`);
    const erased = JSON.parse(psql(`select app.cells_erase_member(jsonb_build_object('member_id', '${member.member}',
                                      'phase', 'erase'))::text`));
    const checked = JSON.parse(psql(`select app.cells_erase_member(jsonb_build_object('member_id', '${member.member}',
                                       'phase', 'check'))::text`));
    check('B50-last-leader-handover-and-deletion-zero', dropAssistant.status === 200
      && dropLeader.code === 'conflict' && JSON.stringify(dropLeader).includes('handover_required')
      && stillLeads === '1' && erased?.remaining === 0 && checked?.remaining === 0,
      { assistant_removed: dropAssistant.status, last_leader_removed: dropLeader.code, deletion_check: checked?.remaining });
  } finally {
    const left = cleanup();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'cells-transfer-e2e';
            delete from app.platform_environment_history where set_by = 'cells-transfer-e2e';`);
    }
    log('A99-cleanup', { users_left: Number(left), unmarked: marked,
      programmes_left: Number(psql(`select count(*) from app.cells_programmes p join app.cells_cells c using (cell_id)
                                    where c.name in ('${SHIKOSWE}', '${ESTATES}')`)) });
  }
  finish();
}

runMain(import.meta.url, main);
