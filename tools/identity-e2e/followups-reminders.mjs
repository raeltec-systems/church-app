#!/usr/bin/env node
// Story 4.7 end-to-end on the LOCAL stack: follow-up task reminders through real GoTrue phone
// sign-in (no SMS), the real Data API (PostgREST), the 1.9 system route and the real worker script
// (tools/notifications/worker.mjs), proving the ticket's verify with the SYNTHETIC source
// `fixture_followup`:
//   * a leader assigns a task: one worker run delivers the owner's assignment notice, which opens
//     current with the deep link /followups/tasks/<id> and generic text only; a second run
//     delivers nothing (one item per logical key);
//   * a missed deadline: the owner's due reminder and exactly ONE supervisor alert; re-planning
//     never adds a second alert; the owner snoozes the reminder;
//   * Waiting with a review date: the change is recorded in the activity, the original due date
//     stays, the reminders move to the review date and the old snooze is cancelled;
//   * reassignment: the old owner has nothing pending and their old notice opens out of date; the
//     new owner gets the assignment notice;
//   * Done and Closed: nothing is pending and the worker sends nothing more;
//   * creator-configured reminders, and a registered SYNTHETIC source-specific schedule (purpose
//     synthetic_report_due, opened through the owner operation as a source would) used instead of
//     the generic one;
//   * owner decision Q4: a Pastor outside the group may own a task (owner rights only), a
//     non-Pastor outsider is refused;
//   * every follow-up inbox item carries fixed generic text, never task content.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900370-900379. Evidence is redacted JSONL:
// statuses, codes, counts; never tokens, passwords, numbers, the credential or task text. Every
// user, member, grant, department, task, job, item and receipt it created is removed; the run's
// credential is revoked and its principal disabled.
//
// Usage: node tools/identity-e2e/followups-reminders.mjs [--evidence <file.jsonl>]
import { execFile } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 4.7 E2E';
export const DEPARTMENT = 'SYNTHETIC Preaching Rota';
export const SOURCE_TYPE = 'fixture_followup';
export const PURPOSE = 'synthetic_check_in';
export const REPORT_PURPOSE = 'synthetic_report_due';

/** The fixed generic reminder texts (title / body) of the Follow-ups contracts. */
export const GENERIC_TEXT = {
  followup_assigned: ['New follow-up task', 'A follow-up task was assigned to you. Open it to see the next action.'],
  followup_due: ['Follow-up task due', 'A follow-up task is due. Open it to record progress or set a review date.'],
  followup_overdue: ['Follow-up task overdue', 'A follow-up task you supervise is overdue. Open it to follow up with its owner.'],
};

/** The reserved fictional numbers this run uses (+44 7700 900370-900379). */
export function isFictionalRemindersPhone(phone) {
  return /^\+44770090037[0-9]$/.test(phone);
}

/** The deep link a follow-up reminder opens. */
export function taskLink(taskId) {
  return `/followups/tasks/${taskId}`;
}

/** Is an inbox item a follow-up reminder that carries exactly its contract's generic text? */
export function isGenericFollowupItem(item) {
  const text = GENERIC_TEXT[item?.reminder_kind];
  return Boolean(text) && item.title === text[0] && item.body === text[1];
}

