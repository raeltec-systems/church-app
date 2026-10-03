#!/usr/bin/env node
// Story 1.2 Auth provider harness CLI. See README.md.
//
// Environment:
//   SUPABASE_URL                 isolated auth-test project URL (required)
//   SUPABASE_PUBLISHABLE_KEY     publishable/anon key only (required)
//   HARNESS_EVIDENCE             evidence JSONL path (default: evidence-1.2/harness-log.jsonl)
//   HARNESS_STATE                local token/password state (default: OS temp dir, mode 0600)
//
// Usage: node run.mjs <command> [args] [--step <name>]

import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  AuthClient,
  maskIdentifier,
  parseRedirectLocation,
  parseVerifyLink,
  scrub,
  summarizeJwt,
  summarizeSession,
  summarizeUser,
} from './lib.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ALLOWED_REF = 'szfyfezfvxyuvovnnakr';
const EVIDENCE =
  process.env.HARNESS_EVIDENCE ||
  resolve(
    HERE,
    '../../_bmad-output/initiative-church-app/epic-platform-baseline/evidence-1.2/harness-log.jsonl',
  );
const STATE = process.env.HARNESS_STATE || join(tmpdir(), 'bic-auth-harness-state.json');

function parseArgs(argv) {
  const pos = [];
  const opt = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) {
      const k = argv[i].slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) opt[k] = true;
      else opt[k] = argv[++i];
    } else pos.push(argv[i]);
  }
  return { pos, opt };
}

function loadState() {
  if (!existsSync(STATE)) return { sessions: {}, passwords: {} };
  return JSON.parse(readFileSync(STATE, 'utf8'));
}
function saveState(s) {
  writeFileSync(STATE, JSON.stringify(s), { mode: 0o600 });
}

function record(step, command, data) {
  const entry = scrub({ ts: new Date().toISOString(), step: step || command, command, ...data });
  mkdirSync(dirname(EVIDENCE), { recursive: true });
  appendFileSync(EVIDENCE, JSON.stringify(entry) + '\n');
  console.log(JSON.stringify(entry, null, 2));
}

function newPassword() {
  // Synthetic, high-entropy, never printed or written to evidence.
  return 'Hx!' + randomBytes(18).toString('base64url');
}

function identifier(opt) {
  if (opt.phone) return { phone: String(opt.phone) };
  if (opt.email) return { email: String(opt.email) };
  throw new Error('--phone or --email required');
}
function maskedId(id) {
  return id.phone ? { phone: maskIdentifier(id.phone) } : { email: maskIdentifier(id.email) };
}

function storeSession(state, label, r) {
  state.sessions[label] = {
    access_token: r.access_token,
    refresh_token: r.refresh_token,
    stored_at: new Date().toISOString(),
  };
}

function requireSession(state, label) {
  const s = state.sessions[label];
  if (!s) throw new Error(`no stored session "${label}"`);
  return s;
}

