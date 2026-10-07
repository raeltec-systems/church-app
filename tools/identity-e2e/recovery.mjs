#!/usr/bin/env node
// Story 2.7 end-to-end on the LOCAL stack: recover a password through a verified same-account
// email, through real GoTrue (phone sign-up without SMS, native email change, /recover, /verify,
// PKCE code exchange), the real Data API (PostgREST) and the stack's Mailpit (nothing leaves the
// machine):
//   * a member signs up by phone, is approved, proposes a recovery email (fresh password sign-in),
//     verifies it through GoTrue's email-change link on the SAME account (access waits in review),
//     and an Admin approves it into the binding; a fresh sign-in is granted again;
//   * forgot password from the MOBILE link (zm.bickafue.mobile://callback/auth/recovery) and the
//     WEB link (<site>/#/auth/recovery): PKCE code exchange gives a recovery session that reads no
//     private data and can only set the password; every older session loses private access; the
//     old password fails; a fresh password sign-in is granted; an intercepted code without the
//     verifier is useless;
//   * neutral failures: unknown, unverified (pending), unapproved (verified, not approved) and
//     changed (approved, then changed directly in Auth) addresses, an expired link, a reused
//     link and a non-allowlisted redirect; magic links obey the same gate;
//   * an existing hold stays in force after a reset.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on` (no SMS
// provider, hook, test OTP or SMS MFA), then `off` afterwards. Needs Mailpit (part of
// `supabase start`) and a database with no usable Admin (`npx supabase db reset` first).
// LOCAL only (exact origin), SYNTHETIC fictional numbers +44 7700 900280-900289 and
// @example.test addresses. Evidence is redacted JSONL: statuses, codes and booleans; never
// tokens, codes, links, passwords, numbers or addresses. Everything it created is removed.
//
// Usage: node tools/identity-e2e/recovery.mjs [--evidence <file.jsonl>]
import { execFileSync } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { appendFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import { amrMethods, assertLocalOrigin, redact } from './run.mjs';

export const MAILPIT = 'http://127.0.0.1:54324';
export const MOBILE_RECOVERY = 'zm.bickafue.mobile://callback/auth/recovery';
export const MOBILE_EMAIL_CONFIRMED = 'zm.bickafue.mobile://callback/auth/email-confirmed';
export const WEB_SITE = 'http://127.0.0.1:3000';
export const WEB_RECOVERY = `${WEB_SITE}/#/auth/recovery`;

/** The reserved fictional numbers this run uses (+44 7700 900280-900289). */
export function isFictionalRecoveryPhone(phone) {
  return /^\+44770090028[0-9]$/.test(phone);
}

/** A PKCE verifier and its S256 challenge (RFC 7636). */
export function pkcePair(bytes = randomBytes(32)) {
  const verifier = Buffer.from(bytes).toString('base64url');
  return { verifier, challenge: createHash('sha256').update(verifier).digest('base64url') };
}

/**
 * What a GoTrue verify redirect says, without keeping the code: the redirect base (no query or
 * fragment), whether it carries a code, and the error code if any.
 */
export function redirectFacts(location) {
  if (!location) return { base: null, has_code: false, error_code: null };
  const [beforeHash, hash = ''] = String(location).split('#');
  const q = beforeHash.includes('?') ? beforeHash.slice(beforeHash.indexOf('?') + 1) : '';
  const params = new URLSearchParams(q);
  const frag = new URLSearchParams(hash.startsWith('/') ? '' : hash);
  const base = beforeHash.split('?')[0] + (hash.startsWith('/') ? `#${hash}` : '');
  return {
    base,
    has_code: Boolean(params.get('code')),
    error_code: params.get('error_code') ?? frag.get('error_code'),
  };
}

/** The code from a verify redirect (kept in memory only). */
export function codeFrom(location) {
  const beforeHash = String(location ?? '').split('#')[0];
  const q = beforeHash.includes('?') ? beforeHash.slice(beforeHash.indexOf('?') + 1) : '';
  return new URLSearchParams(q).get('code');
}

const NAME_PREFIX = 'SYNTHETIC 2.7 E2E';
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
  const signUp = (phone, pw) => http('POST', '/auth/v1/signup', { body: { phone, password: pw } });
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const refresh = (rt) => http('POST', '/auth/v1/token?grant_type=refresh_token', { body: { refresh_token: rt } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const envelope = (fn, token, cmd, expected, payload, requestId = randomUUID()) =>
    rpc(fn, token, { version: 1, command: cmd, request_id: requestId, expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const recoveryCmd = (token, cmd, expected, payload) => envelope('identity_recovery_email_command', token, cmd, expected, payload);
  const summary = async (token) => {
    const r = await rpc('identity_my_member_summary', token);
    return { status: r.status, detail: r.json?.details ?? null, has_recovery_email: r.json?.has_recovery_email ?? null };
  };
  const myRecovery = async (token) => {
    const r = await rpc('identity_my_recovery_email', token);
    return { status: r.status, detail: r.json?.details ?? null, access: r.json?.access ?? null,
      state: r.json?.proposal?.state ?? null, verified: r.json?.proposal?.verified ?? null,
      can_propose: r.json?.can_propose ?? null, has_approved_email: Boolean(r.json?.approved_email) };
  };
  const recover = (email, redirectTo, pkce) => http('POST',
    `/auth/v1/recover${redirectTo ? `?redirect_to=${encodeURIComponent(redirectTo)}` : ''}`,
    { body: { email, ...(pkce ? { code_challenge: pkce.challenge, code_challenge_method: 's256' } : {}) } });
  const exchange = (code, verifier) => http('POST', '/auth/v1/token?grant_type=pkce', { body: { auth_code: code, code_verifier: verifier } });
  const openLink = async (link) => {
    if (!link?.startsWith(`${origin}/auth/v1/verify?`)) return { status: null, location: null };
    const res = await fetch(link, { redirect: 'manual' });
    return { status: res.status, location: res.headers.get('location') };
  };

  // Mailpit: the newest message to one address since a moment, and its local verify link.
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
  const mailFacts = (m) => ({ mail: Boolean(m), subject: m?.subject ?? null, has_link: Boolean(m?.link) });

  const run = randomBytes(4).toString('hex');
  const mail = (tag) => `synthetic-2-7-${tag}-${run}@example.test`;
  const people = {
    admin: { phone: '+447700900280', name: `${NAME_PREFIX} Admin` },
    member: { phone: '+447700900281', name: `${NAME_PREFIX} Member`, email: mail('member') },
    other: { phone: '+447700900282', name: `${NAME_PREFIX} Unapproved`, email: mail('unapproved') },
    changer: { phone: '+447700900283', name: `${NAME_PREFIX} Changer`, email: mail('changer'), changed: mail('changed') },
    held: { phone: '+447700900284', name: `${NAME_PREFIX} Held`, email: mail('held') },
    late: { phone: '+447700900285', name: `${NAME_PREFIX} Late Click`, email: mail('late') },
    rejected: { phone: '+447700900286', name: `${NAME_PREFIX} Rejected`, email: mail('rejected') },
  };
  for (const p of Object.values(people)) if (!isFictionalRecoveryPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  const users = new Set();
  const digits = [...new Set(Object.values(people).map((p) => `'${p.phone.slice(1)}'`))].join(',');
  const addresses = Object.values(people).flatMap((p) => [p.email, p.changed]).filter(Boolean);
  const cleanup = () => {
    const ids = [...users].map((u) => `'${u}'`);
    const byUser = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    return psql(`
    create temp table gone_users as select u.id from auth.users u
     where ${byUser} u.phone in (${digits}) or u.email like 'synthetic-2-7-%@example.test';
    create temp table gone_members as
      select m.member_id from app.identity_members m where m.display_name like '${NAME_PREFIX}%';
    create temp table gone_apps as
      select a.application_id from app.identity_membership_applications a
       where a.auth_user_id in (select id from gone_users) or a.full_name like '${NAME_PREFIX}%';
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
    select count(*) from auth.users u where ${byUser} u.phone in (${digits}) or u.email like 'synthetic-2-7-%@example.test';`);
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
    psql(`select app.platform_set_environment('local', 'identity-recovery-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('X00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null, email: settings.json?.external?.email },
    mailpit: mailpitUp,
    leftover_users_removed: cleanup(),
  });
  if (Number(psql(`select app.identity_usable_admin_count()`)) !== 0) {
    throw new Error('the local database already has a usable Admin; run `npx supabase db reset` first');
  }

  try {
    const { admin, member, other, changer, held, late, rejected } = people;
    const seeded = async (p, { email } = {}) => {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: {
        phone: p.phone, phone_confirm: true, password: p.password, ...(email ? { email, email_confirm: true } : {}) } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'identity-recovery-e2e')`);
      return created.status;
    };

    // The Admin (staff web): a synthetic phone account linked by the operator and bootstrapped.
    await seeded(admin);
    psql(`select app.identity_bootstrap_admin('${admin.member}', 'israel')`);
    admin.token = (await signIn(admin.phone, admin.password)).json?.access_token;
    const adminAccess = await rpc('identity_my_access', admin.token);
    check('X01-admin-signed-in-by-phone', amrMethods(admin.token).includes('password') && adminAccess.json?.roles?.includes('admin'),
      { amr: amrMethods(admin.token), roles: adminAccess.json?.roles });

    // ----------------------------------------------------- member: sign up by phone, approved
    member.password = password();
    const up = await signUp(member.phone, member.password);
    member.user = up.json?.user?.id;
    users.add(member.user);
    const sent = await envelope('identity_application_command', up.json?.access_token, 'identity.submit_application', null,
      { full_name: member.name, cell_choice: { choice: 'not_sure' }, privacy_notice_version: 'draft-2026-10-07' });
    const approved = await envelope('identity_review_command', admin.token, 'identity.approve_application', sent.revision,
      { application_id: sent.data?.application_id, identity_check: 'in_person' });
    await sleep(EPOCH_WAIT_MS);
    member.token = (await signIn(member.phone, member.password)).json?.access_token;
    const s0 = await summary(member.token);
    const r0 = await myRecovery(member.token);
    check('X10-member-approved-no-recovery-email', up.status === 200 && !up.json?.user?.email && approved.status === 200
      && s0.status === 200 && s0.has_recovery_email === false && r0.can_propose === true && r0.has_approved_email === false,
      { signup: up.status, signup_has_email: Boolean(up.json?.user?.email), approve: approved.status, summary: s0, recovery: r0 });

    // ------------------------------------- add the email to the SAME account, verify, approve
    const proposed = await recoveryCmd(member.token, 'identity.propose_recovery_email', null, { email: member.email });
    const pkceEmail = pkcePair();
    const askedAt = Date.now();
    const update = await http('PUT', `/auth/v1/user?redirect_to=${encodeURIComponent(MOBILE_EMAIL_CONFIRMED)}`,
      { token: member.token, body: { email: member.email, code_challenge: pkceEmail.challenge, code_challenge_method: 's256' } });
    const pendingRow = psql(`select coalesce(email, '') || '|' || (email_change = '${member.email}')::text from auth.users where id = '${member.user}'`);
    check('X11-propose-and-request-verification-same-account', proposed.status === 200 && proposed.data?.state === 'pending'
      && proposed.data?.verified === false && update.status === 200 && update.json?.id === member.user && pendingRow === '|true',
      { propose: proposed.status, state: proposed.data?.state, verified: proposed.data?.verified, update_user: update.status,
        same_account: update.json?.id === member.user, auth_email_empty_until_verified: pendingRow === '|true' });

    // Unverified: a reset to the pending address sends nothing (Auth has no such email yet).
    await sleep(RESEND_WAIT_MS);
    const confirmMail = await mailTo(member.email, askedAt);
    const unverifiedAt = Date.now();
    const recUnverified = await recover(member.email, MOBILE_RECOVERY, pkcePair());
    const unverifiedMail = await mailTo(member.email, unverifiedAt, { waitMs: 2500 });
    const unverifiedReset = unverifiedMail && unverifiedMail.subject !== confirmMail?.subject;
    check('X12-unverified-address-neutral-no-mail', recUnverified.status === 200 && JSON.stringify(recUnverified.json) === '{}'
      && !unverifiedReset, { recover: recUnverified.status, body_empty: JSON.stringify(recUnverified.json) === '{}', reset_mail: Boolean(unverifiedReset) });

    const opened = await openLink(confirmMail?.link);
    const confirmFacts = redirectFacts(opened.location);
    const s1 = await summary(member.token);
    const r1 = await myRecovery(member.token);
    check('X13-verified-email-waits-for-approval', confirmFacts.base === MOBILE_EMAIL_CONFIRMED && opened.status === 303
      && s1.status === 403 && s1.detail === 'review_required' && r1.status === 200 && r1.access === 'review_required' && r1.verified === true,
      { mail: mailFacts(confirmMail), redirect: confirmFacts, summary: s1, recovery: r1 });

    const queue = (await rpc('identity_admin_recovery_email_queue', admin.token)).json?.proposals ?? [];
    const item = queue.find((p) => p.proposal_id === proposed.data?.proposal_id);
    const memberQueue = await rpc('identity_admin_recovery_email_queue', member.token);
    const selfApprove = await recoveryCmd(member.token, 'identity.approve_recovery_email', item?.revision,
      { proposal_id: item?.proposal_id, identity_check: 'in_person' });
    const approve = await recoveryCmd(admin.token, 'identity.approve_recovery_email', item?.revision,
      { proposal_id: item?.proposal_id, identity_check: 'in_person' });
    const s2 = await summary(member.token);
    await sleep(EPOCH_WAIT_MS);
    member.token = (await signIn(member.phone, member.password)).json?.access_token;
    const s3 = await summary(member.token);
    check('X14-admin-approves-into-binding', item?.verified === true && item?.other_changes === false
      && memberQueue.status === 403 && selfApprove.code === 'forbidden'
      && approve.status === 200 && approve.data?.state === 'approved'
      && s2.status === 401 && s2.detail === 'untrusted_session' && s3.status === 200 && s3.has_recovery_email === true,
      { queue_item: { verified: item?.verified, other_changes: item?.other_changes, access_review: item?.access_review },
        member_reads_queue: memberQueue.status, member_approves: selfApprove.code, approve: approve.status,
        pre_approval_session: s2, fresh_sign_in: s3,
        binding: psql(`select binding_revision || ':' || link_state from app.identity_account_links where auth_user_id = '${member.user}' and link_state <> 'ended'`) });

    // ---------------------------------------------- forgot password from the MOBILE link
    const old = await signIn(member.phone, member.password); // a second, older session
    const pkceMobile = pkcePair();
    await sleep(RESEND_WAIT_MS);
    const mobileAt = Date.now();
    const recMobile = await recover(member.email, MOBILE_RECOVERY, pkceMobile);
    const mobileMail = await mailTo(member.email, mobileAt);
    const mobileOpen = await openLink(mobileMail?.link);
    const mobileFacts = redirectFacts(mobileOpen.location);
    const stolen = await exchange(codeFrom(mobileOpen.location), pkcePair().verifier);
    const rs = await exchange(codeFrom(mobileOpen.location), pkceMobile.verifier);
    const recToken = rs.json?.access_token;
    const recSummary = await summary(recToken);
    const recOwn = await myRecovery(recToken);
    check('X20-mobile-link-gives-recovery-session-without-private-access', recMobile.status === 200 && JSON.stringify(recMobile.json) === '{}'
      && mobileFacts.base === MOBILE_RECOVERY && mobileFacts.has_code && stolen.status >= 400 && rs.status === 200
      && amrMethods(recToken).includes('recovery') && !amrMethods(recToken).includes('password')
      && recSummary.status === 401 && recSummary.detail === 'untrusted_session' && recOwn.status === 401,
      { recover: recMobile.status, mail: mailFacts(mobileMail), redirect: mobileFacts, code_without_verifier: stolen.status,
        exchange: rs.status, amr: amrMethods(recToken), recovery_session_summary: recSummary, recovery_session_own_email: recOwn.status });

    const newPassword = password();
    const setPw = await http('PUT', '/auth/v1/user', { token: recToken, body: { password: newPassword } });
    const oldSummary = await summary(old.json?.access_token);
    const oldRefresh = await refresh(old.json?.refresh_token);
    const memberOld = await summary(member.token);
    const recAfter = await summary(recToken);
    const oldPw = await signIn(member.phone, member.password);
    const sessionsLeft = psql(`select count(*) from auth.sessions where user_id = '${member.user}'`);
    await http('POST', '/auth/v1/logout?scope=local', { token: recToken });
    await sleep(EPOCH_WAIT_MS);
    member.password = newPassword;
    const fresh = await signIn(member.phone, member.password);
    const sFresh = await summary(fresh.json?.access_token);
    member.token = fresh.json?.access_token;
    check('X21-password-set-old-sessions-dead-fresh-sign-in-granted', setPw.status === 200
      && oldSummary.status === 401 && oldRefresh.status >= 400 && memberOld.status === 401 && recAfter.status === 401
      && oldPw.status === 400 && sessionsLeft === '1' && sFresh.status === 200,
      { set_password: setPw.status, older_session: oldSummary, older_refresh: oldRefresh.status, earlier_session: memberOld,
        recovery_session_after: recAfter, old_password: oldPw.status, sessions_left_before_sign_out: Number(sessionsLeft),
        fresh_sign_in: sFresh, events: psql(`select string_agg(array_to_string(e.kinds, '+'), ',' order by e.event_id) from app.identity_credential_events e join app.identity_account_links l using (link_id) where l.auth_user_id = '${member.user}'`) });

    const reused = await openLink(mobileMail?.link);
    const reusedFacts = redirectFacts(reused.location);
    check('X22-reused-link-fails-neutrally', reused.status === 303 && !reusedFacts.has_code && reusedFacts.error_code === 'otp_expired',
      { redirect: reusedFacts });

    // ------------------------------------------------- forgot password from the WEB link
    const pkceWeb = pkcePair();
    await sleep(RESEND_WAIT_MS);
    const webAt = Date.now();
    const recWeb = await recover(member.email, WEB_RECOVERY, pkceWeb);
    const webMail = await mailTo(member.email, webAt);
    const webOpen = await openLink(webMail?.link);
    const webFacts = redirectFacts(webOpen.location);
    const rw = await exchange(codeFrom(webOpen.location), pkceWeb.verifier);
    const webSummary = await summary(rw.json?.access_token);
    const webPassword = password();
    const setWeb = await http('PUT', '/auth/v1/user', { token: rw.json?.access_token, body: { password: webPassword } });
    const memberBefore = await summary(member.token);
    await sleep(EPOCH_WAIT_MS);
    member.password = webPassword;
    const freshWeb = await signIn(member.phone, member.password);
    const sWeb = await summary(freshWeb.json?.access_token);
    member.token = freshWeb.json?.access_token;
    check('X23-web-link-reset', recWeb.status === 200 && webFacts.base === `${WEB_SITE}/#/auth/recovery` && webFacts.has_code
      && rw.status === 200 && webSummary.status === 401 && setWeb.status === 200 && memberBefore.status === 401 && sWeb.status === 200,
      { recover: recWeb.status, mail: mailFacts(webMail), redirect: webFacts, exchange: rw.status,
        recovery_session_summary: webSummary, set_password: setWeb.status, earlier_session: memberBefore, fresh_sign_in: sWeb });

    // ----------------------------------------------------------- expired, redirect allowlist
    await sleep(RESEND_WAIT_MS);
    const expiredAt = Date.now();
    await recover(member.email, MOBILE_RECOVERY, pkcePair());
    const expiredMail = await mailTo(member.email, expiredAt);
    psql(`update auth.users set recovery_sent_at = now() - interval '2 hours' where id = '${member.user}'`);
    const expiredOpen = await openLink(expiredMail?.link);
    const expiredFacts = redirectFacts(expiredOpen.location);
    check('X24-expired-link-fails-neutrally', expiredOpen.status === 303 && !expiredFacts.has_code && expiredFacts.error_code === 'otp_expired',
      { mail: mailFacts(expiredMail), redirect: expiredFacts });

    await sleep(RESEND_WAIT_MS);
    const evilAt = Date.now();
    const evilPkce = pkcePair();
    await recover(member.email, 'https://attacker.example/steal', evilPkce);
    const evilMail = await mailTo(member.email, evilAt);
    const evilOpen = await openLink(evilMail?.link);
    const evilFacts = redirectFacts(evilOpen.location);
    // The member did not ask for this one: the code is never exchanged here.
    check('X25-non-allowlisted-redirect-falls-back-to-site', evilFacts.base !== null && !evilFacts.base.startsWith('https://attacker.example')
      && evilFacts.base.startsWith(WEB_SITE), { redirect_base: evilFacts.base, has_code: evilFacts.has_code });

    // ------------------------------------------------------------- unknown address: neutral
    const unknownAddress = mail('nobody');
    const unknownAt = Date.now();
    const recUnknown = await recover(unknownAddress, MOBILE_RECOVERY, pkcePair());
    const unknownMail = await mailTo(unknownAddress, unknownAt, { waitMs: 2000 });
    check('X30-unknown-address-neutral-no-mail', recUnknown.status === 200 && JSON.stringify(recUnknown.json) === '{}' && !unknownMail,
      { recover: recUnknown.status, body_empty: JSON.stringify(recUnknown.json) === '{}', mail: Boolean(unknownMail) });

    // ------------------------------------------ unapproved: verified on the account, not approved
    await seeded(other);
    other.token = (await signIn(other.phone, other.password)).json?.access_token;
    await recoveryCmd(other.token, 'identity.propose_recovery_email', null, { email: other.email });
    const otherAt = Date.now();
    await http('PUT', `/auth/v1/user?redirect_to=${encodeURIComponent(MOBILE_EMAIL_CONFIRMED)}`, { token: other.token, body: { email: other.email } });
    const otherConfirm = await mailTo(other.email, otherAt);
    await openLink(otherConfirm?.link);
    await sleep(RESEND_WAIT_MS);
    const unapprovedAt = Date.now();
    const recUnapproved = await recover(other.email, MOBILE_RECOVERY, pkcePair());
    const unapprovedMail = await mailTo(other.email, unapprovedAt);
    const unapprovedOpen = await openLink(unapprovedMail?.link);
    const unapprovedFacts = redirectFacts(unapprovedOpen.location);
    await sleep(RESEND_WAIT_MS);
    const magicAt = Date.now();
    const magic = await http('POST', '/auth/v1/otp', { body: { email: other.email, create_user: false } });
    const magicMail = await mailTo(other.email, magicAt);
    const magicOpen = await openLink(magicMail?.link);
    const magicFacts = redirectFacts(magicOpen.location);
    const magicSession = /access_token=/.test(String(magicOpen.location ?? ''));
    check('X31-unapproved-address-link-gives-no-session', recUnapproved.status === 200 && JSON.stringify(recUnapproved.json) === '{}'
      && Boolean(unapprovedMail?.link) && !unapprovedFacts.has_code && magic.status === 200 && !magicFacts.has_code && !magicSession,
      { recover: recUnapproved.status, mail: mailFacts(unapprovedMail), redirect: unapprovedFacts,
        magic_link: { request: magic.status, mail: mailFacts(magicMail), redirect: { base: magicFacts.base, error_code: magicFacts.error_code }, session: magicSession } });

    // -------------------------------- changed: approved, then changed directly in Auth (Admin API)
    await seeded(changer, { email: changer.email });
    const direct = await http('PUT', `/auth/v1/admin/users/${changer.user}`, { admin: true, body: { email: changer.changed, email_confirm: true } });
    await sleep(RESEND_WAIT_MS);
    const changedAt = Date.now();
    const recOld = await recover(changer.email, MOBILE_RECOVERY, pkcePair());
    const recNew = await recover(changer.changed, MOBILE_RECOVERY, pkcePair());
    const oldMail = await mailTo(changer.email, changedAt, { waitMs: 2000 });
    const newMail = await mailTo(changer.changed, changedAt);
    const newOpen = await openLink(newMail?.link);
    const newFacts = redirectFacts(newOpen.location);
    check('X32-changed-address-fails-neutrally', direct.status === 200 && recOld.status === 200 && recNew.status === 200
      && !oldMail && Boolean(newMail?.link) && !newFacts.has_code,
      { direct_auth_change: direct.status, recover_approved_address: recOld.status, approved_address_mail: Boolean(oldMail),
        recover_new_address: recNew.status, new_address_mail: mailFacts(newMail), new_address_redirect: newFacts });

    // ---------------------------------------------------------------- hold stays in force
    await seeded(held, { email: held.email });
    psql(`insert into app.identity_holds (member_id, hold_kind, reason, placed_by) values ('${held.member}', 'security', 'SYNTHETIC 2.7 E2E hold', 'identity-recovery-e2e')`);
    const pkceHeld = pkcePair();
    const heldAt = Date.now();
    await recover(held.email, MOBILE_RECOVERY, pkceHeld);
    const heldMail = await mailTo(held.email, heldAt);
    const heldOpen = await openLink(heldMail?.link);
    const rh = await exchange(codeFrom(heldOpen.location), pkceHeld.verifier);
    const heldPw = password();
    const setHeld = await http('PUT', '/auth/v1/user', { token: rh.json?.access_token, body: { password: heldPw } });
    await sleep(EPOCH_WAIT_MS);
    const heldFresh = await signIn(held.phone, heldPw);
    const sHeld = await summary(heldFresh.json?.access_token);
    const holdOpen = psql(`select count(*) from app.identity_holds where member_id = '${held.member}' and released_at is null`);
    check('X33-hold-stays-in-force-after-reset', rh.status === 200 && setHeld.status === 200 && heldFresh.status === 200
      && sHeld.status === 403 && sHeld.detail === 'review_required' && holdOpen === '1',
      { exchange: rh.status, set_password: setHeld.status, fresh_sign_in: heldFresh.status, summary: sHeld, open_holds: Number(holdOpen) });

    // ------------------------------------------------------------- lockout exits (review fix)
    const authEmail = (user) => psql(`select coalesce(email, '') || '|' || coalesce(email_change, '') from auth.users where id = '${user}'`);
    const pendingOf = async (token) => (await rpc('identity_my_recovery_email', token)).json?.proposal;

    // The member withdraws their own verified email from the review state.
    const inReview = await summary(other.token);
    const otherProposal = await pendingOf(other.token);
    const withdrawn = await recoveryCmd(other.token, 'identity.withdraw_recovery_email', otherProposal?.revision,
      { proposal_id: otherProposal?.proposal_id });
    await sleep(EPOCH_WAIT_MS);
    const otherFresh = await summary((await signIn(other.phone, other.password)).json?.access_token);
    check('X35-member-withdraws-from-review', inReview.status === 403 && inReview.detail === 'review_required'
      && withdrawn.status === 200 && withdrawn.data?.state === 'withdrawn' && authEmail(other.user) === '|'
      && otherFresh.status === 200 && otherFresh.has_recovery_email === false,
      { before: inReview, withdraw: withdrawn.data?.state, auth_email_cleared: authEmail(other.user) === '|', fresh_sign_in: otherFresh });

    // An Admin rejects a verified email: the account is back on its approved binding.
    await seeded(rejected);
    rejected.token = (await signIn(rejected.phone, rejected.password)).json?.access_token;
    await recoveryCmd(rejected.token, 'identity.propose_recovery_email', null, { email: rejected.email });
    const rejectedAt = Date.now();
    await http('PUT', `/auth/v1/user?redirect_to=${encodeURIComponent(MOBILE_EMAIL_CONFIRMED)}`, { token: rejected.token, body: { email: rejected.email } });
    await openLink((await mailTo(rejected.email, rejectedAt))?.link);
    const rq = (await rpc('identity_admin_recovery_email_queue', admin.token)).json?.proposals?.find((p) => p.member_id === rejected.member);
    const rejectVerified = await recoveryCmd(admin.token, 'identity.reject_recovery_email', rq?.revision,
      { proposal_id: rq?.proposal_id, reason: 'contact_church_office' });
    await sleep(EPOCH_WAIT_MS);
    const rejectedFresh = await summary((await signIn(rejected.phone, rejected.password)).json?.access_token);
    check('X36-reject-verified-returns-to-approved-binding', rq?.verified === true && rejectVerified.status === 200
      && rejectVerified.data?.state === 'rejected' && authEmail(rejected.user) === '|' && rejectedFresh.status === 200,
      { verified_before: rq?.verified, reject: rejectVerified.data?.state, auth_email_cleared: authEmail(rejected.user) === '|', fresh_sign_in: rejectedFresh });

    // Rejected before the member opens the confirmation link: the later click changes nothing.
    await seeded(late);
    late.token = (await signIn(late.phone, late.password)).json?.access_token;
    await recoveryCmd(late.token, 'identity.propose_recovery_email', null, { email: late.email });
    const lateAt = Date.now();
    await http('PUT', `/auth/v1/user?redirect_to=${encodeURIComponent(MOBILE_EMAIL_CONFIRMED)}`, { token: late.token, body: { email: late.email } });
    const lateMail = await mailTo(late.email, lateAt);
    const lq = (await rpc('identity_admin_recovery_email_queue', admin.token)).json?.proposals?.find((p) => p.member_id === late.member);
    const rejectUnverified = await recoveryCmd(admin.token, 'identity.reject_recovery_email', lq?.revision, { proposal_id: lq?.proposal_id });
    const lateOpen = await openLink(lateMail?.link);
    const lateFacts = redirectFacts(lateOpen.location);
    const lateSummary = await summary(late.token);
    check('X37-confirmation-link-after-reject-changes-nothing', lq?.verified === false && rejectUnverified.status === 200
      && authEmail(late.user) === '|' && !lateFacts.has_code && lateSummary.status === 200,
      { verified_before: lq?.verified, reject: rejectUnverified.data?.state, link_redirect: lateFacts,
        auth_email_still_empty: authEmail(late.user) === '|', session_still_granted: lateSummary.status });

    const sms = (await http('GET', '/auth/v1/settings')).json?.sms_provider ?? null;
    check('X34-no-sms', !sms, { sms_provider: sms });
  } finally {
    const left = cleanup();
    const mailRemoved = await clearMail();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'identity-recovery-e2e';
            delete from app.platform_environment_history where set_by = 'identity-recovery-e2e';`);
    }
    log('X99-cleanup', { users_left: Number(left), synthetic_mail_removed: mailRemoved, unmarked: marked });
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
