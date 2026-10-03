import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, appendFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { evaluate, findDestructive, stripSql } from './check-migrations.mjs';
import { compare, parseHosted, localMigrations } from './check-migration-drift.mjs';
import { findSecrets } from './secret-patterns.mjs';
import { scanFiles } from './scan-secrets.mjs';
import { seal, verify } from './package-web.mjs';

// Synthetic credentials are assembled at run time so this file never matches the repo scan.
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const jwt = (payload) => `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64(payload)}.${'s'.repeat(43)}`;
const SECRET_KEY = 'sb_' + 'secret_' + 'Q'.repeat(30);
const ACCESS_TOKEN = 'sb' + 'p_' + 'a1'.repeat(20);
const PUBLISHABLE = 'sb_' + 'publishable_' + 'P'.repeat(30);

// ---------------------------------------------------------------- migration policy

const BASE = ['20261003112319_a.sql', '20261003134340_b.sql'];
const files = (extra = {}) => ({ '20261003112319_a.sql': 'select 1;', '20261003134340_b.sql': 'select 2;', ...extra });

test('additive later migration passes', () => {
  const r = evaluate({ files: files({ '20261004000000_c.sql': 'create table app.t(id int);' }), baseNames: BASE,
    changed: [{ status: 'A', path: 'supabase/migrations/20261004000000_c.sql' }] });
  assert.deepEqual(r.errors, []);
});

test('destructive statements in new migrations fail with line numbers', () => {
  for (const sql of ['drop table app.t;', 'alter table app.t drop column x;', 'TRUNCATE app.t;',
    'drop function if exists app.f();', 'do $$ begin execute \'x\'; drop view app.v; end $$;']) {
    const r = evaluate({ files: files({ '20261004000000_c.sql': `-- header\n${sql}` }), baseNames: BASE, changed: [] });
    assert.equal(r.errors.length, 1, sql);
    assert.match(r.errors[0], /20261004000000_c\.sql:2: destructive/);
  }
});

test('comments, string literals and relaxations are not destructive', () => {
  const sql = `-- we never drop anything
/* truncate later /* nested drop */ */
insert into app.t(note) values ('awaiting an owner-approved drop'), ('it''s truncate');
alter table app.t alter column x drop not null;
alter table app.t alter column y drop default;
create temp table tmp(x int) on commit drop;
select "drop" from app.t;`;
  assert.deepEqual(findDestructive(sql), []);
  assert.equal(stripSql("a 'b\nc' d").split('\n').length, 2);
});

test('apostrophes inside dollar quotes and E-strings cannot hide a later DROP', () => {
  const cases = [
    ["comment on table app.t is $$Don't use$$;\ndrop table app.u;", 2],
    ["insert into app.t(note) values (E'it\\'s');\ndrop table app.u;", 2],
    ["comment on table app.t is $doc$Don't $$ use$doc$;\nselect 1;\ndrop table app.u;", 3],
    ["create function app.f() returns void language plpgsql as $fn$\nbegin\n  raise notice 'x'; -- don't\n  drop table app.u;\nend;\n$fn$;", 4],
    ['do $$\nbegin\n  drop view app.v;\nend $$;', 3],
  ];
  for (const [sql, line] of cases) {
    const hits = findDestructive(sql);
    assert.equal(hits.length, 1, sql);
    assert.equal(hits[0].line, line, sql);
  }
  // A DROP inside a literal (non-body) dollar quote or E-string is text, not a statement.
  assert.deepEqual(findDestructive("comment on table app.t is $$drop me$$;\nselect E'a\\'drop';"), []);
  // Bare DROP IDENTITY / DROP EXPRESSION stay strict; only the IF EXISTS forms are allowed.
  assert.equal(findDestructive('alter table app.t alter column x drop identity;').length, 1);
  assert.deepEqual(findDestructive('alter table app.t alter column x drop identity if exists;'), []);
});

test('an owner-approved cleanup marker allows destructive statements', () => {
  const sql = '-- owner-approved-cleanup: decision 2026-11-01 retire v0 functions\ndrop function app.retired_x_v0();';
  const r = evaluate({ files: files({ '20261004000000_c.sql': sql }), baseNames: BASE, changed: [] });
  assert.deepEqual(r.errors, []);
  assert.match(r.notes.join(), /owner-approved-cleanup/);
  const empty = '-- owner-approved-cleanup:\ndrop table app.t;';
  assert.equal(evaluate({ files: files({ '20261004000000_c.sql': empty }), baseNames: BASE }).errors.length, 1);
});

