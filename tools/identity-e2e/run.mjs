#!/usr/bin/env node
// Story 2.1 end-to-end on the LOCAL stack: phone/password sign-up and sign-in through native
// GoTrue (no SMS), then the live-access-checked read api.identity_my_member_summary.
// Story 2.2 extends it (E30-E45) with direct native Auth calls for every alternate route: token
// refresh, magic link, email OTP, recovery and a password set from it, the verified email/password
// alias, direct Auth phone/email changes (with revert and simulated re-approval), global sign-out,
// ban and a dormant labelled-fixture account. Magic-link/OTP/recovery tokens come from the Auth
// Admin generate_link endpoint (local secret key, never logged) and are redeemed at native
// /auth/v1/verify, so no email is sent.
//
// Preconditions: `npx supabase start`, migrations applied, and the local-only phone switch
//   node tools/auth-harness/local-phone-auth.mjs on
// Seeding and cleanup use psql in the local db container as the restricted operator.
// Only the exact local origin is accepted. SYNTHETIC fictional-range numbers only
// (+1 202 555 0170-0179 and +44 7700 900170-900179). Evidence is a redacted JSONL log: status
// codes, error codes, AMR method names and summary fields; never tokens or passwords.
//
// Usage: node tools/identity-e2e/run.mjs [--evidence <file.jsonl>]
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { amrMethods, localHttp, localKey, password, psql, startRun } from './harness.mjs';

// Moved to the shared harness in story 2.13; re-exported for existing importers.
export { amrMethods, assertLocalOrigin, LOCAL_ORIGIN, redact } from './harness.mjs';

/** Reserved fictional ranges used by this run. */
export function isFictional(phone) {
  return /^\+1202555017[0-9]$/.test(phone) || /^\+44770090017[0-9]$/.test(phone);
}

