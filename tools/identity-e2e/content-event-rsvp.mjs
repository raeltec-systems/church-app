#!/usr/bin/env node
// Story 6.11 end-to-end on the LOCAL stack: event posters, the projection the calendar export
// uses, and RSVP within capacity, through real GoTrue phone sign-in (no SMS), the real Data API
// (PostgREST), the real Storage API and the content-assets Edge Function served by
// `supabase functions serve` (started here when it is not already running). It proves the
// ticket's verify at the API level:
//   * a Media member (the organiser) publishes a capacity-2 SYNTHETIC event with a poster
//     (uploaded through the Edge Function, cited with a church-owned rights record, placed by the
//     sync) and a three-day event; a signed-out caller reads both endpoints of each and fetches the
//     poster, while a poster that is too small is refused with nothing stored;
//   * two members RSVP and a third is refused `full`; members racing at once for the last place
//     of a capacity-1 event get exactly one `going` (twice: again after the winner cancels);
//   * a cancel frees a place; deactivating a member who is going frees theirs (released);
//   * guests and a Pending account cannot RSVP, and the public projection names nobody;
//   * the organiser and an Admin read the names of the members going, while another editor, a
//     member and a guest are refused; only an Admin or an organiser changes the organisers;
//   * a member deletion erases the RSVP (Content's registered deletion hook, as the 2.11 worker's
//     erase step calls it) and the check answers zero;
//   * no client role reads or writes the new Content tables.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards, the edge-runtime image, and a database with no usable Admin (`npx supabase db reset`
// first). LOCAL only (exact origin), SYNTHETIC fictional numbers +44 7700 900584-900598. Evidence
// is redacted JSONL: statuses, codes, counts and booleans; never tokens, passwords, numbers,
// names or paths. Everything it created (rows and Storage objects) is removed.
//
// Usage: node tools/identity-e2e/content-event-rsvp.mjs [--evidence <file.jsonl>]
import { removeLocalEdgeRuntime } from '../auth-harness/local-target.mjs';
import { spawn, execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';

import { amrMethods, localHttp, localKey, password, psql, runMain, sleep, startRun } from './harness.mjs';
import { solidPng } from './content-banners.mjs';
import { churchDate, churchDayAt } from './content-events.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 6.11 E2E';
const TAG = '(6.11 E2E)';
export const CAMP = `SYNTHETIC Youth Camp ${TAG}`;
export const CONFERENCE = `SYNTHETIC Three-day Conference ${TAG}`;
export const LAST_SEAT = `SYNTHETIC Last-seat Dinner ${TAG}`;
const FN = '/functions/v1/content-assets';

/** The public event projection's keys since story 6.11, exactly. */
export const PUBLIC_KEYS = ['description', 'ends_at', 'event_id', 'location', 'offline_allowed', 'poster',
  'publication_revision', 'published_at', 'rsvp', 'starts_at', 'title'];

/** The public RSVP object's keys: counts only. */
export const RSVP_KEYS = ['capacity', 'full', 'going', 'open', 'spaces_left'];

/** The reserved fictional numbers this run uses (+44 7700 900584-900598). */
export function isFictionalRsvpPhone(phone) {
  return /^\+44770090058[4-9]$/.test(phone) || /^\+44770090059[0-8]$/.test(phone);
}

/** Of concurrent RSVP answers, how many said going and how many were refused full. */
export function raceTally(answers) {
  return {
    going: answers.filter((a) => a?.data?.rsvp_state === 'going').length,
    full: answers.filter((a) => a?.code === 'validation_failed' && a?.field_errors?.event_id === 'full').length,
    other: answers.filter((a) => a?.data?.rsvp_state !== 'going'
      && !(a?.code === 'validation_failed' && a?.field_errors?.event_id === 'full')).length,
  };
}

async function main() {
  const { log, check, finish } = startRun();
  const keys = localKey();
  const { origin, key, secret, service } = keys;
  const http = localHttp(keys);
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const content = (token, cmd, expected, payload, requestId = randomUUID()) =>
    rpc('content_command', token, { version: 1, command: cmd, request_id: requestId, expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const rsvp = (token, eventId, cmd = 'content.rsvp_event') => content(token, cmd, null, { event_id: eventId });
  const publicEvent = async (eventId, token) => (await rpc('content_public_event', token, { event_id: eventId })).json?.event;
  const going = (eventId) => Number(psql(`select count(*) from app.content_event_rsvps
    where item_id = '${eventId}' and rsvp_state = 'going'`));
  const fn = async (method, query, { token, body, type } = {}) => {
    const headers = { apikey: key };
    if (token) headers.Authorization = `Bearer ${token}`;
    if (type) headers['Content-Type'] = type;
    const res = await fetch(`${origin}${FN}?${query}`, { method, headers, body });
    const buf = Buffer.from(await res.arrayBuffer());
    let json = null;
    try { json = JSON.parse(buf.toString('utf8')); } catch { /* bytes */ }
    return { status: res.status, json };
  };
  const upload = (token, itemId, bytes) =>
    fn('POST', `action=upload&item_id=${itemId}&purpose=event_poster`, { token, body: bytes, type: 'image/png' });
  const sync = (token) => fn('POST', 'action=sync', { token });
  const storage = async (method, path, { asService, body } = {}) => {
    const headers = { apikey: asService ? secret : key };
    if (asService) headers.Authorization = `Bearer ${service}`;
    if (body) headers['Content-Type'] = 'application/json';
    const res = await fetch(`${origin}/storage/v1/${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
    const buf = Buffer.from(await res.arrayBuffer());
    let json = null;
    try { json = JSON.parse(buf.toString('utf8')); } catch { /* bytes */ }
    return { status: res.status, json, type: res.headers.get('content-type'), bytes: buf.length };
  };

  const people = {
    admin: { phone: '+447700900584', name: `${NAME_PREFIX} Admin` },
    organiser: { phone: '+447700900585', name: `${NAME_PREFIX} Media O` },
    editor: { phone: '+447700900586', name: `${NAME_PREFIX} Media N` },
    a: { phone: '+447700900587', name: `${NAME_PREFIX} Member A` },
    b: { phone: '+447700900588', name: `${NAME_PREFIX} Member B` },
    c: { phone: '+447700900589', name: `${NAME_PREFIX} Member C` },
    r1: { phone: '+447700900590', name: `${NAME_PREFIX} Racer 1` },
    r2: { phone: '+447700900591', name: `${NAME_PREFIX} Racer 2` },
    r3: { phone: '+447700900592', name: `${NAME_PREFIX} Racer 3` },
    r4: { phone: '+447700900593', name: `${NAME_PREFIX} Racer 4` },
    r5: { phone: '+447700900594', name: `${NAME_PREFIX} Racer 5` },
    f: { phone: '+447700900595', name: `${NAME_PREFIX} Member F` },
    pending: { phone: '+447700900596', name: `${NAME_PREFIX} Pending`, noLink: true },
  };
  for (const p of Object.values(people)) if (!isFictionalRsvpPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  const users = new Set();
  const digits = Object.values(people).map((p) => `'${p.phone.slice(1)}'`).join(',');
  const itemsSql = `select r.item_id from app.content_event_revisions r where r.title like 'SYNTHETIC % ${TAG}'
      union select r.item_id from app.content_rights_revisions r where r.label like 'SYNTHETIC % ${TAG}'`;
  const cleanupObjects = async () => {
    const names = (bucket) => psql(`select coalesce(string_agg(o.name, ',' order by o.name), '') from storage.objects o
      where o.bucket_id = '${bucket}' and (o.name in (select a.draft_path from app.content_assets a
        where a.item_id in (${itemsSql}))
        or o.name like any (select 'event/' || i.item_id::text || '/%' from (${itemsSql}) i))`).split(',').filter(Boolean);
    let removed = 0;
    for (const bucket of ['content-drafts', 'content-public']) {
      const list = names(bucket);
      if (list.length) {
        const r = await storage('DELETE', `object/${bucket}`, { asService: true, body: { prefixes: list } });
        removed += Array.isArray(r.json) ? r.json.length : 0;
      }
    }
    return removed;
  };
  const cleanup = () => {
    const ids = [...users].filter(Boolean).map((u) => `'${u}'`);
    const byUser = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    return psql(`
    begin;
    create temp table gone_users as select u.id from auth.users u where ${byUser} u.phone in (${digits});
    create temp table gone_members as
      select m.member_id from app.identity_members m where m.display_name like '${NAME_PREFIX}%';
    create temp table gone_items as ${itemsSql};
    delete from app.content_event_rsvps v
     where v.item_id in (select item_id from gone_items) or v.member_id in (select member_id from gone_members);
    delete from app.content_event_organisers o
     where o.item_id in (select item_id from gone_items) or o.member_id in (select member_id from gone_members);
    alter table app.content_revision_files disable trigger content_revision_files_draft_only;
    delete from app.content_revision_files f where f.item_id in (select item_id from gone_items);
    alter table app.content_revision_files enable trigger content_revision_files_draft_only;
    delete from app.content_assets a where a.item_id in (select item_id from gone_items);
    delete from app.content_audit a where a.item_id in (select item_id from gone_items);
    delete from app.content_rights_revisions r where r.item_id in (select item_id from gone_items);
    delete from app.content_event_revisions r where r.item_id in (select item_id from gone_items);
    delete from app.content_items i where i.item_id in (select item_id from gone_items);
    delete from app.identity_handover_obligations o where o.member_id in (select member_id from gone_members);
    delete from app.identity_membership_lifecycle e
     where e.member_id in (select member_id from gone_members) or e.actor_member_id in (select member_id from gone_members);
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
    commit;
    select count(*) from auth.users u where ${byUser} u.phone in (${digits});`);
  };

  const settings = await http('GET', '/auth/v1/settings');
  if (settings.json?.external?.phone !== true) {
    throw new Error('the local phone provider is off: run `node tools/auth-harness/local-phone-auth.mjs on` first');
  }
  const marker = psql(`select coalesce((select environment from app.platform_environment), '')`);
  let marked = false;
  if (marker === '') {
    psql(`select app.platform_set_environment('local', 'content-event-rsvp-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }

  // The Edge Function: use a running `functions serve`, else start one for this run.
  const probe = () => fetch(`${origin}${FN}?action=sync`, { method: 'POST', headers: { apikey: key } })
    .then((r) => r.status).catch(() => 0);
  let serve = null;
  if (await probe() !== 401) {
    serve = process.platform === 'win32'
      ? spawn('npx supabase functions serve', { stdio: 'ignore', shell: true })
      : spawn('npx', ['supabase', 'functions', 'serve'], { stdio: 'ignore', detached: true });
    const deadline = Date.now() + 120_000;
    while (await probe() !== 401) {
      if (Date.now() > deadline) throw new Error('the Edge Function did not start (is the edge-runtime image present?)');
      await sleep(1500);
    }
  }
  log('C00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    function_served: true, started_here: Boolean(serve), leftover_objects_removed: await cleanupObjects(),
    leftover_users_removed: cleanup(),
  });

  const ids = {};
  try {
    const { admin, organiser, editor, a, b, c, f, pending } = people;
    const racers = [people.r1, people.r2, people.r3, people.r4, people.r5];
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      if (!p.noLink) p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'content-event-rsvp-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    const grantMedia = async (p) => {
      const rev = Number(psql(`select revision from app.identity_grant_sets where member_id = '${p.member}'`));
      return rpc('identity_grant_command', admin.token, { version: 1, command: 'identity.grant_role',
        request_id: randomUUID(), expected_revision: rev, payload: { member_id: p.member, role: 'media' } });
    };
    const g1 = await grantMedia(organiser);
    const g2 = await grantMedia(editor);
    check('C01-signed-in-by-phone-and-two-media-editors', Object.values(people).every((p) => amrMethods(p.token).includes('password'))
      && g1.status === 200 && g2.status === 200, { grants: [g1.status, g2.status] });

    // ------------------------------------------------------------------ a capacity-2 event with a poster
    const now = Date.now();
    const campDraft = await content(organiser.token, 'content.create_event', null, {
      title: CAMP, description: 'SYNTHETIC two days by the lake, with meals.',
      starts_at: churchDayAt(now, 6, '09:00'), ends_at: churchDayAt(now, 7, '16:00'),
      location: 'SYNTHETIC Camp grounds', rsvp_enabled: true, rsvp_capacity: 2 });
    ids.camp = campDraft.data?.event_id;
    const organisers = psql(`select coalesce(string_agg(member_id::text, ','), '') from app.content_event_organisers
      where item_id = '${ids.camp}' and organiser_state = 'active'`);
    const small = await upload(organiser.token, ids.camp, solidPng(500, 500, [200, 120, 40]));
    const smallStored = Number(psql(`select count(*) from app.content_assets where item_id = '${ids.camp}'`));
    const up = await upload(organiser.token, ids.camp, solidPng(1600, 900, [30, 90, 60]));
    ids.poster = up.json?.asset_id;
    const rightsDraft = await content(organiser.token, 'content.create_rights_record', null, {
      label: `SYNTHETIC Camp poster ${TAG}`, source_key: 'church-posters', holder: 'SYNTHETIC Church media team',
      basis: 'church_owned', clears_display: true, clears_offline: false, clears_audio: false,
      evidence: 'SYNTHETIC: designed for this test run; no real rights are claimed.' });
    ids.rights = rightsDraft.data?.rights_id;
    const verified = await content(organiser.token, 'content.verify_rights_record', rightsDraft.revision, { rights_id: ids.rights });
    const saved = await content(organiser.token, 'content.save_event', campDraft.revision, {
      event_id: ids.camp, title: CAMP, description: 'SYNTHETIC two days by the lake, with meals.',
      starts_at: churchDayAt(now, 6, '09:00'), ends_at: churchDayAt(now, 7, '16:00'),
      location: 'SYNTHETIC Camp grounds', rsvp_enabled: true, rsvp_capacity: 2,
      poster_asset_id: ids.poster, poster_rights_id: ids.rights, poster_alt_text: 'SYNTHETIC green tents by a lake' });
    const published = await content(organiser.token, 'content.publish_event', saved.revision, { event_id: ids.camp });
    const beforeSync = await publicEvent(ids.camp);
    const synced = await sync(organiser.token);
    const pub = await publicEvent(ids.camp);
    const posterFile = pub?.poster ? await storage('GET', `object/public/content-public/${pub.poster.path}`) : { status: 0 };
    check('C10-a-capacity-2-event-with-a-poster-is-published', campDraft.status === 200
      && organisers === organiser.member && small.status === 422 && small.json?.field_errors?.width === 'too_small'
      && smallStored === 0 && up.status === 200 && verified.status === 200 && saved.status === 200
      && published.data?.state === 'published' && beforeSync?.poster === null && synced.json?.placed >= 1
      && pub?.poster?.alt_text === 'SYNTHETIC green tents by a lake' && pub?.poster?.width === 1600
      && posterFile.status === 200 && posterFile.type === 'image/png',
      { creator_is_organiser: organisers === organiser.member, small_poster: small.status,
        small_reason: small.json?.field_errors?.width ?? null, small_stored: smallStored, upload: up.status,
        rights: verified.data?.state, save: saved.status, publish: published.data?.state,
        poster_before_sync: beforeSync?.poster ?? null, placed: synced.json?.placed ?? null,
        anon_poster_fetch: posterFile.status, poster_type: posterFile.type });
    check('C11-the-public-projection-carries-counts-and-no-name', JSON.stringify(Object.keys(pub ?? {}).sort()) === JSON.stringify(PUBLIC_KEYS)
      && JSON.stringify(Object.keys(pub?.rsvp ?? {}).sort()) === JSON.stringify(RSVP_KEYS)
      && pub?.rsvp?.capacity === 2 && pub?.rsvp?.going === 0 && pub?.rsvp?.open === true,
      { keys_match: JSON.stringify(Object.keys(pub ?? {}).sort()) === JSON.stringify(PUBLIC_KEYS), rsvp: pub?.rsvp ?? null });

    // ------------------------------------------------------------------ a three-day event keeps both endpoints
    const confDraft = await content(organiser.token, 'content.create_event', null, {
      title: CONFERENCE, description: 'SYNTHETIC three days of teaching.',
      starts_at: churchDayAt(now, 10, '08:30'), ends_at: churchDayAt(now, 12, '17:00'), location: 'SYNTHETIC Main sanctuary' });
    ids.conference = confDraft.data?.event_id;
    const confPub = await content(organiser.token, 'content.publish_event', confDraft.revision, { event_id: ids.conference });
    const conf = await publicEvent(ids.conference);
    check('C12-a-three-day-event-keeps-both-endpoints-for-the-calendar-export', confPub.status === 200
      && churchDate(conf?.starts_at) === churchDate(churchDayAt(now, 10, '08:30'))
      && churchDate(conf?.ends_at) === churchDate(churchDayAt(now, 12, '17:00'))
      && Date.parse(conf.ends_at) - Date.parse(conf.starts_at) > 2 * 86_400_000 && conf?.rsvp === null,
      { publish: confPub.status, church_days: [churchDate(conf?.starts_at), churchDate(conf?.ends_at)], rsvp: conf?.rsvp ?? null });

    // ------------------------------------------------------------------ RSVP within capacity
    const ra = await rsvp(a.token, ids.camp);
    const rb = await rsvp(b.token, ids.camp);
    const rc = await rsvp(c.token, ids.camp);
    const afterTwo = await publicEvent(ids.camp);
    check('C20-two-members-go-and-a-third-is-refused-full', ra.data?.rsvp_state === 'going' && rb.data?.rsvp_state === 'going'
      && rb.data?.full === true && rc.code === 'validation_failed' && rc.field_errors?.event_id === 'full'
      && afterTwo?.rsvp?.going === 2 && afterTwo?.rsvp?.spaces_left === 0 && afterTwo?.rsvp?.full === true,
      { a: ra.data?.rsvp_state, b: rb.data?.rsvp_state, c: rc.field_errors?.event_id ?? rc.code, public_rsvp: afterTwo?.rsvp });

    // ------------------------------------------------------------------ the race for the last place
    const dinnerDraft = await content(organiser.token, 'content.create_event', null, {
      title: LAST_SEAT, description: 'SYNTHETIC dinner with one seat left.',
      starts_at: churchDayAt(now, 8, '18:00'), ends_at: churchDayAt(now, 8, '21:00'),
      location: 'SYNTHETIC Church hall', rsvp_enabled: true, rsvp_capacity: 1 });
    ids.dinner = dinnerDraft.data?.event_id;
    await content(organiser.token, 'content.publish_event', dinnerDraft.revision, { event_id: ids.dinner });
    const round1 = await Promise.all(racers.map((p) => rsvp(p.token, ids.dinner)));
    const tally1 = raceTally(round1);
    const winner = racers[round1.findIndex((x) => x?.data?.rsvp_state === 'going')];
    const going1 = going(ids.dinner);
    const freed = winner ? await rsvp(winner.token, ids.dinner, 'content.cancel_rsvp') : {};
    const round2 = await Promise.all(racers.filter((p) => p !== winner).map((p) => rsvp(p.token, ids.dinner)));
    const tally2 = raceTally(round2);
    const going2 = going(ids.dinner);
    check('C21-racing-members-get-exactly-one-place', tally1.going === 1 && tally1.full === 4 && tally1.other === 0
      && going1 === 1 && freed.data?.rsvp_state === 'cancelled' && tally2.going === 1 && tally2.full === 3
      && tally2.other === 0 && going2 === 1,
      { round1: tally1, going_after_round1: going1, winner_cancelled: freed.data?.rsvp_state ?? null,
        round2: tally2, going_after_round2: going2 });

    // ------------------------------------------------------------------ cancel and deactivation free places
    const cancelA = await rsvp(a.token, ids.camp, 'content.cancel_rsvp');
    const afterCancel = await publicEvent(ids.camp);
    const rc2 = await rsvp(c.token, ids.camp);
    const bRev = Number(psql(`select revision from app.identity_members where member_id = '${b.member}'`));
    const deactivated = await rpc('identity_lifecycle_command', admin.token, { version: 1, command: 'identity.deactivate_membership',
      request_id: randomUUID(), expected_revision: bRev, payload: { member_id: b.member, reason_code: 'moved_away' } });
    const bState = psql(`select rsvp_state from app.content_event_rsvps where item_id = '${ids.camp}' and member_id = '${b.member}'`);
    const afterRelease = await publicEvent(ids.camp);
    check('C22-a-cancel-frees-a-place-and-the-row-stays', cancelA.data?.rsvp_state === 'cancelled'
      && afterCancel?.rsvp?.going === 1 && afterCancel?.rsvp?.spaces_left === 1 && rc2.data?.rsvp_state === 'going'
      && Number(psql(`select count(*) from app.content_event_rsvps where item_id = '${ids.camp}' and member_id = '${a.member}'`)) === 1,
      { cancel: cancelA.data?.rsvp_state, going_after_cancel: afterCancel?.rsvp?.going, c_takes_it: rc2.data?.rsvp_state });
    check('C23-deactivating-a-member-who-is-going-frees-the-place', deactivated.status === 200 && !deactivated.json?.code
      && bState === 'released' && afterRelease?.rsvp?.going === 1 && afterRelease?.rsvp?.spaces_left === 1,
      { deactivate: deactivated.status, b_rsvp: bState, going_after: afterRelease?.rsvp?.going });

    // ------------------------------------------------------------------ guests and Pending
    const anonCmd = await rpc('content_command', undefined, { version: 1, command: 'content.rsvp_event',
      request_id: randomUUID(), expected_revision: null, payload: { event_id: ids.camp } });
    const pendingCmd = await rsvp(pending.token, ids.camp);
    const anonMine = await rpc('content_my_event_rsvp', undefined, { event_id: ids.camp });
    const pendingMine = await rpc('content_my_event_rsvp', pending.token, { event_id: ids.camp });
    const cMine = await rpc('content_my_event_rsvp', c.token, { event_id: ids.camp });
    check('C24-guests-and-pending-cannot-rsvp', anonCmd.status === 401 && pendingCmd.code === 'forbidden'
      && anonMine.status === 401 && pendingMine.status === 403 && cMine.json?.rsvp_state === 'going',
      { anon_command: anonCmd.status, pending_command: pendingCmd.code, anon_mine: anonMine.status,
        pending_mine: pendingMine.status, member_mine: cMine.json?.rsvp_state });

    // ------------------------------------------------------------------ names: organisers and Admins only
    const names = (token) => rpc('content_staff_event_rsvps', token, { event_id: ids.camp });
    const byOrganiser = await names(organiser.token);
    const byAdmin = await names(admin.token);
    const byEditor = await names(editor.token);
    const byMember = await names(a.token);
    const byAnon = await names(undefined);
    const listed = (r) => (r.json?.rsvps?.attendees ?? []).map((x) => x.name).sort();
    const publicText = JSON.stringify([await publicEvent(ids.camp), (await rpc('content_public_events', undefined)).json]);
    const editorList = JSON.stringify((await rpc('content_staff_events', editor.token)).json);
    const editorCamp = ((await rpc('content_staff_events', editor.token)).json?.events ?? []).find((e) => e.event_id === ids.camp);
    check('C25-only-organisers-and-admins-read-who-is-going', byOrganiser.status === 200
      && JSON.stringify(listed(byOrganiser)) === JSON.stringify([c.name])
      && byAdmin.status === 200 && JSON.stringify(listed(byAdmin)) === JSON.stringify([c.name])
      && byEditor.status === 403 && byMember.status === 403 && byAnon.status === 401
      && !publicText.includes(NAME_PREFIX) && !publicText.includes(c.member)
      && !editorList.includes(c.name) && editorCamp?.sees_names === false && editorCamp?.rsvp_going === 1,
      { organiser: byOrganiser.status, organiser_names: listed(byOrganiser).length, admin: byAdmin.status,
        other_editor: byEditor.status, member: byMember.status, guest: byAnon.status,
        public_names: publicText.includes(NAME_PREFIX), editor_list_names: editorList.includes(c.name),
        editor_sees_names: editorCamp?.sees_names ?? null, editor_count: editorCamp?.rsvp_going ?? null });

    // ------------------------------------------------------------------ organisers
    const rev = () => Number(psql(`select revision from app.content_items where item_id = '${ids.camp}'`));
    const selfAdd = await content(editor.token, 'content.set_event_organisers', rev(), { event_id: ids.camp, organiser_ids: [editor.member] });
    const memberAdd = await content(organiser.token, 'content.set_event_organisers', rev(), { event_id: ids.camp, organiser_ids: [organiser.member, a.member] });
    const added = await content(organiser.token, 'content.set_event_organisers', rev(), { event_id: ids.camp, organiser_ids: [organiser.member, editor.member] });
    const editorNow = await names(editor.token);
    const adminSets = await content(admin.token, 'content.set_event_organisers', rev(), { event_id: ids.camp, organiser_ids: [organiser.member] });
    const editorAfter = await names(editor.token);
    check('C26-only-an-admin-or-an-organiser-changes-the-organisers', selfAdd.code === 'forbidden'
      && memberAdd.field_errors?.organiser_ids === 'not_editor' && added.status === 200 && editorNow.status === 200
      && adminSets.status === 200 && editorAfter.status === 403,
      { editor_self_add: selfAdd.code, member_named: memberAdd.field_errors?.organiser_ids ?? null, organiser_adds: added.status,
        added_editor_reads: editorNow.status, admin_sets: adminSets.status, removed_editor_reads: editorAfter.status });

    // ------------------------------------------------------------------ deletion erases the RSVP
    const rf = await rsvp(f.token, ids.camp);
    const erase = (phase) => JSON.parse(psql(`select app.content_erase_member(jsonb_build_object('phase', '${phase}',
      'member_id', '${f.member}', 'account_id', '${f.user}'))::text`));
    const beforeErase = erase('check');
    const erased = erase('erase');
    const fRows = Number(psql(`select count(*) from app.content_event_rsvps where member_id = '${f.member}'`));
    check('C30-a-member-deletion-erases-the-rsvp-and-the-check-answers-zero', rf.data?.rsvp_state === 'going'
      && beforeErase.remaining >= 1 && erased.remaining === 0 && fRows === 0,
      { f_going: rf.data?.rsvp_state, remaining_before: beforeErase.remaining, remaining_after: erased.remaining, rows_left: fRows });

    // ------------------------------------------------------------------ no client role touches a new Content table
    const tables = [];
    for (const t of ['content_event_rsvps', 'content_event_organisers', 'content_member_commands']) {
      for (const [who, token] of [['anon', undefined], ['member', a.token], ['media', organiser.token]]) {
        for (const profile of ['app', 'api']) {
          const read = await http('GET', `/rest/v1/${t}?select=*`, { token, profile });
          const write = await http('POST', `/rest/v1/${t}`, { token, profile, body: { item_id: ids.camp } });
          tables.push({ refused: read.status >= 400 && write.status >= 400 && !Array.isArray(read.json) });
        }
      }
    }
    check('C40-no-client-role-reads-or-writes-the-new-tables', tables.every((x) => x.refused),
      { attempts: tables.length, refused: tables.filter((x) => x.refused).length });
  } finally {
    const objectsRemoved = await cleanupObjects();
    const left = cleanup();
    if (serve) {
      if (process.platform === 'win32') {
        try { execFileSync('taskkill', ['/pid', String(serve.pid), '/T', '/F'], { stdio: 'ignore' }); } catch { /* gone */ }
      } else {
        try { process.kill(-serve.pid, 'SIGINT'); } catch { /* gone */ }
      }
      await sleep(2000);
      try { removeLocalEdgeRuntime(); } catch { /* not running */ }
    }
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'content-event-rsvp-e2e';
            delete from app.platform_environment_history where set_by = 'content-event-rsvp-e2e';`);
    }
    log('C99-cleanup', { users_left: Number(left), objects_removed: objectsRemoved, unmarked: marked, stopped_serve: Boolean(serve),
      items_left: Number(psql(`select count(*) from app.content_event_revisions where title like 'SYNTHETIC % ${TAG}'`)) });
  }
  finish();
}

runMain(import.meta.url, main);