test('out-of-order, duplicate and badly named migrations fail', () => {
  const early = evaluate({ files: files({ '20261003120000_late_arrival.sql': 'select 3;' }), baseNames: BASE });
  assert.match(early.errors.join(), /must be later than/);
  const dup = evaluate({ files: files({ '20261003134340_dup.sql': 'select 3;' }), baseNames: BASE });
  assert.match(dup.errors.join(), /already used/);
  const bad = evaluate({ files: files({ 'fix.sql': 'select 3;' }) });
  assert.match(bad.errors.join(), /name must be/);
});

test('merged migrations are immutable', () => {
  const edited = evaluate({ files: files(), baseNames: BASE, changed: [{ status: 'M', path: 'supabase/migrations/20261003134340_b.sql' }] });
  assert.match(edited.errors.join(), /immutable/);
  const renamed = evaluate({ files: { '20261003112319_a.sql': '', '20261005000000_b.sql': '' }, baseNames: BASE,
    changed: [{ status: 'R100', oldPath: 'supabase/migrations/20261003134340_b.sql', path: 'supabase/migrations/20261005000000_b.sql' }] });
  assert.match(renamed.errors.join(), /cannot be renamed/);
  const deleted = evaluate({ files: { '20261003112319_a.sql': '' }, baseNames: BASE,
    changed: [{ status: 'D', path: 'supabase/migrations/20261003134340_b.sql' }] });
  assert.match(deleted.errors.join(), /immutable|renamed or deleted/);
});

test('without a base every migration must be non-destructive', () => {
  assert.equal(evaluate({ files: files({ '20261004000000_c.sql': 'drop table x;' }) }).errors.length, 1);
});

// ---------------------------------------------------------------- drift

const L = [{ version: '1', name: 'a' }, { version: '2', name: 'b' }];

test('drift: in sync, pending and drift cases', () => {
  assert.equal(compare(L, L).status, 'in_sync');
  const pend = compare([...L, { version: '3', name: 'c' }], L);
  assert.equal(pend.status, 'pending');
  assert.deepEqual(pend.pending, ['3_c']);
  assert.match(compare(L, [...L, { version: '3', name: 'hotfix' }]).drift.join(), /not in supabase\/migrations/);
  assert.match(compare(L, [{ version: '1', name: 'a' }, { version: '2', name: 'other' }]).drift.join(), /hosted name/);
  assert.match(compare([...L, { version: '15', name: 'x' }], [...L, { version: '3', name: 'c' }]).drift.join(), /not in supabase/);
  assert.match(compare([{ version: '1', name: 'a' }, { version: '2', name: 'b' }, { version: '3', name: 'c' }],
    [{ version: '1', name: 'a' }, { version: '3', name: 'c' }]).drift.join(), /out of order/);
});

test('drift: parses MCP / Management API shapes', () => {
  assert.deepEqual(parseHosted({ migrations: [{ version: '2', name: 'b' }, { version: '1', name: 'a' }] }), L);
  assert.deepEqual(parseHosted([{ version: 1, name: 'a' }]), [{ version: '1', name: 'a' }]);
  assert.throws(() => parseHosted({ nope: 1 }), /not an array/);
  assert.ok(localMigrations().length >= 5);
});

// ---------------------------------------------------------------- secrets

test('repo mode finds real credentials but not role names or local defaults', () => {
  const text = [
    `key=${SECRET_KEY}`, `token ${ACCESS_TOKEN}`, `svc=${jwt({ role: 'service_role', iss: 'supabase' })}`,
    '-----BEGIN ' + 'PRIVATE KEY-----', 'postgres://postgres:' + 'Hunter2Secret@db.abcdefghijklmnopqrst.supabase.co:5432/postgres',
  ].join('\n');
  const rules = findSecrets(text).map((h) => h.rule);
  for (const r of ['supabase_secret_key', 'supabase_access_token', 'jwt(role=service_role)', 'private_key', 'database_url_with_password']) {
    assert.ok(rules.includes(r), r);
  }
  const benign = 'grant select to service_role;\npostgresql://postgres:postgres@127.0.0.1:54322/postgres\npostgres://u:$PGPASSWORD@host/db\nsb_secret_ prefix mentioned';
  assert.deepEqual(findSecrets(benign), []);
  assert.ok(!JSON.stringify(findSecrets(text)).includes(SECRET_KEY), 'findings never echo the value');
});

test('bundle mode refuses any JWT and service_role but allows a publishable key', () => {
  assert.deepEqual(findSecrets(`const k="${PUBLISHABLE}";const u="https://x.supabase.co";`, { mode: 'bundle' }), []);
  assert.match(findSecrets(`k="${jwt({ role: 'anon' })}"`, { mode: 'bundle' })[0].rule, /jwt_in_client_bundle\(role=anon\)/);
  assert.equal(findSecrets('x="service_role"', { mode: 'bundle' })[0].rule, 'service_role_reference');
  // supabase-dart's own prefix check is not a key; a real secret key is.
  assert.deepEqual(findSecrets('B.c.ba(a,"sb_secret_")', { mode: 'bundle' }), []);
  assert.equal(findSecrets(`k="${SECRET_KEY}"`, { mode: 'bundle' })[0].rule, 'supabase_secret_key');
});

