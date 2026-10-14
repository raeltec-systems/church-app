#!/usr/bin/env node
// Local <-> hosted migration-history drift check (story 1.8).
//
//   node tools/ci/check-migration-drift.mjs --env staging [--hosted-file list.json] [--require-synced]
//
// The hosted list comes from --hosted-file (the JSON the Supabase MCP `list_migrations` tool or
// the Management API returns) or, when SUPABASE_ACCESS_TOKEN is set, from
// GET https://api.supabase.com/v1/projects/<ref>/database/migrations.
// Without either, the check is skipped (exit 0) so CI passes before the owner adds the secret.
//
// Outcomes
//   in sync       hosted == local
//   pending       local has versions newer than every hosted version (promotion will apply them)
//   DRIFT (fail)  hosted has a version local lacks, a version's name differs, or a local version
//                 missing on hosted is older than the hosted head (out-of-order apply)
// --require-synced also fails on pending (used after a promotion).

import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadEnvironments } from '../env/environments.mjs';
import { NAME_RE } from './check-migrations.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

export function localMigrations(dir = join(ROOT, 'supabase/migrations')) {
  return readdirSync(dir).filter((f) => NAME_RE.test(f)).sort().map((f) => {
    const m = /^(\d{14})_(.+)\.sql$/.exec(f);
    return { version: m[1], name: m[2] };
  });
}

/** Accepts {migrations:[...]}, [...], or the MCP envelope; returns [{version, name}]. */
export function parseHosted(json) {
  const list = Array.isArray(json) ? json : json?.migrations ?? json?.result ?? null;
  if (!Array.isArray(list)) throw new Error('hosted migration list is not an array');
  return list.map((m) => ({ version: String(m.version), name: m.name ?? null })).sort((a, b) => a.version.localeCompare(b.version));
}

export function compare(local, hosted) {
  const localBy = new Map(local.map((m) => [m.version, m.name]));
  const hostedBy = new Map(hosted.map((m) => [m.version, m.name]));
  const hostedHead = hosted.at(-1)?.version ?? '';
  const drift = [];
  const pending = [];
  for (const h of hosted) {
    if (!localBy.has(h.version)) drift.push(`hosted ${h.version}_${h.name} is not in supabase/migrations (applied outside review?)`);
    else if (h.name && localBy.get(h.version) !== h.name) drift.push(`version ${h.version}: hosted name "${h.name}" != local "${localBy.get(h.version)}"`);
  }
  for (const l of local) {
    if (hostedBy.has(l.version)) continue;
    if (l.version < hostedHead) drift.push(`local ${l.version}_${l.name} is older than hosted head ${hostedHead} but not applied (out of order)`);
    else pending.push(`${l.version}_${l.name}`);
  }
  return { drift, pending, status: drift.length ? 'drift' : pending.length ? 'pending' : 'in_sync' };
}

async function fetchHosted(ref, token) {
  const res = await fetch(`https://api.supabase.com/v1/projects/${ref}/database/migrations`, {
    headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' },
  });
  if (!res.ok) throw new Error(`Management API answered HTTP ${res.status} for ${ref}`);
  return res.json();
}

async function main(argv) {
  const opt = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--require-synced') opt.requireSynced = true;
    else opt[argv[i].replace(/^--/, '')] = argv[++i];
  }
  const envName = opt.env ?? 'staging';
  const env = loadEnvironments()[envName];
  const ref = opt['project-ref'] ?? env?.supabase?.project_ref;
  let hostedJson;
  if (opt['hosted-file']) hostedJson = JSON.parse(readFileSync(opt['hosted-file'], 'utf8'));
  else if (process.env.SUPABASE_ACCESS_TOKEN && ref) hostedJson = await fetchHosted(ref, process.env.SUPABASE_ACCESS_TOKEN);
  else {
    const msg = `drift check for ${envName} skipped: ${ref ? 'SUPABASE_ACCESS_TOKEN is not set' : 'no project ref'} (owner step in docs/runbooks/environments-and-promotion.md)`;
    console.log(process.env.GITHUB_ACTIONS ? `::notice title=Migration drift::${msg}` : `check-migration-drift: ${msg}`);
    return 0;
  }
  const result = compare(localMigrations(), parseHosted(hostedJson));
  for (const d of result.drift) console.error(`check-migration-drift: DRIFT ${envName} (${ref}): ${d}`);
  for (const p of result.pending) console.log(`check-migration-drift: pending for ${envName}: ${p}`);
  console.log(`check-migration-drift: ${envName} (${ref}) ${result.status}`);
  if (result.drift.length) return 1;
  if (opt.requireSynced && result.pending.length) return 1;
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).then((c) => { process.exitCode = c; }, (err) => {
    console.error(`check-migration-drift: ${err.message}`);
    process.exitCode = 2;
  });
}
