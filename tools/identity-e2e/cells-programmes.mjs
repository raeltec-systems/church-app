#!/usr/bin/env node
// Story 5.3 end-to-end on the LOCAL stack: a meeting's programme draft through real GoTrue phone
// sign-in (no SMS) and the real Data API (PostgREST), proving the ticket's verify at the API level:
//   * the cell's leader starts a programme for a meeting ahead and saves parts in church time, one
//     of them unassigned (a visible gap) and one led by a member without a login;
//   * overlapping, out-of-order, out-of-meeting and end-before-start parts and an assignee from
//     another cell are refused per part (`parts.<index>`) and nothing is written; a stale save is
//     a conflict; the assistant's save keeps every part id;
//   * a cell member, the other cell's leader and an account without member access cannot read the
//     draft; Admin-only access reads counts only; Pastor oversight reads the whole draft and
//     cannot change it; a cancelled programme is read-only;
//   * direct table queries are refused and the audit holds no topic, labels, names or numbers.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900010-900019. Evidence is redacted JSONL:
// statuses, codes, counts; never tokens, passwords, numbers, names or programme text. Everything
// it created is removed.
//
// Usage: node tools/identity-e2e/cells-programmes.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';
import { churchClock } from './duties-shared.mjs';
import { weekdayInTwoDays } from './cells-meetings.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 5.3 E2E';
export const SHIKOSWE = 'SYNTHETIC Shikoswe Cell (5.3 E2E)';
export const ESTATES = 'SYNTHETIC Estates C5/C7 Cell (5.3 E2E)';
const VENUE = 'SYNTHETIC 12 Shikoswe Road';
const TOPIC = 'SYNTHETIC Rooted in love';
const LABELS = ['SYNTHETIC Opening prayer', 'SYNTHETIC Worship', 'SYNTHETIC Bible study'];

/** The reserved fictional numbers this run uses (+44 7700 900010-900019). */
export function isFictionalProgrammesPhone(phone) {
  return /^\+44770090001[0-9]$/.test(phone);
}

/** A part as cells.save_programme takes it. */
export function partOf(label, start, end, assignee = null, partId = undefined) {
  return { ...(partId ? { part_id: partId } : {}), label, start_time: start, end_time: end, assignee_member_id: assignee };
}

