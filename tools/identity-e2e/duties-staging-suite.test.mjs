import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  BORROWED, DEPARTMENTS, DUTIES_PEOPLE, MEMBER_NOTE, NUMBERS, PRINCIPALS, PRIVATE, PROBES, READS, STALE, SUITE_TEXT,
  addDays, argValue, boardEntry, changedFields, churchDate, coveragePosition, departmentC, expectProbe, expectRead,
  isLimitedConflict, isSuitePhone, leakKind, leaksPrivate, minuteCeil, newestHistory, parseTarget, renderSummary,
  runCalendar, stagingCleanupSql,
} from './duties-staging-suite.mjs';
import { NUMBERS as PILOT_NUMBERS } from './duties-pilot.mjs';
import { PERSONAS as IDENTITY_PERSONAS } from './staging-suite.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
// Fixed instants (no clock): Thursday 15 October 2026, 10:00 UTC (12:00 church time).
const THURSDAY = Date.parse('2026-10-15T10:00:00Z');
const A = 'aaaaaaaa-1111-4111-8111-111111111111';
const B = 'bbbbbbbb-2222-4222-8222-222222222222';
const C = 'cccccccc-3333-4333-8333-333333333333';

test('every number is in the suite\'s reserved block and none is another suite\'s staging persona', () => {
  for (const target of ['local', 'staging']) {
    for (const phone of Object.values(NUMBERS[target])) assert.equal(isSuitePhone(target, phone), true, phone);
  }
  for (const phone of ['+447700900539', '+447700900550', '+447700900583', '447700900541']) assert.equal(isSuitePhone('local', phone), false, phone);
  for (const phone of ['+12025550152', '+12025550160', '+12025550170', '+12025550199', '+447700900541']) {
    assert.equal(isSuitePhone('staging', phone), false, phone);
  }
  assert.equal(isSuitePhone('production', NUMBERS.local.m1), false);
  // The Duties people never reuse the identity suite's or the pilot's staging accounts (0150 is the shared Admin).
  const others = new Set([...Object.values(IDENTITY_PERSONAS).map((p) => p.phone), ...Object.values(PILOT_NUMBERS.staging)]);
  for (const label of DUTIES_PEOPLE) assert.equal(others.has(NUMBERS.staging[label]), false, label);
  // The owner's demonstration block (+1 202 555 0170-0179) is never used.
  for (const phone of Object.values(NUMBERS.staging)) assert.doesNotMatch(phone, /^\+120255501(7\d)$/);
  assert.deepEqual(Object.keys(BORROWED).sort(), ['cellL', 'deact', 'guest', 'held', 'pastor']);
});

test('the target is local unless staging is asked for explicitly, and nothing else is accepted', () => {
  assert.equal(parseTarget([], {}), 'local');
  assert.equal(parseTarget(['--target', 'staging'], {}), 'staging');
  assert.equal(parseTarget([], { DUTIES_SUITE_TARGET: 'staging' }), 'staging');
  assert.throws(() => parseTarget(['--target', 'production'], {}), /unknown target/);
  assert.throws(() => parseTarget(['--target', 'local'], { DUTIES_SUITE_TARGET: 'staging' }), /disagree/);
  assert.equal(argValue(['x', '--summary', 's.md'], '--summary'), 's.md');
  assert.equal(argValue(['x', '--summary', '--keep'], '--summary'), null);
});

test('the run calendar is 12-21 church days ahead and fits the 31-day coverage window', () => {
  for (const runId of ['00000000', '0000000f', 'ffffffff', '12ab34cd', 'zzzzzzzz']) {
    const cal = runCalendar(THURSDAY, runId);
    const days = (Date.parse(`${cal.base}T00:00:00Z`) - Date.parse(`${churchDate(THURSDAY)}T00:00:00Z`)) / 86_400_000;
    assert.ok(days >= 12 && days <= 21, `${runId}: ${days}`);
    assert.match(cal.minute, /^(00|15|30|45)$/);
    assert.equal(cal.to, addDays(cal.from, 27));
  }
  assert.equal(minuteCeil(Date.parse('2026-10-15T10:00:00.001Z')), '2026-10-15T10:01:00.000Z');
  assert.equal(departmentC('1a2b3c4d'), 'SYNTHETIC Closing Suite C 1a2b3c4d');
  assert.ok(Object.values(DEPARTMENTS).every((n) => n.startsWith('SYNTHETIC ')));
});

