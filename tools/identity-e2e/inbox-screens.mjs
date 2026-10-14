#!/usr/bin/env node
// Story 3.7 end-to-end on the LOCAL stack: the inbox screens' server contract through real
// GoTrue phone sign-in (no SMS), the real Data API (PostgREST), the real worker script and the
// real Realtime service (private broadcast channels):
//   * a member's session joins its own `account:<uid>` channel; another member's session and a
//     signed-out socket are refused on it;
//   * delivery, the first open, a snooze, a cancellation and a response each reach the open
//     channel as `inbox_changed` with an EMPTY payload: the captured frames carry no item, source
//     or member id, no text and no source type;
//   * markers: a new item is listed not opened; opening marks it opened and offers the policy's
//     snooze choices (1 hour, 24 hours, 2 days);
//   * snooze: only the recipient may snooze; the list shows when it comes back; a source
//     cancellation removes the snooze; a 2-day snooze of a request starting in 20 hours is
//     clamped to the start; the member's response removes the snooze and the item opens out of
//     date;
//   * push off for a category keeps new reminders in the inbox and queues no push.
//
// Needs Realtime running (start the stack without `-x realtime`) and the local phone switch:
// `node tools/auth-harness/local-phone-auth.mjs on`, then `off` afterwards. LOCAL only (exact
// origin), SYNTHETIC fictional numbers +44 7700 900930-900939, synthetic device tokens.
// Evidence is redacted JSONL: statuses, codes, states, counts, and the captured signal payloads
// and frame keys; never tokens, passwords, numbers, ids or the credential. Every user, member,
// link, reminder, schedule, job, item, device, setting, receipt and broadcast row it created is
// removed; the run's credential is revoked and its principal disabled.
//
// Usage: node tools/identity-e2e/inbox-screens.mjs [--evidence <file.jsonl>]
import { execFile } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { amrMethods, localHttp, localKey, password, psql, runMain, sleep, startRun } from './harness.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 3.7 E2E';

/** The reserved fictional numbers this run uses (+44 7700 900930-900939). */
export function isFictionalScreensPhone(phone) {
  return /^\+44770090093[0-9]$/.test(phone);
}

/**
 * A captured refresh signal is generic when it is a broadcast `inbox_changed` whose payload is
 * exactly `{}`, whose envelope holds only Realtime's own fields (`meta` carries at most
 * Realtime's per-message `id`), and which contains none of the given private values (ids, text)
 * anywhere but the topic. The topic is the subscriber's own `account:<uid>` channel name, which
 * the subscriber chose; it must equal `ownTopic`.
 */
export function isGenericSignal(frame, privateValues, ownTopic) {
  if (!frame || typeof frame !== 'object' || frame.event !== 'broadcast') return false;
  if (ownTopic !== undefined && frame.topic !== `realtime:${ownTopic}`) return false;
  const inner = frame.payload;
  if (!inner || inner.event !== 'inbox_changed' || inner.type !== 'broadcast') return false;
  if (!Object.keys(inner).every((k) => ['event', 'meta', 'payload', 'type'].includes(k))) return false;
  if (inner.meta !== undefined && !Object.keys(inner.meta ?? {}).every((k) => k === 'id')) return false;
  if (!inner.payload || typeof inner.payload !== 'object' || Array.isArray(inner.payload)
      || Object.keys(inner.payload).length !== 0) return false;
  const { topic: _topic, ...rest } = frame;
  const text = JSON.stringify(rest);
  return privateValues.every((v) => !v || !text.includes(String(v)));
}

