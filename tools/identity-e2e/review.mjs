#!/usr/bin/env node
// Story 2.5 end-to-end on the LOCAL stack: Admin review of membership applications, linking
// existing or accountless members, and reclaiming a phone username, through real GoTrue phone
// sign-up (no SMS, no email) and the real Data API (PostgREST).
//   * an Admin (staff web) approves one applicant as a new member: the applicant's session from
//     before the approval is no longer trusted, a fresh sign-in reaches the new member;
//   * a second applicant is linked to an EXISTING member whose earlier account was unlinked
//     (lost phone): same member id and record; the unlink ended the member's grants (audited
//     as role_revoked), so the relinked account starts with NO roles; the old account has no
//     access;
//   * an Admin records an accountless member with a relative's labelled contact number; the
//     relative signs up with that number and the same name: still no access, the Admin queue
//     shows the member as a duplicate candidate, and the Admin rejects the relative (re-apply is
//     then rate limited); the person later creates an account and is linked to the same member;
//   * an applicant is asked for details, corrects one field and is approved;
//   * someone else registered a phone username first (F1): the Admin reclaims it after an
//     identity check, the holder is banned and its session dies, and the owner then signs up with
//     the number and is approved; a username held by a linked account is refused;
//   * non-Admins cannot read the queue or decide; every decision leaves a content-free audit row.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on` (no SMS
// provider, hook, test OTP or SMS MFA), then `off` afterwards. Needs a database with no usable
// Admin (run `npx supabase db reset` first if another run left one).
// LOCAL only (exact origin), SYNTHETIC fictional numbers +1 202 555 0190-0199. Evidence is
// redacted JSONL: statuses, codes, signals and revisions; never tokens, passwords or numbers.
// Every user, application, member, link, grant, audit row and receipt it created is removed.
//
// Usage: node tools/identity-e2e/review.mjs [--evidence <file.jsonl>]
import { execFileSync } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import { appendFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import { amrMethods, assertLocalOrigin, redact } from './run.mjs';

/** The reserved fictional numbers this run uses (+1 202 555 0190-0199). */
export function isFictionalReviewPhone(phone) {
  return /^\+120255501[9][0-9]$/.test(phone);
}

/** Keys an applicant's own application view must never carry (review data stays staff-only). */
export const STAFF_ONLY_KEYS = ['candidates', 'member_id', 'prior_not_approved', 'own_account'];

/** Staff-only keys found in an applicant's view (empty = safe). */
export function leakedStaffKeys(application) {
  return STAFF_ONLY_KEYS.filter((k) => Object.hasOwn(application ?? {}, k));
}

const NAME_PREFIX = 'SYNTHETIC 2.5 E2E';
const EPOCH_WAIT_MS = 6500; // the 2.2 trust-epoch margin is 5 s

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
    const res = await fetch(`${origin}${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
    const text = await res.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { /* non-JSON */ }
    return { status: res.status, json };
  }
  const password = () => `Synthetic-${randomBytes(12).toString('base64url')}`;
  const signUp = (phone, pw) => http('POST', '/auth/v1/signup', { body: { phone, password: pw } });
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const envelope = (fn, token, cmd, expected, payload, requestId = randomUUID()) =>
    rpc(fn, token, { version: 1, command: cmd, request_id: requestId, expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const review = (token, cmd, expected, payload, requestId) =>
    envelope('identity_review_command', token, cmd, expected, payload, requestId);
  const err = (r) => ({ status: r.status, code: r.json?.code ?? r.json?.message, detail: r.json?.details });
  const summary = async (token) => {
    const r = await rpc('identity_my_member_summary', token);
    return { status: r.status, member_id: r.json?.member_id, detail: r.json?.details };
  };
  const myApplication = async (token) => (await rpc('identity_my_application', token)).json?.application;
  const apply = (p) => envelope('identity_application_command', p.token, 'identity.submit_application', null,
    { full_name: p.name, cell_choice: { choice: 'not_sure' }, privacy_notice_version: 'draft-2026-10-07' });
  const queue = async (token) => (await rpc('identity_admin_application_queue', token)).json?.applications ?? [];
  const audit = (where) => psql(`select coalesce(string_agg(action || ':' || coalesce(identity_check, '-') || ':' || coalesce(reason_code, '-'), ',' order by event_id), '') from app.identity_membership_audit where ${where}`);
  const signUpApplicant = async (p) => {
    p.password = password();
    const up = await signUp(p.phone, p.password);
    p.token = up.json?.access_token;
    p.user = up.json?.user?.id;
    if (p.user) users.add(p.user);
    return up;
  };

  const people = {
    admin: { phone: '+12025550190', name: `${NAME_PREFIX} Admin` },
    one: { phone: '+12025550191', name: `${NAME_PREFIX} New Member` },
    two: { phone: '+12025550192', name: `${NAME_PREFIX} Returning Member` },
    old: { phone: '+12025550196', name: `${NAME_PREFIX} Returning Member` },
    later: { phone: '+12025550193', name: `${NAME_PREFIX} Ruth Accountless` },
    relative: { phone: '+12025550197', name: `${NAME_PREFIX} Ruth Accountless` },
    details: { phone: '+12025550194', name: `${NAME_PREFIX} Detail Applicant` },
    squatter: { phone: '+12025550195', name: `${NAME_PREFIX} Squatter` },
    owner: { phone: '+12025550195', name: `${NAME_PREFIX} Number Owner` },
  };
  for (const p of Object.values(people)) if (!isFictionalReviewPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  const users = new Set();
  const digits = [...new Set(Object.values(people).map((p) => `'${p.phone.slice(1)}'`))].join(',');
  const cleanup = () => {
    const ids = [...users].map((u) => `'${u}'`);
    const byUser = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    return psql(`
    create temp table gone_users as select u.id from auth.users u where ${byUser} u.phone in (${digits});
    create temp table gone_members as
      select m.member_id from app.identity_members m where m.display_name like '${NAME_PREFIX}%';
    create temp table gone_apps as
      select a.application_id from app.identity_membership_applications a
       where a.auth_user_id in (select id from gone_users) or a.full_name like '${NAME_PREFIX}%';
    delete from app.identity_membership_audit a
     where a.application_id in (select application_id from gone_apps)
        or a.member_id in (select member_id from gone_members)
        or a.actor_member_id in (select member_id from gone_members)
        or a.target_account_id in (select id from gone_users);
    delete from app.identity_phone_reclaims r
     where r.released_account_id in (select id from gone_users) or r.actor_member_id in (select member_id from gone_members);
    delete from app.identity_member_provenance p
     where p.member_id in (select member_id from gone_members) or p.application_id in (select application_id from gone_apps);
    delete from app.identity_contact_routes c where c.member_id in (select member_id from gone_members);
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
    psql(`select app.platform_set_environment('local', 'identity-review-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('R00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });
  if (Number(psql(`select app.identity_usable_admin_count()`)) !== 0) {
    throw new Error('the local database already has a usable Admin; run `npx supabase db reset` first');
  }

  try {
    const { admin, one, two, old, later, relative, details, squatter, owner } = people;

    // The Admin: a synthetic phone account linked by the operator and bootstrapped (staff web).
    admin.password = password();
    const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: {
      phone: admin.phone, phone_confirm: true, password: admin.password } });
    admin.user = created.json?.id;
    users.add(admin.user);
    admin.member = psql(`select app.identity_seed_synthetic_link('${admin.user}', '${admin.name}', 'identity-review-e2e')`);
    psql(`select app.identity_bootstrap_admin('${admin.member}', 'israel')`);
    admin.token = (await signIn(admin.phone, admin.password)).json?.access_token;
    const adminAccess = await rpc('identity_my_access', admin.token);
    check('R01-admin-signed-in-by-phone', amrMethods(admin.token).includes('password') && adminAccess.json?.roles?.includes('admin'),
      { amr: amrMethods(admin.token), roles: adminAccess.json?.roles });

    // ---------------------------------------------------------------- approve as a new member
    const up1 = await signUpApplicant(one);
    const sent1 = await apply(one);
    check('R10-applicant-applies', up1.status === 200 && sent1.data?.church_status === 'awaiting_approval',
      { signup: up1.status, church_status: sent1.data?.church_status, has_email: Boolean(up1.json?.user?.email) });
    const deniedQueue = await rpc('identity_admin_application_queue', one.token);
    const deniedReview = await review(one.token, 'identity.approve_application', 1,
      { application_id: sent1.data?.application_id, identity_check: 'in_person' });
    check('R11-applicant-cannot-review', deniedQueue.status === 403 && deniedReview.code === 'forbidden',
      { queue: err(deniedQueue), self_approve: deniedReview.code });
    const before1 = await summary(one.token);
    const approved = await review(admin.token, 'identity.approve_application', sent1.revision,
      { application_id: sent1.data?.application_id, identity_check: 'established_relationship' });
    one.member = approved.data?.member_id;
    const stale1 = await summary(one.token);
    check('R12-approve-new-member', approved.status === 200 && approved.data?.church_status === 'approved' && Boolean(one.member)
      && before1.status === 403 && before1.detail === 'not_linked' && stale1.status === 401 && stale1.detail === 'untrusted_session',
      { church_status: approved.data?.church_status, before: before1, pre_approval_session_after: stale1 });
    await sleep(EPOCH_WAIT_MS);
    one.token = (await signIn(one.phone, one.password)).json?.access_token;
    const fresh1 = await summary(one.token);
    const status1 = await myApplication(one.token);
    check('R13-fresh-sign-in-granted', fresh1.status === 200 && fresh1.member_id === one.member
      && status1?.church_status === 'approved' && leakedStaffKeys(status1).length === 0,
      { summary: { status: fresh1.status, same_member: fresh1.member_id === one.member }, church_status: status1?.church_status,
        leaked_staff_keys: leakedStaffKeys(status1) });
    const memberQueue = await rpc('identity_admin_application_queue', one.token);
    check('R14-member-without-admin-cannot-review', memberQueue.status === 403 && memberQueue.json?.details === 'not_granted',
      err(memberQueue));
    check('R15-approval-audited', audit(`application_id = '${sent1.data?.application_id}'`) === 'application_approved:established_relationship:-',
      { audit: audit(`application_id = '${sent1.data?.application_id}'`) });

    // ------------------------------------------- link to an existing member (earlier account lost)
    old.password = password();
    const oldUser = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: old.phone, phone_confirm: true, password: old.password } });
    old.user = oldUser.json?.id;
    users.add(old.user);
    two.member = psql(`select app.identity_seed_synthetic_link('${old.user}', '${two.name}', 'identity-review-e2e')`);
    psql(`select app.identity_designate_lead_pastor('${two.member}', 'israel')`);
    old.token = (await signIn(old.phone, old.password)).json?.access_token;
    const memberRevision = Number(psql(`select revision from app.identity_members where member_id = '${two.member}'`));
    const unlinked = await review(admin.token, 'identity.unlink_account', memberRevision, { member_id: two.member, reason: 'account_lost' });
    const oldAfter = await summary(old.token);
    check('R20-unlink-lost-account', unlinked.status === 200 && unlinked.data?.account === 'no_login'
      && oldAfter.status === 403 && oldAfter.detail === 'not_linked',
      { account: unlinked.data?.account, old_session: oldAfter, audit: audit(`member_id = '${two.member}'`) });
    await signUpApplicant(two);
    const sent2 = await apply(two);
    const q2 = await queue(admin.token);
    const cand2 = q2.find((a) => a.application_id === sent2.data?.application_id)?.candidates?.find((c) => c.member_id === two.member);
    check('R21-duplicate-candidate-for-admin-only', cand2?.signals?.includes('same_name') && cand2?.link_eligible === true
      && leakedStaffKeys(await myApplication(two.token)).length === 0,
      { signals: cand2?.signals, link_eligible: cand2?.link_eligible, account: cand2?.account });
    const linked2 = await review(admin.token, 'identity.link_application', sent2.revision,
      { application_id: sent2.data?.application_id, member_id: two.member, identity_check: 'in_person' });
    await sleep(EPOCH_WAIT_MS);
    two.token = (await signIn(two.phone, two.password)).json?.access_token;
    const fresh2 = await summary(two.token);
    const access2 = await rpc('identity_my_access', two.token);
    const oldSignIn = await signIn(old.phone, old.password);
    const oldFresh = await summary(oldSignIn.json?.access_token);
    check('R22-link-existing-member-keeps-id-no-grants', linked2.status === 200 && linked2.data?.member_id === two.member
      && fresh2.status === 200 && fresh2.member_id === two.member && Array.isArray(access2.json?.roles)
      && access2.json.roles.length === 0
      && psql(`select count(*) from app.identity_access_audit where target_member_id = '${two.member}' and action = 'role_revoked'`) === '1'
      && oldFresh.status === 403 && oldFresh.detail === 'not_linked'
      && psql(`select count(*) from app.identity_members where display_name = '${two.name}'`) === '1',
      { same_member: fresh2.member_id === two.member, roles_after_relink: access2.json?.roles,
        grants_ended_at_unlink: Number(psql(`select count(*) from app.identity_access_audit where target_member_id = '${two.member}' and action = 'role_revoked'`)), old_account_fresh_sign_in: oldFresh,
        people_with_that_name: Number(psql(`select count(*) from app.identity_members where display_name = '${two.name}'`)),
        audit: audit(`application_id = '${sent2.data?.application_id}'`) });

    // ------------------------------- accountless member, a shared contact number, a later account
    const createdMember = await review(admin.token, 'identity.create_member', null, {
      full_name: later.name, consent_basis: 'leader_assisted', assisted_by_member_id: one.member,
      contact_route: { phone: relative.phone, belongs_to: 'relative', holder_label: 'Daughter' } });
    later.member = createdMember.data?.member_id;
    check('R30-accountless-member-recorded', createdMember.status === 200 && createdMember.data?.account === 'no_login'
      && createdMember.data?.contact_routes?.[0]?.belongs_to === 'relative' && Boolean(createdMember.data?.contact_routes?.[0]?.holder_label),
      { account: createdMember.data?.account, origin: createdMember.data?.origin,
        contact_route: { belongs_to: createdMember.data?.contact_routes?.[0]?.belongs_to, labelled: Boolean(createdMember.data?.contact_routes?.[0]?.holder_label) } });
    await signUpApplicant(relative);
    const sentR = await apply(relative);
    const relSummary = await summary(relative.token);
    const relLinks = psql(`select count(*) from app.identity_account_links where auth_user_id = '${relative.user}'`);
    const qR = await queue(admin.token);
    const candR = qR.find((a) => a.application_id === sentR.data?.application_id)?.candidates?.find((c) => c.member_id === later.member);
    check('R31-shared-contact-number-gives-no-access', relSummary.status === 403 && relSummary.detail === 'not_linked' && relLinks === '0'
      && candR?.signals?.includes('contact_route_phone') && candR?.signals?.includes('same_name')
      && leakedStaffKeys(await myApplication(relative.token)).length === 0,
      { relative_summary: relSummary, relative_links: Number(relLinks), staff_signals: candR?.signals });
    const rejected = await review(admin.token, 'identity.reject_application', sentR.revision,
      { application_id: sentR.data?.application_id, reason: 'contact_church_office', identity_check: 'in_person' });
    const relStatus = await myApplication(relative.token);
    const reapply = await apply(relative);
    check('R32-reject-with-reason-and-reapply-cooldown', rejected.data?.church_status === 'not_approved'
      && relStatus?.decision_reason === 'contact_church_office' && Boolean(relStatus?.reapply_from) && reapply.code === 'rate_limited',
      { church_status: relStatus?.church_status, reason: relStatus?.decision_reason, reapply_from_set: Boolean(relStatus?.reapply_from),
        reapply_now: reapply.code });
    await signUpApplicant(later);
    const sentL = await apply(later);
    const linkedL = await review(admin.token, 'identity.link_application', sentL.revision,
      { application_id: sentL.data?.application_id, member_id: later.member, identity_check: 'in_person' });
    await sleep(EPOCH_WAIT_MS);
    later.token = (await signIn(later.phone, later.password)).json?.access_token;
    const freshL = await summary(later.token);
    const routes = psql(`select count(*) from app.identity_contact_routes where member_id = '${later.member}' and ended_at is null`);
    const prov = psql(`select origin || ':' || consent_basis from app.identity_member_provenance where member_id = '${later.member}'`);
    check('R33-later-account-linked-to-accountless-member', linkedL.status === 200 && freshL.status === 200
      && freshL.member_id === later.member && routes === '1' && prov === 'admin_record:leader_assisted',
      { same_member: freshL.member_id === later.member, contact_routes_kept: Number(routes), provenance: prov });

    // ------------------------------------------------------------------- ask for details, correct
    await signUpApplicant(details);
    const sentD = await apply(details);
    const asked = await review(admin.token, 'identity.request_application_details', sentD.revision,
      { application_id: sentD.data?.application_id, requested: ['full_name'] });
    const seen = await myApplication(details.token);
    const corrected = await envelope('identity_application_command', details.token, 'identity.correct_application', seen?.revision,
      { application_id: sentD.data?.application_id, full_name: `${details.name} Corrected` });
    const approvedD = await review(admin.token, 'identity.approve_application', corrected.revision,
      { application_id: sentD.data?.application_id, identity_check: 'in_person' });
    check('R40-ask-details-correct-approve', asked.data?.church_status === 'details_requested'
      && JSON.stringify(seen?.details_requested) === '["full_name"]' && corrected.data?.church_status === 'awaiting_approval'
      && approvedD.data?.church_status === 'approved',
      { asked: asked.data?.church_status, requested: seen?.details_requested, corrected: corrected.data?.church_status,
        approved: approvedD.data?.church_status });

    // ------------------------------------------------------------ reclaim a phone username (F1)
    await signUpApplicant(squatter);
    await apply(squatter);
    owner.password = password();
    const blocked = await signUp(owner.phone, owner.password);
    const linkedRefused = await review(admin.token, 'identity.reclaim_phone_username', null,
      { phone_username: one.phone, identity_check: 'in_person' });
    const reclaimed = await review(admin.token, 'identity.reclaim_phone_username', null,
      { phone_username: owner.phone, identity_check: 'in_person', reason: 'registered_by_someone_else' });
    const squatterOld = await rpc('identity_my_application', squatter.token);
    const squatterSignIn = await signIn(squatter.phone, squatter.password);
    check('R50-reclaim-releases-username', blocked.status === 422 && linkedRefused.code === 'conflict'
      && reclaimed.status === 200 && reclaimed.data?.released === true && reclaimed.data?.application_withdrawn === true
      && squatterOld.status === 401 && squatterSignIn.status === 400,
      { owner_sign_up_before: blocked.status, linked_username: linkedRefused.code, released: reclaimed.data?.released,
        holder_application_withdrawn: reclaimed.data?.application_withdrawn, holder_old_session: err(squatterOld),
        holder_sign_in: squatterSignIn.status, audit: audit(`action = 'phone_username_reclaimed' and target_account_id = '${squatter.user}'`) });
    const ownerUp = await signUpApplicant(owner);
    const sentO = await apply(owner);
    const approvedO = await review(admin.token, 'identity.approve_application', sentO.revision,
      { application_id: sentO.data?.application_id, identity_check: 'in_person' });
    await sleep(EPOCH_WAIT_MS);
    owner.token = (await signIn(owner.phone, owner.password)).json?.access_token;
    const freshO = await summary(owner.token);
    check('R51-owner-signs-up-and-is-approved', ownerUp.status === 200 && owner.user !== squatter.user
      && approvedO.data?.church_status === 'approved' && freshO.status === 200,
      { sign_up: ownerUp.status, new_account: owner.user !== squatter.user, summary: freshO.status });

    // --------------------------------------------------------------------------- audit is content-free
    const auditText = psql(`select coalesce(string_agg(a::text, ' '), '') from app.identity_membership_audit a`);
    const leaked = [...Object.values(people).map((p) => p.phone.slice(1)), ...Object.values(people).map((p) => p.name), 'Daughter']
      .filter((v) => auditText.includes(v));
    check('R60-audit-content-free', leaked.length === 0 && auditText.length > 0, { leaked_values: leaked.length,
      actions: psql(`select string_agg(distinct action, ',' order by action) from app.identity_membership_audit`) });
  } finally {
    const left = cleanup();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'identity-review-e2e';
            delete from app.platform_environment_history where set_by = 'identity-review-e2e';`);
    }
    log('R99-cleanup', { users_left: Number(left), unmarked: marked });
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