test('the read matrix: admin-only, oversight, scope-only and own reads', () => {
  assert.deepEqual(expectRead(PRINCIPALS.anon, 'duties_my_duties'), { status: 401 });
  assert.deepEqual(expectRead(PRINCIPALS.guest, 'duties_my_duties'), { status: 403, detail: 'not_linked' });
  assert.deepEqual(expectRead(PRINCIPALS.held, 'followups_my_tasks'), { status: 403, detail: 'review_required' });
  assert.deepEqual(expectRead(PRINCIPALS.deact, 'duties_rota'), { status: 403, detail: 'not_linked' });
  const ng = { status: 403, detail: 'not_granted' };
  const ok = { status: 200 };
  // The Admin role alone manages but holds no department scope: no outcomes, no member history.
  assert.deepEqual(expectRead(PRINCIPALS.admin, 'duties_admin_overview'), ok);
  assert.deepEqual(expectRead(PRINCIPALS.admin, 'duties_outcomes'), ng);
  assert.deepEqual(expectRead(PRINCIPALS.admin, 'duties_member_history'), ng);
  assert.deepEqual(expectRead(PRINCIPALS.admin, 'followups_task'), ok);
  // Pastor oversees (rota, board, coverage) but does not manage (candidates) or own tasks.
  assert.deepEqual(expectRead(PRINCIPALS.pastor, 'duties_coverage'), ok);
  assert.deepEqual(expectRead(PRINCIPALS.pastor, 'duties_candidates'), ng);
  assert.deepEqual(expectRead(PRINCIPALS.pastor, 'followups_task'), ng);
  // Another department's leader: its own board, not A's coverage or candidates; the shared member's history.
  assert.deepEqual(expectRead(PRINCIPALS.leadB, 'duties_leader_board'), ok);
  assert.deepEqual(expectRead(PRINCIPALS.leadB, 'duties_coverage'), ng);
  assert.deepEqual(expectRead(PRINCIPALS.leadB, 'duties_member_history'), ok);
  // A cell leader gains no department authority, but supervises fixture follow-ups in their scope.
  assert.deepEqual(expectRead(PRINCIPALS.cellL, 'duties_leader_board'), ng);
  assert.deepEqual(expectRead(PRINCIPALS.cellL, 'followups_supervision'), ok);
  assert.deepEqual(expectRead(PRINCIPALS.m1, 'duties_member_history'), ok);
  assert.deepEqual(expectRead(PRINCIPALS.m1, 'duties_rota'), ng);
  for (const p of Object.values(PRINCIPALS)) for (const r of READS) assert.ok(expectRead(p, r).status, r);
  assert.throws(() => expectRead(PRINCIPALS.m1, 'duties_unknown'), /no expectation/);
});