/** One Realtime socket joined to a private topic; collects broadcast frames. */
function channel(origin, key, topic, token) {
  const url = `${origin.replace(/^http/, 'ws')}/realtime/v1/websocket?apikey=${encodeURIComponent(key)}&vsn=1.0.0`;
  const ws = new WebSocket(url);
  const frames = [];
  let reply = null;
  let ref = 1;
  const heartbeat = setInterval(() => {
    if (ws.readyState === 1) ws.send(JSON.stringify({ topic: 'phoenix', event: 'heartbeat', payload: {}, ref: String(++ref) }));
  }, 20_000);
  ws.onopen = () => ws.send(JSON.stringify({
    topic: `realtime:${topic}`, event: 'phx_join', ref: '1', join_ref: '1',
    payload: { config: { broadcast: { ack: false, self: false }, presence: { key: '' }, postgres_changes: [], private: true },
               ...(token ? { access_token: token } : {}) } }));
  ws.onmessage = (m) => {
    let f;
    try { f = JSON.parse(m.data); } catch { return; }
    if (f.event === 'phx_reply' && f.ref === '1') reply = f.payload?.status ?? 'unknown';
    if (f.event === 'broadcast') frames.push(f);
  };
  ws.onerror = () => { if (reply === null) reply = 'socket_error'; };
  return {
    frames,
    joined: async (ms = 8000) => {
      const until = Date.now() + ms;
      while (reply === null && Date.now() < until) await sleep(100);
      return reply ?? 'timeout';
    },
    close: () => { clearInterval(heartbeat); try { ws.close(); } catch { /* closed */ } },
  };
}

