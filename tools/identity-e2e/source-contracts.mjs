#!/usr/bin/env node
// Story 3.2 end-to-end on the LOCAL stack: registered source contracts, generic payloads and
// authorised deep links, through real GoTrue phone sign-in (no SMS), the real Data API
// (PostgREST), the 1.9 system route and the real worker script (tools/notifications/worker.mjs):
//   * an unregistered reminder kind and a payload with a private field are refused, and nothing is
//     written;
//   * five SYNTHETIC reminders (current, stale revision, cancelled, revoked scope, expired) are
//     delivered; the inbox shows the registered generic title and body;
//   * after the source changes, opening the current item answers `current` with the authorised
//     target, and opening each of the other four answers the generic `superseded` state with no
//     target and no source content; the revised source's new item opens as current;
//   * another member and a signed-out caller cannot open the item.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. LOCAL only (exact origin), SYNTHETIC fictional numbers +44 7700 900840-900849.
// Evidence is redacted JSONL: statuses, codes, states and counts; never tokens, passwords, numbers,
// ids or the credential. Every user, member, link, reminder, job, item and receipt it created is
// removed; the run's credential is revoked and its principal disabled.
//
// Usage: node tools/identity-e2e/source-contracts.mjs [--evidence <file.jsonl>]
import { execFile } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 3.2 E2E';
const ADAPTERS = ['current', 'stale', 'cancelled', 'revoked', 'expired'];
const OPEN_KEYS = ['body', 'delivered_at', 'due_at', 'item_id', 'reminder_kind', 'state', 'target', 'title'];

/** The reserved fictional numbers this run uses (+44 7700 900840-900849). */
export function isFictionalContractsPhone(phone) {
  return /^\+44770090084[0-9]$/.test(phone);
}

/**
 * An opened item in the generic superseded state: exactly the generic fields, no target, and none
 * of the given source values anywhere in the answer.
 */
export function isGenericSuperseded(answer, sourceValues) {
  if (!answer || typeof answer !== 'object') return false;
  const keys = Object.keys(answer).sort();
  const text = JSON.stringify(answer);
  return answer.state === 'superseded' && answer.target === null
    && keys.length === OPEN_KEYS.length && keys.every((k, i) => k === OPEN_KEYS[i])
    && sourceValues.every((v) => !v || !text.includes(String(v)));
}

