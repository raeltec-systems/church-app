import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  DEPARTMENT, GENERIC_TEXT, LEADER_ONLY, NUMBERS, addDays, argValue, boardPositionOf, churchDate, churchInstant,
  holdsPrivate, isGenericItem, isPilotPhone, itemsNew, leaksLeaderText, minuteCeil, nextSunday, parseTarget,
  positionOf, probePlan, quarterlyRota, shortNoticeStart, stagingCleanupSql,
} from './duties-pilot.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
// Fixed instants (no clock): Thursday 15 October 2026, 10:00 UTC (12:00 church time).
const THURSDAY = Date.parse('2026-10-15T10:00:00Z');
const D = 'aaaaaaaa-1111-4111-8111-111111111111';
const S = 'bbbbbbbb-2222-4222-8222-222222222222';
const O = 'cccccccc-3333-4333-8333-333333333333';
const M = 'dddddddd-4444-4444-8444-444444444444';

test('the department is the synthetic stand-in and every number is in its reserved block', () => {
  assert.equal(DEPARTMENT, 'SYNTHETIC Preaching Rota');
  for (const target of ['local', 'staging']) {
    for (const phone of Object.values(NUMBERS[target])) assert.equal(isPilotPhone(target, phone), true, phone);
  }
  for (const phone of ['+447700900409', '+447700900420', '+12025550169', '+12025550150', '447700900410']) {
    assert.equal(isPilotPhone('local', phone), false, phone);
  }
  for (const phone of ['+12025550165', '+12025550169', '+12025550158', '+447700900410']) {
    assert.equal(isPilotPhone('staging', phone), false, phone);
  }
  assert.equal(isPilotPhone('production', '+447700900410'), false);
});

test('the target is local unless staging is asked for explicitly, and nothing else is accepted', () => {
  assert.equal(parseTarget([], {}), 'local');
  assert.equal(parseTarget(['--target', 'staging'], {}), 'staging');
  assert.equal(parseTarget([], { DUTIES_PILOT_TARGET: 'staging' }), 'staging');
  assert.equal(parseTarget(['--target', 'local'], { DUTIES_PILOT_TARGET: 'local' }), 'local');
  assert.throws(() => parseTarget(['--target', 'production'], {}), /unknown target/);
  assert.throws(() => parseTarget([], { DUTIES_PILOT_TARGET: 'prod' }), /unknown target/);
  assert.throws(() => parseTarget(['--target', 'local'], { DUTIES_PILOT_TARGET: 'staging' }), /disagree/);
  assert.equal(argValue(['x', '--evidence', 'e.jsonl'], '--evidence'), 'e.jsonl');
  assert.equal(argValue(['x', '--evidence', '--target'], '--evidence'), null);
  assert.equal(argValue(['x'], '--cleanup-sql'), null);
});

test('church dates and times are Africa/Lusaka (UTC+2) whatever the machine zone', () => {
  assert.equal(churchDate(Date.parse('2026-10-17T21:59:00Z')), '2026-10-17');
  assert.equal(churchDate(Date.parse('2026-10-17T22:30:00Z')), '2026-10-18');
  assert.equal(churchInstant('2026-10-18', '10:00'), '2026-10-18T08:00:00.000Z');
  assert.equal(churchInstant('2026-10-18', '00:30'), '2026-10-17T22:30:00.000Z');
  assert.equal(addDays('2026-12-27', 7), '2027-01-03');
  assert.equal(minuteCeil(Date.parse('2026-10-15T10:00:00.001Z')), '2026-10-15T10:01:00.000Z');
  assert.equal(minuteCeil(Date.parse('2026-10-15T10:00:00Z')), '2026-10-15T10:00:00.000Z');
});

