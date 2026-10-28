#!/usr/bin/env node
// Story 5.5 end-to-end on the LOCAL stack: You're on, through real GoTrue phone sign-in (no SMS) and
// the real Data API (PostgREST), proving the ticket's verify at the API level:
//   * a member reads which published part is theirs (with its Duties occurrence) and finds it in
//     My duties Awaiting, with the reporting time and instructions fields;
//   * the programme read names leaders but shows no answer to any member;
//   * the member accepts through duties.respond, another member declines, and a stale answer is
//     refused;
//   * the cell's leader records Confirmed by leader for a member without a login through
//     duties.confirm_by_leader (the 5.5 Duties contract change): attributed to the leader in the
//     Duties audit, distinct from a member's own acceptance, replayed identically, refused a second
//     time; a member, Admin alone, Pastor and another cell's leader cannot.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900030-900039. Evidence is redacted JSONL:
// statuses, codes, counts; never tokens, passwords, numbers, names or programme text. Everything it
// created is removed.
//
// Usage: node tools/identity-e2e/cells-youre-on.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';
import { weekdayInTwoDays } from './cells-meetings.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 5.5 E2E';
export const SHIKOSWE = 'SYNTHETIC Shikoswe Cell (5.5 E2E)';
export const ESTATES = 'SYNTHETIC Estates C5/C7 Cell (5.5 E2E)';
export const DEPARTMENT = 'SYNTHETIC Ushers (5.5 E2E)';
const VENUE = 'SYNTHETIC 12 Shikoswe Road';
const TOPIC = 'SYNTHETIC Rooted in love';

