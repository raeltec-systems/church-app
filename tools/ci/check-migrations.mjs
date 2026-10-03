#!/usr/bin/env node
// Migration promotion policy (story 1.8, AD-17: expand/contract, forward repair, no destructive
// rollback). Run from CI against the branch's base revision.
//
//   node tools/ci/check-migrations.mjs [--base <git-ref>] [--dir supabase/migrations]
//
// Rules
//  1. Every file is named <14-digit version>_<snake_name>.sql and versions are unique.
//  2. With --base: a migration that exists at the base is immutable (no edit, rename or delete),
//     and every new migration's version is later than every base version (promotion stays
//     version-ordered, so hosted projects apply it after what they already have).
//  3. New migrations (all migrations without --base) are non-destructive: DROP / TRUNCATE
//     outside comments and string literals ('…', E'…', non-body $tag$…$tag$) fail, unless the
//     file carries an explicit `-- owner-approved-cleanup: <decision reference>` line. Function
//     and DO bodies (dollar quotes after AS / DO) are scanned as code. Allowed relaxations:
//     ALTER ... DROP NOT NULL, DROP DEFAULT, ON COMMIT DROP, and DROP IDENTITY / DROP
//     EXPRESSION only in their `IF EXISTS` form (the bare forms still fail).

import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
export const NAME_RE = /^(\d{14})_[a-z0-9_]+\.sql$/;
export const CLEANUP_MARKER_RE = /^--[ \t]*owner-approved-cleanup:[ \t]*\S[^\n]*$/m;
const DOLLAR_TAG_RE = /^\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$/;

/** Blanks comments and quoted literals/identifiers, keeping newlines so lines still match. */
export function stripSql(sql) {
  let out = '';
  let i = 0;
  const blank = (s) => s.replace(/[^\n]/g, ' ');
  while (i < sql.length) {
    const c = sql[i];
    const n = sql[i + 1];
    if (c === '-' && n === '-') {
      const end = sql.indexOf('\n', i);
      const stop = end === -1 ? sql.length : end;
      out += blank(sql.slice(i, stop));
      i = stop;
    } else if (c === '/' && n === '*') {
      let depth = 1;
      let j = i + 2;
      while (j < sql.length && depth > 0) {
        if (sql[j] === '/' && sql[j + 1] === '*') { depth++; j += 2; } else if (sql[j] === '*' && sql[j + 1] === '/') { depth--; j += 2; } else j++;
      }
      out += blank(sql.slice(i, j));
      i = j;
    } else if (c === '$' && DOLLAR_TAG_RE.test(sql.slice(i, i + 65))) {
      // Dollar quote: $$…$$ or $tag$…$tag$. A function or DO body (after AS / DO) is code and is
      // scanned recursively; any other dollar-quoted string is a literal and is blanked.
      const tag = DOLLAR_TAG_RE.exec(sql.slice(i, i + 65))[0];
      const close = sql.indexOf(tag, i + tag.length);
      const stop = close === -1 ? sql.length : close + tag.length;
      const body = sql.slice(i + tag.length, close === -1 ? sql.length : close);
      const isCode = /\b(as|do)\s*$/i.test(stripSql(sql.slice(Math.max(0, i - 200), i)));
      out += blank(tag) + (isCode ? stripSql(body) : blank(body)) + (close === -1 ? '' : blank(tag));
      i = stop;
    } else if (c === "'" || c === '"') {
      // E'…' strings also allow backslash escapes (E'it\'s').
      const escapes = c === "'" && /[eE]/.test(sql[i - 1] ?? '') && !/[A-Za-z0-9_$]/.test(sql[i - 2] ?? '');
      let j = i + 1;
      while (j < sql.length) {
        if (escapes && sql[j] === '\\') j += 2;
        else if (sql[j] === c && sql[j + 1] === c) j += 2;
        else if (sql[j] === c) { j++; break; } else j++;
      }
      out += blank(sql.slice(i, j));
      i = j;
    } else {
      out += c;
      i++;
    }
  }
  return out;
}

/** Returns [{line, statement}] for destructive keywords in executable SQL. */
export function findDestructive(sql) {
  const code = stripSql(sql)
    .replace(/\bdrop\s+(not\s+null|default|identity\s+if\s+exists|expression\s+if\s+exists)\b/gi, (m) => m.replace(/drop/i, '____'))
    .replace(/\bon\s+commit\s+drop\b/gi, (m) => m.replace(/drop/i, '____'));
  const hits = [];
  code.split('\n').forEach((line, idx) => {
    for (const m of line.matchAll(/\b(drop|truncate)\b/gi)) {
      hits.push({ line: idx + 1, statement: `${m[1].toUpperCase()} …${line.trim().slice(0, 80)}` });
    }
  });
  return hits;
}

