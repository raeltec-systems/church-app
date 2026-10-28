#!/usr/bin/env node
// Story 6.1 end-to-end on the LOCAL stack: the Content publication lifecycle and the first
// anonymous read, through real GoTrue phone sign-in (no SMS) and the real Data API (PostgREST),
// proving the ticket's verify at the API level:
//   * a Media member drafts a two-day SYNTHETIC Harvest Thanksgiving event; nobody outside the
//     editors sees the draft;
//   * publishing it makes it readable WITHOUT signing in (publishable key only) with both
//     endpoints, in exactly the public projection;
//   * an edited draft leaves the published revision live until it is published again;
//   * withdrawal removes it from both public reads;
//   * anonymous and Pending callers read no draft, editor identity or private field; a plain member
//     is refused every editor command and the editors' read; anon cannot call either;
//   * no client role reads or writes a Content table directly;
//   * once Content's deletion hook has erased an editor (as the 2.11 worker's erase step calls it),
//     the editors' read shows that editor as a former member and the check answers 0.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards, and a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900100-900109. Evidence is redacted JSONL:
// statuses, codes, counts and booleans; never tokens, passwords or numbers. Everything it created is
// removed.
//
// Usage: node tools/identity-e2e/content-events.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';
import { churchClock } from './duties-shared.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 6.1 E2E';
export const HARVEST = 'SYNTHETIC Harvest Thanksgiving (6.1 E2E)';
const EDITED = 'SYNTHETIC Harvest Thanksgiving and meal (6.1 E2E)';
const OTHER = 'SYNTHETIC Youth evening (6.1 E2E)';

/** The public projection's keys, exactly. */
export const PUBLIC_KEYS = ['description', 'ends_at', 'event_id', 'location', 'offline_allowed',
  'publication_revision', 'published_at', 'starts_at', 'title'];

/** The reserved fictional numbers this run uses (+44 7700 900100-900109). */
export function isFictionalContentPhone(phone) {
  return /^\+44770090010[0-9]$/.test(phone);
}

/** The UTC instant of church (Africa/Lusaka, UTC+2) date `days` ahead of `nowMs` at `hhmm`. */
export function churchDayAt(nowMs, days, hhmm) {
  const church = new Date(nowMs + 2 * 3_600_000);
  const [h, m] = hhmm.split(':').map(Number);
  const utc = Date.UTC(church.getUTCFullYear(), church.getUTCMonth(), church.getUTCDate() + days, h - 2, m);
  return new Date(utc).toISOString();
}

/** The church date (YYYY-MM-DD) of a UTC instant. */
export function churchDate(iso) {
  return new Date(Date.parse(iso) + 2 * 3_600_000).toISOString().slice(0, 10);
}

/** The keys of an object, sorted. */
export function sortedKeys(o) {
  return Object.keys(o ?? {}).sort();
}

