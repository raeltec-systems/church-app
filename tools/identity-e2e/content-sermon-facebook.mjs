#!/usr/bin/env node
// Entry 6.10, LOCAL only: real phone/password Auth, Content commands and the public sermon
// RPCs for a sermon's Facebook video or live link beside YouTube. No request to Facebook or
// YouTube, no policy approval, notification or production/staging access is made. Synthetic
// published fixtures stay immutable in this disposable database; reset before running again.
// Run the full SQL suite first. Enable the local phone harness before this run; the run
// restores its off state, including when a check throws.
// Usage: node tools/identity-e2e/content-sermon-facebook.mjs [--evidence <file.jsonl>]
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';
import { PUBLIC_SERMON_KEYS, findSermon, isPublicCatalog, isPublicSermon, leaks, sortedKeys } from './content-sermons.mjs';

const OPERATOR = 'israel';
const PREFIX = 'SYNTHETIC Facebook sermons 6.10 E2E';
const phoneAuthScript = fileURLToPath(new URL('../auth-harness/local-phone-auth.mjs', import.meta.url));
export const SYNTHETIC_PHONES = Object.freeze(['+447700900115', '+447700900116', '+447700900117', '+447700900118']);
export const NOTES = '# SYNTHETIC Notes\n\nA **faithful** promise.\n\n[Read the passage](https://ebible.org/web/GEN01.htm)';

// Pasted forms and the one value the server stores for each (invented page names and ids).
export const ACCEPTED_LINKS = Object.freeze([
  ['https://m.facebook.com/SyntheticChurch/videos/1061000000000001/?mibextid=SYNTHETIC',
    'https://www.facebook.com/SyntheticChurch/videos/1061000000000001/'],
  ['https://www.facebook.com/watch/live/?ref=watch_permalink&v=1061000000000002',
    'https://www.facebook.com/watch/?v=1061000000000002'],
  ['https://facebook.com/watch?v=1061000000000003', 'https://www.facebook.com/watch/?v=1061000000000003'],
  ['https://fb.watch/SyNtH610a/', 'https://fb.watch/SyNtH610a/'],
]);
// Refused links and the field error each must produce.
export const REFUSED_LINKS = Object.freeze([
  ['https://www.youtube.com/watch?v=abcdefghijk', 'not_facebook'],
  ['https://facebook.com.evil.example/SyntheticChurch/videos/1061000000000001/', 'not_facebook'],
  ['https://example.com/SyntheticChurch/videos/1061000000000001/', 'not_facebook'],
  ['http://www.facebook.com/SyntheticChurch/videos/1061000000000001/', 'invalid'],
  ['https://user@www.facebook.com/SyntheticChurch/videos/1061000000000001/', 'invalid'],
  ['https://www.facebook.com:8443/SyntheticChurch/videos/1061000000000001/', 'invalid'],
  ['https://www.facebook.com/SyntheticChurch/videos/not-a-number/', 'invalid'],
  ['https://www.facebook.com/SyntheticChurch/posts/1061000000000001/', 'invalid'],
  ['https://www.facebook.com/share/v/SYNTHETIC1/', 'invalid'],
  ['https://www.facebook.com/watch/?v=1061000000000001&v=1061000000000002', 'invalid'],
  ['javascript:alert(1)', 'invalid'],
  ['https://www.facebook.com/SyntheticChurch/live/', 'not_embeddable'],
]);

export const isFictionalFacebookPhone = (phone) => SYNTHETIC_PHONES.includes(phone);

