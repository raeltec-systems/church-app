#!/usr/bin/env node
// Story 4.8 end-to-end on the LOCAL stack: duty response deadlines and creator-configured duty
// reminders through real GoTrue phone sign-in (no SMS), the real Data API (PostgREST), the 1.9
// system route and the real worker script (tools/notifications/worker.mjs), proving the ticket's
// verify line:
//   * defaults from the shared 3.3 calculation: a mid-week assignment for Sunday (48 hours), a
//     quarterly rota (14 days for dates a month or more ahead), a same-day assignment (Short
//     notice: one member item, the leaders' short-notice alert, the board's direct-contact flag);
//   * a creator's deadline and reminder offsets (and a malformed list refused);
//   * accept (only the pre-service reminder is left, and it is delivered), decline (nothing left),
//     reassignment A -> B -> A (fresh reminders each time), cancellation (only the notice);
//   * a held and an accountless assignee: no inbox item, both on the leader's Needs contact list;
//   * snooze honoured and stopped by the answer; no quiet-hours deferral (23:30 church time stays);
//   * duties.set_reminders for one date (nobody asked again);
//   * the expected jobs only: no stale reminder after any change, generic text on every item;
//   * (review) a pre-service reminder to a member who has not answered asks for the answer
//     (duty_response_due); a leader granted after a deadline passed gets the overdue alert at the
//     next re-plan (driven by the real clock, no time travel); set_reminders racing accept_many
//     ends consistent with no deadlock.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900670-900679. Evidence is redacted JSONL:
// statuses, codes, counts and hour offsets; never tokens, passwords, numbers, the credential, names
// or duty text. Every user, member, grant, department, duty, job, schedule, item and receipt it
// created is removed; the run's credential is revoked and its principal disabled.
//
// Usage: node tools/identity-e2e/duties-reminders.mjs [--evidence <file.jsonl>]
import { execFile } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 4.8 E2E';
export const DEPARTMENT = 'SYNTHETIC Preaching Rota';

/** The fixed generic texts (title / body) of the duty kinds a member or leader may receive. */
export const GENERIC_TEXT = {
  duty_assigned: ['New duty assigned', 'You have a new duty. Open it to accept or say you cannot make it.'],
  duty_changed: ['Duty changed', 'One of your duties changed. Open it to see what changed and answer again.'],
  duty_released: ['Duty changed', 'A duty you were given has changed and is no longer assigned to you.'],
  duty_cancelled: ['Duty cancelled', 'One of your duties was cancelled. Open My duties to see what is still yours.'],
  duty_updated: ['Duty details updated', 'The details of one of your duties were updated. Open it to read them.'],
  duty_response_due: ['Duty answer needed',
    'One of your duties is waiting for your answer. Open it to accept or say you cannot make it.'],
  duty_starting: ['Duty coming up', 'One of your duties is coming up soon. Open it to see the details.'],
  duty_response_overdue: ['Duty answer overdue',
    'A duty in your department passed its answer-by time without an answer. Open Duties to follow it up.'],
  duty_short_notice: ['Short-notice duty',
    'A duty in your department was given at short notice and needs an answer now. Contact the member directly.'],
};

/** The reserved fictional numbers this run uses (+44 7700 900670-900679). */
export function isFictionalDutyRemindersPhone(phone) {
  return /^\+44770090067[0-9]$/.test(phone);
}

/** Is an inbox item a duty notice or reminder that carries exactly its contract's generic text? */
export function isGenericDutyItem(item) {
  const text = GENERIC_TEXT[item?.reminder_kind];
  return Boolean(text) && item.title === text[0] && item.body === text[1];
}

/** The answer-by default of the Q2 fixture for a duty starting `leadMs` after the assignment. */
export function defaultBeforeStartHours(leadMs) {
  const h = leadMs / 3_600_000;
  if (h >= 30 * 24) return 14 * 24;
  if (h >= 72) return 48;
  return 24;
}

