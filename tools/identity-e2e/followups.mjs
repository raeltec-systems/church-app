#!/usr/bin/env node
// Story 4.6 end-to-end on the LOCAL stack: the Follow-ups registry and My follow-ups, through real
// GoTrue phone sign-in (no SMS) and the real Data API (PostgREST), proving the ticket's verify at
// the API level with the SYNTHETIC source `fixture_followup`:
//   * an Admin creates `SYNTHETIC Preaching Rota` and makes a leader with identity.grant_scope;
//     the leader creates SYNTHETIC tasks for an ordinary app member M and an accountless member X;
//     a member without the scope cannot, and a second task for the same source and purpose is
//     refused;
//   * M sees My follow-ups (next action, minimal source context) and moves one task through In
//     progress, Waiting (with a review date; the original due date is kept) and Done, and closes
//     another (refused without a reason);
//   * owners come from the department roster only (an outsider is refused) and two concurrent
//     opens of one source make one task;
//   * the leader records an update for X (attributed to the leader, for X) and reassigns X's task
//     to member O, who then sees it; M cannot reassign;
//   * the Admin's routing view and task view carry no private notes, next action or context, and
//     an Admin cannot work a task; another member is refused; direct table queries are refused;
//     receipts hold no names or text.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900220-900229. Evidence is redacted JSONL:
// statuses, codes, counts; never tokens, passwords, numbers or note text. Every user, member,
// grant, department, task, activity, note and receipt it created is removed.
//
// Usage: node tools/identity-e2e/followups.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 4.6 E2E';
export const DEPARTMENT = 'SYNTHETIC Preaching Rota';
export const SOURCE_TYPE = 'fixture_followup';
export const PURPOSE = 'synthetic_check_in';

/** The reserved fictional numbers this run uses (+44 7700 900220-900229). */
export function isFictionalFollowupsPhone(phone) {
  return /^\+44770090022[0-9]$/.test(phone);
}

/** Keys the Admin routing view must never carry (private content). */
export const PRIVATE_KEYS = ['next_action', 'context', 'notes', 'latest_outcome', 'close_reason', 'source_id', 'activity'];

/** Does a routing task (or any object) carry a private key? */
export function hasPrivateKey(obj) {
  return obj != null && typeof obj === 'object' && PRIVATE_KEYS.some((k) => Object.hasOwn(obj, k));
}

/** A task of a list by id. */
export function findTask(list, taskId) {
  return (list ?? []).find((t) => t?.task_id === taskId) ?? null;
}

