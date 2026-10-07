#!/usr/bin/env node
// Story 2.8 end-to-end on the LOCAL stack: change credentials under review and hold access,
// through real GoTrue (phone sign-in without SMS, native email change, /recover, /verify, PKCE,
// Auth Admin changes), the real Data API (PostgREST) and the stack's Mailpit:
//   * a phone-username change and a recovery-email replacement and removal are requested by the
//     member (fresh password sign-in), approved by an Admin after an identity check and applied to
//     Auth server-side; obsolete sessions are revoked; the new values sign in;
//   * an ownership-dispute hold: the held session reaches only the generic access-review answer;
//     a public forgot-password request, a reset, a login, a direct Auth change and an email
//     verification never clear the hold or approve a binding; only another Admin's release does,
//     and only a reviewed restore approves the account's credentials again;
//   * a lost-device hold revokes every session and calls the registered (SYNTHETIC fixture)
//     device-registration hook in the same transaction;
//   * the stolen-session PUT /user email change (2.7 carried risk) is resolved by restore; a 2.7
//     `other_changes` case is resolved by reject + accept.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on` (no SMS
// provider, hook, test OTP or SMS MFA), then `off` afterwards. Needs Mailpit (part of
// `supabase start`) and a database with no usable Admin (`npx supabase db reset` first).
// LOCAL only (exact origin), SYNTHETIC fictional numbers +44 7700 900330-900349 and
// @example.test addresses. Evidence is redacted JSONL: statuses, codes and booleans; never
// tokens, codes, links, passwords, numbers or addresses. Everything it created is removed.
//
// Usage: node tools/identity-e2e/credentials.mjs [--evidence <file.jsonl>]
import { execFileSync } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import { appendFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import { MAILPIT, MOBILE_EMAIL_CONFIRMED, MOBILE_RECOVERY, codeFrom, pkcePair, redirectFacts } from './recovery.mjs';
import { amrMethods, assertLocalOrigin, redact } from './run.mjs';

/** The reserved fictional numbers this run uses (+44 7700 900330-900349). */
export function isFictionalCredentialPhone(phone) {
  return /^\+4477009003[34][0-9]$/.test(phone);
}

/** Keys the member's own credentials read may carry: it never says why access is in review. */
export const MY_CREDENTIALS_KEYS = ['access', 'can_request', 'church_contact', 'last_change', 'pending_change',
  'pending_recovery_email', 'phone_username', 'recent_sign_in_minutes', 'recovery_email'];

/** Keys of the member's own read that are not in the allowlist (a reason would leak here). */
export function unexpectedKeys(read) {
  return Object.keys(read ?? {}).filter((k) => !MY_CREDENTIALS_KEYS.includes(k)).sort();
}

const NAME_PREFIX = 'SYNTHETIC 2.8 E2E';
const EPOCH_WAIT_MS = 6500; // the 2.2 trust-epoch margin is 5 s
const RESEND_WAIT_MS = 1200; // local max_frequency is 1 s per address

function localKey() {
  const env = execFileSync('npx', ['supabase', 'status', '-o', 'env'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  const url = /^API_URL="([^"]+)"/m.exec(env)?.[1];
  const key = /^PUBLISHABLE_KEY="([^"]+)"/m.exec(env)?.[1];
  const secret = /^SECRET_KEY="([^"]+)"/m.exec(env)?.[1];
  const service = /^SERVICE_ROLE_KEY="([^"]+)"/m.exec(env)?.[1];
  if (!url || !key || !secret || !service) throw new Error('local stack is not running');
  return { origin: assertLocalOrigin(url), key, secret, service };
}

