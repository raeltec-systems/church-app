#!/usr/bin/env node
// Story 1.2 LOCAL track only. Reads local GoTrue container log lines (JSON per
// line) on stdin and prints one JSON summary on stdout: request groups by
// path/method/status/error_code, and every line that mentions an SMS provider
// or SMS sending, reduced to its level, msg and error fields. Nothing else of a
// log line is kept, so tokens and identifiers never reach evidence (and the
// output still passes through run.mjs scrub() on `attach`).
// See sql/local/observe_local_auth_logs.txt for the exact command.

import { readFileSync } from 'node:fs';

const SMS_RE = /\b(sms|twilio|messagebird|textlocal|vonage)\b/i;
const groups = new Map();
const smsLines = [];
let lines = 0;
for (const raw of readFileSync(0, 'utf8').split('\n')) {
  if (!raw.trim()) continue;
  lines++;
  let j;
  try {
    j = JSON.parse(raw);
  } catch {
    j = { msg: raw.slice(0, 200) };
  }
  if (j.path) {
    const k = [j.path, j.method ?? null, j.status ?? null, j.error_code ?? null];
    const key = JSON.stringify(k);
    groups.set(key, (groups.get(key) || 0) + 1);
  }
  if (SMS_RE.test(raw)) {
    smsLines.push({
      level: j.level ?? null,
      path: j.path ?? null,
      status: j.status ?? null,
      error_code: j.error_code ?? null,
      msg: j.msg ?? null,
      error: j.error ?? null,
    });
  }
}
const requests = [...groups.entries()]
  .map(([k, n]) => {
    const [path, method, status, error_code] = JSON.parse(k);
    return { path, method, status, error_code, n };
  })
  .sort((a, b) => String(a.path).localeCompare(String(b.path)) || (a.status ?? 0) - (b.status ?? 0));
process.stdout.write(
  JSON.stringify({ log_lines: lines, requests, sms_mentions: smsLines.length, sms_lines: smsLines }) + '\n',
);