test('bundle scan reads binary files too', () => {
  const dir = mkdtempSync(join(tmpdir(), 'scan-'));
  try {
    writeFileSync(join(dir, 'clean.js'), `const k="${PUBLISHABLE}";`);
    writeFileSync(join(dir, 'main.wasm'), Buffer.concat([Buffer.from([0, 1, 2]), Buffer.from(SECRET_KEY)]));
    const hits = scanFiles([join(dir, 'clean.js'), join(dir, 'main.wasm')], { mode: 'bundle', base: dir });
    assert.ok(hits.some((h) => h.file === 'main.wasm'));
    assert.ok(!hits.some((h) => h.file === 'clean.js'));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------- immutable artifacts

test('sealed artifacts verify and detect tampering or the wrong environment', () => {
  const root = mkdtempSync(join(tmpdir(), 'seal-'));
  const dir = join(root, 'web');
  try {
    mkdirSync(join(dir, 'assets'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<html></html>');
    writeFileSync(join(dir, 'assets', 'a.js'), 'x');
    const m = seal(dir, { env: 'staging', commit: 'abc', apiUrl: 'https://x.supabase.co' });
    assert.equal(m.file_count, 2);
    assert.equal(verify(dir, { env: 'staging', commit: 'abc' }).tree_sha256, m.tree_sha256);
    assert.throws(() => verify(dir, { env: 'production' }), /built for staging/);
    assert.throws(() => verify(dir, { commit: 'def' }), /built from abc/);
    appendFileSync(join(dir, 'assets', 'a.js'), 'y');
    assert.throws(() => verify(dir), /changed after sealing: assets\/a\.js/);
    writeFileSync(join(dir, 'assets', 'a.js'), 'x');
    writeFileSync(join(dir, 'extra.js'), '');
    assert.throws(() => verify(dir), /added after sealing/);
    rmSync(join(dir, 'extra.js'));
    rmSync(join(dir, 'index.html'));
    assert.throws(() => verify(dir), /missing: index\.html/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------- hosted SQL

test('hosted SQL only targets known environments and quotes values', async () => {
  const { verifySql, ensureMarkerSql, literal } = await import('./hosted-sql.mjs');
  assert.match(verifySql('production'), /set_config\('ci\.expected_env', 'production', false\)/);
  assert.throws(() => verifySql('local'), /unknown environment/);
  assert.throws(() => ensureMarkerSql("staging'); drop table x; --", 'ci'), /unknown environment/);
  assert.equal(literal("o'brien"), "'o''brien'");
  assert.match(ensureMarkerSql('staging', "gh:o'brien run 1"), /'gh:o''brien run 1'/);
  assert.throws(() => ensureMarkerSql('staging', ' '), /set_by/);
});

test('pre-push precheck refuses a database marked as another environment', async () => {
  const { precheckSql } = await import('./hosted-sql.mjs');
  const sql = precheckSql('production');
  assert.match(sql, /to_regclass\('app\.platform_environment'\)/);
  assert.match(sql, /<> 'production'/);
  assert.throws(() => precheckSql('local'), /unknown environment/);
});

test('drift check skips (exit 0) when no access token is configured', async () => {
  const { spawnSync } = await import('node:child_process');
  const { fileURLToPath } = await import('node:url');
  const script = fileURLToPath(new URL('./check-migration-drift.mjs', import.meta.url));
  const env = { ...process.env };
  delete env.SUPABASE_ACCESS_TOKEN;
  delete env.GITHUB_ACTIONS;
  const r = spawnSync(process.execPath, [script, '--env', 'staging'], { env, encoding: 'utf8' });
  assert.equal(r.status, 0);
  assert.match(r.stdout, /skipped: SUPABASE_ACCESS_TOKEN is not set/);
});

test('system credentials are secrets in every mode; their digest and prefix are not', () => {
  const token = `sysc_staging_${'Ab3-_'.repeat(8)}xyz`;
  assert.equal(token.length, 'sysc_staging_'.length + 43);
  assert.equal(findSecrets(`x=${token}`)[0].rule, 'system_credential');
  assert.equal(findSecrets(`"${token}"`, { mode: 'bundle' })[0].rule, 'system_credential');
  assert.ok(!JSON.stringify(findSecrets(token)).includes(token.slice(12)), 'findings never echo the value');
  assert.deepEqual(findSecrets(`sysc_local_short sysc_<env>_<43> ${'a'.repeat(64)}`), []);
});
