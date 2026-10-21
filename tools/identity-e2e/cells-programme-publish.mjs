#!/usr/bin/env node
// Story 5.4 end-to-end on the LOCAL stack: publishing a programme through real GoTrue phone
// sign-in (no SMS) and the real Data API (PostgREST), proving the ticket's verify at the API level:
//   * a synthetic programme with an assigned, an unassigned and a department-linked part (and a
//     part for a member who is on that department duty at the same time) is published; the
//     overlap is refused on its part first and published with a reason;
//   * Duties holds one current cell-owned slot per part, Awaiting for the assignees and open for
//     the unassigned part; the department duty is unchanged and still owned by its department;
//   * a republish creates no duplicate slot, link or assignment;
//   * the staff preview equals what a member reads, and the member read holds no response, note,
//     history, instructions or study notes; members of another cell, Admin alone, the cell's
//     leader (not a member) and an account without member access cannot read it;
//   * the member finds the part in My duties (owner Cell programme, Awaiting);
//   * cancelling the programme cancels its cell-owned duties, ends the display link, leaves the
//     department duty alone, and members read nothing;
//   * direct table queries are refused and the programme audit holds no text, names or numbers.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900020-900029. Evidence is redacted JSONL:
// statuses, codes, counts; never tokens, passwords, numbers, names or programme text. Everything
// it created is removed.
//
// Usage: node tools/identity-e2e/cells-programme-publish.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';
import { weekdayInTwoDays } from './cells-meetings.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 5.4 E2E';
export const SHIKOSWE = 'SYNTHETIC Shikoswe Cell (5.4 E2E)';
export const ESTATES = 'SYNTHETIC Estates C5/C7 Cell (5.4 E2E)';
export const DEPARTMENT = 'SYNTHETIC Ushers (5.4 E2E)';
const VENUE = 'SYNTHETIC 12 Shikoswe Road';
const TOPIC = 'SYNTHETIC Rooted in love';
const NOTES = 'SYNTHETIC private study notes';

/** The reserved fictional numbers this run uses (+44 7700 900020-900029). */
export function isFictionalPublishPhone(phone) {
  return /^\+44770090002[0-9]$/.test(phone);
}

/** A member read's text holds none of the private words a projection must leave out. */
export function leaksPrivate(json) {
  return /(study_notes|response|note|history|instructions|SYNTHETIC private)/.test(JSON.stringify(json ?? {}));
}

/** The projection without the fields only a published copy carries. */
export function withoutPublication(projection) {
  if (!projection) return projection;
  const { revision, published_at: publishedAt, ...rest } = projection;
  return rest;
}

