#!/usr/bin/env node
// Story 3.5 end-to-end on the LOCAL stack: recipients are routed by current access and their
// work is retired on lifecycle events, through real GoTrue phone sign-in (no SMS), the real Data
// API (PostgREST), the real Identity commands and the real worker script
// (tools/notifications/worker.mjs) with a local `notifications_worker` credential:
//   * members register devices and read their push settings (the token is never returned);
//   * an Admin places a hold and deactivates a membership: the held and deactivated members'
//     tokens are retired in Identity's transaction;
//   * an Admin records an accountless member whose contact route is a relative's number (the
//     relative is an active member with a device);
//   * the Admin enqueues SYNTHETIC reminders for the active, held, deactivated and accountless
//     members; one worker run gives the active member the inbox item and a pending member-push
//     job, and the three others a direct-contact need each on the source's route; the relative
//     gets no job, item, push job or need, and no need carries a number;
//   * a lost-device hold (sessions revoked) retires the token and cancels the pending push job;
//   * a member's own deletion request retires tokens, cancels push and pending jobs, and the
//     registered deletion hooks erase everything so the deletion check answers zero.
//
// Needs the local phone switch (`node tools/auth-harness/local-phone-auth.mjs on`, then `off`)
// and a database with no usable Admin (`npx supabase db reset` first). LOCAL only, SYNTHETIC
// fictional numbers +44 7700 900890-900899. Evidence is redacted JSONL: statuses, codes, counts
// and booleans; never tokens, passwords, device tokens, numbers or the credential. Everything it
// created is removed; the credential is revoked and its principal disabled.
//
// Usage: node tools/identity-e2e/routing.mjs [--evidence <file.jsonl>]
import { execFile } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 3.5 E2E';

/** The reserved fictional numbers this run uses (+44 7700 900890-900899). */
export function isFictionalRoutingPhone(phone) {
  return /^\+44770090089[0-9]$/.test(phone);
}

/** A synthetic FCM-shaped device token (never a real one). */
export function syntheticDeviceToken() {
  return `synthetic-${randomBytes(24).toString('base64url')}:APA91b`;
}

