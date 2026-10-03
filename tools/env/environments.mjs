#!/usr/bin/env node
// Environment separation rules (AD-17, story 1.8).
//
// config/environments/{local,staging,production}.json hold NON-SECRET configuration. This module
// validates them, guards recipients (non-production may only address synthetic recipients;
// production refuses everything while sending is disabled) and resolves deploy targets so a
// job for one environment can never be pointed at another environment's project.
//
// CLI:
//   node tools/env/environments.mjs check                         validate all configs
//   node tools/env/environments.mjs target <env> <project_ref>    refuse a mismatched target
//   node tools/env/environments.mjs get <env> <dotted.key>        print one config value
//   node tools/env/environments.mjs recipients <env> <addr>...    refuse non-synthetic recipients
// Optional env: PRODUCTION_PROJECT_REF (the production ref, when it exists) strengthens checks.

import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { findSecrets } from '../ci/secret-patterns.mjs';

export const ENVIRONMENT_NAMES = ['local', 'staging', 'production'];
export const CONFIG_DIR = resolve(dirname(fileURLToPath(import.meta.url)), '../../config/environments');

// Owner test inboxes (owner-decisions-milestone-1.md): plus-tagged only, never the bare inbox.
export const OWNER_TEST_INBOX_PATTERNS = ['israelmuyoba+*@gmail.com'];
// Reserved names that can never reach a real person (RFC 2606 / RFC 6761).
const RESERVED_DOMAIN_SUFFIXES = ['.test', '.invalid', '.example', '.localhost'];
const RESERVED_DOMAINS = ['example.com', 'example.net', 'example.org'];

const PROJECT_REF_RE = /^[a-z]{20}$/;

export function loadEnvironments(dir = CONFIG_DIR) {
  const envs = {};
  for (const file of readdirSync(dir).filter((f) => f.endsWith('.json')).sort()) {
    envs[file.replace(/\.json$/, '')] = JSON.parse(readFileSync(join(dir, file), 'utf8'));
  }
  return envs;
}

/** True when a recipient pattern can only match synthetic recipients. */
export function isSyntheticPattern(pattern) {
  if (typeof pattern !== 'string') return false;
  const p = pattern.toLowerCase();
  if (OWNER_TEST_INBOX_PATTERNS.includes(p)) return true;
  const at = p.lastIndexOf('@');
  // Domain-only patterns may wildcard whole leading labels only ("*.invalid", not "*invalid").
  if (at < 0 && p.startsWith('*') && !p.startsWith('*.')) return false;
  const domain = at >= 0 ? p.slice(at + 1) : p.replace(/^\*/, '');
  if (domain.includes('*')) return false;
  if (RESERVED_DOMAINS.includes(domain)) return true;
  return RESERVED_DOMAIN_SUFFIXES.some((s) => domain === s.slice(1) || domain.endsWith(s));
}

function globToRegExp(glob) {
  // A pattern without "@" is a domain pattern: "*.invalid" matches "anyone@host.invalid".
  if (!glob.includes('@')) glob = `*@${glob}`;
  const escaped = glob.toLowerCase().replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '[^@\\s]+');
  return new RegExp(`^${escaped}$`);
}

/** Whether `address` may receive anything from environment `env`. Fails closed. */
export function recipientAllowed(env, address) {
  if (!env || !env.recipients || typeof address !== 'string') return false;
  if (env.kind !== 'nonproduction' || env.recipients.mode !== 'synthetic_only') return false;
  const a = address.trim().toLowerCase();
  if (!/^[^@\s]+@[^@\s]+$/.test(a)) return false;
  return (env.recipients.allowed_patterns ?? [])
    .filter(isSyntheticPattern)
    .some((p) => globToRegExp(p).test(a));
}

export function assertRecipients(env, addresses) {
  const refused = addresses.filter((a) => !recipientAllowed(env, a));
  if (refused.length > 0) {
    throw new Error(`${env?.name ?? 'unknown'}: refused ${refused.length} recipient(s); `
      + (env?.kind === 'production'
        ? 'production sending is disabled until the outbound_sending gate is approved'
        : 'only synthetic test recipients are allowed outside production'));
  }
  return true;
}

function get(obj, dotted) {
  return dotted.split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj);
}

