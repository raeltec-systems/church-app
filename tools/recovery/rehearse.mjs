#!/usr/bin/env node
// Isolated database-plus-object restore rehearsal (story 1.10, AD-14, AD-17). SYNTHETIC only.
//
// Source: the running LOCAL Supabase stack (database + Storage). Restore target: a throwaway
// Postgres container (`bic-rcv-isolated`, same image as the local stack, `--network none`, no
// published port, no API in front of it) plus an isolated object directory. Hosted projects are
// never touched.
//
//   node tools/recovery/rehearse.mjs all [--evidence <dir>] [--keep]
//       seed -> backup (T1) -> revoke -> delete -> seal, then restore T1 into isolation once per
//       scenario: absent, gap, tampered, unsealed, early_seal (all must stay held) and complete
//       (must reconcile). Exit 1 on any unexpected outcome.
//   Step by step (used to mirror each journal segment to the owner's Drive folder in between):
//       seed | backup | revoke | delete | seal
//       restore <scenario>                  restore T1 into isolated database rcv_<scenario> (lands held)
//       reconcile <scenario> [--journal-dir <dir>] [--cutoff <iso>]
//                                           reconcile that restore from a journal; exit 1 with the
//                                           refusal reason when the journal is absent or incomplete
//       status <scenario>                   print the restored target's recovery status and gates
//       scenario <scenario> [--journal-dir <dir>] [--cutoff <iso>]
//                                           restore + reconcile, checked against the expected outcome
//       cleanup            remove the isolated container and the local environment marker we set
//
// State (journal segments, the backup artifact, isolated object stores) lives in the gitignored
// RECOVERY_STATE_DIR (default .recovery-state/). The journal there is long-lived: it is the
// independent record, and the local database's acknowledgements must be a prefix of it.

import { spawnSync } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import {
  copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, unlinkSync, writeFileSync,
} from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { LocalSegmentJournal, SEGMENT_RE, verifyJournal } from './journal.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const STATE_DIR = resolve(process.env.RECOVERY_STATE_DIR ?? join(ROOT, '.recovery-state'));
const JOURNAL_DIR = join(STATE_DIR, 'journal');
const RUN_FILE = join(STATE_DIR, 'run.json');
export const OPERATOR = 'israel';
export const BUCKET = 'rcv-synthetic-rehearsal';
export const ISOLATED = 'bic-rcv-isolated';
const MARKER_BY = 'recovery-rehearsal';
export const NEGATIVE_SCENARIOS = ['absent', 'gap', 'tampered', 'unsealed', 'early_seal'];

let evidenceDir = null;
const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');
const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

function log(step, data) {
  const line = { step, at: new Date().toISOString(), ...data };
  console.log(JSON.stringify(line));
  if (evidenceDir) {
    mkdirSync(evidenceDir, { recursive: true });
    writeFileSync(join(evidenceDir, 'rehearsal-log.jsonl'), `${JSON.stringify(line)}\n`, { flag: 'a' });
  }
  return line;
}

