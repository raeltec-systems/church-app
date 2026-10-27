#!/usr/bin/env node
// Story 6.8 end-to-end on the LOCAL stack: hymn favourites and Hymns for this Sunday, through real
// GoTrue phone sign-in (no SMS), the real Data API (PostgREST) and the real Identity grant command,
// proving the ticket's verify at the API level:
//   * a member saves and removes favourites from two sessions (two phones) and each session reads
//     the other's change; another member, Admin and Media read only their own; nobody can remove
//     someone else's; numbers outside the built-in edition (bicc-tonga-2012: hymns 1-199,
//     choruses 1-67) are refused;
//   * a guest (publishable key only) cannot read or save favourites and a Pending account is
//     refused (the apps then ask a guest to sign in);
//   * an Admin makes a SYNTHETIC member a worship leader through identity.grant_scope (a scope on the
//     church's one Sunday-list record); the worship leader and then a Media member set this
//     Sunday's list (the coming Sunday in church time); a plain member and a Pastor are refused, a
//     stale revision conflicts, and anyone reads the list signed out in exactly the public
//     projection (date, edition, item ids; no name, time or capacity);
//   * revoking the scope refuses the worship leader at once;
//   * no client role reads or writes a table of this story;
//   * Content's deletion hook (as the 2.11 worker's erase step calls it) erases a member's
//     favourites and anonymises the lists they saved, and the check answers 0 (locally the _rows
//     body is applied; on staging the owner applies it by hand).
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards, and a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900641-900649. Evidence is redacted JSONL:
// statuses, codes, counts and booleans; never tokens, passwords or numbers. Everything it created is
// removed.
//
// Usage: node tools/identity-e2e/content-hymn-lists.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 6.8 E2E';
export const EDITION = 'bicc-tonga-2012';

/** The public projection's keys, exactly. */
export const PUBLIC_KEYS = ['edition', 'items', 'publication_revision', 'sunday'];

/** The reserved fictional numbers this run uses (+44 7700 900641-900649). */
export function isFictionalHymnPhone(phone) {
  return /^\+44770090064[1-9]$/.test(phone);
}

/** The keys of an object, sorted. */
export function sortedKeys(o) {
  return Object.keys(o ?? {}).sort();
}

/** The saved item ids of a favourites read, sorted. */
export function savedItems(read) {
  return (read?.favourites ?? []).map((f) => f.item).sort();
}

/**
 * This Sunday in church time (Africa/Lusaka, UTC+2, no daylight saving) at `nowMs`: today on a
 * Sunday, else the coming Sunday, as YYYY-MM-DD.
 */
