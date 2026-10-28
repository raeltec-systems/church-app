#!/usr/bin/env node
// Story 5.2 end-to-end on the LOCAL stack: meeting reminders and change notices through real
// GoTrue phone sign-in (no SMS), the real Data API (PostgREST) and the real worker script
// (tools/notifications/worker.mjs), proving the ticket's seven cases at the API level:
//   * normal week: one reminder per confirmed member (none for the leader, who is not a member);
//   * a leader-changed reminder moves every member's reminder;
//   * a move cancels the old-time reminder, plans the new one and delivers a change notice that
//     opens My cell; a cancellation leaves no reminder and delivers a cancellation notice;
//   * a member snoozes a delivered reminder and gets it again;
//   * a member transferred out before the reminder gets nothing;
//   * an accountless member gets no inbox item: the leader sees them under "Tell directly";
//   * no job, item or opened item carries a venue or a member name.
// Reminders far ahead are made due now by moving their scheduled_at (the worker then runs them),
// as the duties reminder E2E does.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900390-900399. Evidence is redacted JSONL:
// statuses, codes, counts; never tokens, passwords, numbers, venues or the credential. Everything
// it created is removed; the run's credential is revoked and its principal disabled.
//
// Usage: node tools/identity-e2e/cells-meeting-reminders.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';
import { notificationsWorker } from './duties-shared.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 5.2 E2E';
export const SHIKOSWE = 'SYNTHETIC Shikoswe Cell (5.2 E2E)';
export const ESTATES = 'SYNTHETIC Estates C5/C7 Cell (5.2 E2E)';
const VENUE = 'SYNTHETIC 12 Shikoswe Road';

/** The reserved fictional numbers this run uses (+44 7700 900390-900399). */
export function isFictionalMeetingRemindersPhone(phone) {
  return /^\+44770090039[0-9]$/.test(phone);
}

/** The ISO weekday (1 = Monday) three church days after `nowMs`. */
export function weekdayInThreeDays(nowMs) {
  const d = new Date(nowMs + 2 * 3_600_000 + 3 * 86_400_000).getUTCDay();
  return d === 0 ? 7 : d;
}

/** Whole hours from `scheduledIso` to `startIso` (the reminder's offset before the start). */
export function hoursBefore(scheduledIso, startIso) {
  return Math.round((Date.parse(startIso) - Date.parse(scheduledIso)) / 3_600_000);
}

/** No string in `value` (deep) contains any of `needles`. */
export function containsNone(value, needles) {
  const text = JSON.stringify(value ?? null);
  return needles.every((n) => !text.includes(n));
}

