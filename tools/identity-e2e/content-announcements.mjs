#!/usr/bin/env node
// Story 6.13 end-to-end on the LOCAL stack: pinned announcements with an optional generic notice,
// through real GoTrue phone sign-in (no SMS), the real Data API (PostgREST), the real Identity and
// Notifications commands and the real system route with a local `notifications_worker`
// credential, proving the ticket's verify at the API level:
//   * a Media member publishes a pinned and an unpinned SYNTHETIC announcement, the unpinned one
//     with a notice; the anonymous read returns both, the pinned one first, in exactly the public
//     projection (no draft, editor identity or notice record);
//   * the notice enqueues one job per member the app can reach now; one worker step gives each of
//     them one inbox item (generic text) with one delivered attempt row, and a push job only to the
//     member with a device and the category on; the member who turned the category off gets the
//     inbox item only; held, deactivated and accountless members, a Pending account and guests get
//     no job, item, push job or direct-contact need;
//   * the push message the worker would send (notifications.push_prepare) is the contract's
//     generic text and the inbox item id; no job, attempt, inbox row, receipt or payload carries
//     the announcement's title or body;
//   * withdrawal takes it out of the public read and its inbox item opens out of date; publishing
//     it again cannot notify twice; a plain member is refused every editor command; an erased
//     editor reads as a former member.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards, and a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900681-900689. Evidence is redacted JSONL:
// statuses, codes, counts and booleans; never tokens, passwords, device tokens, numbers or the
// credential. Everything it created is removed; the credential is revoked, its principal disabled
// and the outbound_sending gate and push switch are put back as found.
//
// Usage: node tools/identity-e2e/content-announcements.mjs [--evidence <file.jsonl>]
import { createHash, randomBytes, randomUUID } from 'node:crypto';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 6.13 E2E';
export const PINNED = 'SYNTHETIC Harvest week (6.13 E2E)';
export const UNPINNED = 'SYNTHETIC Choir practice moved (6.13 E2E)';
const OTHER = 'SYNTHETIC Youth evening (6.13 E2E)';
export const BODY_MARK = 'SYNTHETIC-BODY-6.13';
export const NOTICE_TITLE = 'Church announcement';
export const NOTICE_BODY = 'The church has posted an announcement. Open the app to read it.';

/** The public projection's keys, exactly. */
export const PUBLIC_KEYS = ['announcement_id', 'body', 'pinned', 'publication_revision', 'published_at', 'title'];

/** The reserved fictional numbers this run uses (+44 7700 900681-900689). */
export function isFictionalAnnouncementPhone(phone) {
  return /^\+44770090068[1-9]$/.test(phone);
}

/** A synthetic FCM-shaped device token (never a real one). */
export function syntheticDeviceToken() {
  return `synthetic-${randomBytes(24).toString('base64url')}:APA91b`;
}

/** The titles of a public list read, in order. */
export function titlesOf(list) {
  return (list?.announcements ?? []).map((a) => a.title);
}