/** The `parts.<index>` codes of a refusal, in index order ("1:overlap"). */
export function partCodes(fieldErrors) {
  return Object.entries(fieldErrors ?? {})
    .filter(([k]) => /^parts\.\d+$/.test(k))
    .map(([k, v]) => `${k.slice(6)}:${v}`)
    .sort();
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
  const read = async (fn, token, body = {}) => {
    const r = await rpc(fn, token, body);
    return { status: r.status, json: r.json, detail: r.json?.details ?? null };
  };

  const people = {
    admin: { phone: '+447700900010', name: `${NAME_PREFIX} Admin` },
    leader: { phone: '+447700900011', name: `${NAME_PREFIX} Leader S` },
    assistant: { phone: '+447700900012', name: `${NAME_PREFIX} Assistant S` },
    member: { phone: '+447700900013', name: `${NAME_PREFIX} Member S` },
    estates: { phone: '+447700900014', name: `${NAME_PREFIX} Member E` },
    estatesLeader: { phone: '+447700900015', name: `${NAME_PREFIX} Leader E` },
    pastor: { phone: '+447700900016', name: `${NAME_PREFIX} Pastor` },
    pending: { phone: '+447700900017', name: `${NAME_PREFIX} Pending`, noLink: true },
  };
  for (const p of Object.values(people)) if (!isFictionalProgrammesPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
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
    create temp table gone_jobs as
      select j.job_id from app.notifications_jobs j
       where j.recipient_member_id in (select member_id from gone_members)
          or j.source_id in (select m.meeting_id from app.cells_meetings m where m.cell_id in (select cell_id from gone_cells));
    delete from app.notifications_push_jobs p where p.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_attempts a where a.job_id in (select job_id from gone_jobs);
    delete from app.notifications_direct_contact_needs n where n.job_id in (select job_id from gone_jobs);
    update app.notifications_jobs j set snoozed_from_item_id = null where j.job_id in (select job_id from gone_jobs);
    delete from app.notifications_inbox_items i where i.job_id in (select job_id from gone_jobs)
       or i.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_jobs j where j.job_id in (select job_id from gone_jobs);
    delete from app.notifications_schedules s where s.recipient_member_id in (select member_id from gone_members)
       or s.source_id in (select m.meeting_id from app.cells_meetings m where m.cell_id in (select cell_id from gone_cells));
    delete from app.cells_programme_audit a where a.cell_id in (select cell_id from gone_cells)
       or a.actor_member_id in (select member_id from gone_members);
    delete from app.cells_programme_parts pt
     where pt.programme_id in (select p.programme_id from app.cells_programmes p where p.cell_id in (select cell_id from gone_cells));
    delete from app.cells_programmes p where p.cell_id in (select cell_id from gone_cells);
    delete from app.cells_meeting_contact_needs n
     where n.meeting_id in (select m.meeting_id from app.cells_meetings m where m.cell_id in (select cell_id from gone_cells));
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
    psql(`select app.platform_set_environment('local', 'cells-programmes-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('P00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  try {
    const { admin, leader, assistant, member, estates, estatesLeader, pastor, pending } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      if (!p.noLink) p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'cells-programmes-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    const accountless = psql(`insert into app.identity_members (display_name, membership_state, is_synthetic)
      values ('${NAME_PREFIX} Accountless A', 'approved', true) returning member_id`);
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    check('P01-members-signed-in-by-phone', Object.values(people).every((p) => amrMethods(p.token).includes('password')),
      { amr: amrMethods(admin.token) });

    // ------------------------------------------------------------------ setup
    const made = [];
    for (const [name, label] of [[SHIKOSWE, 'SYNTHETIC Shikoswe'], [ESTATES, 'SYNTHETIC Estates C5/C7']]) {
      made.push(await cells(admin.token, 'cells.create_cell', null, { name, signup_label: label, broad_area: 'SYNTHETIC Kafue' }));
    }
    const S = made[0].data?.cell_id;
    const E = made[1].data?.cell_id;
    const overview = async () => (await read('cells_admin_overview', admin.token)).json;
    let ov = await overview();
    const grantsRev = (memberId) => ov?.members?.find((m) => m.member_id === memberId)?.grants_revision;
    const grants = [];
    for (const [p, kind, cell] of [[leader, 'cell_leader', S], [assistant, 'cell_assistant', S], [estatesLeader, 'cell_leader', E]]) {
      grants.push(await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantsRev(p.member),
        { member_id: p.member, scope_kind: kind, scope_id: cell }));
      ov = await overview();
    }
    grants.push(await envelope('identity_grant_command', admin.token, 'identity.grant_role', grantsRev(pastor.member),
      { member_id: pastor.member, role: 'pastor' }));
    const place = async (memberId, cell) => {
      ov = await overview();
      const row = ov?.members?.find((m) => m.member_id === memberId);
      const option = ov?.cells?.find((c) => c.cell_id === cell);
      const asked = await cells(admin.token, 'cells.request_change', row?.cell_revision,
        { member_id: memberId, cell_id: cell, cell_revision: option?.signup_revision });
      return cells(admin.token, 'cells.confirm_request', asked.revision, { request_id: asked.data?.open_request?.request_id });
    };
    const placed = [await place(member.member, S), await place(accountless, S), await place(estates.member, E)];
    for (const p of [leader, assistant, estatesLeader, pastor]) p.token = (await signIn(p.phone, p.password)).json?.access_token;
    ov = await overview();
    const set = await cells(admin.token, 'cells.set_schedule', ov?.cells?.find((c) => c.cell_id === S)?.revision,
      { cell_id: S, weekday: weekdayInTwoDays(Date.now()), start_time: '18:00', end_time: '19:30', venue: VENUE });
    const board = (await read('cells_meetings', leader.token)).json;
    const meeting = board?.cells?.find((c) => c.cell_id === S)?.meetings?.[0];
    check('P02-cells-roles-members-and-a-meeting-ahead', made.every((m) => m.status === 200)
      && grants.every((g) => g.status === 200) && placed.every((p) => p.status === 200) && set.status === 200
      && churchClock(meeting?.starts_at) === '18:00' && Date.parse(meeting?.starts_at) > Date.now(),
      { cells: made.map((m) => m.status), grants: grants.map((g) => g.status), placed: placed.map((p) => p.status),
        schedule: set.status, meeting_at_18_church_time: churchClock(meeting?.starts_at) === '18:00' });

    // ------------------------------------------------------------------ create
    const createBy = async (p) => cells(p.token, 'cells.create_programme', null, { meeting_id: meeting?.meeting_id });
    const refusedCreate = { member: await createBy(member), admin: await createBy(admin), pastor: await createBy(pastor),
      other_leader: await createBy(estatesLeader) };
    const created = await createBy(leader);
    const again = await createBy(assistant);
    const P = created.data?.programme_id;
    check('P10-leader-starts-the-programme-once', Object.values(refusedCreate).every((r) => r.code === 'forbidden')
      && created.status === 200 && created.revision === 1 && created.data?.state === 'draft'
      && again.code === 'conflict' && again.field_errors?.meeting_id === 'exists',
      { refused: Object.fromEntries(Object.entries(refusedCreate).map(([k, v]) => [k, v.code])), created: created.status,
        revision: created.revision, second: again.code, second_field: again.field_errors?.meeting_id ?? null });

    // ------------------------------------------------------------------ save with a gap
    const draft = [
      partOf(LABELS[0], '18:00', '18:10', member.member),
      partOf(LABELS[1], '18:10', '18:30', accountless),
      partOf(LABELS[2], '18:30', '19:15'),
    ];
    const saved = await cells(leader.token, 'cells.save_programme', 1,
      { programme_id: P, topic: TOPIC, scripture: 'Ephesians 3:14-21', study_notes: 'SYNTHETIC notes', parts: draft });
    const parts = saved.data?.parts ?? [];
    check('P20-draft-saved-with-a-visible-gap', saved.status === 200 && saved.revision === 2 && parts.length === 3
      && saved.data?.gaps === 1 && parts[2]?.assignee === null && parts[1]?.assignee?.member_id === accountless
      && churchClock(parts[0]?.starts_at) === '18:00' && churchClock(parts[2]?.ends_at) === '19:15',
      { status: saved.status, revision: saved.revision, parts: parts.length, gaps: saved.data?.gaps,
        accountless_assignable: parts[1]?.assignee?.member_id === accountless });

    // ------------------------------------------------------------------ bad parts
    const bad = async (ps) => cells(leader.token, 'cells.save_programme', 2, { programme_id: P, parts: ps });
    const tries = {
      overlap: await bad([partOf('A', '18:00', '18:20'), partOf('B', '18:10', '18:30')]),
      out_of_order: await bad([partOf('A', '18:30', '18:40'), partOf('B', '18:00', '18:10')]),
      outside_meeting: await bad([partOf('A', '17:50', '18:10'), partOf('B', '19:20', '19:40')]),
      end_before_start: await bad([partOf('A', '18:20', '18:10')]),
      assignee_not_in_cell: await bad([partOf('A', '18:00', '18:10', estates.member)]),
    };
    const codes = Object.fromEntries(Object.entries(tries).map(([k, v]) => [k, partCodes(v.field_errors)]));
    const unchanged = (await read('cells_programme', leader.token, { meeting_id: meeting?.meeting_id })).json?.programme;
    check('P21-bad-parts-refused-per-part-nothing-written', Object.values(tries).every((t) => t.code === 'validation_failed')
      && JSON.stringify(codes.overlap) === '["1:overlap"]' && JSON.stringify(codes.out_of_order) === '["1:out_of_order"]'
      && JSON.stringify(codes.outside_meeting) === '["0:outside_meeting","1:outside_meeting"]'
      && JSON.stringify(codes.end_before_start) === '["0:end_before_start"]'
      && JSON.stringify(codes.assignee_not_in_cell) === '["0:assignee_not_in_cell"]'
      && unchanged?.revision === 2 && unchanged?.parts?.length === 3,
      { codes, revision_after: unchanged?.revision, parts_after: unchanged?.parts?.length });

    const stale = await cells(assistant.token, 'cells.save_programme', 1, { programme_id: P, parts: draft });
    const keepIds = parts.map((p, i) => partOf(LABELS[i], churchClock(p.starts_at), churchClock(p.ends_at),
      p.assignee?.member_id ?? null, p.part_id));
    const resaved = await cells(assistant.token, 'cells.save_programme', 2, { programme_id: P, topic: TOPIC, parts: keepIds });
    const sameIds = (resaved.data?.parts ?? []).map((p) => p.part_id).join() === parts.map((p) => p.part_id).join();
    check('P22-stale-save-conflicts-and-part-ids-are-stable', stale.code === 'conflict' && resaved.status === 200
      && resaved.revision === 3 && sameIds,
      { stale: stale.code, resaved: resaved.status, revision: resaved.revision, same_part_ids: sameIds });

    // ------------------------------------------------------------------ who reads the draft
    const readBy = async (p) => read('cells_programme', p.token, { meeting_id: meeting?.meeting_id });
    const r = { member: await readBy(member), other_leader: await readBy(estatesLeader), pending: await readBy(pending),
      admin: await readBy(admin), pastor: await readBy(pastor), assistant: await readBy(assistant) };
    const text = (x) => JSON.stringify(x.json ?? {});
    const adminText = text(r.admin);
    check('P30-only-managers-and-pastor-oversight-read-the-draft',
      r.member.status === 403 && r.member.detail === 'not_granted'
      && r.other_leader.status === 403 && r.other_leader.detail === 'not_granted' && r.pending.status >= 400
      && r.admin.status === 200 && r.admin.json?.view === 'metadata' && r.admin.json?.programme?.part_count === 3
      && r.admin.json?.programme?.gaps === 1 && !adminText.includes(TOPIC) && !adminText.includes(LABELS[0])
      && !adminText.includes(NAME_PREFIX) && !adminText.includes(VENUE)
      && r.pastor.status === 200 && r.pastor.json?.view === 'full' && r.pastor.json?.can_edit === false
      && r.pastor.json?.programme?.topic === TOPIC && !text(r.pastor).includes(VENUE)
      && r.assistant.json?.can_edit === true && r.assistant.json?.roster?.length === 2,
      { member: `${r.member.status}:${r.member.detail}`, other_leader: `${r.other_leader.status}:${r.other_leader.detail}`,
        pending: r.pending.status, admin_view: r.admin.json?.view, admin_leaks_content: adminText.includes(TOPIC),
        pastor_view: r.pastor.json?.view, pastor_can_edit: r.pastor.json?.can_edit, roster: r.assistant.json?.roster?.length });

    const pastorSave = await cells(pastor.token, 'cells.save_programme', 3, { programme_id: P, parts: [] });
    const adminSave = await cells(admin.token, 'cells.save_programme', 3, { programme_id: P, parts: [] });
    check('P31-pastor-and-admin-cannot-change-it', pastorSave.code === 'forbidden' && adminSave.code === 'forbidden',
      { pastor: pastorSave.code, admin: adminSave.code });

    // ------------------------------------------------------------------ cancel
    const cancelled = await cells(leader.token, 'cells.cancel_programme', 3, { programme_id: P });
    const afterCancel = await cells(leader.token, 'cells.save_programme', 4, { programme_id: P, parts: [] });
    check('P40-a-cancelled-programme-is-read-only', cancelled.status === 200 && cancelled.data?.state === 'cancelled'
      && afterCancel.code === 'conflict' && afterCancel.field_errors?.programme_id === 'not_draft',
      { cancelled: cancelled.data?.state, save_after: afterCancel.code, field: afterCancel.field_errors?.programme_id ?? null });

    // ------------------------------------------------------------------ direct tables and audit
    const tables = [];
    for (const t of ['cells_programmes', 'cells_programme_parts', 'cells_programme_audit']) {
      for (const profile of ['app', 'api']) {
        const x = await http('GET', `/rest/v1/${t}?select=*`, { token: leader.token, profile });
        tables.push({ t, profile, status: x.status, refused: x.status >= 400 && !Array.isArray(x.json) });
      }
    }
    check('P50-direct-table-queries-refused', tables.every((x) => x.refused),
      { statuses: tables.map((x) => `${x.profile}.${x.t}:${x.status}`) });
    const auditText = psql(`select coalesce(string_agg(a::text, ' '), '') from app.cells_programme_audit a
                             where a.cell_id = '${S}'`);
    const leaked = [TOPIC, VENUE, ...LABELS, ...Object.values(people).map((p) => p.phone.slice(1)), NAME_PREFIX]
      .filter((v) => auditText.includes(v));
    check('P51-audit-content-free', leaked.length === 0 && auditText.length > 0, { leaked_values: leaked.length,
      actions: psql(`select string_agg(distinct action, ',' order by action) from app.cells_programme_audit where cell_id = '${S}'`) });
  } finally {
    const left = cleanup();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'cells-programmes-e2e';
            delete from app.platform_environment_history where set_by = 'cells-programmes-e2e';`);
    }
    log('P99-cleanup', { users_left: Number(left), unmarked: marked,
      programmes_left: Number(psql(`select count(*) from app.cells_programmes p join app.cells_cells c using (cell_id)
                                    where c.name in ('${SHIKOSWE}', '${ESTATES}')`)) });
  }
  finish();
}

runMain(import.meta.url, main);
