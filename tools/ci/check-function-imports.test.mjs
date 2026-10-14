import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { checkFunctionImports, importSpecifiers } from './check-function-imports.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

function tree(files) {
  const root = mkdtempSync(join(tmpdir(), 'fn-imports-'));
  for (const [path, body] of Object.entries(files)) {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), body);
  }
  return root;
}

test('import specifiers: static, re-export, side-effect and dynamic forms with lines', () => {
  const src = "import { a } from './a.mjs';\nexport { b } from \"../_shared/b.mjs\";\nimport './c.mjs';\n"
    + "const d = await import('../../outside.mjs');\nimport x from 'node:fs';\n";
  assert.deepEqual(importSpecifiers(src).map((s) => [s.specifier, s.line]),
    [['./a.mjs', 1], ['../_shared/b.mjs', 2], ['./c.mjs', 3], ['../../outside.mjs', 4], ['node:fs', 5]]);
});

test('imports inside supabase/functions (own folder and _shared) pass', () => {
  const root = tree({
    'functions/_shared/x.mjs': 'export const x = 1;\n',
    'functions/fn/index.ts': "import { y } from './logic.mjs';\nimport 'jsr:@supabase/functions-js';\n",
    'functions/fn/logic.mjs': "import { x } from '../_shared/x.mjs';\nexport const y = x;\n",
  });
  try {
    assert.deepEqual(checkFunctionImports(join(root, 'functions')), []);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('an import that escapes supabase/functions or is missing fails with file and line', () => {
  const root = tree({
    'packages/shared/x.mjs': 'export const x = 1;\n',
    'functions/fn/logic.mjs': "// header\nimport { x } from '../../packages/shared/x.mjs';\nimport { z } from './gone.mjs';\n",
  });
  try {
    const problems = checkFunctionImports(join(root, 'functions'));
    assert.equal(problems.length, 2);
    assert.match(problems[0], /logic\.mjs:2: import '\.\.\/\.\.\/packages\/shared\/x\.mjs' leaves/);
    assert.match(problems[1], /logic\.mjs:3: import '\.\/gone\.mjs' does not exist/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('the repository functions stay inside their deploy boundary (CLI exit 0)', () => {
  assert.deepEqual(checkFunctionImports(join(ROOT, 'supabase/functions')), []);
  const out = execFileSync(process.execPath, [join(ROOT, 'tools/ci/check-function-imports.mjs')], { encoding: 'utf8' });
  assert.match(out, /stays inside supabase\/functions/);
});

test('the CLI exits 1 on an escaping import', () => {
  const root = tree({ 'outside.mjs': '', 'functions/fn/index.ts': "import '../../outside.mjs';\n" });
  try {
    assert.throws(() => execFileSync(process.execPath,
      [join(ROOT, 'tools/ci/check-function-imports.mjs'), '--dir', join(root, 'functions')], { stdio: 'pipe' }),
    (e) => e.status === 1 && /leaves/.test(String(e.stderr)));
  } finally { rmSync(root, { recursive: true, force: true }); }
});