test('the quarterly rota is 13 Sundays from the first Sunday at least three days away', () => {
  assert.equal(nextSunday(THURSDAY, 3), '2026-10-18');
  // Friday 23:00 UTC is Saturday 01:00 church time: three days on is Tuesday, so the next Sunday.
  assert.equal(nextSunday(Date.parse('2026-10-16T23:00:00Z'), 3), '2026-10-25');
  // A Sunday itself is kept.
  assert.equal(nextSunday(Date.parse('2026-10-15T00:00:00Z'), 3), '2026-10-18');
  const rota = quarterlyRota(THURSDAY);
  assert.deepEqual(rota, { from_date: '2026-10-18', until_date: '2027-01-10', start_time: '10:00', sundays: 13,
    positions: ['Preacher', 'Reader'] });
  for (const date of [rota.from_date, rota.until_date]) assert.equal(new Date(`${date}T00:00:00Z`).getUTCDay(), 0);
  assert.equal((Date.parse(rota.until_date) - Date.parse(rota.from_date)) / 86_400_000 / 7 + 1, rota.sundays);
});

test('the short-notice duty and the reassignment probe are placed relative to the run', () => {
  assert.equal(shortNoticeStart(THURSDAY), '2026-10-15T13:00:00.000Z');
  const probe = probePlan(Date.parse('2026-10-15T10:00:30Z'));
  assert.equal(probe.response_deadline, '2026-10-15T10:16:00.000Z');
  assert.equal(probe.due_at, '2026-10-15T10:06:00.000Z');
  assert.equal(probe.starts_at, '2026-10-17T10:01:00.000Z');
  assert.deepEqual(probe.reminders, [{ anchor: 'response_deadline', before: '10 minutes' }]);
  // The reminder falls due after the reassignment (a few seconds later) and before the answer-by time.
  assert.ok(Date.parse(probe.due_at) - Date.parse('2026-10-15T10:00:30Z') >= 4 * 60_000);
  assert.ok(Date.parse(probe.due_at) < Date.parse(probe.response_deadline));
});

test('inbox items are generic and new items are told apart from earlier ones', () => {
  for (const [kind, [title, body]] of Object.entries(GENERIC_TEXT)) {
    assert.equal(isGenericItem({ reminder_kind: kind, title, body }), true, kind);
    assert.equal(isGenericItem({ reminder_kind: kind, title, body: `${body} SYNTHETIC Ruth` }), false, kind);
  }
  assert.equal(isGenericItem({ reminder_kind: 'unknown_kind', title: 'x', body: 'y' }), false);
  assert.equal(isGenericItem(null), false);
  const items = [{ item_id: 'i1', reminder_kind: 'duty_assigned' }, { item_id: 'i2', reminder_kind: 'duty_released' },
    { item_id: 'i3', reminder_kind: 'duty_assigned' }];
  assert.deepEqual(itemsNew(items, new Set(['i1'])).map((i) => i.item_id), ['i2', 'i3']);
  assert.deepEqual(itemsNew(items, new Set(['i1']), 'duty_assigned').map((i) => i.item_id), ['i3']);
  assert.deepEqual(itemsNew(null, new Set()), []);
});

test('leader-only text, numbers, routes, notes and reasons are caught for a non-leader', () => {
  assert.equal(leaksLeaderText({ assignments: [{ note: 'SYNTHETIC member note M: fine' }] }), false);
  assert.equal(leaksLeaderText({ x: `${LEADER_ONLY}: rang` }), true);
  assert.equal(leaksLeaderText({ x: 'call +447700900419' }), true);
  assert.equal(leaksLeaderText({ x: '+12025550159' }), true);
  assert.equal(holdsPrivate({ departments: [{ contact_routes: {}, positions: [{ assignment: { confirmation: { channel: 'phone' } } }] }] }), false);
  assert.equal(holdsPrivate({ departments: [{ contact_routes: { [M]: [{ belongs_to: 'household' }] }, positions: [] }] }), true);
  assert.equal(holdsPrivate({ departments: [{ positions: [{ assignment: { note: 'x' } }] }] }), true);
  assert.equal(holdsPrivate({ departments: [{ positions: [{ assignment: { confirmation: { reason: 'x' } } }] }] }), true);
  assert.equal(holdsPrivate({ departments: [{ positions: [{ follow_up: { task_id: O } }] }] }), true);
  assert.equal(holdsPrivate({ departments: [{ positions: [{ follow_up: { last_attempt: { note: 'x' } } }] }] }), true);
  assert.equal(holdsPrivate({ any: 'SYNTHETIC member note O: travelling' }), true);
});

