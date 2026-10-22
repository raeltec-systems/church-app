#!/usr/bin/env node
// Stories 6.3 and 6.5 end-to-end on the LOCAL stack: verified giving methods and the anonymous How
// to give read, through real GoTrue phone sign-in (no SMS) and the real Data API (PostgREST), proving the
// ticket's verify at the API level:
//   * Admin A drafts SAMPLE mobile-money and bank methods; a newly granted Admin is refused
//     verification for 14 elapsed days; Media, a Pastor, a plain member, a Pending account and anon
//     cannot; nobody outside the Admins sees a draft;
//   * Admin A cannot verify a method Admin A saved (owner decision 2026-10-21); Admin B verifies,
//     Admin A publishes and reorders them, and a signed-out caller (publishable key only) reads
//     every copyable value in the church's order;
//   * changing an account number refuses publication until a different Admin verifies it again,
//     while the old revision stays live;
//   * Media, a Pastor and a plain member are refused every giving command and the Admins' read;
//   * any amount or payer field is rejected;
//   * anonymous, Pending and member callers read no draft or verification evidence (verifier, test
//     note, editor identity), and no client role reads or writes a giving table;
//   * hiding removes a method on refresh and publishing brings it back; unsafe flags are public,
//     reversible, audited and do not alter the published instructions;
//   * once Content's deletion hook has erased an Admin (as the 2.11 worker's erase step calls it),
//     the Admins' read shows that Admin as a former member and the check answers 0.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards, and a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900510-900518; every method is a SAMPLE with
// obviously fictional values. Evidence is redacted JSONL: statuses, codes, counts and booleans;
// never tokens, passwords, numbers or destination values. Everything it created is removed.
//
// Usage: node tools/identity-e2e/content-giving.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 6.3 E2E';
export const MOBILE = 'SAMPLE Mobile Money (6.3 E2E)';
export const BANK = 'SAMPLE Bank transfer (6.3 E2E)';
const FORMER = 'SAMPLE At church (6.3 E2E)';
const TEST_NOTE = 'SAMPLE check (6.3 E2E): the treasurer checked that the provider showed the church name for these details.';
const OLD_ACCOUNT = '9900 1234 5678';
const NEW_ACCOUNT = '9900 8765 4321';

/** The public projection's keys, exactly. */
export const PUBLIC_KEYS = ['contact', 'currency', 'details', 'logo', 'method_id', 'method_type', 'name', 'note',
  'publication_revision', 'published_at', 'purpose', 'steps', 'unsafe', 'ussd_code', 'verified_on'];

/** The reserved fictional numbers this run uses (+44 7700 900510-900518). */
export function isFictionalGivingPhone(phone) {
  return /^\+44770090051[0-8]$/.test(phone);
}

/** The church date (YYYY-MM-DD, Africa/Lusaka, UTC+2) `days` before `nowMs`. */
export function churchDaysAgo(nowMs, days) {
  return new Date(nowMs + 2 * 3_600_000 - days * 86_400_000).toISOString().slice(0, 10);
}

/** The keys of an object, sorted. */
export function sortedKeys(o) {
  return Object.keys(o ?? {}).sort();
}

/** The public method with this id in a list read, or undefined. */
export function findMethod(list, id) {
  return (list?.methods ?? []).find((m) => m.method_id === id);
}

/** A method's copyable value for `key` (`account_number`, `merchant_id`, ...), or undefined. */
export function detail(method, key) {
  return (method?.details ?? []).find((d) => d.key === key)?.value;
}

/** A create payload for a SAMPLE mobile money method (fictional values only). */
export function mobilePayload(name) {
  return {
    method_type: 'mobile_money', name, purpose: 'Tithes and offerings', currency: 'ZMW',
    beneficiary: 'SAMPLE Brethren in Christ Church Kafue', identifier_kind: 'merchant', identifier: '990177',
    ussd_code: '*990*7#',
    steps: ['Dial the starting code on your SAMPLE line.', 'Choose Pay merchant.', 'Enter the merchant ID shown above.',
      'Check the name shown is the church, then confirm with your PIN.'],
    note: 'SAMPLE: the provider may charge a fee.', contact: 'SAMPLE church office, +260 97 000 0177',
  };
}

