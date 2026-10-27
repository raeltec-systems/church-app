#!/usr/bin/env node
// Entry 6.9, LOCAL only: real phone/password Auth, Content commands/public RPCs and
// the purpose-driven content-assets pipeline. No YouTube request, policy approval,
// notification or production/staging access is made. Synthetic published fixtures
// stay immutable in this disposable database; reset before running this again.
// Run the full SQL suite first. Enable the local phone harness before this run;
// the run restores its off state, including when a check throws.
// Usage: node tools/identity-e2e/content-sermons.mjs [--evidence <file.jsonl>]
import { execFileSync, spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

import { amrMethods, localHttp, localKey, password, psql, runMain, sleep, startRun } from './harness.mjs';
import { solidPng } from './content-banners.mjs';

const OPERATOR = 'israel';
const PREFIX = 'SYNTHETIC Sermons 6.9 E2E';
const phoneAuthScript = fileURLToPath(new URL('../auth-harness/local-phone-auth.mjs', import.meta.url));
export const SYNTHETIC_PHONES = Object.freeze(Array.from({ length: 6 }, (_, i) => `+44770090065${i + 1}`));
export const SERIES_TITLES = Object.freeze(['SYNTHETIC Faithfulness (6.9 E2E)', 'SYNTHETIC Hope (6.9 E2E)']);
export const SERMON_TITLES = Object.freeze(['SYNTHETIC A faithful promise (6.9 E2E)', 'SYNTHETIC Hope for tomorrow (6.9 E2E)']);
export const SUPPORTED_NOTES = '# SYNTHETIC Notes\n\nA **faithful** promise and *hope*.\n\n- Read together\n- Pray together\n\n[Read the passage](https://ebible.org/web/GEN01.htm)';
export const UNSAFE_NOTES = Object.freeze([
  '<script>alert(1)</script>', '<b>HTML</b>', '![image](https://ebible.org/image.png)',
  '[unsafe](javascript:alert(1))', '[unsafe](http://ebible.org/)', '[unsafe](https://example.com/)',
  '[disguised](https://ebible.org.evil.example/)', '[userinfo](https://ebible.org@evil.example/)',
  '[userinfo](https://user@ebible.org/)', '[port](https://ebible.org:443/)',
  '[reference][ref]\n\n[ref]: https://ebible.org/', '<https://ebible.org/>',
  '[encoded host](https://%65bible.org/)', '[alternate port](https://ebible.org:8443/)',
]);
export const PUBLIC_SERMON_KEYS = Object.freeze([
  'notes', 'offline_allowed', 'publication_revision', 'published_at', 'rights_revision',
  'scripture_reference', 'series', 'sermon_date', 'sermon_id', 'speaker', 'title', 'youtube_video_id',
]);
export const PUBLIC_SERIES_KEYS = Object.freeze([
  'alt_text', 'description', 'offline_allowed', 'poster', 'publication_revision', 'published_at', 'series_id', 'title',
]);
export const PUBLIC_POSTER_KEYS = Object.freeze(['height', 'media_type', 'offline_allowed', 'path', 'rights_revision', 'width']);

export const sortedKeys = (value) => Object.keys(value ?? {}).sort();
export const isFictionalSermonPhone = (phone) => SYNTHETIC_PHONES.includes(phone);
export const findSermon = (catalog, id) => (catalog?.sermons ?? []).find((sermon) => sermon.sermon_id === id);
export const findSeries = (catalog, id) => (catalog?.series ?? []).find((series) => series.series_id === id);
export const leaks = (text, values) => values.filter((value) => typeof value === 'string' && value && text.includes(value));

function exactKeys(value, keys) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && JSON.stringify(sortedKeys(value)) === JSON.stringify(keys);
}

/** Strict evidence guard: neither a private field nor an unexpected nested key is tolerated. */
export function isPublicSeries(value) {
  return exactKeys(value, PUBLIC_SERIES_KEYS)
    && (value.poster === null || exactKeys(value.poster, PUBLIC_POSTER_KEYS));
}