function run(cmd, args, { input, allowFail = false } = {}) {
  const r = spawnSync(cmd, args, { input, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
  if (r.status !== 0 && !allowFail) {
    throw new Error(`${cmd} ${args.slice(0, 3).join(' ')} failed (${r.status}): ${(r.stderr || '').trim().split('\n').slice(-3).join(' | ')}`);
  }
  return { ok: r.status === 0, out: (r.stdout || '').trim(), err: (r.stderr || '').trim() };
}

/** A JSON value as a dollar-quoted SQL literal; refuses values that could close the quote. */
export function jsonLiteral(value) {
  const text = JSON.stringify(value);
  if (text.includes('$j$')) throw new Error('value cannot be quoted safely');
  return `$j$${text}$j$::jsonb`;
}

export const uuidLiteral = (u) => {
  if (!/^[0-9a-f-]{36}$/.test(u)) throw new Error('not a uuid');
  return `'${u}'::uuid`;
};

// ---------------------------------------------------------------------------------------------
// Source (local stack) and isolated target access
// ---------------------------------------------------------------------------------------------
let localEnvCache = null;
function localEnv() {
  if (localEnvCache) return localEnvCache;
  const out = run('npx', ['supabase', 'status', '-o', 'env']).out;
  const env = {};
  for (const line of out.split('\n')) {
    const m = /^([A-Z_]+)="?(.*?)"?$/.exec(line.trim());
    if (m) env[m[1]] = m[2];
  }
  for (const k of ['API_URL', 'SECRET_KEY', 'SERVICE_ROLE_KEY']) if (!env[k]) throw new Error(`local stack not running (${k} missing)`);
  if (!/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(env.API_URL)) throw new Error('source must be the LOCAL stack');
  const db = run('docker', ['ps', '--filter', 'name=supabase_db_', '--format', '{{.Names}}']).out.split('\n')[0];
  if (!db) throw new Error('local database container not found');
  localEnvCache = { ...env, DB_CONTAINER: db };
  return localEnvCache;
}

function psqlIn(container, db, sql) {
  return run('docker', ['exec', '-i', container, 'psql', '-U', 'postgres', '-d', db, '-X', '-qtA', '-v', 'ON_ERROR_STOP=1'], { input: sql });
}
const srcSql = (sql) => psqlIn(localEnv().DB_CONTAINER, 'postgres', sql).out;
const isoSql = (db, sql) => psqlIn(ISOLATED, db, sql).out;
const lastJson = (out) => JSON.parse(out.split('\n').filter((l) => l.startsWith('{') || l.startsWith('[')).pop());

async function storage(method, path, body, contentType) {
  const { API_URL, SECRET_KEY, SERVICE_ROLE_KEY } = localEnv();
  const headers = { apikey: SECRET_KEY, authorization: `Bearer ${SERVICE_ROLE_KEY}` };
  if (contentType) headers['content-type'] = contentType;
  return fetch(`${API_URL}/storage/v1/${path}`, { method, headers, body });
}

function ensureIsolated() {
  const image = run('docker', ['inspect', localEnv().DB_CONTAINER, '--format', '{{.Config.Image}}']).out;
  const exists = run('docker', ['inspect', ISOLATED, '--format', '{{.State.Running}}'], { allowFail: true });
  if (exists.ok && exists.out === 'true') return image;
  if (exists.ok) run('docker', ['rm', '-f', ISOLATED]);
  run('docker', ['run', '-d', '--name', ISOLATED, '--network', 'none', '--label', 'bic.recovery=isolated-SYNTHETIC',
    '-e', `POSTGRES_PASSWORD=${randomBytes(18).toString('hex')}`, image]);
  const deadline = Date.now() + 240_000;
  while (Date.now() < deadline) {
    const logs = run('docker', ['logs', ISOLATED], { allowFail: true });
    const all = `${logs.out}\n${logs.err}`;
    if (/init process complete/i.test(all)
        && run('docker', ['exec', ISOLATED, 'pg_isready', '-U', 'postgres'], { allowFail: true }).ok
        && psqlIn(ISOLATED, 'postgres', 'select 1').out === '1') {
      sleep(1500);
      if (psqlIn(ISOLATED, 'postgres', 'select 1').out === '1') return image;
    }
    sleep(2000);
  }
  throw new Error('isolated container did not become ready');
}

function isolationFacts() {
  const [networks, ports] = run('docker', ['inspect', ISOLATED, '--format',
    '{{range $k, $v := .NetworkSettings.Networks}}{{$k}},{{end}}|{{json .HostConfig.PortBindings}}']).out.split('|');
  return { container: ISOLATED, networks: networks.split(',').filter(Boolean), published_ports: JSON.parse(ports || '{}') };
}

// ---------------------------------------------------------------------------------------------
// Run state and the live journal
// ---------------------------------------------------------------------------------------------
const loadRun = () => (existsSync(RUN_FILE) ? JSON.parse(readFileSync(RUN_FILE, 'utf8')) : {});
function saveRun(r) { mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 }); writeFileSync(RUN_FILE, JSON.stringify(r, null, 2), { mode: 0o600 }); }
const journal = () => new LocalSegmentJournal(JOURNAL_DIR);