/** Complete draft input; exactly one optional video source. */
export function sermonInput(overrides = {}) {
  return {
    title: `${PREFIX} sermon`, speaker: 'SYNTHETIC Speaker One', sermon_date: '2026-10-25',
    scripture_reference: 'Genesis 1:1', notes: NOTES, series_id: null,
    youtube_video_id: null, facebook_video_url: null, video_rights_id: null, ...overrides,
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
  const staffItem = async (person, id) => (await rpc('content_staff_sermons', person?.token)).json?.sermons
    ?.find((item) => item.sermon_id === id);
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
      if (marked) psql(`delete from app.platform_environment where set_by='content-sermon-facebook-e2e';
        delete from app.platform_environment_history where set_by='content-sermon-facebook-e2e';`);
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
    const existing = Number(psql(`select count(*) from app.content_sermon_revisions where title like '${PREFIX}%'`));
    if (existing !== 0) throw new Error('6.10 immutable fixtures exist; reset the local database before a second run');
    const marker = psql(`select coalesce((select environment from app.platform_environment),'')`);
    if (marker === '') {
      psql(`select app.platform_set_environment('local','content-sermon-facebook-e2e')`);
      marked = true;
    } else if (marker !== 'local') throw new Error('local database is not marked local');
    startedAuthWork = true;
    log('S00-precondition', { phone_auth_enabled: true, local_environment: true });

    const { admin, media, member, pending } = people;
    for (const person of Object.values(people)) {
      if (!isFictionalFacebookPhone(person.phone)) throw new Error('fixture phone is not reserved');
      const pw = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true,
        body: { phone: person.phone, phone_confirm: true, password: pw } });
      person.user = created.json?.id;
      if (!person.user) throw new Error('synthetic Auth user creation failed');
      users.add(person.user);
      if (!person.noLink) person.member = psql(`select app.identity_seed_synthetic_link('${person.user}','${person.name}','content-sermon-facebook-e2e')`);
      person.token = (await http('POST', '/auth/v1/token?grant_type=password', { body: { phone: person.phone, password: pw } })).json?.access_token;
      if (!person.token) throw new Error('synthetic phone sign-in failed');
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}','${OPERATOR}')`);
    const revision = Number(psql(`select revision from app.identity_grant_sets where member_id='${media.member}'`));
    const grant = await envelope('identity_grant_command', admin.token, 'identity.grant_role', revision,
      { member_id: media.member, role: 'media' });
    check('S01-phone-auth-and-media-role', Object.values(people).every((person) => amrMethods(person.token).includes('password'))
      && grant.status === 200 && !grant.code, { media_grant: grant.code ?? grant.status });

    const refused = [];
    for (const [link, reason] of REFUSED_LINKS) {
      const answer = await content(media, 'content.create_sermon', null, sermonInput({ facebook_video_url: link }));
      refused.push(answer.code === 'validation_failed' && answer.field_errors?.facebook_video_url === reason);
    }
    const both = await content(media, 'content.create_sermon', null,
      sermonInput({ youtube_video_id: 'SYNTHETIC10', facebook_video_url: ACCEPTED_LINKS[0][0] }));
    check('S10-non-facebook-malformed-live-page-and-two-sources-refused',
      refused.every(Boolean) && both.field_errors?.facebook_video_url === 'one_source',
      { refused_cases: refused.length, refused_with_reason: refused.filter(Boolean).length, two_sources: both.field_errors?.facebook_video_url });

    const drafts = [];
    for (const [i, [link]] of ACCEPTED_LINKS.entries()) {
      const draft = await content(media, 'content.create_sermon', null,
        sermonInput({ title: `${PREFIX} ${i + 1}`, sermon_date: `2026-10-${String(25 - i).padStart(2, '0')}`, facebook_video_url: link }));
      if (!draft.data?.sermon_id) throw new Error('synthetic Facebook sermon draft failed');
      drafts.push({ id: draft.data.sermon_id, revision: draft.revision });
    }
    const stored = [];
    for (const item of drafts) stored.push((await staffItem(media, item.id))?.draft?.facebook_video_url);
    const draftCatalog = await catalog();
    check('S11-pasted-links-are-stored-normalised-and-drafts-stay-private',
      JSON.stringify(stored) === JSON.stringify(ACCEPTED_LINKS.map(([, normal]) => normal))
      && drafts.every((item) => !findSermon(draftCatalog, item.id)),
      { normalised: stored.filter((value, i) => value === ACCEPTED_LINKS[i][1]).length, public_drafts: drafts.filter((item) => findSermon(draftCatalog, item.id)).length });

    const noRights = await content(media, 'content.publish_sermon', drafts[0].revision, { sermon_id: drafts[0].id });
    const rightsFields = {
      label: 'SYNTHETIC Facebook video rights (6.10 E2E)', source_key: 'synthetic-sermon-6-10-e2e',
      holder: 'SYNTHETIC Church media team', basis: 'church_owned', clears_display: true, clears_offline: false,
      clears_audio: false, evidence: 'SYNTHETIC rights fixture only; no real recording rights are asserted.',
    };
    const rightsDraft = await content(media, 'content.create_rights_record', null, rightsFields);
    const rightsId = rightsDraft.data?.rights_id;
    const rightsVerified = await content(media, 'content.verify_rights_record', rightsDraft.revision, { rights_id: rightsId });
    if (!rightsId || rightsVerified.code) throw new Error('synthetic rights record failed');
    for (const [i, item] of drafts.entries()) {
      const saved = await content(media, 'content.save_sermon', item.revision, { sermon_id: item.id,
        ...sermonInput({ title: `${PREFIX} ${i + 1}`, sermon_date: `2026-10-${String(25 - i).padStart(2, '0')}`,
          facebook_video_url: ACCEPTED_LINKS[i][1], video_rights_id: rightsId }) });
      const published = await content(i % 2 ? admin : media, 'content.publish_sermon', saved.revision, { sermon_id: item.id });
      if (published.code) throw new Error('Facebook sermon publication failed');
      item.revision = published.revision;
    }
    const youtube = await content(media, 'content.create_sermon', null, sermonInput({ title: `${PREFIX} YouTube`,
      sermon_date: '2026-10-11', youtube_video_id: 'SYNTHETIC10', video_rights_id: rightsId }));
    const youtubePublished = await content(media, 'content.publish_sermon', youtube.revision, { sermon_id: youtube.data?.sermon_id });

    const anon = await catalog();
    const pendingRead = await catalog(pending);
    const memberRead = await catalog(member);
    const publicText = JSON.stringify(anon);
    const leaked = leaks(publicText, [media.name, media.member, media.user, rightsId, 'saved_by', 'video_rights_id', 'draft']);
    const listed = drafts.map((item) => findSermon(anon, item.id));
    const yt = findSermon(anon, youtube.data?.sermon_id);
    check('S12-facebook-sermons-need-rights-and-publish-for-every-public-caller',
      noRights.field_errors?.video_rights_id === 'required' && isPublicCatalog(anon)
      && publicText === JSON.stringify(pendingRead) && publicText === JSON.stringify(memberRead) && leaked.length === 0
      && listed.every((s, i) => s?.facebook_video_url === ACCEPTED_LINKS[i][1] && s?.youtube_video_id === null && s?.rights_revision === 1)
      && JSON.stringify(sortedKeys(listed[0])) === JSON.stringify(PUBLIC_SERMON_KEYS) && isPublicSermon(listed[0])
      && JSON.stringify(await detail(undefined, drafts[0].id)) === JSON.stringify(listed[0]),
      { publish_without_rights: noRights.field_errors?.video_rights_id, playable_facebook_rows: listed.filter((s) => s?.facebook_video_url).length,
        same_for_public_callers: publicText === JSON.stringify(pendingRead) && publicText === JSON.stringify(memberRead), leaked_fields: leaked.length });
    check('S13-youtube-stays-beside-facebook', !youtubePublished.code && yt?.youtube_video_id === 'SYNTHETIC10'
      && yt?.facebook_video_url === null,
      { youtube_published: !youtubePublished.code, youtube_id: Boolean(yt?.youtube_video_id), facebook_on_youtube_row: yt?.facebook_video_url });

    const replaced = await content(media, 'content.save_sermon', drafts[0].revision, { sermon_id: drafts[0].id,
      ...sermonInput({ title: `${PREFIX} 1`, youtube_video_id: 'SYNTHETIC11', video_rights_id: rightsId }) });
    const whileDrafted = await detail(undefined, drafts[0].id);
    check('S14-switching-source-is-a-draft-until-published', !replaced.code
      && whileDrafted?.facebook_video_url === ACCEPTED_LINKS[0][1] && whileDrafted?.youtube_video_id === null,
      { saved: !replaced.code, live_source: whileDrafted?.facebook_video_url ? 'facebook' : 'other' });

    const rightsWithdrawn = await content(admin, 'content.withdraw_rights_record', rightsVerified.revision, { rights_id: rightsId });
    const hidden = await detail(undefined, drafts[1].id);
    check('S20-withdrawn-clearance-hides-the-video-and-keeps-the-notes', rightsWithdrawn.data?.state === 'withdrawn'
      && hidden?.facebook_video_url === null && hidden?.rights_revision === null && hidden?.notes === NOTES,
      { video_omitted: hidden?.facebook_video_url === null, notes_retained: hidden?.notes === NOTES });

    const refusedCallers = [];
    for (const person of [member, pending]) {
      refusedCallers.push((await content(person, 'content.create_sermon', null,
        sermonInput({ facebook_video_url: ACCEPTED_LINKS[0][1] }))).code === 'forbidden');
    }
    const anonCommand = await content(undefined, 'content.create_sermon', null, sermonInput({ facebook_video_url: ACCEPTED_LINKS[0][1] }));
    const table = await http('GET', '/rest/v1/content_sermon_revisions?select=facebook_video_url', { token: media.token, profile: 'app' });
    check('S30-only-editors-save-facebook-links-and-no-table-access', refusedCallers.every(Boolean) && anonCommand.status === 401
      && table.status >= 400, { refusals: refusedCallers.filter(Boolean).length, anonymous_command: anonCommand.status, table_read: table.status });

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
