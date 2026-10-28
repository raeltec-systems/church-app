import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  DEPARTMENT, OTHER_DEPARTMENT, REVIEW_NOTICE, VACANCY_REASONS, boardHistory, churchTen, coarseOrNull, coveragePosition,
  done, firstJson, isFictionalDecisionsPhone, jsonLiteral, ownerCallSql, refused, sessionClaims,
} from './duties-decisions.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900720', '+447700900729']) assert.equal(isFictionalDecisionsPhone(p), true);
  for (const p of ['+447700900719', '+447700900730', '+12025550720', '447700900720']) {
    assert.equal(isFictionalDecisionsPhone(p), false);
  }
});

test('the departments are synthetic stand-ins', () => {
  assert.equal(DEPARTMENT, 'SYNTHETIC Preaching Rota');
  assert.match(OTHER_DEPARTMENT, /^SYNTHETIC /);
});

test('the review notice is generic and opens the board reviews', () => {
  assert.equal(REVIEW_NOTICE.title, 'Duty needs review');
  assert.equal(REVIEW_NOTICE.link, '/duties/leader/reviews');
});

test('a vacancy reason is one of three coarse codes or nothing', () => {
  assert.deepEqual(VACANCY_REASONS, ['removed_from_department', 'member_inactive', 'member_deleted']);
  for (const v of [...VACANCY_REASONS, null, undefined]) assert.equal(coarseOrNull(v), true);
  for (const v of ['moved_away', 'login_disabled', 'SYNTHETIC free text', '']) assert.equal(coarseOrNull(v), false);
});

test('coverage positions and the newest board history entry are found', () => {
  const cov = { departments: [{ positions: [{ slot_id: 's1', vacated: { since: 'x', reason: 'member_inactive' } }] }] };
  assert.equal(coveragePosition(cov, 's1').vacated.reason, 'member_inactive');
  assert.equal(coveragePosition(cov, 'none'), null);
  assert.equal(coveragePosition(null, 's1'), null);
  const board = { departments: [{ duties: [{ occurrence_id: 'o1', positions: [{ history: [
    { ended_at: '2026-10-15T08:00:00Z', end_reason: 'revised' },
    { ended_at: '2026-10-15T09:00:00Z', end_reason: 'vacated', vacancy_reason: 'removed_from_department' }] }] }] }] };
  assert.equal(boardHistory(board, 'o1').vacancy_reason, 'removed_from_department');
  assert.equal(boardHistory(board, 'o2'), null);
  assert.equal(boardHistory({ departments: [{ duties: [{ occurrence_id: 'o1', positions: [{}] }] }] }, 'o1'), null);
});

test('done and refused read the command envelope', () => {
  assert.equal(done({ status: 200, data: {} }), true);
  assert.equal(done({ status: 200, code: 'conflict' }), false);
  assert.equal(done(undefined), false);
  const r = { status: 200, code: 'conflict', field_errors: { member_id: 'handover_required' } };
  assert.equal(refused(r, 'conflict', 'member_id', 'handover_required'), true);
  assert.equal(refused(r, 'conflict'), true);
  assert.equal(refused(r, 'forbidden'), false);
  assert.equal(refused({ code: 'conflict' }, 'conflict', 'member_id', 'handover_required'), false);
});

test('owner calls are built for a named function only, with the caller claims as data', () => {
  const claims = sessionClaims('x.eyJzdWIiOiJ1MSIsInNlc3Npb25faWQiOiJzMSJ9.y');
  const sql = ownerCallSql(claims, 'fixture_event_changed', { event_id: 'e1', changed: ["it's"] });
  assert.match(sql, /select pg_temp\.try\('fixture_event_changed', /);
  assert.ok(sql.includes(jsonLiteral({ event_id: 'e1', changed: ["it's"] })));
  assert.throws(() => ownerCallSql(claims, 'x; drop', {}));
  assert.deepEqual(firstJson('noise\n{"flagged": 3}\n'), { flagged: 3 });
  assert.equal(firstJson('none'), null);
});

test('church ten is 08:00 UTC (Africa/Lusaka, UTC+2)', () => {
  assert.equal(churchTen('2026-10-18'), '2026-10-18T08:00:00Z');
});