async function preflight() {
  const entries = (await journal().list()) ?? [];
  const acks = JSON.parse(srcSql(`select coalesce(json_agg(json_build_object('seq', seq, 'hash', entry_hash) order by seq), '[]') from app.rcv_journal_acks`));
  for (const a of acks) {
    const e = entries[a.seq - 1];
    if (!e || e.seq !== a.seq || e.hash !== a.hash) {
      throw new Error(`the local database acknowledges journal seq ${a.seq} that ${JOURNAL_DIR} does not hold; reset the local database (npm run db:reset) or restore that journal`);
    }
  }
  const marker = srcSql(`select coalesce((select environment from app.platform_environment), '')`);
  if (marker && marker !== 'local') throw new Error(`local database is marked ${marker}`);
  return { marker, journal_head: entries.length };
}

async function appendAndApply(fields) {
  const entry = await journal().append(fields);
  const applied = JSON.parse(srcSql(`select app.rcv_apply_journal_entry(${jsonLiteral(entry)}, '${OPERATOR}')`));
  return { segment: `seg-${String(entry.seq).padStart(10, '0')}-${entry.kind}.json`, seq: entry.seq, kind: entry.kind, hash: entry.hash, db: applied };
}

// ---------------------------------------------------------------------------------------------
// Steps
// ---------------------------------------------------------------------------------------------
async function seed() {
  const pf = await preflight();
  const r = { run_id: randomUUID(), subject_id: randomUUID(), object_id: randomUUID(), marked_env: false };
  if (!pf.marker) {
    srcSql(`select app.platform_set_environment('local', '${MARKER_BY}')`);
    r.marked_env = true;
  }
  const bucket = await storage('POST', 'bucket', JSON.stringify({ id: BUCKET, name: BUCKET, public: false }), 'application/json');
  if (!bucket.ok && ![400, 409].includes(bucket.status)) throw new Error(`bucket create failed: HTTP ${bucket.status}`);
  const bytes = Buffer.from(`SYNTHETIC recovery rehearsal object ${r.object_id} (story 1.10; no real data)\n`);
  r.object_sha256 = sha256(bytes);
  const up = await storage('POST', `object/${BUCKET}/${r.object_id}`, bytes, 'text/plain');
  if (!up.ok) throw new Error(`object upload failed: HTTP ${up.status}`);
  srcSql(`select app.rcv_create_synthetic(${uuidLiteral(r.subject_id)}, ${uuidLiteral(r.object_id)}, '${BUCKET}', '${r.object_sha256}', '${OPERATOR}')`);
  const cp = await appendAndApply({ kind: 'checkpoint' });
  saveRun(r);
  return log('seed', { journal_head_before: pf.journal_head, subject_id: r.subject_id, object: { bucket: BUCKET, object_id: r.object_id, sha256: r.object_sha256 }, marked_env: r.marked_env, journal: cp });
}

async function backup() {
  const r = loadRun();
  if (!r.object_id) throw new Error('run seed first');
  const status = JSON.parse(srcSql('select app.rcv_recovery_status()'));
  const backupId = `t1-${r.run_id.slice(0, 8)}-SYNTHETIC`;
  const dir = join(STATE_DIR, 'backups', backupId);
  mkdirSync(join(dir, 'objects', BUCKET), { recursive: true, mode: 0o700 });
  // Database bytes: the app and api schemas (schema + data). The artifact ends with the restore
  // hold, so even a plain `psql -f` of it lands held with restored sessions deleted.
  const dump = run('docker', ['exec', localEnv().DB_CONTAINER, 'pg_dump', '-U', 'postgres', '--schema=app', '--schema=api']).out;
  const artifact = `${dump}\n\n-- Story 1.10 (AD-14): a restored snapshot starts held until journal reconciliation.\n`
    + `-- The hold runs only in a restore session and does not depend on restored operator rows.\n`
    + `set app.restore_in_progress = 'on';\nselect app.rcv_hold_after_restore('${backupId}', '${OPERATOR}');\nreset app.restore_in_progress;\n`;
  writeFileSync(join(dir, 'database.sql'), artifact, { mode: 0o600 });
  // Object bytes, separately, through the Storage API.
  const res = await storage('GET', `object/authenticated/${BUCKET}/${r.object_id}`);
  if (!res.ok) throw new Error(`object download failed: HTTP ${res.status}`);
  const bytes = Buffer.from(await res.arrayBuffer());
  if (sha256(bytes) !== r.object_sha256) throw new Error('object bytes changed');
  writeFileSync(join(dir, 'objects', BUCKET, r.object_id), bytes, { mode: 0o600 });
  const manifest = {
    label: 'SYNTHETIC', backup_id: backupId, taken_at: new Date().toISOString(),
    source_environment: status.environment, journal_watermark: status.journal_watermark,
    database: { file: 'database.sql', schemas: ['app', 'api'], bytes: Buffer.byteLength(artifact), sha256: sha256(artifact) },
    objects: [{ bucket: BUCKET, object_id: r.object_id, bytes: bytes.length, sha256: sha256(bytes) }],
  };
  writeFileSync(join(dir, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600 });
  r.backup_id = backupId;
  saveRun(r);
  return log('backup', { manifest, location: dir });
}

