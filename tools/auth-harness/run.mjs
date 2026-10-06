#!/usr/bin/env node
// Story 1.2 Auth provider harness CLI. See README.md.
//
// Environment:
//   SUPABASE_URL                 isolated auth-test project URL (required)
//   SUPABASE_PUBLISHABLE_KEY     publishable/anon key only (required)
//   HARNESS_EVIDENCE             evidence JSONL path (default: evidence-1.2/harness-log.jsonl)
//   HARNESS_STATE_DIR            private state dir printed by `init` (required for every
//                                command except init/attach/note)
//   HARNESS_TARGET               `local` = the local Supabase CLI stack (http://127.0.0.1:54321)
//                                only; default/anything else = the hosted auth-test project.
//                                Local runs label every evidence line `harness_target: "LOCAL"`
//                                and default to evidence-1.2/local-harness-log.jsonl.
//   SUPABASE_ANON_JWT            story 1.3 `rc-*` only: the project's legacy anon key (a
//                                publishable-class JWT; the Edge Function gateway needs a JWT)
//
// Usage: node run.mjs <command> [args] [--step <name>]
// Email links are read from stdin (never argv): `verify-link <label> < link.txt`.

import {
  appendFileSync,
  closeSync,
  constants as FS,
  fchmodSync,
  fstatSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  writeSync,
} from 'node:fs';
import { randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  AuthClient,
  assertAllowedOrigin,
  harnessTarget,
  maskIdentifier,
  parseRedirectLocation,
  parseVerifyLink,
  scrub,
  summarizeJwt,
  summarizeSession,
  summarizeUser,
} from './lib.mjs';
import { rcCommand } from './recovery-cli.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const TARGET = harnessTarget();
const EVIDENCE =
  process.env.HARNESS_EVIDENCE ||
  resolve(
    HERE,
    '../../_bmad-output/initiative-church-app/epic-platform-baseline/evidence-1.2/' +
      (TARGET === 'local' ? 'local-harness-log.jsonl' : 'harness-log.jsonl'),
  );
const STATE_PREFIX = 'bic-auth-harness-';
const STATE_FILE = 'state.json';

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

// State (live tokens + generated passwords) lives in a private mkdtemp dir
// (0700, owned by us, not a symlink). Files are opened with O_NOFOLLOW and
// written via an O_EXCL temp file + rename, so a planted symlink or a
// pre-existing file cannot redirect or widen them.
function stateDir() {
  const dir = process.env.HARNESS_STATE_DIR;
  if (!dir) throw new Error('HARNESS_STATE_DIR is not set: run `init` and export the printed dir');
  const st = lstatSync(dir);
  if (!st.isDirectory() || st.isSymbolicLink()) throw new Error('HARNESS_STATE_DIR is not a real directory');
  if (!basename(dir).startsWith(STATE_PREFIX)) throw new Error('HARNESS_STATE_DIR was not created by `init`');
  if ((st.mode & 0o077) !== 0) throw new Error('HARNESS_STATE_DIR must be mode 0700');
  if (typeof process.getuid === 'function' && st.uid !== process.getuid()) {
    throw new Error('HARNESS_STATE_DIR is not owned by the current user');
  }
  return dir;
}

function loadState() {
  const file = join(stateDir(), STATE_FILE);
  let fd;
  try {
    fd = openSync(file, FS.O_RDONLY | FS.O_NOFOLLOW);
  } catch (e) {
    if (e.code === 'ENOENT') return { sessions: {}, passwords: {} };
    throw e;
  }
  try {
    const st = fstatSync(fd);
    if (!st.isFile() || (st.mode & 0o077) !== 0) throw new Error('state file must be a private regular file');
    return JSON.parse(readFileSync(fd, 'utf8'));
  } finally {
    closeSync(fd);
  }
}

function saveState(s) {
  const dir = stateDir();
  const tmp = join(dir, `.${STATE_FILE}.${randomBytes(6).toString('hex')}`);
  const fd = openSync(tmp, FS.O_WRONLY | FS.O_CREAT | FS.O_EXCL | FS.O_NOFOLLOW, 0o600);
  try {
    fchmodSync(fd, 0o600);
    writeSync(fd, JSON.stringify(s));
  } finally {
    closeSync(fd);
  }
  renameSync(tmp, join(dir, STATE_FILE));
}

function readStdin() {
  try {
    return readFileSync(0, 'utf8').trim();
  } catch {
    return '';
  }
}