async function main() {
  const { log, check, finish } = startRun();
  const keys = localKey();
  const { origin, key } = keys;
  const http = localHttp(keys);
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const reminder = (token, cmd, expected, payload) =>
    rpc('fixture_reminder_command', token, { version: 1, command: cmd, request_id: randomUUID(), expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const open = (token, itemId) => rpc('notifications_open_item', token, { item_id: itemId });
  const utc = (ms) => new Date(ms).toISOString();

  const people = {
    a: { phone: '+447700900840', name: `${NAME_PREFIX} Member A` },
    b: { phone: '+447700900841', name: `${NAME_PREFIX} Member B` },
  };
  for (const p of Object.values(people)) if (!isFictionalContractsPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  const users = new Set();
  const digits = Object.values(people).map((p) => `'${p.phone.slice(1)}'`).join(',');
  const cleanup = () => {
    const ids = [...users].map((u) => `'${u}'`);
    const byUser = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    return psql(`
    create temp table gone_users as select u.id from auth.users u where ${byUser} u.phone in (${digits});
    create temp table gone_members as
      select m.member_id from app.identity_members m where m.display_name like '${NAME_PREFIX}%';
    delete from app.notifications_inbox_items i where i.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_attempts a using app.notifications_jobs j
     where a.job_id = j.job_id and j.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_jobs j where j.recipient_member_id in (select member_id from gone_members);
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

  const settings = await http('GET', '/auth/v1/settings');
  if (settings.json?.external?.phone !== true) {
    throw new Error('the local phone provider is off: run `node tools/auth-harness/local-phone-auth.mjs on` first');
  }
  const marker = psql(`select coalesce((select environment from app.platform_environment), '')`);
  let marked = false;
  if (marker === '') {
    psql(`select app.platform_set_environment('local', 'notifications-contracts-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('C00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  const run = randomUUID().slice(0, 8);
  const credential = `sysc_local_${randomBytes(32).toString('base64url')}`;
  const principal = psql(`select app.sys_create_principal('notifications-worker-e2e-${run}', 'notifications_worker', '${OPERATOR}')`);
  const credentialId = JSON.parse(psql(`select app.sys_register_credential('${principal}',
    '${createHash('sha256').update(credential).digest('hex')}', 'contracts e2e ${run}', interval '2 hours', '${OPERATOR}')`)).credential_id;
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
  const itemOf = (sourceId, revision = 1) => psql(`select coalesce((select i.item_id::text from app.notifications_inbox_items i
    join app.notifications_jobs j on j.job_id = i.job_id where j.source_id = '${sourceId}' and j.source_revision = ${revision}), '')`);

  try {
    const { a, b } = people;
    for (const p of [a, b]) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'notifications-contracts-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    check('C01-members-signed-in-by-phone', [a, b].every((p) => amrMethods(p.token).includes('password')),
      { amr: amrMethods(a.token) });
    const sourcesOfA = () => Number(psql(`select count(*) from app.fixture_reminder_sources where member_id = '${a.member}'`));

    // ------------------------------------------------------------------- refusals at the API
    const unregistered = await reminder(a.token, 'fixture.reminder_create', null,
      { due_at: utc(Date.now()), reminder_kind: 'fixture_not_registered' });
    check('C10-unregistered-kind-refused', unregistered.code === 'validation_failed'
      && unregistered.field_errors?.reminder_kind === 'unregistered' && sourcesOfA() === 0,
      { status: unregistered.status, code: unregistered.code, field_errors: unregistered.field_errors, sources: sourcesOfA() });
    const privateField = await reminder(a.token, 'fixture.reminder_create', null,
      { due_at: utc(Date.now()), body: 'pastoral note', recipient_phone: 'x' });
    check('C11-private-field-rejected', privateField.code === 'validation_failed'
      && privateField.field_errors?.body === 'unknown_field' && privateField.field_errors?.recipient_phone === 'unknown_field'
      && sourcesOfA() === 0,
      { code: privateField.code, field_errors: privateField.field_errors, sources: sourcesOfA() });

    // ----------------------------------------------------------- five SYNTHETIC adapters delivered
    const src = {};
    for (const k of ADAPTERS) {
      const r = await reminder(a.token, 'fixture.reminder_create', null, { due_at: utc(Date.now() - 60_000) });
      src[k] = r.data?.source_id;
    }
    const delivered = await worker();
    const inbox = (await rpc('notifications_my_inbox', a.token)).json;
    check('C20-five-delivered', delivered.exit === 0 && delivered.delivered === 5 && inbox?.items?.length === 5,
      { worker: { exit: delivered.exit, delivered: delivered.delivered }, items: inbox?.items?.length });
    check('C21-generic-text-in-inbox', (inbox?.items ?? []).every((i) => i.title === 'SYNTHETIC test reminder'
      && i.body === 'A test reminder is waiting for you.'),
      { titles: [...new Set((inbox?.items ?? []).map((i) => i.title))], keys: Object.keys(inbox?.items?.[0] ?? {}).sort() });

    // ----------------------------------------------------------------------- the sources change
    const changes = {
      stale: await reminder(a.token, 'fixture.reminder_change', 1, { source_id: src.stale, change: 'revise' }),
      cancelled: await reminder(a.token, 'fixture.reminder_cancel', 1, { source_id: src.cancelled }),
      revoked: await reminder(a.token, 'fixture.reminder_change', 1, { source_id: src.revoked, change: 'revoke' }),
      expired: await reminder(a.token, 'fixture.reminder_change', 1, { source_id: src.expired, change: 'expire' }),
    };
    check('C30-sources-changed', Object.values(changes).every((c) => c.status === 200 && !c.code)
      && changes.stale.revision === 2 && changes.cancelled.revision === 2
      && changes.revoked.revision === 1 && changes.expired.revision === 1,
      { revisions: Object.fromEntries(Object.entries(changes).map(([k, c]) => [k, c.revision ?? c.code])) });

    // ----------------------------------------------------------------------------- opening items
    const current = await open(a.token, itemOf(src.current));
    check('C40-current-opens-with-target', current.status === 200 && current.json?.state === 'current'
      && current.json?.target === `/fixture/reminders/${src.current}` && current.json?.title === 'SYNTHETIC test reminder',
      { status: current.status, state: current.json?.state, target_kind: current.json?.target?.split('/').slice(0, 3).join('/') });
    const superseded = {};
    for (const k of ['stale', 'cancelled', 'revoked', 'expired']) {
      const r = await open(a.token, itemOf(src[k]));
      superseded[k] = { status: r.status, generic: r.status === 200 && isGenericSuperseded(r.json, [src[k], a.member]), state: r.json?.state };
    }
    check('C41-superseded-is-generic', Object.values(superseded).every((s) => s.generic), superseded);
    const again = await worker();
    const revised = await open(a.token, itemOf(src.stale, 2));
    check('C42-revised-source-opens-current', again.delivered === 1 && revised.json?.state === 'current'
      && revised.json?.target === `/fixture/reminders/${src.stale}`,
      { worker: { delivered: again.delivered }, state: revised.json?.state });

    // ------------------------------------------------------------------- who may open the item
    const byB = await open(b.token, itemOf(src.current));
    const signedOut = await http('POST', '/rest/v1/rpc/notifications_open_item', { body: { item_id: itemOf(src.current) }, profile: 'api' });
    check('C50-others-cannot-open', byB.status === 200 && JSON.stringify(byB.json) === '{"state":"not_found"}'
      && [401, 403, 404].includes(signedOut.status) && !JSON.stringify(signedOut.json ?? '').includes(src.current),
      { member_b: byB.json, signed_out: signedOut.status });
  } finally {
    const left = cleanup();
    psql(`select app.sys_revoke_credential('${credentialId}', '${OPERATOR}'); select app.sys_disable_principal('${principal}', '${OPERATOR}');`);
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'notifications-contracts-e2e';
            delete from app.platform_environment_history where set_by = 'notifications-contracts-e2e';`);
    }
    log('C99-cleanup', { users_left: Number(left), credential_revoked: true, principal_disabled: true, unmarked: marked,
      jobs_left: Number(psql(`select count(*) from app.notifications_jobs`)),
      items_left: Number(psql(`select count(*) from app.notifications_inbox_items`)) });
  }
  finish();
}

runMain(import.meta.url, main);
