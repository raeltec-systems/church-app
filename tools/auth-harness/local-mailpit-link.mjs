#!/usr/bin/env node
// Story 1.2 LOCAL track only: print the newest Supabase Auth verify link sent to
// one synthetic address, as caught by the local stack's Mailpit (nothing leaves
// the machine). Pipe the output straight into `run.mjs verify-link <label>` so
// the one-use link never lands in argv, shell history or evidence.
//
// Usage: node local-mailpit-link.mjs <address> [--subject <substring>] [--after <iso ts>]
//        | HARNESS_TARGET=local node run.mjs verify-link <label> --step <s>
//
// Refuses anything but the local Mailpit (http://127.0.0.1:54324) and links
// other than http://127.0.0.1:54321/auth/v1/verify.

import { LOCAL_ORIGIN } from './lib.mjs';

const MAILPIT = 'http://127.0.0.1:54324';

const [address, ...rest] = process.argv.slice(2);
const opt = {};
for (let i = 0; i < rest.length; i += 2) opt[rest[i].replace(/^--/, '')] = rest[i + 1];
if (!address || !address.includes('@')) {
  console.error('usage: local-mailpit-link.mjs <address> [--subject <s>] [--after <iso>]');
  process.exit(2);
}

async function json(path) {
  const r = await fetch(MAILPIT + path);
  if (!r.ok) throw new Error(`mailpit ${path}: ${r.status}`);
  return r.json();
}

const q = encodeURIComponent(`to:"${address}"`);
const list = await json(`/api/v1/search?query=${q}&limit=50`);
const after = opt.after ? Date.parse(opt.after) : 0;
const candidates = (list.messages || [])
  .filter((m) => Date.parse(m.Created) >= after)
  .filter((m) => !opt.subject || String(m.Subject).toLowerCase().includes(String(opt.subject).toLowerCase()))
  .sort((a, b) => Date.parse(b.Created) - Date.parse(a.Created));
if (!candidates.length) {
  console.error('no matching message');
  process.exit(1);
}
const msg = await json(`/api/v1/message/${candidates[0].ID}`);
const text = `${msg.Text || ''}\n${(msg.HTML || '').replace(/&amp;/g, '&')}`;
const prefix = `${LOCAL_ORIGIN}/auth/v1/verify?`;
const link = text
  .match(/https?:\/\/[^\s"'<>)\]]+/g)
  ?.find((l) => l.startsWith(prefix));
if (!link) {
  console.error('message has no local /auth/v1/verify link');
  process.exit(1);
}
process.stdout.write(link + '\n');
