#!/usr/bin/env node
// Story 4.10 end-to-end on the LOCAL stack: completion outcomes and assignment history through
// real GoTrue phone sign-in (no SMS), the real Data API (PostgREST) and the real worker script
// (tools/notifications/worker.mjs), proving the ticket's verify line on synthetic past duties:
//   * an unrecorded past duty stays unrecorded (also after the worker ran: passing time never
//     sets an outcome);
//   * the leader records Completed with a short note; the member sees it in My duties and in
//     their history; the response and the assignment revision are untouched;
//   * a declined assignment cannot become a No-show (Excused can be recorded);
//   * a cancelled accepted duty has no outcome and is not listed;
//   * the deputy corrects Completed to No-show with a reason: the prior value, its note, actor and
//     time are kept; a stale correction and a second first record are refused;
//   * a leader cannot record their own duty;
//   * another member, the Admin role alone, Pastor and another department's leader read no
//     outcome text and no history (and the board, rota, coverage queue and Admin overview carry
//     none); the outcome log is not reachable over the Data API; no notification is sent;
//     the audit and the receipts hold codes only.
//
// Past duties are made by publishing them a few days ahead and then moving their start into the
// past with a direct SQL update (a test-only time shift; nothing in the app can do that).
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900140-900149. Evidence is redacted JSONL:
// statuses, codes, counts and states; never tokens, passwords, numbers, the credential, names,
// notes or reasons. Every user, member, grant, department, duty, outcome, job, item and receipt it
// created is removed; the run's credential is revoked and its principal disabled.
//
// Usage: node tools/identity-e2e/duties-outcomes.mjs [--evidence <file.jsonl>]
import { execFile } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 4.10 E2E';
export const DEPARTMENT = 'SYNTHETIC Preaching Rota';
export const OTHER_DEPARTMENT = 'SYNTHETIC 4.10 E2E Ushers';
/** Texts this run writes; no read but the member's and their leaders' may hold them. */
export const PRIVATE_TEXT = ['SYNTHETIC 4.10 note', 'SYNTHETIC 4.10 reason'];

/** The reserved fictional numbers this run uses (+44 7700 900140-900149). */
export function isFictionalOutcomesPhone(phone) {
  return /^\+44770090014[0-9]$/.test(phone);
}

/** Does an answer hold any of this run's outcome notes or correction reasons? */
export function holdsOutcomeText(answer) {
  const json = JSON.stringify(answer ?? {});
  return PRIVATE_TEXT.some((t) => json.includes(t));
}

/** The position of an outcomes answer by assignment id. */
export function outcomeOf(answer, assignmentId) {
  for (const d of answer?.departments ?? []) {
    for (const p of d.positions ?? []) {
      if (p.assignment?.assignment_id === assignmentId) return p.assignment;
    }
  }
  return null;
}

/** A history entry by assignment id. */
export function entryOf(history, assignmentId) {
  return (history?.entries ?? []).find((e) => e.assignment_id === assignmentId) ?? null;
}

/** "<value>" of each trail revision, newest first. */
export function trailValues(outcome) {
  return (outcome?.trail ?? []).map((t) => t.outcome).join('>');
}

