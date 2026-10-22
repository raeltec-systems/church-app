#!/usr/bin/env node
// Story F3 end-to-end on the LOCAL stack: the existing pg_cron notifications scheduler starts
// notifications-worker, which calls the protected Content Edge action; content-assets uses its
// separate system credential and the Storage API to delete only expired, unreferenced draft files.
// Synthetic fixtures cover old ready and pending uploads, a recent upload, and an asset used by a
// revision. The run also checks that missing and wrong scheduler triggers cause no claims.
// LOCAL only. Evidence contains counts and booleans, never credentials, ids or Storage paths.
//
// Usage: node tools/identity-e2e/content-retention.mjs [--evidence <file.jsonl>]
import { execFileSync, spawn } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { localKey, psql, runMain, sleep, startRun } from './harness.mjs';

const OPERATOR = 'israel';
const MARKER_ACCOUNT = '00000000-0000-4000-8000-00000006f3e0';
const WORKER_FN = '/functions/v1/notifications-worker';
const CONTENT_FN = '/functions/v1/content-assets';
const IN_NETWORK_URL = 'http://kong:8000/functions/v1/notifications-worker';
const DEFAULT_POLICY = { lease_seconds: 120, batch_max: 25, max_attempts: 5, backoff_base_seconds: 60,
  backoff_max_seconds: 3600, default_ttl_seconds: 604800, worker_url: null };
const MAX_WAIT_MS = 120_000;
const SUPABASE_CLI = fileURLToPath(new URL('../../node_modules/supabase/dist/supabase.js', import.meta.url));

/** Results expected from one scheduler run, kept as booleans for evidence and offline tests. */
export function retentionVerdict({ oldReady, oldPending, recent, referenced }) {
  const removed = (row) => row?.asset === false && row?.object === false;
  const retained = (row) => row?.asset === true && row?.object === true;
  return {
    old_ready_removed: removed(oldReady),
    old_pending_removed: removed(oldPending),
    recent_retained: retained(recent),
    referenced_retained: retained(referenced),
  };
}

const newCredential = () => `sysc_local_${randomBytes(32).toString('base64url')}`;
const newTrigger = () => `nwt_${randomBytes(32).toString('hex')}`;