/** The public event with this id in a list read, or undefined. */
export function findEvent(list, id) {
  return (list?.events ?? []).find((e) => e.event_id === id);
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
  const publicList = async (token) => (await rpc('content_public_events', token)).json;
  const publicOne = async (token, id) => (await rpc('content_public_event', token, { event_id: id })).json;
  const staff = async (token) => {
    const r = await rpc('content_staff_events', token);
    return { status: r.status, json: r.json, detail: r.json?.details ?? null };
  };

  const people = {
    admin: { phone: '+447700900100', name: `${NAME_PREFIX} Admin` },
    media: { phone: '+447700900101', name: `${NAME_PREFIX} Media M` },
    member: { phone: '+447700900102', name: `${NAME_PREFIX} Member` },
    pending: { phone: '+447700900103', name: `${NAME_PREFIX} Pending`, noLink: true },
    former: { phone: '+447700900104', name: `${NAME_PREFIX} Media B` },
  };
  for (const p of Object.values(people)) if (!isFictionalContentPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
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
      select distinct r.item_id from app.content_event_revisions r where r.title like 'SYNTHETIC % (6.1 E2E)';
    delete from app.content_audit a where a.item_id in (select item_id from gone_items);
    delete from app.content_event_revisions r where r.item_id in (select item_id from gone_items);
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
    psql(`select app.platform_set_environment('local', 'content-events-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('C00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  try {
    const { admin, media, member, pending, former } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      if (!p.noLink) p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'content-events-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    const revisionOf = (p) => Number(psql(`select revision from app.identity_grant_sets where member_id = '${p.member}'`));
    const grants = [];
    for (const p of [media, former]) {
      grants.push(await envelope('identity_grant_command', admin.token, 'identity.grant_role', revisionOf(p),
        { member_id: p.member, role: 'media' }));
    }
    check('C01-signed-in-by-phone-and-media-granted', Object.values(people).every((p) => amrMethods(p.token).includes('password'))
      && grants.every((g) => g.status === 200 && g.data?.roles?.includes('media')),
      { amr: amrMethods(media.token), grants: grants.map((g) => g.status) });

    // ------------------------------------------------------------------ draft (Media), private
    const now = Date.now();
    const harvest = {
      title: HARVEST,
      description: 'SYNTHETIC Thanksgiving service on Saturday, then a shared meal on Sunday after worship.',
      starts_at: churchDayAt(now, 5, '09:00'),
      ends_at: churchDayAt(now, 6, '12:00'),
      location: 'SYNTHETIC Church grounds, Kafue',
    };
    const byMember = await content(member.token, 'content.create_event', null, harvest);
    const byPending = await content(pending.token, 'content.create_event', null, harvest);
    const byAnon = await rpc('content_command', undefined,
      { version: 1, command: 'content.create_event', request_id: randomUUID(), expected_revision: null, payload: harvest });
    const draft = await content(media.token, 'content.create_event', null, harvest);
    const id = draft.data?.event_id;
    const anon0 = await publicList(undefined);
    const anonOne0 = await publicOne(undefined, id);
    const pending0 = await publicList(pending.token);
    check('C10-media-drafts-privately', draft.status === 200 && draft.data?.state === 'draft'
      && byMember.code === 'forbidden' && byPending.code === 'forbidden' && byAnon.status === 401
      && !findEvent(anon0, id) && anonOne0?.event === null && !findEvent(pending0, id),
      { draft: draft.data?.state, plain_member: byMember.code, pending: byPending.code, anon_status: byAnon.status,
        anon_sees_draft: Boolean(findEvent(anon0, id)), pending_sees_draft: Boolean(findEvent(pending0, id)) });

    // ------------------------------------------------------------------ publish; read signed out
    const published = await content(media.token, 'content.publish_event', draft.revision, { event_id: id });
    const anon1 = await publicList(undefined);
    const e1 = findEvent(anon1, id);
    const one1 = (await publicOne(undefined, id))?.event;
    check('C11-signed-out-reads-both-endpoints', published.status === 200 && published.data?.state === 'published'
      && e1?.title === HARVEST && e1?.starts_at?.endsWith('Z') && e1?.ends_at?.endsWith('Z')
      && churchDate(e1.starts_at) !== churchDate(e1.ends_at)
      && churchClock(e1.starts_at) === '09:00' && churchClock(e1.ends_at) === '12:00'
      && JSON.stringify(sortedKeys(e1)) === JSON.stringify(PUBLIC_KEYS) && JSON.stringify(one1) === JSON.stringify(e1),
      { published: published.data?.state, starts: churchDate(e1?.starts_at ?? '1970-01-01T00:00:00Z'),
        ends: churchDate(e1?.ends_at ?? '1970-01-01T00:00:00Z'), start_clock: churchClock(e1?.starts_at ?? '1970-01-01T00:00:00Z'),
        end_clock: churchClock(e1?.ends_at ?? '1970-01-01T00:00:00Z'), keys: sortedKeys(e1) });

    // ------------------------------------------------------------------ edit: live stays until republished
    const saved = await content(media.token, 'content.save_event', published.revision, { event_id: id, ...harvest, title: EDITED });
    const whileEditing = findEvent(await publicList(undefined), id);
    const editors = await staff(media.token);
    const mine = (editors.json?.events ?? []).find((e) => e.event_id === id);
    const republished = await content(media.token, 'content.publish_event', saved.revision, { event_id: id });
    const afterRepublish = findEvent(await publicList(undefined), id);
    check('C12-edited-draft-leaves-the-published-version-live', saved.status === 200 && saved.data?.draft_revision_no === 2
      && whileEditing?.title === HARVEST && whileEditing?.publication_revision === 1
      && mine?.live?.title === HARVEST && mine?.draft?.title === EDITED
      && republished.status === 200 && afterRepublish?.title === EDITED && afterRepublish?.publication_revision === 2,
      { while_editing: whileEditing?.publication_revision, editors_see_draft: mine?.draft?.title === EDITED,
        after_republish: afterRepublish?.publication_revision });

    // ------------------------------------------------------------------ no draft, identity or private field
    const pendingRead = await publicList(pending.token);
    const memberRead = await publicList(member.token);
    const anonRead = await publicList(undefined);
    const texts = [anonRead, pendingRead, memberRead].map((x) => JSON.stringify(x));
    const leaks = [media.member, media.user, media.name, 'saved_by', 'published_by', 'created_by', 'draft']
      .filter((v) => texts.some((t) => t.includes(v)));
    check('C13-anon-and-pending-read-the-projection-only', leaks.length === 0
      && texts[0] === texts[1] && texts[1] === texts[2] && findEvent(anonRead, id)?.title === EDITED,
      { leaked: leaks.length, same_for_anon_pending_member: texts[0] === texts[1] && texts[1] === texts[2] });

    // ------------------------------------------------------------------ a plain member is refused every editor command
    const current = republished.revision;
    const refusals = [];
    for (const [cmd, payload] of [['content.create_event', harvest], ['content.save_event', { event_id: id, ...harvest }],
      ['content.publish_event', { event_id: id }], ['content.withdraw_event', { event_id: id }], ['content.archive_event', { event_id: id }]]) {
      refusals.push((await content(member.token, cmd, cmd === 'content.create_event' ? null : current, payload)).code);
    }
    const memberStaff = await staff(member.token);
    const pendingStaff = await staff(pending.token);
    const anonStaff = await staff(undefined);
    check('C14-plain-member-refused-every-editor-command', refusals.every((c) => c === 'forbidden')
      && memberStaff.status === 403 && memberStaff.detail === 'not_granted' && pendingStaff.status === 403
      && anonStaff.status === 401,
      { refusals, member_staff_read: `${memberStaff.status}:${memberStaff.detail}`, pending_staff_read: pendingStaff.status,
        anon_staff_read: anonStaff.status });

    // ------------------------------------------------------------------ no client role touches a Content table
    const tables = [];
    for (const t of ['content_items', 'content_event_revisions', 'content_audit', 'content_kinds']) {
      for (const [who, token] of [['anon', undefined], ['member', member.token], ['media', media.token]]) {
        for (const profile of ['app', 'api']) {
          const read = await http('GET', `/rest/v1/${t}?select=*`, { token, profile });
          const write = await http('POST', `/rest/v1/${t}`, { token, profile, body: { kind: 'event' } });
          tables.push({ t, who, profile, refused: read.status >= 400 && write.status >= 400 && !Array.isArray(read.json) });
        }
      }
    }
    check('C15-no-client-role-reads-or-writes-a-content-table', tables.every((x) => x.refused),
      { attempts: tables.length, refused: tables.filter((x) => x.refused).length });

    // ------------------------------------------------------------------ withdraw
    const withdrawn = await content(media.token, 'content.withdraw_event', current, { event_id: id });
    const afterWithdraw = await publicList(undefined);
    const oneAfter = await publicOne(undefined, id);
    check('C16-withdrawal-removes-it-on-refresh', withdrawn.status === 200 && withdrawn.data?.state === 'withdrawn'
      && !findEvent(afterWithdraw, id) && oneAfter?.event === null,
      { state: withdrawn.data?.state, listed: Boolean(findEvent(afterWithdraw, id)), detail: oneAfter?.event ?? null });

    // ------------------------------------------------------------------ an erased editor reads as a former member
    const other = await content(former.token, 'content.create_event', null,
      { ...harvest, title: OTHER, starts_at: churchDayAt(now, 8, '18:00'), ends_at: churchDayAt(now, 8, '20:00') });
    const otherId = other.data?.event_id;
    await content(former.token, 'content.publish_event', other.revision, { event_id: otherId });
    const hook = (phase) => JSON.parse(psql(`select app.content_erase_member(jsonb_build_object(
      'member_id', '${former.member}', 'account_id', '${former.user}', 'deletion_id', gen_random_uuid(), 'phase', '${phase}'))`));
    const before = hook('check');
    const erased = hook('erase');
    const after = hook('check');
    const adminView = (await staff(admin.token)).json?.events?.find((e) => e.event_id === otherId);
    check('C20-erased-editor-reads-as-a-former-member', before.remaining > 0 && erased.remaining === 0 && after.remaining === 0
      && adminView?.created_by === 'Former member' && adminView?.published_by === 'Former member'
      && adminView?.live?.saved_by === 'Former member' && Boolean(findEvent(await publicList(undefined), otherId)),
      { before: before.remaining, after: after.remaining, created_by: adminView?.created_by, published_by: adminView?.published_by });

    const auditText = psql(`select coalesce(string_agg(a::text, ' '), '') from app.content_audit a
                             where a.item_id in ('${id}', '${otherId}')`);
    const leaked = [HARVEST, EDITED, OTHER, ...Object.values(people).map((p) => p.phone.slice(1)), ...Object.values(people).map((p) => p.name)]
      .filter((v) => auditText.includes(v));
    check('C30-audit-content-free', leaked.length === 0 && auditText.length > 0, { leaked_values: leaked.length,
      actions: psql(`select string_agg(action, ',' order by event_id) from app.content_audit where item_id = '${id}'`) });
  } finally {
    const left = cleanup();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'content-events-e2e';
            delete from app.platform_environment_history where set_by = 'content-events-e2e';`);
    }
    log('C99-cleanup', { users_left: Number(left), unmarked: marked,
      items_left: Number(psql(`select count(*) from app.content_event_revisions where title like 'SYNTHETIC % (6.1 E2E)'`)) });
  }
  finish();
}

runMain(import.meta.url, main);
