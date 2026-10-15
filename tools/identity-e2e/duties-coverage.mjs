#!/usr/bin/env node
// Story 4.9 end-to-end on the LOCAL stack: the coverage queue, contact attempts and leader
// confirmation through real GoTrue phone sign-in (no SMS), the real Data API (PostgREST), the 1.9
// system route and the real worker script (tools/notifications/worker.mjs), proving the ticket's
// verify line on a synthetic rota with an unanswered app member (M), an accountless member (X, a
// labelled household number) and a decline (O):
//   * the queue shows each position's state, the counts and (for the department's leader only) the
//     labelled contact route; the decline alerts the leader (generic Duty declined item);
//   * a contact attempt opens a Follow-ups task (owner the leader, due at the next follow-up), a
//     second one sets it Waiting with the new review date;
//   * Confirmed by leader on X by phone, with its reason, labelled as such and kept apart from a
//     member's answer; X's answer reminders and the leaders' alerts stop;
//   * the decline is reassigned: O's assignment is superseded, O's reminders and the decline alert
//     end, O's follow-up task closes with it; M's own acceptance closes M's task;
//   * a leader of another department and an Admin without the scope see nothing private (no
//     route, no note, no reason, no task) and cannot record contact or confirmations;
//   * a position is cancelled (the last one cancels the date); generic text on every item.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900790-900799. Evidence is redacted JSONL:
// statuses, codes, counts and states; never tokens, passwords, numbers, the credential, names,
// notes or reasons. Every user, member, route, grant, department, duty, case, task, job, item and
// receipt it created is removed; the run's credential is revoked and its principal disabled.
//
// Usage: node tools/identity-e2e/duties-coverage.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';
import { genericItemCheck, notificationsWorker, summarize } from './duties-shared.mjs';

export { summarize } from './duties-shared.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 4.9 E2E';
export const DEPARTMENT = 'SYNTHETIC Preaching Rota';
export const OTHER_DEPARTMENT = 'SYNTHETIC 4.9 E2E Ushers';
/** The accountless member's labelled household number (fictional). */
export const HOUSEHOLD_PHONE = '+447700900796';

/** The fixed generic texts (title / body) of the duty kinds a member or leader may receive. */
export const GENERIC_TEXT = {
  duty_assigned: ['New duty assigned', 'You have a new duty. Open it to accept or say you cannot make it.'],
  duty_released: ['Duty changed', 'A duty you were given has changed and is no longer assigned to you.'],
  duty_cancelled: ['Duty cancelled', 'One of your duties was cancelled. Open My duties to see what is still yours.'],
  duty_declined: ['Duty declined', 'A member cannot make a duty in your department. Open Coverage to find cover.'],
  followup_assigned: ['New follow-up task', 'A follow-up task was assigned to you. Open it to see the next action.'],
};

/** An inbox item that carries exactly the generic text of its reminder kind. */
export const isGenericItem = genericItemCheck(GENERIC_TEXT);

/** The reserved fictional numbers this run uses (+44 7700 900790-900799). */
export function isFictionalCoveragePhone(phone) {
  return /^\+44770090079[0-9]$/.test(phone);
}

/** Does a coverage answer hold anything private (a route, a number, a note or a reason)? */
export function holdsPrivate(coverage) {
  const json = JSON.stringify(coverage ?? {});
  if (/\+447700900|SYNTHETIC household|SYNTHETIC: /.test(json)) return true;
  for (const d of coverage?.departments ?? []) {
    if (Object.keys(d.contact_routes ?? {}).length > 0) return true;
    for (const p of d.positions ?? []) {
      if (p.assignment?.note || p.assignment?.confirmation?.reason || p.follow_up?.last_attempt?.note
          || p.follow_up?.task_id) return true;
    }
  }
  return false;
}

