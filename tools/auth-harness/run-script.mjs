#!/usr/bin/env node
// Runs a committed scenario file of run.mjs commands in order (story 1.3).
// One command per line; `#` starts a comment; arguments are split on spaces
// (no quoting); `@sleep <seconds>` pauses. Stops at the first command that exits non-zero, unless the
// line starts with `?` (expected to fail, e.g. a refused call).
//
// Usage: node tools/auth-harness/run-script.mjs tools/auth-harness/scenarios/<file>.txt
// Scenario files mask the owner inbox: `<inbox>` is replaced with HARNESS_INBOX_LOCAL
// (the local part of the owner-approved mailbox), which must be set when a line uses it.
// The same environment as run.mjs applies (SUPABASE_URL, keys, HARNESS_STATE_DIR, ...).

import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const file = process.argv[2];
if (!file) {
  console.error('usage: run-script.mjs <scenario file>');
  process.exit(2);
}

function expandInbox(arg) {
  if (!arg.includes('<inbox>')) return arg;
  const local = process.env.HARNESS_INBOX_LOCAL;
  if (!local || !/^[A-Za-z0-9._-]+$/.test(local)) {
    console.error('run-script: set HARNESS_INBOX_LOCAL (owner inbox local part) for <inbox> lines');
    process.exit(2);
  }
  return arg.replaceAll('<inbox>', local);
}

for (const raw of readFileSync(file, 'utf8').split('\n')) {
  const line = raw.replace(/#.*$/, '').trim();
  if (!line) continue;
  const sleep = line.match(/^@sleep\s+(\d+)$/);
  if (sleep) {
    // Used only to let a short-TTL grant expire.
    console.log(`\n@sleep ${sleep[1]}`);
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, Number(sleep[1]) * 1000);
    continue;
  }
  const tolerate = line.startsWith('?');
  const args = (tolerate ? line.slice(1) : line).trim().split(/\s+/).map(expandInbox);
  console.log(`\n$ run.mjs ${args.join(' ')}`);
  const r = spawnSync(process.execPath, [join(HERE, 'run.mjs'), ...args], { stdio: 'inherit' });
  if (r.status !== 0 && !tolerate) {
    console.error(`run-script: stopped at "${args.join(' ')}" (exit ${r.status})`);
    process.exit(r.status ?? 1);
  }
}
