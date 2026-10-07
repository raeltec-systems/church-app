#!/usr/bin/env node
// Story 2.4 end-to-end on the LOCAL stack: register and apply for membership with a safe cell
// choice, through real GoTrue phone sign-up (no SMS, no email) and the real Data API.
//   * three new applicants sign up with phone + password only and apply with each choice
//     (a cell, I'm not sure, I'm not in a cell yet); each status shows church approval and the
//     cell status separately;
//   * one applicant corrects the request; a stale revision, a replay, a reused request id with a
//     changed body, status fields and a second open application are all refused;
//   * a duplicate username is rejected by Auth without overwriting the account or the request;
//   * the cell chooser exposes only label, broad area, id and revision;
//   * the pending accounts reach no member, access, roster, scoped or table surface, and own no
//     member, link or grant.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on` (no SMS
// provider, hook, test OTP or SMS MFA), then `off` afterwards.
// LOCAL only (exact origin), SYNTHETIC fictional numbers +1 202 555 0181-0182 and
// +44 7700 900181. Evidence is redacted JSONL: statuses, codes and revisions, never tokens,
// passwords or names beyond the SYNTHETIC labels. Every user, application, receipt and the
// synthetic cells it seeded are removed at the end.
//
// Usage: node tools/identity-e2e/apply.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';

/** The reserved fictional numbers this run uses. */
export function isFictionalApplyPhone(phone) {
  return /^\+1202555018[12]$/.test(phone) || phone === '+447700900181';
}

/** The only keys a cell sign-up option may carry (AD-5 safe projection). */
export const SAFE_OPTION_KEYS = ['broad_area', 'cell_id', 'label', 'revision'];

/** Keys of the options that are not in the safe projection (empty = safe). */
export function unsafeOptionKeys(options) {
  const keys = new Set((options ?? []).flatMap((o) => Object.keys(o ?? {})));
  return [...keys].filter((k) => !SAFE_OPTION_KEYS.includes(k)).sort();
}

const SEEDED_CELLS = ['00000000-0000-4000-c000-00000000c241', '00000000-0000-4000-c000-00000000c242',
  '00000000-0000-4000-c000-00000000c243'];