function git(args) {
  return execFileSync('git', args, { cwd: ROOT, encoding: 'utf8' });
}

/**
 * Pure policy evaluation. `files` = {name: content} at HEAD; `baseNames` = names at base or null;
 * `changed` = [{status, path}] from `git diff --name-status base` limited to the directory.
 */
export function evaluate({ files, baseNames = null, changed = [] }) {
  const errors = [];
  const notes = [];
  const versions = new Map();
  for (const name of Object.keys(files).sort()) {
    const m = NAME_RE.exec(name);
    if (!m) { errors.push(`${name}: name must be <YYYYMMDDHHMMSS>_<snake_case>.sql`); continue; }
    if (versions.has(m[1])) errors.push(`${name}: version ${m[1]} already used by ${versions.get(m[1])}`);
    versions.set(m[1], name);
  }
  let newNames = Object.keys(files);
  if (baseNames) {
    const baseSet = new Set(baseNames);
    for (const c of changed) {
      const name = c.path.split('/').pop();
      if (c.status !== 'A' && baseSet.has(name)) {
        errors.push(`${name}: already-merged migrations are immutable (git status ${c.status}); add a new forward-repair migration instead`);
      }
      if (c.status.startsWith('R') || c.status === 'D') {
        const old = (c.oldPath ?? c.path).split('/').pop();
        if (baseSet.has(old) && old !== name) errors.push(`${old}: already-merged migrations cannot be renamed or deleted`);
      }
    }
    const baseMax = baseNames.map((n) => NAME_RE.exec(n)?.[1]).filter(Boolean).sort().pop() ?? '';
    newNames = Object.keys(files).filter((n) => !baseSet.has(n));
    for (const name of newNames) {
      const v = NAME_RE.exec(name)?.[1];
      if (v && v <= baseMax) errors.push(`${name}: version ${v} must be later than the latest merged version ${baseMax}`);
    }
    notes.push(`${newNames.length} new migration(s) since base`);
  }
  for (const name of newNames.sort()) {
    const sql = files[name];
    const hits = findDestructive(sql);
    if (hits.length === 0) continue;
    if (CLEANUP_MARKER_RE.test(sql)) {
      notes.push(`${name}: ${hits.length} destructive statement(s) allowed by its owner-approved-cleanup marker`);
      continue;
    }
    for (const h of hits) {
      errors.push(`${name}:${h.line}: destructive statement (${h.statement}); retire by revoke + rename, or add an owner-approved-cleanup marker`);
    }
  }
  return { errors, notes };
}

function main(argv) {
  const opt = { dir: 'supabase/migrations', base: null };
  for (let i = 0; i < argv.length; i += 2) opt[argv[i].replace(/^--/, '')] = argv[i + 1];
  const dir = join(ROOT, opt.dir);
  const files = {};
  for (const f of readdirSync(dir).filter((f) => f.endsWith('.sql'))) files[f] = readFileSync(join(dir, f), 'utf8');
  for (const f of readdirSync(dir).filter((f) => !f.endsWith('.sql'))) files[f] = '';
  let baseNames = null;
  let changed = [];
  const base = opt.base && !/^0+$/.test(opt.base) ? opt.base : null;
  if (base) {
    // Empty when the base predates the directory.
    baseNames = git(['ls-tree', '--name-only', base, '--', `${opt.dir}/`])
      .split('\n').filter(Boolean).map((p) => p.split('/').pop());
    changed = git(['diff', '--name-status', '-M', base, 'HEAD', '--', opt.dir]).split('\n').filter(Boolean).map((l) => {
      const parts = l.split('\t');
      return parts.length === 3
        ? { status: parts[0], oldPath: parts[1], path: parts[2] }
        : { status: parts[0], path: parts[1] };
    });
    // Uncommitted working-tree changes count too (local runs).
    for (const l of git(['status', '--porcelain', '--', opt.dir]).split('\n').filter(Boolean)) {
      const status = l.slice(0, 2).trim() === '??' ? 'A' : l.slice(0, 2).trim()[0];
      changed.push({ status, path: l.slice(3).split(' -> ').pop() });
    }
  }
  const { errors, notes } = evaluate({ files, baseNames, changed });
  for (const n of notes) console.log(`check-migrations: ${n}`);
  for (const e of errors) console.error(`check-migrations: ${e}`);
  if (errors.length) return 1;
  console.log(`check-migrations: ${Object.keys(files).length} migration(s) ordered, unique and non-destructive${base ? ` (base ${base})` : ''}`);
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (err) {
    console.error(`check-migrations: ${err.message}`);
    process.exitCode = 2;
  }
}
