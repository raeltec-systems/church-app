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
//     Follow-ups deletion check answers zero after the erase phase.
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
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
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
  const credential = `sysc_local_${randomBytes(32).toString('base64url')}`;
  const principal = psql(`select app.sys_create_principal('notifications-worker-lifecycle-${run}', 'notifications_worker', '${OPERATOR}')`);
  const credentialId = JSON.parse(psql(`select app.sys_register_credential('${principal}',
    '${createHash('sha256').update(credential).digest('hex')}', 'duties lifecycle e2e ${run}', interval '2 hours', '${OPERATOR}')`)).credential_id;
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
    check('L21-the-open-task-is-handed-to-its-supervisor', taskOwner(t1) === leader.member
      && pendingObligations(member.member) === 0
      && psql(`select action || ':' || actor_capacity || ':' || code from app.followups_activity where task_id = '${t1}'
           order by activity_id desc limit 1`) === 'reassigned:source:handover',
      { owner_is_supervisor: taskOwner(t1) === leader.member, pending_obligations: pendingObligations(member.member) });
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