export function churchThisSunday(nowMs) {
  const church = new Date(nowMs + 2 * 3_600_000);
  const day = church.getUTCDay();
  return new Date(Date.UTC(church.getUTCFullYear(), church.getUTCMonth(), church.getUTCDate() + ((7 - day) % 7)))
    .toISOString().slice(0, 10);
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
  const fav = (token, cmd, item, edition = EDITION) => content(token, cmd, null, { edition, item });
  const mine = async (token) => {
    const r = await rpc('content_my_hymn_favourites', token);
    return { status: r.status, json: r.json };
  };
  const publicSunday = async (token) => (await rpc('content_public_sunday_hymns', token)).json;
  const staff = async (token) => {
    const r = await rpc('content_staff_sunday_hymns', token);
    return { status: r.status, json: r.json, detail: r.json?.details ?? null };
  };

  const people = {
    admin: { phone: '+447700900641', name: `${NAME_PREFIX} Admin` },
    media: { phone: '+447700900642', name: `${NAME_PREFIX} Media M` },
    leader: { phone: '+447700900643', name: `${NAME_PREFIX} Worship leader` },
    a: { phone: '+447700900644', name: `${NAME_PREFIX} Member A` },
    b: { phone: '+447700900645', name: `${NAME_PREFIX} Member B` },
    pending: { phone: '+447700900646', name: `${NAME_PREFIX} Pending`, noLink: true },
    pastor: { phone: '+447700900647', name: `${NAME_PREFIX} Pastor` },
    erased: { phone: '+447700900648', name: `${NAME_PREFIX} Member E` },
  };
  for (const p of Object.values(people)) if (!isFictionalHymnPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  const users = new Set();
  const digits = Object.values(people).map((p) => `'${p.phone.slice(1)}'`).join(',');
  const startedAt = psql(`select to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')`);
  const cleanup = () => {
    const ids = [...users].filter(Boolean).map((u) => `'${u}'`);
    const byUser = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    return psql(`
    create temp table gone_users as select u.id from auth.users u where ${byUser} u.phone in (${digits});
    create temp table gone_members as
      select m.member_id from app.identity_members m where m.display_name like '${NAME_PREFIX}%';
    delete from app.content_hymn_favourites f where f.member_id in (select member_id from gone_members);
    delete from app.content_sunday_hymn_items i using app.content_sunday_hymn_revisions r
     where i.sunday = r.sunday and i.revision_no = r.revision_no and r.saved_at >= '${startedAt}'::timestamptz;
    delete from app.content_sunday_hymn_revisions r where r.saved_at >= '${startedAt}'::timestamptz;
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
    psql(`select app.platform_set_environment('local', 'content-hymn-lists-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('H00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  try {
    const { admin, media, leader, a, b, pending, pastor, erased } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      if (!p.noLink) p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'content-hymn-lists-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    // Member A's second phone: a second session of the same account.
    a.token2 = (await signIn(a.phone, a.password)).json?.access_token;
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    const revisionOf = (p) => Number(psql(`select revision from app.identity_grant_sets where member_id = '${p.member}'`));
    const roleGrants = [
      await envelope('identity_grant_command', admin.token, 'identity.grant_role', revisionOf(media), { member_id: media.member, role: 'media' }),
      await envelope('identity_grant_command', admin.token, 'identity.grant_role', revisionOf(pastor), { member_id: pastor.member, role: 'pastor' }),
    ];
    check('H01-signed-in-by-phone-and-roles-granted', Object.values(people).every((p) => amrMethods(p.token).includes('password'))
      && Boolean(a.token2) && a.token2 !== a.token && roleGrants.every((g) => g.status === 200),
      { amr: amrMethods(a.token), second_session: Boolean(a.token2) && a.token2 !== a.token, grants: roleGrants.map((g) => g.status) });

    // ------------------------------------------------------------------ favourites on two phones
    const save12 = await fav(a.token, 'content.save_hymn_favourite', 'hymn-12');
    const save24 = await fav(a.token, 'content.save_hymn_favourite', 'chorus-24');
    const phone2 = await mine(a.token2);
    const removed = await fav(a.token2, 'content.remove_hymn_favourite', 'chorus-24');
    const phone1 = await mine(a.token);
    const again = await fav(a.token, 'content.save_hymn_favourite', 'hymn-12');
    check('H10-a-member-saves-and-removes-on-two-phones', save12.status === 200 && save12.data?.saved === true
      && save24.status === 200 && JSON.stringify(savedItems(phone2.json)) === JSON.stringify(['chorus-24', 'hymn-12'])
      && removed.status === 200 && removed.data?.saved === false
      && JSON.stringify(savedItems(phone1.json)) === JSON.stringify(['hymn-12'])
      && again.status === 200 && again.data?.revision === save12.data?.revision,
      { phone2_sees: savedItems(phone2.json).length, removed_on_phone2: removed.data?.saved === false,
        phone1_sees_after_removal: savedItems(phone1.json).length, save_again_is_no_op: again.data?.revision === save12.data?.revision });

    const bRead = await mine(b.token);
    const bRemoves = await fav(b.token, 'content.remove_hymn_favourite', 'hymn-12');
    const adminRead = await mine(admin.token);
    const mediaRead = await mine(media.token);
    const aStill = await mine(a.token);
    check('H11-another-member-cannot-read-or-touch-them', bRead.status === 200 && savedItems(bRead.json).length === 0
      && bRemoves.code === 'not_found' && savedItems(adminRead.json).length === 0 && savedItems(mediaRead.json).length === 0
      && JSON.stringify(savedItems(aStill.json)) === JSON.stringify(['hymn-12']),
      { b_sees: savedItems(bRead.json).length, b_remove: bRemoves.code, admin_sees: savedItems(adminRead.json).length,
        media_sees: savedItems(mediaRead.json).length });

    const refusals = {
      hymn200: (await fav(a.token, 'content.save_hymn_favourite', 'hymn-200')).field_errors?.item,
      chorus68: (await fav(a.token, 'content.save_hymn_favourite', 'chorus-68')).field_errors?.item,
      title: (await fav(a.token, 'content.save_hymn_favourite', 'Amazing grace')).field_errors?.item,
      edition: (await fav(a.token, 'content.save_hymn_favourite', 'hymn-1', 'bicc-tonga-2099')).field_errors?.edition,
    };
    check('H12-numbers-outside-the-edition-are-refused', refusals.hymn200 === 'out_of_range' && refusals.chorus68 === 'out_of_range'
      && refusals.title === 'invalid' && refusals.edition === 'unknown_edition', refusals);

    const anonRead = await mine(undefined);
    const anonSave = await rpc('content_command', undefined,
      { version: 1, command: 'content.save_hymn_favourite', request_id: randomUUID(), expected_revision: null, payload: { edition: EDITION, item: 'hymn-1' } });
    const pendingSave = await fav(pending.token, 'content.save_hymn_favourite', 'hymn-1');
    const pendingRead = await mine(pending.token);
    check('H13-guests-and-pending-cannot-save-or-read', anonRead.status === 401 && anonSave.status === 401
      && pendingSave.code === 'forbidden' && pendingRead.status === 403,
      { anon_read: anonRead.status, anon_save: anonSave.status, pending_save: pendingSave.code, pending_read: pendingRead.status });

    // ------------------------------------------------------------------ the worship leader and Media set this Sunday
    const sunday = churchThisSunday(Date.now());
    const adminStaff = await staff(admin.token);
    const listId = adminStaff.json?.list_id;
    const leaderBefore = await staff(leader.token);
    const granted = await envelope('identity_grant_command', admin.token, 'identity.grant_scope', revisionOf(leader),
      { member_id: leader.member, scope_kind: 'worship_leader', scope_id: listId });
    const leaderStaff = await staff(leader.token);
    check('H20-admin-makes-a-worship-leader', adminStaff.status === 200 && adminStaff.json?.this_sunday === sunday
      && leaderBefore.status === 403 && granted.status === 200 && leaderStaff.status === 200
      && leaderStaff.json?.capacity === 'worship_leader' && leaderStaff.json?.members === null,
      { this_sunday_matches: adminStaff.json?.this_sunday === sunday, before: leaderBefore.status, grant: granted.status,
        capacity: leaderStaff.json?.capacity });

    const byLeader = await content(leader.token, 'content.set_sunday_hymns', leaderStaff.json?.revision,
      { sunday, edition: EDITION, items: ['hymn-12', 'chorus-3', 'hymn-45'] });
    const afterLeader = await publicSunday(undefined);
    const byMedia = await content(media.token, 'content.set_sunday_hymns', byLeader.revision,
      { sunday, edition: EDITION, items: ['hymn-12', 'hymn-45', 'hymn-199'] });
    const afterMedia = await publicSunday(undefined);
    check('H21-worship-leader-and-media-set-this-sundays-list', byLeader.status === 200 && byMedia.status === 200
      && JSON.stringify(afterLeader?.items) === JSON.stringify(['hymn-12', 'chorus-3', 'hymn-45'])
      && JSON.stringify(afterMedia?.items) === JSON.stringify(['hymn-12', 'hymn-45', 'hymn-199'])
      && afterMedia?.sunday === sunday && afterMedia?.edition === EDITION && afterMedia?.publication_revision === 2,
      { leader: byLeader.status, media: byMedia.status, after_leader: afterLeader?.items?.length, after_media: afterMedia?.items?.length,
        publication_revision: afterMedia?.publication_revision });

    const current = byMedia.revision;
    const tries = {
      member: (await content(a.token, 'content.set_sunday_hymns', current, { sunday, edition: EDITION, items: ['hymn-1'] })).code,
      pastor: (await content(pastor.token, 'content.set_sunday_hymns', current, { sunday, edition: EDITION, items: ['hymn-1'] })).code,
      pending: (await content(pending.token, 'content.set_sunday_hymns', current, { sunday, edition: EDITION, items: ['hymn-1'] })).code,
      anon: (await rpc('content_command', undefined, { version: 1, command: 'content.set_sunday_hymns', request_id: randomUUID(),
        expected_revision: current, payload: { sunday, edition: EDITION, items: ['hymn-1'] } })).status,
      stale: (await content(leader.token, 'content.set_sunday_hymns', byLeader.revision, { sunday, edition: EDITION, items: ['hymn-1'] })).code,
      range: (await content(media.token, 'content.set_sunday_hymns', current, { sunday, edition: EDITION, items: ['hymn-200'] })).field_errors?.items,
      memberStaff: (await staff(a.token)).status,
      pastorStaff: (await staff(pastor.token)).status,
    };
    check('H22-plain-member-and-pastor-refused', tries.member === 'forbidden' && tries.pastor === 'forbidden'
      && tries.pending === 'forbidden' && tries.anon === 401 && tries.stale === 'conflict' && tries.range === 'out_of_range'
      && tries.memberStaff === 403 && tries.pastorStaff === 403, tries);

    const texts = [await publicSunday(undefined), await publicSunday(pending.token), await publicSunday(a.token)].map((x) => JSON.stringify(x));
    const leaks = [leader.name, media.name, leader.member, media.member, 'saved_by', 'capacity', 'saved_at', 'worship_leader']
      .filter((v) => texts.some((t) => t.includes(v)));
    check('H23-the-public-read-is-the-projection-only', leaks.length === 0 && texts[0] === texts[1] && texts[1] === texts[2]
      && JSON.stringify(sortedKeys(JSON.parse(texts[0]))) === JSON.stringify(PUBLIC_KEYS),
      { leaked: leaks.length, same_for_anon_pending_member: texts[0] === texts[1] && texts[1] === texts[2], keys: sortedKeys(JSON.parse(texts[0])) });

    const revoked = await envelope('identity_grant_command', admin.token, 'identity.revoke_scope', revisionOf(leader),
      { member_id: leader.member, scope_kind: 'worship_leader', scope_id: listId });
    const afterRevoke = await content(leader.token, 'content.set_sunday_hymns', current, { sunday, edition: EDITION, items: ['hymn-1'] });
    const staffAfterRevoke = await staff(leader.token);
    check('H24-a-revoked-worship-leader-is-refused-at-once', revoked.status === 200 && afterRevoke.code === 'forbidden'
      && staffAfterRevoke.status === 403, { revoke: revoked.status, set: afterRevoke.code, staff_read: staffAfterRevoke.status });

    // ------------------------------------------------------------------ no client role touches a table of this story
    const tables = [];
    for (const t of ['content_hymn_favourites', 'content_sunday_hymn_revisions', 'content_sunday_hymn_items',
      'content_sunday_hymn_lists', 'content_hymn_editions']) {
      for (const [who, token] of [['anon', undefined], ['member', a.token], ['media', media.token]]) {
        for (const profile of ['app', 'api']) {
          const read = await http('GET', `/rest/v1/${t}?select=*`, { token, profile });
          const write = await http('POST', `/rest/v1/${t}`, { token, profile, body: { member_id: a.member } });
          tables.push({ t, who, profile, refused: read.status >= 400 && write.status >= 400 && !Array.isArray(read.json) });
        }
      }
    }
    check('H30-no-client-role-reads-or-writes-a-table', tables.every((x) => x.refused),
      { attempts: tables.length, refused: tables.filter((x) => x.refused).length });

    // ------------------------------------------------------------------ deletion: favourites erased, lists anonymised
    const grantE = await envelope('identity_grant_command', admin.token, 'identity.grant_scope', revisionOf(erased),
      { member_id: erased.member, scope_kind: 'worship_leader', scope_id: listId });
    const eSave = await fav(erased.token, 'content.save_hymn_favourite', 'hymn-3');
    const eSet = await content(erased.token, 'content.set_sunday_hymns', current,
      { sunday, edition: EDITION, items: ['hymn-3', 'hymn-12'] });
    const hook = (phase) => JSON.parse(psql(`select app.content_erase_member(jsonb_build_object(
      'member_id', '${erased.member}', 'account_id', '${erased.user}', 'deletion_id', gen_random_uuid(), 'phase', '${phase}'))`));
    const before = hook('check');
    const erasedNow = hook('erase');
    const after = hook('check');
    const favLeft = Number(psql(`select count(*) from app.content_hymn_favourites where member_id = '${erased.member}'`));
    const savedBy = (await staff(media.token)).json?.sundays?.find((s) => s.sunday === sunday)?.saved_by;
    const stillPublic = await publicSunday(undefined);
    check('H40-deletion-erases-favourites-and-anonymises-lists', grantE.status === 200 && eSave.status === 200 && eSet.status === 200
      && before.remaining > 0 && erasedNow.remaining === 0 && after.remaining === 0 && favLeft === 0
      && savedBy === 'Former member' && JSON.stringify(stillPublic?.items) === JSON.stringify(['hymn-3', 'hymn-12'])
      && JSON.stringify(savedItems((await mine(a.token)).json)) === JSON.stringify(['hymn-12']),
      { before: before.remaining, after: after.remaining, favourites_left: favLeft, saved_by: savedBy,
        list_stays_public: stillPublic?.items?.length === 2 });

    const receipts = psql(`select coalesce(string_agg(r.result::text, ' '), '') from app.cmd_receipts r
                            where r.command like 'content.%hymn%' and r.actor_id in (${[...users].map((u) => `'${u}'`).join(',')})`);
    const receiptLeaks = Object.values(people).flatMap((p) => [p.name, p.phone.slice(1), p.member]).filter((v) => v && receipts.includes(v));
    check('H50-receipts-hold-no-member-or-hymn-text', receipts.length > 0 && receiptLeaks.length === 0,
      { receipts: receipts.length > 0, leaked: receiptLeaks.length });
  } finally {
    const left = cleanup();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'content-hymn-lists-e2e';
            delete from app.platform_environment_history where set_by = 'content-hymn-lists-e2e';`);
    }
    log('H99-cleanup', { users_left: Number(left), unmarked: marked,
      favourites_left: Number(psql(`select count(*) from app.content_hymn_favourites f
                                     where not exists (select 1 from app.identity_members m where m.member_id = f.member_id)`)),
      revisions_left: Number(psql(`select count(*) from app.content_sunday_hymn_revisions where saved_at >= '${startedAt}'::timestamptz`)) });
  }
  finish();
}

runMain(import.meta.url, main);
