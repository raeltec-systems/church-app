#!/usr/bin/env node
// Story 3.6 end-to-end on the LOCAL stack: generic expiring member push through the FCM HTTP v1
// adapter of the Edge Function notifications-worker, against a FAKE FCM endpoint run here (an
// OAuth token endpoint that verifies the service account's RS256 assertion, and a send endpoint
// that answers per device token as scripted). Real GoTrue phone sign-in (no SMS), the real Data
// API, the real system route and `supabase functions serve`:
//   * push off: the inbox item is delivered and nothing is sent;
//   * a member without a registered device (push denied on the phone) and a member who turned
//     push off for the category still get the inbox item and no push job;
//   * push on: one generic message per live device (the contract's fixed title and body, the
//     inbox item id as the only data and as the stable collapse id, an expiry); an unregistered
//     token is retired after the provider's answer; provider acceptance is recorded as
//     `accepted`, never as delivery or reading;
//   * a provider 503 is retried after the backoff with the SAME notification id;
//   * an expired push job is never sent;
//   * the pushed item id opens the item only with the member's session (401 signed out);
//   * responses, function logs, receipts and evidence carry no token, key or text.
//
// Needs the local phone switch (`node tools/auth-harness/local-phone-auth.mjs on`, then `off`),
// the edge-runtime image and a reset database. LOCAL only, SYNTHETIC fictional numbers
// +44 7700 900910-900919. The service account key pair is generated for this run and never
// stored; the env file is 0600 and removed. Evidence is redacted JSONL (statuses, outcome codes,
// counts, booleans). Everything it created is removed and push is switched off again.
//
// Usage: node tools/identity-e2e/push.mjs [--evidence <file.jsonl>]
import { execFileSync, spawn } from 'node:child_process';
import { createHash, createPublicKey, generateKeyPairSync, randomBytes, randomUUID, verify } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { amrMethods, localHttp, localKey, password, psql, runMain, sleep, startRun } from './harness.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 3.6 E2E';
const FN = '/functions/v1/notifications-worker';
const PROJECT = 'bic-kafue-e2e';
const DEFAULT_POLICY = { lease_seconds: 120, batch_max: 25, max_attempts: 5, backoff_base_seconds: 60,
  backoff_max_seconds: 3600, default_ttl_seconds: 604800, worker_url: null, push_enabled: false };

/** The reserved fictional numbers this run uses (+44 7700 900910-900919). */
export function isFictionalPushPhone(phone) {
  return /^\+44770090091[0-9]$/.test(phone);
}

/** A synthetic FCM-shaped device token (never a real one). */
export function syntheticDeviceToken() {
  return `synthetic-${randomBytes(24).toString('base64url')}:APA91b`;
}

/** The values among `values` that appear in `text`. */
export function leaks(text, values) {
  return values.filter((v) => v && String(text).includes(String(v)));
}

/** True when an FCM v1 send body is the generic message for `itemId`, and nothing more. */
export function isGenericMessage(body, { token, itemId, title, text }) {
  const m = body?.message;
  if (!m || Object.keys(m).sort().join(',') !== 'android,apns,data,notification,token') return false;
  if (m.token !== token || JSON.stringify(m.notification) !== JSON.stringify({ title, body: text })) return false;
  if (JSON.stringify(m.data) !== JSON.stringify({ item_id: itemId })) return false;
  const a = m.android;
  if (a?.collapse_key !== itemId || a?.notification?.tag !== itemId || !/^[0-9]+s$/.test(a?.ttl ?? '')) return false;
  const h = m.apns?.headers ?? {};
  return h['apns-collapse-id'] === itemId && /^[0-9]{10}$/.test(h['apns-expiration'] ?? '');
}

const fcmError = (status, code, extra = []) => ({ error: { code: status, status: code, message: 'synthetic',
  details: [{ '@type': 'type.googleapis.com/google.firebase.fcm.v1.FcmError', errorCode: code }, ...extra] } });

/**
 * The fake FCM: POST /token verifies the RS256 assertion with the run's public key and issues an
 * access token; POST /v1/projects/<project>/messages:send needs that token and answers from the
 * per-token script (default: accepted). Every send body is kept in memory for the checks only.
 */