test('the command probes: conflict only with authority, otherwise refused without disclosure', () => {
  assert.equal(STALE > 1000, true);
  assert.deepEqual(expectProbe(PRINCIPALS.anon, 'duties.respond'), { status: 401 });
  assert.deepEqual(expectProbe(PRINCIPALS.held, 'duties.respond'), { code: 'forbidden' });
  assert.deepEqual(expectProbe(PRINCIPALS.m1, 'duties.respond'), { code: 'conflict' });
  assert.deepEqual(expectProbe(PRINCIPALS.leadA, 'duties.respond'), { code: 'not_found' });
  assert.deepEqual(expectProbe(PRINCIPALS.admin, 'duties.confirm_by_leader'), { code: 'forbidden' });
  assert.deepEqual(expectProbe(PRINCIPALS.leadB, 'duties.confirm_by_leader'), { code: 'not_found' });
  assert.deepEqual(expectProbe(PRINCIPALS.depA, 'duties.confirm_by_leader'), { code: 'conflict' });
  assert.deepEqual(expectProbe(PRINCIPALS.admin, 'duties.revise_duty'), { code: 'conflict' });
  assert.deepEqual(expectProbe(PRINCIPALS.pastor, 'duties.revise_duty'), { code: 'forbidden' });
  assert.deepEqual(expectProbe(PRINCIPALS.leadA, 'duties.add_member'), { code: 'forbidden' });
  assert.deepEqual(expectProbe(PRINCIPALS.m1, 'followups.reassign'), { code: 'forbidden' });
  assert.deepEqual(expectProbe(PRINCIPALS.admin, 'followups.update_task'), { code: 'forbidden' });
  for (const p of Object.values(PRINCIPALS)) for (const probe of PROBES) assert.ok(expectProbe(p, probe.cmd), probe.cmd);
  assert.throws(() => expectProbe(PRINCIPALS.m1, 'duties.unknown'), /no expectation/);
});

test('reading answers: positions, history, what changed, limited conflicts and leaks', () => {
  const cov = { departments: [{ positions: [{ slot_id: 's1', status: 'unfilled' }, { slot_id: 's2', assignment: { assignment_id: 'a2' } }] }] };
  assert.equal(coveragePosition(cov, 's1').status, 'unfilled');
  assert.equal(coveragePosition(cov, 'a2').slot_id, 's2');
  assert.equal(coveragePosition(null, 'a2'), null);
  const board = { departments: [{ duties: [{ occurrence_id: 'o1', positions: [{ slot_id: 's9', assignment: { assignment_id: 'a9' },
    history: [{ ended_at: '2026-10-01T00:00:00Z', state: 'old' }, { ended_at: '2026-10-02T00:00:00Z', state: 'new' }] }] }] }] };
  assert.equal(boardEntry(board, 'a9').duty.occurrence_id, 'o1');
  assert.equal(boardEntry(board, 'o1').position.slot_id, 's9');
  assert.equal(newestHistory(boardEntry(board, 's9').position).state, 'new');
  assert.deepEqual(changedFields({ location: 'changed', assignment_id: 'superseded', starts_at: 'changed' }), ['location', 'starts_at']);
  assert.equal(isLimitedConflict({ visibility: 'limited', owner_kind: 'department', from: 'x', to: 'y' }), true);
  assert.equal(isLimitedConflict({ visibility: 'limited', owner_kind: 'department', from: 'x', to: 'y', duty_name: 'z' }), false);
  assert.equal(leaksPrivate({ a: `${PRIVATE}: x` }), true);
  assert.equal(leaksPrivate({ a: 'call +12025550159' }), true);
  assert.equal(leaksPrivate({ a: `${MEMBER_NOTE} M1` }), false);
  assert.equal(leakKind({ a: '+447700900549' }), 'number');
  assert.equal(leakKind({}), null);
  assert.deepEqual(SUITE_TEXT.duty_review_flagged[0], 'Duty needs review');
  assert.deepEqual(SUITE_TEXT.duty_vacated[0], 'Positions need cover');
});