/** Each part's Duties state from the staff read, in part order: pending/accepted/declined, open or linked. */
export function partStates(read) {
  return (read?.duties ?? []).map((d) => {
    const linked = (d.positions ?? []).find((p) => p.kind === 'linked');
    if (linked) return 'linked';
    const owned = (d.positions ?? []).find((p) => p.kind === 'owned' && p.position_key === 'lead');
    return owned?.assignment?.response ?? 'open';
  });
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
    admin: { phone: '+447700900020', name: `${NAME_PREFIX} Admin` },
    leader: { phone: '+447700900021', name: `${NAME_PREFIX} Leader S` },
    assistant: { phone: '+447700900022', name: `${NAME_PREFIX} Assistant S` },
    member: { phone: '+447700900023', name: `${NAME_PREFIX} Member S` },
    usher: { phone: '+447700900024', name: `${NAME_PREFIX} Usher S` },
    estates: { phone: '+447700900025', name: `${NAME_PREFIX} Member E` },
    deptLeader: { phone: '+447700900026', name: `${NAME_PREFIX} Department Leader` },
    pending: { phone: '+447700900027', name: `${NAME_PREFIX} Pending`, noLink: true },
  };
  for (const p of Object.values(people)) if (!isFictionalPublishPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
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
    psql(`select app.platform_set_environment('local', 'cells-programme-publish-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('U00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  try {
    const { admin, leader, assistant, member, usher, estates, deptLeader, pending } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      if (!p.noLink) p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'cells-programme-publish-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    check('U01-members-signed-in-by-phone', Object.values(people).every((p) => amrMethods(p.token).includes('password')),
      { amr: amrMethods(admin.token) });

    // ------------------------------------------------------------------ setup
    const S = (await cells(admin.token, 'cells.create_cell', null,
      { name: SHIKOSWE, signup_label: 'SYNTHETIC Shikoswe', broad_area: 'SYNTHETIC Kafue' })).data?.cell_id;
    const E = (await cells(admin.token, 'cells.create_cell', null,
      { name: ESTATES, signup_label: 'SYNTHETIC Estates', broad_area: 'SYNTHETIC Estates' })).data?.cell_id;
    const D = (await duties(admin.token, 'duties.create_department', null, { name: DEPARTMENT })).data?.department_id;
    let ov = (await read('cells_admin_overview', admin.token)).json;
    const grantsRev = (memberId) => ov?.members?.find((m) => m.member_id === memberId)?.grants_revision;
    const grants = [];
    for (const [p, kind, scope] of [[leader, 'cell_leader', S], [assistant, 'cell_assistant', S],
      [deptLeader, 'department_leader', D]]) {
      grants.push(await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantsRev(p.member),
        { member_id: p.member, scope_kind: kind, scope_id: scope }));
      ov = (await read('cells_admin_overview', admin.token)).json;
    }
    const deptRev = () => Number(psql(`select revision from app.duties_departments where department_id = '${D}'`));
    const added = [];
    for (const p of [deptLeader, usher]) {
      added.push(await duties(admin.token, 'duties.add_member', deptRev(), { department_id: D, member_id: p.member }));
    }
    const place = async (memberId, cell) => {
      ov = (await read('cells_admin_overview', admin.token)).json;
      const row = ov?.members?.find((m) => m.member_id === memberId);
      const asked = await cells(admin.token, 'cells.request_change', row?.cell_revision,
        { member_id: memberId, cell_id: cell, cell_revision: ov?.cells?.find((c) => c.cell_id === cell)?.signup_revision });
      return cells(admin.token, 'cells.confirm_request', asked.revision, { request_id: asked.data?.open_request?.request_id });
    };
    const placed = [await place(member.member, S), await place(usher.member, S), await place(estates.member, E)];
    for (const p of [leader, assistant, deptLeader]) p.token = (await signIn(p.phone, p.password)).json?.access_token;
    ov = (await read('cells_admin_overview', admin.token)).json;
    const set = await cells(admin.token, 'cells.set_schedule', ov?.cells?.find((c) => c.cell_id === S)?.revision,
      { cell_id: S, weekday: weekdayInTwoDays(Date.now()), start_time: '18:00', end_time: '19:30', venue: VENUE });
    const meeting = (await read('cells_meetings', leader.token)).json?.cells?.find((c) => c.cell_id === S)?.meetings?.[0];
    // The department's evening duty at the meeting's time, the usher on it.
    const dept = await duties(deptLeader.token, 'duties.publish_duty', null, {
      department_id: D, member_id: usher.member, duty_name: 'SYNTHETIC Evening ushering',
      starts_at: meeting?.starts_at, ends_at: meeting?.ends_at });
    const deptBefore = psql(`select o.revision || '|' || o.department_id || '|' || coalesce(o.cell_id::text, 'none') || '|'
                               || (select count(*) from app.duties_assignments a join app.duties_slots s using (slot_id)
                                    where s.occurrence_id = o.occurrence_id)
                               from app.duties_occurrences o where o.department_id = '${D}'`);
    check('U02-cells-department-and-a-meeting', [S, E, D].every(Boolean) && grants.every((g) => g.status === 200)
      && added.every((a) => a.status === 200) && placed.every((p) => p.status === 200) && set.status === 200
      && dept.status === 200 && Boolean(meeting),
      { grants: grants.map((g) => g.status), added: added.map((a) => a.status), placed: placed.map((p) => p.status),
        schedule: set.status, department_duty: dept.status });

    // ------------------------------------------------------------------ draft
    const programmeRead = async (p) => read('cells_programme', p.token, { meeting_id: meeting?.meeting_id });
    const created = await cells(leader.token, 'cells.create_programme', null, { meeting_id: meeting?.meeting_id });
    const P = created.data?.programme_id;
    const offered = (await programmeRead(leader)).json?.linkable ?? [];
    const slot = offered[0]?.slot_id;
    const saved = await cells(leader.token, 'cells.save_programme', created.revision, {
      programme_id: P, topic: TOPIC, scripture: 'Ephesians 3:14-21', study_notes: NOTES,
      parts: [
        { label: 'SYNTHETIC Opening prayer', start_time: '18:00', end_time: '18:10', assignee_member_id: member.member },
        { label: 'SYNTHETIC Worship', start_time: '18:10', end_time: '18:30' },
        { label: 'SYNTHETIC Bible study', start_time: '18:30', end_time: '19:00', assignee_member_id: usher.member },
        { label: 'SYNTHETIC Ushering', start_time: '19:00', end_time: '19:30', linked_slot_id: slot },
      ] });
    check('U10-draft-with-assigned-open-and-department-parts', created.status === 200 && offered.length === 1
      && saved.status === 200 && saved.data?.gaps === 1 && Boolean(saved.data?.parts?.[3]?.linked_label),
      { created: created.status, linkable_offered: offered.length, saved: saved.status, gaps: saved.data?.gaps });

    // ------------------------------------------------------------------ publish
    const refused = await cells(leader.token, 'cells.publish_programme', saved.revision, { programme_id: P });
    const byMember = await cells(member.token, 'cells.publish_programme', saved.revision, { programme_id: P });
    const byAdmin = await cells(admin.token, 'cells.publish_programme', saved.revision, { programme_id: P });
    const published = await cells(leader.token, 'cells.publish_programme', saved.revision,
      { programme_id: P, override_reason: 'SYNTHETIC leads study before ushering' });
    check('U20-overlap-refused-on-its-part-then-published-with-a-reason',
      refused.code === 'validation_failed' && refused.field_errors?.['parts.2.member_id'] === 'overlap'
      && byMember.code === 'forbidden' && byAdmin.code === 'forbidden'
      && published.status === 200 && published.data?.state === 'published' && published.data?.duties?.length === 4,
      { refused: refused.code, part_field: Object.keys(refused.field_errors ?? {}), member: byMember.code,
        admin: byAdmin.code, published: published.data?.state, duties_parts: published.data?.duties?.length });

    const staff1 = (await programmeRead(leader)).json;
    const counts = () => psql(`select (select count(*) from app.duties_part_links l join app.cells_programme_parts pt on pt.part_id = l.source_id
                                         where pt.programme_id = '${P}' and l.ended_at is null)
                                   || '|' || (select count(*) from app.duties_slots s join app.duties_part_links l using (slot_id)
                                         join app.cells_programme_parts pt on pt.part_id = l.source_id
                                         where pt.programme_id = '${P}' and l.link_kind = 'owned')
                                   || '|' || (select count(*) from app.duties_assignments a join app.duties_part_links l using (slot_id)
                                         join app.cells_programme_parts pt on pt.part_id = l.source_id
                                         where pt.programme_id = '${P}' and l.link_kind = 'owned')`);
    const counts1 = counts();
    const deptAfter = psql(`select o.revision || '|' || o.department_id || '|' || coalesce(o.cell_id::text, 'none') || '|'
                              || (select count(*) from app.duties_assignments a join app.duties_slots s using (slot_id)
                                   where s.occurrence_id = o.occurrence_id)
                              from app.duties_occurrences o where o.department_id = '${D}'`);
    check('U21-one-slot-per-part-awaiting-department-duty-unchanged',
      JSON.stringify(partStates(staff1)) === '["pending","open","pending","linked"]' && counts1 === '4|3|2'
      && deptAfter === deptBefore,
      { states: partStates(staff1), links_slots_assignments: counts1, department_duty_unchanged: deptAfter === deptBefore });

    const republished = await cells(assistant.token, 'cells.publish_programme', published.revision, { programme_id: P });
    check('U22-republish-duplicates-nothing', republished.status === 200 && counts() === counts1,
      { republished: republished.status, counts: counts() });

    // ------------------------------------------------------------------ who reads what
    const memberProgramme = async (p) => read('cells_meeting_programme', p.token, { meeting_id: meeting?.meeting_id });
    const mine = await memberProgramme(member);
    const staff2 = (await programmeRead(leader)).json;
    const parts = mine.json?.programme?.parts ?? [];
    check('U30-preview-equals-the-member-read', mine.status === 200 && parts.length === 4
      && JSON.stringify(withoutPublication(mine.json?.programme)) === JSON.stringify(staff2?.preview)
      && mine.json?.meeting?.venue === VENUE && parts[1]?.leader === null && Boolean(parts[3]?.department),
      { status: mine.status, parts: parts.length, preview_equal:
        JSON.stringify(withoutPublication(mine.json?.programme)) === JSON.stringify(staff2?.preview),
        venue_shown: mine.json?.meeting?.venue === VENUE });
    const others = { estates: await memberProgramme(estates), admin: await memberProgramme(admin),
      leader: await memberProgramme(leader), pending: await memberProgramme(pending) };
    check('U31-member-read-is-safe-and-for-members-only', !leaksPrivate(mine.json)
      && others.estates.status === 403 && others.estates.detail === 'not_granted'
      && others.admin.status === 403 && others.leader.status === 403 && others.pending.status >= 400,
      { leaks_private: leaksPrivate(mine.json), estates: others.estates.status, admin: others.admin.status,
        leader_not_member: others.leader.status, pending: others.pending.status });

    const myDuties = (await read('duties_my_duties', member.token)).json?.assignments ?? [];
    const part = myDuties.find((a) => a.duty_name === 'SYNTHETIC Opening prayer');
    check('U32-member-finds-the-part-in-my-duties', part?.owner_kind === 'cell' && part?.response === 'pending',
      { owner_kind: part?.owner_kind ?? null, response: part?.response ?? null });

    // ------------------------------------------------------------------ cancel
    const cancelled = await cells(leader.token, 'cells.cancel_programme', republished.revision, { programme_id: P });
    const afterCancel = await memberProgramme(member);
    const ownedStates = psql(`select string_agg(distinct o.occurrence_state, ',') from app.duties_occurrences o
                               join app.duties_slots s using (occurrence_id) join app.duties_part_links l using (slot_id)
                               join app.cells_programme_parts pt on pt.part_id = l.source_id
                              where pt.programme_id = '${P}' and l.link_kind = 'owned'`);
    const activeLinks = psql(`select count(*) from app.duties_part_links l join app.cells_programme_parts pt on pt.part_id = l.source_id
                               where pt.programme_id = '${P}' and l.link_kind = 'linked' and l.ended_at is null`);
    const deptFinal = psql(`select o.revision || '|' || o.department_id || '|' || coalesce(o.cell_id::text, 'none') || '|'
                              || (select count(*) from app.duties_assignments a join app.duties_slots s using (slot_id)
                                   where s.occurrence_id = o.occurrence_id)
                              from app.duties_occurrences o where o.department_id = '${D}'`);
    check('U40-cancel-ends-the-cell-duties-only', cancelled.status === 200 && afterCancel.json?.programme === null
      && ownedStates === 'cancelled' && activeLinks === '0' && deptFinal === deptBefore,
      { cancelled: cancelled.data?.state, member_reads: afterCancel.json?.programme ?? null, owned: ownedStates,
        links_left: Number(activeLinks), department_duty_unchanged: deptFinal === deptBefore });

    // ------------------------------------------------------------------ tables and audit
    const tables = [];
    for (const t of ['cells_programme_projections', 'cells_programmes', 'cells_programme_parts']) {
      for (const profile of ['app', 'api']) {
        const x = await http('GET', `/rest/v1/${t}?select=*`, { token: member.token, profile });
        tables.push({ t, profile, status: x.status, refused: x.status >= 400 && !Array.isArray(x.json) });
      }
    }
    check('U50-direct-table-queries-refused', tables.every((x) => x.refused),
      { statuses: tables.map((x) => `${x.profile}.${x.t}:${x.status}`) });
    const auditText = psql(`select coalesce(string_agg(a::text, ' '), '') from app.cells_programme_audit a where a.cell_id = '${S}'`);
    const leaked = [TOPIC, NOTES, VENUE, 'SYNTHETIC Opening prayer', NAME_PREFIX,
      ...Object.values(people).map((p) => p.phone.slice(1))].filter((v) => auditText.includes(v));
    check('U51-audit-content-free', leaked.length === 0 && auditText.length > 0, { leaked_values: leaked.length,
      actions: psql(`select string_agg(distinct action, ',' order by action) from app.cells_programme_audit where cell_id = '${S}'`) });
  } finally {
    const left = cleanup();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'cells-programme-publish-e2e';
            delete from app.platform_environment_history where set_by = 'cells-programme-publish-e2e';`);
    }
    log('U99-cleanup', { users_left: Number(left), unmarked: marked,
      programmes_left: Number(psql(`select count(*) from app.cells_programmes p join app.cells_cells c using (cell_id)
                                    where c.name in ('${SHIKOSWE}', '${ESTATES}')`)) });
  }
  finish();
}

runMain(import.meta.url, main);