async function main() {
  const { log, check, finish } = startRun();
  const keys = localKey();
  const { origin, key, secret, service } = keys;
  const marker = psql('select coalesce((select environment from app.platform_environment), \'\')');
  let marked = false;
  if (marker === '') {
    psql("select app.platform_set_environment('local', 'content-asset-retention-e2e')");
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }

  const storage = async (method, path, body) => {
    const headers = { apikey: secret, Authorization: `Bearer ${service}` };
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    const res = await fetch(`${origin}/storage/v1/${path}`, {
      method, headers, body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { /* bytes or empty */ }
    return { status: res.status, json };
  };
  const deleteObject = async (path) => {
    const result = await storage('DELETE', `object/content-drafts/${path}`);
    return result.status >= 200 && result.status < 300 || result.status === 404;
  };
  const itemIds = new Set();
  const assetPaths = new Set();
  const cleanupObjects = async () => {
    const stored = psql(`select coalesce(string_agg(a.draft_path, ',' order by a.draft_path), '')
      from app.content_assets a join app.content_items i using (item_id)
      where i.created_by_account = '${MARKER_ACCOUNT}'`).split(',').filter(Boolean);
    const paths = new Set([...stored, ...assetPaths]);
    let removed = 0;
    for (const path of paths) if (await deleteObject(path)) removed++;
    return removed;
  };
  const cleanupRows = () => psql(`
    begin;
    delete from app.content_revision_files f using app.content_items i
     where f.item_id = i.item_id and i.created_by_account = '${MARKER_ACCOUNT}';
    delete from app.content_assets a using app.content_items i
     where a.item_id = i.item_id and i.created_by_account = '${MARKER_ACCOUNT}';
    delete from app.content_audit a where a.item_id in
      (select item_id from app.content_items where created_by_account = '${MARKER_ACCOUNT}');
    delete from app.content_items where created_by_account = '${MARKER_ACCOUNT}';
    commit;
    select count(*)::text from app.content_items where created_by_account = '${MARKER_ACCOUNT}';`);
  const resetScheduler = () => psql(`
    select app.notifications_scheduler_disable('${OPERATOR}');
    delete from vault.secrets where name = 'notifications_worker_trigger';
    select app.notifications_configure_worker('${JSON.stringify(DEFAULT_POLICY)}', '${OPERATOR}');`);
  const upload = async (path) => {
    const bytes = new Uint8Array([0x53, 0x59, 0x4e, 0x54, 0x48, 0x45, 0x54, 0x49, 0x43]);
    const headers = { apikey: secret, Authorization: `Bearer ${service}`, 'content-type': 'image/png', 'x-upsert': 'false' };
    const res = await fetch(`${origin}/storage/v1/object/content-drafts/${path}`, { method: 'POST', headers, body: bytes });
    await res.body?.cancel();
    if (!res.ok) throw new Error('could not create a local synthetic draft object');
  };
  const objectExists = async (path) => {
    const headers = { apikey: secret, Authorization: `Bearer ${service}` };
    const res = await fetch(`${origin}/storage/v1/object/authenticated/content-drafts/${path}`, { method: 'GET', headers });
    await res.body?.cancel();
    return res.ok;
  };
  const assetExists = (assetId) => Number(psql(`select count(*) from app.content_assets where asset_id = '${assetId}'`)) > 0;
  const retentionRequest = async (trigger) => {
    const headers = { 'content-type': 'application/json' };
    if (trigger !== undefined) headers['x-worker-trigger'] = trigger;
    const res = await fetch(`${origin}${CONTENT_FN}?action=retention-cleanup`, {
      method: 'POST', headers, body: '{}',
    });
    const json = await res.json().catch(() => null);
    return { status: res.status, json };
  };

  await cleanupObjects();
  const leftoverRows = cleanupRows();
  resetScheduler();
  log('F300-precondition', { local_only: true, leftover_rows_removed: Number(leftoverRows), scheduler_reset: true });

  const run = randomUUID().slice(0, 8);
  const principals = [];
  const credentials = [];
  const serveLogs = [];
  const envWork = mkdtempSync(join(tmpdir(), 'content-retention-e2e-'));
  const envFile = join(envWork, 'functions.env');
  let serve = null;
  let trigger = '';
  const fixtureItem = randomUUID();
  itemIds.add(fixtureItem);
  const assets = [
    { key: 'old_ready', id: randomUUID(), state: 'ready', age: "interval '31 days'" },
    { key: 'old_pending', id: randomUUID(), state: 'pending', age: "interval '32 days'" },
    { key: 'recent', id: randomUUID(), state: 'ready', age: "interval '29 days'" },
    { key: 'referenced', id: randomUUID(), state: 'ready', age: "interval '33 days'", referenced: true },
  ];
  for (const asset of assets) asset.path = `${asset.id}.png`;
  for (const asset of assets) assetPaths.add(asset.path);

  const mint = (name, purpose) => {
    const credential = newCredential();
    const principal = psql(`select app.sys_create_principal('${name}-${run}', '${purpose}', '${OPERATOR}')`);
    const digest = createHash('sha256').update(credential, 'utf8').digest('hex');
    const credentialId = JSON.parse(psql(`select app.sys_register_credential('${principal}', '${digest}',
      'content retention e2e ${run}', interval '2 hours', '${OPERATOR}')`)).credential_id;
    principals.push(principal);
    credentials.push(credentialId);
    return credential;
  };

  const startServe = async () => {
    const probe = async (path) => fetch(`${origin}${path}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' })
      .then((res) => res.status).catch(() => 0);
    if (await probe(WORKER_FN) === 401 && await probe(`${CONTENT_FN}?action=retention-cleanup`) === 401) return null;
    const child = spawn(process.execPath, [SUPABASE_CLI, 'functions', 'serve', '--env-file', envFile],
      { stdio: ['ignore', 'pipe', 'pipe'], detached: true });
    child.stdout.on('data', (data) => serveLogs.push(String(data)));
    child.stderr.on('data', (data) => serveLogs.push(String(data)));
    const deadline = Date.now() + MAX_WAIT_MS;
    while (Date.now() < deadline) {
      if (child.exitCode !== null) throw new Error('local Edge Functions stopped before boot');
      const [workerStatus, contentStatus] = await Promise.all([probe(WORKER_FN), probe(`${CONTENT_FN}?action=retention-cleanup`)]);
      if (workerStatus === 401 && contentStatus === 401) return child;
      await sleep(1500);
    }
    throw new Error('local Edge Functions did not start');
  };
  const stopServe = async () => {
    if (!serve) return;
    if (process.platform === 'win32') {
      try { execFileSync('taskkill', ['/pid', String(serve.pid), '/T', '/F'], { stdio: 'ignore' }); } catch { /* gone */ }
    } else {
      try { process.kill(-serve.pid, 'SIGINT'); } catch { /* gone */ }
    }
    await sleep(2500);
    if (process.platform !== 'win32') {
      try { process.kill(-serve.pid, 'SIGKILL'); } catch { /* gone */ }
    }
  };

  try {
    const workerCredential = mint('content-retention-notifications', 'notifications_worker');
    const retentionCredential = mint('content-retention-content', 'content_asset_retention');
    psql(`select app.notifications_scheduler_new_trigger('${OPERATOR}')`);
    trigger = psql("select decrypted_secret from vault.decrypted_secrets where name = 'notifications_worker_trigger'");
    if (!/^nwt_[0-9a-f]{64}$/.test(trigger)) throw new Error('local scheduler trigger was not configured');
    writeFileSync(envFile,
      `NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL=${workerCredential}\nNOTIFICATIONS_WORKER_TRIGGER=${trigger}\nCONTENT_ASSET_RETENTION_SYSTEM_CREDENTIAL=${retentionCredential}\n`,
      { mode: 0o600 });
    psql(`select app.notifications_configure_worker('{"worker_url": "${IN_NETWORK_URL}"}', '${OPERATOR}')`);

    await startServe().then((child) => { serve = child; });
    const claimCountBefore = Number(psql('select count(*) from app.content_assets where retention_claim_id is not null'));
    const noTrigger = await retentionRequest(undefined);
    const wrongTrigger = await retentionRequest(newTrigger());
    const claimCountAfter = Number(psql('select count(*) from app.content_assets where retention_claim_id is not null'));
    check('F301-cleanup-requires-the-scheduler-trigger', noTrigger.status === 401 && wrongTrigger.status === 401
      && claimCountBefore === claimCountAfter,
      { missing_trigger: noTrigger.status, wrong_trigger: wrongTrigger.status, claims_unchanged: claimCountBefore === claimCountAfter });

    psql(`insert into app.content_items (item_id, kind, draft_revision_no, last_revision_no,
                                          created_by_member, created_by_account)
          values ('${fixtureItem}', 'banner', 1, 1, '${MARKER_ACCOUNT}', '${MARKER_ACCOUNT}')`);
    for (const asset of assets) {
      psql(`insert into app.content_assets (asset_id, item_id, purpose, state, media_type, byte_size,
              width, height, sha256, draft_path, uploaded_by_member, uploaded_by_account, created_at, ready_at)
            values ('${asset.id}', '${fixtureItem}', 'banner_image', '${asset.state}', 'image/png', 9,
              960, 540, '${createHash('sha256').update(asset.key).digest('hex')}', '${asset.path}',
              '${MARKER_ACCOUNT}', '${MARKER_ACCOUNT}', now() - ${asset.age},
              ${asset.state === 'ready' ? `now() - ${asset.age}` : 'null'})`);
      await upload(asset.path);
    }
    const reference = assets.find((asset) => asset.referenced);
    psql(`insert into app.content_revision_files (item_id, revision_no, slot, purpose, asset_id)
          values ('${fixtureItem}', 1, 'image', 'banner_image', '${reference.id}')`);

    const enabled = JSON.parse(psql(`select app.notifications_scheduler_enable('${OPERATOR}', '15 seconds')`));
    check('F302-existing-notification-scheduler-enabled', enabled.scheduler_jobs === 1,
      { scheduler_jobs: enabled.scheduler_jobs, schedule: enabled.schedule });

    const deadline = Date.now() + MAX_WAIT_MS;
    while (Date.now() < deadline) {
      if (!assetExists(assets[0].id) && !assetExists(assets[1].id)) break;
      await sleep(2000);
    }
    const snapshot = {};
    for (const asset of assets) snapshot[asset.key] = {
      asset: assetExists(asset.id),
      object: await objectExists(asset.path),
    };
    const verdict = retentionVerdict({ oldReady: snapshot.old_ready, oldPending: snapshot.old_pending,
      recent: snapshot.recent, referenced: snapshot.referenced });
    check('F303-expired-unreferenced-ready-and-pending-uploads-are-removed',
      verdict.old_ready_removed && verdict.old_pending_removed,
      { old_ready_removed: verdict.old_ready_removed, old_pending_removed: verdict.old_pending_removed });
    check('F304-recent-and-referenced-uploads-remain', verdict.recent_retained && verdict.referenced_retained,
      { recent_retained: verdict.recent_retained, referenced_retained: verdict.referenced_retained });

    const status = JSON.parse(psql('select app.notifications_scheduler_status()'));
    const notificationRows = Number(psql('select count(*) from app.notifications_jobs'));
    const workerRanCleanup = serveLogs.join('').includes('"content_retention":{"state":"ran"');
    check('F305-existing-scheduler-runs-cleanup-without-creating-notifications',
      status.scheduler_jobs === 1 && status.last_claim_at !== null && workerRanCleanup && notificationRows === 0,
      { scheduler_jobs: status.scheduler_jobs, worker_seen: workerRanCleanup, notification_rows: notificationRows });
  } finally {
    resetScheduler();
    await stopServe();
    const objectsRemoved = await cleanupObjects();
    const rowsLeft = Number(cleanupRows());
    for (let i = 0; i < principals.length; i++) {
      try { psql(`select app.sys_revoke_credential('${credentials[i]}', '${OPERATOR}')`); } catch { /* already revoked */ }
      try { psql(`select app.sys_disable_principal('${principals[i]}', '${OPERATOR}')`); } catch { /* already disabled */ }
    }
    rmSync(envWork, { recursive: true, force: true });
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'content-asset-retention-e2e';
            delete from app.platform_environment_history where set_by = 'content-asset-retention-e2e';`);
    }
    const leaked = [...credentials, trigger, ...assetPaths].filter((secretValue) =>
      secretValue && serveLogs.join('').includes(secretValue)).length;
    check('F399-local-synthetic-data-cleaned', rowsLeft === 0 && leaked === 0,
      { rows_left: rowsLeft, fixture_objects_cleanup_attempted: objectsRemoved, leaked_values_in_logs: leaked });
  }
  finish();
}

runMain(import.meta.url, main);