/** The reserved fictional numbers this run uses (+44 7700 900030-900039). */
export function isFictionalYoureOnPhone(phone) {
  return /^\+44770090003[0-9]$/.test(phone);
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
    admin: { phone: '+447700900030', name: `${NAME_PREFIX} Admin` },
    leader: { phone: '+447700900031', name: `${NAME_PREFIX} Leader S` },
    assistant: { phone: '+447700900032', name: `${NAME_PREFIX} Assistant S` },
    member: { phone: '+447700900033', name: `${NAME_PREFIX} Member S` },
    other: { phone: '+447700900034', name: `${NAME_PREFIX} Other S` },
    estatesLeader: { phone: '+447700900035', name: `${NAME_PREFIX} Leader E` },
    pastor: { phone: '+447700900036', name: `${NAME_PREFIX} Pastor` },
  };
  for (const p of Object.values(people)) if (!isFictionalYoureOnPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
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
    psql(`select app.platform_set_environment('local', 'cells-youre-on-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('Y00-precondition', {
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
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'cells-youre-on-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    const accountless = psql(`insert into app.identity_members (display_name, membership_state, is_synthetic)
      values ('${NAME_PREFIX} Accountless A', 'approved', true) returning member_id`);
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    check('Y01-members-signed-in-by-phone', Object.values(people).every((p) => amrMethods(p.token).includes('password')),
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
    check('Y02-a-published-programme', [S, E].every(Boolean) && grants.every((g) => g.status === 200)
      && placed.every((p) => p.status === 200) && set.status === 200 && published.data?.state === 'published',
      { grants: grants.map((g) => g.status), placed: placed.map((p) => p.status), published: published.data?.state });

    // ------------------------------------------------------------------ the member's own part
    const programmeOf = async (p) => read('cells_meeting_programme', p.token, { meeting_id: meeting?.meeting_id });
    const mine = await programmeOf(member);
    const yours = mine.json?.yours ?? [];
    const myDuties = async (p) => (await read('duties_my_duties', p.token)).json?.assignments ?? [];
    let duty = (await myDuties(member)).find((a) => a.occurrence_id === yours[0]?.occurrence_id);
    check('Y10-the-member-reads-which-part-is-theirs', mine.status === 200 && yours.length === 1
      && mine.json?.programme?.parts?.[0]?.part_id === yours[0]?.part_id && duty?.owner_kind === 'cell'
      && duty?.response === 'pending' && 'reporting_at' in (duty ?? {}) && 'instructions' in (duty ?? {}),
      { yours: yours.length, my_duty_found: Boolean(duty), response: duty?.response ?? null });
    const otherRead = await programmeOf(other);
    check('Y11-names-but-never-answers-to-other-members',
      !/(response|pending|accepted|declined)/.test(JSON.stringify(otherRead.json ?? {}))
      && JSON.stringify(otherRead.json?.programme?.parts?.map((x) => x.leader)) === JSON.stringify(mine.json?.programme?.parts?.map((x) => x.leader)),
      { other_member_sees_answers: /(response|pending|accepted|declined)/.test(JSON.stringify(otherRead.json ?? {})) });

    // ------------------------------------------------------------------ answers through Duties
    const accepted = await duties(member.token, 'duties.respond', duty?.revision,
      { assignment_id: duty?.assignment_id, response: 'accepted' });
    const stale = await duties(member.token, 'duties.respond', duty?.revision,
      { assignment_id: duty?.assignment_id, response: 'declined' });
    const otherDuty = (await myDuties(other)).find((a) => a.duty_name === 'SYNTHETIC Bible study');
    const declined = await duties(other.token, 'duties.respond', otherDuty?.revision,
      { assignment_id: otherDuty?.assignment_id, response: 'declined' });
    duty = (await myDuties(member)).find((a) => a.assignment_id === duty?.assignment_id);
    check('Y20-member-accepts-another-declines-stale-refused', accepted.data?.response === 'accepted'
      && stale.code === 'conflict' && declined.data?.response === 'declined' && duty?.response === 'accepted'
      && duty?.response_provenance === 'member',
      { accepted: accepted.data?.response, stale: stale.code, declined: declined.data?.response });

    // ------------------------------------------------------------------ leader confirmation
    const staff = async (p) => (await read('cells_programme', p.token, { meeting_id: meeting?.meeting_id })).json;
    const worship = (await staff(leader))?.duties?.[1]?.positions?.[0]?.assignment;
    const confirmBy = (p, requestId, revision = worship?.revision) => rpc('duties_command', p.token, { version: 1,
      command: 'duties.confirm_by_leader', request_id: requestId ?? randomUUID(), expected_revision: revision,
      payload: { assignment_id: worship?.assignment_id, channel: 'phone', reason: 'SYNTHETIC said yes on the phone' } })
      .then((r) => ({ status: r.status, ...r.json }));
    const refused = { member: await confirmBy(member), admin: await confirmBy(admin), pastor: await confirmBy(pastor),
      other_leader: await confirmBy(estatesLeader) };
    const requestId = randomUUID();
    const confirmed = await confirmBy(leader, requestId);
    const replay = await confirmBy(leader, requestId);
    const again = await confirmBy(assistant, undefined, confirmed.data?.revision);
    const after = (await staff(assistant))?.duties?.[1]?.positions?.[0]?.assignment;
    check('Y30-leader-confirms-the-member-without-a-login', Object.values(refused).every((r) => r.code === 'not_found')
      && confirmed.data?.provenance === 'leader' && JSON.stringify(replay.data) === JSON.stringify(confirmed.data)
      && again.field_errors?.assignment_id === 'responded'
      && after?.response === 'accepted' && after?.response_provenance === 'leader',
      { refused: Object.fromEntries(Object.entries(refused).map(([k, v]) => [k, v.code])),
        confirmed: confirmed.data?.provenance, replay_same: JSON.stringify(replay.data) === JSON.stringify(confirmed.data),
        second: again.field_errors?.assignment_id ?? null, plan_shows: after?.response_provenance ?? null });
    const audit = psql(`select count(*) from app.duties_audit a where a.action = 'leader_confirmed'
                          and a.actor_capacity = 'cell_leader' and a.department_id is null
                          and a.actor_member_id = '${leader.member}'`);
    check('Y31-confirmation-attributed-in-the-duties-audit', audit === '1', { audit_rows: Number(audit) });
  } finally {
    const left = cleanup();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'cells-youre-on-e2e';
            delete from app.platform_environment_history where set_by = 'cells-youre-on-e2e';`);
    }
    log('Y99-cleanup', { users_left: Number(left), unmarked: marked,
      programmes_left: Number(psql(`select count(*) from app.cells_programmes p join app.cells_cells c using (cell_id)
                                    where c.name in ('${SHIKOSWE}', '${ESTATES}')`)) });
  }
  finish();
}

runMain(import.meta.url, main);