function fakeFcm({ publicKey, clientEmail }) {
  const issued = new Set();
  const script = new Map();
  const sends = [];
  let oauth = 0;
  let badAssertions = 0;
  let endpoint = '';
  const server = createServer((req, res) => {
    let raw = '';
    req.on('data', (d) => { raw += d; });
    req.on('end', () => {
      const answer = (status, json) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(json)); };
      if (req.method === 'POST' && req.url === '/token') {
        oauth += 1;
        const form = new URLSearchParams(raw);
        const [h, c, s] = (form.get('assertion') ?? '').split('.');
        let claims = null;
        try { claims = JSON.parse(Buffer.from(c, 'base64url')); } catch { /* malformed */ }
        const signed = h && c && s && verify('sha256', Buffer.from(`${h}.${c}`), createPublicKey(publicKey), Buffer.from(s, 'base64url'));
        if (form.get('grant_type') !== 'urn:ietf:params:oauth:grant-type:jwt-bearer' || !signed || claims?.iss !== clientEmail
            || claims?.aud !== `${endpoint}/token` || claims?.scope !== 'https://www.googleapis.com/auth/firebase.messaging') {
          badAssertions += 1;
          return answer(400, { error: 'invalid_grant' });
        }
        const token = `fake-access-${randomBytes(16).toString('hex')}`;
        issued.add(token);
        return answer(200, { access_token: token, expires_in: 3600, token_type: 'Bearer' });
      }
      if (req.method === 'POST' && req.url === `/v1/projects/${PROJECT}/messages:send`) {
        if (!issued.has((req.headers.authorization ?? '').replace(/^Bearer /, ''))) return answer(401, { error: { status: 'UNAUTHENTICATED' } });
        let body = null;
        try { body = JSON.parse(raw); } catch { return answer(400, fcmError(400, 'INVALID_ARGUMENT')); }
        sends.push(body);
        const queue = script.get(body?.message?.token) ?? [];
        const step = queue.length > 1 ? queue.shift() : queue[0] ?? 'accepted';
        if (step === 'unregistered') return answer(404, fcmError(404, 'UNREGISTERED'));
        if (step === 'unavailable') return answer(503, fcmError(503, 'UNAVAILABLE'));
        return answer(200, { name: `projects/${PROJECT}/messages/${sends.length}` });
      }
      return answer(404, { error: { status: 'NOT_FOUND' } });
    });
  });
  return {
    server, script, sends, issued,
    stats: () => ({ oauth, badAssertions }),
    setEndpoint: (e) => { endpoint = e; },
  };
}