async function main() {
  const { log, check, finish } = startRun();
  const keys = localKey({ admin: false });
  const http = localHttp(keys);
  const signUp = (phone, pw) => http('POST', '/auth/v1/signup', { body: { phone, password: pw } });
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const command = (token, cmd, expected, payload, requestId = randomUUID()) =>
    rpc('identity_application_command', token, { version: 1, command: cmd, request_id: requestId, expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json, request_id: r.json?.request_id === requestId ? '[same]' : r.json?.request_id }));
  const err = (r) => ({ status: r.status, code: r.json?.error_code ?? r.json?.code ?? r.json?.message, detail: r.json?.details, msg: r.json?.msg });
  const sub = (jwt) => {
    try { return JSON.parse(Buffer.from(String(jwt).split('.')[1], 'base64url').toString('utf8')).sub; } catch { return null; }
  };
  const statusOf = (data) => data && ({ church_status: data.church_status, cell_status: data.cell_status,
    choice: data.cell_choice?.choice, revision: data.revision, application_state: data.application_state });

  const P = {
    one: { phone: '+12025550181', choice: 'cell', name: 'SYNTHETIC 2.4 E2E Applicant One' },
    two: { phone: '+12025550182', choice: 'not_sure', name: 'SYNTHETIC 2.4 E2E Applicant Two' },
    three: { phone: '+447700900181', choice: 'not_in_cell', name: 'SYNTHETIC 2.4 E2E Applicant Three' },
  };
  for (const p of Object.values(P)) if (!isFictionalApplyPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  const digits = Object.values(P).map((p) => `'${p.phone.slice(1)}'`).join(',');
  const ours = `(u.phone in (${digits}))`;
  const cleanup = () => psql(`
    delete from app.identity_application_events e using app.identity_membership_applications a, auth.users u
     where e.application_id = a.application_id and a.auth_user_id = u.id and ${ours};
    delete from app.identity_membership_applications a using auth.users u where a.auth_user_id = u.id and ${ours};
    delete from app.cmd_receipts r using auth.users u where r.actor_id = u.id and ${ours};
    delete from auth.users u where ${ours};
    select count(*) from auth.users u where ${ours};`);

  const settings = await http('GET', '/auth/v1/settings');
  if (settings.json?.external?.phone !== true) {
    throw new Error('the local phone provider is off: run `node tools/auth-harness/local-phone-auth.mjs on` first');
  }
  const marker = psql(`select coalesce((select environment from app.platform_environment), '')`);
  let marked = false;
  if (marker === '') {
    psql(`select app.platform_set_environment('local', 'identity-apply-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  const preexistingCells = Number(psql(`select count(*) from app.cells_cells where cell_id in (${SEEDED_CELLS.map((c) => `'${c}'`).join(',')})`));
  log('A00-precondition', {
    settings: { phone: settings.json?.external?.phone, phone_autoconfirm: settings.json?.phone_autoconfirm,
      sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
    seeded_options: Number(psql(`select app.cells_seed_synthetic_cells('identity-apply-e2e')`)),
  });
  const counts = () => psql(`select (select count(*) from app.identity_members) || '/' || (select count(*) from app.identity_account_links) || '/' || (select count(*) from app.identity_grants)`);
  const before = counts();

  try {
    const anonOptions = await rpc('cells_signup_options', null);
    check('A01-chooser-needs-sign-in', anonOptions.status === 401, err(anonOptions));

    for (const [name, p] of Object.entries(P)) {
      p.password = password();
      const up = await signUp(p.phone, p.password);
      p.token = up.json?.access_token;
      p.user = up.json?.user?.id;
      check(`A10-${name}-phone-signup-no-email`, up.status === 200 && amrMethods(p.token).includes('password')
        && !up.json?.user?.email,
        { status: up.status, amr: amrMethods(p.token), has_email: Boolean(up.json?.user?.email) });

      const opts = await rpc('cells_signup_options', p.token);
      p.options = opts.json?.options ?? [];
      check(`A11-${name}-chooser-safe-projection`, opts.status === 200 && p.options.length === 3
        && unsafeOptionKeys(p.options).length === 0,
        { status: opts.status, count: p.options.length, keys: [...new Set(p.options.flatMap(Object.keys))].sort(),
          labels: p.options.map((o) => o.label) });

      const empty = await rpc('identity_my_application', p.token);
      check(`A12-${name}-no-application-yet`, empty.status === 200 && empty.json?.application === null
        && empty.json?.accepting_applications === true,
        { status: empty.status, application: empty.json?.application, notice: empty.json?.privacy_notice });

      const cellChoice = p.choice === 'cell'
        ? { choice: 'cell', cell_id: p.options[0]?.cell_id, cell_revision: p.options[0]?.revision }
        : { choice: p.choice };
      const sent = await command(p.token, 'identity.submit_application', null,
        { full_name: p.name, cell_choice: cellChoice, privacy_notice_version: empty.json?.privacy_notice?.version });
      p.application = sent.data;
      const expectedCell = p.choice === 'cell' ? 'requested' : 'follow_up';
      check(`A13-${name}-applies-${p.choice}`, sent.status === 200 && sent.revision === 1
        && sent.data?.church_status === 'awaiting_approval' && sent.data?.cell_status === expectedCell,
        { status: sent.status, code: sent.code, ...statusOf(sent.data) });

      const mine = await rpc('identity_my_application', p.token);
      check(`A14-${name}-reads-own-status`, mine.status === 200
        && mine.json?.application?.application_id === p.application?.application_id,
        { status: mine.status, ...statusOf(mine.json?.application) });
    }

    const { one, two, three } = P;
    const corrReq = randomUUID();
    const corrPayload = { application_id: one.application?.application_id, full_name: 'SYNTHETIC 2.4 E2E Applicant One Corrected',
      cell_choice: { choice: 'not_in_cell' } };
    const corrected = await command(one.token, 'identity.correct_application', 1, corrPayload, corrReq);
    check('A20-correct-request', corrected.status === 200 && corrected.revision === 2
      && corrected.data?.cell_status === 'follow_up' && corrected.data?.full_name === corrPayload.full_name,
      { status: corrected.status, code: corrected.code, ...statusOf(corrected.data) });

    const stale = await command(one.token, 'identity.correct_application', 1,
      { application_id: one.application?.application_id, full_name: 'SYNTHETIC stale' });
    check('A21-stale-revision-conflict', stale.code === 'conflict' && stale.current_revision === 2,
      { code: stale.code, current_revision: stale.current_revision });

    const replay = await command(one.token, 'identity.correct_application', 1, corrPayload, corrReq);
    const reused = await command(one.token, 'identity.correct_application', 2,
      { application_id: one.application?.application_id, full_name: 'SYNTHETIC changed' }, corrReq);
    check('A22-replay-and-reused-request-id', replay.revision === 2 && replay.data?.full_name === corrPayload.full_name
      && reused.code === 'conflict', { replay_revision: replay.revision, reused: reused.code });

    const statusFields = await command(one.token, 'identity.correct_application', 2,
      { application_id: one.application?.application_id, application_state: 'approved', cell_status: 'confirmed' });
    check('A23-cannot-set-membership-or-cell-status', statusFields.code === 'validation_failed'
      && statusFields.field_errors?.application_state === 'unknown_field'
      && statusFields.field_errors?.cell_status === 'unknown_field',
      { code: statusFields.code, field_errors: statusFields.field_errors });

    const second = await command(two.token, 'identity.submit_application', null,
      { full_name: two.name, cell_choice: { choice: 'not_sure' }, privacy_notice_version: 'draft-2026-10-07' });
    check('A24-one-open-application', second.code === 'conflict' && second.current_revision === 1,
      { code: second.code, current_revision: second.current_revision });

    // Duplicate username: Auth refuses it; the original account, password and request survive.
    const usersBefore = psql(`select count(*) from auth.users u where u.phone = '${one.phone.slice(1)}'`);
    const dupPassword = password();
    const dup = await signUp(one.phone, dupPassword);
    const withDup = await signIn(one.phone, dupPassword);
    const old = await signIn(one.phone, one.password);
    const after = await rpc('identity_my_application', old.json?.access_token);
    check('A30-duplicate-username-no-overwrite', dup.status === 422 && !dup.json?.access_token
      && withDup.status === 400 && !withDup.json?.access_token
      && old.status === 200 && sub(old.json?.access_token) === one.user
      && psql(`select count(*) from auth.users u where u.phone = '${one.phone.slice(1)}'`) === usersBefore
      && after.json?.application?.revision === 2 && after.json?.application?.full_name === corrPayload.full_name,
      { duplicate: err(dup), duplicate_password_sign_in: withDup.status, original_sign_in: old.status, same_account: sub(old.json?.access_token) === one.user,
        accounts_for_number: Number(usersBefore), application_revision: after.json?.application?.revision });
    one.token = old.json?.access_token;

    // The pending account reaches only its own status and public content.
    const summary = await rpc('identity_my_member_summary', one.token);
    const access = await rpc('identity_my_access', one.token);
    const roster = await rpc('identity_admin_member_grants', one.token);
    const scoped = await rpc('fixture_scoped_read', one.token, { scope_kind: 'fixture_care', scope_id: randomUUID() });
    check('A40-pending-no-member-surfaces', [summary, access, roster, scoped].every((r) => r.status === 403 && r.json?.details === 'not_linked'),
      { summary: err(summary), access: err(access), roster: err(roster), scoped: err(scoped) });
    const tables = await Promise.all([
      http('GET', '/rest/v1/identity_membership_applications', { token: one.token, profile: 'app' }),
      http('GET', '/rest/v1/cells_cells', { token: one.token, profile: 'app' }),
      http('GET', '/rest/v1/identity_membership_applications', { token: one.token, profile: 'api' }),
      http('GET', '/rest/v1/cells_signup_options', { token: one.token, profile: 'api' }),
    ]);
    check('A41-pending-no-direct-tables', tables[0].status === 406 && tables[1].status === 406
      && tables[2].status === 404 && tables[3].status === 404, { statuses: tables.map((t) => t.status) });
    const own2 = await rpc('identity_my_application', two.token);
    const own3 = await rpc('identity_my_application', three.token);
    const ids = [one.application?.application_id, own2.json?.application?.application_id, own3.json?.application?.application_id];
    check('A42-each-applicant-sees-only-their-own', new Set(ids).size === 3 && ids.every(Boolean),
      { distinct_applications: new Set(ids).size });
    const nowCounts = counts();
    const links = psql(`select count(*) from app.identity_account_links l join auth.users u on u.id = l.auth_user_id where ${ours}`);
    check('A43-applying-grants-nothing', nowCounts === before && links === '0',
      { members_links_grants_before: before, after: nowCounts, applicant_links: Number(links) });
    const emails = psql(`select count(*) from auth.users u where ${ours} and u.email is not null`);
    check('A44-no-email-collected', emails === '0', { applicant_emails: Number(emails) });
  } finally {
    const left = cleanup();
    if (preexistingCells === 0) {
      psql(`delete from app.cells_signup_options where cell_id in (${SEEDED_CELLS.map((c) => `'${c}'`).join(',')});
            delete from app.cells_cells where cell_id in (${SEEDED_CELLS.map((c) => `'${c}'`).join(',')});`);
    }
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'identity-apply-e2e';
            delete from app.platform_environment_history where set_by = 'identity-apply-e2e';`);
    }
    log('A99-cleanup', { applicant_users_left: Number(left), unmarked: marked, cells_removed: preexistingCells === 0 });
  }
  finish();
}

runMain(import.meta.url, main);