function psql(sql) {
  const name = execFileSync('docker', ['ps', '--filter', 'name=supabase_db_', '--format', '{{.Names}}'], { encoding: 'utf8' }).trim().split('\n')[0];
  return execFileSync('docker', ['exec', '-i', name, 'psql', '-U', 'postgres', '-X', '-qtA', '-v', 'ON_ERROR_STOP=1', '-c', sql], { encoding: 'utf8' }).trim();
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const evidenceIdx = process.argv.indexOf('--evidence');
  const evidence = evidenceIdx > 0 ? process.argv[evidenceIdx + 1] : null;
  if (evidence) writeFileSync(evidence, '');
  const { origin, key, secret, service } = localKey();
  const results = [];
  const log = (step, data) => {
    const line = { step, target: 'LOCAL', at: new Date().toISOString(), ...redact(data) };
    if (evidence) appendFileSync(evidence, JSON.stringify(line) + '\n');
    console.log(JSON.stringify(line));
  };
  const check = (step, ok, data) => {
    results.push({ step, ok });
    log(step, { verdict: ok ? 'pass' : 'FAIL', ...data });
  };
  async function http(method, path, { token, body, profile, admin } = {}) {
    const headers = { apikey: admin ? secret : key, 'Content-Type': 'application/json' };
    if (admin) headers.Authorization = `Bearer ${service}`;
    else if (token) headers.Authorization = `Bearer ${token}`;
    if (profile) headers[method === 'GET' ? 'Accept-Profile' : 'Content-Profile'] = profile;
    const res = await fetch(`${origin}${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined, redirect: 'manual' });
    const text = await res.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { /* non-JSON */ }
    return { status: res.status, json, location: res.headers.get('location') };
  }
  const password = () => `Synthetic-${randomBytes(12).toString('base64url')}`;
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const refresh = (rt) => http('POST', '/auth/v1/token?grant_type=refresh_token', { body: { refresh_token: rt } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const envelope = (fn, token, cmd, expected, payload, requestId = randomUUID()) =>
    rpc(fn, token, { version: 1, command: cmd, request_id: requestId, expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const credCmd = (token, cmd, expected, payload) => envelope('identity_credential_command', token, cmd, expected, payload);
  const recoveryCmd = (token, cmd, expected, payload) => envelope('identity_recovery_email_command', token, cmd, expected, payload);
  const summary = async (token) => {
    const r = await rpc('identity_my_member_summary', token);
    return { status: r.status, detail: r.json?.details ?? null, has_recovery_email: r.json?.has_recovery_email ?? null };
  };
  // The approved username the summary reports (compared in memory, never logged).
  const usernameOf = async (token) => (await rpc('identity_my_member_summary', token)).json?.phone_username ?? null;
  const mine = async (token) => {
    const r = await rpc('identity_my_credentials', token);
    return { status: r.status, json: r.json };
  };
  const queue = async (token) => (await rpc('identity_admin_credential_queue', token)).json ?? {};
  const recover = (email, redirectTo, pkce) => http('POST',
    `/auth/v1/recover${redirectTo ? `?redirect_to=${encodeURIComponent(redirectTo)}` : ''}`,
    { body: { email, ...(pkce ? { code_challenge: pkce.challenge, code_challenge_method: 's256' } : {}) } });
  const exchange = (code, verifier) => http('POST', '/auth/v1/token?grant_type=pkce', { body: { auth_code: code, code_verifier: verifier } });
  const openLink = async (link) => {
    if (!link?.startsWith(`${origin}/auth/v1/verify?`)) return { status: null, location: null };
    const res = await fetch(link, { redirect: 'manual' });
    return { status: res.status, location: res.headers.get('location') };
  };
  async function mailTo(address, since, { waitMs = 4000 } = {}) {
    const deadline = Date.now() + waitMs;
    for (;;) {
      const r = await fetch(`${MAILPIT}/api/v1/search?query=${encodeURIComponent(`to:"${address}"`)}&limit=50`);
      const list = r.ok ? await r.json() : { messages: [] };
      const fresh = (list.messages || []).filter((m) => Date.parse(m.Created) >= since - 200)
        .sort((a, b) => Date.parse(b.Created) - Date.parse(a.Created));
      if (fresh.length) {
        const msg = await (await fetch(`${MAILPIT}/api/v1/message/${fresh[0].ID}`)).json();
        const text = `${msg.Text || ''}\n${(msg.HTML || '').replace(/&amp;/g, '&')}`;
        const link = text.match(/https?:\/\/[^\s"'<>)\]]+/g)?.find((l) => l.startsWith(`${origin}/auth/v1/verify?`)) ?? null;
        return { subject: msg.Subject, link, count: fresh.length };
      }
      if (Date.now() > deadline) return null;
      await sleep(250);
    }
  }
  const mailFacts = (m) => ({ mail: Boolean(m), has_link: Boolean(m?.link) });

  const run = randomBytes(4).toString('hex');
  const mail = (tag) => `synthetic-2-8-${tag}-${run}@example.test`;
  const people = {
    admin: { phone: '+447700900330', name: `${NAME_PREFIX} Admin` },
    phone: { phone: '+447700900331', name: `${NAME_PREFIX} Phone`, next: '+447700900340' },
    replace: { phone: '+447700900332', name: `${NAME_PREFIX} Replace`, email: mail('replace'), next: mail('replace-new') },
    remove: { phone: '+447700900333', name: `${NAME_PREFIX} Remove`, email: mail('remove') },
    held: { phone: '+447700900334', name: `${NAME_PREFIX} Held`, email: mail('held'), direct: '+447700900341' },
    lost: { phone: '+447700900335', name: `${NAME_PREFIX} Lost`, email: mail('lost') },
    stolen: { phone: '+447700900336', name: `${NAME_PREFIX} Stolen`, thief: mail('thief') },
    other: { phone: '+447700900337', name: `${NAME_PREFIX} Other`, email: mail('other'), direct: '+447700900342' },
    pw: { phone: '+447700900338', name: `${NAME_PREFIX} Password`, email: mail('pw') },
    link: { phone: '+447700900339', name: `${NAME_PREFIX} Link`, email: mail('link'), direct: '+447700900343' },
    rej: { phone: '+447700900344', name: `${NAME_PREFIX} Reject`, email: mail('rej'), next: mail('rej-new') },
  };
  for (const p of Object.values(people)) {
    for (const n of [p.phone, p.next, p.direct].filter((x) => x?.startsWith('+'))) {
      if (!isFictionalCredentialPhone(n)) throw new Error(`not fictional: ${n}`);
    }
  }
  const users = new Set();
  const digits = [...new Set(Object.values(people).flatMap((p) => [p.phone, p.next, p.direct])
    .filter((x) => x?.startsWith('+')).map((x) => `'${x.slice(1)}'`))].join(',');
  const addresses = Object.values(people).flatMap((p) => [p.email, p.next, p.thief]).filter((x) => x?.includes('@'));
  // (pw, link and rej also receive reset mail; their addresses are in the list above.)
  const unhook = () => psql(`delete from app.contract_lifecycle_hooks where module = 'fixture'
                               and event in ('access_hold_applied', 'access_hold_released', 'sessions_revoked')`);
  const cleanup = () => {
    const ids = [...users].map((u) => `'${u}'`);
    const byUser = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    return psql(`
    create temp table gone_users as select u.id from auth.users u
     where ${byUser} u.phone in (${digits}) or u.email like 'synthetic-2-8-%@example.test';
    create temp table gone_members as
      select m.member_id from app.identity_members m where m.display_name like '${NAME_PREFIX}%';
    create temp table gone_apps as
      select a.application_id from app.identity_membership_applications a
       where a.auth_user_id in (select id from gone_users) or a.full_name like '${NAME_PREFIX}%';
    delete from app.fixture_lifecycle_calls c where c.member_id in (select member_id from gone_members);
    delete from app.identity_credential_review_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_credential_changes c
     where c.member_id in (select member_id from gone_members) or c.auth_user_id in (select id from gone_users);
    delete from app.identity_credential_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_recovery_email_proposals p
     where p.member_id in (select member_id from gone_members) or p.auth_user_id in (select id from gone_users);
    delete from app.identity_membership_audit a
     where a.application_id in (select application_id from gone_apps)
        or a.member_id in (select member_id from gone_members)
        or a.actor_member_id in (select member_id from gone_members)
        or a.target_account_id in (select id from gone_users);
    delete from app.identity_member_provenance p
     where p.member_id in (select member_id from gone_members) or p.application_id in (select application_id from gone_apps);
    delete from app.identity_application_events e where e.application_id in (select application_id from gone_apps);
    delete from app.identity_membership_applications a where a.application_id in (select application_id from gone_apps);
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
    delete from auth.flow_state f where f.user_id in (select id from gone_users);
    delete from auth.users u where u.id in (select id from gone_users);
    select count(*) from auth.users u where ${byUser} u.phone in (${digits}) or u.email like 'synthetic-2-8-%@example.test';`);
  };
  const clearMail = async () => {
    const ids = [];
    for (const a of addresses) {
      const r = await fetch(`${MAILPIT}/api/v1/search?query=${encodeURIComponent(`to:"${a}"`)}&limit=200`);
      if (r.ok) ids.push(...((await r.json()).messages || []).map((m) => m.ID));
    }
    if (ids.length) await fetch(`${MAILPIT}/api/v1/messages`, { method: 'DELETE', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ IDs: ids }) });
    return ids.length;
  };

  const settings = await http('GET', '/auth/v1/settings');
  if (settings.json?.external?.phone !== true) {
    throw new Error('the local phone provider is off: run `node tools/auth-harness/local-phone-auth.mjs on` first');
  }
  const mailpitUp = await fetch(`${MAILPIT}/api/v1/info`).then((r) => r.ok).catch(() => false);
  if (!mailpitUp) throw new Error('Mailpit is not reachable on 127.0.0.1:54324 (supabase start includes it)');
  const marker = psql(`select coalesce((select environment from app.platform_environment), '')`);
  let marked = false;
  if (marker === '') {
    psql(`select app.platform_set_environment('local', 'identity-credentials-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('C00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    mailpit: mailpitUp,
    leftover_users_removed: cleanup(),
  });
  if (Number(psql(`select app.identity_usable_admin_count()`)) !== 0) {
    throw new Error('the local database already has a usable Admin; run `npx supabase db reset` first');
  }
  if (Number(psql(`select count(*) from app.contract_lifecycle_hooks where module = 'fixture'
                    and event in ('access_hold_applied', 'access_hold_released', 'sessions_revoked')`)) !== 0) {
    throw new Error('a fixture hold hook is already registered');
  }

  try {
    const { admin, phone, replace, remove, held, lost, stolen, other, pw, link, rej } = people;
    psql(`select app.contract_register_lifecycle_hook('fixture', 'access_hold_applied', 'app.fixture_record_lifecycle(jsonb)'::regprocedure);
          select app.contract_register_lifecycle_hook('fixture', 'access_hold_released', 'app.fixture_record_lifecycle(jsonb)'::regprocedure);
          select app.contract_register_lifecycle_hook('fixture', 'sessions_revoked', 'app.fixture_record_lifecycle(jsonb)'::regprocedure);`);
    const calls = (p) => psql(`select coalesce(string_agg(event, ',' order by call_id), '') from app.fixture_lifecycle_calls where member_id = '${p.member}'`);
    // A member's own reset through the approved email (PKCE, mobile link), then a new password.
    const ownReset = async (p) => {
      const pk = pkcePair();
      await sleep(RESEND_WAIT_MS);
      const at = Date.now();
      await recover(p.email, MOBILE_RECOVERY, pk);
      const m = await mailTo(p.email, at);
      const opened = await openLink(m?.link);
      const ex = await exchange(codeFrom(opened.location), pk.verifier);
      const next = password();
      const set = await http('PUT', '/auth/v1/user', { token: ex.json?.access_token, body: { password: next } });
      if (set.status === 200) p.password = next;
      return { exchange: ex.status, set_password: set.status };
    };
    const seeded = async (p, { email } = {}) => {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: {
        phone: p.phone, phone_confirm: true, password: p.password, ...(email ? { email, email_confirm: true } : {}) } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'identity-credentials-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
      return created.status;
    };
    const memberRev = (p) => Number(psql(`select revision from app.identity_members where member_id = '${p.member}'`));
    const onMember = (cmd, p, payload = {}, token = admin.token) =>
      credCmd(token, cmd, memberRev(p), { member_id: p.member, ...payload });
    const authRow = (p) => psql(`select coalesce(phone, '') || '|' || coalesce(email, '') || '|' || (email_confirmed_at is not null)::text from auth.users where id = '${p.user}'`);
    const sessions = (p) => Number(psql(`select count(*) from auth.sessions where user_id = '${p.user}'`));

    await seeded(admin);
    psql(`select app.identity_bootstrap_admin('${admin.member}', 'israel')`);
    admin.token = (await signIn(admin.phone, admin.password)).json?.access_token;
    const adminAccess = await rpc('identity_my_access', admin.token);
    check('C01-admin-signed-in-by-phone', amrMethods(admin.token).includes('password') && adminAccess.json?.roles?.includes('admin'),
      { amr: amrMethods(admin.token), roles: adminAccess.json?.roles });

    // ------------------------------------------------------------- phone username change
    await seeded(phone);
    const older = await signIn(phone.phone, phone.password); // a second device
    const asked = await credCmd(phone.token, 'identity.request_credential_change', null,
      { change_kind: 'phone_username', phone_username: phone.next });
    const before = await summary(phone.token);
    const memberApproves = await credCmd(older.json?.access_token, 'identity.approve_credential_change', asked.revision,
      { change_id: asked.data?.change_id, identity_check: 'in_person' });
    const item = (await queue(admin.token)).changes?.find((c) => c.change_id === asked.data?.change_id);
    const approved = await credCmd(admin.token, 'identity.approve_credential_change', item?.revision,
      { change_id: item?.change_id, identity_check: 'in_person' });
    const oldSession = await summary(phone.token);
    const oldRefresh = await refresh(older.json?.refresh_token);
    const oldNumber = await signIn(phone.phone, phone.password);
    await sleep(EPOCH_WAIT_MS);
    const newNumber = await signIn(phone.next, phone.password);
    const after = await summary(newNumber.json?.access_token);
    check('C10-phone-username-change-under-review', asked.status === 200 && asked.data?.state === 'pending'
      && before.status === 200 && memberApproves.code === 'forbidden' && item?.phone_available === true
      && approved.status === 200 && approved.data?.state === 'approved'
      && oldSession.status === 401 && oldRefresh.status >= 400 && oldNumber.status === 400
      && newNumber.status === 200 && after.status === 200 && (await usernameOf(newNumber.json?.access_token)) === phone.next
      && calls(phone) === 'sessions_revoked',
      { request: asked.data?.state, access_until_approved: before.status, member_approves: memberApproves.code,
        queue_item: { phone_available: item?.phone_available, other_changes: item?.other_changes },
        approve: approved.data?.state, older_session: oldSession, older_refresh: oldRefresh.status,
        old_number_sign_in: oldNumber.status, new_number_sign_in: newNumber.status, new_number_summary: after.status,
        lifecycle_hook_calls: calls(phone),
        sms_sent: false });

    // --------------------------------------------------- recovery email replaced under review
    await seeded(replace, { email: replace.email });
    const rAsk = await credCmd(replace.token, 'identity.request_credential_change', null,
      { change_kind: 'recovery_email_replace', email: replace.next });
    const rReview = await summary(replace.token);
    const rMine = await mine(replace.token);
    const confirmAt = Date.now();
    const update = await http('PUT', `/auth/v1/user?redirect_to=${encodeURIComponent(MOBILE_EMAIL_CONFIRMED)}`,
      { token: replace.token, body: { email: replace.next } });
    const newMail = await mailTo(replace.next, confirmAt);
    const oldMail = await mailTo(replace.email, confirmAt, { waitMs: 1500 });
    const confirmed = await openLink(newMail?.link);
    await sleep(RESEND_WAIT_MS);
    const verifiedSummary = await summary(replace.token);
    const pkceEarly = pkcePair();
    const earlyAt = Date.now();
    await recover(replace.next, MOBILE_RECOVERY, pkceEarly);
    const earlyMail = await mailTo(replace.next, earlyAt);
    const earlyOpen = redirectFacts((await openLink(earlyMail?.link)).location);
    check('C20-replacement-waits-in-review-verification-approves-nothing', rAsk.status === 200 && rAsk.data?.state === 'pending'
      && rReview.status === 403 && rReview.detail === 'review_required' && rMine.json?.access === 'review_required'
      && unexpectedKeys(rMine.json).length === 0 && update.status === 200 && Boolean(newMail?.link) && !oldMail
      && confirmed.status === 303 && verifiedSummary.status === 403 && Boolean(earlyMail?.link) && !earlyOpen.has_code,
      { request: rAsk.data?.state, summary_in_review: rReview, own_read_access: rMine.json?.access,
        own_read_extra_keys: unexpectedKeys(rMine.json), update_user: update.status, new_address_mail: mailFacts(newMail),
        old_address_mail: Boolean(oldMail), confirm_redirect: confirmed.status, after_verification: verifiedSummary,
        reset_to_unapproved_new_address: { mail: mailFacts(earlyMail), has_code: earlyOpen.has_code } });

    const rItem = (await queue(admin.token)).changes?.find((c) => c.change_id === rAsk.data?.change_id);
    const rApprove = await credCmd(admin.token, 'identity.approve_credential_change', rItem?.revision,
      { change_id: rItem?.change_id, identity_check: 'established_relationship' });
    await sleep(EPOCH_WAIT_MS);
    replace.token = (await signIn(replace.phone, replace.password)).json?.access_token;
    const rAfter = await summary(replace.token);
    await sleep(RESEND_WAIT_MS);
    const oldAt = Date.now();
    await recover(replace.email, MOBILE_RECOVERY, pkcePair());
    const oldReset = await mailTo(replace.email, oldAt, { waitMs: 2000 });
    check('C21-replacement-approved', rItem?.verified === true && rItem?.other_changes === false && rApprove.status === 200
      && rApprove.data?.state === 'approved' && rAfter.status === 200 && rAfter.has_recovery_email === true && !oldReset,
      { queue_item: { verified: rItem?.verified, other_changes: rItem?.other_changes }, approve: rApprove.data?.state,
        fresh_sign_in: rAfter, reset_mail_to_old_address: Boolean(oldReset) });

    // ------------------------------------------------------------------ recovery email removed
    await seeded(remove, { email: remove.email });
    const dAsk = await credCmd(remove.token, 'identity.request_credential_change', null, { change_kind: 'recovery_email_remove' });
    const dBefore = await summary(remove.token);
    const dApprove = await credCmd(admin.token, 'identity.approve_credential_change', dAsk.revision,
      { change_id: dAsk.data?.change_id, identity_check: 'in_person' });
    await sleep(EPOCH_WAIT_MS);
    remove.token = (await signIn(remove.phone, remove.password)).json?.access_token;
    const dAfter = await summary(remove.token);
    await sleep(RESEND_WAIT_MS);
    const dAt = Date.now();
    await recover(remove.email, MOBILE_RECOVERY, pkcePair());
    const dReset = await mailTo(remove.email, dAt, { waitMs: 2000 });
    check('C22-removal-approved', dAsk.status === 200 && dBefore.status === 200 && dApprove.status === 200
      && dApprove.data?.state === 'approved' && authRow(remove).endsWith('||false') && dAfter.status === 200
      && dAfter.has_recovery_email === false && !dReset,
      { request: dAsk.data?.state, access_until_approved: dBefore.status, approve: dApprove.data?.state,
        auth_email_cleared: authRow(remove).endsWith('||false'), fresh_sign_in: dAfter, reset_mail: Boolean(dReset) });

    // -------------------------------------- hold: ownership dispute, nothing but release clears it
    await seeded(held, { email: held.email });
    const memberHolds = await onMember('identity.place_hold', remove, { reason_code: 'security_concern' }, held.token);
    const selfHold = await onMember('identity.place_hold', admin, { reason_code: 'security_concern' });
    const hold = await onMember('identity.place_hold', held, { reason_code: 'ownership_dispute' });
    const hSummary = await summary(held.token);
    const hMine = await mine(held.token);
    check('C30-dispute-hold-help-only', memberHolds.code === 'forbidden' && selfHold.code === 'forbidden'
      && hold.status === 200 && hold.data?.holds?.[0]?.hold_kind === 'access_review'
      && hSummary.status === 403 && hSummary.detail === 'review_required'
      && hMine.status === 200 && hMine.json?.access === 'review_required' && unexpectedKeys(hMine.json).length === 0,
      { member_places_hold: memberHolds.code, admin_holds_self: selfHold.code, hold: hold.data?.holds?.[0]?.hold_kind,
        held_session: hSummary, own_read_access: hMine.json?.access, own_read_extra_keys: unexpectedKeys(hMine.json) });

    // A public forgot-password request, a reset and a login: the hold stays.
    const pkceHeld = pkcePair();
    await sleep(RESEND_WAIT_MS);
    const hAt = Date.now();
    const hRecover = await recover(held.email, MOBILE_RECOVERY, pkceHeld);
    const hMail = await mailTo(held.email, hAt);
    const hOpen = await openLink(hMail?.link);
    const hExchange = await exchange(codeFrom(hOpen.location), pkceHeld.verifier);
    const hPassword = password();
    const hSet = await http('PUT', '/auth/v1/user', { token: hExchange.json?.access_token, body: { password: hPassword } });
    held.password = hPassword;
    await sleep(EPOCH_WAIT_MS);
    held.token = (await signIn(held.phone, held.password)).json?.access_token;
    const hAfterReset = await summary(held.token);
    // A direct Auth change (Auth Admin API): the hold stays and nothing is approved.
    const hDirect = await http('PUT', `/auth/v1/admin/users/${held.user}`, { admin: true, body: { phone: held.direct, phone_confirm: true } });
    const holdOpen = () => Number(psql(`select count(*) from app.identity_holds where member_id = '${held.member}' and released_at is null`));
    const openAfterDirect = holdOpen();
    const reviewFlag = psql(`select binding_review_required from app.identity_account_links where member_id = '${held.member}' and link_state <> 'ended'`);
    check('C31-forgot-password-reset-login-direct-change-never-clear-hold', hRecover.status === 200 && hExchange.status === 200
      && hSet.status === 200 && hAfterReset.status === 403 && hAfterReset.detail === 'review_required'
      && hDirect.status === 200 && openAfterDirect === 1 && reviewFlag === 't',
      { recover: hRecover.status, reset_session: hExchange.status, set_password: hSet.status, fresh_login_after_reset: hAfterReset,
        direct_auth_change: hDirect.status, open_holds: openAfterDirect, binding_review_pending: reviewFlag === 't' });

    const releaseNoCheck = await onMember('identity.release_hold', held, { hold_id: hold.data?.holds?.[0]?.hold_id });
    const release = await onMember('identity.release_hold', held, { hold_id: hold.data?.holds?.[0]?.hold_id, identity_check: 'in_person' });
    await sleep(EPOCH_WAIT_MS);
    const directToken = (await signIn(held.direct, held.password)).json?.access_token;
    const afterRelease = await summary(directToken);
    const restore = await onMember('identity.restore_credentials', held, { identity_check: 'in_person' });
    const directAfterRestore = await signIn(held.direct, held.password);
    await sleep(EPOCH_WAIT_MS);
    held.token = (await signIn(held.phone, held.password)).json?.access_token;
    const restored = await summary(held.token);
    const heldCalls = calls(held);
    check('C32-release-needs-check-binding-only-by-review', releaseNoCheck.code === 'validation_failed' && release.status === 200
      && afterRelease.status === 403 && afterRelease.detail === 'review_required' && restore.status === 200
      && directAfterRestore.status === 400 && restored.status === 200
      && heldCalls === 'access_hold_applied,access_hold_released,sessions_revoked',
      { release_without_check: releaseNoCheck.code, release: release.status, after_release_still_review: afterRelease,
        restore: restore.status, direct_number_after_restore: directAfterRestore.status, approved_number: restored,
        lifecycle_hook_calls: heldCalls });

    // ----------------------------------------------------------------------- lost device
    await seeded(lost, { email: lost.email });
    const deviceB = await signIn(lost.phone, lost.password);
    const lostHold = await onMember('identity.place_hold', lost, { reason_code: 'lost_device' });
    const aSummary = await summary(lost.token);
    const bRefresh = await refresh(deviceB.json?.refresh_token);
    const lostCalls = calls(lost);
    const sameTx = psql(`select count(distinct xact_id) = 1 from app.fixture_lifecycle_calls where member_id = '${lost.member}'`);
    const newDevice = await signIn(lost.phone, lost.password);
    const newDeviceSummary = await summary(newDevice.json?.access_token);
    check('C40-lost-device-revokes-sessions-and-calls-hook', lostHold.status === 200 && lostHold.data?.holds?.[0]?.hold_kind === 'security'
      && aSummary.status === 401 && bRefresh.status >= 400 && lostCalls === 'access_hold_applied,sessions_revoked' && sameTx === 't'
      && newDeviceSummary.status === 403 && newDeviceSummary.detail === 'review_required',
      { hold: lostHold.data?.holds?.[0]?.hold_kind, device_a: aSummary, device_b_refresh: bRefresh.status,
        lifecycle_hook_calls: lostCalls, sessions_revoked: Number(psql(`select sessions_revoked from app.identity_holds where member_id = '${lost.member}'`)),
        new_device_during_hold: newDeviceSummary });
    const releaseFirst = await onMember('identity.release_hold', lost, { hold_id: lostHold.data?.holds?.[0]?.hold_id, identity_check: 'established_relationship' });
    const lostReset = await ownReset(lost);
    const lostRelease = await onMember('identity.release_hold', lost, { hold_id: lostHold.data?.holds?.[0]?.hold_id, identity_check: 'established_relationship' });
    await sleep(EPOCH_WAIT_MS);
    const holdTimeSession = await summary(newDevice.json?.access_token);
    lost.token = (await signIn(lost.phone, lost.password)).json?.access_token;
    const lostAfter = await summary(lost.token);
    check('C41-release-only-after-the-members-own-reset', releaseFirst.field_errors?.hold_id === 'password_reset_required'
      && lostReset.set_password === 200 && lostRelease.status === 200 && holdTimeSession.status === 401 && lostAfter.status === 200,
      { release_before_reset: releaseFirst.field_errors, own_reset: lostReset, release: lostRelease.status,
        session_opened_during_hold: holdTimeSession, fresh_sign_in: lostAfter });

    // --------------------------------------- stolen-session email change (2.7 carried risk)
    await seeded(stolen);
    const thiefSession = await signIn(stolen.phone, stolen.password); // the stolen refresh token
    const thiefAt = Date.now();
    const thiefChange = await http('PUT', `/auth/v1/user?redirect_to=${encodeURIComponent(MOBILE_EMAIL_CONFIRMED)}`,
      { token: thiefSession.json?.access_token, body: { email: stolen.thief } });
    const thiefMail = await mailTo(stolen.thief, thiefAt);
    await openLink(thiefMail?.link);
    const sReview = await summary(stolen.token);
    const sItem = (await queue(admin.token)).reviews?.find((r) => r.member_id === stolen.member);
    const sRestore = await onMember('identity.restore_credentials', stolen, { identity_check: 'in_person' });
    const thiefRefresh = await refresh(thiefSession.json?.refresh_token);
    const authAfter = authRow(stolen);
    await sleep(EPOCH_WAIT_MS);
    stolen.token = (await signIn(stolen.phone, stolen.password)).json?.access_token;
    const sAfter = await summary(stolen.token);
    check('C50-stolen-session-email-change-resolved-by-restore', thiefChange.status === 200 && Boolean(thiefMail?.link)
      && sReview.status === 403 && sReview.detail === 'review_required'
      && sItem?.binding_review === true && sItem?.change_kinds?.includes('email') && sRestore.status === 200
      && thiefRefresh.status >= 400 && authAfter.endsWith('||false') && sAfter.status === 200,
      { direct_email_change: thiefChange.status, member_session: sReview,
        queue: { binding_review: sItem?.binding_review, change_kinds: sItem?.change_kinds }, restore: sRestore.status,
        thief_refresh: thiefRefresh.status, auth_email_removed: authAfter.endsWith('||false'), fresh_sign_in: sAfter });

    // --------------------------------------- 2.7 other_changes: reject, then accept the phone
    await seeded(other);
    const oProposal = await recoveryCmd(other.token, 'identity.propose_recovery_email', null, { email: other.email });
    const oAt = Date.now();
    await http('PUT', `/auth/v1/user?redirect_to=${encodeURIComponent(MOBILE_EMAIL_CONFIRMED)}`, { token: other.token, body: { email: other.email } });
    await openLink((await mailTo(other.email, oAt))?.link);
    await http('PUT', `/auth/v1/admin/users/${other.user}`, { admin: true, body: { phone: other.direct, phone_confirm: true } });
    const oItem = (await rpc('identity_admin_recovery_email_queue', admin.token)).json?.proposals?.find((p) => p.member_id === other.member);
    const oApprove = await recoveryCmd(admin.token, 'identity.approve_recovery_email', oItem?.revision,
      { proposal_id: oItem?.proposal_id, identity_check: 'in_person' });
    const oRestoreWhilePending = await onMember('identity.restore_credentials', other, { identity_check: 'in_person' });
    const oReject = await recoveryCmd(admin.token, 'identity.reject_recovery_email', oItem?.revision, { proposal_id: oItem?.proposal_id });
    const oAccept = await onMember('identity.accept_credentials', other, { identity_check: 'established_relationship' });
    await sleep(EPOCH_WAIT_MS);
    const oSignIn = await signIn(other.direct, other.password);
    const oAfter = await summary(oSignIn.json?.access_token);
    check('C60-other-changes-have-a-reviewed-path', oProposal.status === 200 && oApprove.field_errors?.proposal_id === 'other_changes'
      && oRestoreWhilePending.field_errors?.member_id === 'pending_change' && oReject.status === 200 && oAccept.status === 200
      && oSignIn.status === 200 && oAfter.status === 200 && (await usernameOf(oSignIn.json?.access_token)) === other.direct
      && oAfter.has_recovery_email === false,
      { approve_email: oApprove.field_errors, restore_while_pending: oRestoreWhilePending.field_errors, reject: oReject.data?.state,
        accept: oAccept.status, accepted_number_sign_in: oSignIn.status, summary: oAfter.status });

    // ------------------------- a password changed by a stolen session: restore keeps a hold
    await seeded(pw, { email: pw.email });
    const thief = await signIn(pw.phone, pw.password);
    const thiefPw = await http('PUT', '/auth/v1/user', { token: thief.json?.access_token, body: { password: password() } });
    const memberLocked = await signIn(pw.phone, pw.password);
    const pwAccept = await onMember('identity.accept_credentials', pw, { identity_check: 'in_person' });
    const pwRestore = await onMember('identity.restore_credentials', pw, { identity_check: 'in_person' });
    const thiefRefresh2 = await refresh(thief.json?.refresh_token);
    const pwReleaseFirst = await onMember('identity.release_hold', pw, { hold_id: pwRestore.data?.holds?.[0]?.hold_id, identity_check: 'in_person' });
    const pwReset = await ownReset(pw);
    await sleep(EPOCH_WAIT_MS);
    const pwHeld = await summary((await signIn(pw.phone, pw.password)).json?.access_token);
    const pwRelease = await onMember('identity.release_hold', pw, { hold_id: pwRestore.data?.holds?.[0]?.hold_id, identity_check: 'in_person' });
    await sleep(EPOCH_WAIT_MS);
    const pwAfter = await summary((await signIn(pw.phone, pw.password)).json?.access_token);
    check('C51-stolen-session-password-change-keeps-a-hold-until-the-members-reset', thiefPw.status === 200
      && memberLocked.status === 400 && pwAccept.field_errors?.member_id === 'password_unreviewed'
      && pwRestore.status === 200 && pwRestore.data?.holds?.[0]?.reason_code === 'security_concern' && thiefRefresh2.status >= 400
      && pwReleaseFirst.field_errors?.hold_id === 'password_reset_required' && pwReset.set_password === 200
      && pwHeld.status === 403 && pwHeld.detail === 'review_required' && pwRelease.status === 200 && pwAfter.status === 200,
      { thief_password_change: thiefPw.status, member_old_password: memberLocked.status, accept: pwAccept.field_errors,
        restore_hold: pwRestore.data?.holds?.[0]?.reason_code, thief_refresh: thiefRefresh2.status,
        release_before_reset: pwReleaseFirst.field_errors, own_reset: pwReset, held_after_reset: pwHeld,
        release: pwRelease.status, fresh_sign_in: pwAfter });

    // ------------------- a reset link issued before a restore or a reject is never redeemable
    await seeded(link, { email: link.email });
    const pkLink = pkcePair();
    await sleep(RESEND_WAIT_MS);
    const linkAt = Date.now();
    await recover(link.email, MOBILE_RECOVERY, pkLink);
    const linkMail = await mailTo(link.email, linkAt);
    await http('PUT', `/auth/v1/admin/users/${link.user}`, { admin: true, body: { phone: link.direct, phone_confirm: true } });
    const linkRestore = await onMember('identity.restore_credentials', link, { identity_check: 'in_person' });
    const linkOpen = redirectFacts((await openLink(linkMail?.link)).location);

    await seeded(rej, { email: rej.email });
    const pkRej = pkcePair();
    await sleep(RESEND_WAIT_MS);
    const rejAt = Date.now();
    await recover(rej.email, MOBILE_RECOVERY, pkRej);
    const rejMail = await mailTo(rej.email, rejAt);
    const rAskRej = await credCmd(rej.token, 'identity.request_credential_change', null, { change_kind: 'recovery_email_replace', email: rej.next });
    const rejNewAt = Date.now();
    await http('PUT', `/auth/v1/user?redirect_to=${encodeURIComponent(MOBILE_EMAIL_CONFIRMED)}`, { token: rej.token, body: { email: rej.next } });
    await openLink((await mailTo(rej.next, rejNewAt))?.link);
    const rejDecision = await credCmd(admin.token, 'identity.reject_credential_change', rAskRej.revision, { change_id: rAskRej.data?.change_id });
    const rejBack = authRow(rej).endsWith('|true');
    const rejOpen = redirectFacts((await openLink(rejMail?.link)).location);
    check('C70-reset-links-issued-before-restore-or-reject-are-dead', Boolean(linkMail?.link) && linkRestore.status === 200
      && !linkOpen.has_code && Boolean(rejMail?.link) && rejDecision.status === 200 && rejBack && !rejOpen.has_code,
      { restore: linkRestore.status, link_after_restore: { has_code: linkOpen.has_code, error_code: linkOpen.error_code },
        reject: rejDecision.data?.state, approved_address_back: rejBack,
        link_after_reject: { has_code: rejOpen.has_code, error_code: rejOpen.error_code } });

    const leftHolds = Number(psql(`select count(*) from app.identity_holds h join app.identity_members m using (member_id)
                                   where m.display_name like '${NAME_PREFIX}%' and h.released_at is null`));
    const sms = (await http('GET', '/auth/v1/settings')).json?.sms_provider ?? null;
    check('C99-no-sms-no-open-holds', !sms && leftHolds === 0, { sms_provider: sms, open_holds: leftHolds });
  } finally {
    unhook();
    const left = cleanup();
    const mailRemoved = await clearMail();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'identity-credentials-e2e';
            delete from app.platform_environment_history where set_by = 'identity-credentials-e2e';`);
    }
    log('C100-cleanup', { users_left: Number(left), synthetic_mail_removed: mailRemoved, unmarked: marked });
  }
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  if (failed.length) {
    console.log(`FAILED: ${failed.map((f) => f.step).join(', ')}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((e) => {
    console.error(e.message);
    process.exitCode = 1;
  });
}
