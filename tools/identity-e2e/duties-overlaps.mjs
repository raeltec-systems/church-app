#!/usr/bin/env node
// Story 4.4 end-to-end on the LOCAL stack: overlap warnings and reasoned overrides, through real
// GoTrue phone sign-in (no SMS) and the real Data API (PostgREST), proving the ticket's verify at
// the API level:
//   * a member is given overlapping duties in two departments: the second leader's candidates
//     read shows the overlap as a busy time only (no other team's name, place, ids or
//     instructions) with each candidate's upcoming load;
//   * the assignment is refused without a reason and made with one: the reason is recorded with
//     the assignment, shown on the second department's board only, and the member is still
//     Awaiting response;
//   * a non-overlapping assignment raises no warning;
//   * a SYNTHETIC cell-owned occurrence (the fixture entry 11 will replace with the Cells
//     owner operations) is a conflict too: limited for a department leader, in full for the
//     cell's leader;
//   * two leaders assigning the same member to overlapping duties at once (two one-off duties, and
//     a rota position against a one-off duty), without reasons: one
//     success and one refusal (the per-member lock);
//   * asking a member again after they declined (a place change) while another department has
//     given them that time needs a reason (nothing is carried from a declined answer);
//   * a member, another department's leader and direct table queries are refused; receipts,
//     audit rows and notification jobs hold no reason text.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900760-900769. Evidence is redacted JSONL:
// statuses, codes, counts; never tokens, passwords or numbers. Everything it created is removed.
//
// Usage: node tools/identity-e2e/duties-overlaps.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';

const NAME_PREFIX = 'SYNTHETIC 4.4 E2E';
export const DEPARTMENT = 'SYNTHETIC Preaching Rota 4.4';
export const OTHER_DEPARTMENT = 'SYNTHETIC 4.4 E2E Ushers';
export const CELL = 'SYNTHETIC 4.4 E2E Cell';
const OPERATOR = 'israel';
const REASON = 'SYNTHETIC: agreed with the member to arrive after the first hour.';
const PRIVATE = 'SYNTHETIC private ushers instructions';