/** The position of a coverage answer by assignment id (or slot id). */
export function positionOf(coverage, id) {
  for (const d of coverage?.departments ?? []) {
    for (const p of d.positions ?? []) {
      if (p.assignment?.assignment_id === id || p.slot_id === id) return p;
    }
  }
  return null;
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
    admin: { phone: '+447700900790', name: `${NAME_PREFIX} Admin` },
    leader: { phone: '+447700900791', name: `${NAME_PREFIX} Leader` },
    other: { phone: '+447700900792', name: `${NAME_PREFIX} Other leader` },
    member: { phone: '+447700900793', name: `${NAME_PREFIX} Member M` },
    decliner: { phone: '+447700900794', name: `${NAME_PREFIX} Member O` },
    cover: { phone: '+447700900795', name: `${NAME_PREFIX} Member Q` },
    spare: { phone: '+447700900797', name: `${NAME_PREFIX} Member R` },
  };
  for (const p of Object.values(people)) if (!isFictionalCoveragePhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  if (!isFictionalCoveragePhone(HOUSEHOLD_PHONE)) throw new Error('not fictional');
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
    create temp table gone_occurrences as
      select o.occurrence_id from app.duties_occurrences o where o.department_id in (select department_id from gone_departments);
    create temp table gone_assignments as
      select a.assignment_id from app.duties_assignments a join app.duties_slots s on s.slot_id = a.slot_id
       where s.occurrence_id in (select occurrence_id from gone_occurrences);
    create temp table gone_tasks as
      select t.task_id from app.followups_tasks t
       where (t.source_type = 'duties_coverage_case'
              and t.source_id in (select c.case_id from app.duties_coverage_cases c
                                   where c.assignment_id in (select assignment_id from gone_assignments)))
          or t.owner_member_id in (select member_id from gone_members);
    create temp table gone_jobs as
      select j.job_id from app.notifications_jobs j
       where j.recipient_member_id in (select member_id from gone_members)
          or j.source_id in (select assignment_id from gone_assignments)
          or j.source_id in (select task_id from gone_tasks);
    delete from app.notifications_push_jobs p where p.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_attempts a where a.job_id in (select job_id from gone_jobs);
    delete from app.notifications_direct_contact_needs n where n.job_id in (select job_id from gone_jobs);
    update app.notifications_jobs j set snoozed_from_item_id = null where j.job_id in (select job_id from gone_jobs);
    delete from app.notifications_inbox_items i where i.job_id in (select job_id from gone_jobs)
       or i.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_jobs j where j.job_id in (select job_id from gone_jobs);
    delete from app.notifications_schedules s where s.source_id in (select assignment_id from gone_assignments)
       or s.source_id in (select task_id from gone_tasks)
       or s.recipient_member_id in (select member_id from gone_members);
    delete from app.followups_notes n where n.task_id in (select task_id from gone_tasks);
    delete from app.followups_activity a where a.task_id in (select task_id from gone_tasks);
    delete from app.followups_tasks t where t.task_id in (select task_id from gone_tasks);
    delete from app.duties_contact_attempts t where t.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_coverage_cases c where c.assignment_id in (select assignment_id from gone_assignments);
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
    psql(`select app.platform_set_environment('local', 'duties-coverage-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('C00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  const run = randomUUID().slice(0, 8);
  const { principal, credentialId, worker } = notificationsWorker({ origin, key, operator: OPERATOR,
    principalName: `notifications-worker-coverage-${run}`, label: `duties coverage e2e ${run}` });
  const roleOf = (memberId) => Object.entries(people).find(([, p]) => p.member === memberId)?.[0] ?? 'x';
  // An assignment's jobs in a state: "<m|l>:<kind>@<role>".
  const jobs = (assignmentId, state = 'pending') => summarize(psql(`select coalesce(string_agg(
        case j.source_type when 'duties_assignment' then 'm' else 'l' end || ':' || j.reminder_kind || '@'
        || j.recipient_member_id, ','), '')
      from app.notifications_jobs j where j.source_id = '${assignmentId}' and j.job_state = '${state}'
       and j.snoozed_from_item_id is null`)
    .split(',').filter(Boolean).map((x) => x.replace(/@([0-9a-f-]{36})/, (_, m) => `@${roleOf(m)}`)));
  const inbox = async (p) => (await read('notifications_my_inbox', p.token))?.items ?? [];
  const openItem = async (p, itemId) => (await rpc('notifications_open_item', p.token, { item_id: itemId })).json;
  const coverage = async (p, body = {}) => rpc('duties_coverage', p.token, body);
  const occRevision = (occurrenceId) => Number(psql(`select revision from app.duties_occurrences where occurrence_id = '${occurrenceId}'`));
  const asgRevision = (assignmentId) => Number(psql(`select revision from app.duties_assignments where assignment_id = '${assignmentId}'`));
  const taskOf = (assignmentId) => psql(`select coalesce((select c.task_id::text from app.duties_coverage_cases c
      where c.assignment_id = '${assignmentId}' order by c.opened_at desc limit 1), '')`);
  const taskState = (taskId) => psql(`select coalesce((select task_state || '|' || coalesce(close_code, '-')
      from app.followups_tasks where task_id = '${taskId}'), '')`);
  const attempt = (p, assignmentId, outcome, nextMs, extra = {}) => duty(p.token, 'duties.record_contact_attempt',
    asgRevision(assignmentId), { assignment_id: assignmentId, channel: 'phone', outcome,
      next_follow_up_at: minute(nextMs), ...extra });

  try {
    const { admin, leader, other, member, decliner, cover, spare } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'duties-coverage-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    // The accountless member X with a labelled household number (the 2.5 contact route, SYNTHETIC).
    const accountless = { member: psql(`insert into app.identity_members (display_name, membership_state, is_synthetic)
      values ('${NAME_PREFIX} Accountless X', 'approved', true) returning member_id`) };
    people.accountless = accountless;
    psql(`insert into app.identity_contact_routes (member_id, value, belongs_to, holder_label, is_synthetic,
            created_by_member, created_by_account)
          values ('${accountless.member}', '${HOUSEHOLD_PHONE}', 'household', 'SYNTHETIC household', true,
                  '${admin.member}', '${admin.user}')`);
    check('C01-members-signed-in-by-phone', Object.entries(people).filter(([k]) => k !== 'accountless')
      .every(([, p]) => amrMethods(p.token).includes('password')), { amr: amrMethods(admin.token) });

    // ------------------------------------------------------- setup: two departments and their leaders
    const dept = await duty(admin.token, 'duties.create_department', null, { name: DEPARTMENT });
    const departmentId = dept.data?.department_id;
    const dept2 = await duty(admin.token, 'duties.create_department', null, { name: OTHER_DEPARTMENT });
    const grantRev = (m) => Number(psql(`select revision from app.identity_grant_sets where member_id = '${m}'`));
    const g1 = await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantRev(leader.member),
      { member_id: leader.member, scope_kind: 'department_leader', scope_id: departmentId });
    const g2 = await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantRev(other.member),
      { member_id: other.member, scope_kind: 'department_leader', scope_id: dept2.data?.department_id });
    const added = [];
    for (const p of [member, decliner, cover, spare, accountless]) {
      const rev = Number(psql(`select revision from app.duties_departments where department_id = '${departmentId}'`));
      added.push((await duty(admin.token, 'duties.add_member', rev, { department_id: departmentId, member_id: p.member })).status);
    }
    for (const p of [leader, other]) p.token = (await signIn(p.phone, p.password)).json?.access_token;
    check('C02-departments-leaders-members', dept.status === 200 && dept2.status === 200 && g1.status === 200
      && g2.status === 200 && added.length === 5 && added.every((s) => s === 200),
      { departments: [dept.status, dept2.status], grants: [g1.status, g2.status], members_added: added });

    // ------------------------------------------------------- a synthetic rota: M, X, O and a fourth position
    const series = await duty(leader.token, 'duties.create_series', null, {
      department_id: departmentId, duty_name: 'Sunday service', every: 'week',
      from_date: churchDate(4 * DAY), until_date: churchDate(4 * DAY), start_time: '10:00',
      positions: ['Preacher', 'Reader', 'Usher', 'Steward'] });
    const seriesId = series.data?.series_id;
    const occId = psql(`select occurrence_id from app.duties_occurrences where series_id = '${seriesId}'`);
    const slot = (no) => psql(`select slot_id from app.duties_slots where occurrence_id = '${occId}' and position_no = ${no}`);
    const planned = [];
    for (const [no, p] of [[1, member], [2, accountless], [3, decliner], [4, cover]]) {
      planned.push((await duty(leader.token, 'duties.assign_slot', occRevision(occId), { slot_id: slot(no), member_id: p.member })).status);
    }
    const sRev = Number(psql(`select revision from app.duties_series where series_id = '${seriesId}'`));
    const pub = await duty(leader.token, 'duties.publish_drafts', sRev, { series_id: seriesId, slot_count: 4 });
    const asg = (no) => psql(`select assignment_id from app.duties_assignments where slot_id = '${slot(no)}' and assignment_state = 'current'`);
    const [aM, aX, aO, aQ] = [asg(1), asg(2), asg(3), asg(4)];
    const dec = await duty(decliner.token, 'duties.respond', asgRevision(aO), { assignment_id: aO, response: 'declined' });
    const runA = await worker();
    const declinedItems = (await inbox(leader)).filter((i) => i.reminder_kind === 'duty_declined');
    const declinedOpen = declinedItems[0] ? await openItem(leader, declinedItems[0].item_id) : null;
    check('C10-rota-published-and-the-decline-alerts-the-leader', series.status === 200 && planned.every((s) => s === 200)
      && pub.status === 200 && pub.data?.assignments === 4 && dec.status === 200 && runA.exit === 0
      && declinedItems.length === 1 && declinedOpen?.state === 'current' && declinedOpen?.target === '/duties/coverage'
      && isGenericItem(declinedOpen),
      { published: pub.data?.assignments, declined: dec.status, decline_items: declinedItems.length,
        decline_target: declinedOpen?.target ?? null, generic: isGenericItem(declinedOpen) });

    // ------------------------------------------------------- the queue (the leader's full view)
    const q1 = await coverage(leader);
    const dep = (q1.json?.departments ?? []).find((d) => d.department_id === departmentId);
    const route = dep?.contact_routes?.[accountless.member]?.[0];
    check('C11-queue-states-counts-and-the-labelled-route', q1.status === 200 && dep?.view === 'full'
      && positionOf(q1.json, aM)?.status === 'awaiting' && positionOf(q1.json, aO)?.status === 'declined'
      && (positionOf(q1.json, aX)?.needs_contact?.reasons ?? []).includes('not_reached')
      && positionOf(q1.json, aX)?.assignment?.account === 'no_login'
      && dep?.counts?.required === 4 && dep?.counts?.declined === 1 && dep?.counts?.needs_contact >= 1
      && route?.phone === HOUSEHOLD_PHONE && route?.belongs_to === 'household'
      && !(dep?.contact_routes?.[member.member]),
      { status: q1.status, view: dep?.view, counts: dep?.counts,
        states: [aM, aX, aO, aQ].map((a) => positionOf(q1.json, a)?.status),
        route: route ? { belongs_to: route.belongs_to, labelled: Boolean(route.holder_label) } : null });

    // ------------------------------------------------------- a contact attempt opens the follow-up task
    const at1 = await attempt(leader, aM, 'no_answer', 1 * DAY, { note: 'SYNTHETIC: rang twice' });
    const tM = taskOf(aM);
    const myTasks = (await read('followups_my_tasks', leader.token))?.tasks ?? [];
    const listed = myTasks.find((t) => t.task_id === tM);
    const task1 = await read('followups_task', leader.token, { p_task_id: tM });
    const dueJobs = Number(psql(`select count(*) from app.notifications_jobs where source_id = '${tM}' and job_state = 'pending'
      and reminder_kind = 'followup_due'`));
    check('C20-contact-attempt-opens-a-follow-up-task', at1.status === 200 && at1.data?.followup === 'opened'
      && Boolean(tM) && Boolean(listed) && task1?.task?.state === 'open' && task1?.task?.purpose === 'coverage_follow_up'
      && /^Duty cover: Sunday service on \d{4}-\d{2}-\d{2}$/.test(task1?.task?.context?.label ?? '') && dueJobs === 1,
      { attempt: at1.status, followup: at1.data?.followup, listed: Boolean(listed), state: task1?.task?.state,
        context_ok: /^Duty cover: /.test(task1?.task?.context?.label ?? ''), due_jobs: dueJobs });
    const at2 = await attempt(leader, aM, 'left_message', 2 * DAY);
    const task2 = await read('followups_task', leader.token, { p_task_id: tM });
    const q2 = await coverage(leader);
    check('C21-a-second-attempt-updates-the-task', at2.status === 200 && at2.data?.followup === 'updated'
      && task2?.task?.state === 'waiting' && Boolean(task2?.task?.review_at)
      && positionOf(q2.json, aM)?.follow_up?.attempts === 2
      && positionOf(q2.json, aM)?.follow_up?.last_attempt?.outcome === 'left_message',
      { followup: at2.data?.followup, state: task2?.task?.state, attempts: positionOf(q2.json, aM)?.follow_up?.attempts });

    // ------------------------------------------------------- Confirmed by leader: X by phone
    const atX = await attempt(leader, aX, 'will_answer', 12 * HOUR);
    const tX = taskOf(aX);
    const noReason = await duty(leader.token, 'duties.confirm_by_leader', asgRevision(aX), { assignment_id: aX, channel: 'phone' });
    const conf = await duty(leader.token, 'duties.confirm_by_leader', asgRevision(aX),
      { assignment_id: aX, channel: 'phone', reason: 'SYNTHETIC: confirmed by phone with the household' });
    const q3 = await coverage(leader);
    const px = positionOf(q3.json, aX);
    check('C30-confirmed-by-leader-with-its-reason', atX.status === 200 && noReason.field_errors?.reason === 'required'
      && conf.status === 200 && conf.data?.provenance === 'leader' && px?.status === 'confirmed'
      && px?.assignment?.response_provenance === 'leader' && px?.assignment?.confirmation?.channel === 'phone'
      && px?.assignment?.confirmation?.reason === 'SYNTHETIC: confirmed by phone with the household'
      && Boolean(px?.assignment?.confirmation?.by) && jobs(aX) === 'm:duty_starting@accountless'
      && taskState(tX) === 'closed|source_resolved',
      { refused_without_reason: noReason.field_errors?.reason ?? null, confirmed: conf.status, status: px?.status,
        provenance: px?.assignment?.response_provenance, pending: jobs(aX), task: taskState(tX) });

    // ------------------------------------------------------- reassign the decline
    const atO = await attempt(leader, aO, 'cannot_serve', 1 * DAY);
    const tO = taskOf(aO);
    const re = await duty(leader.token, 'duties.assign_slot', occRevision(occId), { slot_id: slot(3), member_id: spare.member });
    const supersededState = psql(`select assignment_state from app.duties_assignments where assignment_id = '${aO}'`);
    const newO = asg(3);
    check('C31-reassigning-the-decline-cancels-the-old-reminders-and-closes-its-task', atO.status === 200
      && re.status === 200 && re.code == null && supersededState === 'superseded'
      && jobs(aO) === 'm:duty_released@decliner'
      && taskState(tO) === 'closed|source_resolved' && newO !== aO
      && jobs(newO).includes('m:duty_assigned@spare'),
      { attempt: atO.status, reassigned: re.status, code: re.code ?? null, old_state: supersededState, old_pending: jobs(aO),
        old_cancelled: jobs(aO, 'cancelled'),
        task: taskState(tO), new_pending: jobs(newO) });
    const acc = await duty(member.token, 'duties.respond', asgRevision(aM), { assignment_id: aM, response: 'accepted' });
    check('C32-the-member-s-own-acceptance-closes-their-task', acc.status === 200
      && taskState(tM) === 'closed|source_resolved'
      && Number(psql(`select count(*) from app.notifications_jobs where source_id = '${tM}' and job_state = 'pending'`)) === 0,
      { accepted: acc.status, task: taskState(tM) });

    // ------------------------------------------------------- nothing private for another leader or the Admin
    const qk = await coverage(other);
    const qa = await coverage(admin);
    const adminDept = (qa.json?.departments ?? []).find((d) => d.department_id === departmentId);
    const kAttempt = await attempt(other, newO, 'no_answer', 1 * HOUR);
    const aAttempt = await attempt(admin, newO, 'no_answer', 1 * HOUR);
    const aConfirm = await duty(admin.token, 'duties.confirm_by_leader', asgRevision(newO),
      { assignment_id: newO, channel: 'phone', reason: 'x' });
    const kFilter = await coverage(other, { department_id: departmentId });
    const routing = await read('followups_task', admin.token, { p_task_id: tX });
    // Review B1: the Confirmed by leader reason on the board is for the department's leaders only.
    const boardConfirmation = async (p) => {
      const b = await read('duties_leader_board', p.token);
      for (const d of b?.departments ?? []) for (const du of d.duties ?? []) for (const pos of du.positions ?? []) {
        if (pos.assignment?.assignment_id === aX) return pos.assignment.confirmation ?? null;
      }
      return null;
    };
    const leaderBoard = await boardConfirmation(leader);
    const adminBoard = await boardConfirmation(admin);
    const adminRota = JSON.stringify(await read('duties_rota', admin.token));
    check('C40-another-leader-and-an-admin-see-nothing-private', qk.status === 200
      && (qk.json?.departments ?? []).every((d) => d.department_id !== departmentId) && !holdsPrivate(qk.json)
      && qa.status === 200 && adminDept?.view === 'operational' && !holdsPrivate(qa.json)
      && positionOf(qa.json, aX)?.assignment?.confirmation?.channel === 'phone'
      && kAttempt.code === 'not_found' && aAttempt.code === 'forbidden' && aConfirm.code === 'forbidden'
      && kFilter.status === 403 && routing?.view === 'routing' && !JSON.stringify(routing ?? {}).includes('SYNTHETIC:')
      && typeof leaderBoard?.reason === 'string' && adminBoard?.channel === 'phone' && adminBoard?.reason == null
      && !adminRota.includes('SYNTHETIC:'),
      { other_departments: (qk.json?.departments ?? []).length, other_private: holdsPrivate(qk.json),
        admin_view: adminDept?.view, admin_private: holdsPrivate(qa.json), other_attempt: kAttempt.code ?? null,
        admin_attempt: aAttempt.code ?? null, admin_confirm: aConfirm.code ?? null, other_filter: kFilter.status,
        admin_task_view: routing?.view ?? null, leader_board_reason: typeof leaderBoard?.reason === 'string',
        admin_board_reason: adminBoard?.reason != null, admin_rota_private: adminRota.includes('SYNTHETIC:') });

    // ------------------------------------------------------- cancel a position, then the last ones
    const c1 = await duty(leader.token, 'duties.cancel_position', occRevision(occId), { slot_id: slot(4) });
    const qAfter = await coverage(leader);
    const cancelledPending = jobs(aQ);
    const twice = await duty(leader.token, 'duties.cancel_position', occRevision(occId), { slot_id: slot(4) });
    const c2 = await duty(leader.token, 'duties.cancel_position', occRevision(occId), { slot_id: slot(1) });
    const c3 = await duty(leader.token, 'duties.cancel_position', occRevision(occId), { slot_id: slot(2) });
    const c4 = await duty(leader.token, 'duties.cancel_position', occRevision(occId), { slot_id: slot(3) });
    const occState = psql(`select occurrence_state from app.duties_occurrences where occurrence_id = '${occId}'`);
    check('C50-cancel-positions-and-the-last-cancels-the-date', c1.status === 200 && c1.data?.cancelled === 'position'
      && cancelledPending === 'm:duty_cancelled@cover' && positionOf(qAfter.json, slot(4)) === null
      && (qAfter.json?.departments ?? []).find((d) => d.department_id === departmentId)?.counts?.required === 3
      && twice.field_errors?.slot_id === 'cancelled' && c2.status === 200 && c3.status === 200
      && c4.data?.cancelled === 'occurrence' && occState === 'cancelled',
      { first: c1.data?.cancelled, pending: cancelledPending, twice: twice.field_errors?.slot_id ?? null,
        last: c4.data?.cancelled, occurrence: occState });

    // ------------------------------------------------------- generic text; tables refused
    const runZ = await worker();
    const items = [];
    for (const p of [member, decliner, cover, spare, leader]) {
      for (const i of (await inbox(p)).filter((x) => GENERIC_TEXT[x.reminder_kind])) {
        items.push(await openItem(p, i.item_id));
      }
    }
    const tableQueries = [];
    for (const t of ['duties_contact_attempts', 'duties_coverage_cases']) {
      tableQueries.push((await http('GET', `/rest/v1/${t}?select=*`, { token: leader.token, profile: 'app' })).status);
    }
    check('C90-generic-text-only-and-tables-refused', runZ.exit === 0 && items.length > 0 && items.every(isGenericItem)
      && !JSON.stringify(items).includes('SYNTHETIC') && tableQueries.every((s) => s >= 400),
      { items: items.length, all_generic: items.every(isGenericItem), table_queries: tableQueries });
  } finally {
    const left = cleanup();
    psql(`select app.sys_revoke_credential('${credentialId}', '${OPERATOR}'); select app.sys_disable_principal('${principal}', '${OPERATOR}');`);
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'duties-coverage-e2e';
            delete from app.platform_environment_history where set_by = 'duties-coverage-e2e';`);
    }
    log('C99-cleanup', { users_left: Number(left), credential_revoked: true, principal_disabled: true, unmarked: marked,
      departments_left: Number(psql(`select count(*) from app.duties_departments where name in ('${DEPARTMENT}', '${OTHER_DEPARTMENT}')`)),
      tasks_left: Number(psql(`select count(*) from app.followups_tasks where source_type = 'duties_coverage_case'`)) });
  }
  finish();
}

runMain(import.meta.url, main);