async function revoke() {
  const r = loadRun();
  const j = await appendAndApply({ kind: 'access_revoked', subject: r.subject_id });
  const subject = srcSql(`select access_revoked_at is not null from app.rcv_synthetic_subjects where subject_id = ${uuidLiteral(r.subject_id)}`);
  return log('revoke', { journal: j, source_subject_access_revoked: subject === 't' });
}

async function del() {
  const r = loadRun();
  const object = { bucket: BUCKET, object_id: r.object_id };
  // AD-14: the deletion manifest is journaled before the destructive step.
  const manifest = await appendAndApply({ kind: 'deletion_manifest', subject: r.subject_id, object });
  const res = await storage('DELETE', `object/${BUCKET}/${r.object_id}`);
  if (!res.ok) throw new Error(`object delete failed: HTTP ${res.status}`);
  const check = await storage('GET', `object/authenticated/${BUCKET}/${r.object_id}`);
  if (check.ok) throw new Error('object still present after delete');
  const completed = await appendAndApply({ kind: 'deletion_completed', object });
  return log('delete', { journal: [manifest, completed], source_object_http_after_delete: check.status });
}

async function seal() {
  const r = loadRun();
  r.cutoff = new Date().toISOString();
  const entry = await journal().append({ kind: 'seal', cutoff: r.cutoff });
  saveRun(r);
  return log('seal', { seq: entry.seq, head_seq: entry.head_seq, cutoff: entry.cutoff, hash: entry.hash, segment: `seg-${String(entry.seq).padStart(10, '0')}-seal.json` });
}

// ---------------------------------------------------------------------------------------------
// Scenario journals (copies of the live journal, damaged on purpose)
// ---------------------------------------------------------------------------------------------
export function deriveScenario(scenario, sourceDir, targetDir) {
  rmSync(targetDir, { recursive: true, force: true });
  if (scenario === 'absent') return targetDir;
  mkdirSync(targetDir, { recursive: true });
  const names = readdirSync(sourceDir).filter((n) => SEGMENT_RE.test(n)).sort();
  for (const n of names) {
    const kind = SEGMENT_RE.exec(n)[2];
    const isLast = n === names[names.length - 1];
    if (scenario === 'gap' && kind === 'deletion_manifest') continue;
    if (scenario === 'unsealed' && isLast && kind === 'seal') continue;
    if (scenario === 'tampered' && kind === 'access_revoked') {
      const e = JSON.parse(readFileSync(join(sourceDir, n), 'utf8'));
      e.subject = '00000000-0000-4000-8000-00000000dead';
      writeFileSync(join(targetDir, n), `${JSON.stringify(e)}\n`);
      continue;
    }
    copyFileSync(join(sourceDir, n), join(targetDir, n));
  }
  return targetDir;
}