export function isPublicSermon(value) {
  return exactKeys(value, PUBLIC_SERMON_KEYS) && (value.series === null || isPublicSeries(value.series));
}

export function isPublicCatalog(value) {
  return exactKeys(value, ['series', 'sermons', 'truncated'])
    && Array.isArray(value.sermons) && Array.isArray(value.series) && typeof value.truncated === 'boolean'
    && value.sermons.every(isPublicSermon) && value.series.every(isPublicSeries);
}

/** Complete draft input, including the intentionally optional video/series fields. */
export function sermonInput(overrides = {}) {
  return {
    title: SERMON_TITLES[0], speaker: 'SYNTHETIC Speaker One', sermon_date: '2026-10-25',
    scripture_reference: 'Genesis 1:1', notes: SUPPORTED_NOTES, series_id: null,
    youtube_video_id: null, video_rights_id: null, ...overrides,
  };
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
  const catalog = async (person) => (await rpc('content_public_sermons', person?.token)).json;
  const detail = async (person, id) => (await rpc('content_public_sermon', person?.token, { sermon_id: id })).json?.sermon;
  const staff = (person, series = false) => rpc(series ? 'content_staff_sermon_series' : 'content_staff_sermons', person?.token);
  const assets = async (query, person, bytes) => {
    const headers = { apikey: keys.key };
    if (person?.token) headers.Authorization = `Bearer ${person.token}`;
    if (bytes) headers['Content-Type'] = 'image/png';
    const response = await fetch(`${keys.origin}/functions/v1/content-assets?${query}`, { method: 'POST', headers, body: bytes });
    let json = null;
    try { json = await response.json(); } catch { /* coarse error only */ }
    return { status: response.status, json };
  };
  const people = Object.fromEntries(['admin', 'media', 'pastor', 'member', 'pending', 'former'].map((role, i) => [role, {
    phone: SYNTHETIC_PHONES[i], name: `${PREFIX} ${role}`, noLink: role === 'pending',
  }]));
  const users = new Set();
  const phones = SYNTHETIC_PHONES.map((phone) => `'${phone.slice(1)}'`).join(',');
  let marked = false;
  let serve = null;
  let startedAuthWork = false;
  let cleaned = false;
  let finalized = false;

  // Immutable content stays in the disposable local stack. Erase attribution before
  // deleting only this run's synthetic identities; never disable content guards.
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
      if (marked) psql(`delete from app.platform_environment where set_by='content-sermons-e2e';
        delete from app.platform_environment_history where set_by='content-sermons-e2e';`);
    } finally {
      if (serve) {
        if (process.platform === 'win32') {
          try { execFileSync('taskkill', ['/pid', String(serve.pid), '/T', '/F'], { stdio: 'ignore', windowsHide: true }); } catch { /* already stopped */ }
        } else {
          try { process.kill(-serve.pid, 'SIGINT'); } catch { /* already stopped */ }
        }
      }
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
    const existing = Number(psql(`select count(*) from app.content_sermon_revisions where title like 'SYNTHETIC % (6.9 E2E)'`));
    if (existing !== 0) throw new Error('6.9 immutable fixtures exist; reset the local database before a second run');
    const marker = psql(`select coalesce((select environment from app.platform_environment),'')`);
    if (marker === '') {
      psql(`select app.platform_set_environment('local','content-sermons-e2e')`);
      marked = true;
    } else if (marker !== 'local') throw new Error('local database is not marked local');
    startedAuthWork = true;

    if ((await assets('action=sync')).status !== 401) {
      serve = process.platform === 'win32'
        ? spawn('npx supabase functions serve', { stdio: 'ignore', shell: true, windowsHide: true })
        : spawn('npx', ['supabase', 'functions', 'serve'], { stdio: 'ignore', detached: true });
      const deadline = Date.now() + 45_000;
      while ((await assets('action=sync')).status !== 401) {
        if (Date.now() >= deadline) throw new Error('content-assets did not start; check the local edge-runtime image');
        await sleep(750);
      }
    }
    log('S00-precondition', { phone_auth_enabled: true, local_environment: true, edge_started_here: Boolean(serve) });

    const { admin, media, pastor, member, pending, former } = people;
    for (const person of Object.values(people)) {
      if (!isFictionalSermonPhone(person.phone)) throw new Error('fixture phone is not reserved');
      const pw = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true,
        body: { phone: person.phone, phone_confirm: true, password: pw } });
      person.user = created.json?.id;
      if (!person.user) throw new Error('synthetic Auth user creation failed');
      users.add(person.user);
      if (!person.noLink) person.member = psql(`select app.identity_seed_synthetic_link('${person.user}','${person.name}','content-sermons-e2e')`);
      person.token = (await http('POST', '/auth/v1/token?grant_type=password', { body: { phone: person.phone, password: pw } })).json?.access_token;
      if (!person.token) throw new Error('synthetic phone sign-in failed');
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}','${OPERATOR}')`);
    const grantResults = [];
    for (const [person, role] of [[media, 'media'], [pastor, 'pastor'], [former, 'media']]) {
      const revision = Number(psql(`select revision from app.identity_grant_sets where member_id='${person.member}'`));
      grantResults.push(await envelope('identity_grant_command', admin.token, 'identity.grant_role', revision,
        { member_id: person.member, role }));
    }
    check('S01-phone-auth-and-editor-roles', Object.values(people).every((person) => amrMethods(person.token).includes('password'))
      && grantResults.every((answer) => answer.status === 200 && !answer.code), { editor_grants: grantResults.map((answer) => answer.code ?? answer.status) });

    // A rights record must clear at least one use (`none_cleared`); the video
    // record that does not clear display clears audio only.
    const makeRights = async (clearsDisplay, clearsOffline, clearsAudio = false) => {
      const fields = {
        label: `SYNTHETIC ${clearsOffline ? 'Poster' : clearsDisplay ? 'Video' : 'Uncleared video'} rights (6.9 E2E)`,
        source_key: 'synthetic-sermon-6-9-e2e', holder: 'SYNTHETIC Church media team', basis: 'church_owned',
        clears_display: clearsDisplay, clears_offline: clearsOffline, clears_audio: clearsAudio,
        evidence: 'SYNTHETIC rights fixture only; no real recording or image rights are asserted.',
      };
      const draft = await content(media, 'content.create_rights_record', null, fields);
      if (!draft.data?.rights_id) throw new Error('synthetic rights draft failed');
      const verified = await content(media, 'content.verify_rights_record', draft.revision, { rights_id: draft.data.rights_id });
      if (verified.code) throw new Error('synthetic rights verification failed');
      return { id: draft.data.rights_id, revision: verified.revision, fields };
    };
    const videoRights = await makeRights(true, false);
    const posterRights = await makeRights(true, true);
    const unclearedRights = await makeRights(false, false, true);

    const seriesDrafts = [];
    for (let i = 0; i < 2; i++) {
      const fields = { title: SERIES_TITLES[i], description: 'SYNTHETIC Church-authored series description.', alt_text: 'SYNTHETIC navy series poster' };
      const draft = await content(i === 0 ? media : pastor, 'content.create_sermon_series', null, fields);
      if (!draft.data?.series_id) throw new Error('synthetic series draft failed');
      seriesDrafts.push({ id: draft.data.series_id, revision: draft.revision, fields });
    }
    const firstSeries = seriesDrafts[0];
    const upload = await assets(`action=upload&item_id=${firstSeries.id}&purpose=sermon_series_poster`, media,
      solidPng(960, 540, [20, 36, 107]));
    const assetId = upload.json?.asset_id ?? upload.json?.image?.asset_id;
    if (!assetId) throw new Error('series poster upload failed');
    const posterSaved = await content(media, 'content.save_sermon_series', firstSeries.revision,
      { series_id: firstSeries.id, ...firstSeries.fields, poster_asset_id: assetId, poster_rights_id: posterRights.id });
    firstSeries.revision = posterSaved.revision;

    const drafts = [];
    for (let i = 0; i < 2; i++) {
      const fields = sermonInput({ title: SERMON_TITLES[i], speaker: `SYNTHETIC Speaker ${i === 0 ? 'One' : 'Two'}`,
        sermon_date: i === 0 ? '2026-10-25' : '2026-10-18', series_id: seriesDrafts[i].id,
        youtube_video_id: i === 0 ? 'SYNTHETIC01' : null, video_rights_id: i === 0 ? videoRights.id : null });
      const draft = await content(i === 0 ? media : admin, 'content.create_sermon', null, fields);
      if (!draft.data?.sermon_id) throw new Error('synthetic sermon draft failed');
      drafts.push({ id: draft.data.sermon_id, revision: draft.revision, fields });
    }
    const draftCatalog = await catalog();
    check('S10-drafts-and-upload-stay-private', seriesDrafts.every((item) => !findSeries(draftCatalog, item.id))
      && drafts.every((item) => !findSermon(draftCatalog, item.id)) && await detail(undefined, drafts[0].id) === null
      && !JSON.stringify(draftCatalog).includes(assetId), { public_drafts: drafts.filter((item) => findSermon(draftCatalog, item.id)).length, poster_uploaded: upload.status === 200 });

    const incomplete = await content(media, 'content.create_sermon', null, sermonInput({ title: `${PREFIX} Incomplete`, speaker: null, sermon_date: null, scripture_reference: null }));
    const refusedIncomplete = await content(media, 'content.publish_sermon', incomplete.revision, { sermon_id: incomplete.data?.sermon_id });
    check('S11-incomplete-draft-cannot-publish', incomplete.data?.state === 'draft' && refusedIncomplete.code === 'validation_failed'
      && await detail(undefined, incomplete.data?.sermon_id) === null,
      { draft_state: incomplete.data?.state, publish: refusedIncomplete.code, fields: sortedKeys(refusedIncomplete.field_errors) });

    for (let i = 0; i < seriesDrafts.length; i++) {
      const item = seriesDrafts[i];
      const published = await content(i === 0 ? media : pastor, 'content.publish_sermon_series', item.revision, { series_id: item.id });
      item.revision = published.revision;
      if (published.code) throw new Error('series publication failed');
    }
    const synced = await assets('action=sync', media);
    for (let i = 0; i < drafts.length; i++) {
      const item = drafts[i];
      const published = await content(i === 0 ? media : admin, 'content.publish_sermon', item.revision, { sermon_id: item.id });
      item.revision = published.revision;
      if (published.code) throw new Error('sermon publication failed');
    }
    const anon = await catalog();
    const pendingRead = await catalog(pending);
    const memberRead = await catalog(member);
    const publicText = JSON.stringify(anon);
    const leaked = leaks(publicText, [media.name, media.member, media.user, 'saved_by', 'published_by', 'created_by', 'video_rights_id', 'poster_asset_id', 'draft']);
    const first = findSermon(anon, drafts[0].id);
    const firstPoster = findSeries(anon, firstSeries.id)?.poster;
    check('S12-published-catalog-is-identical-for-anon-pending-member', isPublicCatalog(anon)
      && publicText === JSON.stringify(pendingRead) && publicText === JSON.stringify(memberRead) && leaked.length === 0
      && drafts.every((item) => Boolean(findSermon(anon, item.id))) && first?.notes === SUPPORTED_NOTES
      && first?.youtube_video_id === 'SYNTHETIC01' && first?.rights_revision === 1
      && JSON.stringify(anon.sermons.filter((item) => drafts.some((draft) => draft.id === item.sermon_id)).map((item) => item.sermon_id))
        === JSON.stringify(drafts.map((item) => item.id))
      && JSON.stringify(await detail(undefined, drafts[0].id)) === JSON.stringify(first),
      { exact_projection: isPublicCatalog(anon), fixture_sermons: drafts.filter((item) => findSermon(anon, item.id)).length,
        same_for_public_callers: publicText === JSON.stringify(pendingRead) && publicText === JSON.stringify(memberRead), leaked_fields: leaked.length });
    const posterResponse = firstPoster
      ? await http('GET', `/storage/v1/object/public/content-public/${firstPoster.path}`) : { status: 0 };
    check('S13-series-poster-uses-existing-public-file-pipeline', synced.status === 200 && firstPoster?.offline_allowed === true
      && firstPoster?.rights_revision === 1 && posterResponse.status === 200,
      { sync: synced.status, published_poster: Boolean(firstPoster), poster_fetch: posterResponse.status });

    const edits = sermonInput({ ...drafts[0].fields, title: 'SYNTHETIC A faithful promise revised (6.9 E2E)' });
    const saved = await content(pastor, 'content.save_sermon', drafts[0].revision, { sermon_id: drafts[0].id, ...edits });
    const stale = await content(admin, 'content.save_sermon', drafts[0].revision, { sermon_id: drafts[0].id, ...edits });
    const editorRead = await staff(media);
    const editorItem = editorRead.json?.sermons?.find((item) => item.sermon_id === drafts[0].id);
    const previous = await detail(undefined, drafts[0].id);
    const republished = await content(admin, 'content.publish_sermon', saved.revision, { sermon_id: drafts[0].id });
    drafts[0].revision = republished.revision;
    const replaced = await detail(undefined, drafts[0].id);
    check('S20-live-revision-preserved-until-replacement-and-stale-save-refused', saved.data?.draft_revision_no === 2 && stale.code === 'conflict'
      && editorItem?.live?.title === SERMON_TITLES[0] && editorItem?.draft?.title === edits.title
      && previous?.title === SERMON_TITLES[0] && previous?.publication_revision === 1
      && replaced?.title === edits.title && replaced?.publication_revision === 2,
      { saved_draft: saved.data?.draft_revision_no, stale_save: stale.code, before: previous?.publication_revision, after: replaced?.publication_revision });

    const unsafeResults = [];
    for (const notes of UNSAFE_NOTES) {
      const result = await content(media, 'content.save_sermon', drafts[0].revision, { sermon_id: drafts[0].id, ...edits, notes });
      unsafeResults.push(result.code === 'validation_failed' && Boolean(result.field_errors?.notes));
    }
    check('S21-server-rejects-unsupported-and-unsafe-notes', unsafeResults.every(Boolean)
      && (await detail(undefined, drafts[0].id))?.notes === SUPPORTED_NOTES,
      { unsafe_cases: unsafeResults.length, rejected_with_notes_field: unsafeResults.filter(Boolean).length });

    const blocked = await content(media, 'content.create_sermon', null, sermonInput({ title: `${PREFIX} Rights blocked`, youtube_video_id: 'SYNTHETIC02', video_rights_id: unclearedRights.id }));
    const blockedPublish = await content(media, 'content.publish_sermon', blocked.revision, { sermon_id: blocked.data?.sermon_id });
    const videoWithdrawn = await content(media, 'content.withdraw_rights_record', videoRights.revision, { rights_id: videoRights.id });
    const noVideo = await detail(undefined, drafts[0].id);
    check('S22-uncleared-video-does-not-publish-and-withdrawn-clearance-preserves-notes', blockedPublish.code === 'validation_failed'
      && Boolean(blockedPublish.field_errors?.video_rights_id) && videoWithdrawn.data?.state === 'withdrawn'
      && noVideo?.youtube_video_id === null && noVideo?.rights_revision === null && noVideo?.notes === SUPPORTED_NOTES
      && noVideo?.scripture_reference === 'Genesis 1:1',
      { uncleared_publish: blockedPublish.code, video_omitted: noVideo?.youtube_video_id === null, notes_retained: noVideo?.notes === SUPPORTED_NOTES });

    const posterRightsDraft = await content(media, 'content.save_rights_record', posterRights.revision,
      { rights_id: posterRights.id, ...posterRights.fields, clears_offline: false });
    const whileRightsDraft = findSeries(await catalog(), firstSeries.id)?.poster;
    const posterRightsReplaced = await content(media, 'content.verify_rights_record', posterRightsDraft.revision, { rights_id: posterRights.id });
    const onlineOnlyPoster = findSeries(await catalog(), firstSeries.id)?.poster;
    check('S22b-current-rights-revision-controls-poster-offline-eligibility', !posterRightsReplaced.code
      && whileRightsDraft?.offline_allowed === true && whileRightsDraft?.rights_revision === 1
      && onlineOnlyPoster?.offline_allowed === false && onlineOnlyPoster?.rights_revision === 2,
      { prior_live_offline: whileRightsDraft?.offline_allowed, current_live_offline: onlineOnlyPoster?.offline_allowed,
        current_rights_revision: onlineOnlyPoster?.rights_revision });

    const seriesWithdrawn = await content(pastor, 'content.withdraw_sermon_series', firstSeries.revision, { series_id: firstSeries.id });
    await assets('action=sync', pastor);
    const afterSeries = await catalog();
    const teaching = findSermon(afterSeries, drafts[0].id);
    check('S23-series-withdrawal-hides-metadata-and-keeps-teaching', seriesWithdrawn.data?.state === 'withdrawn'
      && !findSeries(afterSeries, firstSeries.id) && teaching?.series === null && teaching?.notes === SUPPORTED_NOTES
      && !JSON.stringify(afterSeries).includes(SERIES_TITLES[0]),
      { series_listed: Boolean(findSeries(afterSeries, firstSeries.id)), sermon_readable: Boolean(teaching), series_metadata_omitted: teaching?.series === null });

    const unauthorized = [];
    for (const person of [member, pending]) {
      for (const kind of ['sermon', 'sermon_series']) {
        const idKey = kind === 'sermon' ? 'sermon_id' : 'series_id';
        const id = kind === 'sermon' ? drafts[0].id : seriesDrafts[1].id;
        for (const action of ['create', 'save', 'publish', 'withdraw', 'archive']) {
          const fields = kind === 'sermon' ? sermonInput() : seriesDrafts[1].fields;
          const payload = action === 'create' ? fields : action === 'save' ? { [idKey]: id, ...fields } : { [idKey]: id };
          unauthorized.push((await content(person, `content.${action}_${kind}`, action === 'create' ? null : 1, payload)).code === 'forbidden');
        }
      }
    }
    const forbiddenReads = [];
    for (const person of [undefined, pending, member]) {
      for (const series of [false, true]) forbiddenReads.push((await staff(person, series)).status === (person ? 403 : 401));
    }
    const anonCommand = await content(undefined, 'content.create_sermon', null, sermonInput());
    check('S30-editor-commands-and-reads-reject-other-callers', unauthorized.every(Boolean) && forbiddenReads.every(Boolean) && anonCommand.status === 401,
      { command_refusals: unauthorized.filter(Boolean).length, staff_refusals: forbiddenReads.filter(Boolean).length, anonymous_command: anonCommand.status });
    const tableResults = [];
    for (const table of ['content_sermon_revisions', 'content_sermon_series_revisions']) {
      for (const person of [undefined, member, media, pastor, admin]) {
        for (const profile of ['app', 'api']) {
          const read = await http('GET', `/rest/v1/${table}?select=*`, { token: person?.token, profile });
          const write = await http('POST', `/rest/v1/${table}`, { token: person?.token, profile, body: { title: PREFIX } });
          tableResults.push(read.status >= 400 && write.status >= 400 && !Array.isArray(read.json));
        }
      }
    }
    check('S31-no-client-role-reads-or-writes-new-tables', tableResults.every(Boolean), { attempted_pairs: tableResults.length, refused_pairs: tableResults.filter(Boolean).length });

    const withdrawn = await content(media, 'content.withdraw_sermon', drafts[0].revision, { sermon_id: drafts[0].id });
    const fresh = await catalog();
    check('S40-successful-refresh-excludes-withdrawn-sermon', withdrawn.data?.state === 'withdrawn'
      && !findSermon(fresh, drafts[0].id) && await detail(undefined, drafts[0].id) === null
      && Boolean(findSermon(fresh, drafts[1].id)),
      { withdrawn_listed: Boolean(findSermon(fresh, drafts[0].id)), other_still_listed: Boolean(findSermon(fresh, drafts[1].id)) });
    const archived = await content(admin, 'content.archive_sermon', drafts[1].revision, { sermon_id: drafts[1].id });
    check('S41-archive-removes-public-detail', archived.data?.state === 'archived' && await detail(undefined, drafts[1].id) === null,
      { state: archived.data?.state, public_detail_absent: await detail(undefined, drafts[1].id) === null });

    const formerSeries = await content(former, 'content.create_sermon_series', null,
      { title: `${PREFIX} Former series`, description: 'SYNTHETIC retained series.', alt_text: 'SYNTHETIC series' });
    await content(former, 'content.publish_sermon_series', formerSeries.revision, { series_id: formerSeries.data?.series_id });
    const formerSermon = await content(former, 'content.create_sermon', null,
      sermonInput({ title: `${PREFIX} Former sermon`, series_id: formerSeries.data?.series_id }));
    await content(former, 'content.publish_sermon', formerSermon.revision, { sermon_id: formerSermon.data?.sermon_id });
    const hook = (phase) => JSON.parse(psql(`select app.content_erase_member(jsonb_build_object('member_id','${former.member}',
      'account_id','${former.user}','deletion_id',gen_random_uuid(),'phase','${phase}'))`));
    const before = hook('check');
    const erased = hook('erase');
    const after = hook('check');
    const formerView = (await staff(admin)).json?.sermons?.find((item) => item.sermon_id === formerSermon.data?.sermon_id);
    const formerSeriesView = (await staff(admin, true)).json?.series?.find((item) => item.series_id === formerSeries.data?.series_id);
    check('S50-registered-erase-removes-sermon-and-series-attribution', before.remaining > 0 && erased.remaining === 0 && after.remaining === 0
      && formerView?.created_by === 'Former member' && formerView?.published_by === 'Former member' && formerView?.live?.saved_by === 'Former member'
      && formerSeriesView?.created_by === 'Former member' && formerSeriesView?.published_by === 'Former member'
      && formerSeriesView?.live?.saved_by === 'Former member',
      { before: before.remaining, after: after.remaining, sermon_saved_by_anonymized: formerView?.live?.saved_by === 'Former member',
        series_saved_by_anonymized: formerSeriesView?.live?.saved_by === 'Former member' });
    const boundaryViolations = Number(psql('select count(*) from app.contract_boundary_violations()'));
    const unownedObjects = Number(psql('select count(*) from app.contract_unowned_objects()'));
    check('S51-module-boundaries-remain-clear', boundaryViolations === 0 && unownedObjects === 0,
      { boundary_violations: boundaryViolations, unowned_objects: unownedObjects });
  } finally {
    process.removeListener('SIGINT', onInterrupt);
    process.removeListener('SIGTERM', onTerminate);
    finalize();
  }
  finish();
}

runMain(import.meta.url, main);