/** A create payload for a SAMPLE bank method (fictional values only). */
export function bankPayload(name, accountNumber) {
  return {
    method_type: 'bank', name, purpose: 'Building project', currency: 'ZMW', bank_name: 'SAMPLE Bank of Testing',
    beneficiary: 'SAMPLE BICC Kafue', account_number: accountNumber, branch: 'SAMPLE Kafue branch', branch_code: '990177',
    swift_code: 'SMPLZMLU', reference: 'Your name and BUILDING',
    steps: ['Open your banking app.', 'Pay the account shown above with the reference.'],
    note: null, contact: 'SAMPLE church office, +260 97 000 0177',
  };
}

/** A save payload from a create payload. */
export function savePayload(id, created) {
  const { method_type: _type, ...rest } = created;
  return { method_id: id, ...rest };
}

async function main() {
  const { log, check, finish } = startRun();
  const keys = localKey();
  const http = localHttp(keys);
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const envelope = (fn, token, cmd, expected, payload, requestId = randomUUID()) =>
    rpc(fn, token, { version: 1, command: cmd, request_id: requestId, expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const content = (token, cmd, expected, payload) => envelope('content_command', token, cmd, expected, payload);
  // token undefined = the publishable key only (signed out).
  const publicList = async (token) => (await rpc('content_public_giving_methods', token)).json;
  const publicOne = async (token, id) => (await rpc('content_public_giving_method', token, { method_id: id })).json;
  const staff = async (token) => {
    const r = await rpc('content_staff_giving_methods', token);
    return { status: r.status, json: r.json, detail: r.json?.details ?? null };
  };
  const staffMethod = async (token, id) => (await staff(token)).json?.methods?.find((m) => m.method_id === id);
  const today = Date.now();
  const verifyPayload = (id, days = 0) => ({ method_id: id, tested_on: churchDaysAgo(today, days), test_method: TEST_NOTE });

  const people = {
    adminA: { phone: '+447700900510', name: `${NAME_PREFIX} Admin A` },
    adminB: { phone: '+447700900511', name: `${NAME_PREFIX} Admin B` },
    media: { phone: '+447700900512', name: `${NAME_PREFIX} Media` },
    pastor: { phone: '+447700900513', name: `${NAME_PREFIX} Pastor` },
    member: { phone: '+447700900514', name: `${NAME_PREFIX} Member` },
    pending: { phone: '+447700900515', name: `${NAME_PREFIX} Pending`, noLink: true },
    former: { phone: '+447700900516', name: `${NAME_PREFIX} Admin C` },
    adminRecent: { phone: '+447700900517', name: `${NAME_PREFIX} Recent Admin` },
  };
  for (const p of Object.values(people)) if (!isFictionalGivingPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  const users = new Set();
  const digits = Object.values(people).map((p) => `'${p.phone.slice(1)}'`).join(',');
  const cleanup = () => {
    const ids = [...users].filter(Boolean).map((u) => `'${u}'`);
    const byUser = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    return psql(`
    create temp table gone_users as select u.id from auth.users u where ${byUser} u.phone in (${digits});
    create temp table gone_members as
      select m.member_id from app.identity_members m where m.display_name like '${NAME_PREFIX}%';
    create temp table gone_items as
      select distinct r.item_id from app.content_giving_revisions r where r.name like 'SAMPLE % (6.3 E2E)';
    delete from app.content_giving_audit a where a.item_id in (select item_id from gone_items);
    delete from app.content_audit a where a.item_id in (select item_id from gone_items);
    delete from app.content_giving_revisions r where r.item_id in (select item_id from gone_items);
    delete from app.content_giving_methods g where g.item_id in (select item_id from gone_items);
    delete from app.content_items i where i.item_id in (select item_id from gone_items);
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
    psql(`select app.platform_set_environment('local', 'content-giving-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('G00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  try {
    const { adminA, adminB, adminRecent, media, pastor, member, pending, former } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      if (!p.noLink) p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'content-giving-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    psql(`select app.identity_bootstrap_admin('${adminA.member}', '${OPERATOR}')`);
    const revisionOf = (p) => Number(psql(`select revision from app.identity_grant_sets where member_id = '${p.member}'`));
    const grants = [];
    for (const [p, role] of [[adminB, 'admin'], [former, 'admin'], [adminRecent, 'admin'],
      [media, 'media'], [pastor, 'pastor']]) {
      grants.push(await envelope('identity_grant_command', adminA.token, 'identity.grant_role', revisionOf(p),
        { member_id: p.member, role }));
    }
    psql(`update app.identity_grants set granted_at = now() - interval '14 days'
           where member_id in ('${adminA.member}', '${adminB.member}')
             and role = 'admin' and revoked_at is null`);
    const recentAccess = await rpc('identity_my_access', adminRecent.token);
    const recentTenure = recentAccess.json?.admin_tenure;
    check('G01-signed-in-by-phone-and-roles-granted', Object.values(people).every((p) => amrMethods(p.token).includes('password'))
      && grants.every((g) => g.status === 200) && recentAccess.status === 200
      && typeof recentTenure?.granted_at === 'string'
      && /^\d{4}-\d{2}-\d{2}$/.test(recentTenure?.admin_since ?? '')
      && recentTenure?.granted_by === adminA.name,
      { amr: amrMethods(adminA.token), grants: grants.map((g) => g.status),
        own_tenure: Boolean(recentTenure), grantor_is_admin_a: recentTenure?.granted_by === adminA.name });

    // ------------------------------------------------------------------ drafts (Admin A), private
    const mobileBody = mobilePayload(MOBILE);
    const bankBody = bankPayload(BANK, OLD_ACCOUNT);
    const refusedCreates = {};
    for (const [who, p] of [['media', media], ['pastor', pastor], ['member', member], ['pending', pending]]) {
      refusedCreates[who] = (await content(p.token, 'content.create_giving_method', null, mobileBody)).code;
    }
    const byAnon = await rpc('content_command', undefined,
      { version: 1, command: 'content.create_giving_method', request_id: randomUUID(), expected_revision: null, payload: mobileBody });
    const mobile = await content(adminA.token, 'content.create_giving_method', null, mobileBody);
    const bank = await content(adminA.token, 'content.create_giving_method', null, bankBody);
    const mobileId = mobile.data?.method_id;
    const bankId = bank.data?.method_id;
    const anon0 = await publicList(undefined);
    const pending0 = await publicList(pending.token);
    check('G10-admin-drafts-privately', mobile.status === 200 && mobile.data?.state === 'draft' && bank.data?.state === 'draft'
      && Object.values(refusedCreates).every((c) => c === 'forbidden') && byAnon.status === 401
      && !findMethod(anon0, mobileId) && !findMethod(pending0, bankId) && (await publicOne(undefined, mobileId))?.method === null,
      { drafts: [mobile.data?.state, bank.data?.state], refused: refusedCreates, anon_status: byAnon.status,
        anon_sees_draft: Boolean(findMethod(anon0, mobileId)) });

    // ------------------------------------------------------------------ the second Admin verifies
    const ownVerify = await content(adminA.token, 'content.verify_giving_method', mobile.revision, verifyPayload(mobileId));
    const unverifiedPublish = await content(adminA.token, 'content.publish_giving_method', mobile.revision, { method_id: mobileId });
    const beforeSaved = await content(adminB.token, 'content.verify_giving_method', mobile.revision, verifyPayload(mobileId, 1));
    const recentVerify = await content(adminRecent.token, 'content.verify_giving_method', mobile.revision, verifyPayload(mobileId));
    const afterRecentVerify = await staffMethod(adminA.token, mobileId);
    const vMobile = await content(adminB.token, 'content.verify_giving_method', mobile.revision, verifyPayload(mobileId));
    const vBank = await content(adminB.token, 'content.verify_giving_method', bank.revision, verifyPayload(bankId));
    const seen = await staffMethod(adminA.token, mobileId);
    check('G11-only-a-different-admin-verifies', ownVerify.code === 'validation_failed'
      && ownVerify.field_errors?.method_id === 'saved_by_you'
      && unverifiedPublish.field_errors?.method_id === 'not_verified'
      && beforeSaved.field_errors?.tested_on === 'before_saved'
      && recentVerify.field_errors?.admin_tenure === 'not_eligible'
      && afterRecentVerify?.revision === mobile.revision
      && vMobile.status === 200 && vBank.status === 200
      && seen?.draft?.verification?.verified_by === adminB.name && seen?.draft?.saved_by_you === true,
      { own_verify: ownVerify.field_errors?.method_id, unverified_publish: unverifiedPublish.field_errors?.method_id,
        tested_before_save: beforeSaved.field_errors?.tested_on,
        recent_admin: recentVerify.field_errors?.admin_tenure, revision_unchanged: afterRecentVerify?.revision === mobile.revision,
        verified: [vMobile.status, vBank.status], verifier_named: seen?.draft?.verification?.verified_by === adminB.name });

    // ------------------------------------------------------------------ publish, reorder, read signed out
    const pMobile = await content(adminA.token, 'content.publish_giving_method', vMobile.revision, { method_id: mobileId });
    const pBank = await content(adminA.token, 'content.publish_giving_method', vBank.revision, { method_id: bankId });
    const order0 = (await publicList(undefined))?.methods?.map((m) => m.method_id);
    const moved = await content(adminA.token, 'content.move_giving_method', pBank.revision, { method_id: bankId, position: 1 });
    const anon1 = await publicList(undefined);
    const m1 = findMethod(anon1, mobileId);
    const b1 = findMethod(anon1, bankId);
    const one1 = (await publicOne(undefined, bankId))?.method;
    const copyable = [
      detail(m1, 'beneficiary') === mobileBody.beneficiary, detail(m1, 'merchant_id') === mobileBody.identifier,
      m1?.ussd_code === mobileBody.ussd_code, detail(b1, 'bank_name') === bankBody.bank_name,
      detail(b1, 'beneficiary') === bankBody.beneficiary, detail(b1, 'account_number') === OLD_ACCOUNT,
      detail(b1, 'branch') === bankBody.branch, detail(b1, 'branch_code') === bankBody.branch_code,
      detail(b1, 'swift_code') === bankBody.swift_code, detail(b1, 'reference') === bankBody.reference,
    ];
    check('G12-published-and-reordered-signed-out-reads-every-value', pMobile.status === 200 && pBank.status === 200
      && moved.status === 200 && order0?.[0] === mobileId && anon1?.methods?.[0]?.method_id === bankId
      && anon1?.methods?.[1]?.method_id === mobileId && anon1?.sample === true && copyable.every(Boolean)
      && JSON.stringify(m1?.steps) === JSON.stringify(mobileBody.steps) && m1?.verified_on === churchDaysAgo(today, 0)
      && m1?.contact === mobileBody.contact && JSON.stringify(sortedKeys(b1)) === JSON.stringify(PUBLIC_KEYS)
      && JSON.stringify(one1) === JSON.stringify(b1),
      { published: [pMobile.data?.state, pBank.data?.state], order_before: order0?.indexOf(bankId),
        order_after: anon1?.methods?.findIndex((m) => m.method_id === bankId), copyable_values: copyable.filter(Boolean).length,
        sample: anon1?.sample, keys: sortedKeys(b1) });

    // ------------------------------------------------------------------ changed account number: re-verification
    const changed = await content(adminA.token, 'content.save_giving_method', moved.revision,
      savePayload(bankId, bankPayload(BANK, NEW_ACCOUNT)));
    const refusedPublish = await content(adminA.token, 'content.publish_giving_method', changed.revision, { method_id: bankId });
    const refusedOwn = await content(adminA.token, 'content.verify_giving_method', changed.revision, verifyPayload(bankId));
    // Another Admin's save that changes nothing is refused, and one that changes something makes
    // them a saver too: the Admin who changed the number still cannot verify it.
    const noOp = await content(adminB.token, 'content.save_giving_method', changed.revision,
      savePayload(bankId, bankPayload(BANK, NEW_ACCOUNT)));
    const touched = await content(adminB.token, 'content.save_giving_method', changed.revision,
      { ...savePayload(bankId, bankPayload(BANK, NEW_ACCOUNT)), note: 'SAMPLE: the bank may charge a fee.' });
    const changerVerify = await content(adminA.token, 'content.verify_giving_method', touched.revision, verifyPayload(bankId));
    const toucherVerify = await content(adminB.token, 'content.verify_giving_method', touched.revision, verifyPayload(bankId));
    const whileUnverified = detail((await publicOne(undefined, bankId))?.method, 'account_number');
    const discarded = await content(adminB.token, 'content.discard_giving_draft', touched.revision, { method_id: bankId });
    const afterDiscard = detail((await publicOne(undefined, bankId))?.method, 'account_number');
    const again = await content(adminA.token, 'content.save_giving_method', discarded.revision,
      savePayload(bankId, bankPayload(BANK, NEW_ACCOUNT)));
    const reVerified = await content(adminB.token, 'content.verify_giving_method', again.revision, verifyPayload(bankId));
    const whileVerified = detail((await publicOne(undefined, bankId))?.method, 'account_number');
    const republished = await content(adminA.token, 'content.publish_giving_method', reVerified.revision, { method_id: bankId });
    const afterRepublish = (await publicOne(undefined, bankId))?.method;
    check('G13-changed-account-refused-until-a-different-admin-verifies-old-revision-live', changed.status === 200
      && changed.data?.draft_revision_no === 2 && refusedPublish.field_errors?.method_id === 'not_verified'
      && refusedOwn.field_errors?.method_id === 'saved_by_you' && noOp.field_errors?.method_id === 'unchanged'
      && touched.status === 200 && changerVerify.field_errors?.method_id === 'saved_by_you'
      && toucherVerify.field_errors?.method_id === 'saved_by_you' && whileUnverified === OLD_ACCOUNT
      && discarded.status === 200 && discarded.data?.draft_revision_no === null && afterDiscard === OLD_ACCOUNT
      && again.data?.draft_revision_no === 3 && reVerified.status === 200 && whileVerified === OLD_ACCOUNT
      && republished.status === 200 && detail(afterRepublish, 'account_number') === NEW_ACCOUNT
      && afterRepublish?.publication_revision === 3 && afterRepublish?.verified_on === churchDaysAgo(today, 0),
      { publish_unverified: refusedPublish.field_errors?.method_id, own_verify: refusedOwn.field_errors?.method_id,
        no_op_save: noOp.field_errors?.method_id, changer_after_other_save: changerVerify.field_errors?.method_id,
        other_saver: toucherVerify.field_errors?.method_id, discarded: discarded.status,
        old_live_while_unverified: whileUnverified === OLD_ACCOUNT, old_live_until_published: whileVerified === OLD_ACCOUNT,
        new_live_after: detail(afterRepublish, 'account_number') === NEW_ACCOUNT, publication_revision: afterRepublish?.publication_revision });

    // ------------------------------------------------------------------ Media, Pastor and a plain member refused every command
    const current = republished.revision;
    const commands = [
      ['content.create_giving_method', null, mobileBody],
      ['content.save_giving_method', current, savePayload(bankId, bankPayload(BANK, NEW_ACCOUNT))],
      ['content.verify_giving_method', current, verifyPayload(bankId)],
      ['content.publish_giving_method', current, { method_id: bankId }],
      ['content.hide_giving_method', current, { method_id: bankId }],
      ['content.archive_giving_method', current, { method_id: bankId }],
      ['content.move_giving_method', current, { method_id: bankId, position: 2 }],
      ['content.discard_giving_draft', current, { method_id: bankId }],
      ['content.set_giving_method_unsafe', current, { method_id: bankId, unsafe: true }],
    ];
    const refusals = [];
    for (const p of [media, pastor, member]) {
      for (const [cmd, expected, payload] of commands) refusals.push((await content(p.token, cmd, expected, payload)).code);
    }
    const staffReads = {};
    for (const [who, p] of [['media', media], ['pastor', pastor], ['member', member], ['pending', pending]]) {
      const r = await staff(p.token);
      staffReads[who] = `${r.status}:${r.detail}`;
    }
    const anonStaff = await staff(undefined);
    const unchanged = (await staffMethod(adminA.token, bankId))?.revision === current;
    check('G14-media-pastor-and-member-refused-every-giving-command', refusals.length === 27
      && refusals.every((c) => c === 'forbidden') && staffReads.media === '403:not_granted'
      && staffReads.pastor === '403:not_granted' && staffReads.member === '403:not_granted'
      && staffReads.pending.startsWith('403') && anonStaff.status === 401 && unchanged,
      { refusals: refusals.length, forbidden: refusals.filter((c) => c === 'forbidden').length, staff_reads: staffReads,
        anon_staff_read: anonStaff.status, unchanged });

    // ------------------------------------------------------------------ any amount or payer field is rejected
    const withAmount = await content(adminA.token, 'content.create_giving_method', null,
      { ...mobileBody, amount: '100.00', payer_phone: '+447700900517' });
    const saveWithPayer = await content(adminA.token, 'content.save_giving_method', current,
      { ...savePayload(bankId, bankPayload(BANK, NEW_ACCOUNT)), payer_name: 'SAMPLE payer', transaction_id: 'SAMPLE-1' });
    const verifyWithProof = await content(adminB.token, 'content.verify_giving_method', current,
      { ...verifyPayload(bankId), proof_of_payment: 'SAMPLE' });
    check('G15-amount-and-payer-fields-rejected', withAmount.field_errors?.amount === 'unknown_field'
      && withAmount.field_errors?.payer_phone === 'unknown_field' && saveWithPayer.field_errors?.payer_name === 'unknown_field'
      && saveWithPayer.field_errors?.transaction_id === 'unknown_field'
      && verifyWithProof.field_errors?.proof_of_payment === 'unknown_field'
      && (await staffMethod(adminA.token, bankId))?.revision === current,
      { create: withAmount.field_errors, save: saveWithPayer.field_errors, verify: verifyWithProof.field_errors });

    // ------------------------------------------------------------------ no draft or verification evidence for anyone else
    await content(adminA.token, 'content.save_giving_method', current,
      savePayload(bankId, bankPayload('SAMPLE Bank transfer DRAFT (6.3 E2E)', '9900 0000 7777')));
    const reads = [await publicList(undefined), await publicList(pending.token), await publicList(member.token),
      await publicOne(undefined, bankId), await publicOne(member.token, mobileId)];
    const texts = reads.map((x) => JSON.stringify(x));
    const leaks = [adminA.member, adminA.user, adminA.name, adminB.name, adminB.member, TEST_NOTE, '9900 0000 7777', 'DRAFT',
      'saved_by', 'published_by', 'created_by', 'verified_by', 'verification', 'test_method', 'tested_on', 'draft']
      .filter((v) => texts.some((t) => t.includes(v)));
    check('G16-anon-pending-and-member-read-no-draft-or-verification-evidence', leaks.length === 0
      && texts[0] === texts[1] && texts[1] === texts[2] && detail(findMethod(reads[0], bankId), 'account_number') === NEW_ACCOUNT,
      { leaked: leaks.length, same_for_anon_pending_member: texts[0] === texts[1] && texts[1] === texts[2] });

    // ------------------------------------------------------------------ no client role touches a giving table
    const tables = [];
    for (const t of ['content_giving_methods', 'content_giving_revisions', 'content_giving_audit']) {
      for (const [who, token] of [['anon', undefined], ['member', member.token], ['admin', adminA.token]]) {
        for (const profile of ['app', 'api']) {
          const read = await http('GET', `/rest/v1/${t}?select=*`, { token, profile });
          const write = await http('POST', `/rest/v1/${t}`, { token, profile, body: { method_type: 'bank' } });
          tables.push({ t, who, profile, refused: read.status >= 400 && write.status >= 400 && !Array.isArray(read.json) });
        }
      }
    }
    check('G17-no-client-role-reads-or-writes-a-giving-table', tables.every((x) => x.refused),
      { attempts: tables.length, refused: tables.filter((x) => x.refused).length });

    // ------------------------------------------------------------------ unsafe warning is public and reversible
    const mobileRevision = (await staffMethod(adminA.token, mobileId))?.revision;
    const flagged = await content(adminA.token, 'content.set_giving_method_unsafe', mobileRevision,
      { method_id: mobileId, unsafe: true });
    const flaggedList = await publicList(undefined);
    const flaggedMethod = (await publicOne(undefined, mobileId))?.method;
    const flaggedAudit = psql(`select action || ':' || array_to_string(changed_fields, ',')
      from app.content_giving_audit where item_id = '${mobileId}' and action = 'unsafe_flagged'`);
    const unchangedFlag = await content(adminA.token, 'content.set_giving_method_unsafe', flagged.revision,
      { method_id: mobileId, unsafe: true });
    const cleared = await content(adminA.token, 'content.set_giving_method_unsafe', flagged.revision,
      { method_id: mobileId, unsafe: false });
    const clearedList = await publicList(undefined);
    const clearedMethod = (await publicOne(undefined, mobileId))?.method;
    const clearedAudit = psql(`select action || ':' || array_to_string(changed_fields, ',')
      from app.content_giving_audit where item_id = '${mobileId}' and action = 'unsafe_cleared'`);
    check('G18-unsafe-flag-is-public-reversible-and-audited', flagged.status === 200
      && flagged.data?.state === 'published' && flaggedMethod?.unsafe === true
      && findMethod(flaggedList, mobileId)?.unsafe === true && unchangedFlag.field_errors?.unsafe === 'unchanged'
      && cleared.status === 200 && clearedMethod?.unsafe === false && findMethod(clearedList, mobileId)?.unsafe === false
      && flaggedAudit === 'unsafe_flagged:unsafe' && clearedAudit === 'unsafe_cleared:unsafe'
      && detail(clearedMethod, 'merchant_id') === mobileBody.identifier,
      { flagged: flaggedMethod?.unsafe, cleared: clearedMethod?.unsafe,
        unchanged: unchangedFlag.field_errors?.unsafe, audit: [flaggedAudit, clearedAudit],
        instructions_preserved: detail(clearedMethod, 'merchant_id') === mobileBody.identifier });

    // ------------------------------------------------------------------ hide, then publish again
    const mobileRev = (await staffMethod(adminA.token, mobileId))?.revision;
    const hidden = await content(adminB.token, 'content.hide_giving_method', mobileRev, { method_id: mobileId });
    const afterHide = await publicList(undefined);
    const shown = await content(adminB.token, 'content.publish_giving_method', hidden.revision, { method_id: mobileId });
    const afterShow = await publicList(undefined);
    check('G19-hide-removes-on-refresh-and-publishing-brings-it-back', hidden.status === 200 && hidden.data?.state === 'withdrawn'
      && !findMethod(afterHide, mobileId) && (await publicOne(undefined, mobileId))?.method?.method_id === mobileId
      && shown.status === 200 && Boolean(findMethod(afterShow, mobileId)),
      { hidden: hidden.data?.state, listed_after_hide: Boolean(findMethod(afterHide, mobileId)),
        listed_after_publish: Boolean(findMethod(afterShow, mobileId)) });

    // ------------------------------------------------------------------ an erased Admin reads as a former member
    const church = await content(former.token, 'content.create_giving_method', null, {
      method_type: 'other', name: FORMER, purpose: 'Offering during the service', currency: null,
      steps: ['Bring your gift to the Sunday service.'], note: null, contact: 'SAMPLE church office, +260 97 000 0177',
    });
    const churchId = church.data?.method_id;
    const vChurch = await content(adminA.token, 'content.verify_giving_method', church.revision, verifyPayload(churchId));
    const pChurch = await content(former.token, 'content.publish_giving_method', vChurch.revision, { method_id: churchId });
    const hook = (phase) => JSON.parse(psql(`select app.content_erase_member(jsonb_build_object(
      'member_id', '${former.member}', 'account_id', '${former.user}', 'deletion_id', gen_random_uuid(), 'phase', '${phase}'))`));
    const before = hook('check');
    const erased = hook('erase');
    const after = hook('check');
    const adminView = await staffMethod(adminA.token, churchId);
    check('G20-erased-admin-reads-as-a-former-member', pChurch.status === 200 && before.remaining > 0
      && erased.remaining === 0 && after.remaining === 0
      && adminView?.created_by === 'Former member' && adminView?.published_by === 'Former member'
      && adminView?.live?.saved_by === 'Former member' && adminView?.live?.verification?.verified_by === adminA.name
      && Boolean(findMethod(await publicList(undefined), churchId)),
      { before: before.remaining, after: after.remaining, created_by: adminView?.created_by,
        published_by: adminView?.published_by, saved_by: adminView?.live?.saved_by });

    const auditText = psql(`select coalesce(string_agg(a::text, ' '), '') from (
        select a::text from app.content_audit a where a.item_id in ('${mobileId}', '${bankId}', '${churchId}')
        union all
        select g::text from app.content_giving_audit g where g.item_id in ('${mobileId}', '${bankId}', '${churchId}')) a`);
    const leaked = [MOBILE, BANK, FORMER, OLD_ACCOUNT, NEW_ACCOUNT, TEST_NOTE, mobileBody.identifier,
      ...Object.values(people).map((p) => p.phone.slice(1)), ...Object.values(people).map((p) => p.name)]
      .filter((v) => auditText.includes(v));
    check('G30-audit-content-free', leaked.length === 0 && auditText.length > 0, { leaked_values: leaked.length,
      actions: psql(`select string_agg(action, ',' order by event_id) from app.content_giving_audit where item_id = '${bankId}'`) });
  } finally {
    const left = cleanup();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'content-giving-e2e';
            delete from app.platform_environment_history where set_by = 'content-giving-e2e';`);
    }
    const usersLeft = Number(left);
    const methodsLeft = Number(psql(`select count(*) from app.content_giving_revisions where name like 'SAMPLE % (6.3 E2E)'`));
    const givingLogoSlotsLeft = Number(psql(`select count(*) from app.content_revision_files where purpose = 'giving_logo'`));
    log('G99-cleanup', { users_left: usersLeft, unmarked: marked, methods_left: methodsLeft,
      giving_logo_slots_left: givingLogoSlotsLeft });
    check('G99-cleanup-leaves-no-giving-records', usersLeft === 0 && methodsLeft === 0
      && givingLogoSlotsLeft === 0, { users_left: usersLeft, methods_left: methodsLeft,
        giving_logo_slots_left: givingLogoSlotsLeft });
  }
  finish();
}

runMain(import.meta.url, main);