async function main() {
  const [command, ...rest] = process.argv.slice(2);
  const { pos, opt } = parseArgs(rest);
  const url = process.env.SUPABASE_URL;
  if (!url || !url.includes(ALLOWED_REF)) {
    throw new Error(`SUPABASE_URL must be the isolated auth-test project (${ALLOWED_REF})`);
  }
  const client = new AuthClient({ url, apikey: process.env.SUPABASE_PUBLISHABLE_KEY });
  const state = loadState();
  const step = opt.step;

  switch (command) {
    case 'info': {
      const health = await client.health();
      const settings = await client.settings();
      record(step, command, { health, settings });
      break;
    }

    case 'signup': {
      const [account] = pos;
      const id = identifier(opt);
      state.passwords[account] = newPassword();
      const body = { ...id, password: state.passwords[account] };
      if (opt.redirect) body.email_redirect_to = opt.redirect;
      const r = await client.signup(body);
      if (r.json?.access_token) storeSession(state, account, r.json);
      saveState(state);
      record(step, command, {
        account,
        request: maskedId(id),
        status: r.status,
        session: r.json?.access_token ? summarizeSession(r.json) : null,
        user: r.json?.access_token ? undefined : summarizeUser(r.json?.user ?? r.json),
        error: r.json?.error_code ? { error_code: r.json.error_code, msg: r.json.msg } : undefined,
      });
      break;
    }

    case 'login': {
      const [label] = pos;
      const account = opt.account || label;
      const id = identifier(opt);
      const password = opt.wrong ? newPassword() : state.passwords[account];
      if (!password) throw new Error(`no stored password for account "${account}"`);
      const r = await client.passwordGrant({ ...id, password });
      if (r.json?.access_token && !opt.wrong) storeSession(state, label, r.json);
      saveState(state);
      record(step, command, {
        label,
        account,
        wrong_password: Boolean(opt.wrong),
        request: maskedId(id),
        status: r.status,
        session: r.json?.access_token ? summarizeSession(r.json) : null,
        error: r.json?.error_code ? { error_code: r.json.error_code, msg: r.json.msg } : undefined,
      });
      break;
    }

    case 'otp': {
      const id = identifier(opt);
      const body = { ...id, create_user: false };
      if (opt.redirect) body.email_redirect_to = opt.redirect;
      const r = await client.otp(body);
      record(step, command, { request: maskedId(id), status: r.status, response: r.json });
      break;
    }

    case 'recover': {
      const id = identifier(opt);
      const body = { ...id };
      const path = opt.redirect ? `?redirect_to=${encodeURIComponent(opt.redirect)}` : '';
      const r = await client.call('/auth/v1/recover' + path, { method: 'POST', body });
      record(step, command, { request: maskedId(id), status: r.status, response: r.json });
      break;
    }

    case 'verify-link': {
      // Calls /verify exactly as the emailed link would, without following the redirect.
      const [label, link] = pos;
      const p = parseVerifyLink(link);
      if (!p.origin.includes(ALLOWED_REF)) throw new Error('link is not for the auth-test project');
      const r = await client.verifyGet(p.token, p.type, p.redirectTo);
      const loc = parseRedirectLocation(r.location);
      if (loc.kind === 'session') storeSession(state, label, loc);
      saveState(state);
      record(step, command, {
        label,
        link_type: p.type,
        link_redirect_to: p.redirectTo,
        status: r.status,
        redirect: {
          kind: loc.kind,
          origin: loc.redirect_origin,
          path: loc.redirect_path,
          fragment_type: loc.type,
          error: loc.error,
          error_code: loc.error_code,
          error_description: loc.error_description,
        },
        session: loc.kind === 'session' ? { jwt_summary: summarizeJwt(loc.access_token), has_refresh_token: Boolean(loc.refresh_token) } : null,
        body: r.status >= 400 ? r.json : undefined,
      });
      break;
    }

    case 'verify-otp': {
      // Direct POST /verify with a code (used only to show phone OTP has no bypass).
      const [label] = pos;
      const id = identifier(opt);
      const r = await client.verifyPost({ ...id, type: opt.type || 'sms', token: String(opt.token || '000000') });
      if (r.json?.access_token) storeSession(state, label, r.json);
      saveState(state);
      record(step, command, {
        label,
        request: { ...maskedId(id), type: opt.type || 'sms' },
        status: r.status,
        session: r.json?.access_token ? summarizeSession(r.json) : null,
        error: r.json?.error_code ? { error_code: r.json.error_code, msg: r.json.msg } : undefined,
      });
      break;
    }

    case 'probe': {
      const [label] = pos;
      const s = requireSession(state, label);
      const who = await client.rpc('harness_whoami', s.access_token);
      const probe = await client.rpc('harness_private_probe', s.access_token);
      const user = await client.getUser(s.access_token);
      record(step, command, {
        label,
        jwt_summary: summarizeJwt(s.access_token),
        server_view: { status: who.status, body: who.json },
        private_probe: { status: probe.status, body: probe.json },
        auth_user_endpoint: {
          status: user.status,
          user: user.status === 200 ? summarizeUser(user.json) : undefined,
          error: user.status !== 200 ? user.json : undefined,
        },
      });
      break;
    }

    case 'refresh': {
      const [label] = pos;
      const s = requireSession(state, label);
      const r = await client.refresh(s.refresh_token);
      if (r.json?.access_token) storeSession(state, opt.as || label, r.json);
      saveState(state);
      record(step, command, {
        label,
        stored_as: r.json?.access_token ? opt.as || label : null,
        status: r.status,
        session: r.json?.access_token ? summarizeSession(r.json) : null,
        error: r.json?.error_code ? { error_code: r.json.error_code, msg: r.json.msg } : undefined,
      });
      break;
    }

    case 'set-email': {
      const [label] = pos;
      const s = requireSession(state, label);
      const path = opt.redirect ? `?redirect_to=${encodeURIComponent(opt.redirect)}` : '';
      const r = await client.call('/auth/v1/user' + path, {
        method: 'PUT',
        bearer: s.access_token,
        body: { email: String(opt.email) },
      });
      record(step, command, {
        label,
        request: { email: maskIdentifier(opt.email) },
        status: r.status,
        user: r.status === 200 ? summarizeUser(r.json) : undefined,
        error: r.status !== 200 ? r.json : undefined,
      });
      break;
    }

    case 'set-password': {
      const [label] = pos;
      const account = opt.account;
      if (!account) throw new Error('--account required');
      const s = requireSession(state, label);
      const pw = newPassword();
      const r = await client.updateUser(s.access_token, { password: pw });
      if (r.status === 200) {
        // Keep the superseded password (locally only) to prove it no longer works.
        state.passwords[`${account}@previous`] = state.passwords[account];
        state.passwords[account] = pw;
      }
      saveState(state);
      record(step, command, {
        label,
        account,
        status: r.status,
        user: r.status === 200 ? summarizeUser(r.json) : undefined,
        error: r.status !== 200 ? r.json : undefined,
      });
      break;
    }

    case 'logout': {
      const [label] = pos;
      const s = requireSession(state, label);
      const r = await client.logout(s.access_token, opt.scope || 'local');
      record(step, command, { label, scope: opt.scope || 'local', status: r.status, body: r.json });
      break;
    }

    case 'sessions': {
      // Local listing (labels + digests only) for the operator.
      const out = Object.fromEntries(
        Object.entries(state.sessions).map(([k, v]) => [
          k,
          { session_id: summarizeJwt(v.access_token)?.claims.session_id, sub: summarizeJwt(v.access_token)?.claims.sub, stored_at: v.stored_at },
        ]),
      );
      console.log(JSON.stringify({ state_file: STATE, accounts: Object.keys(state.passwords), sessions: out }, null, 2));
      break;
    }

    case 'note': {
      record(step, command, { note: pos.join(' ') });
      break;
    }

    default:
      console.error(
        'commands: info | signup <account> --phone|--email | login <label> --account <a> --phone|--email [--wrong] | ' +
          'otp --phone|--email | recover --email [--redirect] | verify-link <label> <url> | verify-otp <label> --phone [--type --token] | ' +
          'probe <label> | refresh <label> [--as <label>] | set-email <label> --email [--redirect] | ' +
          'set-password <label> --account <a> | logout <label> [--scope] | sessions | note <text>',
      );
      process.exitCode = 2;
  }
}

main().catch((e) => {
  console.error('harness error:', scrub(String(e?.message || e)));
  process.exitCode = 1;
});

