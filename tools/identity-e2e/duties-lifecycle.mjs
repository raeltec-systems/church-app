#!/usr/bin/env node
// Story 4.12 end-to-end on the LOCAL stack: membership lifecycle and handover in Duties and
// Follow-ups through real GoTrue phone sign-in (no SMS), the real Data API (PostgREST) and the real
// worker script (tools/notifications/worker.mjs), proving the ticket's verify line on synthetic
// members with upcoming duties and open tasks:
//   * a login hold keeps the member's duties and lists them under Needs contact at once (no
//     leader alert, the hold never named);
//   * a church deactivation (raced against a leader giving the member another duty) ends every
//     future assignment in the same transaction: vacancies flagged, the member's jobs cancelled,
//     one leaders' notice per department (delivered by the worker), the open task handed to its
//     supervisor; no deactivation reason reaches a leader;
//   * the last leader of an active department cannot be deactivated until a reachable deputy is
//     in place;
//   * removal from the department ends that department's future duties and tells the member;
//   * a revoked deputy loses their pending alerts, commands and supervision at once;
//   * a deletion hands the member's task over, records no pending handover, and the Duties and
//     Follow-ups deletion check answers zero after the erase phase;
//   * review S2: two-connection races. A deactivation held open in its own transaction (psql, the
//     Admin's session claims) while the leader revises and publishes the member's duties over HTTP:
//     the deactivation succeeds and the leader's commands wait, then succeed or are refused cleanly
//     (never `unavailable`, never a deadlock). And the reverse orders, with the leader's revise_duty
//     or publish_duty paused mid-command by a third connection while the Admin deactivates the
//     member over HTTP: both succeed and the duty is vacated;
//   * review B1 and S5: a revoked scope over the hook's cap leaves tasks the former deputy can no
//     longer open; the Admin's complete_handover, raced with the deactivation of the person it
//     would choose, gives them to someone still active (never to the member being deactivated).
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900470-900479. Evidence is redacted JSONL:
// statuses, codes, counts and states; never tokens, passwords, numbers, the credential, names or
// reasons. Every user, member, grant, department, duty, task, hold, deletion, job, item and receipt
// it created is removed; the run's credential is revoked and its principal disabled.
//
// Usage: node tools/identity-e2e/duties-lifecycle.mjs [--evidence <file.jsonl>]
import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { promisify } from 'node:util';

