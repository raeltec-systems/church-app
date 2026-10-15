#!/usr/bin/env node
// Story 4.11 end-to-end on the LOCAL stack: the Duties owner operations through a SYNTHETIC
// Cells-like caller (module fixture, standing in for epic 5), with real GoTrue phone sign-in (no
// SMS) and the real Data API (PostgREST) for every member and department action. The caller's
// command runs in the local database as its owner would, inside the signed-in cell leader's real
// session (the JWT claims of that session), because owner operations are never client-executable.
// It proves the ticket's verify line:
//   * the caller creates, revises and cancels a cell-owned position (each in its own
//     transaction, and all three in one transaction);
//   * the member sees and answers the cell part over HTTP; a late answer to an old revision is
//     refused with what changed;
//   * the caller display-links a department duty, which stays unchanged and managed only by its
//     department; a cell leader cannot edit it over HTTP (revise, cancel, reassign, clear review);
//   * a second link for the same part position is refused, also when two transactions race;
//   * a meeting change flags an owner-review mismatch the department leader sees and clears over
//     HTTP (a stale clear is a conflict);
//   * no person, note or reason of the department crosses to the cell; owner operations and the
//     new tables are not reachable over the Data API.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900240-900249. Evidence is redacted JSONL:
// statuses, codes, counts and states; never tokens, passwords, numbers, names or notes. Every
// user, member, grant, cell, department, duty, part, link, flag, job, item and receipt it created
// is removed (the fixture registrations stay; they are idempotent and SYNTHETIC).
//
// Usage: node tools/identity-e2e/duties-owner-ops.mjs [--evidence <file.jsonl>]
import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { promisify } from 'node:util';