async function main() {
  const { log, check, finish } = startRun();
  const keys = localKey();
  const { origin, key } = keys;
  const http = localHttp(keys);
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const envelope = (fn, token, cmd, expected, payload) =>
    rpc(fn, token, { version: 1, command: cmd, request_id: randomUUID(), expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const utc = (ms) => new Date(ms).toISOString();
  const edgeOut = [];
  const edge = async (trigger) => {
    const res = await fetch(`${origin}${FN}`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-worker-trigger': trigger },
      body: JSON.stringify({ action: 'run' }) });
    const text = await res.text();
    edgeOut.push(text);
    let json = null;
    try { json = JSON.parse(text); } catch { /* not JSON */ }
    return { status: res.status, json };
  };

  const people = {
    a: { phone: '+447700900910', name: `${NAME_PREFIX} Two devices` },
    b: { phone: '+447700900911', name: `${NAME_PREFIX} Flaky provider` },
    c: { phone: '+447700900912', name: `${NAME_PREFIX} Push denied` },
    d: { phone: '+447700900913', name: `${NAME_PREFIX} Push off` },
  };
  for (const p of Object.values(people)) if (!isFictionalPushPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  const users = new Set();
  const digits = Object.values(people).map((p) => `'${p.phone.slice(1)}'`).join(',');
  const cleanup = () => {
    const ids = [...users].map((u) => `'${u}'`);
    const byUser = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    return psql(`
    create temp table gone_users as select u.id from auth.users u where ${byUser} u.phone in (${digits});
    create temp table gone_members as
      select m.member_id from app.identity_members m where m.display_name like '${NAME_PREFIX}%';
    delete from app.notifications_attempts a using app.notifications_jobs j
     where a.job_id = j.job_id and j.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_push_jobs p
     where p.recipient_member_id in (select member_id from gone_members) or p.account_id in (select id from gone_users);
    delete from app.notifications_inbox_items i where i.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_jobs j where j.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_device_tokens t
     where t.member_id in (select member_id from gone_members) or t.account_id in (select id from gone_users);
    delete from app.notifications_push_settings s
     where s.member_id in (select member_id from gone_members) or s.account_id in (select id from gone_users);
    delete from app.fixture_reminder_sources s where s.member_id in (select member_id from gone_members);
    delete from app.identity_access_audit a
     where a.target_member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_grants g where g.member_id in (select member_id from gone_members);
    delete from app.identity_grant_sets s where s.member_id in (select member_id from gone_members);
    delete from app.identity_holds h where h.member_id in (select member_id from gone_members);
    delete from app.identity_binding_history h using app.identity_account_links l
     where h.link_id = l.link_id and (l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users));
    delete from app.identity_credential_events e using app.identity_account_links l
     where e.link_id = l.link_id and (l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users));
    delete from app.identity_account_links l
     where l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users);
    delete from app.identity_members m where m.member_id in (select member_id from gone_members);
    delete from app.cmd_receipts r where r.actor_id in (select id from gone_users);
    delete from auth.users u where u.id in (select id from gone_users);
    select count(*) from auth.users u where ${byUser} u.phone in (${digits});`);
  };
  const resetPolicy = () => psql(`
    select app.notifications_scheduler_disable('${OPERATOR}');
    delete from vault.secrets where name = 'notifications_worker_trigger';
    select app.notifications_configure_worker('${JSON.stringify(DEFAULT_POLICY)}', '${OPERATOR}');`);

  const settings = await http('GET', '/auth/v1/settings');
  if (settings.json?.external?.phone !== true) {
    throw new Error('the local phone provider is off: run `node tools/auth-harness/local-phone-auth.mjs on` first');
  }
  const marker = psql(`select coalesce((select environment from app.platform_environment), '')`);
  let marked = false;
  if (marker === '') {
    psql(`select app.platform_set_environment('local', 'notifications-push-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('P00-precondition', { leftover_users_removed: cleanup(), policy_reset: resetPolicy() !== null });

  // The run's own Firebase-shaped service account: a fresh key pair, never stored.
  const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048,
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' }, publicKeyEncoding: { type: 'spki', format: 'pem' } });
  const clientEmail = `push-e2e@${PROJECT}.iam.gserviceaccount.com`;
  const account = Buffer.from(JSON.stringify({ type: 'service_account', project_id: PROJECT, private_key_id: 'e2e',
    private_key: privateKey, client_email: clientEmail })).toString('base64');
  const fake = fakeFcm({ publicKey, clientEmail });
  await new Promise((r) => fake.server.listen(0, '0.0.0.0', r));
  let gateway = 'host.docker.internal';
  try {
    gateway = execFileSync('docker', ['network', 'inspect', 'supabase_network_church-app', '-f',
      '{{range .IPAM.Config}}{{.Gateway}}{{end}}'], { encoding: 'utf8' }).trim() || gateway;
  } catch { /* keep host.docker.internal */ }
  const endpoint = `http://${gateway}:${fake.server.address().port}`;
  fake.setEndpoint(endpoint);

  const run = randomUUID().slice(0, 8);
  const credential = `sysc_local_${randomBytes(32).toString('base64url')}`;
  const principal = psql(`select app.sys_create_principal('notifications-push-e2e-${run}', 'notifications_worker', '${OPERATOR}')`);
  const credentialId = JSON.parse(psql(`select app.sys_register_credential('${principal}',
    '${createHash('sha256').update(credential).digest('hex')}', 'push e2e ${run}', interval '2 hours', '${OPERATOR}')`)).credential_id;
  psql(`select app.notifications_scheduler_new_trigger('${OPERATOR}')`);
  const trigger = psql(`select decrypted_secret from vault.decrypted_secrets where name = 'notifications_worker_trigger'`);
  const work = mkdtempSync(join(tmpdir(), 'push-e2e-'));
  const envFile = join(work, 'functions.env');
  writeFileSync(envFile, [
    `NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL=${credential}`,
    `NOTIFICATIONS_WORKER_TRIGGER=${trigger}`,
    `NOTIFICATIONS_FCM_SERVICE_ACCOUNT=${account}`,
    `NOTIFICATIONS_FCM_TEST_ENDPOINT=${endpoint}`, ''].join('\n'), { mode: 0o600 });
  let serveLog = '';
  const serve = spawn('npx', ['supabase', 'functions', 'serve', '--env-file', envFile], { stdio: ['ignore', 'pipe', 'pipe'], detached: true });
  serve.stdout.on('data', (d) => { serveLog += d; });
  serve.stderr.on('data', (d) => { serveLog += d; });

  const pushOf = (sourceId) => psql(`select coalesce((select p.push_job_id::text from app.notifications_push_jobs p
    join app.notifications_jobs j on j.job_id = p.job_id where j.source_id = '${sourceId}'), 'none')`);
  const pushState = (pushId) => psql(`select push_state || '|' || coalesce(finish_reason, '-') from app.notifications_push_jobs where push_job_id = '${pushId}'`);
  const pushOutcomes = (pushId) => psql(`select coalesce(string_agg(outcome, ',' order by attempted_at, attempt_id), '')
    from app.notifications_attempts where push_job_id = '${pushId}'`);
  const itemOf = (sourceId) => psql(`select coalesce((select i.item_id::text from app.notifications_inbox_items i
    join app.notifications_jobs j on j.job_id = i.job_id where j.source_id = '${sourceId}'), 'none')`);
  const tokenState = (token) => psql(`select coalesce(retire_reason, 'live') from app.notifications_device_tokens where token = '${token}'`);
  const contract = JSON.parse(psql(`select jsonb_build_object('title', title, 'body', body) from app.contract_reminder_contracts
    where source_type = 'fixture_reminder' and reminder_kind = 'fixture_due'`));
  const devices = {};

  try {
    const deadline = Date.now() + 90_000;
    for (;;) {
      const probe = await fetch(`${origin}${FN}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' })
        .then((r) => r.status).catch(() => 0);
      if (probe === 401) break;
      if (Date.now() > deadline) throw new Error('the Edge Function did not start (is the edge-runtime image present?)');
      await sleep(1500);
    }
    for (const [k, p] of Object.entries(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'notifications-push-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
      if (!amrMethods(p.token).includes('password')) throw new Error(`member ${k} did not sign in`);
    }
    const { a, b, c, d } = people;
    const register = async (p, name) => {
      devices[name] = syntheticDeviceToken();
      return envelope('notifications_command', p.token, 'notifications.register_device', null,
        { token: devices[name], platform: name.endsWith('ios') ? 'ios' : 'android' });
    };
    const regs = [await register(a, 'a1-android'), await register(a, 'a2-ios'), await register(b, 'b1-android'),
      await register(d, 'd1-android')];
    const off = await envelope('notifications_command', d.token, 'notifications.set_push_category', null,
      { source_type: 'fixture_reminder', reminder_kind: 'fixture_due', push_enabled: false });
    check('P01-members-signed-in-and-devices-registered', regs.every((r) => r.status === 200) && off.status === 200
      && !regs.some((r) => JSON.stringify(r).includes(':APA91b')),
      { registered: regs.map((r) => r.status), push_off_for_d: off.status, token_returned: false });
    fake.script.set(devices['a2-ios'], ['unregistered']);
    fake.script.set(devices['b1-android'], ['unavailable', 'accepted']);
    const remind = async (p) => (await envelope('fixture_reminder_command', p.token, 'fixture.reminder_create', null,
      { due_at: utc(Date.now() - 60_000) })).data?.source_id;

    // ------------------------------------------------------------------ push off: inbox only
    const sa = await remind(a);
    const sc = await remind(c);
    const sd = await remind(d);
    const r1 = await edge(trigger);
    check('P10-push-off-inbox-delivered-nothing-sent', r1.status === 200 && r1.json?.outcomes?.delivered === 3
      && r1.json?.push?.enabled === false && r1.json?.push?.claimed === 0 && fake.sends.length === 0
      && [sa, sc, sd].every((s) => itemOf(s) !== 'none') && pushState(pushOf(sa)) === 'pending|-',
      { status: r1.status, delivered: r1.json?.outcomes?.delivered, push: r1.json?.push, sends: fake.sends.length });
    check('P11-denied-or-off-push-keeps-the-inbox-item', pushOf(sc) === 'none' && pushOf(sd) === 'none'
      && itemOf(sc) !== 'none' && itemOf(sd) !== 'none',
      { no_device_push_job: pushOf(sc) === 'none', category_off_push_job: pushOf(sd) === 'none', items: 2 });

    // ------------------------------------------------------------------ push on: accepted + invalid token
    psql(`select app.notifications_configure_worker('{"push_enabled": true}', '${OPERATOR}')`);
    const r2 = await edge(trigger);
    const itemA = itemOf(sa);
    const sentA = fake.sends.filter((s) => s.message?.data?.item_id === itemA);
    check('P20-push-sent-to-each-live-device', r2.status === 200 && r2.json?.push?.claimed === 1
      && r2.json?.push?.outcomes?.accepted === 1 && sentA.length === 2
      && pushState(pushOf(sa)) === 'accepted|accepted' && pushOutcomes(pushOf(sa)).split(',').sort().join(',') === 'accepted,token_invalid',
      { push: r2.json?.push, sends: sentA.length, state: pushState(pushOf(sa)), attempts: pushOutcomes(pushOf(sa)) });
    const generic = sentA.every((s) => isGenericMessage(s, { token: s.message.token, itemId: itemA, title: contract.title, text: contract.body }));
    check('P21-payload-is-generic-and-expiring', generic && sentA.map((s) => s.message.token).sort().join() === [devices['a1-android'], devices['a2-ios']].sort().join(),
      { generic, keys: Object.keys(sentA[0]?.message ?? {}).sort(), data_keys: Object.keys(sentA[0]?.message?.data ?? {}),
        collapse_is_item: sentA.every((s) => s.message.android.collapse_key === itemA && s.message.apns.headers['apns-collapse-id'] === itemA) });
    check('P22-invalid-token-retired-after-the-provider-answer', tokenState(devices['a2-ios']) === 'provider_invalid'
      && tokenState(devices['a1-android']) === 'live',
      { invalid: tokenState(devices['a2-ios']), other: tokenState(devices['a1-android']) });
    check('P23-oauth-assertion-verified', fake.stats().oauth >= 1 && fake.stats().badAssertions === 0,
      { oauth_requests: fake.stats().oauth, bad_assertions: fake.stats().badAssertions });

    // ------------------------------------------------------------------ transient: retried, same notification id
    const sb = await remind(b);
    const r3 = await edge(trigger);
    const itemB = itemOf(sb);
    const first = fake.sends.filter((s) => s.message?.data?.item_id === itemB);
    psql(`update app.notifications_push_jobs set last_failed_at = now() - interval '61 seconds' where push_job_id = '${pushOf(sb)}'`);
    const r4 = await edge(trigger);
    const both = fake.sends.filter((s) => s.message?.data?.item_id === itemB);
    check('P30-transient-retried-with-the-same-notification-id', r3.json?.push?.outcomes?.retry === 1 && first.length === 1
      && r4.json?.push?.outcomes?.accepted === 1 && both.length === 2
      && both.every((s) => s.message.android.collapse_key === itemB && s.message.apns.headers['apns-collapse-id'] === itemB)
      && pushOutcomes(pushOf(sb)) === 'transient,accepted' && pushState(pushOf(sb)) === 'accepted|accepted'
      && tokenState(devices['b1-android']) === 'live',
      { first_run: r3.json?.push?.outcomes, second_run: r4.json?.push?.outcomes, sends: both.length,
        same_notification_id: both.every((s) => s.message.android.collapse_key === itemB), attempts: pushOutcomes(pushOf(sb)) });

    // ------------------------------------------------------------------ expired: never sent
    psql(`select app.notifications_configure_worker('{"push_enabled": false}', '${OPERATOR}')`);
    const se = await remind(a);
    await edge(trigger);
    psql(`update app.notifications_push_jobs set expires_at = now() - interval '1 second' where push_job_id = '${pushOf(se)}';
          select app.notifications_configure_worker('{"push_enabled": true}', '${OPERATOR}');`);
    const before = fake.sends.length;
    const r5 = await edge(trigger);
    check('P40-expired-push-never-sent', r5.json?.push?.expired === 1 && fake.sends.length === before
      && pushState(pushOf(se)) === 'obsolete|expired' && itemOf(se) !== 'none',
      { push: r5.json?.push, new_sends: fake.sends.length - before, state: pushState(pushOf(se)) });

    // ------------------------------------------------------------------ the pushed item id opens only with a session
    const opened = await rpc('notifications_open_item', a.token, { item_id: itemA });
    const signedOut = await rpc('notifications_open_item', undefined, { item_id: itemA });
    const other = await rpc('notifications_open_item', b.token, { item_id: itemA });
    check('P50-push-tap-opens-the-current-item-after-auth', opened.status === 200 && opened.json?.state === 'current'
      && signedOut.status === 401 && other.json?.state === 'not_found',
      { member: [opened.status, opened.json?.state], signed_out: signedOut.status, other_member: other.json?.state });

    // ------------------------------------------------------------------ never delivery, never content
    const claims = Number(psql(`select count(*) from app.notifications_attempts
      where channel = 'push' and outcome not in ('accepted', 'token_invalid', 'rejected', 'transient', 'lapsed', 'fenced',
        'expired', 'obsolete', 'failed', 'exhausted', 'cancelled', 'finished')`));
    const inbox = await rpc('notifications_my_inbox', a.token);
    check('P60-no-attempt-or-item-claims-delivery-or-reading', claims === 0
      && !(inbox.json?.items ?? []).some((i) => 'read' in i || 'read_at' in i || 'push_state' in i),
      { unexpected_outcomes: claims, inbox_keys: Object.keys(inbox.json?.items?.[0] ?? {}).sort() });
    const secrets = [...Object.values(devices), credential, trigger, privateKey.split('\n')[1], clientEmail, ...fake.issued,
      contract.title, contract.body, itemA, itemB, a.member, a.user];
    const status = psql(`select app.notifications_scheduler_status()::text`);
    const receipts = Number(psql(`select count(*) from app.sys_receipts where result::text like '%:APA91b%'`));
    check('P70-responses-logs-status-receipts-content-free', leaks(edgeOut.join('\n'), secrets).length === 0
      && leaks(serveLog, secrets).length === 0 && leaks(status, secrets).length === 0 && receipts === 0
      && serveLog.includes('"fn":"notifications-worker"'),
      { leaked_in_responses: leaks(edgeOut.join('\n'), secrets).length, leaked_in_function_log: leaks(serveLog, secrets).length,
        leaked_in_status: leaks(status, secrets).length, receipts_with_tokens: receipts });
  } finally {
    try { process.kill(-serve.pid, 'SIGINT'); } catch { /* already gone */ }
    await sleep(3000);
    try { process.kill(-serve.pid, 'SIGKILL'); } catch { /* already gone */ }
    try { execFileSync('docker', ['rm', '-f', 'supabase_edge_runtime_church-app'], { stdio: 'ignore' }); } catch { /* not running */ }
    fake.server.close();
    rmSync(work, { recursive: true, force: true });
    resetPolicy();
    const left = cleanup();
    psql(`select app.sys_revoke_credential('${credentialId}', '${OPERATOR}');
          select app.sys_disable_principal('${principal}', '${OPERATOR}');
          delete from app.notifications_worker_runs where principal_id = '${principal}';`);
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'notifications-push-e2e';
            delete from app.platform_environment_history where set_by = 'notifications-push-e2e';`);
    }
    log('P99-cleanup', { users_left: Number(left), credential_revoked: true, principal_disabled: true, unmarked: marked,
      push_jobs_left: Number(psql(`select count(*) from app.notifications_push_jobs`)),
      tokens_left: Number(psql(`select count(*) from app.notifications_device_tokens`)),
      push_enabled: psql(`select push_enabled from app.notifications_worker_settings`) === 't',
      env_file_removed: true });
  }
  finish();
}

runMain(import.meta.url, main);