function record(step, command, data) {
  const entry = scrub({
    ts: new Date().toISOString(),
    step: step || command,
    command,
    ...(TARGET === 'local' ? { harness_target: 'LOCAL' } : {}),
    ...data,
  });
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
  const step = opt.step;

  // Offline commands: no network, no credentials.
  switch (command) {
    case 'init': {
      const dir = mkdtempSync(join(tmpdir(), STATE_PREFIX));
      // mkdtemp creates 0700; assert rather than trust umask.
      if ((lstatSync(dir).mode & 0o077) !== 0) throw new Error('mkdtemp dir is not private');
      console.log(`export HARNESS_STATE_DIR=${dir}`);
      return;
    }
    case 'cleanup': {
      // Removes live tokens and generated passwords. Run at the end of every session.
      const dir = stateDir();
      rmSync(dir, { recursive: true, force: true });
      console.log(JSON.stringify({ removed_state_dir: true }));
      return;
    }
    case 'attach': {
      // Attach raw output of a committed read-only query (MCP execute_sql/query_logs)
      // as evidence. stdin = the raw JSON result. --source = committed query file.
      if (!opt.source) throw new Error('--source <committed query file> required');
      const src = resolve(HERE, String(opt.source));
      if (!src.startsWith(resolve(HERE, 'sql') + '/')) throw new Error('--source must be a file under tools/auth-harness/sql/');
      readFileSync(src); // must exist
      const raw = readStdin();
      let parsed;
      try {
        parsed = JSON.parse(raw);
      } catch {
        throw new Error('stdin must be the raw JSON query result');
      }
      record(step, command, {
        source: `tools/auth-harness/${String(opt.source).replace(/^\.\//, '')}`,
        via: opt.via || 'supabase-mcp',
        window: opt.window || undefined,
        raw_result: parsed,
      });
      return;
    }
    case 'note':
      // Operator commentary only. Notes are NOT observations; evidence claims must cite
      // harness calls or `attach` lines.
      record(step, command, { operator_note: pos.join(' ') });
      return;
    default:
      break;
  }

  const client = new AuthClient({
    url: process.env.SUPABASE_URL,
    apikey: process.env.SUPABASE_PUBLISHABLE_KEY,
  });
  const state = loadState();

  if (command.startsWith('rc-')) {
    await rcCommand(command, { pos, opt, step, client, state, saveState, record });
    return;
  }

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
      // create_user defaults to false: for a phone that has no user, Auth answers
      // `otp_disabled` ("Signups not allowed for otp") before any provider logic.
      // To exercise the no-SMS path, target an EXISTING phone user.
      const createUser = Boolean(opt['create-user']);
      const body = { ...id, create_user: createUser };
      if (opt.redirect) body.email_redirect_to = opt.redirect;
      const r = await client.otp(body);
      record(step, command, {
        request: { ...maskedId(id), create_user: createUser },
        status: r.status,
        response: r.json,
      });
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
      // The one-use link is read from stdin so it never appears in argv or shell history.
      const [label, extra] = pos;
      if (extra) throw new Error('pass the link on stdin, not as an argument');
      const p = parseVerifyLink(readStdin());
      assertAllowedOrigin(p.origin, 'verify link');
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
      console.log(JSON.stringify({ accounts: Object.keys(state.passwords), sessions: out }, null, 2));
      break;
    }

    default:
      console.error(
        'commands: init | cleanup | info | signup <account> --phone|--email | login <label> --account <a> --phone|--email [--wrong] | ' +
          'otp --phone|--email [--create-user] | recover --email [--redirect] | verify-link <label> (link on stdin) | ' +
          'verify-otp <label> --phone [--type --token] | probe <label> | refresh <label> [--as <label>] | ' +
          'set-email <label> --email [--redirect] | set-password <label> --account <a> | logout <label> [--scope] | ' +
          'sessions | attach --source sql/<file> (raw JSON on stdin) | note <text> | ' +
          'rc-operator-token | rc-version | rc-provision <a> --tag --role member|none | rc-request <g> --account <a> | ' +
          'rc-issue <g> --staff <s> --account <a> ' +
          '[--member-of <a2>] [--ttl] | rc-redeem <g> --account <a> [--login-as <a2>] [--inject] [--parallel n] [--weak] [--op <o>] | ' +
          'rc-resume <g> --op <o> --account <a> | rc-relink --staff <s> --account <a> | rc-hold --staff <s> --account <a> [--off] | ' +
          'rc-reconcile [--force]|rc-replay|rc-expire --staff <s> --op <o> | rc-delete-user --staff <s> --account <a> | ' +
          'rc-mfa-enroll <session> | rc-observe --staff <s> [--prefix] | rc-probe <session> | ' +
          'rc-call --action <x> [--as anon|none|forged-own|forged-foreign|session:<l>] [--no-operator] [--body]',
      );
      process.exitCode = 2;
  }
}

main().catch((e) => {
  console.error('harness error:', scrub(String(e?.message || e)));
  process.exitCode = 1;
});