import { amrMethods, dbContainer, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';
import { jsonLiteral, notificationsWorker, sessionClaims } from './duties-shared.mjs';

export { jsonLiteral, sessionClaims } from './duties-shared.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 4.12 E2E';
export const DEPARTMENT = 'SYNTHETIC Preaching Rota';
export const OTHER_DEPARTMENT = 'SYNTHETIC 4.12 E2E Ushers';
/** Identity reason codes that must never reach a leader's read. */
export const REASON_CODES = ['moved_away', 'church_decision', 'member_request', 'login_disabled', 'member_left',
  'deletion_requested', 'deactivat'];

/** The reserved fictional numbers this run uses (+44 7700 900470-900479). */
export function isFictionalLifecyclePhone(phone) {
  return /^\+44770090047[0-9]$/.test(phone);
}

/** Does an answer name any lifecycle reason? */
export function holdsReason(answer) {
  const json = JSON.stringify(answer ?? {});
  return REASON_CODES.some((c) => json.includes(c));
}

/** The coverage position of a slot. */
export function coveragePosition(answer, slotId) {
  for (const d of answer?.departments ?? []) {
    for (const p of d.positions ?? []) if (p.slot_id === slotId) return p;
  }
  return null;
}

/** A department's coverage counts. */
export function coverageCounts(answer, departmentId) {
  return (answer?.departments ?? []).find((d) => d.department_id === departmentId)?.counts ?? null;
}

/** The ISO start of church date `ymd` at 10:00 Africa/Lusaka (UTC+2, no daylight saving). */
export function churchTen(ymd) {
  return `${ymd}T08:00:00Z`;
}

/**
 * One SQL text that runs an api command as the signed-in caller (their session claims, role
 * authenticated) in its own transaction and keeps it open `sleepSeconds` before committing, so a
 * second connection meets its locks.
 */
export function heldCommandSql(claims, endpoint, envelope, sleepSeconds) {
  if (!/^[a-z_]+$/.test(endpoint)) throw new Error('unexpected endpoint');
  return `begin;
select set_config('request.jwt.claims', ${jsonLiteral(claims).replace('::jsonb', '')}, true) is not null;
set local role authenticated;
select api.${endpoint}(${jsonLiteral(envelope)});
select pg_sleep(${Number(sleepSeconds)});
commit;`;
}

/** A raced command's outcome is clean: it went through or was refused with a plain refusal code. */
export function cleanOutcome(r) {
  if (done(r)) return true;
  return r?.status < 500 && ['conflict', 'validation_failed', 'not_found'].includes(r?.code);
}

/** A command answer that went through (no refusal code). */
export function done(r) {
  return r?.status === 200 && !r.code;
}

async function main() {
  const { log, check, finish } = startRun();
  const keys = localKey();
  const { origin, key } = keys;
  const http = localHttp(keys);
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const read = async (fn, token, body = {}) => (await rpc(fn, token, body)).json;
  const envelope = (fn, token, cmd, expected, payload) =>
    rpc(fn, token, { version: 1, command: cmd, request_id: randomUUID(), expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const duty = (token, cmd, expected, payload) => envelope('duties_command', token, cmd, expected, payload);
  const HOUR = 3_600_000;
  const DAY = 24 * HOUR;
  const churchDate = (ms) => new Date(Date.now() + ms + 2 * HOUR).toISOString().slice(0, 10);

  const people = {
    admin: { phone: '+447700900470', name: `${NAME_PREFIX} Admin` },
    leader: { phone: '+447700900471', name: `${NAME_PREFIX} Leader L` },
    deputy: { phone: '+447700900472', name: `${NAME_PREFIX} Deputy P` },
    member: { phone: '+447700900473', name: `${NAME_PREFIX} Member M` },
    removed: { phone: '+447700900474', name: `${NAME_PREFIX} Member O` },
    held: { phone: '+447700900475', name: `${NAME_PREFIX} Member H` },
    sole: { phone: '+447700900476', name: `${NAME_PREFIX} Leader K` },
    spare: { phone: '+447700900477', name: `${NAME_PREFIX} Member X` },
  };
  for (const p of Object.values(people)) if (!isFictionalLifecyclePhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
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
      select t.task_id from app.followups_tasks t where t.scope_id in (select department_id from gone_departments)
          or t.owner_member_id in (select member_id from gone_members);
    create temp table gone_jobs as
      select j.job_id from app.notifications_jobs j
       where j.recipient_member_id in (select member_id from gone_members)
          or j.source_id in (select assignment_id from gone_assignments)
          or j.source_id in (select task_id from gone_tasks);
    create temp table gone_deletions as
      select d.deletion_id from app.identity_deletions d where d.member_id in (select member_id from gone_members);
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
       or a.actor_member_id in (select member_id from gone_members) or a.member_id in (select member_id from gone_members);
    delete from app.duties_slot_revisions r where r.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_assignments a where a.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_slots s where s.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_occurrences o where o.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_series r where r.department_id in (select department_id from gone_departments);
    delete from app.duties_department_members dm where dm.department_id in (select department_id from gone_departments);
    delete from app.identity_deletion_audit a where a.deletion_id in (select deletion_id from gone_deletions);
    delete from app.identity_deletion_steps s where s.deletion_id in (select deletion_id from gone_deletions);
    delete from app.identity_deletion_accounts a where a.deletion_id in (select deletion_id from gone_deletions);
    delete from app.identity_deletion_aggregates a where a.deletion_id in (select deletion_id from gone_deletions);
    delete from app.identity_deletions d where d.deletion_id in (select deletion_id from gone_deletions);
    delete from app.identity_handover_obligations o where o.member_id in (select member_id from gone_members);
    delete from app.identity_membership_lifecycle e
     where e.member_id in (select member_id from gone_members) or e.actor_member_id in (select member_id from gone_members);
    delete from app.identity_credential_review_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
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
    psql(`select app.platform_set_environment('local', 'duties-lifecycle-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('L00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  const run = randomUUID().slice(0, 8);
  const { principal, credentialId, worker } = notificationsWorker({ origin, key, operator: OPERATOR,
    principalName: `notifications-worker-lifecycle-${run}`, label: `duties lifecycle e2e ${run}` });
  const asgRevision = (id) => Number(psql(`select revision from app.duties_assignments where assignment_id = '${id}'`));
  const asgState = (id) => psql(`select assignment_state || ':' || coalesce(end_reason, '-') from app.duties_assignments
    where assignment_id = '${id}'`);
  const slotOf = (id) => psql(`select slot_id from app.duties_assignments where assignment_id = '${id}'`);
  const memberRevision = (m) => Number(psql(`select revision from app.identity_members where member_id = '${m}'`));
  const grantRevision = (m) => Number(psql(`select revision from app.identity_grant_sets where member_id = '${m}'`));
  const departmentRevision = (d) => Number(psql(`select revision from app.duties_departments where department_id = '${d}'`));
  const pendingFor = (memberId, kind) => Number(psql(`select count(*) from app.notifications_jobs
    where recipient_member_id = '${memberId}' and job_state = 'pending' and reminder_kind = '${kind}'`));
  const futureCurrent = (memberId) => Number(psql(`select count(*) from app.duties_assignments a
      join app.duties_slots s on s.slot_id = a.slot_id join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
     where a.member_id = '${memberId}' and a.assignment_state = 'current' and o.occurrence_state = 'published'
       and coalesce(o.reporting_at, o.starts_at) > now()`));
  const taskOwner = (taskId) => psql(`select owner_member_id from app.followups_tasks where task_id = '${taskId}'`);
  const taskSupervisor = (taskId) => psql(`select supervisor_member_id from app.followups_tasks where task_id = '${taskId}'`);
  const pendingObligations = (memberId) => Number(psql(`select count(*) from app.identity_handover_obligations
    where member_id = '${memberId}' and obligation_state = 'pending'`));
  const refused = (r, code, field, value) => r.code === code && (!field || r.field_errors?.[field] === value);
  const coverage = (p, from, to) => read('duties_coverage', p.token, { from_date: from, to_date: to });
  const occRevision = (o) => Number(psql(`select revision from app.duties_occurrences where occurrence_id = '${o}'`));
  const heldCall = async (p, endpoint, cmd, expected, payload, sleepSeconds) => {
    const sql = heldCommandSql(sessionClaims(p.token), endpoint,
      { version: 1, command: cmd, request_id: randomUUID(), expected_revision: expected, payload }, sleepSeconds);
    try {
      const { stdout } = await promisify(execFile)('docker',
        ['exec', '-i', dbContainer(), 'psql', '-U', 'postgres', '-X', '-qtA', '-v', 'ON_ERROR_STOP=1', '-c', sql], { encoding: 'utf8' });
      const line = stdout.split('\n').find((l) => l.trim().startsWith('{'));
      return { status: 200, ...(line ? JSON.parse(line) : {}) };
    } catch (e) {
      return { status: 500, code: /40P01|deadlock/.test(String(e.stderr)) ? 'deadlock' : 'error' };
    }
  };
  const pause = (ms) => new Promise((r) => setTimeout(r, ms));
  const psqlAsync = (sql) => promisify(execFile)('docker',
    ['exec', '-i', dbContainer(), 'psql', '-U', 'postgres', '-X', '-qtA', '-v', 'ON_ERROR_STOP=1', '-c', sql], { encoding: 'utf8' })
    .then(() => 'released', () => 'error');

  try {
    const { admin, leader, deputy, member, removed, held, sole, spare } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'duties-lifecycle-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    // R: an accountless SYNTHETIC member (deleted on the staff route by one Admin).
    const accountless = psql(`insert into app.identity_members (display_name, membership_state, is_synthetic)
      values ('${NAME_PREFIX} Member R', 'approved', true) returning member_id`);
    check('L01-members-signed-in-by-phone', Object.values(people).every((p) => amrMethods(p.token).includes('password')),
      { amr: amrMethods(admin.token), accountless: Boolean(accountless) });

    // ------------------------------------------------------- setup: departments, leaders, members, duties, tasks
    const dept = await duty(admin.token, 'duties.create_department', null, { name: DEPARTMENT });
    const dept2 = await duty(admin.token, 'duties.create_department', null, { name: OTHER_DEPARTMENT });
    const departmentId = dept.data?.department_id;
    const otherId = dept2.data?.department_id;
    const grants = [];
    for (const [p, kind, d] of [[leader, 'department_leader', departmentId], [deputy, 'department_deputy', departmentId],
      [sole, 'department_leader', otherId]]) {
      grants.push((await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantRevision(p.member),
        { member_id: p.member, scope_kind: kind, scope_id: d })).code ?? 'done');
    }
    const added = [];
    for (const [m, d] of [[leader.member, departmentId], [member.member, departmentId], [removed.member, departmentId],
      [held.member, departmentId], [spare.member, departmentId], [accountless, departmentId], [member.member, otherId],
      [sole.member, otherId]]) {
      added.push((await duty(admin.token, 'duties.add_member', departmentRevision(d), { department_id: d, member_id: m })).code ?? 'done');
    }
    for (const p of [leader, deputy, sole]) p.token = (await signIn(p.phone, p.password)).json?.access_token;
    const publish = async (who, days, by = leader, d = departmentId) => duty(by.token, 'duties.publish_duty', null, {
      department_id: d, member_id: who, duty_name: `Duty ${days}`, location: 'SYNTHETIC hall',
      starts_at: churchTen(churchDate(days * DAY)) });
    const published = {
      MP: await publish(member.member, 10), MA: await publish(member.member, 11),
      ME: await publish(member.member, 12, sole, otherId),
      HP: await publish(held.member, 13), HA: await publish(held.member, 14),
      OP: await publish(removed.member, 15), OA: await publish(removed.member, 16),
      RP: await publish(accountless, 17),
    };
    const a = Object.fromEntries(Object.entries(published).map(([k, r]) => [k, r.data?.assignment_id]));
    const answers = [];
    for (const [p, k] of [[member, 'MA'], [member, 'ME'], [held, 'HA'], [removed, 'OA']]) {
      answers.push((await duty(p.token, 'duties.respond', asgRevision(a[k]), { assignment_id: a[k], response: 'accepted' })).code ?? 'done');
    }
    const task = async (owner, supervisor) => {
      const r = await envelope('followups_command', leader.token, 'followups.create_task', null, {
        source_type: 'fixture_followup', source_id: randomUUID(), source_revision: 1, purpose: 'synthetic_check_in',
        owner_member_id: owner, supervisor_member_id: supervisor, scope_kind: 'department_leader', scope_id: departmentId,
        next_action: 'SYNTHETIC: phone and check in', due_at: churchTen(churchDate(9 * DAY)) });
      return r.data?.task_id;
    };
    const t1 = await task(member.member, leader.member);
    const t2 = await task(spare.member, deputy.member);
    const t3 = await task(accountless, leader.member);
    check('L02-setup', done(dept) && done(dept2) && grants.every((s) => s === 'done') && added.every((s) => s === 'done')
      && Object.values(published).every(done) && answers.every((s) => s === 'done') && Boolean(t1 && t2 && t3),
      { grants, members_added: added, published: Object.values(published).map((r) => r.code ?? 'done'), answers,
        tasks: [t1, t2, t3].map(Boolean) });
    const from = churchDate(9 * DAY);
    const to = churchDate(20 * DAY);

    // ------------------------------------------------------- a login hold keeps duties, routes contact
    const coverageJobsBefore = Number(psql(`select count(*) from app.notifications_jobs where source_type = 'duties_coverage'`));
    const hold = await envelope('identity_credential_command', admin.token, 'identity.place_hold', memberRevision(held.member),
      { member_id: held.member, reason_code: 'login_disabled' });
    const c1 = await coverage(leader, from, to);
    const hp = coveragePosition(c1, slotOf(a.HP));
    const ha = coveragePosition(c1, slotOf(a.HA));
    const board1 = await read('duties_leader_board', leader.token);
    check('L10-a-held-member-keeps-duties-with-needs-contact', done(hold) && asgState(a.HP) === 'current:-'
      && asgState(a.HA) === 'current:-' && hp?.status === 'awaiting' && ha?.status === 'confirmed'
      && hp?.needs_contact?.reasons?.includes('not_reached') && ha?.needs_contact?.reasons?.includes('not_reached')
      && Number(psql(`select count(*) from app.notifications_jobs where source_type = 'duties_coverage'`)) === coverageJobsBefore
      && !holdsReason([c1, board1]),
      { hold: hold.code ?? 'done', states: [asgState(a.HP), asgState(a.HA)], statuses: [hp?.status ?? null, ha?.status ?? null],
        needs_contact: [hp?.needs_contact?.reasons ?? null, ha?.needs_contact?.reasons ?? null],
        new_leader_alerts: Number(psql(`select count(*) from app.notifications_jobs where source_type = 'duties_coverage'`)) - coverageJobsBefore,
        reason_in_reads: holdsReason([c1, board1]) });

    // ------------------------------------------------------- deactivation, raced with a leader's new duty
    const [deact, raced] = await Promise.all([
      envelope('identity_lifecycle_command', admin.token, 'identity.deactivate_membership', memberRevision(member.member),
        { member_id: member.member, reason_code: 'moved_away' }),
      publish(member.member, 18),
    ]);
    const racedOutcome = done(raced) ? `published_then_${asgState(raced.data?.assignment_id)}` : (raced.code ?? `http_${raced.status}`);
    check('L20-deactivation-ends-future-assignments-in-one-transaction', done(deact)
      && ['MP', 'MA', 'ME'].every((k) => asgState(a[k]) === 'superseded:vacated') && futureCurrent(member.member) === 0
      && ['published_then_superseded:vacated', 'validation_failed'].includes(racedOutcome)
      && Number(psql(`select count(*) from app.notifications_jobs where recipient_member_id = '${member.member}'
           and job_state = 'pending' and source_type in ('duties_assignment', 'duties_coverage')`)) === 0
      && pendingFor(leader.member, 'duty_vacated') === 1 && pendingFor(deputy.member, 'duty_vacated') === 1
      && pendingFor(sole.member, 'duty_vacated') === 1,
      { deactivate: deact.code ?? 'done', states: ['MP', 'MA', 'ME'].map((k) => asgState(a[k])), raced_publish: racedOutcome,
        future_current_left: futureCurrent(member.member),
        leader_notices: [pendingFor(leader.member, 'duty_vacated'), pendingFor(deputy.member, 'duty_vacated'),
          pendingFor(sole.member, 'duty_vacated')] });
    // Review N3: the supervisor became the owner, so another holder of the scope (the deputy) supervises.
    const t1Activity = psql(`select string_agg(action || ':' || actor_capacity || ':' || code, ',' order by action)
      from app.followups_activity where task_id = '${t1}' and code = 'handover'`);
    check('L21-the-open-task-is-handed-to-its-supervisor', taskOwner(t1) === leader.member
      && taskSupervisor(t1) === deputy.member && pendingObligations(member.member) === 0
      && t1Activity === 'reassigned:source:handover,supervisor_changed:source:handover',
      { owner_is_supervisor: taskOwner(t1) === leader.member, new_supervisor_is_deputy: taskSupervisor(t1) === deputy.member,
        activity: t1Activity.split(','), pending_obligations: pendingObligations(member.member) });
    const runA = await worker();
    const lInbox = ((await read('notifications_my_inbox', leader.token))?.items ?? []).filter((i) => i.reminder_kind === 'duty_vacated');
    const c2 = await coverage(leader, from, to);
    const mp = coveragePosition(c2, slotOf(a.MP));
    const board2 = await read('duties_leader_board', leader.token);
    const pastorlessReads = [c2, board2, await read('duties_rota', leader.token)];
    check('L22-vacancies-flagged-with-one-leader-notice', runA.exit === 0 && lInbox.length === 1
      && lInbox[0]?.title === 'Positions need cover' && mp?.status === 'unfilled' && Boolean(mp?.vacated?.since)
      && coverageCounts(c2, departmentId)?.vacated >= 2 && !holdsReason(pastorlessReads),
      { worker: runA.exit, leader_inbox: lInbox.map((i) => i.reminder_kind), status: mp?.status ?? null,
        flagged: Boolean(mp?.vacated?.since), vacated_count: coverageCounts(c2, departmentId)?.vacated ?? null,
        reason_in_reads: holdsReason(pastorlessReads) });

    // ------------------------------------------------------- review S2: two-connection races, no deadlock
    // Accountless SYNTHETIC members Y, Z and W in D; Y and Z with a duty.
    const raceMembers = psql(`insert into app.identity_members (display_name, membership_state, is_synthetic)
      values ('${NAME_PREFIX} Member Y', 'approved', true), ('${NAME_PREFIX} Member Z', 'approved', true),
             ('${NAME_PREFIX} Member W', 'approved', true)
      returning member_id`).split('\n');
    const [yMember, zMember, wMember] = raceMembers;
    for (const m of raceMembers) await duty(admin.token, 'duties.add_member', departmentRevision(departmentId), { department_id: departmentId, member_id: m });
    const yDuty = await publish(yMember, 20);
    const zDuty = await publish(zMember, 21);
    const yOcc = yDuty.data?.occurrence_id;
    const zOcc = zDuty.data?.occurrence_id;
    // Deactivation first (held open 2 s), then the leader's revision and new duty for Y over HTTP.
    const yDeact = heldCall(admin, 'identity_lifecycle_command', 'identity.deactivate_membership', memberRevision(yMember),
      { member_id: yMember, reason_code: 'moved_away' }, 2);
    await pause(600);
    const yStarted = Date.now();
    const [yRevise, yPublish] = await Promise.all([
      duty(leader.token, 'duties.revise_duty', occRevision(yOcc), { occurrence_id: yOcc, location: 'SYNTHETIC annex' }),
      publish(yMember, 22),
    ]);
    const yWaited = Date.now() - yStarted;
    const yHeld = await yDeact;
    check('L23-a-held-deactivation-and-the-leaders-commands-never-deadlock', done(yHeld)
      && cleanOutcome(yRevise) && cleanOutcome(yPublish) && !done(yPublish) && yWaited >= 800
      && futureCurrent(yMember) === 0 && asgState(yDuty.data?.assignment_id) === 'superseded:vacated',
      { deactivation: yHeld.code ?? 'done', revise_duty: yRevise.code ?? 'done', publish_duty: yPublish.code ?? 'done',
        statuses: [yRevise.status, yPublish.status], waited_for_the_lock: yWaited >= 800, future_current_left: futureCurrent(yMember) });
    // The reverse orders, paused mid-command (the reviewer's deadlocks): a third connection holds a
    // lock the leader's command needs after it has started (Z's pending jobs, which revise_duty
    // cancels after locking the duty; W's member advisory lock, which publish_duty takes before
    // queueing the notice), the Admin then deactivates the member over HTTP, and the third
    // connection lets go. Without the S2 key-share lock both cycles end in 40P01 (`unavailable`).
    const zA = zDuty.data?.assignment_id;
    const zStart = zDuty.data ? churchTen(churchDate(21 * DAY)).replace('T08:00', 'T09:00') : null;
    const zGate = psqlAsync(`begin;
      select count(*) from (select 1 from app.notifications_jobs where source_id = '${zA}' and job_state = 'pending' for update) x;
      select pg_sleep(2.5);
      commit;`);
    await pause(500);
    const zRevise = duty(leader.token, 'duties.revise_duty', occRevision(zOcc), { occurrence_id: zOcc, starts_at: zStart });
    await pause(600);
    const zDeact = envelope('identity_lifecycle_command', admin.token, 'identity.deactivate_membership',
      memberRevision(zMember), { member_id: zMember, reason_code: 'moved_away' });
    const [zRevised, zDeactivated] = await Promise.all([zRevise, zDeact, zGate]);
    const zVacated = Number(psql(`select count(*) from app.duties_assignments where member_id = '${zMember}'
      and assignment_state = 'superseded' and end_reason = 'vacated'`));
    check('L24-a-revision-paused-mid-command-and-the-deactivation-never-deadlock', done(zRevised) && done(zDeactivated)
      && zVacated === 1 && futureCurrent(zMember) === 0,
      { revise_duty: zRevised.code ?? 'done', deactivation: zDeactivated.code ?? 'done',
        statuses: [zRevised.status, zDeactivated.status], vacated: zVacated, future_current_left: futureCurrent(zMember) });
    const wGate = psqlAsync(`begin;
      select pg_advisory_xact_lock(hashtextextended('app.duties_member ${wMember}', 0)) is null;
      select pg_sleep(2.5);
      commit;`);
    await pause(500);
    const wPublish = publish(wMember, 23);
    await pause(600);
    const wDeact = envelope('identity_lifecycle_command', admin.token, 'identity.deactivate_membership',
      memberRevision(wMember), { member_id: wMember, reason_code: 'moved_away' });
    const [wPublished, wDeactivated] = await Promise.all([wPublish, wDeact, wGate]);
    check('L25-a-publish-paused-mid-command-and-the-deactivation-never-deadlock', cleanOutcome(wPublished)
      && done(wDeactivated) && futureCurrent(wMember) === 0,
      { publish_duty: wPublished.code ?? 'done', deactivation: wDeactivated.code ?? 'done',
        statuses: [wPublished.status, wDeactivated.status],
        state: done(wPublished) ? asgState(wPublished.data?.assignment_id) : null, future_current_left: futureCurrent(wMember) });

    // ------------------------------------------------------- the last leader of an active department
    const k1 = await envelope('identity_lifecycle_command', admin.token, 'identity.deactivate_membership',
      memberRevision(sole.member), { member_id: sole.member, reason_code: 'member_request' });
    const kGrant = await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantRevision(spare.member),
      { member_id: spare.member, scope_kind: 'department_deputy', scope_id: otherId });
    const k2 = await envelope('identity_lifecycle_command', admin.token, 'identity.deactivate_membership',
      memberRevision(sole.member), { member_id: sole.member, reason_code: 'member_request' });
    check('L30-the-last-leader-is-refused-until-handover', refused(k1, 'conflict', 'member_id', 'handover_required')
      && done(kGrant) && done(k2),
      { first: [k1.code ?? 'done', k1.field_errors?.member_id ?? null], deputy_given: kGrant.code ?? 'done', second: k2.code ?? 'done' });

    // ------------------------------------------------------- removal from the department
    const byLeader = await duty(leader.token, 'duties.remove_member', departmentRevision(departmentId),
      { department_id: departmentId, member_id: removed.member });
    const remove = await duty(admin.token, 'duties.remove_member', departmentRevision(departmentId),
      { department_id: departmentId, member_id: removed.member });
    const runB = await worker();
    const oInbox = ((await read('notifications_my_inbox', removed.token))?.items ?? []).filter((i) => i.reminder_kind === 'duty_released');
    check('L40-removal-ends-the-department-duties-and-tells-the-member', refused(byLeader, 'forbidden') && done(remove)
      && remove.data?.vacated === 2 && ['OP', 'OA'].every((k) => asgState(a[k]) === 'superseded:vacated')
      && runB.exit === 0 && oInbox.length === 2
      && psql(`select (ended_by_member = '${admin.member}')::text from app.duties_department_members
           where department_id = '${departmentId}' and member_id = '${removed.member}'`) === 'true',
      { leader: byLeader.code ?? 'done', admin: remove.code ?? 'done', vacated: remove.data?.vacated ?? null,
        states: ['OP', 'OA'].map((k) => asgState(a[k])), member_inbox: oInbox.length });

    // ------------------------------------------------------- a revoked deputy loses authority at once
    // A fresh vacancy (X's duty is given back and taken away) gives the deputy a pending notice first.
    const xp = await publish(spare.member, 19);
    const xRemove = await duty(admin.token, 'duties.remove_member', departmentRevision(departmentId),
      { department_id: departmentId, member_id: spare.member });
    const deputyPendingBefore = pendingFor(deputy.member, 'duty_vacated');
    const revoke = await envelope('identity_grant_command', admin.token, 'identity.revoke_scope', grantRevision(deputy.member),
      { member_id: deputy.member, scope_kind: 'department_deputy', scope_id: departmentId });
    const confirm = await duty(deputy.token, 'duties.confirm_by_leader', asgRevision(a.HP),
      { assignment_id: a.HP, channel: 'phone', reason: 'SYNTHETIC: confirmed' });
    const deputyCoverage = await rpc('duties_coverage', deputy.token, {});
    check('L50-a-revoked-deputy-loses-alerts-commands-and-supervision', done(xp) && done(xRemove)
      && deputyPendingBefore === 1 && done(revoke) && pendingFor(deputy.member, 'duty_vacated') === 0
      && ['not_found', 'forbidden'].includes(confirm.code) && deputyCoverage.status === 403
      && taskSupervisor(t2) === leader.member,
      { pending_before: deputyPendingBefore, revoke: revoke.code ?? 'done', pending_after: pendingFor(deputy.member, 'duty_vacated'),
        confirm: confirm.code ?? 'done', coverage: deputyCoverage.status, supervision_moved: taskSupervisor(t2) === leader.member });

    // ------------------------------------------------------- deletion: handover, then the check answers zero
    const del = await envelope('identity_deletion_command', admin.token, 'identity.request_member_deletion',
      memberRevision(accountless), { member_id: accountless, identity_check: 'in_person' });
    const deletionId = psql(`select deletion_id from app.identity_deletions where member_id = '${accountless}'`);
    const blocker = psql(`select coalesce(app.identity_deletion_blocker(d, 'erase_owners'), 'none')
      from app.identity_deletions d where d.deletion_id = '${deletionId}'`);
    const erase = JSON.parse(psql(`select json_object_agg(r ->> 'module', (r ->> 'remaining')::int)
      from jsonb_array_elements(app.identity_call_deletion_hooks('${accountless}', null, '${deletionId}', 'erase')) r
     where r ->> 'module' in ('duties', 'followups')`));
    const checkAnswer = JSON.parse(psql(`select json_object_agg(r ->> 'module', (r ->> 'remaining')::int)
      from jsonb_array_elements(app.identity_call_deletion_hooks('${accountless}', null, '${deletionId}', 'check')) r
     where r ->> 'module' in ('duties', 'followups')`));
    check('L60-deletion-hands-over-and-the-check-answers-zero', done(del) && asgState(a.RP) === 'superseded:vacated'
      && taskOwner(t3) === leader.member && pendingObligations(accountless) === 0 && blocker === 'none'
      && erase.duties === 0 && erase.followups === 0 && checkAnswer.duties === 0 && checkAnswer.followups === 0,
      { request: del.code ?? 'done', state: asgState(a.RP), task_handed_over: taskOwner(t3) === leader.member,
        pending_obligations: pendingObligations(accountless), blocker, erase, check: checkAnswer });

    // ------------------------------------------------------- review B1 and S5: a capped handover, raced
    // In the Ushers department: O and the held H become its deputies, L its leader; X (its deputy
    // since L30) owns 27 open tasks supervised by H. X's scope is revoked: the hook hands over up to
    // 25 (its cap; X's older task in D counts too) to O, the first reachable holder (deputies come
    // first for this purpose); the rest stay with X, who can no longer open them.
    const b1Grants = [];
    for (const [p, kind] of [[removed, 'department_deputy'], [leader, 'department_leader'], [held, 'department_deputy']]) {
      b1Grants.push((await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantRevision(p.member),
        { member_id: p.member, scope_kind: kind, scope_id: otherId })).code ?? 'done');
    }
    const b1Tasks = [];
    for (let k = 0; k < 27; k += 1) {
      const r = await envelope('followups_command', admin.token, 'followups.create_task', null, {
        source_type: 'fixture_followup', source_id: randomUUID(), source_revision: 1, purpose: 'synthetic_check_in',
        owner_member_id: spare.member, supervisor_member_id: held.member, scope_kind: 'department_leader', scope_id: otherId,
        next_action: 'SYNTHETIC: phone and check in', due_at: churchTen(churchDate(9 * DAY)) });
      if (r.data?.task_id) b1Tasks.push(r.data.task_id);
    }
    const xRevoke = await envelope('identity_grant_command', admin.token, 'identity.revoke_scope', grantRevision(spare.member),
      { member_id: spare.member, scope_kind: 'department_deputy', scope_id: otherId });
    const ownedBy = (memberId) => Number(psql(`select count(*) from app.followups_tasks
      where task_id in (${b1Tasks.map((t) => `'${t}'`).join(',')}) and owner_member_id = '${memberId}'`));
    const leftWithX = psql(`select coalesce(string_agg(task_id::text, ','), '') from app.followups_tasks
      where task_id in (${b1Tasks.map((t) => `'${t}'`).join(',')}) and owner_member_id = '${spare.member}'`).split(',').filter(Boolean);
    const xOpens = leftWithX.length ? (await rpc('followups_task', spare.token, { p_task_id: leftWithX[0] })).status : null;
    const waiting = ((await read('followups_admin_routing', admin.token))?.handovers ?? [])
      .find((h) => h.member_id === spare.member);
    check('L26-a-revoked-scope-over-the-cap-is-visible-and-closed-to-the-former-owner',
      b1Grants.every((s) => s === 'done') && b1Tasks.length === 27 && done(xRevoke)
      && ownedBy(removed.member) >= 20 && ownedBy(removed.member) + leftWithX.length === 27 && leftWithX.length >= 2
      && xOpens === 403 && waiting?.tasks >= leftWithX.length,
      { grants: b1Grants, tasks: b1Tasks.length, revoke: xRevoke.code ?? 'done', handed_to_first_holder: ownedBy(removed.member),
        left_with_former_deputy: leftWithX.length, former_deputy_opens: xOpens, admin_sees_waiting: waiting?.tasks ?? null });
    // The Admin continues while O (the first candidate) is being deactivated in another connection.
    const oDeact = heldCall(admin, 'identity_lifecycle_command', 'identity.deactivate_membership', memberRevision(removed.member),
      { member_id: removed.member, reason_code: 'moved_away' }, 2.5);
    await pause(600);
    const more = await envelope('followups_command', admin.token, 'followups.complete_handover', null, { member_id: spare.member });
    const oHeld = await oDeact;
    const xOwners = psql(`select coalesce(string_agg(distinct owner_member_id::text, ','), '') from app.followups_tasks
      where task_id in (${leftWithX.map((t) => `'${t}'`).join(',')})`);
    check('L27-complete-handover-never-picks-a-member-being-deactivated', done(oHeld) && done(more)
      && more.data?.handed_over >= leftWithX.length && xOwners === leader.member,
      { deactivation: oHeld.code ?? 'done', complete_handover: more.code ?? 'done', handed_over: more.data?.handed_over ?? null,
        new_owner_is_the_next_holder: xOwners === leader.member,
        never_the_member_being_deactivated: !xOwners.includes(removed.member) });

    // ------------------------------------------------------- codes only; tables refused
    const auditCodes = psql(`select coalesce(string_agg(distinct action || ':' || coalesce(code, '-'), ',' order by action || ':' || coalesce(code, '-')), '')
      from app.duties_audit where action in ('assignment_vacated', 'member_removed') and department_id in ('${departmentId}', '${otherId}')`);
    const tableQuery = (await http('GET', '/rest/v1/duties_department_members?select=*', { token: leader.token, profile: 'app' })).status;
    check('L90-codes-only-tables-refused', auditCodes === 'assignment_vacated:member_left,assignment_vacated:removed,member_removed:-'
      && tableQuery >= 400,
      { audit: auditCodes.split(','), table_query: tableQuery });
  } finally {
    const left = cleanup();
    psql(`select app.sys_revoke_credential('${credentialId}', '${OPERATOR}'); select app.sys_disable_principal('${principal}', '${OPERATOR}');`);
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'duties-lifecycle-e2e';
            delete from app.platform_environment_history where set_by = 'duties-lifecycle-e2e';`);
    }
    log('L99-cleanup', { users_left: Number(left), credential_revoked: true, principal_disabled: true, unmarked: marked,
      departments_left: Number(psql(`select count(*) from app.duties_departments where name in ('${DEPARTMENT}', '${OTHER_DEPARTMENT}')`)),
      members_left: Number(psql(`select count(*) from app.identity_members where display_name like '${NAME_PREFIX}%'`)) });
  }
  finish();
}

runMain(import.meta.url, main);