/** The reserved fictional numbers this run uses (+44 7700 900760-900769). */
export function isFictionalOverlapPhone(phone) {
  return /^\+44770090076[0-9]$/.test(phone);
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

/** The candidate entry of a member in a candidates read (null when absent). */
export function candidate(read, memberId) {
  return (read?.candidates ?? []).find((c) => c.member_id === memberId) ?? null;
}

/** True when a limited conflict discloses only its owner kind and busy time. */
export function isLimited(conflict) {
  return conflict?.visibility === 'limited'
    && JSON.stringify(Object.keys(conflict).sort()) === JSON.stringify(['from', 'owner_kind', 'to', 'visibility']);
}

/** Exactly one success and one refusal for an overlap among concurrent assignments. */
export function oneAssigned(answers) {
  const ok = answers.filter((a) => a.status === 200 && !a.code).length;
  const refused = answers.filter((a) => a.code === 'validation_failed' && a.field_errors?.member_id === 'overlap'
    && a.field_errors?.override_reason === 'required').length;
  return ok === 1 && refused === answers.length - 1;
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
    admin: { phone: '+447700900760', name: `${NAME_PREFIX} Admin` },
    leaderD: { phone: '+447700900761', name: `${NAME_PREFIX} Leader D` },
    leaderE: { phone: '+447700900762', name: `${NAME_PREFIX} Leader E` },
    member: { phone: '+447700900763', name: `${NAME_PREFIX} Member M` },
    other: { phone: '+447700900764', name: `${NAME_PREFIX} Member O` },
  };
  for (const p of Object.values(people)) if (!isFictionalOverlapPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
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
      select d.department_id from app.duties_departments d where d.name in ('${DEPARTMENT}', '${OTHER_DEPARTMENT}');
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
    psql(`select app.platform_set_environment('local', 'duties-overlaps-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('V00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  try {
    const { admin, leaderD, leaderE, member, other } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'duties-overlaps-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    check('V01-members-signed-in-by-phone', Object.values(people).every((p) => amrMethods(p.token).includes('password')),
      { amr: amrMethods(admin.token) });

    // -------------------------------------------------------------- setup: two departments, a cell
    const dCreated = await duties(admin.token, 'duties.create_department', null, { name: DEPARTMENT });
    const eCreated = await duties(admin.token, 'duties.create_department', null, { name: OTHER_DEPARTMENT });
    const dId = dCreated.data?.department_id;
    const eId = eCreated.data?.department_id;
    const cellId = psql(`insert into app.cells_cells (name, broad_area, is_synthetic, created_by)
      values ('${CELL}', 'SYNTHETIC area', true, 'duties-overlaps-e2e') returning cell_id`);
    const grantsRev = (p) => Number(psql(`select revision from app.identity_grant_sets where member_id = '${p.member}'`));
    const grant = (p, kind, scope) => envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantsRev(p),
      { member_id: p.member, scope_kind: kind, scope_id: scope });
    const grants = [await grant(leaderD, 'department_leader', dId), await grant(leaderE, 'department_leader', eId),
      await grant(leaderE, 'cell_leader', cellId)];
    const addTo = async (departmentId, m) => duties(admin.token, 'duties.add_member',
      Number(psql(`select revision from app.duties_departments where department_id = '${departmentId}'`)),
      { department_id: departmentId, member_id: m });
    const added = [await addTo(dId, member.member), await addTo(dId, other.member), await addTo(eId, member.member),
      await addTo(eId, other.member)];
    check('V02-departments-roles-and-members', dCreated.status === 200 && eCreated.status === 200
      && grants.every((g) => g.status === 200 && !g.code) && added.every((a) => a.status === 200 && !a.code),
      { grants: grants.map((g) => g.code ?? g.status), added: added.map((a) => a.code ?? a.status) });

    const now = Date.now();
    const sun0 = churchSunday(now, 0);
    const sun1 = churchSunday(now, 1);
    const sun2 = churchSunday(now, 2);
    const sun3 = churchSunday(now, 3);
    // The SYNTHETIC cell-owned part for M on Sunday 1, 18:00-19:00 (no Cells command exists yet).
    psql(`with o as (insert into app.duties_occurrences (cell_id, duty_name, starts_at, ends_at, instructions,
                                                        created_by_member, created_by_account)
                     values ('${cellId}', 'SYNTHETIC cell part', '${churchInstant(sun1, '18:00')}', '${churchInstant(sun1, '19:00')}',
                             'SYNTHETIC cell private instructions', '${leaderE.member}', '${leaderE.user}')
                     returning occurrence_id),
               s as (insert into app.duties_slots (occurrence_id, position_no, position_name)
                     select occurrence_id, 1, 'Prayer' from o returning slot_id)
          insert into app.duties_assignments (slot_id, member_id, response_deadline, assigned_by_member, assigned_by_account)
          select slot_id, '${member.member}', '${churchInstant(sun1, '17:00')}', '${leaderE.member}', '${leaderE.user}' from s`);

    const publish = (token, departmentId, who, date, from, to, extra = {}, requestId) => duties(token, 'duties.publish_duty', null, {
      department_id: departmentId, member_id: who, duty_name: 'Sunday duty',
      starts_at: churchInstant(date, from), ends_at: churchInstant(date, to),
      response_deadline: new Date(Date.parse(churchInstant(date, from)) - 86_400_000).toISOString(), ...extra,
    }, requestId);
    const candidates = (token, departmentId, date, from, to) => read('duties_candidates', token, {
      department_id: departmentId, starts_at: churchInstant(date, from), ends_at: churchInstant(date, to) });

    // -------------------------------------------------------------- the first department's duty
    const e1 = await publish(leaderE.token, eId, member.member, sun0, '10:00', '12:00',
      { instructions: PRIVATE, location: 'SYNTHETIC Ushers hall' });
    check('V10-first-duty-overlaps-nothing', e1.status === 200 && e1.data?.override_recorded === false,
      { status: e1.status, override_recorded: e1.data?.override_recorded });

    // -------------------------------------------------------------- the warning, limited
    const c1 = await candidates(leaderD.token, dId, sun0, '11:00', '12:00');
    const m1 = candidate(c1.json, member.member);
    const text1 = JSON.stringify(c1.json ?? {});
    check('V11-warning-without-the-other-teams-details', c1.status === 200 && m1?.conflicts?.count === 1
      && isLimited(m1.conflicts.items[0]) && m1.conflicts.items[0].owner_kind === 'department'
      && !text1.includes(PRIVATE) && !text1.includes(OTHER_DEPARTMENT) && !text1.includes('Ushers hall')
      && !text1.includes(e1.data?.occurrence_id) && candidate(c1.json, other.member)?.conflicts?.count === 0
      && m1.upcoming?.total === 2 && m1.upcoming?.here === 0,
      { status: c1.status, conflict: m1?.conflicts?.items?.[0], load: m1?.upcoming,
        other_conflicts: candidate(c1.json, other.member)?.conflicts?.count });

    // -------------------------------------------------------------- refused, then recorded
    const refused = await publish(leaderD.token, dId, member.member, sun0, '11:00', '12:00');
    const dCount = Number(psql(`select count(*) from app.duties_occurrences where department_id = '${dId}'`));
    check('V12-refused-without-a-reason', refused.code === 'validation_failed'
      && refused.field_errors?.member_id === 'overlap' && refused.field_errors?.override_reason === 'required' && dCount === 0,
      { code: refused.code, field_errors: refused.field_errors, written: dCount });

    const d1 = await publish(leaderD.token, dId, member.member, sun0, '11:00', '12:00', { override_reason: REASON });
    const mine = (await read('duties_my_duties', member.token)).json?.assignments ?? [];
    const dBoard = (await read('duties_leader_board', leaderD.token)).json?.departments?.find((d) => d.department_id === dId);
    const dPosition = dBoard?.duties?.find((x) => x.occurrence_id === d1.data?.occurrence_id)?.positions?.[0]?.assignment;
    const eBoardText = JSON.stringify((await read('duties_leader_board', leaderE.token)).json ?? {});
    const stored = psql(`select override_reason is not null and override_overlaps = 1 and override_by_member = '${leaderD.member}'
      from app.duties_assignments where assignment_id = '${d1.data?.assignment_id}'`);
    check('V13-override-recorded-member-still-awaiting', d1.status === 200 && d1.data?.override_recorded === true
      && d1.data?.response === 'pending' && stored === 't'
      && mine.find((a) => a.assignment_id === d1.data?.assignment_id)?.response === 'pending'
      && dPosition?.override?.reason === REASON && dPosition?.overlaps === 1
      && !eBoardText.includes(REASON) && !JSON.stringify(mine).includes(REASON),
      { status: d1.status, override_recorded: d1.data?.override_recorded, member_sees: mine.map((a) => a.response),
        board_override: Boolean(dPosition?.override), board_overlaps: dPosition?.overlaps,
        other_board_has_reason: eBoardText.includes(REASON) });

    // -------------------------------------------------------------- no overlap, no warning
    const c2 = await candidates(leaderD.token, dId, sun0, '12:00', '13:00');
    const d2 = await publish(leaderD.token, dId, member.member, sun0, '12:00', '13:00');
    check('V14-non-overlapping-raises-no-warning', candidate(c2.json, member.member)?.conflicts?.count === 0
      && d2.status === 200 && !d2.code && d2.data?.override_recorded === false,
      { conflicts: candidate(c2.json, member.member)?.conflicts?.count, status: d2.status, code: d2.code ?? null });

    // -------------------------------------------------------------- the cell-owned fixture
    const cD = candidate((await candidates(leaderD.token, dId, sun1, '18:30', '19:30')).json, member.member);
    const cE = candidate((await candidates(leaderE.token, eId, sun1, '18:30', '19:30')).json, member.member);
    const cellRefused = await publish(leaderD.token, dId, member.member, sun1, '18:30', '19:30');
    check('V15-cell-part-conflicts-disclosed-by-scope', isLimited(cD?.conflicts?.items?.[0])
      && cD.conflicts.items[0].owner_kind === 'cell'
      && cE?.conflicts?.items?.[0]?.visibility === 'full' && cE.conflicts.items[0].duty_name === 'SYNTHETIC cell part'
      && !JSON.stringify(cE).includes('private instructions')
      && cellRefused.field_errors?.member_id === 'overlap',
      { leader_d: cD?.conflicts?.items?.[0]?.visibility, cell_leader: cE?.conflicts?.items?.[0]?.visibility,
        refused: cellRefused.field_errors?.member_id ?? cellRefused.code });

    // -------------------------------------------------------------- two leaders at once
    const races = [];
    for (const [from, to] of [['09:00', '10:00'], ['14:00', '15:00'], ['16:00', '17:00']]) {
      races.push(await Promise.all([
        publish(leaderD.token, dId, member.member, sun1, from, to),
        publish(leaderE.token, eId, member.member, sun1, from, to),
      ]));
    }
    check('V20-concurrent-assignments-one-wins', races.every(oneAssigned),
      { rounds: races.map((r) => r.map((a) => a.code ? a.field_errors?.member_id ?? a.code : 'ok')) });

    // -------------------------------------------------------------- a rota position and a one-off at once
    const gen = await duties(leaderD.token, 'duties.create_series', null, {
      department_id: dId, duty_name: 'SYNTHETIC early prayer', every: 'week', from_date: sun2, until_date: sun2,
      start_time: '09:00', end_time: '10:00', positions: ['Reader'] });
    const rotaOcc = async () => {
      const rota = (await read('duties_rota', leaderD.token)).json;
      const series = rota?.departments?.find((d) => d.department_id === dId)?.series
        ?.find((x) => x.series_id === gen.data?.series_id);
      return { series, occ: series?.occurrences?.[0] };
    };
    let { series, occ } = await rotaOcc();
    const pubRota = await duties(leaderD.token, 'duties.publish_drafts', series?.revision,
      { series_id: gen.data?.series_id, slot_count: 1, deadline_before: '1 day' });
    ({ occ } = await rotaOcc());
    const mixed = await Promise.all([
      duties(leaderD.token, 'duties.assign_slot', occ?.revision, {
        slot_id: occ?.positions?.[0]?.slot_id, member_id: member.member,
        response_deadline: new Date(Date.parse(churchInstant(sun2, '09:00')) - 86_400_000).toISOString() }),
      publish(leaderE.token, eId, member.member, sun2, '09:00', '10:00'),
    ]);
    check('V21-rota-position-and-one-off-race-one-wins', gen.status === 200 && pubRota.status === 200 && !pubRota.code
      && oneAssigned(mixed),
      { answers: mixed.map((a) => a.code ? a.field_errors?.member_id ?? a.code : 'ok') });

    // -------------------------------------------------------------- decline, other department, place change
    const dx = await publish(leaderD.token, dId, other.member, sun3, '10:00', '12:00');
    const declined = await duties(other.token, 'duties.respond', 1, { assignment_id: dx.data?.assignment_id, response: 'declined' });
    const ex = await publish(leaderE.token, eId, other.member, sun3, '10:00', '12:00');
    const dxRev = Number(psql(`select revision from app.duties_occurrences where occurrence_id = '${dx.data?.occurrence_id}'`));
    const placeOnly = await duties(leaderD.token, 'duties.revise_duty', dxRev, {
      occurrence_id: dx.data?.occurrence_id, location: 'SYNTHETIC new room',
      response_deadline: new Date(Date.parse(churchInstant(sun3, '10:00')) - 86_400_000).toISOString() });
    check('V22-asking-a-declined-member-again-needs-a-reason', dx.status === 200 && declined.data?.response === 'declined'
      && ex.status === 200 && ex.data?.override_recorded === false
      && placeOnly.code === 'validation_failed' && placeOnly.field_errors?.override_reason === 'required',
      { other_department: ex.data?.override_recorded, place_change: placeOnly.field_errors ?? placeOnly.code });

    // -------------------------------------------------------------- refusals
    const byMember = await candidates(member.token, dId, sun0, '11:00', '12:00');
    const byOther = await candidates(leaderD.token, eId, sun0, '11:00', '12:00');
    const tables = [];
    for (const t of ['duties_assignments', 'duties_occurrences']) {
      for (const profile of ['app', 'api']) {
        const r = await http('GET', `/rest/v1/${t}?select=*`, { token: leaderD.token, profile });
        tables.push({ t, profile, status: r.status, refused: r.status >= 400 && !Array.isArray(r.json) });
      }
    }
    check('V30-member-other-leader-and-tables-refused', byMember.status === 403 && byOther.status === 403
      && tables.every((x) => x.refused),
      { member: byMember.status, other_leader: byOther.status, tables: tables.map((x) => `${x.profile}.${x.t}:${x.status}`) });

    // -------------------------------------------------------------- content-free records
    const leaks = Number(psql(`select (select count(*) from app.cmd_receipts where result::text like '%SYNTHETIC: agreed%')
      + (select count(*) from app.notifications_jobs j where j::text like '%SYNTHETIC: agreed%')
      + (select count(*) from app.duties_audit a where a::text like '%SYNTHETIC: agreed%')`));
    const audited = Number(psql(`select count(*) from app.duties_audit where action = 'overlap_override' and code = 'overlap'
      and department_id = '${dId}'`));
    check('V40-reason-stays-out-of-receipts-jobs-and-audit', leaks === 0 && audited === 1, { leaks, audited });
  } finally {
    const left = cleanup();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'duties-overlaps-e2e';
            delete from app.platform_environment_history where set_by = 'duties-overlaps-e2e';`);
    }
    log('V99-cleanup', { users_left: Number(left), unmarked: marked,
      departments_left: Number(psql(`select count(*) from app.duties_departments where name in ('${DEPARTMENT}', '${OTHER_DEPARTMENT}')`)),
      cells_left: Number(psql(`select count(*) from app.cells_cells where name = '${CELL}'`)) });
  }
  finish();
}

runMain(import.meta.url, main);
