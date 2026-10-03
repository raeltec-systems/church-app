#!/usr/bin/env node
// Hosted-environment SQL steps for the promotion workflow (story 1.8), through the Supabase
// Management API (POST /v1/projects/<ref>/database/query) so CI needs no direct database route.
// Needs SUPABASE_ACCESS_TOKEN.
//
//   node tools/ci/hosted-sql.mjs ensure-marker <env> <ref> <set_by>
//        Marks an UNMARKED database as <env> (app.platform_set_environment). An already-marked
//        database must already carry <env>; it is never re-marked.
//   node tools/ci/hosted-sql.mjs precheck <env> <ref>
//        Before any migration: a database that already carries a marker must carry <env>
//        (story 1.12 follow-up: a mis-set ref is refused before db push, not after).
//   node tools/ci/hosted-sql.mjs verify <env> <ref>
//        Runs tools/ci/verify-hosted.sql: marker == <env>, private_access/outbound_sending closed.

import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ENVS = ['staging', 'production'];

export function literal(value) {
  return `'${String(value).replace(/'/g, "''")}'`;
}

export function verifySql(env) {
  if (!ENVS.includes(env)) throw new Error(`unknown environment ${env}`);
  return readFileSync(join(HERE, 'verify-hosted.sql'), 'utf8').replace(":'expected_env'", literal(env));
}

export function ensureMarkerSql(env, setBy) {
  if (!ENVS.includes(env)) throw new Error(`unknown environment ${env}`);
  if (!setBy || !setBy.trim()) throw new Error('set_by is required');
  return `do $$
begin
  if not exists (select 1 from app.platform_environment) then
    perform app.platform_set_environment(${literal(env)}, ${literal(setBy)});
  elsif app.platform_current_environment() <> ${literal(env)} then
    raise exception 'hosted database is marked %, refusing to promote %', app.platform_current_environment(), ${literal(env)};
  end if;
end;
$$;
select app.platform_current_environment() as environment;`;
}

export function precheckSql(env) {
  if (!ENVS.includes(env)) throw new Error(`unknown environment ${env}`);
  return `do $$
begin
  if to_regclass('app.platform_environment') is not null
     and exists (select 1 from app.platform_environment)
     and app.platform_current_environment() <> ${literal(env)} then
    raise exception 'hosted database is marked %, refusing to migrate it as %', app.platform_current_environment(), ${literal(env)};
  end if;
end;
$$;`;
}

async function query(ref, sql) {
  const token = process.env.SUPABASE_ACCESS_TOKEN;
  if (!token) throw new Error('SUPABASE_ACCESS_TOKEN is not set');
  const res = await fetch(`https://api.supabase.com/v1/projects/${ref}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  const body = await res.text();
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${body.slice(0, 500)}`);
  return body;
}

async function main([cmd, env, ref, setBy]) {
  if (!/^[a-z]{20}$/.test(ref ?? '')) throw new Error('a valid project ref is required');
  if (cmd === 'ensure-marker') {
    console.log(`hosted-sql: ${env} marker -> ${await query(ref, ensureMarkerSql(env, setBy))}`);
    return 0;
  }
  if (cmd === 'precheck') {
    await query(ref, precheckSql(env));
    console.log(`hosted-sql: ${env} (${ref}) is unmarked or already marked ${env}`);
    return 0;
  }
  if (cmd === 'verify') {
    await query(ref, verifySql(env));
    console.log(`hosted-sql: ${env} (${ref}) marker confirmed; private_access and outbound_sending closed`);
    return 0;
  }
  console.error('usage: hosted-sql.mjs ensure-marker <env> <ref> <set_by> | precheck <env> <ref> | verify <env> <ref>');
  return 2;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).then((c) => { process.exitCode = c; }, (err) => {
    console.error(`hosted-sql: ${err.message}`);
    process.exitCode = 1;
  });
}
