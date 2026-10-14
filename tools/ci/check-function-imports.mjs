#!/usr/bin/env node
// Edge Function deploy boundary (review 3.8-3.10, finding 1). A Supabase Edge Function is
// deployed from `supabase/functions/`: the CLI bundles a function's folder plus the relative
// files it imports, and the MCP `deploy_edge_function` uploads exactly the files it is given
// (named relative to the entrypoint, so shared code is `../_shared/<file>`). A relative import
// that leaves `supabase/functions/` (for example `../../../packages/...`) is therefore never
// deployed and the function fails with module-not-found on its next redeploy.
//
//   node tools/ci/check-function-imports.mjs [--dir supabase/functions]
//
// Rules, for every .ts/.tsx/.js/.mjs file under the directory:
//  1. A relative or absolute file import (`./`, `../`, `/`, `file:`) must resolve inside the
//     directory, and the target file must exist.
//  2. Bare and remote specifiers (`node:`, `npm:`, `jsr:`, `https:`) are not checked here.
// Shared code lives in `supabase/functions/_shared/` (the documented Supabase convention).

import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const SOURCE_RE = /\.(ts|tsx|js|mjs)$/;
// Static `import ... from 'x'`, `export ... from 'x'`, side-effect `import 'x'`, dynamic `import('x')`.
const SPECIFIER_RES = [
  /\b(?:import|export)\b[^'"`;]*?\bfrom\s*(['"])([^'"]+)\1/g,
  /\bimport\s*(['"])([^'"]+)\1/g,
  /\bimport\s*\(\s*(['"])([^'"]+)\1\s*\)/g,
];

/** Every import specifier in a source text, with its 1-based line. */
export function importSpecifiers(source) {
  const found = [];
  const seen = new Set();
  for (const re of SPECIFIER_RES) {
    re.lastIndex = 0;
    for (let m = re.exec(source); m; m = re.exec(source)) {
      const at = m.index + m[0].lastIndexOf(m[2]);
      if (seen.has(at)) continue;
      seen.add(at);
      found.push({ specifier: m[2], line: source.slice(0, at).split('\n').length });
    }
  }
  return found.sort((a, b) => a.line - b.line);
}

function isFileSpecifier(specifier) {
  return specifier.startsWith('./') || specifier.startsWith('../') || specifier.startsWith('/')
    || specifier.startsWith('file:');
}

function sourceFiles(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    if (entry === 'node_modules') continue;
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) out.push(...sourceFiles(path));
    else if (SOURCE_RE.test(entry)) out.push(path);
  }
  return out.sort();
}

/** Violations for every function source under `dir` (absolute path). */
export function checkFunctionImports(dir) {
  const base = resolve(dir);
  const problems = [];
  for (const file of sourceFiles(base)) {
    const rel = relative(ROOT, file) || file;
    for (const { specifier, line } of importSpecifiers(readFileSync(file, 'utf8'))) {
      if (!isFileSpecifier(specifier)) continue;
      const target = specifier.startsWith('file:') ? fileURLToPath(specifier)
        : resolve(dirname(file), specifier);
      if (target !== base && !target.startsWith(base + sep)) {
        problems.push(`${rel}:${line}: import '${specifier}' leaves ${relative(ROOT, base) || base}/ `
          + '(move shared code to supabase/functions/_shared/)');
      } else if (!existsSync(target)) {
        problems.push(`${rel}:${line}: import '${specifier}' does not exist`);
      }
    }
  }
  return problems;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  let dir = join(ROOT, 'supabase/functions');
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === '--dir' && args[i + 1]) { dir = resolve(args[i + 1]); i += 1; }
    else { console.error(`unknown argument: ${args[i]}`); process.exit(2); }
  }
  if (!existsSync(dir)) { console.error(`no such directory: ${dir}`); process.exit(2); }
  const problems = checkFunctionImports(dir);
  if (problems.length) {
    for (const p of problems) console.error(p);
    console.error(`function imports: ${problems.length} problem(s)`);
    process.exit(1);
  }
  console.log('function imports: every relative import stays inside supabase/functions/');
}
