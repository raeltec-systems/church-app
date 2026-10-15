#!/usr/bin/env node
// Story 4.13: the synthetic department pilot rehearsal. It runs the whole duties loop with
// `SYNTHETIC Preaching Rota`, an app member (M), a second app member (O) and an accountless member
// (X, with a labelled household number), through the public API only (Auth and the Data API):
//
//   P10 a quarterly rota (13 Sundays, Preacher and Reader) is generated and published
//   P20 reminders are queued and the worker delivers them (M's New duty assigned; X on Needs contact)
//   P30 answers: M accepts, O says they can't make it (with a note)
//   P40 the gap is visible in Coverage (unfilled, declined, needs contact)
//   P50 a direct contact attempt on X (opens the follow-up task)
//   P60 Confirmed by leader for X (labelled as the leader's, its task closes)
//   P70 a short-notice Sunday assignment (no answer-by time: Short notice, leaders alerted)
//   P80 reassignment: a reminder falling due after the change reaches the new person only
//   P90 nothing private (leader notes, attempt notes, reasons, numbers) reaches a non-leader
//   P98 cleanup through the API (duties cancelled, members removed, leader scope revoked)
//
// Two targets, chosen explicitly (`--target local|staging` or DUTIES_PILOT_TARGET; default local):
//
//   local    the local stack (exact origin http://127.0.0.1:54321). Personas are made with the
//            local Auth admin route and the synthetic seed link, the run's own worker credential
//            drives tools/notifications/worker.mjs, a few extra checks read the job tables, the
//            P80 reminder is moved forward with SQL (test-only), and everything is deleted at the
//            end. Needs `node tools/auth-harness/local-phone-auth.mjs on` and a database with no
//            usable Admin (`npx supabase db reset` first). Fictional numbers +44 7700 900410-900419.
//   staging  the hosted staging project only (https://tmurpotfluignacfueki.supabase.co), with the
//            publishable key and synthetic accounts: no secret or service-role key and no SQL.
//            Personas (+1 202 555 0166-0168) sign up, apply and are approved by the synthetic
//            Admin (+1 202 555 0150) once, then are reused from a state file kept OUTSIDE the
//            repository (mode 0600). The scheduled worker delivers (the run polls). The API cleanup
//            runs at the end; `--cleanup-sql <file>` writes the SQL that removes the run's rows.
//
// Evidence is redacted JSONL (statuses, codes, counts, states): never a token, password, number,
// name, note or reason.
//
// Usage:
//   node tools/identity-e2e/duties-pilot.mjs [--evidence <file.jsonl>]
//   DUTIES_PILOT_TARGET=staging STAGING_PUBLISHABLE_KEY=sb_publishable_... \
//   STAGING_SUITE_ADMIN=/outside/repo/admin.json DUTIES_PILOT_STATE=/outside/repo/duties-pilot-state.json \
//   node tools/identity-e2e/duties-pilot.mjs --evidence <file.jsonl> --cleanup-sql <file.sql>
import { execFile } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { appendFileSync, existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { EPOCH_WAIT_MS, amrMethods, localHttp, localKey, psql, sleep } from './harness.mjs';
import { genericItemCheck } from './duties-shared.mjs';
import {
  ADMIN_PHONE, STAGING_ORIGIN, assertPublishableKey, assertStagingOrigin, assertStateOutsideRepo, redactEvidence,
} from './staging-suite.mjs';

export { churchInstant } from './duties-shared.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const OPERATOR = 'israel';
export const DEPARTMENT = 'SYNTHETIC Preaching Rota';
export const NAME_PREFIX = 'SYNTHETIC Pilot';
/** Leader-only texts carry this marker, so a leak to a non-leader is detectable. */
export const LEADER_ONLY = 'SYNTHETIC leader-only';
export const MINUTE = 60_000;
export const HOUR = 60 * MINUTE;
export const DAY = 24 * HOUR;
/** Africa/Lusaka is UTC+2 all year (owner decision Q2). */
const CHURCH_OFFSET = 2 * HOUR;

/** The fictional numbers of each target. */
export const NUMBERS = {
  local: { admin: '+447700900410', leader: '+447700900411', member: '+447700900412', other: '+447700900413',
    household: '+447700900419' },
  staging: { admin: ADMIN_PHONE, leader: '+12025550166', member: '+12025550167', other: '+12025550168',
    household: '+12025550159' },
};

/** Is `phone` in the reserved pilot block of `target`? */
export function isPilotPhone(target, phone) {
  if (target === 'local') return /^\+44770090041[0-9]$/.test(phone);
  if (target === 'staging') return /^\+1202555015[09]$|^\+120255501(66|67|68)$/.test(phone);
  return false;
}

/** The run's target: `--target` or DUTIES_PILOT_TARGET, default local; anything else is refused. */
export function parseTarget(argv = [], env = {}) {
  const i = argv.indexOf('--target');
  const flag = i >= 0 ? argv[i + 1] : undefined;
  const fromEnv = env.DUTIES_PILOT_TARGET || undefined;
  if (flag !== undefined && fromEnv !== undefined && flag !== fromEnv) {
    throw new Error(`--target ${flag} and DUTIES_PILOT_TARGET=${fromEnv} disagree`);
  }
  const target = flag ?? fromEnv ?? 'local';
  if (target !== 'local' && target !== 'staging') throw new Error(`unknown target ${target}: use local or staging`);
  return target;
}

/** The value after `flag` in argv, or null. */
export function argValue(argv, flag) {
  const i = argv.indexOf(flag);
  return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : null;
}

/** The church-local date (YYYY-MM-DD) of an instant. */
export function churchDate(ms) {
  return new Date(ms + CHURCH_OFFSET).toISOString().slice(0, 10);
}

/** A church-local date plus `n` days. */
export function addDays(date, n) {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

/** The first Sunday (church calendar) on or after the church date `minDays` from now. */
export function nextSunday(nowMs, minDays) {
  const date = churchDate(nowMs + minDays * DAY);
  const weekday = new Date(`${date}T00:00:00Z`).getUTCDay();
  return addDays(date, (7 - weekday) % 7);
}

/** An instant rounded up to the next whole minute, as UTC RFC3339. */
export function minuteCeil(ms) {
  return new Date(Math.ceil(ms / MINUTE) * MINUTE).toISOString();
}

/** The quarterly rota: 13 weekly Sundays from the first Sunday at least three days away, 10:00. */
export function quarterlyRota(nowMs) {
  const from = nextSunday(nowMs, 3);
  return { from_date: from, until_date: addDays(from, 84), start_time: '10:00', sundays: 13,
    positions: ['Preacher', 'Reader'] };
}

/** The short-notice duty: three hours from now (less than an hour is left to answer by default). */
export function shortNoticeStart(nowMs) {
  return minuteCeil(nowMs + 3 * HOUR);
}

/**
 * The reassignment probe: a duty two days away whose creator-set answer-by time is 15 minutes away
 * and whose only reminder is 10 minutes before it, so the reminder falls due about five minutes
 * after the run reassigns the duty.
 */
export function probePlan(nowMs) {
  const deadline = minuteCeil(nowMs + 15 * MINUTE);
  return { starts_at: minuteCeil(nowMs + 2 * DAY), response_deadline: deadline,
    reminders: [{ anchor: 'response_deadline', before: '10 minutes' }],
    due_at: new Date(Date.parse(deadline) - 10 * MINUTE).toISOString() };
}

/** The fixed generic texts (title / body) of the kinds a pilot member or leader may receive. */
export const GENERIC_TEXT = {
  duty_assigned: ['New duty assigned', 'You have a new duty. Open it to accept or say you cannot make it.'],
  duty_changed: ['Duty changed', 'One of your duties changed. Open it to see what changed and answer again.'],
  duty_released: ['Duty changed', 'A duty you were given has changed and is no longer assigned to you.'],
  duty_cancelled: ['Duty cancelled', 'One of your duties was cancelled. Open My duties to see what is still yours.'],
  duty_response_due: ['Duty answer needed', 'One of your duties is waiting for your answer. Open it to accept or say you cannot make it.'],
  duty_starting: ['Duty coming up', 'One of your duties is coming up soon. Open it to see the details.'],
  duty_declined: ['Duty declined', 'A member cannot make a duty in your department. Open Coverage to find cover.'],
  duty_short_notice: ['Short-notice duty', 'A duty in your department was given at short notice and needs an answer now. Contact the member directly.'],
  duty_response_overdue: ['Duty answer overdue', 'A duty in your department passed its answer-by time without an answer. Open Duties to follow it up.'],
  followup_assigned: ['New follow-up task', 'A follow-up task was assigned to you. Open it to see the next action.'],
};

/** An inbox item that carries exactly the generic text of its reminder kind. */
export const isGenericItem = genericItemCheck(GENERIC_TEXT);

const NUMBER_PATTERN = /\+?447700900\d{3}|\+?1202555\d{4}/;
/** Does any JSON hold a leader-only text or a fictional contact number? */
export function leaksLeaderText(value) {
  const json = JSON.stringify(value ?? {});
  return json.includes(LEADER_ONLY) || NUMBER_PATTERN.test(json);
}

/** Does a coverage answer hold anything private (a route, a number, a note, a reason, a task link)? */
export function holdsPrivate(coverage) {
  if (leaksLeaderText(coverage) || JSON.stringify(coverage ?? {}).includes('SYNTHETIC member note')) return true;
  for (const d of coverage?.departments ?? []) {
    if (Object.keys(d.contact_routes ?? {}).length > 0) return true;
    for (const p of d.positions ?? []) {
      if (p.assignment?.note || p.assignment?.confirmation?.reason || p.follow_up?.last_attempt?.note
          || p.follow_up?.task_id) return true;
    }
  }
  return false;
}

/** The coverage position of an assignment (or slot) id. */
export function positionOf(coverage, id) {
  for (const d of coverage?.departments ?? []) {
    for (const p of d.positions ?? []) {
      if (p.assignment?.assignment_id === id || p.slot_id === id) return p;
    }
  }
  return null;
}

/** The leader board position of an assignment (or slot) id, with its duty. */
export function boardPositionOf(board, id) {
  for (const d of board?.departments ?? []) {
    for (const duty of d.duties ?? []) {
      for (const p of duty.positions ?? []) {
        if (p.assignment?.assignment_id === id || p.slot_id === id) return { duty, position: p };
      }
    }
  }
  return null;
}

/** Inbox items that were not in `baseline` (a Set of item ids seen before), optionally of one kind. */
export function itemsNew(items, baseline, kind) {
  return (items ?? []).filter((i) => !baseline.has(i.item_id) && (!kind || i.reminder_kind === kind));
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const uuidList = (ids) => {
  const list = [...new Set((ids ?? []).filter(Boolean))];
  for (const id of list) if (!UUID.test(id)) throw new Error('cleanup ids must be uuids');
  return list.length ? list.map((id) => `'${id}'`).join(', ') : 'null';
};

/**
 * The SQL that removes a staging run's remaining rows (the parent session runs it in the staging
 * SQL editor or through its connector, after the API cleanup). Only the run's series, occurrences
 * and the department memberships of its members are named; personas and the Admin are kept. The
 * department and its scope grants go only when this run created the department.
 */
export function stagingCleanupSql({ departmentId, seriesIds = [], occurrenceIds = [], memberIds = [], removeDepartment = false }) {
  if (!UUID.test(departmentId ?? '')) throw new Error('cleanup needs the department id');
  const dept = `'${departmentId}'`;
  const series = uuidList(seriesIds);
  const occurrences = uuidList(occurrenceIds);
  const members = uuidList(memberIds);
  const lines = [
    '-- Story 4.13 pilot rehearsal: remove one staging run\'s rows (SYNTHETIC data only).',
    'begin;',
    `create temp table pilot_occurrences on commit drop as
  select o.occurrence_id from app.duties_occurrences o
   where o.department_id = ${dept}
     and (o.occurrence_id in (${occurrences}) or o.series_id in (${series}));`,
    `create temp table pilot_assignments on commit drop as
  select a.assignment_id from app.duties_assignments a join app.duties_slots s on s.slot_id = a.slot_id
   where s.occurrence_id in (select occurrence_id from pilot_occurrences);`,
    `create temp table pilot_tasks on commit drop as
  select t.task_id from app.followups_tasks t
   where t.source_type = 'duties_coverage_case'
     and t.source_id in (select c.case_id from app.duties_coverage_cases c
                          where c.assignment_id in (select assignment_id from pilot_assignments));`,
    `create temp table pilot_jobs on commit drop as
  select j.job_id from app.notifications_jobs j
   where j.source_id in (select assignment_id from pilot_assignments)
      or j.source_id in (select task_id from pilot_tasks);`,
    'delete from app.notifications_attempts a where a.job_id in (select job_id from pilot_jobs);',
    'delete from app.notifications_direct_contact_needs n where n.job_id in (select job_id from pilot_jobs);',
    'delete from app.notifications_push_jobs p where p.job_id in (select job_id from pilot_jobs);',
    'update app.notifications_jobs j set snoozed_from_item_id = null where j.job_id in (select job_id from pilot_jobs);',
    'delete from app.notifications_inbox_items i where i.job_id in (select job_id from pilot_jobs);',
    'delete from app.notifications_jobs j where j.job_id in (select job_id from pilot_jobs);',
    `delete from app.notifications_schedules s where s.source_id in (select assignment_id from pilot_assignments)
   or s.source_id in (select task_id from pilot_tasks);`,
    'delete from app.followups_notes n where n.task_id in (select task_id from pilot_tasks);',
    'delete from app.followups_activity a where a.task_id in (select task_id from pilot_tasks);',
    'delete from app.followups_tasks t where t.task_id in (select task_id from pilot_tasks);',
    'delete from app.duties_contact_attempts t where t.assignment_id in (select assignment_id from pilot_assignments);',
    'delete from app.duties_coverage_cases c where c.assignment_id in (select assignment_id from pilot_assignments);',
    'delete from app.duties_contact_needs n where n.assignment_id in (select assignment_id from pilot_assignments);',
    'delete from app.duties_audit a where a.occurrence_id in (select occurrence_id from pilot_occurrences);',
    'delete from app.duties_slot_revisions r where r.occurrence_id in (select occurrence_id from pilot_occurrences);',
    'delete from app.duties_assignments a where a.assignment_id in (select assignment_id from pilot_assignments);',
    'delete from app.duties_slots s where s.occurrence_id in (select occurrence_id from pilot_occurrences);',
    'delete from app.duties_occurrences o where o.occurrence_id in (select occurrence_id from pilot_occurrences);',
    `delete from app.duties_series r where r.department_id = ${dept} and r.series_id in (${series});`,
    `delete from app.duties_department_members dm where dm.department_id = ${dept} and dm.member_id in (${members})
   and dm.ended_at is not null;`,
  ];
  if (removeDepartment) {
    lines.push(
      `delete from app.duties_audit a where a.department_id = ${dept};`,
      `delete from app.duties_department_members dm where dm.department_id = ${dept};`,
      `delete from app.identity_grants g where g.scope_id = ${dept} and g.scope_kind in ('department_leader', 'department_deputy');`,
      `delete from app.duties_departments d where d.department_id = ${dept};`,
    );
  }
  lines.push('commit;', '');
  return lines.join('\n');
}

// ---------------------------------------------------------------------------------------- run
async function main() {
  const argv = process.argv;
  const target = parseTarget(argv, process.env);
  const evidence = argValue(argv, '--evidence');
  const cleanupSqlPath = argValue(argv, '--cleanup-sql');
  // Local only: take the staging route (sign-up, application, approval, no job-table checks, a real
  // wait for the P80 reminder, the staging cleanup SQL executed and verified) against the local stack.
  const stagingPath = target === 'local' && argv.includes('--staging-path');
  const sqlChecks = target === 'local' && !stagingPath;
  const numbers = NUMBERS[target];
  for (const phone of Object.values(numbers)) if (!isPilotPhone(target, phone)) throw new Error(`not fictional: ${phone}`);

  // ---- evidence (redacted; never a token, password, number, name, note or reason)
  if (evidence) writeFileSync(evidence, '');
  const results = [];
  const log = (step, data = {}) => {
    const line = { step, target: target.toUpperCase(), at: new Date().toISOString(), ...redactEvidence(data) };
    if (evidence) appendFileSync(evidence, JSON.stringify(line) + '\n');
    console.log(JSON.stringify(line));
  };
  const check = (step, ok, data = {}) => {
    results.push({ step, ok: Boolean(ok) });
    log(step, { verdict: ok ? 'pass' : 'FAIL', ...data });
    return Boolean(ok);
  };

  // ---- HTTP: the local stack (exact origin) or the staging project (publishable key only)
  let http;
  let origin;
  let publishableKey;
  let state = null;
  let saveState = () => {};
  if (target === 'local') {
    const keys = localKey();
    origin = keys.origin;
    publishableKey = keys.key;
    http = localHttp(keys);
    state = { personas: {} };
  } else {
    origin = assertStagingOrigin(STAGING_ORIGIN);
    publishableKey = assertPublishableKey(process.env.STAGING_PUBLISHABLE_KEY);
    const adminFile = assertStateOutsideRepo(process.env.STAGING_SUITE_ADMIN);
    const statePath = assertStateOutsideRepo(process.env.DUTIES_PILOT_STATE);
    if (cleanupSqlPath) assertStateOutsideRepo(cleanupSqlPath);
    state = existsSync(statePath) ? JSON.parse(readFileSync(statePath, 'utf8')) : {};
    state.personas ??= {};
    state.admin = { pw: JSON.parse(readFileSync(adminFile, 'utf8')).pw };
    if (!state.admin.pw) throw new Error('STAGING_SUITE_ADMIN has no pw');
    saveState = () => {
      const { admin, ...kept } = state;
      const tmp = `${statePath}.tmp`;
      writeFileSync(tmp, JSON.stringify(kept), { mode: 0o600 });
      renameSync(tmp, statePath);
    };
    saveState();
    http = async (method, path, { token, body, profile } = {}) => {
      const headers = { apikey: publishableKey, 'Content-Type': 'application/json' };
      if (token) headers.Authorization = `Bearer ${token}`;
      if (profile) headers[method === 'GET' ? 'Accept-Profile' : 'Content-Profile'] = profile;
      for (let attempt = 0; ; attempt += 1) {
        const res = await fetch(`${origin}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
        const text = await res.text();
        let json = null;
        try { json = text ? JSON.parse(text) : null; } catch { /* non-JSON */ }
        if (res.status === 429 && path.startsWith('/auth/') && attempt < 5) {
          log('auth-rate-limited-waiting', { attempt });
          await sleep(60_000);
          continue;
        }
        return { status: res.status, json };
      }
    };
  }
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const read = async (fn, token, body = {}) => (await rpc(fn, token, body)).json;
  const envelope = (fn, token, cmd, expected, payload) =>
    rpc(fn, token, { version: 1, command: cmd, request_id: randomUUID(), expected_revision: expected ?? null, payload })
      .then((r) => ({ status: r.status, ...(r.json ?? {}) }));
  const duty = (p, cmd, expected, payload) => envelope('duties_command', p.token, cmd, expected, payload);
  const outcome = (r) => (r?.code ? { code: r.code, field_errors: r.field_errors ?? null } : { status: r?.status });

  // ---- the people
  const people = {
    admin: { phone: numbers.admin, name: `${NAME_PREFIX} Admin` },
    leader: { phone: numbers.leader, name: `${NAME_PREFIX} Leader L` },
    member: { phone: numbers.member, name: `${NAME_PREFIX} Member M` },
    other: { phone: numbers.other, name: `${NAME_PREFIX} Member O` },
  };
  const accountless = { name: `${NAME_PREFIX} Accountless X` };
  const users = new Set();
  const run = { seriesIds: [], occurrenceIds: [], departmentId: null, createdDepartment: false, leaderGranted: false };

  // ---- local only: SQL cleanup, environment marker, worker credential
  let marked = false;
  let credential = null;
  let credentialId = null;
  let principal = null;
  const localCleanup = () => {
    const ids = [...users].map((u) => `'${u}'`);
    const byUser = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    const digits = Object.values(numbers).map((p) => `'${p.slice(1)}'`).join(',');
    return psql(`
    create temp table gone_users as select u.id from auth.users u where ${byUser} u.phone in (${digits});
    create temp table gone_members as
      select m.member_id from app.identity_members m where m.display_name like '${NAME_PREFIX}%';
    create temp table gone_apps as
      select a.application_id from app.identity_membership_applications a
       where a.auth_user_id in (select id from gone_users) or a.full_name like '${NAME_PREFIX}%';
    create temp table gone_departments as
      select d.department_id from app.duties_departments d where d.name = '${DEPARTMENT}';
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
    delete from app.identity_membership_audit a
     where a.application_id in (select application_id from gone_apps)
        or a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members)
        or a.target_account_id in (select id from gone_users);
    delete from app.identity_member_provenance p
     where p.member_id in (select member_id from gone_members) or p.recorded_by_member in (select member_id from gone_members)
        or p.application_id in (select application_id from gone_apps);
    delete from app.identity_application_events e where e.application_id in (select application_id from gone_apps);
    delete from app.identity_membership_applications a where a.application_id in (select application_id from gone_apps);
    delete from app.identity_access_audit a
     where a.target_member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_grants g where g.member_id in (select member_id from gone_members)
       or g.scope_id in (select department_id from gone_departments);
    delete from app.duties_departments d where d.department_id in (select department_id from gone_departments);
    delete from app.identity_contact_routes r
     where r.member_id in (select member_id from gone_members) or r.created_by_member in (select member_id from gone_members);
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
  const worker = async () => {
    try {
      const { stdout } = await promisify(execFile)('node', [join(ROOT, 'tools/notifications/worker.mjs'), 'run-once'], {
        encoding: 'utf8',
        env: { PATH: process.env.PATH, SUPABASE_URL: origin, SUPABASE_PUBLISHABLE_KEY: publishableKey,
          NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL: credential } });
      const line = stdout.split('\n').find((l) => l.startsWith('{'));
      return { exit: 0, ...(line ? JSON.parse(line) : {}) };
    } catch (e) {
      return { exit: e.code ?? 1, error: String(e.stderr ?? '').trim().slice(-160) };
    }
  };
  /** Local: the worker runs now. Staging: the scheduled worker runs every minute; wait for it. */
  const settle = async (done, { timeoutMs = 4 * MINUTE } = {}) => {
    const until = Date.now() + timeoutMs;
    for (let round = 0; ; round += 1) {
      if (target === 'local') await worker();
      const value = await done();
      if (value) return value;
      if (target === 'local' ? round >= 2 : Date.now() > until) return value;
      await sleep(target === 'staging' ? 15_000 : 1000);
    }
  };

  // ---- reads and helpers (API only, both targets)
  const inbox = async (p) => (await read('notifications_my_inbox', p.token))?.items ?? [];
  const seen = async (p) => new Set((await inbox(p)).map((i) => i.item_id));
  const openItem = async (p, itemId) => (await rpc('notifications_open_item', p.token, { item_id: itemId })).json;
  const overview = async () => read('duties_admin_overview', people.admin.token);
  const departmentRevision = async () => ((await overview())?.departments ?? [])
    .find((d) => d.department_id === run.departmentId)?.revision;
  const grantsRevision = async (memberId) => {
    let after = {};
    for (let page = 0; page < 40; page += 1) {
      const r = await read('identity_admin_member_grants', people.admin.token, after);
      const hit = (r?.members ?? []).find((m) => m.member_id === memberId);
      if (hit) return { revision: hit.grants?.revision, scopes: hit.grants?.scopes ?? [] };
      if (!r?.next) return null;
      after = { after_display_name: r.next.after_display_name, after_member_id: r.next.after_member_id };
    }
    return null;
  };
  const rotaSeries = async (seriesId) => {
    const r = await read('duties_rota', people.leader.token);
    for (const d of r?.departments ?? []) for (const s of d.series ?? []) if (s.series_id === seriesId) return s;
    return null;
  };
  const myDuties = async (p) => read('duties_my_duties', p.token);
  const myAssignment = async (p, id) => ((await myDuties(p))?.assignments ?? []).find((a) => a.assignment_id === id);
  const board = async (p) => read('duties_leader_board', p.token);
  const coverage = async (p, body) => rpc('duties_coverage', p.token, body);

  // ---- local SQL checks (job tables; never on staging)
  const roleOf = (memberId) => (Object.entries(people).find(([, p]) => p.member === memberId)?.[0]
    ?? (memberId === accountless.member ? 'accountless' : 'x'));
  const jobs = (assignmentId, jobState = 'pending') => [...psql(`select coalesce(string_agg(
        case j.source_type when 'duties_assignment' then 'm' else 'l' end || ':' || j.reminder_kind || '@'
        || j.recipient_member_id, ','), '')
      from app.notifications_jobs j where j.source_id = '${assignmentId}' and j.job_state = '${jobState}'
       and j.snoozed_from_item_id is null`)
    .split(',').filter(Boolean).map((x) => x.replace(/@([0-9a-f-]{36})/, (_, m) => `@${roleOf(m)}`))].sort().join(',');

  let apiCleanupDone = false;
  const apiCleanup = async () => {
    if (apiCleanupDone || !run.departmentId || !people.leader.token) return;
    apiCleanupDone = true;
    const out = { series: [], positions: [], removed: [], revoked: null };
    for (const seriesId of run.seriesIds) {
      const s = await rotaSeries(seriesId);
      const first = (s?.occurrences ?? []).filter((o) => o.state !== 'cancelled' && !o.started)
        .sort((a, b) => a.series_date.localeCompare(b.series_date))[0];
      if (first) {
        out.series.push(outcome(await duty(people.leader, 'duties.cancel_series', s.revision,
          { series_id: seriesId, from_occurrence_id: first.occurrence_id })));
      }
    }
    for (const occurrenceId of run.occurrenceIds) {
      const b = await board(people.leader);
      const dutyRow = (b?.departments ?? []).flatMap((d) => d.duties ?? []).find((x) => x.occurrence_id === occurrenceId);
      const slot = (dutyRow?.positions ?? []).find((p) => !p.cancelled);
      if (dutyRow && slot && dutyRow.state !== 'cancelled') {
        out.positions.push(outcome(await duty(people.leader, 'duties.cancel_position', dutyRow.revision, { slot_id: slot.slot_id })));
      }
    }
    for (const p of [people.member, people.other, accountless]) {
      if (!p.member) continue;
      const r = await duty(people.admin, 'duties.remove_member', await departmentRevision(),
        { department_id: run.departmentId, member_id: p.member });
      out.removed.push(r.code === 'validation_failed' && r.field_errors?.member_id === 'not_in_department' ? 'not_member' : outcome(r));
    }
    if (run.leaderGranted && people.leader.member) {
      const g = await grantsRevision(people.leader.member);
      const r = await envelope('identity_grant_command', people.admin.token, 'identity.revoke_scope', g?.revision,
        { member_id: people.leader.member, scope_kind: 'department_leader', scope_id: run.departmentId });
      out.revoked = outcome(r);
    }
    const ok = out.series.every((x) => x.status === 200) && out.positions.every((x) => x.status === 200)
      && out.removed.every((x) => x === 'not_member' || x.status === 200)
      && (!run.leaderGranted || out.revoked?.status === 200);
    check('P98-api-cleanup-cancels-removes-and-revokes', ok, out);
  };

  /**
   * Personas the staging way: sign up once, apply, approved by the Admin; reused from the state
   * afterwards (staging), or fresh each run (local --staging-path).
   */
  const ensurePersonas = async () => {
    const A = people.admin;
    for (const label of ['leader', 'member', 'other']) {
      const p = people[label];
      const st = (state.personas[label] ??= { phone: p.phone });
      if (st.phone !== p.phone) throw new Error(`state file persona ${label} has another number`);
      if (!st.pw) {
        st.pw = `Synthetic-${randomBytes(15).toString('base64url')}`;
        saveState();
        const up = await http('POST', '/auth/v1/signup', { body: { phone: p.phone, password: st.pw } });
        if (up.status !== 200 || !up.json?.access_token) throw new Error(`sign-up for ${label} failed: ${up.status}`);
        users.add(up.json?.user?.id);
      }
      p.pw = st.pw;
      p.token = (await signIn(p.phone, p.pw)).json?.access_token;
      if (!p.token) throw new Error(`persona ${label} cannot sign in; fix the state file`);
      let summary = await rpc('identity_my_member_summary', p.token);
      if (summary.status !== 200) {
        if (summary.json?.details !== 'not_linked') throw new Error(`persona ${label} is ${summary.json?.details}; heal it by hand`);
        const application = await read('identity_my_application', p.token);
        const mine = application?.application;
        let applicationId = ['submitted', 'needs_details'].includes(mine?.application_state) ? mine.application_id : null;
        if (!applicationId) {
          const sent = await envelope('identity_application_command', p.token, 'identity.submit_application', null,
            { full_name: p.name, cell_choice: { choice: 'not_sure' }, privacy_notice_version: application?.privacy_notice?.version });
          applicationId = sent.data?.application_id;
          if (!applicationId) throw new Error(`application for ${label} refused: ${sent.code}`);
        }
        const queue = (await read('identity_admin_application_queue', A.token))?.applications ?? [];
        const item = queue.find((a) => a.application_id === applicationId);
        const approved = await envelope('identity_review_command', A.token, 'identity.approve_application', item?.revision,
          { application_id: applicationId, identity_check: 'in_person' });
        if (!approved.data?.member_id) throw new Error(`approval for ${label} refused: ${approved.code}`);
        await sleep(EPOCH_WAIT_MS);
        p.token = (await signIn(p.phone, p.pw)).json?.access_token;
        summary = await rpc('identity_my_member_summary', p.token);
      }
      p.member = summary.json?.member_id;
      st.member = p.member;
      saveState();
    }
  };

  try {
    // ====================================================================== P00 precondition
    if (target === 'local') {
      const settings = await http('GET', '/auth/v1/settings');
      if (settings.json?.external?.phone !== true) {
        throw new Error('the local phone provider is off: run `node tools/auth-harness/local-phone-auth.mjs on` first');
      }
      const marker = psql(`select coalesce((select environment from app.platform_environment), '')`);
      if (marker === '') {
        psql(`select app.platform_set_environment('local', 'duties-pilot-e2e')`);
        marked = true;
      } else if (marker !== 'local') {
        throw new Error(`local database is marked ${marker}`);
      }
      const runId = randomUUID().slice(0, 8);
      credential = `sysc_local_${randomBytes(32).toString('base64url')}`;
      principal = psql(`select app.sys_create_principal('notifications-worker-pilot-${runId}', 'notifications_worker', '${OPERATOR}')`);
      credentialId = JSON.parse(psql(`select app.sys_register_credential('${principal}',
        '${createHash('sha256').update(credential).digest('hex')}', 'duties pilot e2e ${runId}', interval '2 hours', '${OPERATOR}')`)).credential_id;
      log('P00-precondition', { phone_provider: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null,
        leftover_users_removed: localCleanup() });

      // Personas: local Auth admin route and the synthetic seed link; the Admin is bootstrapped.
      // With --staging-path only the Admin is seeded: the others take the staging route below.
      for (const p of stagingPath ? [people.admin] : Object.values(people)) {
        p.pw = `Synthetic-${randomBytes(12).toString('base64url')}`;
        const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.pw } });
        p.user = created.json?.id;
        users.add(p.user);
        p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'duties-pilot-e2e')`);
        p.token = (await signIn(p.phone, p.pw)).json?.access_token;
      }
      psql(`select app.identity_bootstrap_admin('${people.admin.member}', '${OPERATOR}')`);
      if (stagingPath) await ensurePersonas();
    } else {
      const A = people.admin;
      A.pw = state.admin.pw;
      A.token = (await signIn(A.phone, A.pw)).json?.access_token;
      const access = await read('identity_my_access', A.token);
      if (!A.token || !access?.roles?.includes('admin')) throw new Error('the synthetic Admin cannot act on staging');
      A.member = access.member_id;
      await ensurePersonas();
      log('P00-precondition', { origin_checked: true, personas: Object.keys(state.personas).length });
    }
    check('P01-personas-signed-in-by-phone', Object.values(people).every((p) => p.token && p.member
      && amrMethods(p.token).includes('password')), { members: Object.values(people).filter((p) => p.member).length });

    const seenAtStart = { member: await seen(people.member), other: await seen(people.other), leader: await seen(people.leader) };

    // ====================================================================== P02 department, leader, members
    const existing = ((await overview())?.departments ?? []).find((d) => d.name.toLowerCase() === DEPARTMENT.toLowerCase());
    if (existing) {
      run.departmentId = existing.department_id;
    } else {
      const created = await duty(people.admin, 'duties.create_department', null, { name: DEPARTMENT });
      run.departmentId = created.data?.department_id;
      run.createdDepartment = Boolean(run.departmentId);
      if (state) { state.departments ??= {}; state.departments[run.departmentId] = 'created_by_pilot'; saveState(); }
    }
    if (state?.departments?.[run.departmentId] === 'created_by_pilot') run.createdDepartment = true;
    // The accountless member X: an Admin record with a labelled SYNTHETIC household number.
    if (state?.accountless?.member) {
      accountless.member = state.accountless.member;
    } else {
      const x = await envelope('identity_review_command', people.admin.token, 'identity.create_member', null, {
        full_name: accountless.name, consent_basis: 'in_person',
        contact_route: { phone: numbers.household, belongs_to: 'household', holder_label: 'SYNTHETIC household' } });
      accountless.member = x.data?.member_id;
      if (state) { state.accountless = { member: accountless.member }; saveState(); }
    }
    const held = await grantsRevision(people.leader.member);
    let grant = { status: 200, code: null };
    if (!(held?.scopes ?? []).some((s) => s.scope_kind === 'department_leader' && s.scope_id === run.departmentId)) {
      grant = await envelope('identity_grant_command', people.admin.token, 'identity.grant_scope', held?.revision,
        { member_id: people.leader.member, scope_kind: 'department_leader', scope_id: run.departmentId });
      run.leaderGranted = grant.status === 200 && !grant.code;
    }
    const added = [];
    for (const p of [people.member, people.other, accountless]) {
      const r = await duty(people.admin, 'duties.add_member', await departmentRevision(),
        { department_id: run.departmentId, member_id: p.member });
      added.push(r.status === 200 && !r.code ? 'added' : (r.field_errors?.member_id === 'current' ? 'already' : r.code));
    }
    people.leader.token = (await signIn(people.leader.phone, people.leader.pw)).json?.access_token;
    check('P02-department-leader-and-members', Boolean(run.departmentId) && Boolean(accountless.member)
      && grant.status === 200 && !grant.code && added.every((a) => a === 'added' || a === 'already'),
      { department: existing ? 'found' : 'created', accountless: Boolean(accountless.member), grant: outcome(grant), members: added });

    // ====================================================================== P10 quarterly rota
    const plan = quarterlyRota(Date.now());
    const series = await duty(people.leader, 'duties.create_series', null, {
      department_id: run.departmentId, duty_name: 'Sunday service', every: 'week', from_date: plan.from_date,
      until_date: plan.until_date, start_time: plan.start_time, positions: plan.positions,
      location: 'SYNTHETIC Main hall' });
    const seriesId = series.data?.series_id;
    if (seriesId) run.seriesIds.push(seriesId);
    let s = await rotaSeries(seriesId);
    const dates = [...(s?.occurrences ?? [])].sort((a, b) => a.series_date.localeCompare(b.series_date));
    const [sun1, sun2] = dates;
    const slotOf = (occ, no) => (occ?.positions ?? []).find((p) => p.position_no === no)?.slot_id;
    const occRevision = async (occurrenceId) => (await rotaSeries(seriesId))?.occurrences
      ?.find((o) => o.occurrence_id === occurrenceId)?.revision;
    const planned = [];
    for (const [occ, no, p] of [[sun1, 1, people.member], [sun1, 2, accountless], [sun2, 1, people.other]]) {
      planned.push((await duty(people.leader, 'duties.assign_slot', await occRevision(occ?.occurrence_id),
        { slot_id: slotOf(occ, no), member_id: p.member })).status);
    }
    s = await rotaSeries(seriesId);
    const seenM20 = await seen(people.member);
    const pub = await duty(people.leader, 'duties.publish_drafts', s?.revision, { series_id: seriesId, slot_count: s?.draft_slots });
    s = await rotaSeries(seriesId);
    const posOf = (occId, no) => s?.occurrences?.find((o) => o.occurrence_id === occId)?.positions?.find((p) => p.position_no === no);
    const aM = posOf(sun1?.occurrence_id, 1)?.assignment?.assignment_id;
    const aX = posOf(sun1?.occurrence_id, 2)?.assignment?.assignment_id;
    const aO = posOf(sun2?.occurrence_id, 1)?.assignment?.assignment_id;
    check('P10-quarterly-rota-published', series.status === 200 && dates.length === plan.sundays
      && dates[0]?.series_date === plan.from_date && new Date(`${plan.from_date}T00:00:00Z`).getUTCDay() === 0
      && planned.every((x) => x === 200) && pub.status === 200 && pub.data?.assignments === 3
      && (s?.occurrences ?? []).every((o) => o.state === 'published') && Boolean(aM && aX && aO),
      { sundays: dates.length, first_is_sunday: new Date(`${plan.from_date}T00:00:00Z`).getUTCDay() === 0,
        planned, published: outcome(pub), assignments: pub.data?.assignments ?? null,
        slots: (s?.occurrences ?? []).reduce((n, o) => n + (o.positions?.length ?? 0), 0) });

    // ====================================================================== P20 reminders queued and delivered
    const mine = await myAssignment(people.member, aM);
    const queued = sqlChecks ? jobs(aM) : null;
    const delivered = await settle(async () => {
      const items = itemsNew(await inbox(people.member), seenM20, 'duty_assigned');
      const cov = await coverage(people.leader, { from_date: plan.from_date, to_date: addDays(plan.from_date, 28), department_id: run.departmentId });
      const xNeeds = (positionOf(cov.json, aX)?.needs_contact?.reasons ?? []).includes('not_reached');
      return items.length >= 1 && xNeeds ? { items, cov } : null;
    });
    const opened = delivered?.items?.[0] ? await openItem(people.member, delivered.items[0].item_id) : null;
    check('P20-reminders-queued-and-delivered-by-the-worker', Boolean(mine) && mine.deadline_source === 'default'
      && (mine.reminders == null || mine.reminders.length > 0) && Boolean(mine.response_deadline)
      && (!sqlChecks || (queued.includes('m:duty_response_due@member') && queued.includes('l:duty_response_overdue@leader')))
      && Boolean(delivered) && opened?.state === 'current' && opened?.target === `/duties/assignments/${aM}` && isGenericItem(opened),
      { deadline_source: mine?.deadline_source ?? null, reminders: mine?.reminders == null ? 'church_defaults' : mine.reminders.length, queued,
        delivered_items: delivered?.items?.length ?? 0, accountless_needs_contact: Boolean(delivered),
        opened: opened?.state ?? null, generic: isGenericItem(opened) });

    // ====================================================================== P30 answers
    const mRev = (await myAssignment(people.member, aM))?.revision;
    const accept = await duty(people.member, 'duties.respond', mRev,
      { assignment_id: aM, response: 'accepted', note: 'SYNTHETIC member note M: glad to preach' });
    const oRev = (await myAssignment(people.other, aO))?.revision;
    const seenL30 = await seen(people.leader);
    const decline = await duty(people.other, 'duties.respond', oRev,
      { assignment_id: aO, response: 'declined', note: 'SYNTHETIC member note O: travelling' });
    const declineAlert = await settle(async () => itemsNew(await inbox(people.leader), seenL30, 'duty_declined')[0]);
    const declineOpen = declineAlert ? await openItem(people.leader, declineAlert.item_id) : null;
    const leaderBoard = await board(people.leader);
    const bM = boardPositionOf(leaderBoard, aM)?.position?.assignment;
    const bO = boardPositionOf(leaderBoard, aO)?.position?.assignment;
    const starting = sqlChecks ? jobs(aM) : null;
    check('P30-member-answers-reach-the-leader', accept.status === 200 && decline.status === 200
      && bM?.response === 'accepted' && bM?.note === 'SYNTHETIC member note M: glad to preach'
      && bO?.response === 'declined' && bO?.note === 'SYNTHETIC member note O: travelling'
      && declineOpen?.target === '/duties/coverage' && isGenericItem(declineOpen)
      && (!sqlChecks || starting === 'm:duty_starting@member'),
      { accepted: outcome(accept), declined: outcome(decline), board: [bM?.response ?? null, bO?.response ?? null],
        decline_alert: declineOpen?.target ?? null, generic: isGenericItem(declineOpen), accepted_pending_jobs: starting });

    // ====================================================================== P40 the gap is visible
    const window = { from_date: plan.from_date, to_date: addDays(plan.from_date, 28), department_id: run.departmentId };
    const gap = await coverage(people.leader, window);
    const gapDept = (gap.json?.departments ?? []).find((d) => d.department_id === run.departmentId);
    const unfilledHere = (gapDept?.positions ?? []).filter((p) => p.status === 'unfilled').length;
    const xRoute = gapDept?.contact_routes?.[accountless.member]?.[0];
    check('P40-the-gap-is-visible-in-coverage', gap.status === 200 && gapDept?.view === 'full'
      && positionOf(gap.json, aM)?.status === 'confirmed' && positionOf(gap.json, aO)?.status === 'declined'
      && positionOf(gap.json, aX)?.status === 'awaiting' && positionOf(gap.json, aX)?.assignment?.account === 'no_login'
      && unfilledHere >= 7 && gapDept?.counts?.unfilled >= unfilledHere && gapDept?.counts?.declined >= 1
      && gapDept?.counts?.needs_contact >= 1 && xRoute?.phone === numbers.household && xRoute?.belongs_to === 'household',
      { counts: gapDept?.counts ?? null, unfilled_listed: unfilledHere,
        states: [aM, aX, aO].map((a) => positionOf(gap.json, a)?.status ?? null),
        route: xRoute ? { belongs_to: xRoute.belongs_to, labelled: Boolean(xRoute.holder_label) } : null });

    // ====================================================================== P50 a direct contact attempt
    const xRev = positionOf(gap.json, aX)?.assignment?.revision;
    const contact = await duty(people.leader, 'duties.record_contact_attempt', xRev, {
      assignment_id: aX, channel: 'phone', outcome: 'will_answer', note: `${LEADER_ONLY}: rang the household`,
      next_follow_up_at: minuteCeil(Date.now() + DAY) });
    const afterContact = await coverage(people.leader, window);
    const xFollow = positionOf(afterContact.json, aX)?.follow_up;
    const xTask = xFollow?.task_id ? await read('followups_task', people.leader.token, { p_task_id: xFollow.task_id }) : null;
    check('P50-direct-contact-attempt-opens-a-follow-up', contact.status === 200 && contact.data?.followup === 'opened'
      && xFollow?.attempts === 1 && xFollow?.last_attempt?.outcome === 'will_answer'
      && xTask?.task?.purpose === 'coverage_follow_up' && ['open', 'waiting'].includes(xTask?.task?.state),
      { attempt: outcome(contact), followup: contact.data?.followup ?? null, attempts: xFollow?.attempts ?? null,
        task: xTask?.task?.state ?? null });

    // ====================================================================== P60 Confirmed by leader
    const confirm = await duty(people.leader, 'duties.confirm_by_leader', xRev,
      { assignment_id: aX, channel: 'phone', reason: `${LEADER_ONLY}: confirmed by phone with the household` });
    const afterConfirm = await coverage(people.leader, window);
    const px = positionOf(afterConfirm.json, aX);
    const bX = boardPositionOf(await board(people.leader), aX)?.position?.assignment;
    const xTaskAfter = xFollow?.task_id ? await read('followups_task', people.leader.token, { p_task_id: xFollow.task_id }) : null;
    const xJobs = sqlChecks ? jobs(aX) : null;
    check('P60-confirmed-by-leader-for-the-accountless-member', confirm.status === 200 && confirm.data?.provenance === 'leader'
      && px?.status === 'confirmed' && px?.assignment?.response_provenance === 'leader'
      && px?.assignment?.confirmation?.channel === 'phone' && Boolean(px?.assignment?.confirmation?.by)
      && bX?.response === 'accepted' && bX?.response_provenance === 'leader'
      && xTaskAfter?.task?.state === 'closed' && (!sqlChecks || xJobs === 'm:duty_starting@accountless'),
      { confirmed: outcome(confirm), status: px?.status ?? null, provenance: px?.assignment?.response_provenance ?? null,
        board_provenance: bX?.response_provenance ?? null, task: xTaskAfter?.task?.state ?? null, pending_jobs: xJobs });

    // ====================================================================== P70 a short-notice Sunday assignment
    const shortAt = Date.now();
    const seenL70 = await seen(people.leader);
    const seenM70 = await seen(people.member);
    const shortDuty = await duty(people.leader, 'duties.publish_duty', null, {
      department_id: run.departmentId, duty_name: 'Sunday short-notice cover', starts_at: shortNoticeStart(shortAt),
      location: 'SYNTHETIC Main hall', member_id: people.member.member });
    if (shortDuty.data?.occurrence_id) run.occurrenceIds.push(shortDuty.data.occurrence_id);
    const aShort = shortDuty.data?.assignment_id;
    const shortMine = await myAssignment(people.member, aShort);
    const shortAlerts = await settle(async () => {
      const l = itemsNew(await inbox(people.leader), seenL70, 'duty_short_notice');
      const m = itemsNew(await inbox(people.member), seenM70, 'duty_assigned');
      return l.length >= 1 && m.length >= 1 ? { l, m } : null;
    });
    const shortBoard = boardPositionOf(await board(people.leader), aShort)?.position?.assignment;
    const shortAccept = await duty(people.member, 'duties.respond', shortMine?.revision, { assignment_id: aShort, response: 'accepted' });
    check('P70-short-notice-sunday-assignment', shortDuty.status === 200 && shortMine?.short_notice === true
      && Boolean(shortAlerts) && shortAlerts.m.length === 1 && shortBoard?.short_notice === true
      && (shortBoard?.needs_contact?.reasons ?? []).includes('short_notice') && shortAccept.status === 200,
      { published: outcome(shortDuty), short_notice: shortMine?.short_notice ?? null,
        leader_alerts: shortAlerts?.l?.length ?? 0, member_items: shortAlerts?.m?.length ?? 0,
        board_needs_contact: shortBoard?.needs_contact?.reasons ?? null, accepted: outcome(shortAccept) });

    // ====================================================================== P80 reassignment, no stale reminder
    const probe = probePlan(Date.now());
    const seenM80 = await seen(people.member);
    const probeDuty = await duty(people.leader, 'duties.publish_duty', null, {
      department_id: run.departmentId, duty_name: 'Sunday reading (reassignment check)', starts_at: probe.starts_at,
      location: 'SYNTHETIC Side room', member_id: people.member.member, response_deadline: probe.response_deadline,
      reminders: probe.reminders });
    if (probeDuty.data?.occurrence_id) run.occurrenceIds.push(probeDuty.data.occurrence_id);
    const aProbeM = probeDuty.data?.assignment_id;
    const probeQueued = sqlChecks ? jobs(aProbeM) : null;
    const probeItem = await settle(async () => {
      for (const i of itemsNew(await inbox(people.member), seenM80, 'duty_assigned')) {
        const o = await openItem(people.member, i.item_id);
        if (o?.target === `/duties/assignments/${aProbeM}`) return i;
      }
      return null;
    });
    const seenO80 = await seen(people.other);
    const reassign = await duty(people.leader, 'duties.assign_slot', probeDuty.data?.revision,
      { slot_id: probeDuty.data?.slot_id, member_id: people.other.member, response_deadline: probe.response_deadline });
    const probeBoard = boardPositionOf(await board(people.leader), probeDuty.data?.slot_id)?.position;
    const aProbeO = probeBoard?.assignment?.assignment_id;
    const mStillHas = Boolean(await myAssignment(people.member, aProbeM));
    let shifted = null;
    if (sqlChecks) {
      // Test-only time shift: every job of the probe still waiting falls due now.
      shifted = Number(psql(`with u as (update app.notifications_jobs set scheduled_at = now() - interval '1 second'
        where job_state = 'pending' and (source_id = '${aProbeM}'
          or (source_id = '${aProbeO}' and reminder_kind = 'duty_response_due')) returning 1) select count(*) from u`));
    } else {
      const wait = Date.parse(probe.due_at) - Date.now();
      if (wait > 0) await sleep(wait);
    }
    const control = await settle(async () => itemsNew(await inbox(people.other), seenO80, 'duty_response_due')[0],
      { timeoutMs: 5 * MINUTE });
    const controlOpen = control ? await openItem(people.other, control.item_id) : null;
    const mItems = itemsNew(await inbox(people.member), seenM80);
    const mStale = mItems.filter((i) => i.reminder_kind === 'duty_response_due');
    const mReleased = mItems.filter((i) => i.reminder_kind === 'duty_released');
    const oldOpen = probeItem ? await openItem(people.member, probeItem.item_id) : null;
    const staleJobs = sqlChecks ? Number(psql(`select count(*) from app.notifications_jobs j
        join app.duties_assignments a on a.assignment_id = j.source_id
      where j.job_state = 'pending'
        and j.reminder_kind in ('duty_response_due', 'duty_starting', 'duty_response_overdue', 'duty_short_notice')
        and (a.assignment_state <> 'current' or j.source_revision <> a.revision or a.response = 'declined'
             or (j.reminder_kind <> 'duty_starting' and a.response <> 'pending')
             or (j.reminder_kind = 'duty_starting' and a.response = 'pending'))`)) : null;
    check('P80-reassignment-sends-no-stale-reminder-to-the-replaced-member', probeDuty.status === 200
      && (!sqlChecks || probeQueued.includes('m:duty_response_due@member')) && Boolean(probeItem)
      && reassign.status === 200 && !reassign.code && Boolean(aProbeO) && aProbeO !== aProbeM && !mStillHas
      && Boolean(control) && controlOpen?.state === 'current' && controlOpen?.target === `/duties/assignments/${aProbeO}`
      && mStale.length === 0 && mReleased.length === 1 && oldOpen?.state === 'superseded' && oldOpen?.target == null
      && (!sqlChecks || staleJobs === 0),
      { published: outcome(probeDuty), queued_for_m: probeQueued, reassigned: outcome(reassign), m_still_lists_it: mStillHas,
        shifted, new_member_reminder: control?.reminder_kind ?? null, new_member_open: controlOpen?.state ?? null,
        replaced_member_reminders: mStale.length, replaced_member_released: mReleased.length,
        old_item: oldOpen?.state ?? null, stale_pending_jobs: staleJobs });

    // ====================================================================== P90 nothing private for a non-leader
    const denied = {};
    for (const [label, p] of [['member', people.member], ['other', people.other]]) {
      denied[label] = [
        (await rpc('duties_leader_board', p.token)).status,
        (await coverage(p, window)).status,
        (await rpc('duties_rota', p.token)).status,
      ];
    }
    const mDuties = await myDuties(people.member);
    const oDuties = await myDuties(people.other);
    const adminCoverage = await coverage(people.admin, window);
    const adminDept = (adminCoverage.json?.departments ?? []).find((d) => d.department_id === run.departmentId);
    const adminBoard = boardPositionOf(await board(people.admin), aX)?.position?.assignment;
    const leaderControl = positionOf((await coverage(people.leader, window)).json, aX)?.assignment?.confirmation?.reason;
    const opened90 = [];
    for (const [label, p] of [['member', people.member], ['other', people.other], ['leader', people.leader]]) {
      for (const i of itemsNew(await inbox(p), seenAtStart[label])) opened90.push(await openItem(p, i.item_id));
    }
    check('P90-no-private-notes-for-a-non-leader', Object.values(denied).flat().every((x) => x === 403)
      && !leaksLeaderText(mDuties) && !leaksLeaderText(oDuties)
      && !JSON.stringify(mDuties ?? {}).includes('SYNTHETIC member note O')
      && !JSON.stringify(oDuties ?? {}).includes('SYNTHETIC member note M')
      && adminCoverage.status === 200 && adminDept?.view === 'operational' && !holdsPrivate(adminCoverage.json)
      && adminBoard?.response_provenance === 'leader' && adminBoard?.confirmation?.reason == null
      && typeof leaderControl === 'string' && leaderControl.startsWith(LEADER_ONLY)
      && opened90.length > 0 && opened90.every(isGenericItem) && !JSON.stringify(opened90).includes('SYNTHETIC'),
      { member_reads: denied.member, other_reads: denied.other, member_my_duties_private: leaksLeaderText(mDuties),
        other_my_duties_private: leaksLeaderText(oDuties), admin_view: adminDept?.view ?? null,
        admin_private: holdsPrivate(adminCoverage.json), admin_board_reason: adminBoard?.confirmation?.reason != null,
        leader_sees_reason: typeof leaderControl === 'string', items: opened90.length,
        all_generic: opened90.every(isGenericItem), kinds: [...new Set(opened90.map((i) => i?.reminder_kind))].sort() });

    // ====================================================================== P98 cleanup through the API
    await apiCleanup();
    const after = await coverage(people.leader, window);
    const leftHere = (after.json?.departments ?? []).find((d) => d.department_id === run.departmentId)?.positions ?? [];
    const runLeft = leftHere.filter((p) => [aM, aX, aO].includes(p.assignment?.assignment_id)).length;
    const runIds = [aM, aX, aO, aShort, aProbeM, aProbeO];
    const stillListed = [...((await myDuties(people.member))?.assignments ?? []), ...((await myDuties(people.other))?.assignments ?? [])]
      .filter((a) => runIds.includes(a.assignment_id)).length;
    check('P99-nothing-of-the-run-is-left-open', runLeft === 0 && stillListed === 0,
      { run_positions_listed: runLeft, still_in_my_duties: stillListed });
  } catch (e) {
    check('P--unexpected-error', false, { error: String(e?.message ?? e).slice(0, 200) });
  } finally {
    try { await apiCleanup(); } catch (e) { check('P98-api-cleanup', false, { error: String(e?.message ?? e).slice(0, 200) }); }
    if (stagingPath && run.departmentId) {
      // The staging cleanup SQL, executed here so it is proven before the parent session uses it.
      psql(stagingCleanupSql({ departmentId: run.departmentId, seriesIds: run.seriesIds, occurrenceIds: run.occurrenceIds,
        memberIds: [people.member.member, people.other.member, accountless.member], removeDepartment: run.createdDepartment }));
      const left = Number(psql(`select count(*) from app.duties_occurrences where department_id = '${run.departmentId}'`))
        + Number(psql(`select count(*) from app.duties_series where department_id = '${run.departmentId}'`))
        + Number(psql(`select count(*) from app.duties_departments where department_id = '${run.departmentId}'`))
        + Number(psql(`select count(*) from app.followups_tasks where scope_id = '${run.departmentId}'`));
      check('P99-staging-cleanup-sql-removes-the-run', left === 0, { rows_left: left });
    }
    if (target === 'local') {
      const left = localCleanup();
      if (credentialId) psql(`select app.sys_revoke_credential('${credentialId}', '${OPERATOR}'); select app.sys_disable_principal('${principal}', '${OPERATOR}');`);
      if (marked) {
        psql(`delete from app.platform_environment where set_by = 'duties-pilot-e2e';
              delete from app.platform_environment_history where set_by = 'duties-pilot-e2e';`);
      }
      log('P99-local-cleanup', { users_left: Number(left), credential_revoked: Boolean(credentialId), unmarked: marked,
        departments_left: Number(psql(`select count(*) from app.duties_departments where name = '${DEPARTMENT}'`)),
        members_left: Number(psql(`select count(*) from app.identity_members where display_name like '${NAME_PREFIX}%'`)) });
    } else if (run.departmentId) {
      const sql = stagingCleanupSql({ departmentId: run.departmentId, seriesIds: run.seriesIds, occurrenceIds: run.occurrenceIds,
        memberIds: [people.member.member, people.other.member, accountless.member], removeDepartment: run.createdDepartment });
      if (cleanupSqlPath) writeFileSync(cleanupSqlPath, sql, { mode: 0o600 });
      log('P99-staging-cleanup-sql', { written: Boolean(cleanupSqlPath), series: run.seriesIds.length, one_off_duties: run.occurrenceIds.length });
    }
  }
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  if (failed.length) {
    console.log(`FAILED: ${failed.map((f) => f.step).join(', ')}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((e) => {
    console.error(`duties-pilot: ${e.message}`);
    process.exitCode = 1;
  });
}
