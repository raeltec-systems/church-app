#!/usr/bin/env node
// Secret scan (story 1.8). Fails when a credential lands in the repository or a client bundle.
//
//   node tools/ci/scan-secrets.mjs                     scan every git-tracked file (repo mode)
//   node tools/ci/scan-secrets.mjs --bundle <dir>...   scan built client output (bundle mode:
//                                                      any JWT, any service_role reference or a
//                                                      real sb_secret_ key fails; the bare prefix
//                                                      that supabase-dart compares against does not)
// Findings print the file, line and rule, never the value.

import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { findSecrets } from './secret-patterns.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const MAX_BYTES = 20 * 1024 * 1024;

function walk(dir) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(p));
    else if (entry.isFile()) out.push(p);
  }
  return out;
}

function readText(path) {
  const st = statSync(path);
  if (st.size > MAX_BYTES) return null;
  const buf = readFileSync(path);
  // Binary files (images, fonts, wasm) are skipped in repo mode; bundle mode scans them as latin1
  // so a key embedded in a compiled artifact is still found.
  return buf;
}

export function scanFiles(files, { mode, base }) {
  const findings = [];
  for (const file of files) {
    const buf = readText(file);
    if (buf === null) continue;
    const binary = buf.includes(0);
    if (binary && mode === 'repo') continue;
    const text = buf.toString(binary ? 'latin1' : 'utf8');
    for (const hit of findSecrets(text, { mode })) {
      findings.push({ file: relative(base, file), ...hit });
    }
  }
  return findings;
}

function main(argv) {
  let mode = 'repo';
  let files;
  let base = ROOT;
  if (argv[0] === '--bundle') {
    mode = 'bundle';
    const dirs = argv.slice(1);
    if (dirs.length === 0) throw new Error('--bundle needs at least one directory');
    files = [];
    for (const d of dirs) {
      const st = statSync(d, { throwIfNoEntry: false });
      if (!st || !st.isDirectory()) throw new Error(`bundle directory not found: ${d}`);
      files.push(...walk(resolve(d)));
    }
    base = process.cwd();
  } else {
    files = execFileSync('git', ['ls-files', '-z'], { cwd: ROOT, encoding: 'utf8' })
      .split('\0').filter(Boolean).map((f) => join(ROOT, f))
      .filter((f) => statSync(f, { throwIfNoEntry: false })?.isFile());
  }
  const findings = scanFiles(files, { mode, base });
  for (const f of findings) console.error(`scan-secrets: ${f.file}:${f.line} ${f.rule} (${f.excerpt})`);
  if (findings.length) {
    console.error(`scan-secrets: ${findings.length} finding(s) in ${mode} mode — remove the value and rotate it`);
    return 1;
  }
  console.log(`scan-secrets: clean (${mode} mode, ${files.length} files)`);
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (err) {
    console.error(`scan-secrets: ${err.message}`);
    process.exitCode = 2;
  }
}