async function main() {
  const { log, check, results } = startRun();
  const keys = localKey();
  const http = localHttp(keys);
  const signUp = (phone, pw) => http('POST', '/auth/v1/signup', { body: { phone, password: pw } });
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const read = (token) => http('POST', '/rest/v1/rpc/identity_my_member_summary', { token, body: {}, profile: 'api' });
  const err = (r) => ({ status: r.status, code: r.json?.error_code ?? r.json?.message, detail: r.json?.details, msg: r.json?.msg });

  const A = '+12025550171', B = '+12025550172', C = '+447700900171', U = '+12025550179';
  // Story 2.2 accounts: D email alias, E direct changes (E2 = its changed phone), F dormant.
  const D = '+12025550173', E = '+12025550174', E2 = '+12025550176', F = '+12025550175';
  const DMAIL = 'synthetic-2-2-e2e-alias@example.test', EMAIL2 = 'synthetic-2-2-e2e-changed@example.test';
  for (const p of [A, B, C, U, D, E, E2, F]) if (!isFictional(p)) throw new Error(`not fictional: ${p}`);
  const digits = [A, B, C, U, D, E, E2, F].map((p) => `'${p.slice(1)}'`).join(',');
  const ours = `(u.phone in (${digits}) or u.email like 'synthetic-2-2-e2e-%@example.test')`;
  const cleanup = () => psql(`
    delete from app.identity_binding_history h using app.identity_account_links l, auth.users u
     where h.link_id = l.link_id and l.auth_user_id = u.id and ${ours};
    delete from app.identity_credential_events e using app.identity_account_links l, auth.users u
     where e.link_id = l.link_id and l.auth_user_id = u.id and ${ours};
    delete from app.identity_holds h using app.identity_account_links l, auth.users u
     where h.member_id = l.member_id and l.auth_user_id = u.id and ${ours};
    delete from app.identity_grants g using app.identity_account_links l, auth.users u
     where g.member_id = l.member_id and l.auth_user_id = u.id and ${ours};
    delete from app.identity_grant_sets s using app.identity_account_links l, auth.users u
     where s.member_id = l.member_id and l.auth_user_id = u.id and ${ours};
    with gone as (delete from app.identity_account_links l using auth.users u
                   where l.auth_user_id = u.id and ${ours} returning l.member_id)
    delete from app.identity_members m using gone where m.member_id = gone.member_id;
    delete from auth.users u where ${ours};
    select count(*) from auth.users u where ${ours};`);

  const marker = psql(`select coalesce((select environment from app.platform_environment), '')`);
  let marked = false;
  if (marker === '') {
    psql(`select app.platform_set_environment('local', 'identity-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('E00-precondition', { settings: await http('GET', '/auth/v1/settings').then((r) => ({
    status: r.status, phone: r.json?.external?.phone, phone_autoconfirm: r.json?.phone_autoconfirm,
    sms_provider: r.json?.sms_provider })), leftover_users_removed: cleanup() });

  const startedAt = new Date().toISOString();
  try {
    const pwA = password();
    const up = await signUp(A, pwA);
    check('E10-phone-signup', up.status === 200 && amrMethods(up.json?.access_token).includes('password'),
      { status: up.status, amr: amrMethods(up.json?.access_token), stored_phone: up.json?.user?.phone });

    const r0 = await read(up.json?.access_token);
    check('E11-read-before-link', r0.status === 403 && r0.json?.details === 'not_linked', err(r0));

    const userA = psql(`select id from auth.users where phone = '${A.slice(1)}'`);
    psql(`select app.identity_seed_synthetic_link('${userA}', 'SYNTHETIC E2E Member', 'identity-e2e')`);
    log('E12-operator-seeded-link', { approved_phone: psql(`select approved_phone from app.identity_account_links where auth_user_id = '${userA}'`) });

    const r1 = await read(up.json?.access_token);
    check('E13-read-after-link', r1.status === 200 && r1.json?.display_name === 'SYNTHETIC E2E Member',
      { status: r1.status, summary: r1.json && { ...r1.json, member_id: '[uuid]' } });

    const s2 = await signIn(A, pwA);
    const r2 = await read(s2.json?.access_token);
    check('E14-second-device-sign-in', s2.status === 200 && r2.status === 200,
      { status: s2.status, amr: amrMethods(s2.json?.access_token), read_status: r2.status });

    const wrong = await signIn(A, password());
    const unknown = await signIn(U, password());
    check('E15-generic-credential-errors', wrong.status === 400 && unknown.status === 400
      && wrong.json?.error_code === unknown.json?.error_code && wrong.json?.msg === unknown.json?.msg,
      { wrong: err(wrong), unknown: err(unknown) });

    const dup = await signUp(A, password());
    check('E16-duplicate-username-refused', dup.status === 422 && !dup.json?.access_token, err(dup));

    const nopw = await http('POST', '/auth/v1/signup', { body: { phone: B } });
    check('E17-passwordless-signup-refused', nopw.status >= 400 && !nopw.json?.access_token, err(nopw));

    const otp = await http('POST', '/auth/v1/otp', { body: { phone: B, create_user: true } });
    const bUser = psql(`select count(*) from auth.users where phone = '${B.slice(1)}'`);
    const bLinked = psql(`select count(*) from app.identity_account_links l join auth.users u on u.id = l.auth_user_id where u.phone = '${B.slice(1)}'`);
    check('E18-phone-otp-no-sms-no-tokens-no-link', otp.status >= 400 && !otp.json?.access_token && bLinked === '0',
      { ...err(otp), f1_user_rows: Number(bUser), linked: Number(bLinked) });

    const pwC = password();
    const upC = await signUp(C, pwC);
    const rC = await read(upC.json?.access_token);
    check('E19-uk-number-unlinked-denied', upC.status === 200 && rC.status === 403 && rC.json?.details === 'not_linked',
      { signup_status: upC.status, stored_phone: upC.json?.user?.phone, read: err(rC) });

    const anon = await read(null);
    check('E20-signed-out-denied', anon.status === 401, err(anon));

    const direct = await http('GET', '/rest/v1/identity_members', { token: s2.json?.access_token, profile: 'app' });
    const directApi = await http('GET', '/rest/v1/identity_account_links', { token: s2.json?.access_token, profile: 'api' });
    check('E21-direct-table-query-denied', direct.status === 406 && directApi.status === 404,
      { app_schema: direct.status, api_schema: directApi.status });

    const out = await http('POST', '/auth/v1/logout?scope=local', { token: s2.json?.access_token });
    const r3 = await read(s2.json?.access_token);
    const r4 = await read(up.json?.access_token);
    check('E22-signed-out-session-denied-other-session-kept', r3.status === 401 && r3.json?.details === 'untrusted_session' && r4.status === 200,
      { logout_status: out.status, revoked_read: err(r3), other_session_read: r4.status });

    const activity = psql(`select last_member_activity_at is not null from app.identity_account_links where auth_user_id = '${userA}'`);
    check('E23-activity-recorded-only-after-grant', activity === 't', { activity_recorded: activity === 't' });

    // ---- Story 2.2: alternate Auth routes, revocation, direct changes, dormancy ----
    const refresh = (rt) => http('POST', '/auth/v1/token?grant_type=refresh_token', { body: { refresh_token: rt } });
    const signInEmail = (email, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { email, password: pw } });
    const adminUpdate = (id, body) => http('PUT', `/auth/v1/admin/users/${id}`, { admin: true, body });
    const generateLink = (type, email) => http('POST', '/auth/v1/admin/generate_link', { admin: true, body: { type, email } });
    const verifyHash = (type, tokenHash) => http('POST', '/auth/v1/verify', { body: { type, token_hash: tokenHash } });
    const uid = (phone) => psql(`select id from auth.users where phone = '${phone.slice(1)}'`);
    const activityOf = (id) => psql(`select coalesce(last_member_activity_at::text, 'none') from app.identity_account_links where auth_user_id = '${id}' and link_state <> 'ended'`);
    const linkState = (id) => psql(`select link_state || ' gen=' || credential_generation from app.identity_account_links where auth_user_id = '${id}' and link_state <> 'ended'`);
    const events = (id) => psql(`select coalesce(string_agg(e.source || ':' || array_to_string(e.kinds, '+'), ', ' order by e.event_id), '') from app.identity_credential_events e join app.identity_account_links l using (link_id) where l.auth_user_id = '${id}'`);
    const reason = (r) => (r.status === 200 ? 'granted' : `${r.status} ${r.json?.details ?? r.json?.message}`);
    // A fresh sign-in counts only once it is past the trust epoch plus its 5 s safety margin.
    const pastMargin = () => new Promise((resolve) => setTimeout(resolve, 6000));
    const sameMember = (r, id) => r.status === 200 && r.json?.member_id === id;

    // E30: token refresh keeps the password session and its access (no password prompt).
    const sA = await signIn(A, pwA);
    const sAr = await refresh(sA.json?.refresh_token);
    const rAr = await read(sAr.json?.access_token);
    check('E30-refresh-keeps-access', sAr.status === 200 && amrMethods(sAr.json?.access_token).includes('password') && rAr.status === 200,
      { refresh_status: sAr.status, amr: amrMethods(sAr.json?.access_token), read: reason(rAr) });

    // D: phone account with a verified email alias, created by Auth Admin and seeded as approved.
    const pwD = password();
    const cD = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: D, email: DMAIL, password: pwD, phone_confirm: true, email_confirm: true } });
    const userD = cD.json?.id;
    psql(`select app.identity_seed_synthetic_link('${userD}', 'SYNTHETIC E2E Alias Member', 'identity-e2e 2.2')`);
    const sDp = await signIn(D, pwD);
    log('E31-setup-alias-account', { create_status: cD.status, phone_session: sDp.status, activity: activityOf(userD) });

    // E32-E34: magic link, email OTP and recovery sessions (all otp AMR) are denied, no activity.
    const before = activityOf(userD);
    const ml = await generateLink('magiclink', DMAIL);
    const vMl = await verifyHash('magiclink', ml.json?.hashed_token);
    const rMl = await read(vMl.json?.access_token);
    check('E32-magic-link-session-denied', vMl.status === 200 && rMl.status === 401 && rMl.json?.details === 'untrusted_session',
      { verify_status: vMl.status, amr: amrMethods(vMl.json?.access_token), read: reason(rMl) });
    const ot = await generateLink('magiclink', DMAIL);
    const vOt = await http('POST', '/auth/v1/verify', { body: { type: 'email', email: DMAIL, token: ot.json?.email_otp } });
    const rOt = await read(vOt.json?.access_token);
    const rOtR = await read((await refresh(vOt.json?.refresh_token)).json?.access_token);
    check('E33-email-otp-session-denied-also-after-refresh', vOt.status === 200 && rOt.status === 401 && rOtR.status === 401,
      { verify_status: vOt.status, amr: amrMethods(vOt.json?.access_token), read: reason(rOt), read_after_refresh: reason(rOtR) });
    const rc = await generateLink('recovery', DMAIL);
    const vRc = await verifyHash('recovery', rc.json?.hashed_token);
    const rRc = await read(vRc.json?.access_token);
    check('E34-recovery-session-denied', vRc.status === 200 && rRc.status === 401 && rRc.json?.details === 'untrusted_session',
      { verify_status: vRc.status, amr: amrMethods(vRc.json?.access_token), read: reason(rRc) });
    check('E35-denials-wrote-no-activity', activityOf(userD) === before, { before, after: activityOf(userD) });

    // E36: password set from the recovery session: the recovery session stays denied, every
    // session from before is dead, the old password fails, a fresh password sign-in is granted.
    const pwD2 = password();
    const actD36 = activityOf(userD);
    const setPw = await http('PUT', '/auth/v1/user', { token: vRc.json?.access_token, body: { password: pwD2 } });
    const rRc2 = await read(vRc.json?.access_token);
    const rDold = await read(sDp.json?.access_token);
    const oldPw = await signIn(D, pwD);
    const act36 = activityOf(userD) === actD36;
    await pastMargin();
    const sD2 = await signIn(D, pwD2);
    const rD2 = await read(sD2.json?.access_token);
    check('E36-recovery-password-set-needs-fresh-sign-in',
      setPw.status === 200 && rRc2.status === 401 && rDold.status === 401 && oldPw.status === 400 && rD2.status === 200 && act36,
      { set_status: setPw.status, recovery_session: reason(rRc2), pre_reset_session: reason(rDold), old_password: oldPw.status,
        denials_left_activity_unchanged: act36, fresh_sign_in: reason(rD2), link: linkState(userD) });

    // E37: the verified email/password alias resolves to the same account and member.
    const sDe = await signInEmail(DMAIL, pwD2);
    const rDe = await read(sDe.json?.access_token);
    check('E37-email-alias-same-account-same-checks',
      sDe.status === 200 && sDe.json?.user?.id === userD && amrMethods(sDe.json?.access_token).includes('password') && sameMember(rDe, rD2.json?.member_id),
      { status: sDe.status, same_sub: sDe.json?.user?.id === userD, amr: amrMethods(sDe.json?.access_token), read: reason(rDe), same_member: sameMember(rDe, rD2.json?.member_id) });

    // E38-E41: direct Auth phone/email change on a linked account (Auth Admin, bypassing Identity).
    const pwE = password();
    await signUp(E, pwE);
    const userE = uid(E);
    psql(`select app.identity_seed_synthetic_link('${userE}', 'SYNTHETIC E2E Change Member', 'identity-e2e 2.2')`);
    const sE = await signIn(E, pwE);
    const rE0 = await read(sE.json?.access_token);
    const actE = activityOf(userE);
    const chg = await adminUpdate(userE, { phone: E2 });
    const rE1 = await read(sE.json?.access_token);
    const back = await adminUpdate(userE, { phone: E });
    const rE2 = await read(sE.json?.access_token);
    const sE2 = await signIn(E, pwE);
    const rE3 = await read(sE2.json?.access_token);
    const act38 = activityOf(userE) === actE;
    check('E38-direct-phone-change-review-even-after-revert',
      rE0.status === 200 && chg.status === 200 && rE1.json?.details === 'review_required' && back.status === 200
        && rE2.json?.details === 'review_required' && rE3.json?.details === 'review_required' && act38,
      { before: reason(rE0), stale_token_after_change: reason(rE1), after_revert: reason(rE2), fresh_sign_in_before_review: reason(rE3),
        activity_unchanged: act38, link: linkState(userE) });
    // Simulated reviewed re-approval (entries 5/8): a new binding revision and an active link.
    psql(`update app.identity_account_links set link_state = 'active', binding_revision = binding_revision + 1 where auth_user_id = '${userE}'`);
    const rE4 = await read(sE.json?.access_token);
    const rE4b = await read(sE2.json?.access_token);
    const act39 = activityOf(userE) === actE;
    await pastMargin();
    const sE3 = await signIn(E, pwE);
    const rE5 = await read(sE3.json?.access_token);
    check('E39-after-reapproval-stale-tokens-dead-fresh-granted',
      rE4.json?.details === 'untrusted_session' && rE4b.json?.details === 'untrusted_session' && act39 && rE5.status === 200,
      { pre_change_token: reason(rE4), during_review_token: reason(rE4b), activity_unchanged: act39, fresh_sign_in: reason(rE5) });
    const actE40 = activityOf(userE);
    const em = await adminUpdate(userE, { email: EMAIL2, email_confirm: true });
    const rE6 = await read(sE3.json?.access_token);
    const sE4 = await signIn(E, pwE);
    const rE7 = await read(sE4.json?.access_token);
    const act40 = activityOf(userE) === actE40;
    check('E40-direct-email-change-review', em.status === 200 && rE6.json?.details === 'review_required' && rE7.json?.details === 'review_required' && act40,
      { stale_token: reason(rE6), fresh_sign_in: reason(rE7), activity_unchanged: act40, link: linkState(userE) });
    check('E41-changes-recorded-by-kind', /auth_users:phone, auth_users:phone, .*identity_account_links:link_active.*auth_users:email/.test(events(userE)),
      { events: events(userE) });

    // E42: global sign-out revokes every session of the account.
    const sA1 = await signIn(A, pwA);
    const sA2 = await signIn(A, pwA);
    const actA42 = activityOf(uid(A));
    const outAll = await http('POST', '/auth/v1/logout?scope=global', { token: sA1.json?.access_token });
    const rA1 = await read(sA1.json?.access_token);
    const rA2 = await read(sA2.json?.access_token);
    const rA2r = await refresh(sA2.json?.refresh_token);
    const act42 = activityOf(uid(A)) === actA42;
    check('E42-global-sign-out-revokes-all', outAll.status === 204 && rA1.status === 401 && rA2.status === 401 && rA2r.status >= 400 && act42,
      { logout_status: outAll.status, session_1: reason(rA1), session_2: reason(rA2), refresh_status: rA2r.status, activity_unchanged: act42 });

    // E43: ban (Auth Admin revocation); unbanning does not revive the old session.
    const sA3 = await signIn(A, pwA);
    const actA43 = activityOf(uid(A));
    const ban = await adminUpdate(uid(A), { ban_duration: '24h' });
    const rA3 = await read(sA3.json?.access_token);
    const unban = await adminUpdate(uid(A), { ban_duration: 'none' });
    const rA3b = await read(sA3.json?.access_token);
    const act43 = activityOf(uid(A)) === actA43;
    await pastMargin();
    const sA4 = await signIn(A, pwA);
    const rA4 = await read(sA4.json?.access_token);
    check('E43-ban-revokes-and-unban-does-not-revive',
      ban.status === 200 && rA3.status === 401 && unban.status === 200 && rA3b.status === 401 && act43 && rA4.status === 200,
      { banned: reason(rA3), old_session_after_unban: reason(rA3b), activity_unchanged: act43, fresh_sign_in: reason(rA4) });

    // E44: dormant labelled-fixture account: prior activity is read before any refresh.
    const pwF = password();
    await signUp(F, pwF);
    const userF = uid(F);
    psql(`select app.identity_seed_synthetic_link('${userF}', 'SYNTHETIC E2E Dormant Member', 'identity-e2e 2.2')`);
    psql(`update app.identity_account_links set last_member_activity_at = now() - interval '91 days' where auth_user_id = '${userF}'`);
    const dormantBefore = activityOf(userF);
    const fixture = psql(`select label from app.identity_settings where setting = 'dormancy_days' order by version desc limit 1`);
    const sF = await signIn(F, pwF);
    const sFr = await refresh(sF.json?.refresh_token);
    const rF = await read(sFr.json?.access_token);
    check('E44-dormant-fixture-denied-without-activity-update',
      sF.status === 200 && sFr.status === 200 && rF.json?.details === 'review_required' && activityOf(userF) === dormantBefore,
      { fixture_label: fixture, sign_in: sF.status, refresh: sFr.status, read: reason(rF), activity_unchanged: activityOf(userF) === dormantBefore });

    // E45: what Identity recorded for the alias account (kinds only).
    check('E45-recovery-reset-recorded', /auth_users:password/.test(events(userD)) && linkState(userD).startsWith('active'),
      { events: events(userD), link: linkState(userD) });
  } finally {
    const smsLines = execFileSync('docker', ['logs', '--since', startedAt, 'supabase_auth_church-app'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    const sent = smsLines.split('\n').filter((l) => /sms/i.test(l) && !/Unable to get SMS provider|sms_provider|missing/i.test(l));
    check('E98-no-sms-sent', sent.length === 0, { sms_send_lines: sent.length });
    const left = cleanup();
    if (marked) psql(`delete from app.platform_environment where set_by = 'identity-e2e'; delete from app.platform_environment_history where set_by = 'identity-e2e';`);
    check('E99-cleanup', left === '0', { synthetic_users_left: Number(left) });
  }
  const failed = results.filter((r) => !r.ok);
  console.log(failed.length ? `FAIL: ${failed.map((r) => r.step).join(', ')}` : `PASS: ${results.length} checks`);
  process.exit(failed.length ? 1 : 0);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((e) => {
    console.error(`identity-e2e: ${e.message}`);
    process.exit(1);
  });
}
