#!/usr/bin/env node
// Epic 6 entry 14, LOCAL only: real phone/password Auth, Content commands and the public search
// read api.content_public_search. A Media editor publishes a SYNTHETIC sermon in a series, an
// event and a pinned announcement that share one search word, and keeps a draft and a withdrawn
// item with the same word; a signed-out caller, a Pending account and a member then search. No
// notification, policy approval, staging or production access is made (publish uses notify
// false). Synthetic published fixtures stay immutable in this disposable database; reset before
// running again. Run the full SQL suite first. Enable the local phone harness before this run;
// the run restores its off state, including when a check throws.
// Usage: node tools/identity-e2e/content-search.mjs [--evidence <file.jsonl>]
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';

const OPERATOR = 'israel';
const PREFIX = 'SYNTHETIC Search 6.14 E2E';
// One word every fixture carries, so a single search reaches all three kinds.
export const WORD = 'Zambezisearch';
const phoneAuthScript = fileURLToPath(new URL('../auth-harness/local-phone-auth.mjs', import.meta.url));
export const SYNTHETIC_PHONES = Object.freeze(['+447700900575', '+447700900576', '+447700900577', '+447700900578']);
export const SEARCH_KEYS = Object.freeze(['announcements', 'events', 'query', 'sermons', 'truncated']);

export const isFictionalSearchPhone = (phone) => SYNTHETIC_PHONES.includes(phone);

/** Top-level keys of a search answer, sorted. */
export const sortedKeys = (value) => Object.keys(value ?? {}).sort();

/** Whether an answer has exactly the five keys and three lists of at most ten. */
export function isSearchAnswer(value) {
  return JSON.stringify(sortedKeys(value)) === JSON.stringify(SEARCH_KEYS)
    && ['sermons', 'events', 'announcements'].every((k) => Array.isArray(value[k]) && value[k].length <= 10)
    && typeof value.truncated === 'boolean' && typeof value.query === 'string';
}

/** The ids of one kind in an answer, in order. */
export const idsOf = (answer, kind, key) => (answer?.[kind] ?? []).map((item) => item[key]);

/** Strings that must never appear in a public answer. */
export const leaks = (text, needles) => needles.filter((n) => n && text.includes(n));