function gateProbe(db) {
  // Rolled back: shows what the gates would say if the owner had approved them.
  const out = isoSql(db, `begin;
select app.policy_approve('private_access', '{"enabled": true}', '${OPERATOR}', 'REHEARSAL PROBE - rolled back');
select app.policy_approve('outbound_sending', '{"enabled": true}', '${OPERATOR}', 'REHEARSAL PROBE - rolled back');
select json_build_object('private_access_if_approved', app.policy_is_open('private_access'),
                         'outbound_sending_if_approved', app.policy_is_open('outbound_sending'));
rollback;`);
  return lastJson(out);
}

function scenarioDb(scenario) {
  if (!/^[a-z_]{1,30}$/.test(scenario ?? '')) throw new Error('scenario must be a short lowercase name');
  return { db: `rcv_${scenario}`, store: join(STATE_DIR, 'isolated-objects', scenario) };
}

function targetFacts(scenario) {
  const r = loadRun();
  const { db, store } = scenarioDb(scenario);
  return {
    status: JSON.parse(isoSql(db, 'select app.rcv_recovery_status()')),
    subject_access_revoked: isoSql(db, `select access_revoked_at is not null from app.rcv_synthetic_subjects where subject_id = ${uuidLiteral(r.subject_id)}`) === 't',
    object_present: existsSync(join(store, BUCKET, r.object_id)),
    gates_if_approved: gateProbe(db),
  };
}

function loadBackup() {
  const r = loadRun();
  if (!r.backup_id || !r.cutoff) throw new Error('run seed, backup, revoke, delete and seal first');
  const backupDir = join(STATE_DIR, 'backups', r.backup_id);
  const manifest = JSON.parse(readFileSync(join(backupDir, 'manifest.json'), 'utf8'));
  const artifact = readFileSync(join(backupDir, 'database.sql'), 'utf8');
  if (sha256(artifact) !== manifest.database.sha256) throw new Error('database artifact does not match its manifest');
  return { r, backupDir, manifest, artifact };
}

/** Restores the T1 database artifact and objects into the isolated target (no reconciliation). */
async function restoreTarget(scenario) {
  const { r, backupDir, manifest, artifact } = loadBackup();
  const { db, store } = scenarioDb(scenario);
  const image = ensureIsolated();
  run('docker', ['exec', ISOLATED, 'dropdb', '-U', 'postgres', '--if-exists', db]);
  run('docker', ['exec', ISOLATED, 'createdb', '-U', 'postgres', db]);
  run('docker', ['exec', '-i', ISOLATED, 'psql', '-U', 'postgres', '-d', db, '-X', '-q', '-v', 'ON_ERROR_STOP=1', '--single-transaction'], { input: artifact });
  // Objects into the isolated store, checked against the manifest.
  rmSync(store, { recursive: true, force: true });
  for (const o of manifest.objects) {
    mkdirSync(join(store, o.bucket), { recursive: true, mode: 0o700 });
    const src = join(backupDir, 'objects', o.bucket, o.object_id);
    if (sha256(readFileSync(src)) !== o.sha256) throw new Error('object backup does not match its manifest');
    copyFileSync(src, join(store, o.bucket, o.object_id));
  }
  return { target: { ...isolationFacts(), image, database: db, object_store: store }, backup_id: r.backup_id, restored: targetFacts(scenario) };
}

/** Plain `psql -f` of the artifact (no ON_ERROR_STOP, no single transaction) must land held. */
function plainRestoreCheck() {
  const { r, backupDir } = loadBackup();
  ensureIsolated();
  const db = 'rcv_plain_psql';
  run('docker', ['exec', ISOLATED, 'dropdb', '-U', 'postgres', '--if-exists', db]);
  run('docker', ['exec', ISOLATED, 'createdb', '-U', 'postgres', db]);
  run('docker', ['cp', join(backupDir, 'database.sql'), `${ISOLATED}:/tmp/rcv-database.sql`]);
  const res = run('docker', ['exec', ISOLATED, 'psql', '-U', 'postgres', '-d', db, '-X', '-q', '-f', '/tmp/rcv-database.sql'], { allowFail: true });
  const status = JSON.parse(isoSql(db, 'select app.rcv_recovery_status()'));
  return log('restore:plain_psql', { backup_id: r.backup_id, database: db, psql_exit_ok: res.ok, status, gates_if_approved: gateProbe(db) });
}

