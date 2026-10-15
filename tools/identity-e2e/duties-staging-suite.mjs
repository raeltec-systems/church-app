#!/usr/bin/env node
// Story 4.15: the closing Duties and Follow-ups suite, through the public API only (Auth and the
// Data API), with SYNTHETIC people and fictional numbers. It runs every scenario the ticket names
// and a role and scope permission matrix:
//
//   S10 departments and a rota (drafts hidden from members, published to three people)
//   S20 revisions (a material change re-asks, a late answer to the old revision is refused, a
//       notes-only edit keeps the acceptance)
//   S30 responses (accept, can't make it with a note, can't make it anymore, bulk acceptance)
//   S40 conflicts (an overlap with another department warns without its details; refused without
//       a reason; recorded with one, the member still answers)
//   S50 deadlines and reminders (creator deadline and reminders, the default, set reminders,
//       short notice with the leaders' alert; the worker delivers New duty assigned)
//   S60 coverage and direct confirmation (queue states and counts, the labelled route for the
//       accountless member, a contact attempt opens a follow-up, Confirmed by leader, reassignment
//       of a decline, cancelling a position; Admin and Pastor see the operational view only)
//   S70 completion (outcomes after the start, a correction keeps the prior value, an unrecorded
//       duty is never a no-show; Admin role alone and another department's leader refused)
//   S80 follow-ups (a task for an app member: states, review date, close needs a reason,
//       reassignment, routing metadata for the Admin; the assignment notice is delivered)
//   S90 lifecycle and handover (a login hold routes to Needs contact; removal and deactivation
//       vacate with the coarse reason shown to the department's leaders and deputies only; scope
//       loss closes reads and commands at once; revoking the last reachable leader is refused
//       `handover_required`; unlinking an account is never refused, records the handover, which
//       the Admin resolves; the account is linked back to the same member)
//   S95 owner operations (not reachable over the Data API; on the local stack also a SYNTHETIC
//       linked event change flags a duty, the leader gets "Duty needs review" and clears it)
//   M   the permission matrix: principals (signed out, no member access, held, deactivated, app
//       member, cell leader, Pastor, Admin role alone, the department's leader and deputy, another
//       department's leader) x every Duties and Follow-ups read and a set of command probes that
//       cannot change anything (a stale expected revision), each with its exact expected answer
//   S99 privacy and cleanup (no note, reason, route or number reaches a member; every duty of the
//       run is cancelled, the run's tasks closed, the people restored)
//
// Two targets, chosen explicitly (`--target local|staging` or DUTIES_SUITE_TARGET; default local):
//
//   local    the local stack (exact origin http://127.0.0.1:54321). Every person is made with the
//            local Auth admin route and the synthetic seed link, the run's own worker credential
//            drives tools/notifications/worker.mjs, and everything is deleted at the end. Needs
//            `node tools/auth-harness/local-phone-auth.mjs on` and a database with no usable Admin
//            (`npx supabase db reset` first). Fictional numbers +44 7700 900540-900549, 900580-900582.
//            `--staging-path` takes the staging route on the local stack: the Duties people sign
//            up, apply and are approved; no SQL check and no SQL-made owner operation; the staging
//            cleanup SQL is executed and verified.
//   staging  the hosted staging project only (https://tmurpotfluignacfueki.supabase.co), with the
//            publishable key: no secret or service-role key and no SQL. The Duties people
//            (+1 202 555 0153-0158, the household number 0159) sign up, apply and are approved by
//            the synthetic Admin (0150) once and are reused from a state file kept OUTSIDE the
//            repository (mode 0600). The Pastor, the no-access, held and deactivated people and the
//            cell leader are the identity suite's personas (story 2.14), read from its state file
//            and only signed in (never changed). The scheduled worker delivers (the run polls).
//            The API cleanup runs at the end; `--cleanup-sql <file>` writes the SQL that removes
//            the run's rows (run by the parent session after the suite). The owner runs the
//            staging target: it needs the synthetic Admin's password (duties.md, story 4.15).
//
// Evidence is redacted JSONL (statuses, codes, counts, states): never a token, password, number,
// name, note or reason. `--summary <file.md>` writes the readable summary with both matrices.
//
// Usage:
//   node tools/identity-e2e/duties-staging-suite.mjs [--staging-path] [--evidence <f.jsonl>] [--summary <f.md>]
//   DUTIES_SUITE_TARGET=staging STAGING_PUBLISHABLE_KEY=sb_publishable_... \
//   STAGING_SUITE_ADMIN=/outside/repo/admin.json STAGING_SUITE_STATE=/outside/repo/staging-suite-state.json \
//   DUTIES_SUITE_STATE=/outside/repo/duties-suite-state.json \
//   node tools/identity-e2e/duties-staging-suite.mjs --evidence <f.jsonl> --summary <f.md> --cleanup-sql <f.sql>
import { randomBytes, randomUUID } from 'node:crypto';
import { appendFileSync, chmodSync, existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import { EPOCH_WAIT_MS, amrMethods, localHttp, localKey, psql, sleep } from './harness.mjs';
import { churchInstant, genericItemCheck, jsonLiteral, notificationsWorker, sessionClaims } from './duties-shared.mjs';
import { GENERIC_TEXT } from './duties-pilot.mjs';
import {
  ADMIN_PHONE, STAGING_ORIGIN, assertPublishableKey, assertStagingOrigin, assertStateOutsideRepo, isSuiteFictional,
  redactEvidence,
} from './staging-suite.mjs';

const OPERATOR = 'israel';
export const NAME_PREFIX = 'SYNTHETIC Closing';
export const DEPARTMENTS = { A: 'SYNTHETIC Closing Suite A', B: 'SYNTHETIC Closing Suite B' };
/** The per-run department the unlink rule uses (removed by the cleanup). */
export const departmentC = (runId) => `SYNTHETIC Closing Suite C ${runId}`;
/** Texts only the department's leaders may read carry this marker, so a leak is detectable. */
export const PRIVATE = 'SYNTHETIC closing private';
export const MINUTE = 60_000;
export const HOUR = 60 * MINUTE;
export const DAY = 24 * HOUR;
const CHURCH_OFFSET = 2 * HOUR;

/** The Duties people (made and kept by this suite) and, on staging, the identity suite labels it borrows. */
export const DUTIES_PEOPLE = ['leadA', 'depA', 'leadB', 'm1', 'm2', 'life'];
export const BORROWED = { pastor: 'pastor', guest: 'guest', held: 'held', deact: 'deact', cellL: 'leader' };

/** The fictional numbers of each target (local: every person; staging: the Duties people only). */
export const NUMBERS = {
  local: {
    admin: '+447700900540', leadA: '+447700900541', depA: '+447700900542', leadB: '+447700900543', m1: '+447700900544',
    m2: '+447700900545', life: '+447700900546', pastor: '+447700900547', guest: '+447700900548', household: '+447700900549',
    held: '+447700900580', deact: '+447700900581', cellL: '+447700900582',
  },
  staging: {
    admin: ADMIN_PHONE, leadA: '+12025550153', depA: '+12025550154', leadB: '+12025550155', m1: '+12025550156',
    m2: '+12025550157', life: '+12025550158', household: '+12025550159',
  },
};

/** Is `phone` one of this suite's reserved numbers on `target`? */
export function isSuitePhone(target, phone) {
  if (target === 'local') return /^\+4477009005(4[0-9]|8[0-2])$/.test(phone);
  if (target === 'staging') return phone === ADMIN_PHONE || /^\+120255501(5[3-9])$/.test(phone);
  return false;
}

/** The run's target: `--target` or DUTIES_SUITE_TARGET, default local; anything else is refused. */
export function parseTarget(argv = [], env = {}) {
  const i = argv.indexOf('--target');
  const flag = i >= 0 ? argv[i + 1] : undefined;
  const fromEnv = env.DUTIES_SUITE_TARGET || undefined;
  if (flag !== undefined && fromEnv !== undefined && flag !== fromEnv) {
    throw new Error(`--target ${flag} and DUTIES_SUITE_TARGET=${fromEnv} disagree`);
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

/** An instant rounded up to the next whole minute, as UTC RFC3339. */
export function minuteCeil(ms) {
  return new Date(Math.ceil(ms / MINUTE) * MINUTE).toISOString();
}

/**
 * The run's calendar: a base date 12-21 days ahead (from the run id, so two runs rarely share a
 * time) and the minute every one-off duty of the run starts at. Every window of the run fits the
 * coverage queue's 31 days.
 */
export function runCalendar(nowMs, runId) {
  const seed = parseInt(String(runId).slice(0, 6), 16) || 0;
  const base = churchDate(nowMs + (12 + (seed % 10)) * DAY);
  const minute = String((seed >> 4) % 4 * 15).padStart(2, '0');
  return { base, minute, from: base, to: addDays(base, 27) };
}

/** Does any JSON hold a private text or a fictional contact number? */
export function leaksPrivate(value) {
  const json = JSON.stringify(value ?? {});
  return json.includes(PRIVATE) || /\+?447700900\d{3}|\+?1202555\d{4}/.test(json);
}

/** What leaks, for the evidence: 'private', 'number' or null. */
export function leakKind(value) {
  const json = JSON.stringify(value ?? {});
  if (json.includes(PRIVATE)) return 'private';
  return /\+?447700900\d{3}|\+?1202555\d{4}/.test(json) ? 'number' : null;
}

/** The coverage position of a slot or assignment id. */
export function coveragePosition(answer, id) {
  for (const d of answer?.departments ?? []) {
    for (const p of d.positions ?? []) if (p.slot_id === id || p.assignment?.assignment_id === id) return p;
  }
  return null;
}

/** The leader board duty (and position) holding an assignment, slot or occurrence id. */
export function boardEntry(board, id) {
  for (const d of board?.departments ?? []) {
    for (const duty of d.duties ?? []) {
      if (duty.occurrence_id === id) return { department: d, duty, position: duty.positions?.[0] ?? null };
      for (const p of duty.positions ?? []) {
        if (p.slot_id === id || p.assignment?.assignment_id === id) return { department: d, duty, position: p };
      }
    }
  }
  return null;
}

/** The newest history entry of a board position. */
export function newestHistory(position) {
  return [...(position?.history ?? [])].sort((a, b) => String(b.ended_at).localeCompare(String(a.ended_at)))[0] ?? null;
}

/** The keys a field_errors object marks `changed` (what a late answer is told). */
export function changedFields(fieldErrors) {
  return Object.entries(fieldErrors ?? {}).filter(([, v]) => v === 'changed').map(([k]) => k).sort();
}

/** A limited overlap item discloses only its owner kind and busy time. */
export function isLimitedConflict(item) {
  return item?.visibility === 'limited'
    && JSON.stringify(Object.keys(item).sort()) === JSON.stringify(['from', 'owner_kind', 'to', 'visibility']);
}

/** The fixed generic texts of every reminder kind the suite's people may receive. */
export const SUITE_TEXT = {
  ...GENERIC_TEXT,
  duty_vacated: ['Positions need cover',
    'One or more positions in your department no longer have anyone assigned. Open Coverage to find cover.'],
  duty_review_flagged: ['Duty needs review',
    'Something a duty in your department is linked to has changed. Open the Duties board to review it.'],
  followup_due: ['Follow-up task due', 'A follow-up task is due. Open it to record progress or set a review date.'],
  followup_overdue: ['Follow-up task overdue', 'A follow-up task you supervise is overdue. Open it to follow up with its owner.'],
};
/** The stale expected revision the matrix probes send (no record of the run reaches it). */
export const STALE = 987654;
/** Member notes carry this marker (a member reads their own note, never another member's). */
export const MEMBER_NOTE = 'SYNTHETIC member note';
const isGeneric = genericItemCheck(SUITE_TEXT);

// --------------------------------------------------------------------------- the permission matrix
/**
 * Matrix principals: how the server sees each one. `scopes` are department scopes ('A'/'B');
 * `cellScope` a cell scope; `roles` church roles; `self` marks the app member whose task and
 * assignment the probes name.
 */
export const PRINCIPALS = {
  anon: { outcome: 'anon' },
  guest: { outcome: 'not_linked' },
  held: { outcome: 'review_required' },
  deact: { outcome: 'deactivated' },
  m1: { outcome: 'granted', roles: [], scopes: [], member: true, self: true },
  cellL: { outcome: 'granted', roles: [], scopes: [], cellScope: true },
  pastor: { outcome: 'granted', roles: ['pastor'], scopes: [] },
  admin: { outcome: 'granted', roles: ['admin'], scopes: [] },
  leadA: { outcome: 'granted', roles: [], scopes: [['department_leader', 'A']] },
  depA: { outcome: 'granted', roles: [], scopes: [['department_deputy', 'A']] },
  leadB: { outcome: 'granted', roles: [], scopes: [['department_leader', 'B']] },
};

/** Every Duties and Follow-ups read (the probes' arguments are filled in at run time). */
export const READS = ['duties_admin_overview', 'duties_rota', 'duties_leader_board', 'duties_coverage', 'duties_candidates',
  'duties_member_history', 'duties_my_duties', 'duties_outcomes', 'followups_admin_routing', 'followups_my_tasks',
  'followups_supervision', 'followups_task'];

const denial = (p) => {
  if (p.outcome === 'anon') return { status: 401 };
  if (p.outcome === 'review_required') return { status: 403, detail: 'review_required' };
  return { status: 403, detail: 'not_linked' };
};
const ng = { status: 403, detail: 'not_granted' };
const ok = { status: 200 };
const holds = (p, dept) => (p.scopes ?? []).some(([, d]) => d === dept);
const anyDept = (p) => (p.scopes ?? []).length > 0;

/**
 * The exact expected answer of a read for a principal ({status, detail?}). Arguments: coverage
 * and candidates name department A; member_history names the app member m1 (who also serves in
 * department B); followups_task names m1's task in department A.
 */
export function expectRead(p, read) {
  if (p.outcome !== 'granted') return denial(p);
  const admin = p.roles.includes('admin');
  const pastor = p.roles.includes('pastor');
  switch (read) {
    case 'duties_admin_overview':
    case 'followups_admin_routing':
      return admin ? ok : ng;
    case 'duties_rota':
    case 'duties_leader_board':
      return admin || pastor || anyDept(p) ? ok : ng;
    case 'duties_coverage':
      return admin || pastor || holds(p, 'A') ? ok : ng;
    case 'duties_candidates':
      return admin || holds(p, 'A') ? ok : ng;
    case 'duties_member_history':
      return p.self || holds(p, 'A') || holds(p, 'B') ? ok : ng;
    case 'duties_my_duties':
    case 'followups_my_tasks':
      return ok;
    case 'duties_outcomes':
      return anyDept(p) ? ok : ng;
    case 'followups_supervision':
      return anyDept(p) || p.cellScope ? ok : ng;
    case 'followups_task':
      return p.self || holds(p, 'A') || admin ? ok : ng;
    default:
      throw new Error(`no expectation for ${read}`);
  }
}

/**
 * Command probes that cannot change anything: each names a real record of department A with a
 * stale expected revision (STALE), so a caller with authority is answered `conflict` and every other
 * caller is refused before the revision is read.
 */
export const PROBES = [
  { cmd: 'duties.revise_duty', fn: 'duties_command', target: 'one-off duty of A' },
  { cmd: 'duties.set_reminders', fn: 'duties_command', target: 'one-off duty of A' },
  { cmd: 'duties.cancel_position', fn: 'duties_command', target: 'unfilled rota position of A' },
  { cmd: 'duties.confirm_by_leader', fn: 'duties_command', target: 'the accountless member\'s assignment' },
  { cmd: 'duties.record_contact_attempt', fn: 'duties_command', target: 'the accountless member\'s assignment' },
  { cmd: 'duties.respond', fn: 'duties_command', target: 'the app member\'s assignment' },
  { cmd: 'duties.withdraw_acceptance', fn: 'duties_command', target: 'the app member\'s assignment' },
  { cmd: 'duties.add_member', fn: 'duties_command', target: 'department A' },
  { cmd: 'duties.remove_member', fn: 'duties_command', target: 'department A' },
  { cmd: 'followups.update_task', fn: 'followups_command', target: 'the app member\'s task in A' },
  { cmd: 'followups.reassign', fn: 'followups_command', target: 'the app member\'s task in A' },
];

/** The exact expected envelope code (or HTTP 401) of a probe for a principal. */
export function expectProbe(p, cmd) {
  if (p.outcome === 'anon') return { status: 401 };
  if (p.outcome !== 'granted') return { code: 'forbidden' };
  const admin = p.roles.includes('admin');
  const leads = holds(p, 'A');
  switch (cmd) {
    // The occurrence lock: the department's managers (leader, deputy, Admin) reach the revision.
    case 'duties.revise_duty':
    case 'duties.set_reminders':
    case 'duties.cancel_position':
      return { code: leads || admin ? 'conflict' : 'forbidden' };
    // Contact work needs the department's scope: the Admin role alone is refused, anyone else
    // learns nothing (not_found).
    case 'duties.confirm_by_leader':
    case 'duties.record_contact_attempt':
      if (leads) return { code: 'conflict' };
      return { code: admin ? 'forbidden' : 'not_found' };
    // Only the assignee answers their own assignment.
    case 'duties.respond':
    case 'duties.withdraw_acceptance':
      return { code: p.self ? 'conflict' : 'not_found' };
    // Department membership is the Admin's.
    case 'duties.add_member':
    case 'duties.remove_member':
      return { code: admin ? 'conflict' : 'forbidden' };
    // The task's owner and the scope's leaders work it; the Admin sees routing only.
    case 'followups.update_task':
      if (p.self || leads) return { code: 'conflict' };
      return { code: admin ? 'forbidden' : 'not_found' };
    // Reassignment is the scope's leaders' (and an authorised Admin's), never the owner's.
    case 'followups.reassign':
      if (leads || admin) return { code: 'conflict' };
      return { code: p.self ? 'forbidden' : 'not_found' };
    default:
      throw new Error(`no expectation for ${cmd}`);
  }
}

// --------------------------------------------------------------------------------- the cleanup SQL
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const uuidList = (ids) => {
  const list = [...new Set((ids ?? []).filter(Boolean))];
  for (const id of list) if (!UUID.test(id)) throw new Error('cleanup ids must be uuids');
  return list.length ? list.map((id) => `'${id}'`).join(', ') : 'null';
};

/**
 * The SQL that removes a staging run's rows (the owner or parent session runs it after the
 * suite): every occurrence, series, coverage case, contact attempt, outcome, review flag and
 * follow-up task of the kept departments A and B, their jobs, schedules and inbox items, and the
 * per-run departments C (with their grants, memberships and handover obligations). It refuses to
 * run outside a database marked `staging`, and touches only SYNTHETIC departments named
 * `SYNTHETIC Closing Suite...`, whatever ids it is given. People, departments A and B, their
 * memberships and grants are kept for the next run. Audit and lifecycle history stays on purpose
 * (identity audit and lifecycle rows, applications of the relinked account, released holds).
 */
export function stagingCleanupSql({ keptDepartmentIds = [], runDepartmentIds = [], environment = 'staging' }) {
  // `environment` is 'local' only for the --staging-path proof on the local stack.
  if (!['staging', 'local'].includes(environment)) throw new Error('cleanup runs on staging (or local for the proof)');
  if (keptDepartmentIds.length === 0) throw new Error('cleanup needs the kept department ids');
  const kept = uuidList(keptDepartmentIds);
  const runOnly = uuidList(runDepartmentIds);
  const suiteDepartment = `d.is_synthetic and d.name like 'SYNTHETIC Closing Suite%'`;
  return [
    '-- Story 4.15 closing suite: remove one staging run\'s rows (SYNTHETIC data only).',
    '-- Never run it while a suite run is in progress (runs must not overlap).',
    'begin;',
    `do $guard$ begin
  if app.platform_current_environment() is distinct from '${environment}' then
    raise exception 'the closing-suite cleanup runs only on ${environment}';
  end if;
end $guard$;`,
    `create temp table suite_kept on commit drop as
  select d.department_id from app.duties_departments d where d.department_id in (${kept}) and ${suiteDepartment};`,
    `create temp table suite_run on commit drop as
  select d.department_id from app.duties_departments d where d.department_id in (${runOnly}) and ${suiteDepartment}
     and d.department_id not in (select department_id from suite_kept);`,
    `create temp table suite_departments on commit drop as
  select department_id from suite_kept union select department_id from suite_run;`,
    `create temp table suite_occurrences on commit drop as
  select o.occurrence_id from app.duties_occurrences o where o.department_id in (select department_id from suite_departments);`,
    `create temp table suite_assignments on commit drop as
  select a.assignment_id from app.duties_assignments a join app.duties_slots s on s.slot_id = a.slot_id
   where s.occurrence_id in (select occurrence_id from suite_occurrences);`,
    `create temp table suite_cases on commit drop as
  select c.case_id from app.duties_coverage_cases c where c.assignment_id in (select assignment_id from suite_assignments);`,
    `create temp table suite_flags on commit drop as
  select f.flag_id from app.duties_review_flags f where f.occurrence_id in (select occurrence_id from suite_occurrences);`,
    `create temp table suite_tasks on commit drop as
  select t.task_id from app.followups_tasks t where t.scope_id in (select department_id from suite_departments)
      or (t.source_type = 'duties_coverage_case' and t.source_id in (select case_id from suite_cases));`,
    `create temp table suite_sources on commit drop as
  select assignment_id as id from suite_assignments union select occurrence_id from suite_occurrences
  union select task_id from suite_tasks union select case_id from suite_cases union select flag_id from suite_flags
  union select department_id from suite_departments;`,
    `create temp table suite_jobs on commit drop as
  select j.job_id from app.notifications_jobs j where j.source_id in (select id from suite_sources);`,
    'delete from app.notifications_attempts a where a.job_id in (select job_id from suite_jobs);',
    'delete from app.notifications_direct_contact_needs n where n.job_id in (select job_id from suite_jobs);',
    'delete from app.notifications_push_jobs p where p.job_id in (select job_id from suite_jobs);',
    'update app.notifications_jobs j set snoozed_from_item_id = null where j.job_id in (select job_id from suite_jobs);',
    'delete from app.notifications_inbox_items i where i.job_id in (select job_id from suite_jobs);',
    'delete from app.notifications_jobs j where j.job_id in (select job_id from suite_jobs);',
    'delete from app.notifications_schedules s where s.source_id in (select id from suite_sources);',
    'delete from app.followups_notes n where n.task_id in (select task_id from suite_tasks);',
    'delete from app.followups_activity a where a.task_id in (select task_id from suite_tasks);',
    'delete from app.followups_tasks t where t.task_id in (select task_id from suite_tasks);',
    '-- Outcomes go with their assignments (append-only; removed only by the cascade).',
    'delete from app.duties_contact_attempts t where t.assignment_id in (select assignment_id from suite_assignments);',
    'delete from app.duties_coverage_cases c where c.case_id in (select case_id from suite_cases);',
    'delete from app.duties_contact_needs n where n.assignment_id in (select assignment_id from suite_assignments);',
    `delete from app.duties_audit a where a.occurrence_id in (select occurrence_id from suite_occurrences)
   or a.department_id in (select department_id from suite_run);`,
    'delete from app.duties_slot_revisions r where r.occurrence_id in (select occurrence_id from suite_occurrences);',
    'delete from app.duties_assignments a where a.assignment_id in (select assignment_id from suite_assignments);',
    '-- Review flags go with their occurrences.',
    'delete from app.duties_slots s where s.occurrence_id in (select occurrence_id from suite_occurrences);',
    'delete from app.duties_occurrences o where o.occurrence_id in (select occurrence_id from suite_occurrences);',
    'delete from app.duties_series r where r.department_id in (select department_id from suite_departments);',
    `delete from app.duties_department_members dm where dm.department_id in (select department_id from suite_kept)
   and dm.ended_at is not null;`,
    'delete from app.identity_handover_obligations o where o.subject_id in (select department_id from suite_run);',
    'delete from app.duties_department_members dm where dm.department_id in (select department_id from suite_run);',
    `delete from app.identity_grants g where g.scope_id in (select department_id from suite_run)
   and g.scope_kind in ('department_leader', 'department_deputy');`,
    'delete from app.duties_departments d where d.department_id in (select department_id from suite_run);',
    'commit;',
    '',
  ].join('\n');
}

// --------------------------------------------------------------------------------- the summary
const ABBR = { conflict: 'cf', forbidden: 'fb', not_found: 'nf', validation_failed: 'vf', unauthenticated: 'ua', success: 'OK' };
/** The readable summary: the scenario checks, both matrices and the items not run on this target. */
export function renderSummary({ target, results, matrixRows, notRun }) {
  const lines = [`# Duties closing suite summary (tools/identity-e2e/duties-staging-suite.mjs, target ${target})`, ''];
  const scen = results.filter((r) => !r.step.startsWith('M-'));
  const mat = results.filter((r) => r.step.startsWith('M-'));
  lines.push(`Scenario checks: ${scen.filter((r) => r.ok).length}/${scen.length} passed. `
    + `Matrix cells: ${matrixRows.filter((r) => r.ok).length}/${matrixRows.length} as expected (${mat.filter((r) => r.ok).length}/${mat.length} matrix checks).`, '');
  lines.push('| Check | Verdict |', '|---|---|');
  for (const r of scen) lines.push(`| ${r.step} | ${r.ok ? 'pass' : 'FAIL'} |`);
  const principals = Object.keys(PRINCIPALS);
  const cell = (r) => {
    if (!r) return '';
    const v = r.kind === 'read'
      ? (r.got.status === 200 ? '200' : `${r.got.status}${r.got.detail ? ` ${({ not_granted: 'ng', not_linked: 'nl', review_required: 'rr' })[r.got.detail] ?? r.got.detail}` : ''}`)
      : (r.got.status ? String(r.got.status) : ABBR[r.got.code] ?? r.got.code);
    return r.ok ? v : `**${v}≠**`;
  };
  for (const kind of ['read', 'command']) {
    const rows = matrixRows.filter((r) => r.kind === kind);
    if (!rows.length) continue;
    lines.push('', `## ${kind === 'read' ? 'Reads' : 'Command probes'} (rows: surface; columns: principal)`, '');
    lines.push(`| ${kind === 'read' ? 'Read' : 'Command'} | ${principals.join(' | ')} |`, `|---|${principals.map(() => '---').join('|')}|`);
    for (const s of [...new Set(rows.map((r) => r.surface))]) {
      lines.push(`| ${s} | ${principals.map((p) => cell(rows.find((r) => r.surface === s && r.principal === p))).join(' | ')} |`);
    }
  }
  lines.push('', 'Legend: reads 200 / 401 / 403 with detail (ng not_granted, nl not_linked, rr review_required); command envelope codes '
    + 'cf conflict (authorised, stale revision: nothing changed), fb forbidden, nf not_found (nothing disclosed), 401 signed out. '
    + 'A cell marked ≠ differs from the expectation. Principals: m1 an app member of A and B (owner of the probed task and '
    + 'assignment), cellL a cell leader with no department authority, admin the Admin role alone, leadA/depA department A\'s '
    + 'leader and deputy, leadB another department\'s leader; deact is deactivated. Scope loss and the accountless member are '
    + 'scenario checks (S90-scope-loss, S60).');
  if (notRun.length) { lines.push('', '## Not run on this target', ''); for (const s of notRun) lines.push(`- ${s}`); }
  return lines.join('\n') + '\n';
}

// ---------------------------------------------------------------------------------------- run
async function main() {
  const argv = process.argv;
  const target = parseTarget(argv, process.env);
  const evidence = argValue(argv, '--evidence');
  const summaryPath = argValue(argv, '--summary');
  const cleanupSqlPath = argValue(argv, '--cleanup-sql');
  const stagingPath = target === 'local' && argv.includes('--staging-path');
  const rerunState = stagingPath ? argValue(argv, '--rerun-state') : null;
  const sqlChecks = target === 'local' && !stagingPath;
  const numbers = NUMBERS[target];
  for (const phone of Object.values(numbers)) if (!isSuitePhone(target, phone)) throw new Error(`not fictional: ${phone}`);
  const runId = randomUUID().slice(0, 8);
  const cal = runCalendar(Date.now(), runId);

  // ---- evidence (redacted; never a token, password, number, name, note or reason)
  if (evidence) writeFileSync(evidence, '');
  const results = [];
  const matrixRows = [];
  const notRun = [];
  const log = (step, data = {}) => {
    const line = { step, target: target.toUpperCase(), at: new Date().toISOString(), ...redactEvidence(data) };
    if (evidence) appendFileSync(evidence, JSON.stringify(line) + '\n');
    console.log(JSON.stringify(line));
  };
  const check = (step, pass, data = {}) => {
    results.push({ step, ok: Boolean(pass) });
    log(step, { verdict: pass ? 'pass' : 'FAIL', ...data });
    return Boolean(pass);
  };

  // ---- HTTP: the local stack (exact origin) or the staging project (publishable key only)
  let http;
  let origin;
  let publishableKey;
  let state;
  let saveState = () => {};
  let borrowed = {};
  if (target === 'local') {
    const keys = localKey();
    origin = keys.origin;
    publishableKey = keys.key;
    http = localHttp(keys);
    state = { personas: {} };
    // Local --staging-path rehearsal of a second staging run: the state persists between two runs
    // (the first with --keep), as DUTIES_SUITE_STATE does on staging.
    if (rerunState) {
      assertStateOutsideRepo(rerunState);
      if (existsSync(rerunState)) state = JSON.parse(readFileSync(rerunState, 'utf8'));
      state.personas ??= {};
      saveState = () => { writeFileSync(rerunState, JSON.stringify(state), { mode: 0o600 }); chmodSync(rerunState, 0o600); };
    }
  } else {
    origin = assertStagingOrigin(STAGING_ORIGIN);
    publishableKey = assertPublishableKey(process.env.STAGING_PUBLISHABLE_KEY);
    const adminFile = assertStateOutsideRepo(process.env.STAGING_SUITE_ADMIN);
    const identityState = assertStateOutsideRepo(process.env.STAGING_SUITE_STATE);
    const statePath = assertStateOutsideRepo(process.env.DUTIES_SUITE_STATE);
    if (cleanupSqlPath) assertStateOutsideRepo(cleanupSqlPath);
    state = existsSync(statePath) ? JSON.parse(readFileSync(statePath, 'utf8')) : {};
    state.personas ??= {};
    state.runDepartments ??= [];
    state.admin = { pw: JSON.parse(readFileSync(adminFile, 'utf8')).pw };
    if (!state.admin.pw) throw new Error('STAGING_SUITE_ADMIN has no pw');
    const idState = JSON.parse(readFileSync(identityState, 'utf8'));
    for (const [label, idLabel] of Object.entries(BORROWED)) {
      const st = idState.personas?.[idLabel];
      if (!st?.pw || !st?.phone || !isSuiteFictional(st.phone)) throw new Error(`STAGING_SUITE_STATE has no usable ${idLabel} persona`);
      borrowed[label] = { phone: st.phone, pw: st.pw };
    }
    saveState = () => {
      const { admin, ...kept } = state;
      const tmp = `${statePath}.tmp`;
      writeFileSync(tmp, JSON.stringify(kept), { mode: 0o600 });
      chmodSync(tmp, 0o600);
      renameSync(tmp, statePath);
      chmodSync(statePath, 0o600);
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
        if (res.status === 429 && path.startsWith('/auth/') && attempt < 6) {
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
  const envelope = (fn, token, cmd, expected, payload, requestId = randomUUID()) =>
    rpc(fn, token, { version: 1, command: cmd, request_id: requestId, expected_revision: expected ?? null, payload })
      .then((r) => ({ status: r.status, ...(r.json ?? {}) }));
  const outcome = (r) => (r?.code ? { code: r.code, field_errors: r.field_errors ?? null } : { status: r?.status });
  const done = (r) => r?.status === 200 && !r?.code;

  // ---- the people
  const people = {};
  const person = (label, phone, extra = {}) => (people[label] = { label, phone, name: `${NAME_PREFIX} ${label}`, ...extra });
  person('admin', numbers.admin);
  for (const label of DUTIES_PEOPLE) person(label, numbers[label]);
  for (const label of Object.keys(BORROWED)) person(label, target === 'local' ? numbers[label] : borrowed[label].phone);
  const accountless = { label: 'X', name: `${NAME_PREFIX} accountless X` };
  const tok = async (p, { fresh = false } = {}) => {
    if (!fresh && p.token && Date.now() - p.tokenAt < 40 * MINUTE) return p.token;
    const s = await signIn(p.phone, p.pw);
    p.token = s.json?.access_token;
    p.tokenAt = Date.now();
    return p.token;
  };
  const afterEpoch = async (p) => { await sleep(EPOCH_WAIT_MS); return tok(p, { fresh: true }); };
  const duty = async (p, cmd, expected, payload, requestId) => envelope('duties_command', await tok(p), cmd, expected, payload, requestId);
  const task = async (p, cmd, expected, payload) => envelope('followups_command', await tok(p), cmd, expected, payload);
  const R = async (p, fn, body = {}) => {
    const r = await rpc(fn, p ? await tok(p) : undefined, body);
    return Object.defineProperty({ status: r.status, detail: r.json?.details ?? undefined }, 'json', { value: r.json, enumerable: false });
  };
  const users = new Set();
  const run = { departments: {}, occurrences: [], series: [], tasks: [], createdC: null, lifeUnlinked: false, lifeDeactivated: false,
    m2Deputy: false, holdIds: [] };

  // ---- local only: the environment marker, worker credential and SQL cleanup
  let marked = false;
  let workerHandle = null;
  const localCleanup = () => {
    const ids = [...users].filter(Boolean).map((u) => `'${u}'`);
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
      select d.department_id from app.duties_departments d where d.name like 'SYNTHETIC Closing Suite%';
    create temp table gone_cells as select c.cell_id from app.cells_cells c where c.name like '${NAME_PREFIX}%';
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
    delete from app.fixture_events e where e.title like '${NAME_PREFIX}%';
    delete from app.identity_handover_obligations o where o.member_id in (select member_id from gone_members);
    delete from app.identity_membership_lifecycle e
     where e.member_id in (select member_id from gone_members) or e.actor_member_id in (select member_id from gone_members);
    delete from app.identity_credential_review_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
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
       or g.scope_id in (select department_id from gone_departments) or g.scope_id in (select cell_id from gone_cells);
    delete from app.duties_departments d where d.department_id in (select department_id from gone_departments);
    delete from app.cells_membership_audit a where a.cell_id in (select cell_id from gone_cells);
    delete from app.cells_signup_options o where o.cell_id in (select cell_id from gone_cells);
    delete from app.cells_cells c where c.cell_id in (select cell_id from gone_cells);
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
  /** Local: the worker runs now. Staging: the scheduled worker runs every minute; wait for it. */
  const settle = async (doneFn, { timeoutMs = 4 * MINUTE } = {}) => {
    const until = Date.now() + timeoutMs;
    for (let round = 0; ; round += 1) {
      if (workerHandle) await workerHandle.worker();
      const value = await doneFn();
      if (value) return value;
      if (target === 'local' ? round >= 8 : Date.now() > until) return value;
      await sleep(target === 'staging' ? 15_000 : 1000);
    }
  };

  // ---- reads and helpers (API only, both targets)
  const inbox = async (p) => (await R(p, 'notifications_my_inbox')).json?.items ?? [];
  const seen = async (p) => new Set((await inbox(p)).map((i) => i.item_id));
  const fresh = (items, baseline, kind) => items.filter((i) => !baseline.has(i.item_id) && (!kind || i.reminder_kind === kind));
  const openItem = async (p, itemId) => (await R(p, 'notifications_open_item', { item_id: itemId })).json;
  const overview = async () => (await R(people.admin, 'duties_admin_overview')).json;
  const department = async (id) => ((await overview())?.departments ?? []).find((d) => d.department_id === id);
  const deptRevision = async (id) => (await department(id))?.revision;
  const memberRow = async (memberId) => {
    let after = {};
    for (let page = 0; page < 40; page += 1) {
      const r = (await R(people.admin, 'identity_admin_member_search', { query: null, ...after })).json;
      const hit = (r?.members ?? []).find((m) => m.member_id === memberId);
      if (hit) return hit;
      if (!r?.next) return null;
      after = { after_display_name: r.next.after_display_name, after_member_id: r.next.after_member_id };
    }
    return null;
  };
  const memberRevision = async (memberId) => (await memberRow(memberId))?.revision;
  const grantsRow = async (memberId) => {
    let after = {};
    for (let page = 0; page < 40; page += 1) {
      const r = (await R(people.admin, 'identity_admin_member_grants', after)).json;
      const hit = (r?.members ?? []).find((m) => m.member_id === memberId);
      if (hit) return { revision: hit.grants?.revision, scopes: hit.grants?.scopes ?? [], roles: hit.grants?.roles ?? [] };
      if (!r?.next) return null;
      after = { after_display_name: r.next.after_display_name, after_member_id: r.next.after_member_id };
    }
    return null;
  };
  const grantCmd = async (cmd, p, kind, scopeId) => envelope('identity_grant_command', await tok(people.admin), cmd,
    (await grantsRow(p.member))?.revision, { member_id: p.member, scope_kind: kind, scope_id: scopeId });
  const holdsScope = async (p, kind, scopeId) => ((await grantsRow(p.member))?.scopes ?? [])
    .some((s) => s.scope_kind === kind && s.scope_id === scopeId);
  const ensureScope = async (p, kind, scopeId) => (await holdsScope(p, kind, scopeId) ? 'held' : outcome(await grantCmd('identity.grant_scope', p, kind, scopeId)));
  const myDuties = async (p) => (await R(p, 'duties_my_duties')).json?.assignments ?? [];
  const mine = async (p, id) => (await myDuties(p)).find((a) => a.assignment_id === id) ?? null;
  const board = async (p) => (await R(p, 'duties_leader_board')).json;
  const coverage = async (p, extra = {}) => R(p, 'duties_coverage', { from_date: cal.from, to_date: cal.to, ...extra });
  const occRevision = async (occurrenceId) => boardEntry(await board(people.leadA), occurrenceId)?.duty?.revision;
  const startsAt = (dayOffset, hhmm = `18:${cal.minute}`) => churchInstant(addDays(cal.base, dayOffset), hhmm);
  const publish = async (by, departmentKey, member, dayOffset, extra = {}) => {
    const r = await duty(by, 'duties.publish_duty', null, {
      department_id: run.departments[departmentKey], duty_name: extra.name ?? `Closing duty ${dayOffset}`,
      starts_at: extra.starts_at ?? startsAt(dayOffset, extra.time), location: 'SYNTHETIC hall',
      ...(member ? { member_id: member } : {}), ...(extra.payload ?? {}) });
    if (r.data?.occurrence_id) run.occurrences.push({ id: r.data.occurrence_id, dept: departmentKey });
    return r;
  };

  /** Sign up, apply and be approved by the Admin (staging route), or reuse the state's persona. */
  const ensureByApplication = async (p) => {
    const st = (state.personas[p.label] ??= { phone: p.phone });
    if (st.phone !== p.phone) throw new Error(`state file persona ${p.label} has another number`);
    if (!st.pw) {
      st.pw = `Synthetic-${randomBytes(15).toString('base64url')}`;
      saveState();
      const up = await http('POST', '/auth/v1/signup', { body: { phone: p.phone, password: st.pw } });
      if (up.status !== 200 || !up.json?.access_token) {
        throw new Error(`sign-up for ${p.label} failed (${up.status}): the number may already hold another account; see duties.md story 4.15`);
      }
      users.add(up.json?.user?.id);
    }
    p.pw = st.pw;
    if (!(await tok(p, { fresh: true }))) throw new Error(`persona ${p.label} cannot sign in; fix the state file`);
    let summary = await R(p, 'identity_my_member_summary');
    if (summary.status !== 200 && summary.detail === 'not_linked') {
      await applyAndApprove(p, st.member ?? null);
      summary = await R(p, 'identity_my_member_summary');
    }
    if (summary.status !== 200) throw new Error(`persona ${p.label} is ${summary.detail ?? summary.status}; heal it by hand`);
    p.member = summary.json?.member_id;
    st.member = p.member;
    saveState();
  };
  /** The account applies; the Admin approves it as a new member, or links it to `memberId`. */
  const applyAndApprove = async (p, memberId) => {
    const application = (await R(p, 'identity_my_application')).json;
    const pending = application?.application;
    let applicationId = ['submitted', 'needs_details'].includes(pending?.application_state) ? pending.application_id : null;
    if (!applicationId) {
      const sent = await envelope('identity_application_command', await tok(p), 'identity.submit_application', null,
        { full_name: p.name, cell_choice: { choice: 'not_sure' }, privacy_notice_version: application?.privacy_notice?.version });
      applicationId = sent.data?.application_id;
      if (!applicationId) throw new Error(`application for ${p.label} refused: ${sent.code}`);
    }
    const queue = (await R(people.admin, 'identity_admin_application_queue')).json?.applications ?? [];
    const item = queue.find((a) => a.application_id === applicationId);
    const decided = memberId
      ? await envelope('identity_review_command', await tok(people.admin), 'identity.link_application', item?.revision,
        { application_id: applicationId, member_id: memberId, identity_check: 'in_person' })
      : await envelope('identity_review_command', await tok(people.admin), 'identity.approve_application', item?.revision,
        { application_id: applicationId, identity_check: 'in_person' });
    if (!done(decided)) throw new Error(`${memberId ? 'link' : 'approval'} for ${p.label} refused: ${decided.code}`);
    await afterEpoch(p);
    return decided;
  };
  /** Local: an account and member through the Auth admin route and the synthetic seed link. */
  const seed = async (p, { link = true } = {}) => {
    p.pw = `Synthetic-${randomBytes(12).toString('base64url')}`;
    const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.pw } });
    p.user = created.json?.id;
    users.add(p.user);
    if (link) p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'duties-staging-suite')`);
    await tok(p, { fresh: true });
  };

  let apiCleanupDone = false;
  const apiCleanup = async () => {
    if (apiCleanupDone || !people.leadA.member) return;
    apiCleanupDone = true;
    const out = { occurrences: [], series: [], tasks: [], restored: [] };
    try {
      // People first: a broken run may have left the lifecycle person unlinked, deactivated or held.
      if (run.lifeUnlinked) {
        await applyAndApprove(people.life, people.life.member);
        out.restored.push('relinked');
      }
      if (run.lifeDeactivated) {
        const r = await envelope('identity_lifecycle_command', await tok(people.admin), 'identity.restore_membership',
          run.lifeRevision, { member_id: people.life.member, identity_check: 'in_person' });
        out.restored.push(done(r) ? 'restored' : r.code);
      }
      for (const h of run.holdIds) {
        const r = await envelope('identity_credential_command', await tok(people.admin), 'identity.release_hold',
          await memberRevision(h.member), { member_id: h.member, hold_id: h.hold_id, identity_check: 'in_person' });
        out.restored.push(done(r) ? 'released' : r.code);
      }
      if (run.m2Deputy) out.restored.push(outcome(await grantCmd('identity.revoke_scope', people.m2, 'department_deputy', run.departments.A)));
      const life = await R(people.life, 'duties_my_duties');
      if (life.status === 200) {
        const inA = ((await department(run.departments.A))?.members ?? []).some((m) => m.member_id === people.life.member);
        if (!inA) {
          out.restored.push(outcome(await duty(people.admin, 'duties.add_member', await deptRevision(run.departments.A),
            { department_id: run.departments.A, member_id: people.life.member })));
        }
      }
    } catch (e) {
      out.restored.push(`error: ${String(e?.message ?? e).slice(0, 80)}`);
    }
    for (const s of run.series) {
      const rota = (await R(people.leadA, 'duties_rota')).json;
      const series = (rota?.departments ?? []).flatMap((d) => d.series ?? []).find((x) => x.series_id === s);
      const first = (series?.occurrences ?? []).filter((o) => o.state !== 'cancelled' && !o.started)
        .sort((a, b) => a.series_date.localeCompare(b.series_date))[0];
      if (first) {
        out.series.push(outcome(await duty(people.leadA, 'duties.cancel_series', series.revision,
          { series_id: s, from_occurrence_id: first.occurrence_id })));
      }
    }
    for (const o of run.occurrences) {
      // A one-off duty is cancelled by cancelling its position (the last position cancels the date).
      const by = o.dept === 'B' ? people.leadB : people.leadA;
      const entry = boardEntry(await board(by), o.id);
      if (!entry || entry.duty.state === 'cancelled') continue;
      if (Date.parse(entry.duty.starts_at) <= Date.now()) { out.started = (out.started ?? 0) + 1; continue; }
      for (const pos of (entry.duty.positions ?? []).filter((x) => !x.cancelled)) {
        const rev = boardEntry(await board(by), o.id)?.duty?.revision;
        out.occurrences.push(outcome(await duty(by, 'duties.cancel_position', rev, { slot_id: pos.slot_id })));
      }
    }
    for (const t of run.tasks) {
      const view = (await R(people.leadA, 'followups_task', { p_task_id: t })).json?.task;
      if (view && !['done', 'closed'].includes(view.state)) {
        out.tasks.push(outcome(await task(people.leadA, 'followups.update_task', view.revision,
          { task_id: t, status: 'closed', close_reason: 'SYNTHETIC: closing suite cleanup' })));
      }
    }
    const allOk = [...out.occurrences, ...out.series, ...out.tasks].every((x) => x.status === 200)
      && out.restored.every((x) => typeof x !== 'string' || !x.startsWith('error'));
    check('S98-api-cleanup-cancels-closes-and-restores', allOk, out);
  };

  try {
    // ====================================================================== S00 precondition
    if (target === 'local') {
      const settings = await http('GET', '/auth/v1/settings');
      if (settings.json?.external?.phone !== true) {
        throw new Error('the local phone provider is off: run `node tools/auth-harness/local-phone-auth.mjs on` first');
      }
      const marker = psql(`select coalesce((select environment from app.platform_environment), '')`);
      if (marker === '') {
        psql(`select app.platform_set_environment('local', 'duties-staging-suite')`);
        marked = true;
      } else if (marker !== 'local') {
        throw new Error(`local database is marked ${marker}`);
      }
      const reuse = Boolean(state.local);
      log('S00-precondition', { phone_provider: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null,
        leftover_users_removed: reuse ? 'kept for the rerun' : localCleanup(), run: runId, staging_path: stagingPath, rerun: reuse });
      workerHandle = notificationsWorker({ origin, key: publishableKey, operator: OPERATOR,
        principalName: `notifications-worker-closing-${runId}`, label: `duties closing suite ${runId}` });
      // The Admin and the people the identity suite provides on staging.
      if (reuse) {
        for (const label of ['admin', ...Object.keys(BORROWED)]) Object.assign(people[label], state.local[label]);
        for (const label of DUTIES_PEOPLE) await ensureByApplication(people[label]);
        for (const label of ['admin', ...Object.keys(BORROWED)]) await tok(people[label], { fresh: true });
      } else {
        await seed(people.admin);
        psql(`select app.identity_bootstrap_admin('${people.admin.member}', '${OPERATOR}')`);
        await tok(people.admin, { fresh: true });
        for (const label of ['pastor', 'held', 'deact', 'cellL']) await seed(people[label]);
        await seed(people.guest, { link: false });
        for (const label of DUTIES_PEOPLE) {
          if (stagingPath) await ensureByApplication(people[label]);
          else await seed(people[label]);
        }
        const pastorGrant = await envelope('identity_grant_command', await tok(people.admin), 'identity.grant_role',
          (await grantsRow(people.pastor.member))?.revision, { member_id: people.pastor.member, role: 'pastor' });
        const cell = await envelope('cells_command', await tok(people.admin), 'cells.create_cell', null,
          { name: `${NAME_PREFIX} Cell`, signup_label: `${NAME_PREFIX} Cell`, broad_area: 'SYNTHETIC North' });
        const cellGrant = await grantCmd('identity.grant_scope', people.cellL, 'cell_leader', cell.data?.cell_id);
        const hold = await envelope('identity_credential_command', await tok(people.admin), 'identity.place_hold',
          await memberRevision(people.held.member), { member_id: people.held.member, reason_code: 'login_disabled' });
        const deact = await envelope('identity_lifecycle_command', await tok(people.admin), 'identity.deactivate_membership',
          await memberRevision(people.deact.member), { member_id: people.deact.member, reason_code: 'moved_away' });
        log('S00-local-people', { pastor: outcome(pastorGrant), cell: outcome(cell), cell_leader: outcome(cellGrant), hold: outcome(hold),
          deactivated: outcome(deact) });
        for (const label of ['pastor', 'cellL', 'held', 'deact']) await afterEpoch(people[label]);
        if (rerunState) {
          state.local = Object.fromEntries(['admin', ...Object.keys(BORROWED)].map((l) => [l, { pw: people[l].pw, member: people[l].member }]));
          saveState();
        }
      }
    } else {
      const A = people.admin;
      A.pw = state.admin.pw;
      for (const [label, b] of Object.entries(borrowed)) people[label].pw = b.pw;
      if (!(await tok(A, { fresh: true }))) throw new Error('the synthetic Admin cannot sign in on staging');
      const access = (await R(A, 'identity_my_access')).json;
      if (!access?.roles?.includes('admin')) throw new Error('the synthetic Admin has no Admin role on staging');
      A.member = access.member_id;
      for (const label of DUTIES_PEOPLE) await ensureByApplication(people[label]);
      for (const label of Object.keys(BORROWED)) await tok(people[label], { fresh: true });
      log('S00-precondition', { origin_checked: true, run: runId, personas: DUTIES_PEOPLE.length, borrowed: Object.keys(BORROWED).length });
    }

    // Each borrowed principal must be what the matrix says it is (never changed by this suite).
    const access = {};
    for (const label of ['admin', 'pastor', 'guest', 'held', 'deact', 'cellL', ...DUTIES_PEOPLE]) {
      const r = await R(people[label], 'identity_my_access');
      access[label] = r.status === 200 ? { roles: r.json?.roles ?? [], scopes: (r.json?.scopes ?? []).map((s) => s.scope_kind) } : r.detail ?? r.status;
      if (r.status === 200) people[label].member ??= r.json?.member_id;
    }
    const adminScopes = (await grantsRow(people.admin.member))?.scopes ?? [];
    check('S01-people-signed-in-and-principals-as-the-matrix-says',
      [...DUTIES_PEOPLE, 'admin', 'pastor', 'cellL'].every((l) => people[l].token && amrMethods(people[l].token).includes('password'))
      && JSON.stringify(access.admin?.roles) === '["admin"]' && adminScopes.every((s) => !s.scope_kind?.startsWith('department'))
      && access.pastor?.roles?.includes('pastor') && !access.pastor?.roles?.includes('admin')
      && access.cellL?.scopes?.includes('cell_leader') && !access.cellL?.roles?.includes('admin')
      && access.guest === 'not_linked' && access.held === 'review_required' && access.deact === 'not_linked',
      { access });
    // Review: nothing is written when the people are not what the matrix expects.
    if (!results.at(-1).ok) throw new Error('S01 failed: the people are not as the matrix expects; nothing was changed');

    // ====================================================================== S02 departments, scopes, members
    const ov = await overview();
    for (const [key, name] of Object.entries(DEPARTMENTS)) {
      const found = (ov?.departments ?? []).find((d) => d.name.toLowerCase() === name.toLowerCase());
      if (found) {
        // Review: only a SYNTHETIC department of this suite is reused.
        if (found.is_synthetic !== true) throw new Error(`department ${key} exists but is not synthetic; nothing was changed`);
        run.departments[key] = found.department_id;
      } else {
        const created = await duty(people.admin, 'duties.create_department', null, { name });
        run.departments[key] = created.data?.department_id;
      }
    }
    state.departments = { A: run.departments.A, B: run.departments.B };
    // A per-run department C leaves the list once a cleanup has removed it (the owner runs the
    // cleanup SQL after the suite, so it is confirmed only here, by its absence).
    if (state.runDepartments) {
      const live = new Set((ov?.departments ?? []).map((d) => d.department_id));
      state.runDepartments = state.runDepartments.filter((id) => live.has(id));
    }
    saveState();
    // Heal a broken run: the scope-loss person holds no deputy scope at the start.
    if (await holdsScope(people.m2, 'department_deputy', run.departments.A)) {
      await grantCmd('identity.revoke_scope', people.m2, 'department_deputy', run.departments.A);
    }
    const scopes = {
      leadA: await ensureScope(people.leadA, 'department_leader', run.departments.A),
      depA: await ensureScope(people.depA, 'department_deputy', run.departments.A),
      leadB: await ensureScope(people.leadB, 'department_leader', run.departments.B),
    };
    // The accountless member X: an Admin record with a labelled SYNTHETIC household number.
    if (state.accountless?.member) {
      // Review: the reused record must still be this suite's SYNTHETIC accountless member.
      const row = await memberRow(state.accountless.member);
      if (!row || row.display_name !== accountless.name) {
        throw new Error('the state file\'s accountless member is not this suite\'s SYNTHETIC record; fix the state file');
      }
      accountless.member = state.accountless.member;
    } else {
      const x = await envelope('identity_review_command', await tok(people.admin), 'identity.create_member', null, {
        full_name: accountless.name, consent_basis: 'in_person',
        contact_route: { phone: numbers.household, belongs_to: 'household', holder_label: 'SYNTHETIC household' } });
      accountless.member = x.data?.member_id;
      state.accountless = { member: accountless.member };
      saveState();
    }
    const added = [];
    for (const [key, p] of [['A', people.m1], ['A', people.m2], ['A', people.life], ['A', accountless], ['B', people.m1]]) {
      const r = await duty(people.admin, 'duties.add_member', await deptRevision(run.departments[key]),
        { department_id: run.departments[key], member_id: p.member });
      added.push(done(r) ? 'added' : (r.field_errors?.member_id === 'current' ? 'already' : r.code));
    }
    for (const l of ['leadA', 'depA', 'leadB']) await tok(people[l], { fresh: true });
    check('S02-departments-scopes-and-members', Boolean(run.departments.A && run.departments.B && accountless.member)
      && Object.values(scopes).every((s) => s === 'held' || s.status === 200)
      && added.every((a) => a === 'added' || a === 'already'),
      { scopes, members: added });
    if (!results.at(-1).ok) throw new Error('S02 failed: the departments are not set up; no duty was written');

    // The started duties for completion (S70) are published first so they have started by then.
    const soon = minuteCeil(Date.now() + 4 * MINUTE);
    const seenL05 = await seen(people.leadA);
    const seenM05 = await seen(people.m1);
    const dDone = await publish(people.leadA, 'A', people.m1.member, 0, { name: 'Closing completion', starts_at: soon });
    const dQuiet = await publish(people.leadA, 'A', people.m2.member, 0, { name: 'Closing unanswered', starts_at: soon });
    const doneMine = await mine(people.m1, dDone.data?.assignment_id);
    const doneAccept = await duty(people.m1, 'duties.respond', doneMine?.revision,
      { assignment_id: dDone.data?.assignment_id, response: 'accepted' });

    // ====================================================================== S10 department rota
    const series = await duty(people.leadA, 'duties.create_series', null, {
      department_id: run.departments.A, duty_name: 'Closing rota', every: 'week', from_date: addDays(cal.base, 0),
      until_date: addDays(cal.base, 21), start_time: `09:${cal.minute}`, positions: ['Lead', 'Support'],
      location: 'SYNTHETIC Main hall' });
    const seriesId = series.data?.series_id;
    if (seriesId) run.series.push(seriesId);
    const rotaSeries = async () => ((await R(people.leadA, 'duties_rota')).json?.departments ?? [])
      .flatMap((d) => d.series ?? []).find((s) => s.series_id === seriesId);
    let s = await rotaSeries();
    const dates = [...(s?.occurrences ?? [])].sort((a, b) => a.series_date.localeCompare(b.series_date));
    const slotOf = (occ, no) => (occ?.positions ?? []).find((p) => p.position_no === no)?.slot_id;
    const draftsHidden = (await myDuties(people.m1)).every((a) => !dates.some((o) => o.occurrence_id === a.occurrence_id));
    const memberRota = await R(people.m1, 'duties_rota');
    const planned = [];
    for (const [occ, no, member] of [[dates[0], 1, people.m1.member], [dates[0], 2, accountless.member], [dates[1], 1, people.m2.member]]) {
      const rev = (await rotaSeries())?.occurrences?.find((o) => o.occurrence_id === occ?.occurrence_id)?.revision;
      planned.push((await duty(people.leadA, 'duties.assign_slot', rev, { slot_id: slotOf(occ, no), member_id: member })).status);
    }
    s = await rotaSeries();
    const pub = await duty(people.leadA, 'duties.publish_drafts', s?.revision, { series_id: seriesId, slot_count: s?.draft_slots });
    s = await rotaSeries();
    const posOf = (occId, no) => s?.occurrences?.find((o) => o.occurrence_id === occId)?.positions?.find((p) => p.position_no === no);
    const aM1 = posOf(dates[0]?.occurrence_id, 1)?.assignment?.assignment_id;
    const aX = posOf(dates[0]?.occurrence_id, 2)?.assignment?.assignment_id;
    const aM2 = posOf(dates[1]?.occurrence_id, 1)?.assignment?.assignment_id;
    const unfilledSlot = slotOf(dates[2], 1);
    check('S10-a-rota-is-drafted-hidden-then-published', done(series) && dates.length === 4 && draftsHidden
      && memberRota.status === 403 && planned.every((x) => x === 200) && done(pub) && pub.data?.assignments === 3
      && (s?.occurrences ?? []).every((o) => o.state === 'published') && Boolean(aM1 && aX && aM2),
      { dates: dates.length, drafts_hidden: draftsHidden, member_rota: memberRota.status, planned, published: outcome(pub),
        assignments: pub.data?.assignments ?? null });

    // ====================================================================== S20 revisions
    const d1 = await publish(people.leadA, 'A', people.m1.member, 1, { name: 'Closing revision' });
    const a1 = d1.data?.assignment_id;
    const acc1 = await duty(people.m1, 'duties.respond', (await mine(people.m1, a1))?.revision, { assignment_id: a1, response: 'accepted' });
    const rev1 = await duty(people.leadA, 'duties.revise_duty', await occRevision(d1.data?.occurrence_id),
      { occurrence_id: d1.data?.occurrence_id, location: 'SYNTHETIC side room' });
    const a1b = rev1.data?.assignment_id;
    const late = await duty(people.m1, 'duties.respond', 2, { assignment_id: a1, response: 'accepted' });
    const m1List = await myDuties(people.m1);
    const m1New = m1List.find((a) => a.assignment_id === a1b);
    const acc1b = await duty(people.m1, 'duties.respond', m1New?.revision, { assignment_id: a1b, response: 'accepted' });
    const notes = await duty(people.depA, 'duties.revise_duty', await occRevision(d1.data?.occurrence_id),
      { occurrence_id: d1.data?.occurrence_id, instructions: 'SYNTHETIC: bring the reading.' });
    const afterNotes = await mine(people.m1, a1b);
    const hist = newestHistory(boardEntry(await board(people.leadA), a1b)?.position);
    check('S20-material-change-re-asks-and-the-late-answer-is-refused', done(d1) && done(acc1) && rev1.data?.change === 'material'
      && a1b && a1b !== a1 && late.code === 'conflict' && late.field_errors?.assignment_id === 'superseded'
      && JSON.stringify(changedFields(late.field_errors)) === '["location"]' && !m1List.some((a) => a.assignment_id === a1)
      && m1New?.response === 'pending' && m1New?.previous_response === 'accepted'
      && hist?.state === 'superseded' && hist?.response === 'accepted'
      && done(acc1b) && notes.data?.change === 'notes' && afterNotes?.response === 'accepted',
      { change: rev1.data?.change ?? rev1.code, late: outcome(late), changed: changedFields(late.field_errors),
        new_pending: m1New?.response ?? null, previous: m1New?.previous_response ?? null, history: hist?.state ?? null,
        notes_only: notes.data?.change ?? notes.code, kept: afterNotes?.response ?? null });

    // ====================================================================== S30 responses
    const accM1 = await duty(people.m1, 'duties.respond', (await mine(people.m1, aM1))?.revision, { assignment_id: aM1, response: 'accepted' });
    const decM2 = await duty(people.m2, 'duties.respond', (await mine(people.m2, aM2))?.revision,
      { assignment_id: aM2, response: 'declined', note: `${MEMBER_NOTE} M2: travelling` });
    const withdraw = await duty(people.m1, 'duties.withdraw_acceptance', (await mine(people.m1, a1b))?.revision,
      { assignment_id: a1b, note: `${MEMBER_NOTE} M1: cannot anymore` });
    const three = [await publish(people.leadA, 'A', people.m1.member, 2), await publish(people.leadA, 'A', people.m1.member, 3),
      await publish(people.leadA, 'A', people.m1.member, 4)];
    const listed = await myDuties(people.m1);
    const pick = three.slice(0, 2).map((r) => ({ assignment_id: r.data?.assignment_id,
      revision: listed.find((a) => a.assignment_id === r.data?.assignment_id)?.revision }));
    const bulkId = randomUUID();
    const bulk = await duty(people.m1, 'duties.accept_many', null, { assignments: pick }, bulkId);
    const replay = await duty(people.m1, 'duties.accept_many', null, { assignments: pick }, bulkId);
    const lb30 = await board(people.leadA);
    const answers = three.map((r) => boardEntry(lb30, r.data?.assignment_id)?.position?.assignment?.response);
    const withdrawn = boardEntry(lb30, a1b)?.position?.assignment;
    check('S30-accept-decline-later-decline-and-bulk-acceptance', done(accM1) && done(decM2) && done(withdraw)
      && withdraw.data?.response === 'declined' && withdrawn?.response === 'declined'
      && boardEntry(lb30, aM2)?.position?.assignment?.note === `${MEMBER_NOTE} M2: travelling`
      && done(bulk) && bulk.data?.count === 2 && JSON.stringify(replay.data) === JSON.stringify(bulk.data)
      && JSON.stringify(answers) === '["accepted","accepted","pending"]',
      { accept: outcome(accM1), decline: outcome(decM2), withdraw: withdraw.data?.response ?? withdraw.code, bulk: bulk.data?.count ?? bulk.code,
        replay_same: JSON.stringify(replay.data) === JSON.stringify(bulk.data), answers });

    // ====================================================================== S40 conflicts
    const overlapAt = startsAt(5, `15:${cal.minute}`);
    const inB = await publish(people.leadB, 'B', people.m1.member, 5, { starts_at: overlapAt,
      payload: { ends_at: new Date(Date.parse(overlapAt) + 2 * HOUR).toISOString(), instructions: 'SYNTHETIC B-only instructions' } });
    const atA = new Date(Date.parse(overlapAt) + 30 * MINUTE).toISOString();
    const cands = (await R(people.leadA, 'duties_candidates', { department_id: run.departments.A, starts_at: atA,
      ends_at: new Date(Date.parse(atA) + HOUR).toISOString() })).json;
    const m1Cand = (cands?.candidates ?? []).find((c) => c.member_id === people.m1.member);
    const candText = JSON.stringify(cands ?? {});
    const noReason = await publish(people.leadA, 'A', people.m1.member, 5, { starts_at: atA });
    const withReason = await publish(people.leadA, 'A', people.m1.member, 5, { starts_at: atA,
      payload: { override_reason: `${PRIVATE} override: agreed with the member` } });
    const overrideMine = await mine(people.m1, withReason.data?.assignment_id);
    check('S40-overlap-warns-without-details-and-needs-a-reason', done(inB) && (m1Cand?.conflicts?.count ?? 0) >= 1
      && m1Cand.conflicts.items.every(isLimitedConflict) && !candText.includes(DEPARTMENTS.B) && !candText.includes('SYNTHETIC B-only')
      && noReason.code === 'validation_failed' && noReason.field_errors?.member_id === 'overlap'
      && noReason.field_errors?.override_reason === 'required' && done(withReason) && withReason.data?.override_recorded === true
      && overrideMine?.response === 'pending' && !leaksPrivate(overrideMine),
      { other_department_duty: outcome(inB), conflicts: m1Cand?.conflicts?.count ?? null,
        limited: (m1Cand?.conflicts?.items ?? []).every(isLimitedConflict), refused: outcome(noReason),
        recorded: withReason.data?.override_recorded ?? withReason.code, member_answer: overrideMine?.response ?? null });

    // ====================================================================== S50 deadlines and reminders
    const deadline = new Date(Date.parse(startsAt(6)) - 2 * DAY).toISOString();
    const d5 = await publish(people.leadA, 'A', people.m2.member, 6, { payload: { response_deadline: deadline,
      reminders: [{ anchor: 'response_deadline', before: '1 hour' }] } });
    const d6 = await publish(people.leadA, 'A', people.m2.member, 7);
    const r5 = await mine(people.m2, d5.data?.assignment_id);
    const r6 = await mine(people.m2, d6.data?.assignment_id);
    const set = await duty(people.leadA, 'duties.set_reminders', await occRevision(d6.data?.occurrence_id),
      { occurrence_id: d6.data?.occurrence_id, reminders: [{ anchor: 'starts_at', before: '3 hours' }] });
    const r6b = await mine(people.m2, d6.data?.assignment_id);
    const late50 = await publish(people.leadA, 'A', people.m2.member, 8, { payload: { response_deadline: startsAt(9) } });
    const alerts = await settle(async () => {
      const l = fresh(await inbox(people.leadA), seenL05, 'duty_short_notice');
      const m = fresh(await inbox(people.m1), seenM05, 'duty_assigned');
      return l.length >= 1 && m.length >= 1 ? { l, m } : null;
    });
    const openedAssigned = alerts?.m?.[0] ? await openItem(people.m1, alerts.m[0].item_id) : null;
    check('S50-creator-deadline-default-reminders-and-short-notice', done(d5) && r5?.deadline_source === 'creator'
      && Date.parse(r5?.response_deadline) === Date.parse(deadline) && r5?.reminders?.length === 1
      && r6?.deadline_source === 'default' && Boolean(r6?.response_deadline) && Date.parse(r6.response_deadline) < Date.parse(startsAt(7))
      && done(set) && r6b?.reminders?.length === 1 && r6b.reminders[0]?.anchor === 'starts_at'
      && late50.code === 'validation_failed' && late50.field_errors?.response_deadline === 'after_start'
      && doneMine?.short_notice === true && Boolean(alerts) && isGeneric(openedAssigned)
      && String(openedAssigned?.target ?? '').startsWith('/duties/assignments/'),
      { creator: r5?.deadline_source ?? null, creator_reminders: r5?.reminders?.length ?? null, default: r6?.deadline_source ?? null,
        set_reminders: outcome(set), after_start_refused: late50.field_errors?.response_deadline ?? late50.code,
        short_notice: doneMine?.short_notice ?? null, leader_alerted: alerts?.l?.length ?? 0, member_items: alerts?.m?.length ?? 0,
        generic: isGeneric(openedAssigned) });

    // ====================================================================== S60 coverage and direct confirmation
    const q1 = await coverage(people.leadA, { department_id: run.departments.A });
    const depQ = (q1.json?.departments ?? []).find((d) => d.department_id === run.departments.A);
    const route = depQ?.contact_routes?.[accountless.member]?.[0];
    const states = { m1: coveragePosition(q1.json, aM1)?.status, m2: coveragePosition(q1.json, aM2)?.status,
      x: coveragePosition(q1.json, aX)?.status };
    const xNeeds = coveragePosition(q1.json, aX)?.needs_contact?.reasons ?? [];
    check('S60-the-queue-shows-every-state-and-the-labelled-route', q1.status === 200 && depQ?.view === 'full'
      && states.m1 === 'confirmed' && states.m2 === 'declined' && states.x === 'awaiting'
      && coveragePosition(q1.json, aX)?.assignment?.account === 'no_login' && xNeeds.length > 0
      && (depQ?.counts?.unfilled ?? 0) >= 1 && (depQ?.counts?.declined ?? 0) >= 1 && (depQ?.counts?.needs_contact ?? 0) >= 1
      && route?.phone === numbers.household && route?.belongs_to === 'household' && Boolean(route?.holder_label),
      { states, needs_contact: xNeeds, counts: depQ?.counts ?? null, route: route ? { belongs_to: route.belongs_to, labelled: Boolean(route.holder_label) } : null });

    const xRev = coveragePosition(q1.json, aX)?.assignment?.revision;
    const attempt = await duty(people.leadA, 'duties.record_contact_attempt', xRev, { assignment_id: aX, channel: 'phone',
      outcome: 'will_answer', note: `${PRIVATE} attempt note`, next_follow_up_at: minuteCeil(Date.now() + DAY) });
    const q2 = await coverage(people.leadA, { department_id: run.departments.A });
    const follow = coveragePosition(q2.json, aX)?.follow_up;
    if (follow?.task_id) run.tasks.push(follow.task_id);
    const xTask = follow?.task_id ? (await R(people.leadA, 'followups_task', { p_task_id: follow.task_id })).json : null;
    const noReasonConfirm = await duty(people.leadA, 'duties.confirm_by_leader', coveragePosition(q2.json, aX)?.assignment?.revision,
      { assignment_id: aX, channel: 'phone' });
    const confirm = await duty(people.leadA, 'duties.confirm_by_leader', coveragePosition(q2.json, aX)?.assignment?.revision,
      { assignment_id: aX, channel: 'phone', reason: `${PRIVATE} confirmed with the household` });
    const q3 = await coverage(people.leadA, { department_id: run.departments.A });
    const px = coveragePosition(q3.json, aX);
    const xTaskAfter = follow?.task_id ? (await R(people.leadA, 'followups_task', { p_task_id: follow.task_id })).json : null;
    check('S61-contact-attempt-opens-a-follow-up-and-confirmed-by-leader-closes-it', done(attempt) && attempt.data?.followup === 'opened'
      && follow?.attempts === 1 && xTask?.task?.purpose === 'coverage_follow_up'
      && noReasonConfirm.code === 'validation_failed' && noReasonConfirm.field_errors?.reason === 'required'
      && done(confirm) && confirm.data?.provenance === 'leader' && px?.status === 'confirmed'
      && px?.assignment?.response_provenance === 'leader' && Boolean(px?.assignment?.confirmation?.by)
      && xTaskAfter?.task?.state === 'closed',
      { attempt: attempt.data?.followup ?? attempt.code, task: xTask?.task?.state ?? null, without_reason: noReasonConfirm.field_errors?.reason ?? null,
        confirmed: confirm.data?.provenance ?? confirm.code, status: px?.status ?? null, task_after: xTaskAfter?.task?.state ?? null });

    const reassign = await duty(people.leadA, 'duties.assign_slot', await occRevision(dates[1]?.occurrence_id),
      { slot_id: slotOf(dates[1], 1), member_id: people.life.member });
    const aLife = reassign.data?.assignment_id;
    const cancelPos = await duty(people.leadA, 'duties.cancel_position', await occRevision(dates[2]?.occurrence_id), { slot_id: slotOf(dates[2], 2) });
    const q4 = await coverage(people.leadA, { department_id: run.departments.A });
    const m2Gone = !(await myDuties(people.m2)).some((a) => a.assignment_id === aM2);
    const adminQ = await coverage(people.admin, { department_id: run.departments.A });
    const pastorQ = await coverage(people.pastor, { department_id: run.departments.A });
    const opView = (q) => (q.json?.departments ?? []).find((d) => d.department_id === run.departments.A);
    check('S62-reassign-a-decline-cancel-a-position-and-oversight-without-private-data', done(reassign) && Boolean(aLife)
      && coveragePosition(q4.json, aLife)?.status === 'awaiting' && m2Gone && done(cancelPos)
      && coveragePosition(q4.json, slotOf(dates[2], 2)) === null
      && adminQ.status === 200 && opView(adminQ)?.view === 'operational' && !leaksPrivate(adminQ.json)
      && Object.keys(opView(adminQ)?.contact_routes ?? {}).length === 0
      && pastorQ.status === 200 && opView(pastorQ)?.view === 'operational' && !leaksPrivate(pastorQ.json),
      { reassigned: outcome(reassign), new_status: coveragePosition(q4.json, aLife)?.status ?? null, old_member_still_lists: !m2Gone,
        cancelled: outcome(cancelPos), admin_view: opView(adminQ)?.view ?? null, pastor_view: opView(pastorQ)?.view ?? null,
        admin_private: leaksPrivate(adminQ.json), pastor_private: leaksPrivate(pastorQ.json) });

    // ====================================================================== S80 follow-ups
    const seenM80 = await seen(people.m1);
    const due = churchInstant(addDays(cal.base, 3), '10:00');
    const newTask = async (owner, sourceId = randomUUID()) => {
      const r = await task(people.leadA, 'followups.create_task', null, { source_type: 'fixture_followup', source_id: sourceId,
        source_revision: 1, purpose: 'synthetic_check_in', owner_member_id: owner, supervisor_member_id: people.leadA.member,
        scope_kind: 'department_leader', scope_id: run.departments.A, next_action: 'SYNTHETIC: phone and check in', due_at: due });
      if (r.data?.task_id) run.tasks.push(r.data.task_id);
      return r;
    };
    const src = randomUUID();
    const t1 = await newTask(people.m1.member, src);
    // The assignment notice is delivered before the owner acts (acting on the task retires it).
    const delivered = await settle(async () => fresh(await inbox(people.m1), seenM80, 'followup_assigned').length >= 1);
    const dup = await newTask(people.m1.member, src);
    const t2 = await newTask(people.m1.member);
    const byMember = await envelope('followups_command', await tok(people.m2), 'followups.create_task', null, {
      source_type: 'fixture_followup', source_id: randomUUID(), source_revision: 1, purpose: 'synthetic_check_in',
      owner_member_id: people.m2.member, supervisor_member_id: people.leadA.member, scope_kind: 'department_leader',
      scope_id: run.departments.A, next_action: 'SYNTHETIC', due_at: due });
    const T = t1.data?.task_id;
    const myTasks = (await R(people.m1, 'followups_my_tasks')).json?.tasks ?? [];
    const view = async (p, id) => (await R(p, 'followups_task', { p_task_id: id })).json?.task;
    const u1 = await task(people.m1, 'followups.update_task', (await view(people.m1, T))?.revision, { task_id: T, status: 'in_progress' });
    const review = churchInstant(addDays(cal.base, 5), '10:00');
    const u2 = await task(people.m1, 'followups.update_task', (await view(people.m1, T))?.revision, { task_id: T, status: 'waiting', review_at: review });
    const waiting = await view(people.m1, T);
    const closeNoReason = await task(people.m1, 'followups.update_task', (await view(people.m1, t2.data?.task_id))?.revision,
      { task_id: t2.data?.task_id, status: 'closed' });
    const ownerReassign = await task(people.m1, 'followups.reassign', (await view(people.m1, t2.data?.task_id))?.revision,
      { task_id: t2.data?.task_id, owner_member_id: people.m2.member });
    const moved = await task(people.leadA, 'followups.reassign', (await view(people.leadA, t2.data?.task_id))?.revision,
      { task_id: t2.data?.task_id, owner_member_id: people.m2.member });
    const m2Tasks = (await R(people.m2, 'followups_my_tasks')).json?.tasks ?? [];
    const m1Lost = await R(people.m1, 'followups_task', { p_task_id: t2.data?.task_id });
    const routing = await R(people.admin, 'followups_admin_routing');
    const adminTask = (await R(people.admin, 'followups_task', { p_task_id: T })).json;
    check('S80-follow-ups-owner-states-reassignment-and-routing', done(t1) && dup.code === 'conflict' && byMember.code === 'forbidden'
      && myTasks.some((t) => t.task_id === T) && done(u1) && u1.data?.state === 'in_progress'
      && done(u2) && waiting?.state === 'waiting' && Date.parse(waiting?.review_at) === Date.parse(review)
      && Date.parse(waiting?.due_at) === Date.parse(due)
      && closeNoReason.code === 'validation_failed' && closeNoReason.field_errors?.close_reason === 'required'
      && ownerReassign.code === 'forbidden' && done(moved) && m2Tasks.some((t) => t.task_id === t2.data?.task_id)
      && m1Lost.status === 403 && routing.status === 200 && adminTask?.view === 'routing'
      && !JSON.stringify(adminTask ?? {}).includes('SYNTHETIC: phone') && Boolean(delivered),
      { created: outcome(t1), duplicate: dup.code ?? 'created', by_member: byMember.code ?? 'created', listed: myTasks.length,
        states: [u1.data?.state ?? u1.code, u2.data?.state ?? u2.code], close_without_reason: closeNoReason.field_errors?.close_reason ?? null,
        owner_reassign: ownerReassign.code ?? 'done', reassigned: outcome(moved), former_owner_read: m1Lost.status,
        admin_view: adminTask?.view ?? null, notice_delivered: Boolean(delivered) });

    // ====================================================================== M the permission matrix
    const matrixArgs = {
      duties_coverage: { from_date: cal.from, to_date: cal.to, department_id: run.departments.A },
      duties_candidates: { department_id: run.departments.A, starts_at: startsAt(10), ends_at: null, slot_id: null, reporting_at: null },
      duties_member_history: { member_id: people.m1.member },
      followups_task: { p_task_id: T },
    };
    for (const [label, principal] of Object.entries(PRINCIPALS)) {
      const p = label === 'anon' ? null : people[label];
      let pass = true;
      for (const name of READS) {
        const want = expectRead(principal, name);
        const got = await R(p, name, matrixArgs[name] ?? {});
        const cellOk = got.status === want.status && (want.detail === undefined || got.detail === want.detail);
        pass &&= cellOk;
        matrixRows.push({ principal: label, surface: name, kind: 'read', want, got: { status: got.status, detail: got.detail }, ok: cellOk });
      }
      check(`M-reads-${label}`, pass, { cells: READS.length });
    }
    const dProbe = d6.data?.occurrence_id;
    const probePayload = {
      'duties.revise_duty': { occurrence_id: dProbe, instructions: 'SYNTHETIC matrix probe' },
      'duties.set_reminders': { occurrence_id: dProbe, reminders: [] },
      'duties.cancel_position': { slot_id: unfilledSlot },
      'duties.confirm_by_leader': { assignment_id: aX, channel: 'phone', reason: 'SYNTHETIC matrix probe' },
      'duties.record_contact_attempt': { assignment_id: aX, channel: 'phone', outcome: 'will_answer',
        next_follow_up_at: minuteCeil(Date.now() + DAY) },
      'duties.respond': { assignment_id: aM1, response: 'accepted' },
      'duties.withdraw_acceptance': { assignment_id: aM1 },
      'duties.add_member': { department_id: run.departments.A, member_id: people.m1.member },
      'duties.remove_member': { department_id: run.departments.A, member_id: people.m1.member },
      'followups.update_task': { task_id: T, status: 'in_progress' },
      'followups.reassign': { task_id: T, owner_member_id: people.m1.member },
    };
    for (const [label, principal] of Object.entries(PRINCIPALS)) {
      const p = label === 'anon' ? null : people[label];
      let pass = true;
      for (const probe of PROBES) {
        const want = expectProbe(principal, probe.cmd);
        const r = await rpc(probe.fn, p ? await tok(p) : undefined,
          { version: 1, command: probe.cmd, request_id: randomUUID(), expected_revision: STALE, payload: probePayload[probe.cmd] });
        const got = r.status === 200 ? { code: r.json?.code ?? 'success' } : { status: r.status };
        const cellOk = want.status ? got.status === want.status : got.code === want.code;
        pass &&= cellOk;
        matrixRows.push({ principal: label, surface: probe.cmd, kind: 'command', want, got, ok: cellOk });
      }
      check(`M-commands-${label}`, pass, { cells: PROBES.length });
    }

    // ====================================================================== S70 completion
    const startMs = Date.parse(soon);
    if (Date.now() < startMs + 5000) await sleep(startMs + 5000 - Date.now());
    const accDone = outcome(doneAccept);
    const aDone = dDone.data?.assignment_id;
    const aQuiet = dQuiet.data?.assignment_id;
    const today = churchDate(Date.now());
    const outcomes = async (p) => R(p, 'duties_outcomes', { from_date: today, to_date: today, department_id: run.departments.A });
    const o0 = await outcomes(people.leadA);
    const rowOf = (answer, id) => (answer.json?.departments ?? []).flatMap((d) => d.positions ?? d.assignments ?? [])
      .find((x) => x.assignment_id === id || x.assignment?.assignment_id === id);
    const quietRow = rowOf(o0, aQuiet);
    const recAdmin = await duty(people.admin, 'duties.record_outcome', 1, { assignment_id: aDone, outcome: 'completed' });
    const recB = await duty(people.leadB, 'duties.record_outcome', 1, { assignment_id: aDone, outcome: 'completed' });
    const noShowQuiet = await duty(people.leadA, 'duties.record_outcome', 1, { assignment_id: aQuiet, outcome: 'no_show' });
    const doneRev = boardEntry(await board(people.leadA), aDone)?.position?.assignment?.revision;
    const rec = await duty(people.leadA, 'duties.record_outcome', doneRev, { assignment_id: aDone, outcome: 'completed' });
    const corr = await duty(people.depA, 'duties.correct_outcome', rec.data?.outcome_revision ?? 1,
      // The member reads their own outcome and its correction reason (story 4.10), so no private marker.
      { assignment_id: aDone, outcome: 'excused', reason: 'SYNTHETIC correction reason' });
    const o1 = await outcomes(people.leadA);
    const history = (await R(people.m1, 'duties_member_history')).json;
    check('S70-completion-outcomes-corrections-and-time-never-a-no-show', done(doneAccept) && o0.status === 200 && quietRow != null
      && (quietRow.outcome ?? null) === null && recAdmin.code === 'forbidden' && recB.code === 'not_found'
      && noShowQuiet.code === 'validation_failed' && done(rec) && done(corr)
      && JSON.stringify(rowOf(o1, aDone) ?? {}).includes('excused') && JSON.stringify(history ?? {}).includes('excused')
      && !leaksPrivate((await R(people.admin, 'duties_my_duties')).json),
      { accepted: accDone, unrecorded_outcome: quietRow?.outcome ?? null, admin_alone: recAdmin.code ?? 'done', other_leader: recB.code ?? 'done',
        no_show_for_unanswered: noShowQuiet.field_errors?.outcome ?? noShowQuiet.code ?? 'done', recorded: outcome(rec), corrected: outcome(corr) });

    // ====================================================================== S90 lifecycle and handover
    // A login hold keeps the duty and routes contact to the leader (the hold is never named).
    const hold = await envelope('identity_credential_command', await tok(people.admin), 'identity.place_hold',
      await memberRevision(people.m2.member), { member_id: people.m2.member, reason_code: 'login_disabled' });
    const holdId = hold.data?.holds?.[0]?.hold_id;
    if (holdId) run.holdIds.push({ member: people.m2.member, hold_id: holdId });
    const qh = await coverage(people.leadA, { department_id: run.departments.A });
    const heldPos = coveragePosition(qh.json, d5.data?.assignment_id);
    const release = await envelope('identity_credential_command', await tok(people.admin), 'identity.release_hold',
      await memberRevision(people.m2.member), { member_id: people.m2.member, hold_id: holdId, identity_check: 'in_person' });
    if (done(release)) run.holdIds = run.holdIds.filter((h) => h.hold_id !== holdId);
    await afterEpoch(people.m2);
    check('S90-a-login-hold-keeps-the-duty-with-needs-contact', done(hold) && heldPos?.assignment?.assignment_id === d5.data?.assignment_id
      && (heldPos?.needs_contact?.reasons ?? []).length > 0 && !JSON.stringify(heldPos ?? {}).includes('login_disabled') && done(release),
      { hold: outcome(hold), kept: heldPos?.assignment?.assignment_id === d5.data?.assignment_id,
        needs_contact: heldPos?.needs_contact?.reasons ?? null, release: outcome(release) });

    // Removal from the department vacates with the coarse reason (leaders and deputies only).
    const removed = await duty(people.admin, 'duties.remove_member', await deptRevision(run.departments.A),
      { department_id: run.departments.A, member_id: people.life.member });
    const slotLife = slotOf(dates[1], 1);
    const reasonFor = async (p) => coveragePosition((await coverage(p, { department_id: p === people.leadB ? undefined : run.departments.A })).json, slotLife);
    const vac = { leadA: (await reasonFor(people.leadA))?.vacated?.reason ?? null, depA: (await reasonFor(people.depA))?.vacated?.reason ?? null,
      admin: (await reasonFor(people.admin))?.vacated?.reason ?? null };
    const otherSees = await reasonFor(people.leadB);
    const lifeList = await myDuties(people.life);
    const readd = await duty(people.admin, 'duties.add_member', await deptRevision(run.departments.A),
      { department_id: run.departments.A, member_id: people.life.member });
    check('S91-removal-vacates-with-the-reason-for-leaders-and-deputies-only', done(removed)
      && vac.leadA === 'removed_from_department' && vac.depA === 'removed_from_department' && vac.admin === null && otherSees === null
      && !lifeList.some((a) => a.assignment_id === aLife) && done(readd),
      { removed: outcome(removed), reasons: vac, other_department_leader_sees: otherSees !== null, readded: outcome(readd) });

    // A church deactivation vacates the member's future duties (reason member_inactive); restored.
    const dLife = await publish(people.leadA, 'A', people.life.member, 9);
    const deact = await envelope('identity_lifecycle_command', await tok(people.admin), 'identity.deactivate_membership',
      await memberRevision(people.life.member), { member_id: people.life.member, reason_code: 'moved_away' });
    run.lifeDeactivated = done(deact);
    run.lifeRevision = deact.revision;
    const vLife = coveragePosition((await coverage(people.leadA, { department_id: run.departments.A })).json, dLife.data?.slot_id);
    const restore = await envelope('identity_lifecycle_command', await tok(people.admin), 'identity.restore_membership',
      deact.revision, { member_id: people.life.member, identity_check: 'in_person' });
    if (done(restore)) run.lifeDeactivated = false;
    await afterEpoch(people.life);
    const lifeBack = await R(people.life, 'identity_my_member_summary');
    check('S92-deactivation-vacates-with-member-inactive-and-restore', done(dLife) && done(deact)
      && vLife?.vacated?.reason === 'member_inactive' && done(restore) && lifeBack.status === 200,
      { deactivated: outcome(deact), reason: vLife?.vacated?.reason ?? null, restored: outcome(restore), member_access: lifeBack.status });

    // Scope loss: a deputy granted and revoked loses reads and commands at once.
    const g2 = await grantCmd('identity.grant_scope', people.m2, 'department_deputy', run.departments.A);
    run.m2Deputy = done(g2);
    const asDeputy = await R(people.m2, 'duties_leader_board');
    const r2 = await grantCmd('identity.revoke_scope', people.m2, 'department_deputy', run.departments.A);
    if (done(r2)) run.m2Deputy = false;
    const lostBoard = await R(people.m2, 'duties_leader_board');
    const lostCov = await coverage(people.m2, { department_id: run.departments.A });
    const lostSup = await R(people.m2, 'followups_supervision');
    const lostCmd = await duty(people.m2, 'duties.confirm_by_leader', STALE, probePayload['duties.confirm_by_leader']);
    const lostTask = await task(people.m2, 'followups.update_task', STALE, { task_id: T, status: 'in_progress' });
    check('S93-scope-loss-closes-reads-and-commands-at-once', done(g2) && asDeputy.status === 200 && done(r2)
      && lostBoard.status === 403 && lostBoard.detail === 'not_granted' && lostCov.status === 403 && lostSup.status === 403
      && lostCmd.code === 'not_found' && lostTask.code === 'not_found',
      { granted: outcome(g2), board_as_deputy: asDeputy.status, revoked: outcome(r2), board: lostBoard.status, coverage: lostCov.status,
        supervision: lostSup.status, confirm: lostCmd.code ?? 'done', task: lostTask.code ?? 'done' });

    // Story 4.16: the last reachable leader's scope cannot be revoked until someone else leads.
    const lastB = await grantCmd('identity.revoke_scope', people.leadB, 'department_leader', run.departments.B);
    const stillB = await holdsScope(people.leadB, 'department_leader', run.departments.B);
    check('S94-revoking-the-last-reachable-leader-is-refused-handover-required', lastB.code === 'conflict'
      && lastB.field_errors?.member_id === 'handover_required' && stillB,
      { revoke: lastB.code ?? 'done', field: lastB.field_errors?.member_id ?? null, still_leads: stillB });

    // Story 4.16: unlinking an account is never refused; the handover is recorded and resolved.
    const cName = departmentC(runId);
    const cCreated = await duty(people.admin, 'duties.create_department', null, { name: cName });
    const C = cCreated.data?.department_id;
    run.createdC = C;
    if (C && target === 'staging') { state.runDepartments.push(C); saveState(); }
    const gC = await grantCmd('identity.grant_scope', people.life, 'department_leader', C);
    const unlink = await envelope('identity_review_command', await tok(people.admin), 'identity.unlink_account',
      await memberRevision(people.life.member), { member_id: people.life.member, reason: 'account_lost' });
    run.lifeUnlinked = done(unlink);
    const cView = await department(C);
    const unlinkedRead = await R(people.life, 'duties_my_duties');
    const gLead = await grantCmd('identity.grant_scope', people.leadA, 'department_leader', C);
    const resolved = await duty(people.admin, 'duties.resolve_handover', await deptRevision(C), { department_id: C });
    const cAfter = await department(C);
    let relinkOk = false;
    if (run.lifeUnlinked) {
      const linked = await applyAndApprove(people.life, people.life.member);
      run.lifeUnlinked = !done(linked);
      relinkOk = done(linked);
    }
    const lifeSummary = await R(people.life, 'identity_my_member_summary');
    const stillInA = ((await department(run.departments.A))?.members ?? []).some((m) => m.member_id === people.life.member);
    check('S95-unlink-is-never-refused-records-the-handover-and-relinks-the-same-member', done(cCreated) && done(gC) && done(unlink)
      && (cView?.handovers ?? []).length >= 1 && cView?.needs_leader === true && unlinkedRead.status === 403
      && done(gLead) && done(resolved) && (cAfter?.handovers ?? []).length === 0 && cAfter?.needs_leader === false
      && relinkOk && lifeSummary.status === 200 && lifeSummary.json?.member_id === people.life.member && stillInA,
      { department: outcome(cCreated), sole_leader: outcome(gC), unlink: outcome(unlink), handovers: cView?.handovers?.length ?? null,
        needs_leader: cView?.needs_leader ?? null, unlinked_read: unlinkedRead.detail ?? unlinkedRead.status, new_leader: outcome(gLead),
        resolved: outcome(resolved), after: cAfter?.handovers?.length ?? null, relinked: relinkOk, same_member: lifeSummary.json?.member_id === people.life.member,
        department_membership_kept: stillInA });

    // ====================================================================== S96 owner operations
    // PostgREST answers 404 PGRST202 for a function the exposed `api` schema does not have, and
    // 406 PGRST106 for any request naming the unexposed `app` schema.
    const direct = [];
    for (const fn of ['duties_owner_put_part', 'duties_owner_link_duty', 'duties_owner_flag_review', 'duties_owner_unlink']) {
      const viaApi = await rpc(fn, await tok(people.leadA), {});
      const viaApp = await http('POST', `/rest/v1/rpc/${fn}`, { token: await tok(people.leadA), body: {}, profile: 'app' });
      direct.push({ api: `${viaApi.status} ${viaApi.json?.code ?? ''}`, app: `${viaApp.status} ${viaApp.json?.code ?? ''}` });
    }
    const table = await http('GET', '/rest/v1/duties_review_flags?select=*', { token: await tok(people.leadA), profile: 'app' });
    const tableQuery = `${table.status} ${table.json?.code ?? ''}`;
    check('S96-owner-operations-are-not-reachable-by-clients', direct.every((x) => x.api === '404 PGRST202' && x.app === '406 PGRST106')
      && tableQuery === '406 PGRST106',
      { rpc: direct, table_query: tableQuery });
    if (sqlChecks) {
      // A SYNTHETIC Cells-like caller (the 4.11 fixture): a linked event changes, the duty is flagged.
      const seenR = await seen(people.leadA);
      const dEv = await publish(people.leadA, 'A', people.m1.member, 11);
      psql(`select app.contract_register_source_type('fixture', 'fixture_event', 'app.fixture_event_check(jsonb)'::regprocedure)
             where not exists (select 1 from app.contract_source_types where source_type = 'fixture_event');
            select app.duties_register_link_source('fixture', 'fixture_event', 'event')
             where not exists (select 1 from app.duties_link_sources where source_type = 'fixture_event');`);
      const eventId = psql(`insert into app.fixture_events (title) values ('${NAME_PREFIX} Event') returning event_id`);
      const linked = await duty(people.leadA, 'duties.revise_duty', await occRevision(dEv.data?.occurrence_id),
        { occurrence_id: dEv.data?.occurrence_id, event_ref: eventId });
      const claims = jsonLiteral(sessionClaims(await tok(people.admin))).replace('::jsonb', '');
      const flagged = JSON.parse(psql(`begin;
        do $d$ begin perform set_config('request.jwt.claims', ${claims}, true); end $d$;
        select app.fixture_event_changed(${jsonLiteral({ event_id: eventId, changed: ['time'] })})::text;
        commit;`).split('\n').find((l) => l.startsWith('{')) ?? '{}');
      const notice = await settle(async () => fresh(await inbox(people.leadA), seenR, 'duty_review_flagged')[0]);
      const opened = notice ? await openItem(people.leadA, notice.item_id) : null;
      const rv = boardEntry(await board(people.leadA), dEv.data?.occurrence_id)?.duty?.reviews?.[0];
      const byOther = await duty(people.leadB, 'duties.clear_review', rv?.revision, { flag_id: rv?.flag_id });
      const cleared = await duty(people.leadA, 'duties.clear_review', rv?.revision, { flag_id: rv?.flag_id });
      check('S97-a-linked-event-change-flags-the-duty-and-the-leader-clears-it', done(linked) && flagged?.flagged >= 1
        && Boolean(notice) && opened?.title === 'Duty needs review' && String(opened?.target ?? '').startsWith('/duties/leader')
        && Boolean(rv?.flag_id) && byOther.code === 'forbidden' && done(cleared),
        { linked: linked.data?.change ?? linked.code, flagged: flagged?.flagged ?? flagged?.code ?? null, notice: Boolean(notice),
          link: opened?.target ?? null, other_leader: byOther.code ?? 'done', cleared: outcome(cleared) });
    } else {
      notRun.push('S97 linked-event mismatch flag: owner operations are SQL-only (no client route); proven locally (S97 and duties-decisions D10-D13). '
        + 'For the owner demonstration the parent session raises one flag as owner-demonstration.md B1 describes.');
    }

    // ====================================================================== S99 privacy
    const m1Duties = await myDuties(people.m1);
    const m2Duties = await myDuties(people.m2);
    const memberReads = [];
    for (const p of [people.m1, people.m2]) {
      memberReads.push((await R(p, 'duties_leader_board')).status, (await coverage(p)).status, (await R(p, 'duties_rota')).status);
    }
    const opened99 = [];
    for (const p of [people.m1, people.m2, people.leadA]) {
      for (const i of (await inbox(p)).slice(0, 15)) opened99.push(await openItem(p, i.item_id));
    }
    check('S99-nothing-private-reaches-a-member-and-every-item-is-generic', !leaksPrivate(m1Duties) && !leaksPrivate(m2Duties)
      && !JSON.stringify(m1Duties).includes(`${MEMBER_NOTE} M2`) && !JSON.stringify(m2Duties).includes(`${MEMBER_NOTE} M1`)
      && memberReads.every((x) => x === 403) && opened99.length > 0 && opened99.every(isGeneric) && !JSON.stringify(opened99).includes('SYNTHETIC'),
      { member_reads: memberReads, m1_private: leakKind(m1Duties), m2_private: leakKind(m2Duties), items: opened99.length,
        all_generic: opened99.every(isGeneric), kinds: [...new Set(opened99.map((i) => i?.reminder_kind))].sort() });

    if (target === 'staging' || stagingPath) {
      notRun.push('Deletion (erase or anonymise Duties and Follow-ups data): needs the deletion worker; proven locally by duties-lifecycle L60.');
      notRun.push('Two-connection races (stale answer vs edit, bulk vs edit, deactivation vs publish): proven locally by duties-revisions R70, '
        + 'duties-responses V30, duties-lifecycle L23-L25.');
    }
  } catch (e) {
    check('S--unexpected-error', false, { error: String(e?.message ?? e).slice(0, 200) });
  } finally {
    try { await apiCleanup(); } catch (e) { check('S98-api-cleanup', false, { error: String(e?.message ?? e).slice(0, 200) }); }
    const writeSummary = () => {
      if (summaryPath) writeFileSync(summaryPath, renderSummary({ target: stagingPath ? 'local --staging-path' : target, results, matrixRows, notRun }));
    };
    writeSummary();
    const keptIds = [run.departments.A, run.departments.B].filter(Boolean);
    if (stagingPath && keptIds.length) {
      // The staging cleanup SQL, executed here so it is proven before the parent session uses it.
      psql(stagingCleanupSql({ keptDepartmentIds: keptIds, runDepartmentIds: [run.createdC].filter(Boolean), environment: 'local' }));
      const ids = keptIds.map((d) => `'${d}'`).join(',');
      const left = Number(psql(`select count(*) from app.duties_occurrences where department_id in (${ids})`))
        + Number(psql(`select count(*) from app.duties_series where department_id in (${ids})`))
        + Number(psql(`select count(*) from app.followups_tasks where scope_id in (${ids})`))
        + (run.createdC ? Number(psql(`select count(*) from app.duties_departments where department_id = '${run.createdC}'`)) : 0);
      check('S99-staging-cleanup-sql-removes-the-run', left === 0, { rows_left: left });
    }
    if (target === 'local' && !argv.includes('--keep')) {
      const left = localCleanup();
      if (workerHandle) psql(`select app.sys_revoke_credential('${workerHandle.credentialId}', '${OPERATOR}'); select app.sys_disable_principal('${workerHandle.principal}', '${OPERATOR}');`);
      // The marker this suite set (in this run, or in the first run of a --rerun-state rehearsal).
      const unmarked = psql(`with h as (delete from app.platform_environment_history where set_by = 'duties-staging-suite' returning 1),
        e as (delete from app.platform_environment where set_by = 'duties-staging-suite' returning 1)
        select (select count(*) from e)`) !== '0';
      log('S99-local-cleanup', { users_left: Number(left), credential_revoked: Boolean(workerHandle), unmarked: unmarked || !marked,
        departments_left: Number(psql(`select count(*) from app.duties_departments where name like 'SYNTHETIC Closing Suite%'`)),
        members_left: Number(psql(`select count(*) from app.identity_members where display_name like '${NAME_PREFIX}%'`)) });
    } else if (keptIds.length) {
      const runDepartmentIds = [...new Set(state.runDepartments ?? [])];
      if (cleanupSqlPath) {
        writeFileSync(cleanupSqlPath, stagingCleanupSql({ keptDepartmentIds: keptIds, runDepartmentIds }), { mode: 0o600 });
        chmodSync(cleanupSqlPath, 0o600);
      }
      log('S99-staging-cleanup-sql', { written: Boolean(cleanupSqlPath), run_departments: runDepartmentIds.length });
    }
    writeSummary();
  }
  const failed = results.filter((r) => !r.ok);
  const scen = results.filter((r) => !r.step.startsWith('M-'));
  console.log(`\nscenarios ${scen.filter((r) => r.ok).length}/${scen.length}, matrix cells ${matrixRows.filter((r) => r.ok).length}/${matrixRows.length}`);
  console.log(`${results.length - failed.length}/${results.length} checks passed`);
  if (failed.length) {
    console.log(`FAILED: ${failed.map((f) => f.step).join(', ')}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((e) => {
    console.error(`duties-staging-suite: ${e.message}`);
    process.exitCode = 1;
  });
}