/** A church-time ISO instant [days] from now at [hour]:00 (Africa/Lusaka is UTC+2). */
export function churchInstant(days, hour) {
  const d = new Date(Date.now() + days * 86400000);
  d.setUTCHours(hour - 2, 0, 0, 0);
  return d.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

async function main() {
  const { log, check, finish } = startRun();
  const keys = localKey(); // harness enforces the exact 127.0.0.1 local origin
  const http = localHttp(keys);
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const envelope = (fn, token, command, expected, payload) => rpc(fn, token, {
    version: 1, command, request_id: randomUUID(), expected_revision: expected, payload,
  }).then((response) => ({ status: response.status, ...response.json }));
  const content = (person, command, expected, payload) => envelope('content_command', person?.token, command, expected, payload);
  const search = (person, query) => rpc('content_public_search', person?.token, { query });
  const people = Object.fromEntries(['admin', 'media', 'member', 'pending'].map((role, i) => [role, {
    phone: SYNTHETIC_PHONES[i], name: `${PREFIX} ${role}`, noLink: role === 'pending',
  }]));
  const users = new Set();
  const phones = SYNTHETIC_PHONES.map((phone) => `'${phone.slice(1)}'`).join(',');
  let marked = false;
  let startedAuthWork = false;
  let cleaned = false;
  let finalized = false;

  // Immutable content stays in the disposable local stack. Erase attribution before deleting
  // only this run's synthetic identities; never disable content guards.
  const cleanupIdentities = () => {
    if (cleaned || !startedAuthWork) return;
    cleaned = true;
    const ids = [...users].filter(Boolean).map((id) => `'${id}'`);
    const byId = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    const output = psql(`
      create temp table gone_users as select u.id from auth.users u where ${byId}u.phone in (${phones});
      create temp table gone_members as select distinct l.member_id from app.identity_account_links l
        join gone_users u on u.id=l.auth_user_id;
      select app.content_erase_member(jsonb_build_object('member_id', l.member_id, 'account_id', l.auth_user_id,
        'deletion_id',gen_random_uuid(),'phase','erase')) from app.identity_account_links l join gone_users u on u.id=l.auth_user_id;
      delete from app.identity_access_audit a where a.target_member_id in (select member_id from gone_members)
        or a.actor_member_id in (select member_id from gone_members);
      delete from app.identity_grants g where g.member_id in (select member_id from gone_members);
      delete from app.identity_grant_sets s where s.member_id in (select member_id from gone_members);
      delete from app.identity_holds h where h.member_id in (select member_id from gone_members);
      delete from app.identity_binding_history h using app.identity_account_links l where h.link_id=l.link_id
        and (l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users));
      delete from app.identity_credential_events e using app.identity_account_links l where e.link_id=l.link_id
        and (l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users));
      delete from app.identity_account_links l where l.member_id in (select member_id from gone_members)
        or l.auth_user_id in (select id from gone_users);
      delete from app.identity_members m where m.member_id in (select member_id from gone_members);
      delete from app.cmd_receipts r where r.actor_id in (select id from gone_users);
      delete from auth.users u where u.id in (select id from gone_users);
      select count(*) from auth.users u where ${byId}u.phone in (${phones});
    `);
    const left = Number(output.split(/\r?\n/).at(-1));
    if (left !== 0) throw new Error('synthetic Auth cleanup did not finish');
    log('S99-cleanup', { synthetic_accounts_left: left, immutable_content_retained: true,
      instruction: 'reset the local database before another run' });
  };

  const finalize = () => {
    if (finalized) return;
    finalized = true;
    try {
      cleanupIdentities();
      if (marked) psql(`delete from app.platform_environment where set_by='content-search-e2e';
        delete from app.platform_environment_history where set_by='content-search-e2e';`);
    } finally {
      execFileSync(process.execPath, [phoneAuthScript, 'off'], { stdio: 'inherit', windowsHide: true });
    }
  };
  const onSignal = (code) => {
    try { finalize(); } catch (error) { console.error(`local cleanup failed: ${error.message}`); }
    process.exit(code);
  };
  const onInterrupt = () => onSignal(130);
  const onTerminate = () => onSignal(143);
  process.once('SIGINT', onInterrupt);
  process.once('SIGTERM', onTerminate);

  try {
    const settings = await http('GET', '/auth/v1/settings');
    if (settings.json?.external?.phone !== true) throw new Error('enable local phone auth with tools/auth-harness/local-phone-auth.mjs on first');
    const existing = Number(psql(`select count(*) from app.content_announcement_revisions where title like '${PREFIX}%'`));
    if (existing !== 0) throw new Error('6.14 immutable fixtures exist; reset the local database before a second run');
    const marker = psql(`select coalesce((select environment from app.platform_environment),'')`);
    if (marker === '') {
      psql(`select app.platform_set_environment('local','content-search-e2e')`);
      marked = true;
    } else if (marker !== 'local') throw new Error('local database is not marked local');
    startedAuthWork = true;
    log('S00-precondition', { phone_auth_enabled: true, local_environment: true });

    const { admin, media, member, pending } = people;
    for (const person of Object.values(people)) {
      if (!isFictionalSearchPhone(person.phone)) throw new Error('fixture phone is not reserved');
      const pw = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true,
        body: { phone: person.phone, phone_confirm: true, password: pw } });
      person.user = created.json?.id;
      if (!person.user) throw new Error('synthetic Auth user creation failed');
      users.add(person.user);
      if (!person.noLink) person.member = psql(`select app.identity_seed_synthetic_link('${person.user}','${person.name}','content-search-e2e')`);
      person.token = (await http('POST', '/auth/v1/token?grant_type=password', { body: { phone: person.phone, password: pw } })).json?.access_token;
      if (!person.token) throw new Error('synthetic phone sign-in failed');
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}','${OPERATOR}')`);
    const revision = Number(psql(`select revision from app.identity_grant_sets where member_id='${media.member}'`));
    const grant = await envelope('identity_grant_command', admin.token, 'identity.grant_role', revision,
      { member_id: media.member, role: 'media' });
    check('S01-phone-auth-and-media-role', Object.values(people).every((person) => amrMethods(person.token).includes('password'))
      && grant.status === 200 && !grant.code, { media_grant: grant.code ?? grant.status });

    // Published: a series, a sermon in it, an event and a pinned announcement. Kept back: a draft
    // sermon, a draft event and a withdrawn announcement with the same word.
    const series = await content(media, 'content.create_sermon_series', null,
      { title: `${PREFIX} ${WORD} series`, description: '', alt_text: 'SYNTHETIC poster' });
    const seriesId = series.data?.series_id;
    const seriesPublished = await content(media, 'content.publish_sermon_series', series.revision, { series_id: seriesId });
    const sermonInput = (title, seriesRef) => ({ title, speaker: 'SYNTHETIC Speaker One', sermon_date: '2026-10-25',
      scripture_reference: 'Psalm 23:1', notes: 'SYNTHETIC notes.', series_id: seriesRef,
      youtube_video_id: null, video_rights_id: null });
    const sermon = await content(media, 'content.create_sermon', null, sermonInput(`${PREFIX} Still waters`, seriesId));
    const sermonPublished = await content(media, 'content.publish_sermon', sermon.revision, { sermon_id: sermon.data?.sermon_id });
    const sermonDraft = await content(media, 'content.create_sermon', null, sermonInput(`${PREFIX} ${WORD} draft`, null));
    const eventInput = (title) => ({ title, description: `SYNTHETIC gathering by the ${WORD} river.`,
      starts_at: churchInstant(7, 9), ends_at: churchInstant(7, 12), location: 'SYNTHETIC Church grounds' });
    const event = await content(media, 'content.create_event', null, eventInput(`${PREFIX} Youth day`));
    const eventPublished = await content(media, 'content.publish_event', event.revision, { event_id: event.data?.event_id });
    const eventDraft = await content(media, 'content.create_event', null, eventInput(`${PREFIX} Draft day`));
    const notice = await content(media, 'content.create_announcement', null,
      { title: `${PREFIX} ${WORD} offering`, body: 'SYNTHETIC Bring your offering on Sunday.', pinned: true });
    const noticePublished = await content(media, 'content.publish_announcement', notice.revision,
      { announcement_id: notice.data?.announcement_id, notify: false });
    const gone = await content(media, 'content.create_announcement', null,
      { title: `${PREFIX} ${WORD} withdrawn`, body: 'SYNTHETIC Withdrawn notice.', pinned: false });
    const gonePublished = await content(media, 'content.publish_announcement', gone.revision,
      { announcement_id: gone.data?.announcement_id, notify: false });
    const goneWithdrawn = await content(media, 'content.withdraw_announcement', gonePublished.revision,
      { announcement_id: gone.data?.announcement_id });
    const published = [seriesPublished, sermonPublished, eventPublished, noticePublished, goneWithdrawn];
    check('S10-synthetic-content-published-without-notice', published.every((r) => r.status === 200 && !r.code)
      && !sermonDraft.code && !eventDraft.code && noticePublished.data?.notified === 0,
      { published: published.filter((r) => !r.code).length, notified: noticePublished.data?.notified });

    const anon = await search(undefined, WORD.toLowerCase());
    const answer = anon.json;
    const sermonIds = idsOf(answer, 'sermons', 'sermon_id');
    const eventIds = idsOf(answer, 'events', 'event_id');
    const noticeIds = idsOf(answer, 'announcements', 'announcement_id');
    check('S11-one-word-finds-a-sermon-an-event-and-an-announcement', anon.status === 200 && isSearchAnswer(answer)
      && JSON.stringify(sermonIds) === JSON.stringify([sermon.data?.sermon_id])
      && JSON.stringify(eventIds) === JSON.stringify([event.data?.event_id])
      && JSON.stringify(noticeIds) === JSON.stringify([notice.data?.announcement_id]) && answer.truncated === false,
      { status: anon.status, sermons: sermonIds.length, events: eventIds.length, announcements: noticeIds.length });

    const sermonDetail = (await rpc('content_public_sermon', undefined, { sermon_id: sermon.data?.sermon_id })).json?.sermon;
    const eventDetail = (await rpc('content_public_event', undefined, { event_id: event.data?.event_id })).json?.event;
    const noticeDetail = (await rpc('content_public_announcement', undefined,
      { announcement_id: notice.data?.announcement_id })).json?.announcement;
    check('S12-results-are-the-public-projections', JSON.stringify(answer.sermons[0]) === JSON.stringify(sermonDetail)
      && JSON.stringify(answer.events[0]) === JSON.stringify(eventDetail)
      && JSON.stringify(answer.announcements[0]) === JSON.stringify(noticeDetail),
      { sermon_same: JSON.stringify(answer.sermons[0]) === JSON.stringify(sermonDetail),
        event_same: JSON.stringify(answer.events[0]) === JSON.stringify(eventDetail),
        announcement_same: JSON.stringify(answer.announcements[0]) === JSON.stringify(noticeDetail) });

    const asPending = (await search(pending, WORD.toLowerCase())).json;
    const asMember = (await search(member, WORD.toUpperCase())).json;
    const text = JSON.stringify(answer);
    const leaked = leaks(text, [media.name, admin.name, media.member, media.user, 'saved_by', 'created_by', 'draft',
      sermonDraft.data?.sermon_id, eventDraft.data?.event_id, gone.data?.announcement_id]);
    check('S13-every-caller-reads-the-same-answer-and-nothing-private', JSON.stringify(asPending) === text
      && JSON.stringify({ ...asMember, query: answer.query }) === text && leaked.length === 0,
      { pending_same: JSON.stringify(asPending) === text, member_same_ignoring_case: JSON.stringify({ ...asMember, query: answer.query }) === text,
        leaked_fields: leaked.length });

    const short = await search(undefined, 'a');
    const long = await search(undefined, 'x'.repeat(101));
    const blank = await search(undefined, '   ');
    const percent = (await search(undefined, '%%')).json;
    check('S20-the-query-is-bounded-and-literal', [short, long, blank].every((r) => r.status === 400 && r.json?.message === 'invalid')
      && isSearchAnswer(percent) && percent.sermons.length + percent.events.length + percent.announcements.length === 0,
      { short: short.status, long: long.status, blank: blank.status, percent_matches: (percent?.sermons?.length ?? -1) });

    const table = await http('GET', '/rest/v1/content_items?select=item_id', { profile: 'app' });
    const command = await content(undefined, 'content.create_announcement', null, { title: 'x', body: 'x', pinned: false });
    check('S30-anonymous-reads-only-the-function', table.status >= 400 && command.status === 401,
      { table_read: table.status, anonymous_command: command.status });

    const boundaryViolations = Number(psql('select count(*) from app.contract_boundary_violations()'));
    const unownedObjects = Number(psql('select count(*) from app.contract_unowned_objects()'));
    check('S40-module-boundaries-remain-clear', boundaryViolations === 0 && unownedObjects === 0,
      { boundary_violations: boundaryViolations, unowned_objects: unownedObjects });
  } finally {
    process.removeListener('SIGINT', onInterrupt);
    process.removeListener('SIGTERM', onTerminate);
    finalize();
  }
  finish();
}

runMain(import.meta.url, main);