/** A refused direct table query: an error status and no rows in the body. */
export function refusedTableQuery(r) {
  return r.status >= 400 && !Array.isArray(r.json);
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
  const fu = (token, cmd, expected, payload, requestId) => envelope('followups_command', token, cmd, expected, payload, requestId);
  const read = async (fn, token, body = {}) => {
    const r = await rpc(fn, token, body);
    return { status: r.status, json: r.json, detail: r.json?.details ?? null };
  };
  const at = (ms) => new Date(Date.now() + ms).toISOString();
  const DAY = 86_400_000;

  const people = {
    admin: { phone: '+447700900220', name: `${NAME_PREFIX} Admin` },
    leader: { phone: '+447700900221', name: `${NAME_PREFIX} Leader` },
    member: { phone: '+447700900222', name: `${NAME_PREFIX} Member M` },
    other: { phone: '+447700900223', name: `${NAME_PREFIX} Member O` },
    plain: { phone: '+447700900224', name: `${NAME_PREFIX} Non-leader` },
  };
  for (const p of Object.values(people)) if (!isFictionalFollowupsPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
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
    -- Since story 4.7 tasks carry reminders (jobs, schedules, inbox items).
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
    psql(`select app.platform_set_environment('local', 'followups-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('F00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  try {
    const { admin, leader, member, other, plain } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'followups-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    // A member without a login (an approved member record only).
    const accountless = psql(`insert into app.identity_members (display_name, membership_state, is_synthetic)
      values ('${NAME_PREFIX} Accountless X', 'approved', true) returning member_id`);
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    check('F01-members-signed-in-by-phone', Object.values(people).every((p) => amrMethods(p.token).includes('password')),
      { amr: amrMethods(admin.token) });

    // --------------------------------------------------------- setup: department and leader scope
    const dept = await envelope('duties_command', admin.token, 'duties.create_department', null, { name: DEPARTMENT });
    const departmentId = dept.data?.department_id;
    const overview = (await read('duties_admin_overview', admin.token)).json;
    const grantsRev = overview?.members?.find((m) => m.member_id === leader.member)?.grants_revision;
    const grant = await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantsRev,
      { member_id: leader.member, scope_kind: 'department_leader', scope_id: departmentId });
    // The department's members: owners are chosen from its roster only (review S2).
    const added = [];
    for (const [i, id] of [member.member, other.member, accountless].entries()) {
      added.push((await envelope('duties_command', admin.token, 'duties.add_member', i + 1,
        { department_id: departmentId, member_id: id })).status);
    }
    const supervision = await read('followups_supervision', leader.token);
    const purpose = supervision.json?.purposes?.find((p) => p.source_type === SOURCE_TYPE && p.purpose === PURPOSE);
    const scope = supervision.json?.scopes?.find((s) => s.scope_id === departmentId);
    const roster = (scope?.candidates ?? []).map((c) => c.member_id);
    const xCandidate = scope?.candidates?.find((c) => c.member_id === accountless);
    check('F02-leader-scope-roster-and-synthetic-purpose', dept.status === 200 && grant.status === 200
      && added.every((x) => x === 200) && supervision.status === 200 && Boolean(purpose)
      && scope?.family === 'department' && xCandidate?.account === 'no_login'
      && roster.includes(member.member) && roster.includes(other.member) && !roster.includes(plain.member)
      && !roster.includes(admin.member),
      { department: dept.status, grant: grant.status, members_added: added, supervision: supervision.status,
        purpose: Boolean(purpose), family: scope?.family ?? null, roster_size: roster.length,
        outsider_in_roster: roster.includes(plain.member), accountless_label: xCandidate?.account ?? null });

    // ------------------------------------------------------------------------------ creating
    const draft = (owner, sourceId, extra = {}) => ({
      source_type: SOURCE_TYPE, source_id: sourceId, source_revision: 1, purpose: PURPOSE,
      owner_member_id: owner, scope_kind: 'department_leader', scope_id: departmentId,
      next_action: 'SYNTHETIC: phone and check in', due_at: at(3 * DAY), ...extra,
    });
    const sources = { a: randomUUID(), b: randomUUID(), x: randomUUID() };
    const byPlain = await fu(plain.token, 'followups.create_task', null, draft(member.member, sources.a));
    const createRequest = randomUUID();
    const draftA = draft(member.member, sources.a);
    const taskA = await fu(leader.token, 'followups.create_task', null, draftA, createRequest);
    const replay = await fu(leader.token, 'followups.create_task', null, draftA, createRequest);
    const dup = await fu(leader.token, 'followups.create_task', null, draft(other.member, sources.a));
    const taskB = await fu(leader.token, 'followups.create_task', null, draft(member.member, sources.b));
    const taskX = await fu(leader.token, 'followups.create_task', null,
      draft(accountless, sources.x, { note: 'SYNTHETIC note: prefers a call after work' }));
    const ids = { a: taskA.data?.task_id, b: taskB.data?.task_id, x: taskX.data?.task_id };
    // Two leaders' clients open the same source at once: exactly one task (review N10).
    const raceSource = randomUUID();
    const race = await Promise.all([0, 1].map(() =>
      fu(leader.token, 'followups.create_task', null, draft(other.member, raceSource))));
    const raceTasks = Number(psql(`select count(*) from app.followups_tasks where source_id = '${raceSource}'`));
    check('F11-concurrent-open-makes-one-task', raceTasks === 1
      && race.filter((r) => r.data?.state === 'open').length === 1
      && race.filter((r) => r.code === 'conflict' && r.field_errors?.purpose === 'task_exists').length === 1,
      { answers: race.map((r) => r.code ?? r.status), fields: race.map((r) => r.field_errors ?? null), tasks: raceTasks });
    const outsider = await fu(leader.token, 'followups.create_task', null, draft(plain.member, randomUUID()));
    check('F12-owner-outside-the-roster-refused', outsider.code === 'validation_failed'
      && outsider.field_errors?.owner_member_id === 'not_in_scope',
      { code: outsider.code, field: outsider.field_errors?.owner_member_id ?? null });
    check('F10-leader-creates-synthetic-tasks', byPlain.code === 'forbidden' && taskA.status === 200
      && taskA.data?.state === 'open' && JSON.stringify(replay.data) === JSON.stringify(taskA.data)
      && dup.code === 'conflict' && dup.field_errors?.purpose === 'task_exists'
      && taskB.status === 200 && taskX.status === 200,
      { non_leader: byPlain.code, created: [taskA.status, taskB.status, taskX.status], replay_same: JSON.stringify(replay.data) === JSON.stringify(taskA.data),
        duplicate: `${dup.code}:${dup.field_errors?.purpose}` });

    // ------------------------------------------------------------------------------ My follow-ups
    const mine = (await read('followups_my_tasks', member.token)).json;
    const a0 = findTask(mine?.tasks, ids.a);
    check('F20-owner-sees-my-follow-ups', mine?.tasks?.length === 2 && a0?.state === 'open'
      && a0?.next_action === 'SYNTHETIC: phone and check in' && a0?.context?.label === 'SYNTHETIC check-in source'
      && a0?.capacity === 'owner' && a0?.can_update === true && a0?.can_reassign === false,
      { tasks: mine?.tasks?.length, state: a0?.state, context: a0?.context?.label ?? null, capacity: a0?.capacity });

    const update = (token, id, revision, payload, requestId) => fu(token, 'followups.update_task', revision, { task_id: id, ...payload }, requestId);
    const s1 = await update(member.token, ids.a, 1, { status: 'in_progress' });
    const noReview = await update(member.token, ids.a, s1.revision, { status: 'waiting' });
    const s2 = await update(member.token, ids.a, s1.revision, { status: 'waiting', review_at: at(5 * DAY) });
    const waiting = findTask((await read('followups_my_tasks', member.token)).json?.tasks, ids.a);
    const s3 = await update(member.token, ids.a, s2.revision, { status: 'done', outcome: 'contacted' });
    const after = await update(member.token, ids.a, s3.revision, { status: 'in_progress' });
    check('F21-owner-moves-a-task-through-every-state', s1.data?.state === 'in_progress'
      && noReview.code === 'validation_failed' && noReview.field_errors?.review_at === 'required'
      && s2.data?.state === 'waiting' && waiting?.due_at === a0?.due_at && Boolean(waiting?.review_at)
      && waiting?.review_at > waiting?.due_at && s3.data?.state === 'done'
      && after.code === 'conflict' && after.field_errors?.task_id === 'finished',
      { states: [s1.data?.state, s2.data?.state, s3.data?.state], waiting_without_review: noReview.field_errors?.review_at,
        due_kept: waiting?.due_at === a0?.due_at, review_after_due: waiting?.review_at > waiting?.due_at, after_done: after.field_errors?.task_id });
    const noReason = await update(member.token, ids.b, 1, { status: 'closed' });
    const closed = await update(member.token, ids.b, 1, { status: 'closed', close_reason: 'SYNTHETIC: no longer needed' });
    check('F22-closing-needs-a-reason', noReason.code === 'validation_failed' && noReason.field_errors?.close_reason === 'required'
      && closed.data?.state === 'closed',
      { without_reason: `${noReason.code}:${noReason.field_errors?.close_reason}`, closed: closed.data?.state });

    // --------------------------------------------------- the leader works for the accountless owner
    const forX = await update(leader.token, ids.x, 1, { outcome: 'contacted', note: 'SYNTHETIC note: reached by phone' });
    const xDetail = (await read('followups_task', leader.token, { p_task_id: ids.x })).json;
    const recorded = xDetail?.activity?.find((e) => e.action === 'outcome_recorded');
    check('F30-leader-records-an-update-for-an-accountless-owner', forX.status === 200 && recorded?.capacity === 'supervisor'
      && recorded?.actor === leader.name && recorded?.on_behalf_of === `${NAME_PREFIX} Accountless X`
      && xDetail?.notes?.length === 2 && xDetail?.notes?.every((n) => n.on_behalf_of === `${NAME_PREFIX} Accountless X`),
      { status: forX.status, capacity: recorded?.capacity, attributed: recorded?.actor === leader.name,
        for_owner: recorded?.on_behalf_of === `${NAME_PREFIX} Accountless X`, notes: xDetail?.notes?.length });
    const byOwner = await fu(member.token, 'followups.reassign', forX.revision, { task_id: ids.a, owner_member_id: other.member });
    const reassigned = await fu(leader.token, 'followups.reassign', forX.revision, { task_id: ids.x, owner_member_id: other.member });
    const otherMine = (await read('followups_my_tasks', other.token)).json;
    check('F31-leader-reassigns-and-the-owner-cannot', byOwner.code === 'forbidden' && reassigned.status === 200
      && findTask(otherMine?.tasks, ids.x)?.capacity === 'owner',
      { owner_attempt: byOwner.code, reassigned: reassigned.status, new_owner_sees_it: Boolean(findTask(otherMine?.tasks, ids.x)) });
    const formerOwner = await fu(member.token, 'followups.reassign', reassigned.revision, { task_id: ids.x, owner_member_id: member.member });
    check('F32-an-unrelated-member-sees-nothing', formerOwner.code === 'not_found', { reassign_attempt: formerOwner.code });

    // ------------------------------------------------------------------------------ Admin routing
    const routing = await read('followups_admin_routing', admin.token);
    const routed = (routing.json?.tasks ?? []).filter((t) => [ids.a, ids.b, ids.x].includes(t.task_id));
    const adminView = (await read('followups_task', admin.token, { p_task_id: ids.x })).json;
    const adminWork = await update(admin.token, ids.x, reassigned.revision, { note: 'SYNTHETIC: admin' });
    check('F40-admin-sees-routing-metadata-only', routing.status === 200 && routed.length === 3
      && routed.every((t) => !hasPrivateKey(t) && t.owner?.display_name && t.state && t.due_at)
      && !Object.hasOwn(routing.json ?? {}, 'candidates')
      && (routing.json?.scopes ?? []).every((s) => s.candidates.every((c) => c.member_id !== plain.member))
      && adminView?.view === 'routing' && !hasPrivateKey(adminView) && !hasPrivateKey(adminView?.task)
      && adminWork.code === 'forbidden',
      { routed: routed.length, private_keys: routed.filter(hasPrivateKey).length, view: adminView?.view, admin_update: adminWork.code });
    const byPlainRead = await read('followups_task', plain.token, { p_task_id: ids.x });
    const plainSupervision = await read('followups_supervision', plain.token);
    const memberRouting = await read('followups_admin_routing', member.token);
    check('F41-others-are-refused', byPlainRead.status === 403 && byPlainRead.detail === 'not_granted'
      && plainSupervision.status === 403 && memberRouting.status === 403,
      { task: byPlainRead.status, supervision: plainSupervision.status, routing: memberRouting.status });

    // -------------------------------------------------------------- direct tables and receipts
    const tables = [];
    for (const t of ['followups_tasks', 'followups_notes', 'followups_activity', 'followups_purposes']) {
      for (const profile of ['app', 'api']) {
        const r = await http('GET', `/rest/v1/${t}?select=*`, { token: member.token, profile });
        tables.push({ t, profile, status: r.status, refused: refusedTableQuery(r) });
      }
    }
    const rpcOp = await http('POST', '/rest/v1/rpc/followups_open_task', { token: leader.token, profile: 'app', body: { p_input: {} } });
    check('F50-direct-table-queries-refused', tables.every((x) => x.refused) && rpcOp.status >= 400,
      { statuses: tables.map((x) => `${x.profile}.${x.t}:${x.status}`), owner_operation: rpcOp.status });
    const receiptText = Number(psql(`select count(*) from app.cmd_receipts where command like 'followups.%'
      and (result::text like '%${NAME_PREFIX}%' or result::text like '%SYNTHETIC note%' or result::text like '%SYNTHETIC: phone%')`));
    const activityCols = psql(`select string_agg(column_name, ',' order by column_name) from information_schema.columns
      where table_schema = 'app' and table_name = 'followups_activity' and data_type = 'text'`);
    check('F51-receipts-and-activity-hold-no-text', receiptText === 0
      && activityCols === 'action,actor_capacity,code,environment,from_state,outcome,to_state',
      { receipts_with_text: receiptText, activity_text_columns: activityCols });
  } finally {
    const left = cleanup();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'followups-e2e';
            delete from app.platform_environment_history where set_by = 'followups-e2e';`);
    }
    log('F99-cleanup', { users_left: Number(left), unmarked: marked,
      tasks_left: Number(psql(`select count(*) from app.followups_tasks t join app.identity_members m on m.member_id = t.owner_member_id
                               where m.display_name like '${NAME_PREFIX}%'`)),
      departments_left: Number(psql(`select count(*) from app.duties_departments where name = '${DEPARTMENT}'`)) });
  }
  finish();
}

runMain(import.meta.url, main);