/** The keys of an object, sorted. */
export function sortedKeys(o) {
  return Object.keys(o ?? {}).sort();
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
  const envelope = (fn, token, cmd, expected, payload, requestId = randomUUID()) =>
    rpc(fn, token, { version: 1, command: cmd, request_id: requestId, expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const content = (token, cmd, expected, payload) => envelope('content_command', token, cmd, expected, payload);
  const publicList = async (token) => (await rpc('content_public_announcements', token)).json;
  const publicOne = async (token, id) => (await rpc('content_public_announcement', token, { announcement_id: id })).json;
  const staff = async (token) => {
    const r = await rpc('content_staff_announcements', token);
    return { status: r.status, json: r.json, detail: r.json?.details ?? null };
  };

  const people = {
    admin: { phone: '+447700900681', name: `${NAME_PREFIX} Admin` },
    media: { phone: '+447700900682', name: `${NAME_PREFIX} Media M` },
    a: { phone: '+447700900683', name: `${NAME_PREFIX} Member A`, device: true },
    b: { phone: '+447700900684', name: `${NAME_PREFIX} Member B`, device: true },
    c: { phone: '+447700900685', name: `${NAME_PREFIX} Member C` },
    held: { phone: '+447700900686', name: `${NAME_PREFIX} Held`, device: true },
    pending: { phone: '+447700900687', name: `${NAME_PREFIX} Pending`, noLink: true },
    former: { phone: '+447700900688', name: `${NAME_PREFIX} Media F` },
    leaving: { phone: '+447700900689', name: `${NAME_PREFIX} Deactivated`, device: true },
  };
  for (const p of Object.values(people)) if (!isFictionalAnnouncementPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  const users = new Set();
  const digits = Object.values(people).map((p) => `'${p.phone.slice(1)}'`).join(',');
  const phones = Object.values(people).map((p) => `'${p.phone}'`).join(',');
  const cleanup = () => {
    const ids = [...users].filter(Boolean).map((u) => `'${u}'`);
    const byUser = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    return psql(`
    create temp table gone_users as select u.id from auth.users u where ${byUser} u.phone in (${digits});
    create temp table gone_members as
      select m.member_id from app.identity_members m where m.display_name like '${NAME_PREFIX}%';
    create temp table gone_items as
      select distinct r.item_id from app.content_announcement_revisions r where r.title like 'SYNTHETIC % (6.13 E2E)';
    delete from app.notifications_attempts a using app.notifications_jobs j
     where a.job_id = j.job_id and (j.recipient_member_id in (select member_id from gone_members)
                                    or j.source_id in (select item_id from gone_items));
    delete from app.notifications_push_jobs p
     where p.recipient_member_id in (select member_id from gone_members) or p.account_id in (select id from gone_users);
    delete from app.notifications_direct_contact_needs n
     where n.recipient_member_id in (select member_id from gone_members) or n.source_id in (select item_id from gone_items);
    update app.notifications_jobs j set snoozed_from_item_id = null where j.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_inbox_items i where i.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_jobs j
     where j.recipient_member_id in (select member_id from gone_members) or j.source_id in (select item_id from gone_items);
    delete from app.notifications_schedules s where s.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_device_tokens t
     where t.member_id in (select member_id from gone_members) or t.account_id in (select id from gone_users);
    delete from app.notifications_push_settings s
     where s.member_id in (select member_id from gone_members) or s.account_id in (select id from gone_users);
    delete from app.content_audit a where a.item_id in (select item_id from gone_items);
    delete from app.content_announcement_revisions r where r.item_id in (select item_id from gone_items);
    delete from app.content_items i where i.item_id in (select item_id from gone_items);
    delete from app.identity_handover_obligations o where o.member_id in (select member_id from gone_members);
    delete from app.identity_membership_lifecycle e
     where e.member_id in (select member_id from gone_members) or e.actor_member_id in (select member_id from gone_members);
    delete from app.identity_membership_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
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
    psql(`select app.platform_set_environment('local', 'content-announcements-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  const leftovers = cleanup();
  if (Number(psql(`select app.identity_usable_admin_count()`)) !== 0) {
    throw new Error('the local database already has a usable Admin; run `npx supabase db reset` first');
  }
  // Push needs the owner-controlled outbound_sending gate open and the push switch on. Local only:
  // remember both exactly as found and put them back in cleanup (also on an early exit).
  const gateBefore = psql(`select coalesce((select to_jsonb(g) - 'gate' from app.policy_gates g
                                              where gate = 'outbound_sending')::text, '')`);
  if (gateBefore === '') throw new Error('the outbound_sending gate is missing');
  const pushBefore = psql(`select push_enabled from app.notifications_worker_settings`) === 't';
  const restore = () => psql(`
    update app.policy_gates g set (state, approved_value, approved_by, approved_at, approval_note) =
      (select r.state, r.approved_value, r.approved_by, r.approved_at, r.approval_note
         from jsonb_populate_record(null::app.policy_gates, '${gateBefore.replace(/'/g, "''")}'::jsonb) r)
     where g.gate = 'outbound_sending';
    select app.notifications_configure_worker('{"push_enabled": ${pushBefore}}', '${OPERATOR}');
    select app.policy_is_open('outbound_sending');`);
  let restored = null;
  // The last line of the restore is whether the gate is open now ('t' or 'f').
  const restoreOnce = () => {
    if (restored === null) restored = restore().split('\n').pop().trim();
    return restored;
  };
  process.once('exit', () => { try { restoreOnce(); } catch { /* reported by the run */ } });
  log('A00-precondition', { settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: Number(leftovers) });

  const run = randomUUID().slice(0, 8);
  const credential = `sysc_local_${randomBytes(32).toString('base64url')}`;
  const principal = psql(`select app.sys_create_principal('content-announcements-e2e-${run}', 'notifications_worker', '${OPERATOR}')`);
  const credentialId = JSON.parse(psql(`select app.sys_register_credential('${principal}',
    '${createHash('sha256').update(credential).digest('hex')}', 'announcements e2e ${run}', interval '2 hours', '${OPERATOR}')`)).credential_id;
  const sysRaw = [];
  const sys = async (command, payload = {}) => {
    const res = await fetch(`${origin}/rest/v1/rpc/system_command`, {
      method: 'POST',
      headers: { apikey: key, 'content-type': 'application/json', 'content-profile': 'api', 'x-system-credential': credential },
      body: JSON.stringify({ version: 1, command, request_id: randomUUID(), payload }),
    });
    const text = await res.text();
    sysRaw.push(text);
    let json = null;
    try { json = JSON.parse(text); } catch { /* non-JSON */ }
    return { status: res.status, ...(json ?? {}) };
  };
  const deviceTokens = [];

  try {
    const { admin, media, a, b, c, held, pending, former, leaving } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      if (!p.noLink) p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'content-announcements-e2e')`);
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    for (const p of Object.values(people)) p.token = (await signIn(p.phone, p.password)).json?.access_token;
    const grantRev = (p) => Number(psql(`select revision from app.identity_grant_sets where member_id = '${p.member}'`));
    const grants = [];
    for (const p of [media, former]) {
      grants.push(await envelope('identity_grant_command', admin.token, 'identity.grant_role', grantRev(p),
        { member_id: p.member, role: 'media' }));
    }
    check('A01-signed-in-by-phone-and-media-granted', Object.values(people).every((p) => amrMethods(p.token).includes('password'))
      && grants.every((g) => g.status === 200 && g.data?.roles?.includes('media')),
      { members: Object.keys(people).length, grants: grants.map((g) => g.status) });

    // ------------------------------------------------------------------ devices, category off, hold, deactivation
    const notif = (p, cmd, expected, payload) => envelope('notifications_command', p.token, cmd, expected, payload);
    const registered = [];
    for (const p of Object.values(people).filter((x) => x.device)) {
      const t = syntheticDeviceToken();
      deviceTokens.push(t);
      registered.push(await notif(p, 'notifications.register_device', null, { token: t, platform: 'android' }));
    }
    const off = await notif(b, 'notifications.set_push_category', null,
      { source_type: 'content_announcement', reminder_kind: 'announcement_published', push_enabled: false });
    const categories = (await rpc('notifications_my_push_settings', a.token)).json?.categories ?? [];
    const category = categories.find((x) => x.source_type === 'content_announcement' && x.reminder_kind === 'announcement_published');
    const memberRev = (p) => Number(psql(`select revision from app.identity_members where member_id = '${p.member}'`));
    const hold = await envelope('identity_credential_command', admin.token, 'identity.place_hold', memberRev(held),
      { member_id: held.member, reason_code: 'security_concern' });
    const deactivate = await envelope('identity_lifecycle_command', admin.token, 'identity.deactivate_membership', memberRev(leaving),
      { member_id: leaving.member, reason_code: 'church_decision' });
    const accountless = psql(`insert into app.identity_members (display_name, membership_state, is_synthetic)
      values ('${NAME_PREFIX} Accountless', 'approved', true) returning member_id`);
    check('A10-devices-category-off-hold-deactivation-accountless', registered.every((r) => r.status === 200)
      && off.status === 200 && off.data?.push_enabled === false && category?.title === NOTICE_TITLE && category?.push_enabled === true
      && hold.status === 200 && !hold.code && deactivate.status === 200 && !deactivate.code && Boolean(accountless),
      { devices: registered.length, category_offered: Boolean(category), category_off: off.data?.push_enabled ?? null,
        hold: hold.code ?? 'ok', deactivate: deactivate.code ?? 'ok' });

    // ------------------------------------------------------------------ drafts are private
    const pinnedBody = `${BODY_MARK} Harvest services all week; bring a friend.`;
    const unpinnedBody = `${BODY_MARK} Choir practice moves to Thursday evening.`;
    const byMember = await content(a.token, 'content.create_announcement', null, { title: PINNED, body: pinnedBody, pinned: true });
    const byPending = await content(pending.token, 'content.create_announcement', null, { title: PINNED, body: pinnedBody, pinned: true });
    const byAnon = await rpc('content_command', undefined, { version: 1, command: 'content.create_announcement',
      request_id: randomUUID(), expected_revision: null, payload: { title: PINNED, body: pinnedBody, pinned: true } });
    const d1 = await content(media.token, 'content.create_announcement', null, { title: PINNED, body: pinnedBody, pinned: true });
    const d2 = await content(media.token, 'content.create_announcement', null, { title: UNPINNED, body: unpinnedBody, pinned: false });
    const id1 = d1.data?.announcement_id;
    const id2 = d2.data?.announcement_id;
    const anon0 = await publicList(undefined);
    check('A11-media-drafts-privately', d1.status === 200 && d1.data?.state === 'draft' && d2.data?.state === 'draft'
      && byMember.code === 'forbidden' && byPending.code === 'forbidden' && byAnon.status === 401
      && titlesOf(anon0).length === 0 && (await publicOne(undefined, id1))?.announcement === null,
      { drafts: [d1.data?.state, d2.data?.state], plain_member: byMember.code, pending: byPending.code, anon_status: byAnon.status,
        anon_listed: titlesOf(anon0).length });

    // ------------------------------------------------------------------ publish: pinned quietly, unpinned with a notice
    const editors = await staff(media.token);
    const p1 = await content(media.token, 'content.publish_announcement', d1.revision, { announcement_id: id1, notify: false });
    const p2 = await content(media.token, 'content.publish_announcement', d2.revision, { announcement_id: id2, notify: true });
    const jobRows = (id) => psql(`select coalesce(string_agg(j.recipient_member_id::text || ':' || j.job_state, ',' order by j.recipient_member_id), '')
      from app.notifications_jobs j where j.source_type = 'content_announcement' and j.source_id = '${id}'`);
    const reachable = [admin, media, a, b, c, former].map((p) => p.member).sort();
    const pendingJobs = jobRows(id2).split(',').filter(Boolean);
    check('A12-a-notice-enqueues-one-job-per-reachable-member', p1.status === 200 && p1.data?.notified === 0 && jobRows(id1) === ''
      && p2.status === 200 && p2.data?.notified === 6 && editors.json?.audience?.members === 6
      && JSON.stringify(pendingJobs.map((x) => x.split(':')[0]).sort()) === JSON.stringify(reachable)
      && pendingJobs.every((x) => x.endsWith(':pending')),
      { quiet_notified: p1.data?.notified, notice_notified: p2.data?.notified, audience: editors.json?.audience ?? null,
        jobs: pendingJobs.length });

    const anon1 = await publicList(undefined);
    const pendingRead = await publicList(pending.token);
    const memberRead = await publicList(a.token);
    const texts = [anon1, pendingRead, memberRead].map((x) => JSON.stringify(x));
    const editorLeaks = leaks(texts.join(' '), [media.member, media.user, media.name, 'saved_by', 'published_by', 'notified', 'draft']);
    check('A13-anonymous-read-both-pinned-first', JSON.stringify(titlesOf(anon1)) === JSON.stringify([PINNED, UNPINNED])
      && anon1?.announcements?.[0]?.pinned === true && anon1?.announcements?.[1]?.pinned === false
      && anon1.announcements.every((x) => JSON.stringify(sortedKeys(x)) === JSON.stringify(PUBLIC_KEYS))
      && texts[0] === texts[1] && texts[1] === texts[2] && editorLeaks.length === 0
      && (await publicOne(undefined, id2))?.announcement?.title === UNPINNED,
      { titles_in_order: titlesOf(anon1).map((t) => (t === PINNED ? 'pinned' : 'unpinned')), keys: sortedKeys(anon1?.announcements?.[0]),
        same_for_anon_pending_member: texts[0] === texts[1] && texts[1] === texts[2], editor_fields_leaked: editorLeaks.length });

    // ------------------------------------------------------------------ the worker: inbox items, attempt rows, push jobs
    const step = await sys('notifications.deliver_due', {});
    const members = { admin, media, a, b, c, former, held, leaving };
    const count = (sql) => Number(psql(sql));
    const itemsOf = (p) => count(`select count(*) from app.notifications_inbox_items i join app.notifications_jobs j on j.job_id = i.job_id
      where j.source_id = '${id2}' and i.recipient_member_id = '${p.member}'`);
    const pushOf = (memberId) => count(`select count(*) from app.notifications_push_jobs p join app.notifications_jobs j on j.job_id = p.job_id
      where j.source_id = '${id2}' and p.recipient_member_id = '${memberId}'`);
    const inboxes = {};
    for (const [k, p] of Object.entries({ admin, media, a, b, c, former })) {
      const r = await rpc('notifications_my_inbox', p.token);
      inboxes[k] = (r.json?.items ?? []).filter((i) => i.reminder_kind === 'announcement_published');
    }
    check('A20-each-eligible-member-gets-one-inbox-item', step.status === 200 && step.data?.delivered === 6
      && Object.values(inboxes).every((list) => list.length === 1 && list[0].title === NOTICE_TITLE && list[0].body === NOTICE_BODY)
      && ['admin', 'media', 'a', 'b', 'c', 'former'].every((k) => itemsOf(members[k]) === 1),
      { delivered: step.data?.delivered ?? null, items: Object.fromEntries(Object.entries(inboxes).map(([k, l]) => [k, l.length])) });
    const attempts = count(`select count(*) from app.notifications_attempts t join app.notifications_jobs j on j.job_id = t.job_id
      where j.source_id = '${id2}' and t.outcome = 'delivered'`);
    const jobStates = psql(`select coalesce(string_agg(distinct j.job_state || '|' || coalesce(j.finish_reason, '-'), ','), '')
      from app.notifications_jobs j where j.source_id = '${id2}'`);
    const strays = count(`select (select count(*) from app.notifications_jobs j
                                   where j.source_type = 'content_announcement'
                                     and j.recipient_member_id in ('${held.member}', '${leaving.member}', '${accountless}'))
                               + (select count(*) from app.notifications_inbox_items i
                                   where i.recipient_member_id in ('${held.member}', '${leaving.member}', '${accountless}'))
                               + (select count(*) from app.notifications_direct_contact_needs n where n.source_type = 'content_announcement')`);
    check('A21-job-and-attempt-rows', attempts === 6 && jobStates === 'delivered|delivered' && strays === 0,
      { delivered_attempts: attempts, job_states: jobStates, held_deactivated_accountless_rows_and_needs: strays });
    check('A22-push-job-only-with-a-device-and-the-category-on', pushOf(a.member) === 1 && pushOf(b.member) === 0
      && pushOf(c.member) === 0 && pushOf(held.member) === 0 && pushOf(leaving.member) === 0 && pushOf(accountless) === 0
      && pushOf(admin.member) === 0,
      { member_with_device: pushOf(a.member), category_off: pushOf(b.member), no_device: pushOf(c.member),
        held: pushOf(held.member), deactivated: pushOf(leaving.member), accountless: pushOf(accountless) });
    const itemA = inboxes.a?.[0]?.item_id;
    const opened = await rpc('notifications_open_item', a.token, { item_id: itemA });
    const signedOut = await rpc('notifications_open_item', undefined, { item_id: itemA });
    check('A23-the-item-opens-the-announcement', opened.status === 200 && opened.json?.state === 'current'
      && opened.json?.target === `/announcements/${id2}` && signedOut.status === 401,
      { state: opened.json?.state ?? null, target_is_announcement: opened.json?.target === `/announcements/${id2}`, signed_out: signedOut.status });

    // ------------------------------------------------------------------ the push message is generic
    psql(`select app.policy_approve('outbound_sending', '{"enabled": true, "scope": "local announcements e2e"}',
      '${OPERATOR}', 'LOCAL E2E ONLY: content-announcements.mjs opens the gate and restores it in cleanup');
      select app.notifications_configure_worker('{"push_enabled": true}', '${OPERATOR}');`);
    const claimed = await sys('notifications.push_claim', {});
    const pushJobA = psql(`select p.push_job_id from app.notifications_push_jobs p join app.notifications_jobs j on j.job_id = p.job_id
      where j.source_id = '${id2}' and p.recipient_member_id = '${a.member}'`);
    const lease = (claimed.data?.jobs ?? []).find((x) => x.push_job_id === pushJobA);
    const prepared = await sys('notifications.push_prepare', { push_job_id: pushJobA, lease_token: lease?.lease_token });
    const released = await sys('notifications.push_release', { push_job_id: pushJobA, lease_token: lease?.lease_token });
    psql(`select app.notifications_configure_worker('{"push_enabled": false}', '${OPERATOR}')`);
    const message = prepared.data?.message ?? {};
    const contentValues = [PINNED, UNPINNED, BODY_MARK, 'Choir', 'Harvest'];
    check('A30-the-push-payload-carries-no-announcement-text', claimed.status === 200 && Boolean(lease)
      && prepared.data?.outcome === 'send' && message.title === NOTICE_TITLE && message.body === NOTICE_BODY
      && message.item_id === itemA && leaks(JSON.stringify(prepared.data ?? {}), contentValues).length === 0
      && released.status === 200,
      { outcome: prepared.data?.outcome ?? null, message_keys: sortedKeys(message), generic_text: message.title === NOTICE_TITLE
        && message.body === NOTICE_BODY, leaked: leaks(JSON.stringify(prepared.data ?? {}), contentValues).length,
        released: released.data?.outcome ?? released.status });
    const stored = psql(`select coalesce(string_agg(x, ' '), '') from (
        select to_jsonb(j)::text as x from app.notifications_jobs j where j.source_id in ('${id1}', '${id2}')
        union all select to_jsonb(t)::text from app.notifications_attempts t join app.notifications_jobs j on j.job_id = t.job_id
         where j.source_id in ('${id1}', '${id2}')
        union all select to_jsonb(i)::text from app.notifications_inbox_items i join app.notifications_jobs j on j.job_id = i.job_id
         where j.source_id in ('${id1}', '${id2}')
        union all select to_jsonb(p)::text from app.notifications_push_jobs p join app.notifications_jobs j on j.job_id = p.job_id
         where j.source_id in ('${id1}', '${id2}')
        union all select r.result::text from app.cmd_receipts r where r.actor_id in (${[...users].map((u) => `'${u}'`).join(',')})
        union all select r.result::text from app.sys_receipts r
        union all select to_jsonb(a)::text from app.content_audit a where a.item_id in ('${id1}', '${id2}')) s`);
    check('A31-no-row-or-receipt-carries-the-announcement', leaks(stored, contentValues).length === 0
      && leaks(sysRaw.join(' '), contentValues).length === 0,
      { leaked_in_rows_and_receipts: leaks(stored, contentValues).length, leaked_in_route_answers: leaks(sysRaw.join(' '), contentValues).length });

    // ------------------------------------------------------------------ withdraw, republish, refusals
    const w = await content(media.token, 'content.withdraw_announcement', p2.revision, { announcement_id: id2 });
    const anon2 = await publicList(undefined);
    const stale = await rpc('notifications_open_item', a.token, { item_id: itemA });
    const again = await content(media.token, 'content.publish_announcement', w.revision, { announcement_id: id2, notify: true });
    const quiet = await content(media.token, 'content.publish_announcement', w.revision, { announcement_id: id2, notify: false });
    const jobsAfter = jobRows(id2).split(',').filter(Boolean).length;
    check('A40-withdrawal-and-one-notice-per-revision', w.status === 200 && w.data?.state === 'withdrawn'
      && JSON.stringify(titlesOf(anon2)) === JSON.stringify([PINNED]) && stale.json?.state === 'superseded'
      && again.code === 'validation_failed' && again.field_errors?.notify === 'already_notified'
      && quiet.status === 200 && quiet.data?.state === 'published' && jobsAfter === 6,
      { withdrawn: w.data?.state, listed_after: titlesOf(anon2).length, item_after_withdrawal: stale.json?.state ?? null,
        notify_again: again.field_errors?.notify ?? again.code, republished_quietly: quiet.data?.state, jobs: jobsAfter });
    const current = quiet.revision;
    const refusals = [];
    for (const [cmd, payload] of [['content.create_announcement', { title: OTHER, body: unpinnedBody, pinned: false }],
      ['content.save_announcement', { announcement_id: id2, title: OTHER, body: unpinnedBody, pinned: false }],
      ['content.publish_announcement', { announcement_id: id2, notify: true }],
      ['content.withdraw_announcement', { announcement_id: id2 }], ['content.archive_announcement', { announcement_id: id2 }]]) {
      refusals.push((await content(a.token, cmd, cmd === 'content.create_announcement' ? null : current, payload)).code);
    }
    const memberStaff = await staff(a.token);
    const pendingStaff = await staff(pending.token);
    const anonStaff = await staff(undefined);
    const tables = [];
    for (const token of [undefined, a.token, media.token]) {
      for (const profile of ['app', 'api']) {
        const read = await http('GET', '/rest/v1/content_announcement_revisions?select=*', { token, profile });
        tables.push(read.status >= 400 && !Array.isArray(read.json));
      }
    }
    check('A41-plain-member-refused-and-no-table-access', refusals.every((x) => x === 'forbidden')
      && memberStaff.status === 403 && memberStaff.detail === 'not_granted' && pendingStaff.status === 403
      && anonStaff.status === 401 && tables.every(Boolean),
      { refusals, member_staff: `${memberStaff.status}:${memberStaff.detail}`, pending_staff: pendingStaff.status,
        anon_staff: anonStaff.status, table_reads_refused: tables.filter(Boolean).length });

    // ------------------------------------------------------------------ an erased editor reads as a former member
    const o = await content(former.token, 'content.create_announcement', null, { title: OTHER, body: unpinnedBody, pinned: false });
    const otherId = o.data?.announcement_id;
    await content(former.token, 'content.publish_announcement', o.revision, { announcement_id: otherId, notify: false });
    const hook = (phase) => JSON.parse(psql(`select app.content_erase_member(jsonb_build_object(
      'member_id', '${former.member}', 'account_id', '${former.user}', 'deletion_id', gen_random_uuid(), 'phase', '${phase}'))`));
    const before = hook('check');
    const erased = hook('erase');
    const after = hook('check');
    const view = (await staff(admin.token)).json?.announcements?.find((x) => x.announcement_id === otherId);
    check('A50-erased-editor-reads-as-a-former-member', before.remaining > 0 && erased.remaining === 0 && after.remaining === 0
      && view?.created_by === 'Former member' && view?.published_by === 'Former member' && view?.live?.saved_by === 'Former member'
      && titlesOf(await publicList(undefined)).includes(OTHER),
      { before: before.remaining, after: after.remaining, created_by: view?.created_by ?? null });
  } finally {
    const gate = restoreOnce();
    const left = cleanup();
    psql(`select app.sys_revoke_credential('${credentialId}', '${OPERATOR}');
          select app.sys_disable_principal('${principal}', '${OPERATOR}');
          delete from app.notifications_worker_runs where principal_id = '${principal}';`);
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'content-announcements-e2e';
            delete from app.platform_environment_history where set_by = 'content-announcements-e2e';`);
    }
    log('A99-cleanup', { users_left: Number(left), credential_revoked: true, principal_disabled: true, unmarked: marked,
      outbound_sending_restored: gate === (JSON.parse(gateBefore).state === 'approved' ? 't' : 'f'),
      push_enabled_restored: (psql(`select push_enabled from app.notifications_worker_settings`) === 't') === pushBefore,
      items_left: Number(psql(`select count(*) from app.content_announcement_revisions where title like 'SYNTHETIC % (6.13 E2E)'`)) });
  }
  finish();
}

runMain(import.meta.url, main);