test('positions are found in the coverage queue and on the board', () => {
  const coverage = { departments: [{ positions: [{ slot_id: 's1', status: 'unfilled' }, { slot_id: 's2', assignment: { assignment_id: 'a2' }, status: 'declined' }] }] };
  assert.equal(positionOf(coverage, 's1').status, 'unfilled');
  assert.equal(positionOf(coverage, 'a2').status, 'declined');
  assert.equal(positionOf(coverage, 'none'), null);
  const board = { departments: [{ duties: [{ occurrence_id: 'o1', positions: [{ slot_id: 's9', assignment: { assignment_id: 'a9' } }] }] }] };
  assert.equal(boardPositionOf(board, 'a9').duty.occurrence_id, 'o1');
  assert.equal(boardPositionOf(board, 's9').position.slot_id, 's9');
  assert.equal(boardPositionOf(null, 'a9'), null);
});

test('the staging cleanup SQL names only the run and is not destructive to the schema', () => {
  const sql = stagingCleanupSql({ departmentId: D, seriesIds: [S], occurrenceIds: [O, O], memberIds: [M] });
  assert.match(sql, /^-- Story 4\.13/);
  assert.match(sql, /\nbegin;\n/);
  assert.match(sql, /commit;\n$/);
  assert.doesNotMatch(sql.replaceAll('on commit drop', ''), /\b(drop|truncate|alter)\b/i);
  assert.doesNotMatch(sql, /delete from app\.duties_departments d/);
  assert.doesNotMatch(sql, /identity_members|auth\.users/);
  assert.equal(sql.split(`'${O}'`).length - 1, 1);
  assert.match(sql, new RegExp(`series_id in \\('${S}'\\)`));
  assert.match(sql, /dm\.ended_at is not null/);
  const whole = stagingCleanupSql({ departmentId: D, removeDepartment: true });
  assert.match(whole, /delete from app\.duties_departments d where d\.department_id = 'aaaaaaaa/);
  assert.match(whole, /series_id in \(null\)/);
  assert.throws(() => stagingCleanupSql({ departmentId: 'x' }), /department id/);
  assert.throws(() => stagingCleanupSql({ departmentId: D, occurrenceIds: ["1'; drop table x; --"] }), /uuids/);
});

test('a wrong target or a staging run without its guards is refused before any call', () => {
  const script = join(HERE, 'duties-pilot.mjs');
  const run = (env, args = []) => spawnSync(process.execPath, [script, ...args], {
    encoding: 'utf8', env: { PATH: process.env.PATH, ...env }, timeout: 20_000 });
  const bogus = run({ DUTIES_PILOT_TARGET: 'production' });
  assert.equal(bogus.status, 1);
  assert.match(bogus.stderr, /unknown target production/);
  const noKey = run({ DUTIES_PILOT_TARGET: 'staging' });
  assert.equal(noKey.status, 1);
  assert.match(noKey.stderr, /STAGING_PUBLISHABLE_KEY must be an sb_publishable_ key/);
  const secretKey = run({ DUTIES_PILOT_TARGET: 'staging', STAGING_PUBLISHABLE_KEY: 'sb_secret_abc' });
  assert.match(secretKey.stderr, /sb_publishable_/);
  const inside = run({ DUTIES_PILOT_TARGET: 'staging', STAGING_PUBLISHABLE_KEY: 'sb_publishable_x',
    STAGING_SUITE_ADMIN: join(HERE, 'admin.json') });
  assert.equal(inside.status, 1);
  assert.match(inside.stderr, /inside the repository/);
});