/** Reconciles an already-restored target from a journal. Returns {outcome, reason?, ...}. */
async function reconcileTarget(scenario, { journalDir, cutoff } = {}) {
  const r = loadRun();
  const { db, store } = scenarioDb(scenario);
  const restored = JSON.parse(isoSql(db, 'select app.rcv_recovery_status()'));
  if (restored.state !== 'restored_held') throw new Error(`${db} is not a held restore (state ${restored.state})`);
  const jDir = journalDir ? resolve(journalDir)
    : scenario === 'complete' ? JOURNAL_DIR
      : deriveScenario(scenario, JOURNAL_DIR, join(STATE_DIR, 'scenarios', scenario));
  const theCutoff = cutoff ?? (scenario === 'early_seal' ? new Date(Date.parse(r.cutoff) + 3_600_000).toISOString() : r.cutoff);
  const entries = await new LocalSegmentJournal(jDir).list();
  const acks = JSON.parse(isoSql(db, `select coalesce(json_agg(json_build_object('seq', seq, 'hash', entry_hash) order by seq), '[]') from app.rcv_journal_acks`));
  const verdict = verifyJournal(entries, { cutoff: theCutoff, databaseAcks: acks });
  const refuse = (reason) => {
    isoSql(db, `select app.rcv_record_refusal(${uuidLiteral(restored.restore_id)}, '${reason}', '${OPERATOR}')`);
    return { outcome: 'held', reason };
  };
  let outcome;
  if (!verdict.complete) {
    outcome = refuse(verdict.reason);
  } else {
    const absent = [];
    const applied = [];
    try {
      for (const e of entries) {
        const res = JSON.parse(isoSql(db, `select app.rcv_apply_journal_entry(${jsonLiteral(e)}, '${OPERATOR}')`));
        applied.push({ seq: res.seq, kind: res.kind, newly_applied: res.applied });
        if (res.delete_object) {
          const p = join(store, res.delete_object.bucket, res.delete_object.object_id);
          if (existsSync(p)) unlinkSync(p);
          if (existsSync(p)) throw new Error('restored object could not be removed');
          if (!absent.includes(res.delete_object.object_id)) absent.push(res.delete_object.object_id);
        }
      }
      const done = JSON.parse(isoSql(db, `select app.rcv_complete_reconciliation(${uuidLiteral(restored.restore_id)}, ${verdict.head_seq}, '${verdict.head_hash}', array[${absent.map(uuidLiteral).join(',')}]::uuid[], '${OPERATOR}')`));
      outcome = { outcome: done.state, applied, verified_absent: absent };
    } catch (e) {
      // Any replay failure keeps the hold and is recorded with a reason code.
      outcome = { ...refuse(/journal_mismatch/.test(e.message) ? 'journal_mismatch' : 'replay_failed'), applied };
    }
  }
  return { journal: { dir: jDir, cutoff: theCutoff, entries: entries?.length ?? 0, verdict }, ...outcome };
}

/** Restore + reconcile + facts, logged as one scenario record. */
async function runScenario(scenario, opts = {}) {
  const restored = await restoreTarget(scenario);
  const rec = await reconcileTarget(scenario, opts);
  return log(`restore:${scenario}`, { ...restored, ...rec, after: targetFacts(scenario) });
}

function cleanup({ keep = false } = {}) {
  const r = loadRun();
  if (!keep) run('docker', ['rm', '-f', ISOLATED], { allowFail: true });
  if (r.marked_env) {
    srcSql(`delete from app.platform_environment where set_by = '${MARKER_BY}';
            delete from app.platform_environment_history where set_by = '${MARKER_BY}';`);
    r.marked_env = false;
    saveRun(r);
  }
  return log('cleanup', { container_removed: !keep });
}

