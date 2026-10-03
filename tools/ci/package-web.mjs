#!/usr/bin/env node
// Immutable client build artifacts (story 1.8).
//
//   node tools/ci/package-web.mjs seal   <build_dir> --env <name> --commit <sha> --api-url <url>
//   node tools/ci/package-web.mjs verify <build_dir> [--env <name>] [--commit <sha>]
//
// `seal` writes <build_dir>/../<basename>.SHA256SUMS and <basename>.manifest.json next to the
// build directory (not inside it, so the hashes cover exactly the served files). `verify` fails
// if any file was added, removed or changed after sealing, or if the manifest names a different
// environment or commit than the deploy expects. Deploy jobs only ever verify, never rebuild.

import { createHash } from 'node:crypto';
import { readFileSync, readdirSync, writeFileSync, existsSync } from 'node:fs';
import { basename, dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

function walk(dir) {
  const out = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...walk(p));
    else if (e.isFile()) out.push(p);
  }
  return out;
}

export function hashTree(dir) {
  return walk(dir)
    .map((p) => ({ path: relative(dir, p).split('\\').join('/'), sha256: createHash('sha256').update(readFileSync(p)).digest('hex') }))
    .sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
}

export function sidecarPaths(dir) {
  const d = resolve(dir);
  return { sums: join(dirname(d), `${basename(d)}.SHA256SUMS`), manifest: join(dirname(d), `${basename(d)}.manifest.json`) };
}

export function seal(dir, { env, commit, apiUrl, now = new Date().toISOString() }) {
  if (!env || !commit || !apiUrl) throw new Error('seal needs --env, --commit and --api-url');
  const files = hashTree(dir);
  if (files.length === 0) throw new Error(`${dir} is empty`);
  const sums = files.map((f) => `${f.sha256}  ${f.path}`).join('\n') + '\n';
  const treeSha256 = createHash('sha256').update(sums).digest('hex');
  const manifest = {
    artifact: basename(resolve(dir)),
    environment: env,
    commit,
    supabase_api_url: apiUrl,
    file_count: files.length,
    tree_sha256: treeSha256,
    sealed_at: now,
  };
  const p = sidecarPaths(dir);
  writeFileSync(p.sums, sums);
  writeFileSync(p.manifest, JSON.stringify(manifest, null, 2) + '\n');
  return manifest;
}

export function verify(dir, { env = null, commit = null } = {}) {
  const p = sidecarPaths(dir);
  if (!existsSync(p.sums) || !existsSync(p.manifest)) throw new Error(`no seal found next to ${dir}`);
  const manifest = JSON.parse(readFileSync(p.manifest, 'utf8'));
  const expected = new Map(readFileSync(p.sums, 'utf8').split('\n').filter(Boolean).map((l) => {
    const [sha, ...rest] = l.split('  ');
    return [rest.join('  '), sha];
  }));
  const problems = [];
  const actual = hashTree(dir);
  const seen = new Set();
  for (const f of actual) {
    seen.add(f.path);
    if (!expected.has(f.path)) problems.push(`added after sealing: ${f.path}`);
    else if (expected.get(f.path) !== f.sha256) problems.push(`changed after sealing: ${f.path}`);
  }
  for (const path of expected.keys()) if (!seen.has(path)) problems.push(`missing: ${path}`);
  const treeSha256 = createHash('sha256').update(readFileSync(p.sums)).digest('hex');
  if (treeSha256 !== manifest.tree_sha256) problems.push('SHA256SUMS does not match the manifest tree hash');
  if (env && manifest.environment !== env) problems.push(`artifact was built for ${manifest.environment}, not ${env}`);
  if (commit && manifest.commit !== commit) problems.push(`artifact was built from ${manifest.commit}, not ${commit}`);
  if (problems.length) throw new Error(problems.join('; '));
  return manifest;
}

function main(argv) {
  const [cmd, dir, ...rest] = argv;
  const opt = {};
  for (let i = 0; i < rest.length; i += 2) opt[rest[i].replace(/^--/, '')] = rest[i + 1];
  if (cmd === 'seal') {
    const m = seal(dir, { env: opt.env, commit: opt.commit, apiUrl: opt['api-url'] });
    console.log(`package-web: sealed ${m.artifact} for ${m.environment} @ ${m.commit}: ${m.file_count} files, tree ${m.tree_sha256}`);
    return 0;
  }
  if (cmd === 'verify') {
    const m = verify(dir, { env: opt.env, commit: opt.commit });
    console.log(`package-web: verified ${m.artifact} for ${m.environment} @ ${m.commit}: tree ${m.tree_sha256}`);
    return 0;
  }
  console.error('usage: package-web.mjs seal|verify <build_dir> [--env e] [--commit sha] [--api-url url]');
  return 2;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (err) {
    console.error(`package-web: ${err.message}`);
    process.exitCode = 1;
  }
}
