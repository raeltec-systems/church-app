#!/usr/bin/env node
// Reduce a Supabase MCP get_edge_function result (JSON on stdin) to a
// fingerprint: version, verify_jwt, ezbr hash, and the sha256 of each
// deployed source file compared with the committed file in
// functions/harness-recovery/. File contents are not printed.
// Usage: node edge-function-fingerprint.mjs < get_edge_function.json
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const sha = (t) => createHash('sha256').update(t).digest('hex');
const fn = JSON.parse(readFileSync(0, 'utf8'));
const files = {};
for (const f of fn.files ?? []) {
  const committed = sha(readFileSync(join(HERE, 'functions', 'harness-recovery', f.name), 'utf8'));
  const deployed = sha(f.content);
  files[f.name] = { deployed_sha256: deployed, committed_sha256: committed, match: deployed === committed };
}
console.log(JSON.stringify({
  slug: fn.slug,
  version: fn.version,
  status: fn.status,
  verify_jwt: fn.verify_jwt,
  ezbr_sha256: fn.ezbr_sha256,
  files,
  all_files_match_committed: Object.values(files).length > 0 && Object.values(files).every((x) => x.match),
}));