/** The ISO start of church date `ymd` at 10:00 Africa/Lusaka (UTC+2, no daylight saving). */
export function churchTen(ymd) {
  return `${ymd}T08:00:00Z`;
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
  const HOUR = 3_600_000;
  const DAY = 24 * HOUR;
  const churchDate = (ms) => new Date(Date.now() + ms + 2 * HOUR).toISOString().slice(0, 10);

  const people = {
    admin: { phone: '+447700900140', name: `${NAME_PREFIX} Admin` },
    leader: { phone: '+447700900141', name: `${NAME_PREFIX} Leader` },
    deputy: { phone: '+447700900142', name: `${NAME_PREFIX} Deputy` },
    other: { phone: '+447700900143', name: `${NAME_PREFIX} Other leader` },
    member: { phone: '+447700900144', name: `${NAME_PREFIX} Member M` },
    decliner: { phone: '+447700900145', name: `${NAME_PREFIX} Member O` },
    quiet: { phone: '+447700900146', name: `${NAME_PREFIX} Member Q` },
    spare: { phone: '+447700900147', name: `${NAME_PREFIX} Member R` },
    pastor: { phone: '+447700900148', name: `${NAME_PREFIX} Pastor` },
  };
  for (const p of Object.values(people)) if (!isFictionalOutcomesPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
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
    delete from app.duties_outcomes x where x.assignment_id in (select assignment_id from gone_assignments);
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
    psql(`select app.platform_set_environment('local', 'duties-outcomes-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('O00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  const run = randomUUID().slice(0, 8);
  const credential = `sysc_local_${randomBytes(32).toString('base64url')}`;
  const principal = psql(`select app.sys_create_principal('notifications-worker-outcomes-${run}', 'notifications_worker', '${OPERATOR}')`);
  const credentialId = JSON.parse(psql(`select app.sys_register_credential('${principal}',
    '${createHash('sha256').update(credential).digest('hex')}', 'duties outcomes e2e ${run}', interval '2 hours', '${OPERATOR}')`)).credential_id;
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
  const outcomeRevision = (id) => Number(psql(`select coalesce(max(revision), 0) from app.duties_outcomes where assignment_id = '${id}'`));
  const outcomesRead = (p, body = {}) => rpc('duties_outcomes', p.token, body);
  const historyRead = (p, memberId) => rpc('duties_member_history', p.token, memberId ? { member_id: memberId } : {});
  const record = (p, id, outcome, note) => duty(p.token, 'duties.record_outcome', asgRevision(id),
    { assignment_id: id, outcome, ...(note ? { note } : {}) });
  const correct = (p, id, outcome, reason, extra = {}, expected = null) => duty(p.token, 'duties.correct_outcome',
    expected ?? outcomeRevision(id), { assignment_id: id, outcome, reason, ...extra });
  const jobCount = () => Number(psql('select count(*) from app.notifications_jobs'));
  // A command answer: done (no refusal code) or refused with a code.
  const done = (r) => r.status === 200 && !r.code;
  const refused = (r, code, field, value) => r.code === code && (!field || r.field_errors?.[field] === value);

  try {
    const { admin, leader, deputy, other, member, decliner, quiet, spare, pastor } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'duties-outcomes-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    psql(`insert into app.identity_grants (member_id, role, granted_by_operator) values ('${pastor.member}', 'pastor', '${OPERATOR}')`);
    check('O01-members-signed-in-by-phone', Object.values(people).every((p) => amrMethods(p.token).includes('password')),
      { amr: amrMethods(admin.token) });

    // ------------------------------------------------------- setup: departments, leaders, deputy, members
    const dept = await duty(admin.token, 'duties.create_department', null, { name: DEPARTMENT });
    const departmentId = dept.data?.department_id;
    const dept2 = await duty(admin.token, 'duties.create_department', null, { name: OTHER_DEPARTMENT });
    const grantRev = (m) => Number(psql(`select revision from app.identity_grant_sets where member_id = '${m}'`));
    const grants = [];
    for (const [p, kind, d] of [[leader, 'department_leader', departmentId], [deputy, 'department_deputy', departmentId],
      [other, 'department_leader', dept2.data?.department_id]]) {
      grants.push((await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantRev(p.member),
        { member_id: p.member, scope_kind: kind, scope_id: d })).code ?? 'done');
    }
    const added = [];
    for (const p of [leader, member, decliner, quiet, spare]) {
      const rev = Number(psql(`select revision from app.duties_departments where department_id = '${departmentId}'`));
      added.push((await duty(admin.token, 'duties.add_member', rev, { department_id: departmentId, member_id: p.member })).code ?? 'done');
    }
    for (const p of [leader, deputy, other, pastor]) p.token = (await signIn(p.phone, p.password)).json?.access_token;
    check('O02-departments-leaders-members', done(dept) && done(dept2)
      && grants.every((s) => s === 'done') && added.every((s) => s === 'done'),
      { departments: [dept.status, dept2.status], grants, members_added: added });

    // ------------------------------------------------------- duties a few days ahead, answered
    const publish = async (who, days) => duty(leader.token, 'duties.publish_duty', null, {
      department_id: departmentId, member_id: who.member, duty_name: `Duty ${days}`, location: 'SYNTHETIC hall',
      starts_at: churchTen(churchDate(days * DAY)) });
    const pA = await publish(member, 3);     // M accepts: recorded, then corrected
    const pB = await publish(decliner, 4);   // O declines
    const pC = await publish(quiet, 5);      // Q never answers: stays unrecorded
    const pK = await publish(member, 6);     // M accepts, then the duty is cancelled
    const pL = await publish(leader, 7);     // the leader's own duty
    const [aA, aB, aC, aK, aL] = [pA, pB, pC, pK, pL].map((p) => p.data?.assignment_id);
    const answers = [
      await duty(member.token, 'duties.respond', asgRevision(aA), { assignment_id: aA, response: 'accepted' }),
      await duty(decliner.token, 'duties.respond', asgRevision(aB), { assignment_id: aB, response: 'declined' }),
      await duty(member.token, 'duties.respond', asgRevision(aK), { assignment_id: aK, response: 'accepted' }),
      await duty(leader.token, 'duties.respond', asgRevision(aL), { assignment_id: aL, response: 'accepted' }),
    ].map((r) => r.code ?? 'done');
    const occOf = (id) => psql(`select s.occurrence_id from app.duties_assignments a join app.duties_slots s on s.slot_id = a.slot_id
      where a.assignment_id = '${id}'`);
    const slotOf = (id) => psql(`select slot_id from app.duties_assignments where assignment_id = '${id}'`);
    const kOcc = occOf(aK);
    const cancelK = await duty(leader.token, 'duties.cancel_position',
      Number(psql(`select revision from app.duties_occurrences where occurrence_id = '${kOcc}'`)), { slot_id: slotOf(aK) });
    // The test-only time shift: each duty moves to 10:00 church time some days ago.
    for (const [id, daysAgo] of [[aA, 1], [aB, 2], [aC, 2], [aK, 3], [aL, 1]]) {
      psql(`update app.duties_occurrences set starts_at = '${churchTen(churchDate(-daysAgo * DAY))}', ends_at = null,
              reporting_at = null where occurrence_id = '${occOf(id)}'`);
    }
    check('O03-past-synthetic-duties', [pA, pB, pC, pK, pL].every(done)
      && answers.every((s) => s === 'done') && done(cancelK) && cancelK.data?.cancelled === 'occurrence',
      { published: [pA, pB, pC, pK, pL].map((p) => p.code ?? 'done'), answers, cancelled: cancelK.data?.cancelled ?? null });

    // ------------------------------------------------------- passing time sets nothing
    const runA = await worker();
    const r0 = await outcomesRead(leader);
    check('O10-an-unrecorded-past-duty-stays-unrecorded', r0.status === 200 && runA.exit === 0
      && [aA, aB, aC].every((id) => outcomeOf(r0.json, id)?.outcome_state === 'unrecorded')
      && Number(psql('select count(*) from app.duties_outcomes')) === 0,
      { status: r0.status, worker: runA.exit, states: [aA, aB, aC].map((id) => outcomeOf(r0.json, id)?.outcome_state ?? null),
        outcomes_in_db: Number(psql('select count(*) from app.duties_outcomes')) });

    // ------------------------------------------------------- record, then the member sees it
    const jobsBefore = jobCount();
    const recA = await record(leader, aA, 'completed', 'SYNTHETIC 4.10 note A');
    const mineA = ((await rpc('duties_my_duties', member.token)).json?.assignments ?? []).find((a) => a.assignment_id === aA);
    const histM = await historyRead(member);
    check('O20-record-completed-the-member-sees-it', done(recA) && recA.data?.outcome_revision === 1
      && !holdsOutcomeText(recA) && mineA?.outcome?.outcome === 'completed' && mineA?.outcome?.note === 'SYNTHETIC 4.10 note A'
      && mineA?.response === 'accepted' && mineA?.revision === asgRevision(aA)
      && histM.status === 200 && entryOf(histM.json, aA)?.outcome_state === 'completed',
      { status: recA.status, outcome_revision: recA.data?.outcome_revision ?? null, my_duties: mineA?.outcome?.outcome ?? null,
        response_kept: mineA?.response ?? null, history: entryOf(histM.json, aA)?.outcome_state ?? null });

    // ------------------------------------------------------- declined: never a No-show; cancelled: no outcome
    const noShowB = await record(leader, aB, 'no_show');
    const excusedB = await record(leader, aB, 'excused');
    const recK = await record(leader, aK, 'completed');
    const r1 = await outcomesRead(leader);
    check('O21-a-declined-assignment-cannot-become-a-no-show', refused(noShowB, 'validation_failed', 'outcome', 'not_accepted')
      && done(excusedB) && outcomeOf(r1.json, aB)?.outcome_state === 'excused',
      { no_show: [noShowB.code ?? null, noShowB.field_errors?.outcome ?? null], excused: excusedB.code ?? 'done' });
    check('O22-a-cancelled-accepted-duty-has-no-outcome', refused(recK, 'conflict', 'assignment_id', 'cancelled')
      && outcomeOf(r1.json, aK) === null
      && entryOf(histM.json, aK)?.outcome_state === 'none',
      { record: [recK.code ?? null, recK.field_errors?.assignment_id ?? null], listed: outcomeOf(r1.json, aK) !== null,
        history_state: entryOf(histM.json, aK)?.state ?? null });

    // ------------------------------------------------------- corrections keep the prior value and actor
    const again = await record(deputy, aA, 'excused');
    const noReason = await duty(deputy.token, 'duties.correct_outcome', 1, { assignment_id: aA, outcome: 'no_show' });
    const corr = await correct(deputy, aA, 'no_show', 'SYNTHETIC 4.10 reason: sign-in sheet', { note: 'SYNTHETIC 4.10 note A2' });
    const stale = await correct(leader, aA, 'excused', 'SYNTHETIC 4.10 reason two', {}, 1);
    const r2 = await outcomesRead(leader);
    const oA = outcomeOf(r2.json, aA)?.outcome;
    const firstRow = psql(`select outcome || '|' || note || '|' || (recorded_by_member = '${leader.member}')
      from app.duties_outcomes where assignment_id = '${aA}' and revision = 1`);
    check('O30-corrections-keep-the-prior-value-and-actor', refused(again, 'conflict', 'assignment_id', 'recorded')
      && refused(noReason, 'validation_failed', 'reason', 'required') && done(corr)
      && corr.data?.previous_outcome === 'completed' && refused(stale, 'conflict')
      && trailValues(oA) === 'no_show>completed'
      && oA?.trail?.[1]?.note === 'SYNTHETIC 4.10 note A' && oA?.trail?.[1]?.by === leader.name
      && oA?.trail?.[0]?.by === deputy.name && oA?.trail?.[0]?.reason === 'SYNTHETIC 4.10 reason: sign-in sheet'
      && firstRow === 'completed|SYNTHETIC 4.10 note A|true',
      { second_record: [again.code ?? null, again.field_errors?.assignment_id ?? null],
        without_reason: noReason.field_errors?.reason ?? null, corrected: corr.code ?? 'done', stale: stale.code ?? 'done',
        trail: trailValues(oA), prior_actor_kept: oA?.trail?.[1]?.by === leader.name,
        prior_note_kept: oA?.trail?.[1]?.note === 'SYNTHETIC 4.10 note A' });

    // ------------------------------------------------------- no self-grading
    const own = await record(leader, aL, 'completed');
    const byDeputy = await record(deputy, aL, 'completed');
    check('O31-a-leader-cannot-grade-their-own-duty', refused(own, 'validation_failed', 'assignment_id', 'own')
      && outcomeOf(r2.json, aL)?.own === true && done(byDeputy),
      { own: [own.code ?? null, own.field_errors?.assignment_id ?? null], deputy: byDeputy.code ?? 'done' });

    // ------------------------------------------------------- who reads what
    const notOthers = [];
    for (const [who, p] of [['admin', admin], ['pastor', pastor], ['other_leader', other], ['spare_member', spare]]) {
      const h = await historyRead(p, member.member);
      const o = await outcomesRead(p);
      const reads = [];
      for (const fn of ['duties_leader_board', 'duties_rota', 'duties_coverage', 'duties_admin_overview', 'duties_my_duties']) {
        reads.push((await rpc(fn, p.token)).json);
      }
      const rec = await record(p, aC, 'completed');
      notOthers.push({ who, history: h.status, outcomes: o.status,
        outcomes_departments: (o.json?.departments ?? []).map((d) => d.department_id === departmentId ? 'D' : 'other'),
        text: holdsOutcomeText([h.json, o.json, ...reads]), record: rec.code ?? 'done' });
    }
    const leaderHistory = await historyRead(leader, member.member);
    const deputyHistory = await historyRead(deputy, member.member);
    check('O40-history-and-outcome-text-only-for-the-member-and-their-leaders',
      notOthers.every((n) => n.history === 403 && !n.text && ['forbidden', 'not_found'].includes(n.record))
      && notOthers.filter((n) => n.who !== 'other_leader').every((n) => n.outcomes === 403)
      && notOthers.find((n) => n.who === 'other_leader')?.outcomes_departments.every((d) => d !== 'D')
      && leaderHistory.status === 200 && deputyHistory.status === 200
      && entryOf(deputyHistory.json, aA)?.outcome?.trail?.[0]?.reason === 'SYNTHETIC 4.10 reason: sign-in sheet'
      && leaderHistory.json?.summary?.no_show === 1,
      { others: notOthers, leader_history: leaderHistory.status, deputy_history: deputyHistory.status,
        summary: leaderHistory.json?.summary ? { held: leaderHistory.json.summary.held, no_show: leaderHistory.json.summary.no_show,
          ended: leaderHistory.json.summary.ended } : null });

    // ------------------------------------------------------- codes only; no notifications; tables refused
    const auditCodes = psql(`select coalesce(string_agg(action || ':' || code, ',' order by event_id), '') from app.duties_audit
      where action like 'outcome_%' and department_id = '${departmentId}'`);
    const receiptText = Number(psql(`select count(*) from app.cmd_receipts where result::text like '%SYNTHETIC 4.10%'`));
    const tableQuery = (await http('GET', '/rest/v1/duties_outcomes?select=*', { token: leader.token, profile: 'app' })).status;
    check('O90-codes-only-no-notification-tables-refused', auditCodes.split(',').length === 4
      && !auditCodes.includes('SYNTHETIC') && receiptText === 0 && jobCount() === jobsBefore && tableQuery >= 400,
      { audit: auditCodes.split(',').map((x) => x.split(':')[0]).sort(), receipts_with_text: receiptText,
        new_jobs: jobCount() - jobsBefore, table_query: tableQuery });
  } finally {
    const left = cleanup();
    psql(`select app.sys_revoke_credential('${credentialId}', '${OPERATOR}'); select app.sys_disable_principal('${principal}', '${OPERATOR}');`);
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'duties-outcomes-e2e';
            delete from app.platform_environment_history where set_by = 'duties-outcomes-e2e';`);
    }
    log('O99-cleanup', { users_left: Number(left), credential_revoked: true, principal_disabled: true, unmarked: marked,
      departments_left: Number(psql(`select count(*) from app.duties_departments where name in ('${DEPARTMENT}', '${OTHER_DEPARTMENT}')`)),
      outcomes_left: Number(psql('select count(*) from app.duties_outcomes')) });
  }
  finish();
}

runMain(import.meta.url, main);
