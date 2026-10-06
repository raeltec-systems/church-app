#!/usr/bin/env node
// LOCAL-ONLY: switch the local Supabase CLI stack's Auth (GoTrue) phone provider on or off
// WITHOUT any SMS provider, credentials, Send SMS hook, test OTP or SMS MFA (story 2.1).
//
// Why: Supabase CLI 2.119.0 forces GOTRUE_EXTERNAL_PHONE_ENABLED=false when no SMS provider is
// enabled (evidence-1.2/local-cli-phone-gate.txt), although hosted Auth accepts the same no-SMS
// configuration through the Management API (evidence-1.2, hosted phone track). This recreates
// the CLI's own auth container with exactly two env changes, mirroring the hosted body:
//   GOTRUE_EXTERNAL_PHONE_ENABLED=true   (external_phone_enabled)
//   GOTRUE_SMS_AUTOCONFIRM=true          (sms_autoconfirm; phone confirmation off)
// It refuses to run if any SMS provider, credential, hook, test OTP or phone MFA setting is
// present, and touches only the container named supabase_auth_<project_id> on the CLI network.
// `off` restores GOTRUE_EXTERNAL_PHONE_ENABLED=false; `supabase stop && supabase start` also
// returns to the CLI's own configuration.
//
// Usage: node tools/auth-harness/local-phone-auth.mjs on|off|status
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

export function projectId(configToml) {
  const m = /^project_id\s*=\s*"([a-z0-9_-]+)"/m.exec(configToml);
  if (!m) throw new Error('project_id not found in supabase/config.toml');
  return m[1];
}

// Env entries that would mean an SMS route exists. Any non-empty value is refused.
const FORBIDDEN = [
  /^GOTRUE_SMS_PROVIDER=./,
  /^GOTRUE_SMS_(TWILIO|TWILIO_VERIFY|MESSAGEBIRD|TEXTLOCAL|VONAGE)_[A-Z_]+=./,
  /^GOTRUE_SMS_TEST_OTP=./,
  /^GOTRUE_HOOK_SEND_SMS_(ENABLED=true|URI=.)/,
  /^GOTRUE_MFA_PHONE_(ENROLL|VERIFY)_ENABLED=true/,
];

/** Returns the forbidden SMS-related entries of an env list (empty = safe). */
export function smsViolations(env) {
  return env.filter((e) => FORBIDDEN.some((re) => re.test(e)));
}

/** The env list with the phone provider set as requested and sms autoconfirm on. */
export function withPhone(env, enabled) {
  const set = {
    GOTRUE_EXTERNAL_PHONE_ENABLED: String(enabled),
    GOTRUE_SMS_AUTOCONFIRM: 'true',
  };
  const out = env.filter((e) => !Object.keys(set).some((k) => e.startsWith(`${k}=`)));
  for (const [k, v] of Object.entries(set)) out.push(`${k}=${v}`);
  return out;
}

function docker(args, opts = {}) {
  return execFileSync('docker', args, { encoding: 'utf8', ...opts });
}

function main(mode) {
  if (!['on', 'off', 'status'].includes(mode)) {
    console.error('usage: local-phone-auth.mjs on|off|status');
    process.exit(2);
  }
  const id = projectId(readFileSync(path.join(root, 'supabase/config.toml'), 'utf8'));
  const name = `supabase_auth_${id}`;
  const network = `supabase_network_${id}`;
  const [info] = JSON.parse(docker(['inspect', name]));
  if (info.Config.Labels?.['com.supabase.cli.project'] !== id || !info.NetworkSettings.Networks[network]) {
    throw new Error(`${name} is not the local Supabase CLI auth container of project ${id}`);
  }
  if (!/^public\.ecr\.aws\/supabase\/gotrue:v[0-9.]+$/.test(info.Config.Image)) {
    throw new Error(`unexpected auth image ${info.Config.Image}`);
  }
  const env = info.Config.Env;
  const phone = env.find((e) => e.startsWith('GOTRUE_EXTERNAL_PHONE_ENABLED='));
  const bad = smsViolations(env);
  if (bad.length) throw new Error(`refusing: SMS configuration present (${bad.map((e) => e.split('=')[0]).join(', ')})`);
  if (mode === 'status') {
    console.log(`${name}: ${phone ?? 'GOTRUE_EXTERNAL_PHONE_ENABLED unset'}; no SMS provider, hook, test OTP or phone MFA`);
    return;
  }
  const next = withPhone(env, mode === 'on');
  if (smsViolations(next).length) throw new Error('refusing: result would contain SMS configuration');
  const args = ['run', '-d', '--name', name, '--network', network,
    '--network-alias', 'auth', '--restart', 'unless-stopped',
    '--add-host', 'host.docker.internal:host-gateway'];
  for (const [k, v] of Object.entries(info.Config.Labels ?? {})) args.push('--label', `${k}=${v}`);
  args.push('--label', 'church-app.local-phone-auth=story-2.1');
  const hc = info.Config.Healthcheck;
  if (hc?.Test?.[0] === 'CMD-SHELL') {
    args.push('--health-cmd', hc.Test[1], '--health-interval', `${hc.Interval / 1e9}s`,
      '--health-timeout', `${hc.Timeout / 1e9}s`, '--health-retries', String(hc.Retries));
  }
  for (const e of next) args.push('-e', e);
  args.push(info.Config.Image, ...(info.Config.Cmd ?? []));
  docker(['rm', '-f', name]);
  docker(args);
  for (let i = 0; i < 60; i++) {
    const s = docker(['inspect', '-f', '{{.State.Health.Status}}', name]).trim();
    if (s === 'healthy') {
      console.log(`${name}: GOTRUE_EXTERNAL_PHONE_ENABLED=${mode === 'on'}, GOTRUE_SMS_AUTOCONFIRM=true; no SMS provider (LOCAL only)`);
      return;
    }
    execFileSync('sleep', ['1']);
  }
  throw new Error(`${name} did not become healthy`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    main(process.argv[2]);
  } catch (e) {
    console.error(`local-phone-auth: ${e.message}`);
    process.exit(1);
  }
}