/** Checks one scenario result against the matrix; returns problems. */
export function expectScenario(name, res) {
  const p = [];
  const restoredHeld = res.restored.status.state === 'restored_held'
    && res.restored.gates_if_approved.private_access_if_approved === false
    && res.restored.gates_if_approved.outbound_sending_if_approved === false;
  if (!restoredHeld) p.push(`${name}: restore did not land held with both gates closed`);
  if (name === 'complete' || name === 'drive') {
    if (res.outcome !== 'reconciled') p.push(`${name}: expected reconciled, got ${res.outcome}`);
    if (!res.after.subject_access_revoked) p.push(`${name}: subject access not revoked`);
    if (res.after.object_present) p.push(`${name}: restored object still present`);
    if (res.after.status.serving_hold) p.push(`${name}: hold not cleared`);
    if (!res.after.gates_if_approved.private_access_if_approved || !res.after.gates_if_approved.outbound_sending_if_approved) {
      p.push(`${name}: gates should depend only on owner approval after reconciliation`);
    }
    if (res.after.status.private_access_open || res.after.status.outbound_sending_open) p.push(`${name}: unresolved gates must stay closed`);
  } else {
    const expected = { absent: 'journal_absent', gap: 'journal_gap', tampered: 'journal_chain_broken', unsealed: 'journal_unsealed', early_seal: 'journal_seal_before_cutoff' }[name];
    if (res.outcome !== 'held' || res.reason !== expected) p.push(`${name}: expected held/${expected}, got ${res.outcome}/${res.reason}`);
    if (!res.after.status.serving_hold || res.after.status.last_refusal !== expected) p.push(`${name}: hold/refusal not recorded`);
    if (res.after.gates_if_approved.private_access_if_approved || res.after.gates_if_approved.outbound_sending_if_approved) {
      p.push(`${name}: a gate opened without a complete journal`);
    }
  }
  return p;
}

async function main(argv) {
  const args = [...argv];
  const opt = (name) => { const i = args.indexOf(name); if (i < 0) return undefined; const v = args[i + 1]; args.splice(i, 2); return v; };
  const flag = (name) => { const i = args.indexOf(name); if (i < 0) return false; args.splice(i, 1); return true; };
  const ev = opt('--evidence');
  if (ev) evidenceDir = resolve(ev);
  const keep = flag('--keep');
  const journalDir = opt('--journal-dir');
  const cutoff = opt('--cutoff');
  const [cmd, scenario] = args;
  switch (cmd) {
    case 'seed': await seed(); break;
    case 'backup': await backup(); break;
    case 'revoke': await revoke(); break;
    case 'delete': await del(); break;
    case 'seal': await seal(); break;
    case 'restore': log(`restore-only:${scenario}`, await restoreTarget(scenario)); break;
    case 'reconcile': {
      const res = log(`reconcile:${scenario}`, await reconcileTarget(scenario, { journalDir, cutoff }));
      if (res.outcome !== 'reconciled') { console.error(`held: ${res.reason}`); process.exitCode = 1; }
      break;
    }
    case 'status': log(`status:${scenario}`, targetFacts(scenario)); break;
    case 'scenario': {
      const res = await runScenario(scenario, { journalDir, cutoff });
      const problems = expectScenario(scenario, res);
      if (problems.length) { console.error(problems.join('\n')); process.exitCode = 1; }
      break;
    }
    case 'cleanup': cleanup({ keep }); break;
    case 'all': {
      const problems = [];
      try {
        await seed(); await backup(); await revoke(); await del(); await seal();
        for (const s of [...NEGATIVE_SCENARIOS, 'complete']) problems.push(...expectScenario(s, await runScenario(s)));
        const plain = plainRestoreCheck();
        if (plain.status.state !== 'restored_held' || plain.gates_if_approved.private_access_if_approved
            || plain.gates_if_approved.outbound_sending_if_approved) {
          problems.push('plain psql -f restore did not land held with both gates closed');
        }
      } finally {
        cleanup({ keep });
      }
      log('summary', { scenarios: [...NEGATIVE_SCENARIOS, 'complete'], problems });
      if (problems.length) { console.error(problems.join('\n')); process.exitCode = 1; }
      break;
    }
    default:
      console.error('usage: rehearse.mjs all|seed|backup|revoke|delete|seal|restore|reconcile|status|scenario <scenario>|cleanup [--evidence dir] [--journal-dir dir] [--cutoff iso] [--keep]');
      process.exitCode = 2;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch((e) => { console.error(`rehearse: ${e.message}`); process.exitCode = 1; });
}