/** The values among `values` that appear in `text`. */
export function leaks(text, values) {
  return values.filter((v) => v && String(text).includes(String(v)));
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

  const people = {
    admin: { phone: '+447700900890', name: `${NAME_PREFIX} Admin` },
    active: { phone: '+447700900891', name: `${NAME_PREFIX} Active` },
    held: { phone: '+447700900892', name: `${NAME_PREFIX} Held` },
    leaving: { phone: '+447700900893', name: `${NAME_PREFIX} Deactivated` },
    relative: { phone: '+447700900894', name: `${NAME_PREFIX} Relative` },
    lost: { phone: '+447700900895', name: `${NAME_PREFIX} Lost device` },
    deleting: { phone: '+447700900896', name: `${NAME_PREFIX} Deleting` },
  };
  for (const p of Object.values(people)) if (!isFictionalRoutingPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  const users = new Set();
  const digits = Object.values(people).map((p) => `'${p.phone.slice(1)}'`).join(',');
  const phones = Object.values(people).map((p) => `'${p.phone}'`).join(',');
  const cleanup = () => {
    const ids = [...users].map((u) => `'${u}'`);
    const byUser = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    return psql(`
    create temp table gone_users as select u.id from auth.users u where ${byUser} u.phone in (${digits});
    create temp table gone_members as
      select m.member_id from app.identity_members m
       where m.display_name like '${NAME_PREFIX}%'
          or m.member_id in (select d.member_id from app.identity_deletions d
                              join app.identity_deletion_accounts a on a.deletion_id = d.deletion_id
                             where a.auth_user_id in (select id from gone_users));
    create temp table gone_deletions as
      select d.deletion_id from app.identity_deletions d where d.member_id in (select member_id from gone_members);
    delete from app.notifications_attempts a using app.notifications_jobs j
     where a.job_id = j.job_id and j.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_push_jobs p
     where p.recipient_member_id in (select member_id from gone_members) or p.account_id in (select id from gone_users);
    delete from app.notifications_direct_contact_needs n where n.recipient_member_id in (select member_id from gone_members);
    update app.notifications_jobs j set snoozed_from_item_id = null where j.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_inbox_items i where i.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_jobs j where j.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_schedules s where s.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_device_tokens t
     where t.member_id in (select member_id from gone_members) or t.account_id in (select id from gone_users);
    delete from app.notifications_push_settings s
     where s.member_id in (select member_id from gone_members) or s.account_id in (select id from gone_users);
    delete from app.fixture_reminder_contact_needs n where n.member_id in (select member_id from gone_members);
    delete from app.fixture_reminder_sources s
     where s.member_id in (select member_id from gone_members) or s.created_by_account in (select id from gone_users);
    delete from app.identity_deletion_audit a where a.deletion_id in (select deletion_id from gone_deletions);
    delete from app.identity_deletion_steps s where s.deletion_id in (select deletion_id from gone_deletions);
    delete from app.identity_deletion_accounts a where a.deletion_id in (select deletion_id from gone_deletions);
    delete from app.identity_deletion_aggregates a where a.deletion_id in (select deletion_id from gone_deletions);
    delete from app.identity_deletions d where d.deletion_id in (select deletion_id from gone_deletions);
    delete from app.identity_handover_obligations o where o.member_id in (select member_id from gone_members);
    delete from app.identity_membership_lifecycle e
     where e.member_id in (select member_id from gone_members) or e.actor_member_id in (select member_id from gone_members);
    delete from app.identity_recovery_operations o where o.member_id in (select member_id from gone_members);
    delete from app.identity_recovery_grants g where g.member_id in (select member_id from gone_members);
    delete from app.identity_recovery_cases c where c.member_id in (select member_id from gone_members);
    delete from app.identity_recovery_requests r where r.claimed_phone in (${phones});
    delete from app.identity_recovery_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_membership_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_member_provenance p
     where p.member_id in (select member_id from gone_members) or p.recorded_by_member in (select member_id from gone_members);
    delete from app.identity_contact_routes c
     where c.member_id in (select member_id from gone_members) or c.created_by_member in (select member_id from gone_members);
    delete from app.identity_credential_review_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_access_audit a
     where a.target_member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_grants g where g.member_id in (select member_id from gone_members);
    delete from app.identity_grant_sets s where s.member_id in (select member_id from gone_members);
    delete from app.identity_binding_history h using app.identity_account_links l
     where h.link_id = l.link_id and (l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users));
    delete from app.identity_credential_events e using app.identity_account_links l
     where e.link_id = l.link_id and (l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users));
    delete from app.identity_holds h where h.member_id in (select member_id from gone_members);
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
    psql(`select app.platform_set_environment('local', 'notifications-routing-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  const leftovers = cleanup();
  if (Number(psql(`select app.identity_usable_admin_count()`)) !== 0) {
    throw new Error('the local database already has a usable Admin; run `npx supabase db reset` first');
  }
  log('R00-precondition', { settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: Number(leftovers) });

  const run = randomUUID().slice(0, 8);
  const credential = `sysc_local_${randomBytes(32).toString('base64url')}`;
  const principal = psql(`select app.sys_create_principal('notifications-routing-e2e-${run}', 'notifications_worker', '${OPERATOR}')`);
  const credentialId = JSON.parse(psql(`select app.sys_register_credential('${principal}',
    '${createHash('sha256').update(credential).digest('hex')}', 'routing e2e ${run}', interval '2 hours', '${OPERATOR}')`)).credential_id;
  const workerOut = [];
  const worker = async () => {
    try {
      const { stdout } = await promisify(execFile)('node', [join(ROOT, 'tools/notifications/worker.mjs'), 'run-once'], {
        encoding: 'utf8', env: { PATH: process.env.PATH, SUPABASE_URL: origin, SUPABASE_PUBLISHABLE_KEY: key,
          NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL: credential } });
      workerOut.push(stdout);
      const line = stdout.split('\n').find((l) => l.startsWith('{'));
      return { exit: 0, ...(line ? JSON.parse(line) : {}) };
    } catch (e) {
      workerOut.push(`${e.stdout ?? ''}${e.stderr ?? ''}`);
      return { exit: e.code ?? 1, error: String(e.stderr ?? '').trim().slice(-160) };
    }
  };
  const deviceTokens = [];

  try {
    const { admin, active, held, leaving, relative, lost, deleting } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'notifications-routing-e2e')`);
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}', 'israel')`);
    for (const p of Object.values(people)) p.token = (await signIn(p.phone, p.password)).json?.access_token;
    check('R01-members-signed-in-by-phone', Object.values(people).every((p) => amrMethods(p.token).includes('password')),
      { members: Object.keys(people).length });

    const memberRev = (p) => Number(psql(`select revision from app.identity_members where member_id = '${p.member}'`));
    const notif = (p, cmd, expected, payload) => envelope('notifications_command', p.token, cmd, expected, payload);
    const tokensOf = (memberId) => psql(`select coalesce(string_agg(coalesce(retire_reason, 'live'), ',' order by registered_at), '')
      from app.notifications_device_tokens where member_id = '${memberId}'`);
    const jobState = (jobId) => psql(`select job_state || '|' || coalesce(finish_reason, cancel_reason, '-') from app.notifications_jobs where job_id = '${jobId}'`);
    const pushOf = (jobId) => psql(`select coalesce((select push_state || '|' || coalesce(finish_reason, '-') from app.notifications_push_jobs where job_id = '${jobId}'), 'none')`);
    const forMember = async (memberId, dueMs = Date.now() - 60_000) => {
      const r = await envelope('fixture_reminder_command', admin.token, 'fixture.reminder_create_for', null,
        { member_id: memberId, due_at: utc(dueMs) });
      return { status: r.status, code: r.code ?? null, source: r.data?.source_id,
        job: r.data?.source_id ? psql(`select job_id from app.notifications_jobs where source_id = '${r.data.source_id}'`) : null };
    };

    // ------------------------------------------------------------------ devices and settings
    const registered = [];
    for (const p of [active, held, leaving, relative, lost, deleting]) {
      const t = syntheticDeviceToken();
      deviceTokens.push(t);
      registered.push(await notif(p, 'notifications.register_device', null, { token: t, platform: 'android' }));
    }
    const answers = JSON.stringify(registered);
    check('R10-devices-registered-token-never-returned', registered.every((r) => r.status === 200 && r.revision === 1 && r.data?.device_id)
      && leaks(answers, deviceTokens).length === 0,
      { statuses: registered.map((r) => r.status), keys: Object.keys(registered[0]?.data ?? {}).sort() });
    const read = await rpc('notifications_my_push_settings', active.token);
    const fixtureCategory = (read.json?.categories ?? []).find((c) => c.source_type === 'fixture_reminder' && c.reminder_kind === 'fixture_due');
    check('R11-push-settings-read', read.status === 200 && fixtureCategory?.push_enabled === true && read.json?.devices?.length === 1
      && leaks(JSON.stringify(read.json), deviceTokens).length === 0,
      { status: read.status, category_push: fixtureCategory?.push_enabled ?? null, devices: read.json?.devices?.length ?? null });
    const off = await notif(active, 'notifications.set_push_category', null,
      { source_type: 'fixture_reminder', reminder_kind: 'fixture_due', push_enabled: false });
    const on = await notif(active, 'notifications.set_push_category', off.revision,
      { source_type: 'fixture_reminder', reminder_kind: 'fixture_due', push_enabled: true });
    const stale = await notif(active, 'notifications.set_push_category', off.revision,
      { source_type: 'fixture_reminder', reminder_kind: 'fixture_due', push_enabled: false });
    check('R12-push-category-set-with-revisions', off.status === 200 && off.data?.push_enabled === false && on.data?.push_enabled === true
      && on.revision === 2 && stale.code === 'conflict' && stale.current_revision === 2,
      { off: off.revision, on: on.revision, stale: { code: stale.code, current: stale.current_revision } });

    // ------------------------------------------------------------- holds, deactivation, accountless
    const hold = await envelope('identity_credential_command', admin.token, 'identity.place_hold', memberRev(held),
      { member_id: held.member, reason_code: 'security_concern' });
    const deactivate = await envelope('identity_lifecycle_command', admin.token, 'identity.deactivate_membership', memberRev(leaving),
      { member_id: leaving.member, reason_code: 'church_decision' });
    check('R20-hold-and-deactivation-retire-tokens', hold.status === 200 && !hold.code && deactivate.status === 200 && !deactivate.code
      && tokensOf(held.member) === 'access_hold_applied' && tokensOf(leaving.member) === 'membership_deactivated',
      { hold: hold.code ?? 'ok', deactivate: deactivate.code ?? 'ok', held_tokens: tokensOf(held.member), deactivated_tokens: tokensOf(leaving.member) });
    const heldRegister = await notif(held, 'notifications.register_device', null, { token: syntheticDeviceToken(), platform: 'android' });
    check('R21-held-member-cannot-register', heldRegister.code === 'forbidden', { code: heldRegister.code ?? null });
    const accountless = await envelope('identity_review_command', admin.token, 'identity.create_member', null, {
      full_name: `${NAME_PREFIX} Accountless`, consent_basis: 'leader_assisted', assisted_by_member_id: admin.member,
      contact_route: { phone: relative.phone, belongs_to: 'relative', holder_label: 'Daughter' } });
    const accountlessMember = accountless.data?.member_id;
    check('R22-accountless-member-with-relative-contact', accountless.status === 200 && accountless.data?.account === 'no_login'
      && accountless.data?.contact_routes?.[0]?.belongs_to === 'relative',
      { status: accountless.status, account: accountless.data?.account ?? null });

    // ---------------------------------------------------------------------------- routing
    const jobs = {
      active: await forMember(active.member), held: await forMember(held.member),
      leaving: await forMember(leaving.member), accountless: await forMember(accountlessMember),
    };
    check('R30-reminders-enqueued-through-the-api', Object.values(jobs).every((j) => j.status === 200 && j.job),
      { statuses: Object.fromEntries(Object.entries(jobs).map(([k, j]) => [k, j.status])) });
    const run1 = await worker();
    check('R31-one-worker-run-routes-each-recipient', run1.exit === 0 && run1.delivered === 1 && run1.ineligible === 3,
      { claimed: run1.claimed, delivered: run1.delivered, ineligible: run1.ineligible, failed: run1.failed });
    const inboxActive = await rpc('notifications_my_inbox', active.token);
    const items = (m) => Number(psql(`select count(*) from app.notifications_inbox_items where recipient_member_id = '${m}'`));
    check('R32-inbox-only-for-the-active-member', inboxActive.status === 200 && inboxActive.json?.items?.length === 1
      && items(held.member) === 0 && items(leaving.member) === 0 && items(accountlessMember) === 0,
      { active_items: inboxActive.json?.items?.length ?? null, held: items(held.member), deactivated: items(leaving.member), accountless: items(accountlessMember) });
    const states = Object.fromEntries(Object.entries(jobs).map(([k, j]) => [k, jobState(j.job)]));
    const needs = psql(`select count(*) from app.notifications_direct_contact_needs n
      join app.fixture_reminder_contact_needs f on f.need_id = n.need_id
      where n.route_state = 'routed' and n.recipient_member_id in ('${held.member}', '${leaving.member}', '${accountlessMember}')`);
    check('R33-direct-contact-needs-for-the-others', states.active === 'delivered|delivered' && states.held === 'ineligible|direct_contact'
      && states.leaving === 'ineligible|direct_contact' && states.accountless === 'ineligible|direct_contact' && Number(needs) === 3,
      { states, needs_on_the_source_route: Number(needs) });
    check('R34-member-push-only-for-the-active-account', pushOf(jobs.active.job) === 'pending|-'
      && ['held', 'leaving', 'accountless'].every((k) => pushOf(jobs[k].job) === 'none'),
      { active: pushOf(jobs.active.job), others: ['held', 'leaving', 'accountless'].map((k) => pushOf(jobs[k].job)) });
    const relativeRows = Number(psql(`select (select count(*) from app.notifications_jobs where recipient_member_id = '${relative.member}')
      + (select count(*) from app.notifications_inbox_items where recipient_member_id = '${relative.member}')
      + (select count(*) from app.notifications_push_jobs where recipient_member_id = '${relative.member}')
      + (select count(*) from app.notifications_direct_contact_needs where recipient_member_id = '${relative.member}')`));
    const needText = psql(`select coalesce(string_agg(to_jsonb(n)::text, ' '), '') from app.notifications_direct_contact_needs n`)
      + psql(`select coalesce(string_agg(to_jsonb(n)::text, ' '), '') from app.fixture_reminder_contact_needs n`);
    check('R35-no-job-for-a-relatives-contact', relativeRows === 0 && leaks(needText, [relative.phone.slice(1)]).length === 0,
      { relative_rows: relativeRows, number_in_needs: leaks(needText, [relative.phone.slice(1)]).length });

    // ----------------------------------------------------------------- sessions revoked (lost device)
    const lostJob = await forMember(lost.member);
    const run2 = await worker();
    const pendingBefore = pushOf(lostJob.job);
    const lostHold = await envelope('identity_credential_command', admin.token, 'identity.place_hold', memberRev(lost),
      { member_id: lost.member, reason_code: 'lost_device' });
    const sessionsLeft = Number(psql(`select count(*) from auth.sessions where user_id = '${lost.user}'`));
    check('R40-revoked-sessions-retire-tokens-and-cancel-push', run2.delivered === 1 && pendingBefore === 'pending|-'
      && lostHold.status === 200 && !lostHold.code && sessionsLeft === 0
      && tokensOf(lost.member) === 'access_hold_applied' && pushOf(lostJob.job) === 'cancelled|access_hold_applied'
      && items(lost.member) === 1,
      { push_before: pendingBefore, hold: lostHold.code ?? 'ok', sessions_left: sessionsLeft, tokens: tokensOf(lost.member),
        push_after: pushOf(lostJob.job), items_kept: items(lost.member) });

    // ------------------------------------------------------------------------------ deletion
    const delDue = await forMember(deleting.member);
    const delFuture = await forMember(deleting.member, Date.now() + 2 * 86_400_000);
    const run3 = await worker();
    deleting.token = (await signIn(deleting.phone, deleting.password)).json?.access_token;
    const mine = await envelope('identity_deletion_command', deleting.token, 'identity.request_my_deletion', null,
      { confirm: 'delete_my_account' });
    const deletionId = psql(`select deletion_id from app.identity_deletions where member_id = '${deleting.member}'`);
    check('R50-deletion-request-retires-and-cancels', run3.delivered === 1 && mine.status === 200 && !mine.code
      && /^(membership_deactivated|deletion_requested|sessions_revoked)$/.test(tokensOf(deleting.member))
      && /^cancelled\|/.test(pushOf(delDue.job)) && jobState(delFuture.job) === 'cancelled|member_deleted',
      { request: mine.code ?? 'ok', tokens: tokensOf(deleting.member), push: pushOf(delDue.job), future_job: jobState(delFuture.job) });
    const refused = await forMember(deleting.member);
    check('R51-nothing-enqueued-after-the-request', refused.code === 'validation_failed' && !refused.job, { code: refused.code });
    const hookCounts = (phase) => JSON.parse(psql(`select app.identity_call_deletion_hooks('${deleting.member}', '${deleting.user}', '${deletionId}', '${phase}')`));
    const before = hookCounts('check');
    const erased = hookCounts('erase');
    const after = hookCounts('check');
    const byModule = (rows) => Object.fromEntries(rows.map((r) => [r.module, r.remaining]));
    check('R52-deletion-check-answers-zero', (byModule(before).notifications ?? 0) > 0 && (byModule(before).fixture ?? 0) > 0
      && after.every((r) => r.remaining === 0) && erased.every((r) => r.remaining === 0),
      { before: byModule(before), after: byModule(after) });

    const out = workerOut.join('\n');
    const leaked = leaks(out, [credential, ...Object.values(people).flatMap((p) => [p.member, p.user, p.phone.slice(1)]), ...deviceTokens]);
    check('R60-worker-output-content-free', leaked.length === 0, { leaked_values: leaked.length, lines: workerOut.length });
  } finally {
    const left = cleanup();
    psql(`select app.sys_revoke_credential('${credentialId}', '${OPERATOR}'); select app.sys_disable_principal('${principal}', '${OPERATOR}');`);
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'notifications-routing-e2e';
            delete from app.platform_environment_history where set_by = 'notifications-routing-e2e';`);
    }
    log('R99-cleanup', { users_left: Number(left), credential_revoked: true, principal_disabled: true, unmarked: marked,
      tokens_left: Number(psql(`select count(*) from app.notifications_device_tokens`)),
      needs_left: Number(psql(`select count(*) from app.notifications_direct_contact_needs`)),
      jobs_left: Number(psql(`select count(*) from app.notifications_jobs`)) });
  }
  finish();
}

runMain(import.meta.url, main);
