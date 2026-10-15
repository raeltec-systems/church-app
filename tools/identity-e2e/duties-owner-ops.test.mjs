import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  CELLS, DEPARTMENT, DEPARTMENT_TEXT, churchAt, firstJson, holdsDepartmentText, isFictionalOwnerOpsPhone,
  jsonLiteral, ownerCallSql, sessionClaims,
} from './duties-owner-ops.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900240', '+447700900249']) assert.equal(isFictionalOwnerOpsPhone(p), true);
  for (const p of ['+447700900239', '+447700900250', '+12025550240', '447700900240']) {
    assert.equal(isFictionalOwnerOpsPhone(p), false);
  }
});

test('the department, cells and texts are synthetic stand-ins', () => {
  assert.match(DEPARTMENT, /^SYNTHETIC /);
  for (const c of CELLS) assert.match(c, /^SYNTHETIC /);
  for (const t of DEPARTMENT_TEXT) assert.match(t, /^SYNTHETIC /);
});

test('department text anywhere in a cell answer is caught', () => {
  assert.equal(holdsDepartmentText({ positions: [{ kind: 'linked', filled: true }] }), false);
  assert.equal(holdsDepartmentText({ positions: [{ name: 'SYNTHETIC 4.11 E2E Member Q' }] }), true);
  assert.equal(holdsDepartmentText([{ note: 'SYNTHETIC 4.11 department instructions two' }]), true);
  assert.equal(holdsDepartmentText(null), false);
});

test('session claims are read from the token without keeping it', () => {
  const payload = { sub: 'u1', session_id: 's1', amr: [{ method: 'password' }] };
  const token = `h.${Buffer.from(JSON.stringify(payload)).toString('base64url')}.sig`;
  assert.deepEqual(sessionClaims(token), payload);
  assert.throws(() => sessionClaims(''));
});

test('JSON values are dollar-quoted, and the quote tag is refused inside them', () => {
  assert.equal(jsonLiteral({ a: 'b' }), '$j$' + '{"a":"b"}' + '$j$::jsonb');
  assert.throws(() => jsonLiteral({ a: '$j$' }));
});

test('an owner call runs inside one transaction with the session claims', () => {
  const sql = ownerCallSql({ sub: 'u1' }, 'fixture_programme_publish', { cell_id: 'c1' }, { sleepSeconds: 1.5 });
  assert.match(sql, /^begin;/);
  assert.match(sql, /set_config\('request\.jwt\.claims', \$j\$\{"sub":"u1"\}\$j\$, true\)/);
  assert.match(sql, /pg_temp\.try\('fixture_programme_publish', \$j\$\{"cell_id":"c1"\}\$j\$::jsonb\)/);
  assert.match(sql, /pg_sleep\(1\.5\)/);
  assert.match(sql, /commit;$/);
  assert.throws(() => ownerCallSql({}, 'bad; name', {}));
});

test('the first JSON line of psql output is the answer', () => {
  assert.deepEqual(firstJson('\n{"code":"forbidden"}\n\n'), { code: 'forbidden' });
  assert.equal(firstJson(''), null);
});

test('church clock times are UTC+2 (Africa/Lusaka, no daylight saving)', () => {
  assert.equal(churchAt('2026-10-21', '18:00'), '2026-10-21T16:00:00Z');
  assert.equal(churchAt('2026-10-21', '01:30'), '2026-10-20T23:30:00Z');
});