test('the staging cleanup SQL removes the run\'s rows, keeps people and departments A and B, and is not destructive', () => {
  const sql = stagingCleanupSql({ keptDepartmentIds: [A, B], runDepartmentIds: [C, C] });
  assert.match(sql, /^-- Story 4\.15/);
  assert.match(sql, /\nbegin;\n/);
  assert.match(sql, /commit;\n$/);
  // It refuses to run anywhere but staging, before any row is touched.
  assert.ok(sql.indexOf("app.platform_current_environment() is distinct from 'staging'") < sql.indexOf('delete from'));
  assert.match(sql, /raise exception 'the closing-suite cleanup runs only on staging'/);
  // Only SYNTHETIC departments of this suite are touched, whatever ids it is given.
  assert.equal(sql.split("d.is_synthetic and d.name like 'SYNTHETIC Closing Suite%'").length - 1, 2);
  assert.doesNotMatch(sql.replaceAll('on commit drop', ''), /\b(drop|truncate|alter)\b/i);
  assert.doesNotMatch(sql, /identity_members|auth\.users|identity_account_links|duties_outcomes x|identity_access_audit|identity_membership_lifecycle/);
  assert.match(sql, /delete from app\.duties_departments d where d\.department_id in \(select department_id from suite_run\);/);
  assert.match(sql, /department_id not in \(select department_id from suite_kept\)/);
  assert.match(sql, /dm\.department_id in \(select department_id from suite_kept\)\n\s+and dm\.ended_at is not null/);
  assert.match(sql, /delete from app\.notifications_schedules s where s\.source_id in \(select id from suite_sources\);/);
  assert.equal(sql.split(`'${C}'`).length - 1, 1);
  assert.equal(stagingCleanupSql({ keptDepartmentIds: [A] }).includes('d.department_id in (null)'), true);
  assert.match(stagingCleanupSql({ keptDepartmentIds: [A], environment: 'local' }), /is distinct from 'local'/);
  assert.throws(() => stagingCleanupSql({ keptDepartmentIds: [A], environment: 'production' }), /staging/);
  assert.throws(() => stagingCleanupSql({ keptDepartmentIds: [] }), /kept department/);
  assert.throws(() => stagingCleanupSql({ keptDepartmentIds: [A], runDepartmentIds: ["1'; drop table x; --"] }), /uuids/);
});

test('the summary shows both matrices and marks a difference', () => {
  const md = renderSummary({ target: 'staging', results: [{ step: 'S10-x', ok: true }, { step: 'M-reads-m1', ok: false }],
    matrixRows: [
      { principal: 'm1', surface: 'duties_rota', kind: 'read', got: { status: 403, detail: 'not_granted' }, ok: true },
      { principal: 'admin', surface: 'duties.respond', kind: 'command', got: { code: 'conflict' }, ok: false },
    ], notRun: ['deletion'] });
  assert.match(md, /Scenario checks: 1\/1 passed\. Matrix cells: 1\/2/);
  assert.match(md, /\| duties_rota \|.*403 ng/);
  assert.match(md, /\*\*cf≠\*\*/);
  assert.match(md, /## Not run on this target\n\n- deletion/);
});

test('a wrong target or a staging run without its guards is refused before any call', () => {
  const script = join(HERE, 'duties-staging-suite.mjs');
  const run = (env, args = []) => spawnSync(process.execPath, [script, ...args], {
    encoding: 'utf8', env: { PATH: process.env.PATH, ...env }, timeout: 20_000 });
  const bogus = run({ DUTIES_SUITE_TARGET: 'production' });
  assert.equal(bogus.status, 1);
  assert.match(bogus.stderr, /unknown target production/);
  const noKey = run({ DUTIES_SUITE_TARGET: 'staging' });
  assert.equal(noKey.status, 1);
  assert.match(noKey.stderr, /STAGING_PUBLISHABLE_KEY must be an sb_publishable_ key/);
  const secretKey = run({ DUTIES_SUITE_TARGET: 'staging', STAGING_PUBLISHABLE_KEY: 'sb_secret_abc' });
  assert.match(secretKey.stderr, /sb_publishable_/);
  const inside = run({ DUTIES_SUITE_TARGET: 'staging', STAGING_PUBLISHABLE_KEY: 'sb_publishable_x',
    STAGING_SUITE_ADMIN: join(HERE, 'admin.json') });
  assert.equal(inside.status, 1);
  assert.match(inside.stderr, /inside the repository/);
});