/** Waits until `ch` holds more than `before` frames (or the time is up); returns the new ones. */
async function newFrames(ch, before, ms = 8000) {
  const until = Date.now() + ms;
  while (ch.frames.length <= before && Date.now() < until) await sleep(100);
  await sleep(300);
  return ch.frames.slice(before);
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
  const reminder = (token, cmd, expected, payload) => envelope('fixture_reminder_command', token, cmd, expected, payload);
  const notif = (token, cmd, expected, payload) => envelope('notifications_command', token, cmd, expected, payload);
  const open = (token, itemId) => rpc('notifications_open_item', token, { item_id: itemId });
  const listed = async (token, itemId) => ((await rpc('notifications_my_inbox', token)).json?.items ?? [])
    .find((i) => i.item_id === itemId) ?? null;
  const utc = (ms) => new Date(ms).toISOString();

  const people = {
    a: { phone: '+447700900930', name: `${NAME_PREFIX} Member A` },
    b: { phone: '+447700900931', name: `${NAME_PREFIX} Member B` },
  };
  for (const p of Object.values(people)) if (!isFictionalScreensPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
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
    delete from app.notifications_direct_contact_needs n where n.recipient_member_id in (select member_id from gone_members);
    update app.notifications_jobs j set snoozed_from_item_id = null
     where j.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_inbox_items i where i.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_jobs j where j.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_schedules s where s.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_device_tokens t
     where t.member_id in (select member_id from gone_members) or t.account_id in (select id from gone_users);
    delete from app.notifications_push_settings s
     where s.member_id in (select member_id from gone_members) or s.account_id in (select id from gone_users);
    delete from app.fixture_reminder_contact_needs n where n.member_id in (select member_id from gone_members);
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
    delete from realtime.messages r where r.topic in (select 'account:' || id::text from gone_users);
    delete from auth.users u where u.id in (select id from gone_users);
    select count(*) from auth.users u where ${byUser} u.phone in (${digits});`);
  };

  const settings = await http('GET', '/auth/v1/settings');
  if (settings.json?.external?.phone !== true) {
    throw new Error('the local phone provider is off: run `node tools/auth-harness/local-phone-auth.mjs on` first');
  }
  // Realtime answers a join (here refused: no session) once it is up; a reset restarts it.
  let probeReply = 'timeout';
  for (let i = 0; i < 8 && (probeReply === 'socket_error' || probeReply === 'timeout'); i++) {
    if (i) await sleep(4000);
    const probe = channel(origin, key, `account:${randomUUID()}`, null);
    probeReply = await probe.joined(5000);
    probe.close();
  }
  if (probeReply === 'socket_error' || probeReply === 'timeout') {
    throw new Error('Realtime is not running: start the local stack without `-x realtime`');
  }
  const marker = psql(`select coalesce((select environment from app.platform_environment), '')`);
  let marked = false;
  if (marker === '') {
    psql(`select app.platform_set_environment('local', 'notifications-screens-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('S00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    realtime: 'running', leftover_users_removed: cleanup(),
  });

  const run = randomUUID().slice(0, 8);
  const credential = `sysc_local_${randomBytes(32).toString('base64url')}`;
  const principal = psql(`select app.sys_create_principal('notifications-worker-e2e-${run}', 'notifications_worker', '${OPERATOR}')`);
  const credentialId = JSON.parse(psql(`select app.sys_register_credential('${principal}',
    '${createHash('sha256').update(credential).digest('hex')}', 'screens e2e ${run}', interval '2 hours', '${OPERATOR}')`)).credential_id;
  const worker = async () => {
    try {
      const { stdout } = await promisify(execFile)('node', [join(ROOT, 'tools/notifications/worker.mjs'), 'run-once'], {
        encoding: 'utf8',
        env: { PATH: process.env.PATH, SUPABASE_URL: origin, SUPABASE_PUBLISHABLE_KEY: key, NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL: credential } });
      const line = stdout.split('\n').find((l) => l.startsWith('{'));
      return { exit: 0, ...(line ? JSON.parse(line) : {}) };
    } catch (e) {
      return { exit: e.code ?? 1, error: String(e.stderr ?? '').trim().slice(-160) };
    }
  };
  const itemOf = (sourceId) => psql(`select coalesce((select i.item_id::text from app.notifications_inbox_items i
    join app.notifications_jobs j on j.job_id = i.job_id where j.source_id = '${sourceId}' and j.snoozed_from_item_id is null
    order by i.delivered_at desc limit 1), '')`);
  const snoozeJobs = (itemId) => psql(`select coalesce(string_agg(job_state || ':' || coalesce(cancel_reason, '-'), ','
    order by enqueued_at), '') from app.notifications_jobs where snoozed_from_item_id = '${itemId}'`);
  const sockets = [];

  try {
    const { a, b } = people;
    for (const p of [a, b]) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'notifications-screens-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    check('S01-members-signed-in-by-phone', [a, b].every((p) => amrMethods(p.token).includes('password')),
      { amr: amrMethods(a.token) });

    // ------------------------------------------------------------ channel authorisation
    const chA = channel(origin, key, `account:${a.user}`, a.token);
    const chB = channel(origin, key, `account:${b.user}`, b.token);
    const spy = channel(origin, key, `account:${a.user}`, b.token);
    const anon = channel(origin, key, `account:${a.user}`, null);
    sockets.push(chA, chB, spy, anon);
    const joins = { own_a: await chA.joined(), own_b: await chB.joined(), b_on_a: await spy.joined(), signed_out_on_a: await anon.joined() };
    check('S10-only-the-account-joins-its-channel', joins.own_a === 'ok' && joins.own_b === 'ok'
      && joins.b_on_a === 'error' && joins.signed_out_on_a === 'error', joins);

    const privateValues = () => [a.user, b.user, a.member, b.member, 'fixture', 'SYNTHETIC', 'reminder', 'waiting'];
    const signals = [];
    const expectSignal = async (step, action) => {
      const before = chA.frames.length;
      const beforeB = chB.frames.length;
      const result = await action();
      const got = await newFrames(chA, before);
      signals.push(...got);
      return { result, got, toB: chB.frames.length - beforeB };
    };

    // ------------------------------------------------------------ delivery, markers, open
    const src1 = (await reminder(a.token, 'fixture.reminder_create', null, { due_at: utc(Date.now() - 60_000) })).data?.source_id;
    const delivered = await expectSignal('deliver', worker);
    const item1 = itemOf(src1);
    const values1 = [...privateValues(), src1, item1];
    check('S20-delivery-signals-generically', delivered.result.delivered === 1 && delivered.got.length >= 1
      && delivered.got.every((f) => isGenericSignal(f, values1, `account:${a.user}`)) && delivered.toB === 0,
      { delivered: delivered.result.delivered, frames: delivered.got.length, payloads: delivered.got.map((f) => f.payload?.payload),
        frame_keys: Object.keys(delivered.got[0] ?? {}).sort(), inner_keys: Object.keys(delivered.got[0]?.payload ?? {}).sort(),
        frames_to_b: delivered.toB });
    const fresh = await listed(a.token, item1);
    check('S21-new-item-not-opened', fresh?.opened === false && fresh?.snoozed_until === null,
      { opened: fresh?.opened, snoozed_until: fresh?.snoozed_until });
    const byB = await open(b.token, item1);
    const opened = await expectSignal('open', () => open(a.token, item1));
    const afterOpen = await listed(a.token, item1);
    check('S22-open-marks-opened-and-offers-choices', JSON.stringify(byB.json) === '{"state":"not_found"}'
      && opened.result.json?.state === 'current'
      && JSON.stringify(opened.result.json?.snooze_choices) === '["1 hour","24 hours","2 days"]'
      && afterOpen?.opened === true && opened.got.length >= 1 && opened.got.every((f) => isGenericSignal(f, values1, `account:${a.user}`)),
      { by_b: byB.json, state: opened.result.json?.state, choices: opened.result.json?.snooze_choices, opened: afterOpen?.opened,
        frames: opened.got.length });
    const reopened = await expectSignal('reopen', () => open(a.token, item1));
    check('S23-second-open-is-silent', reopened.result.json?.state === 'current' && reopened.got.length === 0,
      { frames: reopened.got.length });

    // ------------------------------------------------------------ snooze and cancellation
    const foreign = await notif(b.token, 'notifications.snooze_item', null, { item_id: item1, choice: '1 hour' });
    const badChoice = await notif(a.token, 'notifications.snooze_item', null, { item_id: item1, choice: '3 hours' });
    const snoozed = await expectSignal('snooze', () => notif(a.token, 'notifications.snooze_item', null, { item_id: item1, choice: '24 hours' }));
    const afterSnooze = await listed(a.token, item1);
    check('S30-member-snoozes-own-item', foreign.code === 'not_found' && badChoice.code === 'validation_failed'
      && badChoice.field_errors?.choice === 'invalid' && snoozed.result.revision === 2 && snoozed.result.data?.clamped === false
      && afterSnooze?.snoozed_until === snoozed.result.data?.scheduled_at && snoozeJobs(item1) === 'pending:-'
      && snoozed.got.length >= 1 && snoozed.got.every((f) => isGenericSignal(f, values1, `account:${a.user}`)),
      { foreign: foreign.code, bad_choice: badChoice.field_errors, revision: snoozed.result.revision, clamped: snoozed.result.data?.clamped,
        listed_matches: afterSnooze?.snoozed_until === snoozed.result.data?.scheduled_at, jobs: snoozeJobs(item1), frames: snoozed.got.length });
    const cancelled = await expectSignal('cancel', () => reminder(a.token, 'fixture.reminder_cancel', 1, { source_id: src1 }));
    const afterCancel = await listed(a.token, item1);
    const openCancelled = await open(a.token, item1);
    check('S31-cancellation-removes-the-snooze', cancelled.result.status === 200 && !cancelled.result.code
      && snoozeJobs(item1) === 'cancelled:source_cancelled' && afterCancel?.snoozed_until === null
      && openCancelled.json?.state === 'superseded' && cancelled.got.length >= 1,
      { jobs: snoozeJobs(item1), snoozed_until: afterCancel?.snoozed_until, state: openCancelled.json?.state, frames: cancelled.got.length });

    // ------------------------------------------------------------ clamp, then a response
    const startsAt = Math.floor((Date.now() + 20 * 3600_000) / 1000) * 1000;
    const scheduled = await reminder(a.token, 'fixture.reminder_schedule', null, { starts_at: utc(startsAt) });
    const src2 = scheduled.data?.source_id;
    const delivered2 = await expectSignal('deliver2', worker);
    const item2 = itemOf(src2);
    const clamp = await expectSignal('snooze2', () => notif(a.token, 'notifications.snooze_item', null, { item_id: item2, choice: '2 days' }));
    check('S40-snooze-clamped-to-the-start', scheduled.data?.enqueued === 1 && delivered2.result.delivered === 1
      && clamp.result.data?.clamped === true && Date.parse(clamp.result.data?.scheduled_at) === startsAt
      && Date.parse(clamp.result.data?.expires_at) === startsAt && clamp.got.length >= 1,
      { enqueued: scheduled.data?.enqueued, delivered: delivered2.result.delivered, clamped: clamp.result.data?.clamped,
        at_start: Date.parse(clamp.result.data?.scheduled_at) === startsAt, frames: clamp.got.length });
    const responded = await expectSignal('respond', () => reminder(a.token, 'fixture.reminder_respond', 1, { source_id: src2 }));
    const afterResponse = await listed(a.token, item2);
    const openResponded = await open(a.token, item2);
    const again = await notif(a.token, 'notifications.snooze_item', null, { item_id: item2, choice: '1 hour' });
    check('S41-response-removes-the-snooze', responded.result.status === 200 && !responded.result.code
      && snoozeJobs(item2) === 'cancelled:responded' && afterResponse?.snoozed_until === null
      && openResponded.json?.state === 'superseded' && !('snooze_choices' in (openResponded.json ?? {}))
      && again.code === 'conflict' && again.field_errors?.item_id === 'superseded' && responded.got.length >= 1,
      { jobs: snoozeJobs(item2), snoozed_until: afterResponse?.snoozed_until, state: openResponded.json?.state,
        snooze_again: again.code, frames: responded.got.length });

    // ------------------------------------------------------------ push off keeps the inbox
    const device = await notif(a.token, 'notifications.register_device', null,
      { token: `fcm-${'t'.repeat(40)}:APA91b`, platform: 'android' });
    const off = await notif(a.token, 'notifications.set_push_category', null,
      { source_type: 'fixture_reminder', reminder_kind: 'fixture_due', push_enabled: false });
    const settingsRead = (await rpc('notifications_my_push_settings', a.token)).json;
    const src3 = (await reminder(a.token, 'fixture.reminder_create', null, { due_at: utc(Date.now() - 60_000) })).data?.source_id;
    const delivered3 = await worker();
    const item3 = itemOf(src3);
    const inInbox = await listed(a.token, item3);
    const pushJobs = Number(psql(`select count(*) from app.notifications_push_jobs where item_id = '${item3 || randomUUID()}'`));
    const category = (settingsRead?.categories ?? []).find((c) => c.reminder_kind === 'fixture_due');
    check('S50-push-off-keeps-in-app-items', device.status === 200 && !device.code && off.revision === 1
      && category?.push_enabled === false && delivered3.delivered === 1 && inInbox !== null && pushJobs === 0,
      { device: device.code ?? 'ok', setting_revision: off.revision, push_enabled: category?.push_enabled,
        categories: (settingsRead?.categories ?? []).map((c) => c.reminder_kind), delivered: delivered3.delivered,
        in_inbox: inInbox !== null, push_jobs: pushJobs });

    // ------------------------------------------------------------ every captured signal
    const everything = [...privateValues(), src1, src2, src3, item1, item2, item3];
    check('S60-every-signal-is-content-free', signals.length >= 6 && signals.every((f) => isGenericSignal(f, everything, `account:${a.user}`))
      && spy.frames.length === 0 && anon.frames.length === 0,
      { captured: signals.length, payloads: [...new Set(signals.map((f) => JSON.stringify(f.payload?.payload)))],
        events: [...new Set(signals.map((f) => f.payload?.event))], to_refused_sockets: spy.frames.length + anon.frames.length });
  } finally {
    for (const s of sockets) s.close();
    const left = cleanup();
    psql(`select app.sys_revoke_credential('${credentialId}', '${OPERATOR}'); select app.sys_disable_principal('${principal}', '${OPERATOR}');`);
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'notifications-screens-e2e';
            delete from app.platform_environment_history where set_by = 'notifications-screens-e2e';`);
    }
    log('S99-cleanup', { users_left: Number(left), credential_revoked: true, principal_disabled: true, unmarked: marked,
      jobs_left: Number(psql(`select count(*) from app.notifications_jobs`)),
      items_left: Number(psql(`select count(*) from app.notifications_inbox_items`)) });
  }
  finish();
}

runMain(import.meta.url, main);