/** "<kind>:<count>" rows sorted, so a summary does not depend on query order. */
export function summarize(rows) {
  return [...rows].sort().join(',');
}

/** An instant at a church-local (Africa/Lusaka, UTC+2, no daylight saving) date and time. */
export function churchInstant(date, hhmm) {
  return new Date(`${date}T${hhmm}:00+02:00`).toISOString();
}

async function main() {
  const { log, check, finish } = startRun();
  const keys = localKey();
  const { origin, key } = keys;
  const http = localHttp(keys);
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const envelope = (fn, token, cmd, expected, payload) =>
    rpc(fn, token, { version: 1, command: cmd, request_id: randomUUID(), expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const duty = (token, cmd, expected, payload) => envelope('duties_command', token, cmd, expected, payload);
  const read = async (fn, token, body = {}) => (await rpc(fn, token, body)).json;
  const HOUR = 3_600_000;
  const DAY = 24 * HOUR;
  const minute = (ms) => new Date(Math.floor((Date.now() + ms) / 60_000) * 60_000).toISOString();
  const churchDate = (ms) => new Date(Date.now() + ms + 2 * HOUR).toISOString().slice(0, 10);

  const people = {
    admin: { phone: '+447700900670', name: `${NAME_PREFIX} Admin` },
    leader: { phone: '+447700900671', name: `${NAME_PREFIX} Leader` },
    deputy: { phone: '+447700900672', name: `${NAME_PREFIX} Deputy` },
    member: { phone: '+447700900673', name: `${NAME_PREFIX} Member M` },
    other: { phone: '+447700900674', name: `${NAME_PREFIX} Member O` },
    held: { phone: '+447700900675', name: `${NAME_PREFIX} Member H` },
  };
  for (const p of Object.values(people)) if (!isFictionalDutyRemindersPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
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
    create temp table gone_occurrences as
      select o.occurrence_id from app.duties_occurrences o where o.department_id in (select department_id from gone_departments);
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
    delete from app.duties_contact_needs n where n.assignment_id in (select assignment_id from gone_assignments);
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
       or g.scope_id in (select department_id from gone_departments);
    delete from app.duties_departments d where d.department_id in (select department_id from gone_departments);
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
    psql(`select app.platform_set_environment('local', 'duties-reminders-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('D00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  const run = randomUUID().slice(0, 8);
  const credential = `sysc_local_${randomBytes(32).toString('base64url')}`;
  const principal = psql(`select app.sys_create_principal('notifications-worker-duties-${run}', 'notifications_worker', '${OPERATOR}')`);
  const credentialId = JSON.parse(psql(`select app.sys_register_credential('${principal}',
    '${createHash('sha256').update(credential).digest('hex')}', 'duties reminders e2e ${run}', interval '2 hours', '${OPERATOR}')`)).credential_id;
  const worker = async () => {
    try {
      const { stdout } = await promisify(execFile)('node', [join(ROOT, 'tools/notifications/worker.mjs'), 'run-once'], {
        encoding: 'utf8',
        env: { PATH: process.env.PATH, SUPABASE_URL: origin, SUPABASE_PUBLISHABLE_KEY: key, NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL: credential } });
      const line = stdout.split('\n').find((l) => l.startsWith('{'));
      return { exit: 0, ...(line ? JSON.parse(line) : {}) };
    } catch (e) {
      return { exit: e.code ?? 1, error: String(e.stderr ?? '').trim().slice(-160) };
    }
  };
  const roleOf = (memberId) => Object.entries(people).find(([, p]) => p.member === memberId)?.[0] ?? 'x';
  // An assignment's pending jobs: "<m|l>:<kind>@<role>:<hours from its deadline | now>".
  const pending = (assignmentId) => summarize(psql(`select coalesce(string_agg(
        case j.source_type when 'duties_assignment' then 'm' else 'l' end || ':' || j.reminder_kind || '@'
        || j.recipient_member_id || ':' || case when abs(extract(epoch from j.scheduled_at - now())) < 120 then 'now'
             else round(extract(epoch from j.scheduled_at - a.response_deadline) / 3600)::text end, ','), '')
      from app.notifications_jobs j join app.duties_assignments a on a.assignment_id = j.source_id
     where j.source_id = '${assignmentId}' and j.job_state = 'pending' and j.snoozed_from_item_id is null`)
    .split(',').filter(Boolean).map((x) => x.replace(/@([0-9a-f-]{36})/, (_, m) => `@${roleOf(m)}`)));
  const dueNow = (assignmentId, kinds) => Number(psql(`with x as (
        select job_id, row_number() over (order by scheduled_at) as rn from app.notifications_jobs
         where source_id = '${assignmentId}' and job_state = 'pending' and snoozed_from_item_id is null
           and reminder_kind in (${kinds.map((k) => `'${k}'`).join(',')})),
      u as (update app.notifications_jobs j set scheduled_at = now() - make_interval(secs => x.rn)
              from x where j.job_id = x.job_id returning 1)
      select count(*) from u`));
  const row = (assignmentId) => JSON.parse(psql(`select json_build_object('deadline_source', deadline_source,
      'short_notice', short_notice, 'revision', revision, 'response', response,
      'before_start_h', round(extract(epoch from (select coalesce(o.reporting_at, o.starts_at) from app.duties_slots s
         join app.duties_occurrences o on o.occurrence_id = s.occurrence_id where s.slot_id = a.slot_id) - a.response_deadline) / 3600),
      'deadline_vs_assigned_s', round(extract(epoch from a.response_deadline - a.assigned_at)))
      from app.duties_assignments a where assignment_id = '${assignmentId}'`));
  const inbox = async (p) => (await read('notifications_my_inbox', p.token))?.items ?? [];
  const openItem = async (p, itemId) => (await rpc('notifications_open_item', p.token, { item_id: itemId })).json;
  const boardAssignment = async (p, assignmentId) => {
    const b = await read('duties_leader_board', p.token);
    for (const d of b?.departments ?? []) for (const du of d.duties ?? []) for (const pos of du.positions ?? []) {
      if (pos.assignment?.assignment_id === assignmentId) return pos.assignment;
    }
    return null;
  };
  const occRevision = (occurrenceId) => Number(psql(`select revision from app.duties_occurrences where occurrence_id = '${occurrenceId}'`));
  const asgRevision = (assignmentId) => Number(psql(`select revision from app.duties_assignments where assignment_id = '${assignmentId}'`));

  try {
    const { admin, leader, deputy, member, other, held } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'duties-reminders-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    const accountless = { member: psql(`insert into app.identity_members (display_name, membership_state, is_synthetic)
      values ('${NAME_PREFIX} Accountless X', 'approved', true) returning member_id`) };
    people.accountless = accountless;
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    check('D01-members-signed-in-by-phone', [admin, leader, deputy, member, other, held].every((p) => amrMethods(p.token).includes('password')),
      { amr: amrMethods(admin.token) });

    // --------------------------------------------------------- setup: department, leader, deputy
    const dept = await duty(admin.token, 'duties.create_department', null, { name: DEPARTMENT });
    const departmentId = dept.data?.department_id;
    const grantRev = (m) => Number(psql(`select revision from app.identity_grant_sets where member_id = '${m}'`));
    const g1 = await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantRev(leader.member),
      { member_id: leader.member, scope_kind: 'department_leader', scope_id: departmentId });
    const g2 = await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantRev(deputy.member),
      { member_id: deputy.member, scope_kind: 'department_deputy', scope_id: departmentId });
    const added = [];
    for (const p of [member, other, held, accountless]) {
      const rev = Number(psql(`select revision from app.duties_departments where department_id = '${departmentId}'`));
      added.push((await duty(admin.token, 'duties.add_member', rev, { department_id: departmentId, member_id: p.member })).status);
    }
    check('D02-department-leader-deputy-members', dept.status === 200 && g1.status === 200 && g2.status === 200
      && added.every((s) => s === 200), { department: dept.status, grants: [g1.status, g2.status], members_added: added });
    // Leaders re-sign in so their tokens carry the fresh scope.
    for (const p of [leader, deputy]) p.token = (await signIn(p.phone, p.password)).json?.access_token;

    const publish = (p, startsAt, extra = {}) => duty(leader.token, 'duties.publish_duty', null, {
      department_id: departmentId, member_id: p.member, duty_name: 'Sunday preaching', location: 'SYNTHETIC Main hall',
      starts_at: startsAt, ...extra });

    // ------------------------------------------------- mid-week for Sunday: the 48-hour default
    const b = await publish(member, minute(4 * DAY));
    const bId = b.data?.assignment_id;
    const bRow = row(bId);
    const bMine = (await read('duties_my_duties', member.token))?.assignments?.find((x) => x.assignment_id === bId);
    check('D10-mid-week-48-hour-default', b.status === 200 && bRow.deadline_source === 'default' && !bRow.short_notice
      && bRow.before_start_h === 48 && bMine?.deadline_source === 'default' && bMine?.short_notice === false
      && pending(bId) === summarize(['m:duty_assigned@member:now', 'm:duty_response_due@member:-24', 'm:duty_response_due@member:0',
        'm:duty_response_due@member:24', 'l:duty_response_overdue@leader:0', 'l:duty_response_overdue@deputy:0']),
      { published: b.status, row: bRow, pending: pending(bId) });

    // ------------------------------------------------- a quarterly rota: 14 days a month ahead
    const series = await duty(leader.token, 'duties.create_series', null, {
      department_id: departmentId, duty_name: 'Sunday service', every: 'week',
      from_date: churchDate(5 * DAY), until_date: churchDate(5 * DAY + 84 * DAY), start_time: '10:00', positions: ['Preacher'] });
    const seriesId = series.data?.series_id;
    const dates = psql(`select string_agg(o.occurrence_id || '/' || s.slot_id, ',' order by o.series_date)
      from app.duties_occurrences o join app.duties_slots s on s.occurrence_id = o.occurrence_id where o.series_id = '${seriesId}'`)
      .split(',').map((x) => x.split('/'));
    const planned = [];
    for (const k of [0, dates.length - 1]) {
      const [occ, slot] = dates[k];
      planned.push((await duty(leader.token, 'duties.assign_slot', occRevision(occ), { slot_id: slot, member_id: member.member })).status);
    }
    const sRev = Number(psql(`select revision from app.duties_series where series_id = '${seriesId}'`));
    const pub = await duty(leader.token, 'duties.publish_drafts', sRev, { series_id: seriesId, slot_count: dates.length });
    const firstA = psql(`select assignment_id from app.duties_assignments where slot_id = '${dates[0][1]}' and assignment_state = 'current'`);
    const lastA = psql(`select assignment_id from app.duties_assignments where slot_id = '${dates[dates.length - 1][1]}' and assignment_state = 'current'`);
    check('D11-quarterly-rota-14-day-default', series.status === 200 && planned.every((s) => s === 200) && pub.status === 200
      && pub.data?.assignments === 2 && row(lastA).before_start_h === 14 * 24 && row(lastA).deadline_source === 'default'
      && row(firstA).before_start_h === 48,
      { dates: dates.length, published: pub.status, assignments: pub.data?.assignments,
        first_before_start_h: row(firstA).before_start_h, last_before_start_h: row(lastA).before_start_h });

    // ------------------------------------------------- the same day: Short notice
    const c = await publish(other, minute(6 * HOUR));
    const cId = c.data?.assignment_id;
    const cRow = row(cId);
    const cPending = pending(cId);
    const cBoard = await boardAssignment(leader, cId);
    const cMine = (await read('duties_my_duties', other.token))?.assignments?.find((x) => x.assignment_id === cId);
    const runC = await worker();
    const oItems = (await inbox(other)).filter((i) => i.reminder_kind?.startsWith('duty_'));
    const lItems = (await inbox(leader)).filter((i) => i.reminder_kind === 'duty_short_notice');
    const lOpen = lItems[0] ? await openItem(leader, lItems[0].item_id) : null;
    check('D12-same-day-short-notice', c.status === 200 && cRow.short_notice && cRow.deadline_vs_assigned_s === 0
      && cPending === summarize(['m:duty_assigned@other:now', 'l:duty_short_notice@leader:now', 'l:duty_short_notice@deputy:now'])
      && cMine?.short_notice === true && (cBoard?.needs_contact?.reasons ?? []).includes('short_notice')
      && runC.exit === 0 && oItems.length === 1 && lItems.length === 1 && lOpen?.state === 'current'
      && lOpen?.target === '/duties/leader' && isGenericDutyItem(lOpen),
      { row: cRow, pending: cPending, member_items: oItems.length, leader_items: lItems.length,
        board_reasons: cBoard?.needs_contact?.reasons ?? null, leader_open: lOpen?.state, leader_target: lOpen?.target });

    // ------------------------------------------------- a creator's deadline and offsets
    const startD = minute(20 * DAY);
    const d = await publish(member, startD, {
      response_deadline: new Date(Date.parse(startD) - 3 * DAY).toISOString(),
      reminders: [{ anchor: 'response_deadline', before: '2 days' }, { anchor: 'starts_at', before: '2 hours' }] });
    const dId = d.data?.assignment_id;
    const bad = await publish(member, minute(21 * DAY), { reminders: [{ anchor: 'deadline', before: '1 day' }] });
    check('D20-creator-deadline-and-offsets', d.status === 200 && row(dId).deadline_source === 'creator'
      && pending(dId) === summarize(['m:duty_assigned@member:now', 'm:duty_response_due@member:-48', 'm:duty_response_due@member:70',
        'l:duty_response_overdue@leader:0', 'l:duty_response_overdue@deputy:0'])
      && bad.code === 'validation_failed' && bad.field_errors?.reminders === 'invalid',
      { published: d.status, pending: pending(dId), malformed: bad.field_errors?.reminders ?? null });

    // ------------------------------------------------- accept: the pre-service reminder stays
    const acc = await duty(member.token, 'duties.respond', asgRevision(dId), { assignment_id: dId, response: 'accepted' });
    const afterAccept = pending(dId);
    const madeDue = dueNow(dId, ['duty_starting']);
    const runD = await worker();
    const starting = (await inbox(member)).filter((i) => i.reminder_kind === 'duty_starting');
    check('D30-accept-keeps-only-the-pre-service-reminder', acc.status === 200
      && afterAccept === 'm:duty_starting@member:70' && madeDue === 1 && runD.exit === 0 && starting.length === 1
      && isGenericDutyItem(starting[0]),
      { accepted: acc.status, pending: afterAccept, starting_items: starting.length });

    // ------------------------------------------------- decline: nothing left
    const dec = await duty(member.token, 'duties.respond', asgRevision(bId), { assignment_id: bId, response: 'declined' });
    check('D31-decline-stops-everything', dec.status === 200 && pending(bId) === '',
      { declined: dec.status, pending: pending(bId) });

    // ------------------------------------------------- reassign A -> B -> A
    const r = await publish(member, minute(10 * DAY));
    const rOcc = r.data?.occurrence_id;
    const chain = [r.data?.assignment_id];
    for (const p of [other, member]) {
      const rv = await duty(leader.token, 'duties.revise_duty', occRevision(rOcc), { occurrence_id: rOcc, member_id: p.member });
      chain.push(rv.data?.assignment_id);
    }
    const full = (who) => summarize([`m:duty_assigned@${who}:now`, `m:duty_response_due@${who}:-24`, `m:duty_response_due@${who}:0`,
      `m:duty_response_due@${who}:24`, 'l:duty_response_overdue@leader:0', 'l:duty_response_overdue@deputy:0']);
    check('D40-reassign-back-gets-fresh-reminders', new Set(chain).size === 3
      && pending(chain[0]) === 'm:duty_released@member:now' && pending(chain[1]) === 'm:duty_released@other:now'
      && pending(chain[2]) === full('member'),
      { assignments: new Set(chain).size, first: pending(chain[0]), second: pending(chain[1]), back: pending(chain[2]) });

    // ------------------------------------------------- cancel a rota date
    const [cancelOcc] = dates[dates.length - 1];
    const can = await duty(leader.token, 'duties.cancel_occurrence', occRevision(cancelOcc), { occurrence_id: cancelOcc });
    check('D41-cancel-leaves-only-the-cancellation-notice', can.status === 200 && pending(lastA) === 'm:duty_cancelled@member:now',
      { cancelled: can.status, pending: pending(lastA) });

    // ------------------------------------------------- held and accountless: Needs contact
    const x = await publish(accountless, minute(9 * DAY));
    const h = await publish(held, minute(9 * DAY + 2 * HOUR));
    const memberRev = Number(psql(`select revision from app.identity_members where member_id = '${held.member}'`));
    const hold = await envelope('identity_credential_command', admin.token, 'identity.place_hold', memberRev,
      { member_id: held.member, reason_code: 'security_concern' });
    const runH = await worker();
    const needs = Number(psql(`select count(*) from app.duties_contact_needs where assignment_id in ('${x.data?.assignment_id}', '${h.data?.assignment_id}')`));
    const xBoard = await boardAssignment(leader, x.data?.assignment_id);
    const hBoard = await boardAssignment(deputy, h.data?.assignment_id);
    const heldItems = Number(psql(`select count(*) from app.notifications_inbox_items where recipient_member_id in ('${held.member}', '${accountless.member}')`));
    check('D50-held-and-accountless-reach-needs-contact', x.status === 200 && h.status === 200 && hold.status === 200
      && runH.exit === 0 && needs === 2 && heldItems === 0
      && (xBoard?.needs_contact?.reasons ?? []).join() === 'not_reached'
      && (hBoard?.needs_contact?.reasons ?? []).join() === 'not_reached',
      { hold: hold.status, needs, inbox_items: heldItems, accountless: xBoard?.needs_contact?.reasons ?? null,
        held: hBoard?.needs_contact?.reasons ?? null });

    // ------------------------------------------------- snooze: honoured, stopped by the answer
    const s = await publish(member, minute(8 * DAY));
    const sId = s.data?.assignment_id;
    const madeS = dueNow(sId, ['duty_response_due']);
    await worker();
    const due = (await inbox(member)).filter((i) => i.reminder_kind === 'duty_response_due');
    const snooze = await envelope('notifications_command', member.token, 'notifications.snooze_item', null,
      { item_id: due[0]?.item_id, choice: '1 hour' });
    const snoozedAt = Number(psql(`select round(extract(epoch from scheduled_at - now()) / 60) from app.notifications_jobs
      where snoozed_from_item_id = '${due[0]?.item_id}' and job_state = 'pending'`));
    psql(`update app.notifications_jobs set scheduled_at = now() - interval '30 seconds'
      where snoozed_from_item_id = '${due[0]?.item_id}' and job_state = 'pending'`);
    const runS = await worker();
    const again = (await inbox(member)).filter((i) => i.reminder_kind === 'duty_response_due');
    const later = await envelope('notifications_command', member.token, 'notifications.snooze_item', null,
      { item_id: again[0]?.item_id, choice: '2 days' });
    const ans = await duty(member.token, 'duties.respond', asgRevision(sId), { assignment_id: sId, response: 'accepted' });
    const stopped = psql(`select coalesce(string_agg(job_state || ':' || coalesce(cancel_reason, '-'), ','), '')
      from app.notifications_jobs where snoozed_from_item_id = '${again[0]?.item_id}'`);
    // Three asks to answer while pending: 24 hours before and at the deadline, and 24 hours before
    // the start (a pre-service reminder asks for the answer while none is given).
    check('D60-snooze-honoured-and-stopped-by-the-answer', madeS === 3 && due.length === 3 && snooze.status === 200
      && snoozedAt >= 59 && snoozedAt <= 61 && runS.delivered === 1 && again.length === 4 && later.status === 200
      && ans.status === 200 && stopped === 'cancelled:responded',
      { made_due: madeS, items: [due.length, again.length], snooze: snooze.status, minutes: snoozedAt,
        delivered_again: runS.delivered, second_snooze: later.status, after_answer: stopped });

    // ------------------------------------------------- no quiet hours: 23:30 church time stays
    const lateDate = churchDate(12 * DAY);
    const q = await publish(other, churchInstant(churchDate(13 * DAY), '09:00'), {
      response_deadline: churchInstant(lateDate, '23:30'), reminders: [{ anchor: 'response_deadline', before: '0 minutes' }] });
    const lateAt = psql(`select to_char(scheduled_at at time zone 'Africa/Lusaka', 'HH24:MI') from app.notifications_jobs
      where source_id = '${q.data?.assignment_id}' and reminder_kind = 'duty_response_due'`);
    check('D70-no-quiet-hours-deferral', q.status === 200 && lateAt === '23:30', { published: q.status, local_time: lateAt });

    // ------------------------------------------------- set_reminders for one date
    const n = await publish(other, minute(15 * DAY));
    const nOcc = n.data?.occurrence_id;
    const set = await duty(leader.token, 'duties.set_reminders', occRevision(nOcc), { occurrence_id: nOcc, reminders: [] });
    const unchanged = await duty(leader.token, 'duties.set_reminders', occRevision(nOcc), { occurrence_id: nOcc, reminders: [] });
    const asMember = await duty(other.token, 'duties.set_reminders', occRevision(nOcc), { occurrence_id: nOcc, reminders: null });
    check('D80-set-reminders-for-one-date', set.status === 200 && set.data?.replanned === 1
      && pending(n.data?.assignment_id) === summarize(['m:duty_assigned@other:now', 'l:duty_response_overdue@leader:0',
        'l:duty_response_overdue@deputy:0'])
      && asgRevision(n.data?.assignment_id) === 1 && unchanged.field_errors?.occurrence_id === 'unchanged'
      && asMember.code === 'forbidden',
      { set: set.status, replanned: set.data?.replanned, pending: pending(n.data?.assignment_id),
        unchanged: unchanged.field_errors?.occurrence_id ?? null, member: asMember.code ?? asMember.status });

    // ------------------------------------------------- review: set_reminders racing accept_many
    const raceRounds = [];
    for (let round = 0; round < 3; round += 1) {
      const pr = await publish(member, minute((30 + round) * DAY));
      const prId = pr.data?.assignment_id;
      const prOcc = pr.data?.occurrence_id;
      const [setR, accR] = await Promise.all([
        duty(leader.token, 'duties.set_reminders', occRevision(prOcc),
          { occurrence_id: prOcc, reminders: [{ anchor: 'starts_at', before: '3 hours' }] }),
        duty(member.token, 'duties.accept_many', null,
          { assignments: [{ assignment_id: prId, revision: asgRevision(prId) }] }),
      ]);
      const hoursFromDeadline = row(prId).before_start_h - 3;
      raceRounds.push({ set: setR.status, accept: accR.status, response: row(prId).response,
        pending: pending(prId), expected: `m:duty_starting@member:${hoursFromDeadline}` });
    }
    check('D82-set-reminders-racing-accept-many-is-consistent', raceRounds.every((x) => x.set === 200 && x.accept === 200
      && x.response === 'accepted' && x.pending === x.expected),
      { rounds: raceRounds.map(({ set, accept, response, pending: pend }) => ({ set, accept, response, pending: pend })) });

    // ------------------------------------------------- review S1: a leader granted after the deadline
    // A creator deadline 75 seconds ahead passes on the real clock; then Member M becomes a deputy
    // and a re-plan (set_reminders) gives them the overdue alert now. The leaders who already had
    // one keep exactly one.
    const lateDeadline = new Date(Math.ceil((Date.now() + 75_000) / 1000) * 1000);
    const lt = await publish(other, minute(11 * DAY), { response_deadline: lateDeadline.toISOString() });
    const ltId = lt.data?.assignment_id;
    const ltOcc = lt.data?.occurrence_id;
    while (Date.now() < lateDeadline.getTime() + 2_000) await new Promise((res) => setTimeout(res, 1_000));
    const g3 = await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantRev(member.member),
      { member_id: member.member, scope_kind: 'department_deputy', scope_id: departmentId });
    const ltSet = await duty(leader.token, 'duties.set_reminders', occRevision(ltOcc), { occurrence_id: ltOcc, reminders: [] });
    const alerts = psql(`select coalesce(string_agg(recipient_member_id || ':' || job_state, ',' order by recipient_member_id), '')
      from app.notifications_jobs where source_id = '${ltId}' and reminder_kind = 'duty_response_overdue'`)
      .split(',').filter(Boolean).map((x) => x.replace(/^([0-9a-f-]{36})/, (_, m) => roleOf(m))).sort().join(',');
    const runL = await worker();
    const newItems = (await inbox(member)).filter((i) => i.reminder_kind === 'duty_response_overdue');
    const newOpen = newItems[0] ? await openItem(member, newItems[0].item_id) : null;
    check('D85-leader-granted-after-the-deadline-is-alerted', lt.status === 200 && g3.status === 200 && ltSet.status === 200
      && g3.code == null && row(ltId).short_notice === false && alerts === 'deputy:pending,leader:pending,member:pending'
      && runL.exit === 0 && newItems.length === 1 && newOpen?.target === '/duties/leader' && isGenericDutyItem(newOpen),
      { published: lt.status, grant: g3.status, grant_code: g3.code ?? null, set: ltSet.status, alerts,
        new_deputy_items: newItems.length, new_deputy_target: newOpen?.target ?? null });

    // ------------------------------------------------- the expected jobs only; generic text
    const stale = Number(psql(`select count(*) from app.notifications_jobs j join app.duties_assignments a on a.assignment_id = j.source_id
      where j.job_state = 'pending'
        and j.reminder_kind in ('duty_response_due', 'duty_starting', 'duty_response_overdue', 'duty_short_notice')
        and (a.assignment_state <> 'current' or j.source_revision <> a.revision or a.response = 'declined'
             or (j.reminder_kind <> 'duty_starting' and a.response <> 'pending')
             or (j.reminder_kind = 'duty_starting' and a.response = 'pending'))`));
    const items = [];
    for (const p of [member, other, leader, deputy]) items.push(...(await inbox(p)).filter((i) => i.reminder_kind?.startsWith('duty_')));
    const tableQuery = await http('GET', '/rest/v1/duties_contact_needs?select=*', { token: leader.token, profile: 'app' });
    check('D90-no-stale-reminder-and-generic-text-only', stale === 0 && items.length > 0 && items.every(isGenericDutyItem)
      && !JSON.stringify(items).includes('SYNTHETIC') && tableQuery.status >= 400,
      { stale, items: items.length, all_generic: items.every(isGenericDutyItem), needs_table_query: tableQuery.status });
  } finally {
    const left = cleanup();
    psql(`select app.sys_revoke_credential('${credentialId}', '${OPERATOR}'); select app.sys_disable_principal('${principal}', '${OPERATOR}');`);
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'duties-reminders-e2e';
            delete from app.platform_environment_history where set_by = 'duties-reminders-e2e';`);
    }
    log('D99-cleanup', { users_left: Number(left), credential_revoked: true, principal_disabled: true, unmarked: marked,
      departments_left: Number(psql(`select count(*) from app.duties_departments where name = '${DEPARTMENT}'`)) });
  }
  finish();
}

runMain(import.meta.url, main);