/** Returns a list of human-readable violations (empty = valid). */
export function validateEnvironments(envs, { productionRef = process.env.PRODUCTION_PROJECT_REF || null } = {}) {
  const errors = [];
  const names = Object.keys(envs).sort();
  if (names.join(',') !== [...ENVIRONMENT_NAMES].sort().join(',')) {
    errors.push(`expected exactly ${ENVIRONMENT_NAMES.join(', ')} configs, found ${names.join(', ')}`);
  }
  for (const [file, env] of Object.entries(envs)) {
    const where = `${file}.json`;
    if (env.name !== file) errors.push(`${where}: name "${env.name}" must equal the file name`);
    if (env.database_marker !== file) errors.push(`${where}: database_marker must be "${file}"`);
    const expectedKind = file === 'production' ? 'production' : 'nonproduction';
    if (env.kind !== expectedKind) errors.push(`${where}: kind must be "${expectedKind}"`);
    if (env.features?.sms !== false) errors.push(`${where}: features.sms must be false (no SMS anywhere)`);
    if (env.features?.private_access !== false) {
      errors.push(`${where}: features.private_access must stay false; the database private_access gate controls activation`);
    }
    if (env.features?.outbound_sending !== false) {
      errors.push(`${where}: features.outbound_sending must stay false; the database outbound_sending gate controls activation`);
    }
    if (!Array.isArray(env.supabase?.data_api_schemas) || env.supabase.data_api_schemas.join() !== 'api') {
      errors.push(`${where}: supabase.data_api_schemas must be exactly ["api"]`);
    }
    const ref = env.supabase?.project_ref ?? null;
    if (ref !== null && !PROJECT_REF_RE.test(ref)) errors.push(`${where}: project_ref is not a Supabase ref`);
    if (ref !== null && env.supabase.api_url !== `https://${ref}.supabase.co`) {
      errors.push(`${where}: api_url must be https://${ref}.supabase.co`);
    }
    for (const hit of findSecrets(JSON.stringify(env), { mode: 'bundle' })) {
      errors.push(`${where}: contains a secret-like value (${hit.rule}); configs hold names only`);
    }
    const dep = env.deploy ?? {};
    if (file === 'production') {
      if (env.recipients?.mode !== 'disabled' || (env.recipients?.allowed_patterns ?? []).length !== 0) {
        errors.push(`${where}: recipients must be disabled with no patterns in the baseline`);
      }
      if (dep.requires_approval !== true || dep.github_environment !== 'production') {
        errors.push(`${where}: deploy must use the approval-protected "production" GitHub environment`);
      }
    } else {
      if (env.recipients?.mode !== 'synthetic_only') errors.push(`${where}: recipients.mode must be synthetic_only`);
      for (const p of env.recipients?.allowed_patterns ?? []) {
        if (!isSyntheticPattern(p)) errors.push(`${where}: recipient pattern "${p}" can reach a real person`);
      }
      if (dep.github_environment === 'production') errors.push(`${where}: must not deploy through the production environment`);
      if (productionRef && JSON.stringify(env).includes(productionRef)) {
        errors.push(`${where}: references the production project ref`);
      }
    }
  }
  const hosted = Object.values(envs).map((e) => e.supabase?.project_ref).filter(Boolean);
  if (new Set(hosted).size !== hosted.length) errors.push('two environments share a Supabase project');
  if (productionRef && hosted.includes(productionRef) && envs.production?.supabase?.project_ref !== productionRef) {
    errors.push('the production project ref is configured for a non-production environment');
  }
  return errors;
}

/**
 * Refuses a deploy unless `projectRef` is the project of environment `name` and of no other.
 * Production's ref is not in the repo; it must come from the protected environment variable.
 */
export function resolveDeployTarget(envs, name, projectRef) {
  const env = envs[name];
  if (!env || name === 'local') throw new Error(`"${name}" is not a deployable environment`);
  if (!projectRef || !PROJECT_REF_RE.test(projectRef)) {
    throw new Error(`${name}: no valid project ref supplied (owner step: set SUPABASE_PROJECT_REF / create the project)`);
  }
  const others = Object.values(envs).filter((e) => e.name !== name).map((e) => e.supabase?.project_ref).filter(Boolean);
  if (others.includes(projectRef)) throw new Error(`${name}: ${projectRef} belongs to another environment`);
  const configured = env.supabase?.project_ref ?? null;
  if (configured !== null && configured !== projectRef) {
    throw new Error(`${name}: expected project ${configured}, got ${projectRef}`);
  }
  return {
    name,
    projectRef,
    apiUrl: env.supabase?.api_url ?? `https://${projectRef}.supabase.co`,
    githubEnvironment: env.deploy.github_environment,
    databaseMarker: env.database_marker,
  };
}

function main(argv) {
  const [cmd, ...args] = argv;
  const envs = loadEnvironments();
  if (cmd === 'check') {
    const errors = validateEnvironments(envs);
    for (const e of errors) console.error(`environments: ${e}`);
    if (errors.length) return 1;
    console.log(`environments: ${Object.keys(envs).length} configs valid (separate refs, synthetic non-production recipients, production private/sending disabled)`);
    return 0;
  }
  if (cmd === 'target') {
    const t = resolveDeployTarget(envs, args[0], args[1]);
    console.log(JSON.stringify(t));
    return 0;
  }
  if (cmd === 'get') {
    const v = get(envs[args[0]], args[1] ?? '');
    if (v === undefined || v === null) {
      console.error(`environments: ${args[0]}.${args[1]} is not set`);
      return 1;
    }
    console.log(typeof v === 'string' ? v : JSON.stringify(v));
    return 0;
  }
  if (cmd === 'recipients') {
    assertRecipients(envs[args[0]], args.slice(1));
    console.log(`environments: ${args.length - 1} recipient(s) allowed for ${args[0]}`);
    return 0;
  }
  console.error('usage: environments.mjs check | target <env> <ref> | get <env> <key> | recipients <env> <addr>...');
  return 2;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (err) {
    console.error(`environments: ${err.message}`);
    process.exitCode = 1;
  }
}