import { amrMethods, dbContainer, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';
import { jsonLiteral, sessionClaims } from './duties-shared.mjs';

export { sessionClaims, jsonLiteral } from './duties-shared.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 4.11 E2E';
export const DEPARTMENT = 'SYNTHETIC 4.11 E2E Preaching Rota';
export const CELLS = ['SYNTHETIC 4.11 E2E Cell', 'SYNTHETIC 4.11 E2E Other Cell'];
/** Texts this run writes on the department side; the cell's reads must never hold them. */
export const DEPARTMENT_TEXT = ['SYNTHETIC 4.11 department instructions', 'SYNTHETIC 4.11 E2E Member Q'];

/** The reserved fictional numbers this run uses (+44 7700 900240-900249). */
export function isFictionalOwnerOpsPhone(phone) {
  return /^\+44770090024[0-9]$/.test(phone);
}

/** Does an answer hold any department-side text (an assignee's name or the duty's instructions)? */
export function holdsDepartmentText(answer) {
  const json = JSON.stringify(answer ?? {});
  return DEPARTMENT_TEXT.some((t) => json.includes(t));
}

/** The ISO instant of church date `ymd` at `hh:mm` Africa/Lusaka (UTC+2, no daylight saving). */
export function churchAt(ymd, hhmm) {
  const [h, m] = hhmm.split(':').map(Number);
  const d = new Date(`${ymd}T00:00:00Z`);
  d.setUTCHours(h - 2, m);
  return d.toISOString().replace('.000Z', 'Z');
}

/** One SQL text that runs an owner call as the caller's command body inside a session. */
export function ownerCallSql(claims, fn, input, { sleepSeconds = 0 } = {}) {
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
${sleepSeconds > 0 ? `select pg_sleep(${Number(sleepSeconds)});` : ''}
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
  const http = localHttp(keys);
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const envelope = (fn, token, cmd, expected, payload) =>
    rpc(fn, token, { version: 1, command: cmd, request_id: randomUUID(), expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const duty = (token, cmd, expected, payload) => envelope('duties_command', token, cmd, expected, payload);
  const HOUR = 3_600_000;
  const DAY = 24 * HOUR;
  const churchDate = (ms) => new Date(Date.now() + ms + 2 * HOUR).toISOString().slice(0, 10);
  const owner = (p, fn, input) => firstJson(psql(ownerCallSql(sessionClaims(p.token), fn, input)));
  const ownerAsync = async (p, fn, input, sleepSeconds) => {
    const args = ['exec', '-i', dbContainer(), 'psql', '-U', 'postgres', '-X', '-qtA', '-v', 'ON_ERROR_STOP=1',
      '-c', ownerCallSql(sessionClaims(p.token), fn, input, { sleepSeconds })];
    const { stdout } = await promisify(execFile)('docker', args, { encoding: 'utf8' });
    return firstJson(stdout);
  };

  const people = {
    admin: { phone: '+447700900240', name: `${NAME_PREFIX} Admin` },
    leader: { phone: '+447700900241', name: `${NAME_PREFIX} Leader` },
    deputy: { phone: '+447700900242', name: `${NAME_PREFIX} Deputy` },
    cellLeader: { phone: '+447700900243', name: `${NAME_PREFIX} Cell leader` },
    cellAssistant: { phone: '+447700900244', name: `${NAME_PREFIX} Cell assistant` },
    otherCellLeader: { phone: '+447700900245', name: `${NAME_PREFIX} Other cell leader` },
    member: { phone: '+447700900246', name: `${NAME_PREFIX} Member M` },
    other: { phone: '+447700900247', name: `${NAME_PREFIX} Member O` },
    quiet: { phone: '+447700900248', name: `${NAME_PREFIX} Member Q` },
    pastor: { phone: '+447700900249', name: `${NAME_PREFIX} Pastor` },
  };
  for (const p of Object.values(people)) if (!isFictionalOwnerOpsPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  const users = new Set();
  const digits = Object.values(people).map((p) => `'${p.phone.slice(1)}'`).join(',');
  const cellNames = CELLS.map((c) => `'${c}'`).join(',');
  const cleanup = () => {
    const ids = [...users].map((u) => `'${u}'`);
    const byUser = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    return psql(`
    create temp table gone_users as select u.id from auth.users u where ${byUser} u.phone in (${digits});
    create temp table gone_members as
      select m.member_id from app.identity_members m where m.display_name like '${NAME_PREFIX}%';
    create temp table gone_departments as
      select d.department_id from app.duties_departments d where d.name = '${DEPARTMENT}';
    create temp table gone_cells as select c.cell_id from app.cells_cells c where c.name in (${cellNames});
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
          or j.source_id in (select assignment_id from gone_assignments);
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
       or a.actor_member_id in (select member_id from gone_members);
    delete from app.duties_slot_revisions r where r.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_assignments a where a.assignment_id in (select assignment_id from gone_assignments);
    -- Part links and review flags go with their slots and occurrences (the only way they are removed).
    delete from app.duties_slots s where s.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_occurrences o where o.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_series r where r.department_id in (select department_id from gone_departments);
    delete from app.duties_department_members dm where dm.department_id in (select department_id from gone_departments);
    delete from app.fixture_programme_parts p where p.cell_id in (select cell_id from gone_cells);
    delete from app.fixture_events e where e.title like '${NAME_PREFIX}%';
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
    psql(`select app.platform_set_environment('local', 'duties-owner-ops-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('X00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  const occRev = (id) => Number(psql(`select revision from app.duties_occurrences where occurrence_id = '${id}'`));
  const asg = (id) => JSON.parse(psql(`select to_jsonb(a) from app.duties_assignments a where a.assignment_id = '${id}'`) || 'null');
  const jobs = (id) => psql(`select coalesce(string_agg(reminder_kind || ':' || job_state, ',' order by enqueued_at, reminder_kind), '')
    from app.notifications_jobs where source_type = 'duties_assignment' and source_id = '${id}'
     and reminder_kind in ('duty_assigned', 'duty_released', 'duty_cancelled', 'duty_changed')`);
  const done = (r) => r && r.status === 200 && !r.code;
  const ok = (r) => r && !r.code && !r.sqlstate;
  const refused = (r, code, field, value) => r?.code === code && (!field || r.field_errors?.[field] === value);
  const positionOf = (answer, key) => (answer?.positions ?? []).find((p) => p.position_key === key) ?? null;
  const myDuty = async (p, occurrenceId) => ((await rpc('duties_my_duties', p.token)).json?.assignments ?? [])
    .find((a) => a.occurrence_id === occurrenceId) ?? null;
  const boardDuty = async (p, occurrenceId) => {
    const b = (await rpc('duties_leader_board', p.token)).json;
    for (const d of b?.departments ?? []) for (const x of d.duties ?? []) if (x.occurrence_id === occurrenceId) return x;
    return null;
  };

  try {
    const { admin, leader, deputy, cellLeader, cellAssistant, otherCellLeader, member, other, quiet, pastor } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'duties-owner-ops-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    psql(`insert into app.identity_grants (member_id, role, granted_by_operator) values ('${pastor.member}', 'pastor', '${OPERATOR}')`);
    check('X01-members-signed-in-by-phone', Object.values(people).every((p) => amrMethods(p.token).includes('password')),
      { amr: amrMethods(admin.token) });

    // ------------------------------------------------------- setup: department, cells, scopes, registrations
    const dept = await duty(admin.token, 'duties.create_department', null, { name: DEPARTMENT });
    const departmentId = dept.data?.department_id;
    psql(`insert into app.cells_cells (name, broad_area, is_synthetic, created_by)
          values ('${CELLS[0]}', 'SYNTHETIC area', true, 'duties-owner-ops-e2e'),
                 ('${CELLS[1]}', 'SYNTHETIC area', true, 'duties-owner-ops-e2e')`);
    const cellId = psql(`select cell_id from app.cells_cells where name = '${CELLS[0]}'`);
    const cell2Id = psql(`select cell_id from app.cells_cells where name = '${CELLS[1]}'`);
    const grantRev = (m) => Number(psql(`select revision from app.identity_grant_sets where member_id = '${m}'`));
    const grants = [];
    for (const [p, kind, scope] of [[leader, 'department_leader', departmentId], [deputy, 'department_deputy', departmentId],
      [cellLeader, 'cell_leader', cellId], [cellAssistant, 'cell_assistant', cellId], [otherCellLeader, 'cell_leader', cell2Id]]) {
      grants.push((await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantRev(p.member),
        { member_id: p.member, scope_kind: kind, scope_id: scope })).code ?? 'done');
    }
    const added = [];
    for (const p of [leader, quiet]) {
      const rev = Number(psql(`select revision from app.duties_departments where department_id = '${departmentId}'`));
      added.push((await duty(admin.token, 'duties.add_member', rev, { department_id: departmentId, member_id: p.member })).code ?? 'done');
    }
    for (const p of [leader, deputy, cellLeader, cellAssistant, otherCellLeader]) p.token = (await signIn(p.phone, p.password)).json?.access_token;
    psql(`select app.contract_register_source_type('fixture', 'fixture_programme_part', 'app.fixture_programme_part_check(jsonb)'::regprocedure)
           where not exists (select 1 from app.contract_source_types where source_type = 'fixture_programme_part');
          select app.contract_register_source_type('fixture', 'fixture_event', 'app.fixture_event_check(jsonb)'::regprocedure)
           where not exists (select 1 from app.contract_source_types where source_type = 'fixture_event');
          select app.duties_register_link_source('fixture', 'fixture_programme_part', 'cell_part');
          select app.duties_register_link_source('fixture', 'fixture_event', 'event');`);
    check('X02-department-cells-scopes-registrations', done(dept) && grants.every((s) => s === 'done')
      && added.every((s) => s === 'done') && !!cellId && !!cell2Id,
      { department: dept.status, grants, members_added: added });

    // ------------------------------------------------------- create, answer, revise (verify)
    const day = churchDate(6 * DAY);
    const p1 = owner(cellLeader, 'fixture_programme_publish', {
      cell_id: cellId, duty_name: 'SYNTHETIC 4.11 Worship part', starts_at: churchAt(day, '18:00'), ends_at: churchAt(day, '19:00'),
      location: 'SYNTHETIC cell home', instructions: 'SYNTHETIC 4.11 part instructions',
      positions: [{ position_key: 'lead', position_name: 'Lead', member_id: member.member },
        { position_key: 'second', position_name: 'Second' }] });
    const occ1 = p1?.occurrence_id;
    const mAsg = positionOf(p1, 'lead')?.assignment_id;
    const mineM = await myDuty(member, occ1);
    check('X10-the-caller-creates-a-cell-owned-part', ok(p1) && p1.created === true && p1.positions?.length === 2
      && psql(`select coalesce(department_id::text, 'none') || '|' || (cell_id = '${cellId}') from app.duties_occurrences where occurrence_id = '${occ1}'`) === 'none|true'
      && mineM?.owner_kind === 'cell' && mineM?.department_name == null && jobs(mAsg) === 'duty_assigned:pending'
      && (mineM?.leaders ?? []).map((l) => l.role).join(',') === 'leader,assistant',
      { created: p1?.created ?? null, positions: p1?.positions?.length ?? null, owner_kind: mineM?.owner_kind ?? null,
        member_notice: jobs(mAsg), leaders: (mineM?.leaders ?? []).map((l) => l.role) });

    const acceptM = await duty(member.token, 'duties.respond', mineM?.revision, { assignment_id: mAsg, response: 'accepted' });
    check('X11-the-member-accepts-the-cell-part-over-http', done(acceptM) && acceptM.data?.response === 'accepted',
      { status: acceptM.status, response: acceptM.data?.response ?? null });

    const p1r = owner(cellAssistant, 'fixture_programme_publish', {
      part_id: p1?.part_id, expected_revision: occRev(occ1), duty_name: 'SYNTHETIC 4.11 Worship part',
      starts_at: churchAt(day, '18:30'), ends_at: churchAt(day, '19:30'), location: 'SYNTHETIC cell home',
      instructions: 'SYNTHETIC 4.11 part instructions',
      positions: [{ position_key: 'lead', position_name: 'Lead', member_id: other.member },
        { position_key: 'third', position_name: 'Third' }] });
    const oAsg = positionOf(p1r, 'lead')?.assignment_id;
    const lateM = await duty(member.token, 'duties.respond', asg(mAsg)?.revision, { assignment_id: mAsg, response: 'declined' });
    const mineO = await myDuty(other, occ1);
    check('X12-the-caller-revises-the-position', ok(p1r) && p1r.changed === true
      && asg(mAsg)?.assignment_state === 'superseded' && asg(mAsg)?.response === 'accepted'
      && mineO?.assignment_id === oAsg && mineO?.response === 'pending'
      && positionOf(p1r, 'second')?.cancelled === true && !!positionOf(p1r, 'third')
      && refused(lateM, 'conflict', 'assignment_id', 'superseded') && lateM.field_errors?.starts_at === 'changed'
      && jobs(mAsg).includes('duty_released:pending'),
      { changed: p1r?.changed ?? null, old_state: asg(mAsg)?.assignment_state ?? null, old_answer_kept: asg(mAsg)?.response ?? null,
        new_member_sees: mineO?.response ?? null, late_answer: lateM.code ?? 'done', what_changed: Object.keys(lateM.field_errors ?? {}).sort(),
        released_notice: jobs(mAsg).includes('duty_released:pending') });

    // ------------------------------------------------------- link a department duty (verify)
    const dday = churchDate(8 * DAY);
    const dd = await duty(leader.token, 'duties.publish_duty', null, {
      department_id: departmentId, member_id: quiet.member, duty_name: 'SYNTHETIC 4.11 Cell preaching',
      starts_at: churchAt(dday, '18:00'), ends_at: churchAt(dday, '19:00'), instructions: 'SYNTHETIC 4.11 department instructions' });
    const ddOcc = dd.data?.occurrence_id;
    const ddAsg = dd.data?.assignment_id;
    const ddSlot = psql(`select slot_id from app.duties_assignments where assignment_id = '${ddAsg}'`);
    const before = { rev: occRev(ddOcc), asg: asg(ddAsg), jobs: Number(psql(`select count(*) from app.notifications_jobs where source_id = '${ddAsg}'`)) };
    const p2 = owner(cellLeader, 'fixture_programme_publish', {
      cell_id: cellId, duty_name: 'SYNTHETIC 4.11 Study part', starts_at: churchAt(dday, '19:00'), ends_at: churchAt(dday, '20:00'),
      positions: [{ position_key: 'host', member_id: member.member }] });
    const link = owner(cellLeader, 'fixture_programme_link', { part_id: p2?.part_id, position_key: 'preacher', slot_id: ddSlot });
    const ddBoard = await boardDuty(leader, ddOcc);
    const unchanged = occRev(ddOcc) === before.rev && JSON.stringify(asg(ddAsg)) === JSON.stringify(before.asg)
      && Number(psql(`select count(*) from app.notifications_jobs where source_id = '${ddAsg}'`)) === before.jobs
      && Number(psql(`select count(*) from app.duties_occurrences where duty_name = 'SYNTHETIC 4.11 Cell preaching'`)) === 1;
    const part2 = owner(cellLeader, 'duties_owner_part', { source_type: 'fixture_programme_part', source_id: p2?.part_id, cell_id: cellId });
    check('X20-a-department-duty-is-linked-not-cloned-or-changed', done(dd) && ok(link) && link.kind === 'linked'
      && unchanged && ddBoard?.linked_parts === 1 && positionOf(part2, 'preacher')?.filled === true
      && !holdsDepartmentText(part2) && !JSON.stringify(part2).includes(quiet.member),
      { link: link?.kind ?? link?.code ?? null, department_duty_unchanged: unchanged, board_linked_parts: ddBoard?.linked_parts ?? null,
        cell_sees_filled: positionOf(part2, 'preacher')?.filled ?? null, cell_sees_department_people: holdsDepartmentText(part2) });

    // ------------------------------------------------------- a second link is refused, also in a race
    const second = owner(cellLeader, 'fixture_programme_link', { part_id: p2?.part_id, position_key: 'preacher', slot_id: ddSlot });
    const partRev = Number(psql(`select revision from app.fixture_programme_parts where part_id = '${p2?.part_id}'`));
    const raceInput = { source_type: 'fixture_programme_part', source_id: p2?.part_id, source_revision: partRev, cell_id: cellId,
      position_key: 'raced', slot_id: ddSlot };
    const first = ownerAsync(cellLeader, 'duties_owner_link_duty', raceInput, 1.5);
    await new Promise((r) => setTimeout(r, 400));
    const racer = ownerAsync(cellAssistant, 'duties_owner_link_duty', raceInput, 0);
    const [ra, rb] = await Promise.all([first, racer]);
    const raced = Number(psql(`select count(*) from app.duties_part_links where source_id = '${p2?.part_id}' and position_key = 'raced'`));
    check('X21-a-second-link-for-the-same-part-position-is-refused', refused(second, 'conflict', 'position_key', 'linked')
      && [ra, rb].filter(ok).length === 1 && [ra, rb].filter((r) => refused(r, 'conflict', 'position_key', 'linked')).length === 1
      && raced === 1,
      { sequential: second?.code ?? 'done', race: [ra, rb].map((r) => r?.code ?? (ok(r) ? 'linked' : 'error')), links: raced });

    // ------------------------------------------------------- a cell leader cannot edit the department duty
    const edits = {
      revise: (await duty(cellLeader.token, 'duties.revise_duty', occRev(ddOcc), { occurrence_id: ddOcc, location: 'SYNTHETIC moved by a cell' })).code ?? 'done',
      cancel: (await duty(cellLeader.token, 'duties.cancel_position', occRev(ddOcc), { slot_id: ddSlot })).code ?? 'done',
      reassign: (await duty(cellLeader.token, 'duties.assign_slot', occRev(ddOcc), { slot_id: ddSlot, member_id: member.member })).code ?? 'done',
      set_reminders: (await duty(cellLeader.token, 'duties.set_reminders', occRev(ddOcc), { occurrence_id: ddOcc, reminders: [] })).code ?? 'done',
    };
    const deptStill = await duty(leader.token, 'duties.revise_duty', occRev(ddOcc), { occurrence_id: ddOcc, instructions: 'SYNTHETIC 4.11 department instructions two' });
    check('X22-a-cell-leader-cannot-edit-the-department-duty', edits.revise === 'forbidden' && edits.cancel === 'forbidden'
      && edits.reassign === 'forbidden' && edits.set_reminders === 'forbidden' && done(deptStill),
      { ...edits, department_still_manages: deptStill.code ?? 'done' });

    // ------------------------------------------------------- flag and clear a mismatch (verify)
    const jobsBefore = Number(psql('select count(*) from app.notifications_jobs'));
    const revBefore = occRev(ddOcc);
    const flagged = owner(cellLeader, 'fixture_programme_changed', { part_id: p2?.part_id, changed: ['time'] });
    const seen = await boardDuty(leader, ddOcc);
    const review = seen?.reviews?.[0];
    const byCell = await duty(cellLeader.token, 'duties.clear_review', review?.revision, { flag_id: review?.flag_id });
    const stale = await duty(leader.token, 'duties.clear_review', (review?.revision ?? 0) + 5, { flag_id: review?.flag_id });
    const cleared = await duty(leader.token, 'duties.clear_review', review?.revision, { flag_id: review?.flag_id });
    const after = await boardDuty(deputy, ddOcc);
    check('X30-a-meeting-change-flags-a-mismatch-the-department-clears', flagged?.flagged === 1
      && review?.source === 'cell_part' && (review?.changed ?? []).join(',') === 'time'
      && occRev(ddOcc) === revBefore && Number(psql('select count(*) from app.notifications_jobs')) === jobsBefore
      && byCell.code === 'forbidden' && stale.code === 'conflict' && done(cleared) && (after?.reviews ?? []).length === 0,
      { flagged: flagged?.flagged ?? null, review: review ? { source: review.source, changed: review.changed } : null,
        duty_revision_unchanged: occRev(ddOcc) === revBefore, new_jobs: Number(psql('select count(*) from app.notifications_jobs')) - jobsBefore,
        clear_by_cell: byCell.code ?? 'done', stale_clear: stale.code ?? 'done', cleared: cleared.code ?? 'done',
        open_after: (after?.reviews ?? []).length });

    // ------------------------------------------------------- the linked-event reference
    const eventId = psql(`insert into app.fixture_events (title) values ('${NAME_PREFIX} Event') returning event_id`);
    const named = await duty(leader.token, 'duties.revise_duty', occRev(ddOcc), { occurrence_id: ddOcc, event_ref: eventId });
    const evFlag = owner(admin, 'fixture_event_changed', { event_id: eventId, changed: ['place'] });
    const evLinks = owner(admin, 'duties_owner_event_links', { source_type: 'fixture_event', source_id: eventId });
    const evSeen = await boardDuty(deputy, ddOcc);
    check('X31-an-event-change-flags-the-duty-that-names-it', done(named) && named.data?.change === 'reference'
      && evFlag?.flagged === 1 && evLinks?.duties?.[0]?.review_open === true && evSeen?.reviews?.[0]?.source === 'event',
      { named: named.data?.change ?? named.code ?? null, flagged: evFlag?.flagged ?? null,
        event_links: evLinks?.duties?.length ?? null, review: evSeen?.reviews?.[0]?.source ?? null });

    // ------------------------------------------------------- cancel (verify), and all three in one transaction
    const cancelled = owner(cellLeader, 'fixture_programme_cancel', { part_id: p1?.part_id, expected_revision: occRev(occ1) });
    const cancelledLinks = owner(cellLeader, 'fixture_programme_cancel', { part_id: p2?.part_id,
      expected_revision: occRev(p2?.occurrence_id) });
    check('X40-the-caller-cancels-the-part', ok(cancelled) && cancelled.state === 'cancelled'
      && asg(oAsg)?.assignment_state === 'cancelled' && jobs(oAsg).includes('duty_cancelled:pending')
      && ok(cancelledLinks) && cancelledLinks.links_ended === 2 && occRev(ddOcc) === Number(named.data?.revision ?? -1),
      { state: cancelled?.state ?? cancelled?.code ?? null, member_assignment: asg(oAsg)?.assignment_state ?? null,
        member_told: jobs(oAsg).includes('duty_cancelled:pending'), links_ended: cancelledLinks?.links_ended ?? null,
        department_duty_untouched: occRev(ddOcc) === Number(named.data?.revision ?? -1) });

    const claims = sessionClaims(cellLeader.token);
    const oneTx = psql(`begin;
      do $d$ begin perform set_config('request.jwt.claims', ${jsonLiteral(claims).replace('::jsonb', '')}, true); end $d$;
      create temp table step1 on commit drop as select app.fixture_programme_publish(${jsonLiteral({
        cell_id: cellId, duty_name: 'SYNTHETIC 4.11 One-transaction part', starts_at: churchAt(churchDate(10 * DAY), '18:00'),
        positions: [{ position_key: 'solo', member_id: member.member }] })}) as r;
      create temp table step2 on commit drop as select app.fixture_programme_publish(jsonb_build_object(
        'part_id', (select r ->> 'part_id' from step1), 'expected_revision', (select r -> 'revision' from step1),
        'duty_name', 'SYNTHETIC 4.11 One-transaction part', 'starts_at', ${jsonLiteral(churchAt(churchDate(10 * DAY), '18:00'))},
        'positions', jsonb_build_array(jsonb_build_object('position_key', 'solo', 'member_id', '${other.member}')))) as r;
      create temp table step3 on commit drop as select app.fixture_programme_cancel(jsonb_build_object(
        'part_id', (select r ->> 'part_id' from step1), 'expected_revision', (select r -> 'revision' from step2))) as r;
      select (select r ->> 'state' from step3) || '|' || (select string_agg(a.assignment_state, ',' order by a.supersedes_assignment_id nulls first)
        from app.duties_assignments a join app.duties_slots s on s.slot_id = a.slot_id
       where s.occurrence_id = (select (r ->> 'occurrence_id')::uuid from step1));
      commit;`);
    check('X41-create-revise-and-cancel-in-one-transaction', oneTx === 'cancelled|superseded,cancelled', { result: oneTx });

    // ------------------------------------------------------- not reachable over the Data API
    const direct = (await rpc('duties_owner_put_part', cellLeader.token, { p_input: {} })).status;
    const fixtureRpc = (await rpc('fixture_programme_publish', cellLeader.token, { p_input: {} })).status;
    const tables = [];
    for (const t of ['duties_part_links', 'duties_review_flags', 'duties_link_sources']) {
      tables.push((await http('GET', `/rest/v1/${t}?select=*`, { token: leader.token, profile: 'app' })).status);
    }
    const otherCell = owner(otherCellLeader, 'duties_owner_part', { source_type: 'fixture_programme_part', source_id: p1?.part_id, cell_id: cellId });
    const pastorClear = await duty(pastor.token, 'duties.clear_review', 1, { flag_id: review?.flag_id });
    check('X90-owner-operations-and-tables-are-not-reachable-by-clients', direct >= 400 && fixtureRpc >= 400
      && tables.every((s) => s >= 400) && otherCell?.code === 'forbidden' && pastorClear.code === 'forbidden',
      { owner_rpc: direct, fixture_rpc: fixtureRpc, tables, other_cell_read: otherCell?.code ?? 'done', pastor_clear: pastorClear.code ?? 'done' });
  } finally {
    const left = cleanup();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'duties-owner-ops-e2e';
            delete from app.platform_environment_history where set_by = 'duties-owner-ops-e2e';`);
    }
    log('X99-cleanup', { users_left: Number(left), unmarked: marked,
      departments_left: Number(psql(`select count(*) from app.duties_departments where name = '${DEPARTMENT}'`)),
      cells_left: Number(psql(`select count(*) from app.cells_cells where name in (${cellNames})`)),
      links_left: Number(psql(`select count(*) from app.duties_part_links l join app.fixture_programme_parts p on p.part_id = l.source_id`)),
      parts_left: Number(psql(`select count(*) from app.fixture_programme_parts p join app.cells_cells c on c.cell_id = p.cell_id
                                where c.name in (${cellNames})`)) });
  }
  finish();
}

runMain(import.meta.url, main);
