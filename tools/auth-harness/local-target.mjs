// Exact local-stack targeting for destructive test fixtures. Never choose the first DB.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

/** Deliberately narrow parser: refuse ambiguous/unsupported target configuration. */
export function parseLocalTarget(toml) {
  const sections = new Map([['', []]]);
  let section = '';
  for (const line of toml.replace(/\r\n/g, '\n').split('\n')) {
    const header = /^\[([^\]]+)\]\s*(?:#.*)?$/.exec(line);
    if (header) {
      section = header[1];
      if (sections.has(section)) throw new Error('duplicate local config section');
      sections.set(section, []);
    } else sections.get(section).push(line);
  }
  const value = (group, key, pattern) => {
    const lines = (sections.get(group) ?? []).filter((line) => new RegExp(`^${key}\\s*=`).test(line));
    if (lines.length !== 1) throw new Error(`expected one local ${group}.${key}`);
    const match = pattern.exec(lines[0]);
    if (!match) throw new Error(`unsupported local ${group}.${key}`);
    return match[1];
  };
  const project = value('', 'project_id', /^project_id\s*=\s*"([a-z0-9][a-z0-9_-]{0,62})"\s*(?:#.*)?$/);
  const port = (group) => {
    const n = Number(value(group, 'port', /^port\s*=\s*([0-9]+)\s*(?:#.*)?$/));
    if (!Number.isSafeInteger(n) || n < 1024 || n > 65535) throw new Error('invalid local port');
    return n;
  };
  const apiPort = port('api');
  const dbPort = port('db');
  if (apiPort === dbPort) throw new Error('local API and database ports overlap');
  return { project, apiPort, dbPort, origin: `http://127.0.0.1:${apiPort}`, network: `supabase_network_${project}` };
}
export const localTarget = () => parseLocalTarget(readFileSync(join(ROOT, 'supabase/config.toml'), 'utf8'));

export function assertLocalEndpoint(url, target = localTarget()) {
  // Validate the expected value too; callers cannot use this to allow a hosted URL.
  if (target.origin !== `http://127.0.0.1:${target.apiPort}` || !Number.isInteger(target.apiPort)
      || target.apiPort < 1024 || target.apiPort > 65535 || url !== target.origin) {
    throw new Error('refusing mismatched or non-local API target');
  }
  return url;
}
export function assertLocalDocker(endpoint) {
  if (!/^(?:npipe|unix):\/\//.test(endpoint ?? '')) throw new Error('refusing non-local Docker daemon');
}
const docker = (args) => execFileSync('docker', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
function checkDaemon() {
  if (process.env.DOCKER_HOST) assertLocalDocker(process.env.DOCKER_HOST);
  assertLocalDocker(docker(['context', 'inspect', '--format', '{{.Endpoints.docker.Host}}']).trim());
}
export function assertContainer(info, target, kind) {
  if (!['db', 'kong', 'edge_runtime'].includes(kind)) throw new Error('unsupported local service');
  const name = `supabase_${kind}_${target.project}`;
  if (info?.Name !== `/${name}` || info.Config?.Labels?.['com.supabase.cli.project'] !== target.project
      || !info.NetworkSettings?.Networks?.[target.network] || info.State?.Running !== true
      || !/^[a-f0-9]{64}$/.test(info.Id ?? '')) throw new Error(`refusing unexpected local ${kind} container`);
  const internalPort = kind === 'db' ? '5432/tcp' : kind === 'kong' ? '8000/tcp' : null;
  const expectedPort = kind === 'db' ? target.dbPort : target.apiPort;
  if (internalPort && !(info.NetworkSettings.Ports?.[internalPort] ?? []).some((p) => p.HostPort === String(expectedPort))) {
    throw new Error(`refusing mismatched local ${kind} port`);
  }
  return info.Id;
}
const verified = new Map();
/** Return an immutable container ID, not a name that could be replaced during the run. */
export function localContainer(kind, target = localTarget()) {
  const cacheKey = JSON.stringify([target, kind]);
  if (verified.has(cacheKey)) return verified.get(cacheKey);
  checkDaemon();
  const data = JSON.parse(docker(['inspect', `supabase_${kind}_${target.project}`]));
  if (data.length !== 1) throw new Error('expected exactly one local container');
  const id = assertContainer(data[0], target, kind);
  verified.set(cacheKey, id);
  return id;
}
export function localStatus() {
  const target = localTarget();
  localContainer('db', target);
  localContainer('kong', target);
  const output = execFileSync(process.execPath, [join(ROOT, 'node_modules/supabase/dist/supabase.js'), 'status', '-o', 'env'],
    { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  const env = Object.fromEntries(output.split(/\r?\n/).flatMap((line) => {
    const match = /^([A-Z_]+)="([^"]*)"$/.exec(line);
    return match ? [[match[1], match[2]]] : [];
  }));
  assertLocalEndpoint(env.API_URL, target);
  return env; // Keys stay in process memory, never in diagnostics/evidence.
}
export function removeLocalEdgeRuntime() {
  // Invoked only by a runner that started its own serving process.
  const id = localContainer('edge_runtime');
  docker(['rm', '-f', id]);
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv[2] !== 'db') throw new Error('usage: local-target.mjs db');
    console.log(localContainer('db'));
  } catch { console.error('local-target: exact local stack could not be verified'); process.exitCode = 1; }
}