async function main() {
  const { log, check, finish } = startRun();
  const keys = localKey();
  const { origin, key } = keys;
  const http = localHttp(keys);
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const envelope = (fn, token, cmd, expected, payload, requestId = randomUUID()) =>
    rpc(fn, token, { version: 1, command: cmd, request_id: requestId, expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const cells = (token, cmd, expected, payload) => envelope('cells_command', token, cmd, expected, payload);
  const read = async (fn, token) => (await rpc(fn, token)).json;

  const people = {
    admin: { phone: '+447700900390', name: `${NAME_PREFIX} Admin` },
    leader: { phone: '+447700900391', name: `${NAME_PREFIX} Leader` },
    member: { phone: '+447700900392', name: `${NAME_PREFIX} Member M` },
    mover: { phone: '+447700900393', name: `${NAME_PREFIX} Member T` },
  };
  for (const p of Object.values(people)) if (!isFictionalMeetingRemindersPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  const names = [...Object.values(people).map((p) => p.name), `${NAME_PREFIX} Accountless A`];
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
    create temp table gone_meetings as
      select m.meeting_id from app.cells_meetings m where m.cell_id in (select cell_id from gone_cells);
    create temp table gone_jobs as
      select j.job_id from app.notifications_jobs j
       where j.recipient_member_id in (select member_id from gone_members)
          or j.source_id in (select meeting_id from gone_meetings);
    delete from app.notifications_push_jobs p where p.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_attempts a where a.job_id in (select job_id from gone_jobs);
    delete from app.notifications_direct_contact_needs n where n.job_id in (select job_id from gone_jobs);
    update app.notifications_jobs j set snoozed_from_item_id = null where j.job_id in (select job_id from gone_jobs);
    delete from app.notifications_inbox_items i where i.job_id in (select job_id from gone_jobs)
       or i.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_jobs j where j.job_id in (select job_id from gone_jobs);
    delete from app.notifications_schedules s where s.source_id in (select meeting_id from gone_meetings)
       or s.recipient_member_id in (select member_id from gone_members);
    delete from app.cells_meeting_contact_needs n where n.meeting_id in (select meeting_id from gone_meetings);
    delete from app.cells_meeting_audit a where a.cell_id in (select cell_id from gone_cells)
       or a.actor_member_id in (select member_id from gone_members);
    delete from app.cells_meetings m where m.meeting_id in (select meeting_id from gone_meetings);
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
    psql(`select app.platform_set_environment('local', 'cells-meeting-reminders-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('R00-precondition', { settings: { phone: settings.json?.external?.phone }, leftover_users_removed: cleanup() });

  const run = randomUUID().slice(0, 8);
  const { principal, credentialId, worker } = notificationsWorker({ origin, key, operator: OPERATOR,
    principalName: `notifications-worker-meetings-${run}`, label: `cells meeting reminders e2e ${run}` });

  try {
    const { admin, leader, member, mover } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'cells-meeting-reminders-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    const accountless = psql(`insert into app.identity_members (display_name, membership_state, is_synthetic)
      values ('${NAME_PREFIX} Accountless A', 'approved', true) returning member_id`);
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);

    // Cells, the leader, and three confirmed members of Shikoswe (one without a login).
    const S = (await cells(admin.token, 'cells.create_cell', null,
      { name: SHIKOSWE, signup_label: 'SYNTHETIC Shikoswe', broad_area: 'SYNTHETIC Kafue' })).data?.cell_id;
    const E = (await cells(admin.token, 'cells.create_cell', null,
      { name: ESTATES, signup_label: 'SYNTHETIC Estates', broad_area: 'SYNTHETIC Estates' })).data?.cell_id;
    const overview = async () => read('cells_admin_overview', admin.token);
    let ov = await overview();
    const granted = await envelope('identity_grant_command', admin.token, 'identity.grant_scope',
      ov?.members?.find((m) => m.member_id === leader.member)?.grants_revision,
      { member_id: leader.member, scope_kind: 'cell_leader', scope_id: S });
    const place = async (memberId, cell) => {
      ov = await overview();
      const row = ov?.members?.find((m) => m.member_id === memberId);
      const asked = await cells(admin.token, 'cells.request_change', row?.cell_revision,
        { member_id: memberId, cell_id: cell, cell_revision: ov?.cells?.find((c) => c.cell_id === cell)?.signup_revision });
      return cells(admin.token, 'cells.confirm_request', asked.revision, { request_id: asked.data?.open_request?.request_id });
    };
    const placed = [await place(member.member, S), await place(mover.member, S), await place(accountless, S)];
    check('R01-members-and-cells', Object.values(people).every((p) => amrMethods(p.token).includes('password'))
      && granted.status === 200 && placed.every((p) => p.status === 200),
      { grant: granted.status, placed: placed.map((p) => p.status) });

    // ------------------------------------------------------------------ normal week
    ov = await overview();
    const set = await cells(admin.token, 'cells.set_schedule', ov?.cells?.find((c) => c.cell_id === S)?.revision,
      { cell_id: S, weekday: weekdayInThreeDays(Date.now()), start_time: '18:00', end_time: '19:30', venue: VENUE });
    const board = async () => (await read('cells_meetings', leader.token))?.cells?.find((c) => c.cell_id === S);
    let b = await board();
    const [first, second, third] = b?.meetings ?? [];
    const remindersOf = (meetingId) => JSON.parse(psql(`select coalesce(json_agg(json_build_object(
        'who', j.recipient_member_id, 'at', to_char(j.scheduled_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))), '[]')
      from app.notifications_jobs j where j.source_type = 'cells_meeting' and j.source_id = '${meetingId}'
       and j.reminder_kind = 'cells_meeting_reminder' and j.job_state = 'pending' and j.snoozed_from_item_id is null`));
    const r1 = remindersOf(first.meeting_id);
    const whoGets = new Set(r1.map((r) => r.who));
    check('R10-normal-week-one-reminder-per-confirmed-member', set.status === 200 && r1.length === 3
      && whoGets.has(member.member) && whoGets.has(mover.member) && whoGets.has(accountless) && !whoGets.has(leader.member)
      && r1.every((r) => hoursBefore(r.at, first.starts_at) === 24),
      { set: set.status, reminders: r1.length, leader_reminded: whoGets.has(leader.member),
        hours_before: [...new Set(r1.map((r) => hoursBefore(r.at, first.starts_at)))] });

    // ------------------------------------------------------------------ leader changes the reminders
    const changed = await cells(leader.token, 'cells.set_meeting_reminders', b?.schedule?.reminders_revision,
      { cell_id: S, reminders: [{ before: '2 hours' }] });
    const r2 = remindersOf(first.meeting_id);
    check('R20-leader-changed-reminder', changed.status === 200 && r2.length === 3
      && r2.every((r) => hoursBefore(r.at, first.starts_at) === 2),
      { status: changed.status, hours_before: [...new Set(r2.map((r) => hoursBefore(r.at, first.starts_at)))] });

    // ------------------------------------------------------------------ move: notice delivered
    const shift = (iso, h) => new Date(Date.parse(iso) + h * 3_600_000).toISOString();
    const moved = await cells(leader.token, 'cells.move_meeting', second.revision,
      { meeting_id: second.meeting_id, starts_at: shift(second.starts_at, 24), ends_at: shift(second.ends_at, 24) });
    const r3 = remindersOf(second.meeting_id);
    const ran1 = await worker();
    const inbox = async (p) => (await read('notifications_my_inbox', p.token))?.items ?? [];
    const mItems1 = await inbox(member);
    const changeItem = mItems1.find((i) => i.reminder_kind === 'cells_meeting_changed');
    const opened = (await rpc('notifications_open_item', member.token, { item_id: changeItem?.item_id })).json;
    check('R30-move-replans-and-delivers-a-change-notice', moved.status === 200 && ran1.exit === 0
      && r3.length === 3 && r3.every((r) => hoursBefore(r.at, moved.data?.starts_at) === 2)
      && changeItem?.title === 'Cell meeting changed' && opened?.state === 'current' && opened?.target === '/my-cell',
      { moved: moved.status, new_time_reminders: r3.length, delivered: ran1.delivered, item: changeItem?.title ?? null,
        open_state: opened?.state ?? null, target: opened?.target ?? null });

    // ------------------------------------------------------------------ cancel: notice, no reminder
    const cancelled = await cells(leader.token, 'cells.cancel_meeting', third.revision, { meeting_id: third.meeting_id });
    await worker();
    const cancelItem = (await inbox(member)).find((i) => i.reminder_kind === 'cells_meeting_cancelled');
    check('R31-cancel-leaves-no-reminder-and-delivers-a-notice', cancelled.status === 200
      && remindersOf(third.meeting_id).length === 0 && cancelItem?.title === 'Cell meeting cancelled',
      { cancelled: cancelled.status, reminders_left: remindersOf(third.meeting_id).length, item: cancelItem?.title ?? null });

    // ------------------------------------------------------------------ snooze, transfer, accountless
    // The member moves to Estates before the first meeting's reminder; then that reminder is due.
    const transferred = await place(mover.member, E);
    psql(`update app.notifications_jobs set scheduled_at = now() - interval '10 seconds'
           where source_type = 'cells_meeting' and source_id = '${first.meeting_id}'
             and reminder_kind = 'cells_meeting_reminder' and job_state = 'pending'`);
    const ran2 = await worker();
    const reminderItem = (await inbox(member)).find((i) => i.reminder_kind === 'cells_meeting_reminder');
    const moverReminder = (await inbox(mover)).find((i) => i.reminder_kind === 'cells_meeting_reminder');
    const snooze = await envelope('notifications_command', member.token, 'notifications.snooze_item', null,
      { item_id: reminderItem?.item_id, choice: '1 hour' });
    psql(`update app.notifications_jobs set scheduled_at = now() - interval '5 seconds'
           where snoozed_from_item_id = '${reminderItem?.item_id}' and job_state = 'pending'`);
    const ran3 = await worker();
    const again = (await inbox(member)).filter((i) => i.reminder_kind === 'cells_meeting_reminder');
    check('R40-snooze-honoured', reminderItem?.title === 'Cell meeting coming up' && snooze.status === 200
      && ran3.delivered === 1 && again.length === 2,
      { item: reminderItem?.title ?? null, snooze: snooze.status, delivered_again: ran3.delivered, items: again.length });
    check('R41-transferred-member-gets-nothing', transferred.status === 200 && !moverReminder,
      { transferred: transferred.status, reminded_after_transfer: Boolean(moverReminder), worker: ran2.exit });

    b = await board();
    const firstNow = (b?.meetings ?? []).find((m) => m.meeting_id === first.meeting_id);
    const tell = (firstNow?.contact_needs ?? []).map((n) => n.display_name);
    const aItems = Number(psql(`select count(*) from app.notifications_inbox_items where recipient_member_id = '${accountless}'`));
    check('R50-accountless-member-to-tell-directly', aItems === 0 && tell.length === 1 && tell[0] === `${NAME_PREFIX} Accountless A`,
      { inbox_items: aItems, tell_directly: tell.length });

    // ------------------------------------------------------------------ payloads
    const allItems = [...await inbox(member), ...await inbox(mover)];
    const jobsText = psql(`select coalesce(string_agg(j::text, ' '), '') from app.notifications_jobs j
                            where j.source_type = 'cells_meeting'`);
    check('R60-no-venue-or-name-in-any-payload', allItems.length > 0
      && containsNone(allItems, [VENUE, ...names]) && containsNone(opened, [VENUE, ...names])
      && containsNone(jobsText, [VENUE, ...names]),
      { items: allItems.length, kinds: [...new Set(allItems.map((i) => i.reminder_kind))].sort() });
  } finally {
    const left = cleanup();
    psql(`select app.sys_revoke_credential('${credentialId}', '${OPERATOR}'); select app.sys_disable_principal('${principal}', '${OPERATOR}');`);
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'cells-meeting-reminders-e2e';
            delete from app.platform_environment_history where set_by = 'cells-meeting-reminders-e2e';`);
    }
    log('R99-cleanup', { users_left: Number(left), unmarked: marked });
  }
  finish();
}

runMain(import.meta.url, main);