/** "<kind>:<count>" for the pending jobs summary, sorted. */
export function summarize(rows) {
  return [...rows].sort().join(',');
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
  const fu = (token, cmd, expected, payload) => envelope('followups_command', token, cmd, expected, payload);
  const read = async (fn, token, body = {}) => {
    const r = await rpc(fn, token, body);
    return { status: r.status, json: r.json, detail: r.json?.details ?? null };
  };
  const at = (ms) => new Date(Date.now() + ms).toISOString();
  const DAY = 86_400_000;

  const people = {
    admin: { phone: '+447700900370', name: `${NAME_PREFIX} Admin` },
    leader: { phone: '+447700900371', name: `${NAME_PREFIX} Leader` },
    member: { phone: '+447700900372', name: `${NAME_PREFIX} Member M` },
    other: { phone: '+447700900373', name: `${NAME_PREFIX} Member O` },
    pastor: { phone: '+447700900374', name: `${NAME_PREFIX} Pastor` },
    plain: { phone: '+447700900375', name: `${NAME_PREFIX} Outsider` },
  };
  for (const p of Object.values(people)) if (!isFictionalRemindersPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
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
    create temp table gone_tasks as
      select t.task_id from app.followups_tasks t
       where t.scope_id in (select department_id from gone_departments)
          or t.owner_member_id in (select member_id from gone_members);
    create temp table gone_jobs as
      select j.job_id from app.notifications_jobs j
       where j.recipient_member_id in (select member_id from gone_members)
          or j.source_id in (select task_id from gone_tasks);
    delete from app.notifications_push_jobs p where p.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_attempts a where a.job_id in (select job_id from gone_jobs);
    delete from app.notifications_direct_contact_needs n where n.job_id in (select job_id from gone_jobs);
    update app.notifications_jobs j set snoozed_from_item_id = null where j.job_id in (select job_id from gone_jobs);
    delete from app.notifications_inbox_items i where i.job_id in (select job_id from gone_jobs)
       or i.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_jobs j where j.job_id in (select job_id from gone_jobs);
    delete from app.notifications_schedules s where s.source_id in (select task_id from gone_tasks)
       or s.recipient_member_id in (select member_id from gone_members);
    delete from app.followups_notes n where n.task_id in (select task_id from gone_tasks);
    delete from app.followups_activity a where a.task_id in (select task_id from gone_tasks);
    delete from app.followups_tasks t where t.task_id in (select task_id from gone_tasks);
    delete from app.duties_audit a where a.department_id in (select department_id from gone_departments)
       or a.actor_member_id in (select member_id from gone_members);
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
    psql(`select app.platform_set_environment('local', 'followups-reminders-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('R00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  // The run's worker principal and credential (only the digest is registered).
  const run = randomUUID().slice(0, 8);
  const credential = `sysc_local_${randomBytes(32).toString('base64url')}`;
  const principal = psql(`select app.sys_create_principal('notifications-worker-followups-${run}', 'notifications_worker', '${OPERATOR}')`);
  const credentialId = JSON.parse(psql(`select app.sys_register_credential('${principal}',
    '${createHash('sha256').update(credential).digest('hex')}', 'followups reminders e2e ${run}', interval '2 hours', '${OPERATOR}')`)).credential_id;
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
  // The task's pending jobs as "<kind>@<recipient>" (recipient by role name).
  const roleOf = (memberId) => Object.entries(people).find(([, p]) => p.member === memberId)?.[0] ?? 'other_member';
  const pending = (taskId) => summarize(psql(`select coalesce(string_agg(reminder_kind || '@' || recipient_member_id, ','), '')
      from app.notifications_jobs where source_id = '${taskId}' and job_state = 'pending' and snoozed_from_item_id is null`)
    .split(',').filter(Boolean).map((x) => { const [k, m] = x.split('@'); return `${k}@${roleOf(m)}`; }));
  const cancelReasons = (taskId) => psql(`select coalesce(string_agg(distinct cancel_reason, ',' order by cancel_reason), '')
      from app.notifications_jobs where source_id = '${taskId}' and job_state = 'cancelled'`);
  // Moves the task's pending jobs of these kinds into the past (staggered: one logical key each).
  const dueNow = (taskId, kinds) => Number(psql(`with x as (
        select job_id, row_number() over (order by scheduled_at) as rn from app.notifications_jobs
         where source_id = '${taskId}' and job_state = 'pending' and reminder_kind in (${kinds.map((k) => `'${k}'`).join(',')})),
      u as (update app.notifications_jobs j set scheduled_at = now() - make_interval(secs => x.rn)
              from x where j.job_id = x.job_id returning 1)
      select count(*) from u`));
  const inbox = async (p) => (await read('notifications_my_inbox', p.token)).json?.items ?? [];
  const openItem = async (p, itemId) => (await rpc('notifications_open_item', p.token, { item_id: itemId })).json;
  const taskRead = async (p, taskId) => (await read('followups_task', p.token, { p_task_id: taskId })).json;

  try {
    const { admin, leader, member, other, pastor, plain } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'followups-reminders-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    psql(`insert into app.identity_grants (member_id, role, granted_by_operator) values ('${pastor.member}', 'pastor', '${OPERATOR}')`);
    check('R01-members-signed-in-by-phone', Object.values(people).every((p) => amrMethods(p.token).includes('password')),
      { amr: amrMethods(admin.token) });

    // --------------------------------------------------------- setup: department and leader scope
    const dept = await envelope('duties_command', admin.token, 'duties.create_department', null, { name: DEPARTMENT });
    const departmentId = dept.data?.department_id;
    const overview = (await read('duties_admin_overview', admin.token)).json;
    const grantsRev = overview?.members?.find((m) => m.member_id === leader.member)?.grants_revision;
    const grant = await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantsRev,
      { member_id: leader.member, scope_kind: 'department_leader', scope_id: departmentId });
    const added = [];
    for (const [i, id] of [member.member, other.member].entries()) {
      added.push((await envelope('duties_command', admin.token, 'duties.add_member', i + 1,
        { department_id: departmentId, member_id: id })).status);
    }
    check('R02-department-and-leader', dept.status === 200 && grant.status === 200 && added.every((s) => s === 200),
      { department: dept.status, grant: grant.status, members_added: added });

    const draft = (owner, extra = {}) => ({
      source_type: SOURCE_TYPE, source_id: randomUUID(), source_revision: 1, purpose: PURPOSE,
      owner_member_id: owner, scope_kind: 'department_leader', scope_id: departmentId,
      next_action: 'SYNTHETIC: phone and check in', due_at: at(3 * DAY), ...extra,
    });
    const update = (token, id, revision, payload) => fu(token, 'followups.update_task', revision, { task_id: id, ...payload });

    // ------------------------------------------------------------- assignment: one notice per key
    const a = await fu(leader.token, 'followups.create_task', null, draft(member.member));
    const ta = a.data?.task_id;
    const afterCreate = pending(ta);
    const first = await worker();
    const second = await worker();
    const mItems = (await inbox(member)).filter((i) => i.reminder_kind === 'followup_assigned');
    const opened = mItems[0] ? await openItem(member, mItems[0].item_id) : null;
    check('R10-assignment-notice-delivered-once-with-the-deep-link', a.status === 200
      && afterCreate === 'followup_assigned@member,followup_due@member,followup_overdue@leader'
      && first.exit === 0 && first.delivered === 1 && second.delivered === 0 && mItems.length === 1
      && opened?.state === 'current' && opened?.target === taskLink(ta) && isGenericFollowupItem(opened),
      { created: a.status, pending: afterCreate, runs: [first.delivered, second.delivered], items: mItems.length,
        state: opened?.state, target_is_task: opened?.target === taskLink(ta), generic: isGenericFollowupItem(opened) });

    // ---------------------------------------------------- a missed deadline: one supervisor alert
    psql(`update app.followups_tasks set due_at = now() - interval '25 hours' where task_id = '${ta}'`);
    const madeDue = dueNow(ta, ['followup_due', 'followup_overdue']);
    const missed = await worker();
    const again = await worker();
    const replan = await update(member.token, ta, 1, { status: 'in_progress' });
    const alerts = Number(psql(`select count(*) from app.notifications_jobs where source_id = '${ta}' and reminder_kind = 'followup_overdue'`));
    const afterReplan = await worker();
    const leaderAlerts = (await inbox(leader)).filter((i) => i.reminder_kind === 'followup_overdue');
    const dueItem = (await inbox(member)).find((i) => i.reminder_kind === 'followup_due');
    check('R20-missed-deadline-one-supervisor-alert', madeDue === 2 && missed.delivered === 2 && again.delivered === 0
      && replan.status === 200 && alerts === 1 && afterReplan.delivered === 0 && leaderAlerts.length === 1
      && Boolean(dueItem) && isGenericFollowupItem(leaderAlerts[0]),
      { made_due: madeDue, runs: [missed.delivered, again.delivered, afterReplan.delivered], alert_jobs: alerts,
        supervisor_items: leaderAlerts.length, owner_due_item: Boolean(dueItem) });
    const snooze = await envelope('notifications_command', member.token, 'notifications.snooze_item', null,
      { item_id: dueItem?.item_id, choice: '1 hour' });
    check('R21-owner-snoozes-the-reminder', snooze.status === 200 && Boolean(snooze.data?.scheduled_at),
      { status: snooze.status, code: snooze.code ?? null });

    // ---------------------------------------------------- Waiting: recorded, reminders move
    const w1 = await update(member.token, ta, replan.revision, { status: 'waiting', review_at: at(2 * DAY) });
    const w2 = await update(member.token, ta, w1.revision, { review_at: at(4 * DAY) });
    const detail = await taskRead(member, ta);
    const recorded = (detail?.activity ?? []).filter((e) => e.review_at);
    const rows = psql(`select (j.scheduled_at = t.review_at)::text || ':' || j.reminder_kind from app.notifications_jobs j
      join app.followups_tasks t on t.task_id = j.source_id where j.source_id = '${ta}' and j.job_state = 'pending'
      and j.snoozed_from_item_id is null order by j.reminder_kind`).split('\n');
    const oldReminder = await openItem(member, dueItem?.item_id);
    check('R30-review-date-change-recorded-and-reminders-moved', w1.status === 200 && w2.status === 200
      && recorded.map((e) => e.action).join(',') === 'status_changed,review_date_set'
      && detail?.task?.due_at && detail.task.review_at > detail.task.due_at
      && pending(ta) === 'followup_due@member,followup_overdue@leader' && rows[0] === 'true:followup_due'
      && cancelReasons(ta).includes('source_revised') && oldReminder?.state === 'superseded',
      { states: [w1.data?.state, w2.data?.state], recorded: recorded.map((e) => e.action), pending: pending(ta),
        due_at_review: rows[0], cancelled: cancelReasons(ta), old_reminder: oldReminder?.state });

    // ---------------------------------------------------- reassignment
    const re = await fu(leader.token, 'followups.reassign', w2.revision, { task_id: ta, owner_member_id: other.member });
    const afterReassign = pending(ta);
    const reRun = await worker();
    const oItems = (await inbox(other)).filter((i) => i.reminder_kind === 'followup_assigned');
    const mOld = await openItem(member, mItems[0]?.item_id);
    check('R40-reassignment-moves-reminders-to-the-new-owner', re.status === 200
      && afterReassign === 'followup_assigned@other,followup_due@other,followup_overdue@leader'
      && cancelReasons(ta).includes('reassigned') && reRun.delivered === 1 && oItems.length === 1
      && mOld?.state === 'superseded',
      { reassigned: re.status, pending: afterReassign, cancelled: cancelReasons(ta), delivered: reRun.delivered,
        new_owner_items: oItems.length, old_owner_notice: mOld?.state });

    // ---------------------------------------------------- Done and Closed
    const done = await update(other.token, ta, re.revision, { status: 'done' });
    const b = await fu(leader.token, 'followups.create_task', null, draft(member.member));
    const closed = await update(member.token, b.data?.task_id, 1, { status: 'closed', close_reason: 'SYNTHETIC: no longer needed' });
    const afterClose = await worker();
    check('R50-nothing-after-done-or-closed', done.data?.state === 'done' && closed.data?.state === 'closed'
      && pending(ta) === '' && pending(b.data?.task_id) === '' && cancelReasons(ta).includes('task_done')
      && cancelReasons(b.data?.task_id) === 'task_closed' && afterClose.delivered === 0,
      { states: [done.data?.state, closed.data?.state], pending: [pending(ta), pending(b.data?.task_id)],
        delivered: afterClose.delivered });

    // ---------------------------------------------------- creator reminders
    const c = await fu(leader.token, 'followups.create_task', null, draft(member.member, {
      reminders: [{ anchor: 'deadline', before: '24 hours' }, { anchor: 'deadline', before: '0 minutes' }] }));
    const cDetail = await taskRead(leader, c.data?.task_id);
    const cDue = Number(psql(`select count(*) from app.notifications_jobs where source_id = '${c.data?.task_id}' and reminder_kind = 'followup_due' and job_state = 'pending'`));
    const bad = await fu(leader.token, 'followups.create_task', null, draft(member.member, { reminders: [{ anchor: 'deadline', before: 'soon' }] }));
    check('R60-creator-configured-reminders', c.status === 200 && cDue === 2 && cDetail?.task?.reminders?.schedule === 'custom'
      && bad.code === 'validation_failed' && bad.field_errors?.reminders === 'invalid',
      { created: c.status, owner_due_jobs: cDue, schedule: cDetail?.task?.reminders?.schedule, malformed: bad.field_errors?.reminders ?? null });

    // ---------------------------------------- the registered SYNTHETIC source-specific schedule
    const report = JSON.parse(psql(`select app.followups_open_task(jsonb_build_object(
      'source_type', '${SOURCE_TYPE}', 'source_id', gen_random_uuid(), 'source_revision', 1,
      'purpose', '${REPORT_PURPOSE}', 'owner_member_id', '${member.member}', 'supervisor_member_id', '${leader.member}',
      'scope_kind', 'department_leader', 'scope_id', '${departmentId}', 'next_action', 'SYNTHETIC: submit the report',
      'due_at', app.cmd_utc(now() + interval '1 day'), 'actor_member_id', '${leader.member}', 'actor_account_id', '${leader.user}'))`));
    const tr = report.task_id;
    const reportJobs = psql(`select string_agg(reminder_kind || ':' || round(extract(epoch from j.scheduled_at - t.due_at) / 3600), ','
        order by j.scheduled_at) from app.notifications_jobs j join app.followups_tasks t on t.task_id = j.source_id
       where j.source_id = '${tr}' and j.job_state = 'pending'`);
    const reportDetail = await taskRead(leader, tr);
    const madeReportDue = dueNow(tr, ['followup_due']);
    const reportRun = await worker();
    const reportDelivered = Number(psql(`select count(*) from app.notifications_jobs
      where source_id = '${tr}' and job_state = 'delivered'`));
    const reportOthers = Number(psql(`select count(*) from app.notifications_jobs
      where source_id = '${tr}' and (reminder_kind <> 'followup_due' or recipient_member_id <> '${member.member}')`));
    check('R70-source-specific-schedule-replaces-the-generic-one', reportJobs === 'followup_due:0,followup_due:48'
      && reportDetail?.task?.reminders?.schedule === 'source' && madeReportDue === 2 && reportRun.exit === 0
      && reportDelivered === 2 && reportOthers === 0,
      { pending: reportJobs, schedule: reportDetail?.task?.reminders?.schedule, report_delivered: reportDelivered,
        notice_or_supervisor_jobs: reportOthers });

    // ---------------------------------------------------- owner decision Q4
    const forPastor = await fu(leader.token, 'followups.create_task', null, draft(pastor.member));
    const forPlain = await fu(leader.token, 'followups.create_task', null, draft(plain.member));
    const pastorMine = (await read('followups_my_tasks', pastor.token)).json?.tasks ?? [];
    const pastorOther = await read('followups_task', pastor.token, { p_task_id: c.data?.task_id });
    const pastorSupervision = await read('followups_supervision', pastor.token);
    const roster = ((await read('followups_supervision', leader.token)).json?.scopes ?? [])
      .find((s) => s.scope_id === departmentId)?.candidates?.map((x) => x.member_id) ?? [];
    check('R80-q4-pastor-may-own-outsider-may-not', forPastor.status === 200 && forPlain.field_errors?.owner_member_id === 'not_in_scope'
      && pastorMine.length === 1 && pastorMine[0].capacity === 'owner' && pastorOther.status === 403
      && pastorSupervision.status === 403 && roster.includes(pastor.member) && !roster.includes(plain.member)
      && pending(forPastor.data?.task_id).includes('followup_assigned@pastor'),
      { pastor_owner: forPastor.status, outsider: forPlain.field_errors?.owner_member_id ?? forPlain.status,
        pastor_tasks: pastorMine.length, pastor_other_task: pastorOther.status, pastor_supervision: pastorSupervision.status,
        roster_has_pastor: roster.includes(pastor.member), roster_has_outsider: roster.includes(plain.member) });

    // ---------------------------------------------------- privacy
    const all = [...await inbox(member), ...await inbox(other), ...await inbox(leader)]
      .filter((i) => i.reminder_kind?.startsWith('followup_'));
    const tableQuery = await http('GET', '/rest/v1/followups_reminder_schedules?select=*', { token: member.token, profile: 'app' });
    check('R90-generic-text-only', all.length > 0 && all.every(isGenericFollowupItem)
      && !JSON.stringify(all).includes('SYNTHETIC') && tableQuery.status >= 400,
      { items: all.length, all_generic: all.every(isGenericFollowupItem), registry_query: tableQuery.status });
  } finally {
    const left = cleanup();
    psql(`select app.sys_revoke_credential('${credentialId}', '${OPERATOR}'); select app.sys_disable_principal('${principal}', '${OPERATOR}');`);
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'followups-reminders-e2e';
            delete from app.platform_environment_history where set_by = 'followups-reminders-e2e';`);
    }
    log('R99-cleanup', { users_left: Number(left), credential_revoked: true, principal_disabled: true, unmarked: marked,
      departments_left: Number(psql(`select count(*) from app.duties_departments where name = '${DEPARTMENT}'`)) });
  }
  finish();
}

runMain(import.meta.url, main);
