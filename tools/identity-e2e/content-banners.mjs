#!/usr/bin/env node
// Story 6.2 end-to-end on the LOCAL stack: rights records, the q5_content_rights gate, the asset
// path and Home banners, through real GoTrue phone sign-in (no SMS), the real Data API
// (PostgREST), the real Storage API and the content-assets Edge Function served by
// `supabase functions serve` (started here when it is not already running). It proves the
// ticket's verify at the API and Storage level:
//   * a Media member uploads a `SYNTHETIC Theme 2026` image and a campaign image through the Edge
//     Function; an oversized file (over the purpose's 5 MiB and over the 10 MiB body cap), a
//     disguised file (text named and declared as a PNG; a PNG declared as JPEG), a PNG header with
//     no image data and an undersized image are refused with nothing stored; HTML appended after a
//     real image is dropped before anything is stored;
//   * a plain member, a Pending account and a signed-out caller cannot upload, sync or preview;
//   * a theme cited with a third-party rights record whose source is missing from the Q5 fixture
//     cannot be published; with the SYNTHETIC church record both banners publish, and after the
//     sync a signed-out caller reads the carousel (theme first) and fetches both images;
//   * neither anonymous nor member callers can fetch a draft, an uncleared or a withdrawn file,
//     nor list either bucket; withdrawing the campaign and suspending the theme's rights take them
//     off Home at once and the sync removes their public objects;
//   * no client role reads or writes a new Content table directly.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards, the edge-runtime image, and a database with no usable Admin (`npx supabase db reset`
// first). LOCAL only (exact origin), SYNTHETIC fictional numbers +44 7700 900501-900509. Evidence is
// redacted JSONL: statuses, codes, counts and booleans; never tokens, passwords, numbers or paths.
// Everything it created (rows and Storage objects) is removed.
//
// Usage: node tools/identity-e2e/content-banners.mjs [--evidence <file.jsonl>]
import { spawn, execFileSync } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { deflateSync } from 'node:zlib';

import { amrMethods, localHttp, localKey, password, psql, runMain, sleep, startRun } from './harness.mjs';
import { churchDayAt } from './content-events.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 6.2 E2E';
const TAG = '(6.2 E2E)';
export const THEME = `SYNTHETIC Theme 2026 ${TAG}`;
export const CAMPAIGN = `SYNTHETIC Harvest campaign ${TAG}`;
const UNCLEARED = `SYNTHETIC Licensed photo banner ${TAG}`;
const FN = '/functions/v1/content-assets';

/** The public banner projection's keys, exactly. */
export const PUBLIC_KEYS = ['alt_text', 'banner_id', 'banner_kind', 'event_id', 'image', 'publication_revision',
  'published_at', 'rights_revision', 'subtitle', 'theme_year', 'title'];

/** The reserved fictional numbers this run uses (+44 7700 900501-900509). */
export function isFictionalBannerPhone(phone) {
  return /^\+44770090050[1-9]$/.test(phone);
}

const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});

/** CRC-32 (PNG chunks). */
export function crc32(buf) {
  let c = 0xffffffff;
  for (const b of buf) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const head = Buffer.alloc(8);
  head.writeUInt32BE(data.length, 0);
  head.write(type, 4, 'ascii');
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), data])), 0);
  return Buffer.concat([head, data, crc]);
}

/** A valid solid-colour RGB PNG; `padTo` appends zero bytes after IEND up to that size. */
export function solidPng(width, height, [r, g, b], padTo = 0) {
  const row = Buffer.alloc(1 + width * 3);
  for (let x = 0; x < width; x++) row.set([r, g, b], 1 + x * 3);
  const raw = Buffer.alloc(row.length * height);
  for (let y = 0; y < height; y++) row.copy(raw, y * row.length);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr.set([8, 2, 0, 0, 0], 8);
  const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
  return padTo > png.length ? Buffer.concat([png, Buffer.alloc(padTo - png.length)]) : png;
}

/** A valid RGB PNG of random pixels (incompressible: about 3 bytes per pixel). */
export function noisePng(width, height) {
  const raw = randomBytes((1 + width * 3) * height);
  for (let y = 0; y < height; y++) raw[y * (1 + width * 3)] = 0;
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr.set([8, 2, 0, 0, 0], 8);
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw, { level: 1 })), chunk('IEND', Buffer.alloc(0))]);
}

export const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');

/** The banner with this id in a public read, or undefined. */
export function findBanner(read, id) {
  return (read?.banners ?? []).find((b) => b.banner_id === id);
}

async function main() {
  const { log, check, finish } = startRun();
  const keys = localKey();
  const { origin, key, secret, service } = keys;
  const http = localHttp(keys);
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const content = (token, cmd, expected, payload) =>
    rpc('content_command', token, { version: 1, command: cmd, request_id: randomUUID(), expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const publicRead = async (token) => (await rpc('content_public_banners', token)).json;
  // The Edge Function, as staff web calls it (publishable key, the caller's bearer token).
  const fn = async (method, query, { token, body, type } = {}) => {
    const headers = { apikey: key };
    if (token) headers.Authorization = `Bearer ${token}`;
    if (type) headers['Content-Type'] = type;
    const res = await fetch(`${origin}${FN}?${query}`, { method, headers, body });
    const buf = Buffer.from(await res.arrayBuffer());
    let json = null;
    try { json = JSON.parse(buf.toString('utf8')); } catch { /* bytes */ }
    return { status: res.status, json, bytes: buf, type: res.headers.get('content-type'), cache: res.headers.get('cache-control') };
  };
  const upload = (token, itemId, bytes, type) => fn('POST', `action=upload&item_id=${itemId}&purpose=banner_image`, { token, body: bytes, type });
  const sync = (token) => fn('POST', 'action=sync', { token });
  // Storage, as anyone (publishable key, optional token) or as the service (cleanup only).
  const storage = async (method, path, { token, body, asService } = {}) => {
    const headers = { apikey: asService ? secret : key };
    if (asService) headers.Authorization = `Bearer ${service}`;
    else if (token) headers.Authorization = `Bearer ${token}`;
    if (body) headers['Content-Type'] = 'application/json';
    const res = await fetch(`${origin}/storage/v1/${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
    const buf = Buffer.from(await res.arrayBuffer());
    let json = null;
    try { json = JSON.parse(buf.toString('utf8')); } catch { /* bytes */ }
    return { status: res.status, json, bytes: buf };
  };
  const objectCount = (bucket) => Number(psql(`select count(*) from storage.objects where bucket_id = '${bucket}'`));

  const people = {
    admin: { phone: '+447700900501', name: `${NAME_PREFIX} Admin` },
    media: { phone: '+447700900502', name: `${NAME_PREFIX} Media M` },
    member: { phone: '+447700900503', name: `${NAME_PREFIX} Member` },
    pending: { phone: '+447700900504', name: `${NAME_PREFIX} Pending`, noLink: true },
  };
  for (const p of Object.values(people)) if (!isFictionalBannerPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  const users = new Set();
  const digits = Object.values(people).map((p) => `'${p.phone.slice(1)}'`).join(',');
  const cleanupObjects = async () => {
    const names = (bucket) => psql(`select coalesce(string_agg(o.name, ',' order by o.name), '') from storage.objects o
      where o.bucket_id = '${bucket}' and (o.name in (select a.draft_path from app.content_assets a
        where a.item_id in (select r.item_id from app.content_banner_revisions r where r.title like 'SYNTHETIC % ${TAG}'))
        or o.name like any (select 'banner/' || r.item_id::text || '/%' from app.content_banner_revisions r
                             where r.title like 'SYNTHETIC % ${TAG}'))`).split(',').filter(Boolean);
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
    create temp table gone_items as
      select r.item_id from app.content_banner_revisions r where r.title like 'SYNTHETIC % ${TAG}'
      union select r.item_id from app.content_rights_revisions r where r.label like 'SYNTHETIC % ${TAG}'
      union select r.item_id from app.content_event_revisions r where r.title like 'SYNTHETIC % ${TAG}';
    alter table app.content_revision_files disable trigger content_revision_files_draft_only;
    delete from app.content_revision_files f where f.item_id in (select item_id from gone_items);
    alter table app.content_revision_files enable trigger content_revision_files_draft_only;
    delete from app.content_assets a where a.item_id in (select item_id from gone_items);
    delete from app.content_audit a where a.item_id in (select item_id from gone_items);
    delete from app.content_banner_revisions r where r.item_id in (select item_id from gone_items);
    delete from app.content_rights_revisions r where r.item_id in (select item_id from gone_items);
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
    psql(`select app.platform_set_environment('local', 'content-banners-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }

  // The Edge Function: use a running `functions serve`, else start one for this run.
  const probe = () => fetch(`${origin}${FN}?action=sync`, { method: 'POST', headers: { apikey: key } })
    .then((r) => r.status).catch(() => 0);
  let serve = null;
  if (await probe() !== 401) {
    // On Windows npx is a .cmd script, which Node starts only through a shell (one command string).
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
    const { admin, media, member, pending } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      if (!p.noLink) p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'content-banners-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    const grantRev = Number(psql(`select revision from app.identity_grant_sets where member_id = '${media.member}'`));
    const grant = await rpc('identity_grant_command', admin.token,
      { version: 1, command: 'identity.grant_role', request_id: randomUUID(), expected_revision: grantRev,
        payload: { member_id: media.member, role: 'media' } });
    check('C01-signed-in-by-phone-and-media-granted', Object.values(people).every((p) => amrMethods(p.token).includes('password'))
      && grant.status === 200 && grant.json?.data?.roles?.includes('media'), { grant: grant.status });

    const buckets = await storage('GET', 'bucket', { asService: true });
    const byId = Object.fromEntries((buckets.json ?? []).map((b) => [b.id, b]));
    const policies = Number(psql(`select count(*) from pg_policies where schemaname = 'storage'`));
    check('C02-a-private-draft-bucket-and-a-public-bucket', byId['content-drafts']?.public === false
      && byId['content-public']?.public === true && policies === 0,
      { drafts_public: byId['content-drafts']?.public, public_public: byId['content-public']?.public, storage_policies: policies });

    // ------------------------------------------------------------------ rights records
    const rightsBody = (label, source, basis) => ({ label, source_key: source, holder: 'SYNTHETIC Church media team',
      basis, clears_display: true, clears_offline: false, clears_audio: false,
      evidence: 'SYNTHETIC: made for this test run; no real rights are claimed.' });
    const ownDraft = await content(media.token, 'content.create_rights_record', null,
      rightsBody(`SYNTHETIC Church artwork ${TAG}`, 'synthetic', 'church_owned'));
    ids.own = ownDraft.data?.rights_id;
    const own = await content(media.token, 'content.verify_rights_record', ownDraft.revision, { rights_id: ids.own });
    const thirdDraft = await content(media.token, 'content.create_rights_record', null,
      rightsBody(`SYNTHETIC Licensed photo ${TAG}`, 'acme-press', 'licence'));
    ids.third = thirdDraft.data?.rights_id;
    const third = await content(media.token, 'content.verify_rights_record', thirdDraft.revision, { rights_id: ids.third });
    const byMemberRights = await content(member.token, 'content.create_rights_record', null,
      rightsBody(`SYNTHETIC Member record ${TAG}`, 'synthetic', 'church_owned'));
    check('C10-rights-recorded-and-verified-by-media', own.status === 200 && own.data?.state === 'published'
      && third.status === 200 && byMemberRights.code === 'forbidden',
      { own: own.data?.state, third_party: third.data?.state, plain_member: byMemberRights.code });

    // ------------------------------------------------------------------ banners and an event to link
    const now = Date.now();
    const eventDraft = await content(media.token, 'content.create_event', null, {
      title: `SYNTHETIC Harvest Thanksgiving ${TAG}`, description: 'SYNTHETIC harvest service.',
      starts_at: churchDayAt(now, 5, '09:00'), ends_at: churchDayAt(now, 5, '12:00'), location: 'SYNTHETIC Church grounds' });
    ids.event = eventDraft.data?.event_id;
    const eventLive = await content(media.token, 'content.publish_event', eventDraft.revision, { event_id: ids.event });
    const themeFields = { banner_kind: 'theme', theme_year: 2026, title: THEME, subtitle: 'Deuteronomy 7:9',
      alt_text: 'SYNTHETIC navy artwork with the words of the 2026 theme', event_id: null };
    const campaignFields = { banner_kind: 'campaign', theme_year: null, title: CAMPAIGN, subtitle: 'SYNTHETIC Saturday, church grounds',
      alt_text: 'SYNTHETIC orange poster for the harvest thanksgiving', event_id: ids.event };
    const themeDraft = await content(media.token, 'content.create_banner', null, themeFields);
    const campaignDraft = await content(media.token, 'content.create_banner', null, campaignFields);
    const unclearedDraft = await content(media.token, 'content.create_banner', null,
      { ...campaignFields, title: UNCLEARED, event_id: null });
    ids.theme = themeDraft.data?.banner_id;
    ids.campaign = campaignDraft.data?.banner_id;
    ids.uncleared = unclearedDraft.data?.banner_id;
    check('C11-banner-drafts', eventLive.status === 200 && [themeDraft, campaignDraft, unclearedDraft].every((d) => d.status === 200
      && d.data?.state === 'draft'), { theme: themeDraft.data?.state, campaign: campaignDraft.data?.state });

    // ------------------------------------------------------------------ uploads and refusals
    const themePng = solidPng(1920, 1080, [20, 36, 107]);
    const campaignPng = solidPng(1600, 900, [232, 120, 40]);
    // A polyglot: the real campaign image with HTML appended. Only the image is kept.
    const campaignPolyglot = Buffer.concat([campaignPng, Buffer.from('<html><script>alert(1)</script></html>')]);
    const otherPng = solidPng(1280, 720, [90, 90, 90]);
    const draftsBefore = objectCount('content-drafts');
    const assetsBefore = Number(psql(`select count(*) from app.content_assets`));
    const themeUp = await upload(media.token, ids.theme, themePng, 'image/png');
    const campaignUp = await upload(media.token, ids.campaign, campaignPolyglot, 'image/png');
    const otherUp = await upload(media.token, ids.uncleared, otherPng, 'image/png');
    check('C12-media-uploads-two-images', themeUp.status === 200 && themeUp.json?.outcome === 'uploaded'
      && themeUp.json?.width === 1920 && themeUp.json?.height === 1080 && themeUp.json?.media_type === 'image/png'
      && campaignUp.status === 200 && campaignUp.json?.byte_size === campaignPng.length
      && otherUp.status === 200 && objectCount('content-drafts') === draftsBefore + 3,
      { theme: themeUp.status, campaign: campaignUp.status, measured: `${themeUp.json?.width}x${themeUp.json?.height}`,
        draft_objects_added: objectCount('content-drafts') - draftsBefore });

    const counts = () => `${objectCount('content-drafts')}|${Number(psql(`select count(*) from app.content_assets where state = 'ready'`))}`;
    const before = counts();
    const overPurpose = await upload(media.token, ids.theme, noisePng(1920, 1080), 'image/png');
    const overCap = await upload(media.token, ids.theme, solidPng(1920, 1080, [1, 2, 3], 11 * 1024 * 1024), 'image/png');
    const disguised = await upload(media.token, ids.theme,
      Buffer.from('<html><body><script>alert(1)</script> SYNTHETIC not an image</body></html>'), 'image/png');
    const mismatched = await upload(media.token, ids.theme, themePng, 'image/jpeg');
    const small = await upload(media.token, ids.theme, solidPng(800, 450, [1, 2, 3]), 'image/png');
    const headerOnly = await upload(media.token, ids.theme, themePng.subarray(0, 33), 'image/png');
    check('C13-oversized-and-disguised-files-refused-nothing-stored',
      overPurpose.status === 413 && overPurpose.json?.field_errors?.byte_size === 'too_large'
      && overCap.status === 413 && overCap.json?.field_errors?.file === 'too_large'
      && disguised.status === 415 && disguised.json?.field_errors?.file === 'unsupported_type'
      && mismatched.status === 415 && mismatched.json?.field_errors?.file === 'type_mismatch'
      && small.status === 422 && small.json?.field_errors?.width === 'too_small'
      && headerOnly.status === 415 && headerOnly.json?.field_errors?.file === 'invalid_image'
      && counts() === before,
      { over_purpose: `${overPurpose.status}:${overPurpose.json?.field_errors?.byte_size}`,
        over_cap: `${overCap.status}:${overCap.json?.field_errors?.file}`,
        disguised: `${disguised.status}:${disguised.json?.field_errors?.file}`,
        mismatched: `${mismatched.status}:${mismatched.json?.field_errors?.file}`,
        undersized: `${small.status}:${small.json?.field_errors?.width}`,
        header_only: `${headerOnly.status}:${headerOnly.json?.field_errors?.file}`, nothing_stored: counts() === before });

    const memberUp = await upload(member.token, ids.theme, themePng, 'image/png');
    const pendingUp = await upload(pending.token, ids.theme, themePng, 'image/png');
    const anonUp = await upload(undefined, ids.theme, themePng, 'image/png');
    check('C14-only-editors-upload', memberUp.status === 403 && pendingUp.status === 403 && anonUp.status === 401
      && counts() === before, { member: memberUp.status, pending: pendingUp.status, anon: anonUp.status });

    // ------------------------------------------------------------------ the Q5 gate: an unlisted source cannot publish
    const save = async (id, fields, assetId, rightsId, revision) =>
      content(media.token, 'content.save_banner', revision, { banner_id: id, ...fields, image_asset_id: assetId, image_rights_id: rightsId });
    const themeThird = await save(ids.theme, themeFields, themeUp.json?.asset_id, ids.third, themeDraft.revision);
    const themeRefused = await content(media.token, 'content.publish_banner', themeThird.revision, { banner_id: ids.theme });
    const unclearedSaved = await save(ids.uncleared, { ...campaignFields, title: UNCLEARED, event_id: null }, otherUp.json?.asset_id,
      ids.third, unclearedDraft.revision);
    const unclearedRefused = await content(media.token, 'content.publish_banner', unclearedSaved.revision, { banner_id: ids.uncleared });
    check('C20-third-party-source-missing-from-q5-cannot-be-published', themeThird.status === 200
      && themeRefused.code === 'validation_failed' && themeRefused.field_errors?.image_rights_id === 'source_not_cleared'
      && unclearedRefused.field_errors?.image_rights_id === 'source_not_cleared',
      { theme: `${themeRefused.code}:${themeRefused.field_errors?.image_rights_id}`,
        other: unclearedRefused.field_errors?.image_rights_id });

    // ------------------------------------------------------------------ publish both; sync; signed-out carousel
    const themeOwn = await save(ids.theme, themeFields, themeUp.json?.asset_id, ids.own, themeThird.revision);
    const themeLive = await content(media.token, 'content.publish_banner', themeOwn.revision, { banner_id: ids.theme });
    const campaignSaved = await save(ids.campaign, campaignFields, campaignUp.json?.asset_id, ids.own, campaignDraft.revision);
    const campaignLive = await content(media.token, 'content.publish_banner', campaignSaved.revision, { banner_id: ids.campaign });
    const beforeSync = await publicRead(undefined);
    const memberSync = await sync(member.token);
    const anonSync = await sync(undefined);
    const synced = await sync(media.token);
    const carousel = await publicRead(undefined);
    const theme = findBanner(carousel, ids.theme);
    const campaign = findBanner(carousel, ids.campaign);
    const order = (carousel?.banners ?? []).filter((b) => [ids.theme, ids.campaign].includes(b.banner_id)).map((b) => b.banner_kind);
    const fetchPublic = (path) => storage('GET', `object/public/content-public/${path}`);
    const themeFile = theme ? await fetchPublic(theme.image.path) : null;
    const campaignFile = campaign ? await fetchPublic(campaign.image.path) : null;
    check('C21-both-published-and-the-carousel-reads-signed-out', themeLive.status === 200 && campaignLive.status === 200
      && !findBanner(beforeSync, ids.theme) && memberSync.status === 403 && anonSync.status === 401
      && synced.status === 200 && synced.json?.placed >= 2 && synced.json?.waiting === 0
      && JSON.stringify(order) === JSON.stringify(['theme', 'campaign'])
      && JSON.stringify(Object.keys(theme ?? {}).sort()) === JSON.stringify(PUBLIC_KEYS)
      && theme?.title === THEME && theme?.theme_year === 2026 && theme?.alt_text === themeFields.alt_text
      && campaign?.event_id === ids.event && theme?.image?.path === `banner/${ids.theme}/r${theme?.publication_revision}/image.png`
      && themeFile?.status === 200 && sha256(themeFile.bytes) === sha256(themePng)
      && campaignFile?.status === 200 && sha256(campaignFile.bytes) === sha256(campaignPng)
      && !campaignFile.bytes.includes(Buffer.from('<script>')),
      { before_sync_listed: Boolean(findBanner(beforeSync, ids.theme)), member_sync: memberSync.status, anon_sync: anonSync.status,
        sync: synced.json?.outcome, placed: synced.json?.placed, order, theme_file: themeFile?.status, campaign_file: campaignFile?.status,
        bytes_match: themeFile ? sha256(themeFile.bytes) === sha256(themePng) : false,
        appended_html_dropped: campaignFile ? !campaignFile.bytes.includes(Buffer.from('<script>')) : false });
    const texts = [await publicRead(undefined), await publicRead(pending.token), await publicRead(member.token)].map((x) => JSON.stringify(x));
    const leaks = [media.member, media.user, media.name, 'saved_by', 'published_by', 'draft', 'asset_id', ids.own, ids.third,
      'content-drafts'].filter((v) => texts.some((t) => t.includes(v)));
    check('C22-anon-pending-member-read-the-projection-only', leaks.length === 0 && texts[0] === texts[1] && texts[1] === texts[2],
      { leaked: leaks.length, same: texts[0] === texts[1] && texts[1] === texts[2] });

    // ------------------------------------------------------------------ draft and uncleared files are never fetchable
    const draftPath = (assetId) => psql(`select draft_path from app.content_assets where asset_id = '${assetId}'`);
    const unclearedDraftPath = draftPath(otherUp.json?.asset_id);
    const themeDraftPath = draftPath(themeUp.json?.asset_id);
    const attempts = [];
    for (const path of [unclearedDraftPath, themeDraftPath]) {
      for (const [who, token] of [['anon', undefined], ['member', member.token], ['media', media.token]]) {
        for (const route of [`object/public/content-drafts/${path}`, `object/authenticated/content-drafts/${path}`,
          `object/content-drafts/${path}`]) {
          const r = await storage('GET', route, { token });
          attempts.push({ who, ok: r.status >= 400 && !r.bytes.equals(themePng) && !r.bytes.equals(otherPng) });
        }
      }
    }
    const unclearedPublic = await fetchPublic(`banner/${ids.uncleared}/r1/image.png`);
    const lists = [];
    for (const bucket of ['content-drafts', 'content-public']) {
      for (const [who, token] of [['anon', undefined], ['member', member.token], ['media', media.token]]) {
        const r = await storage('POST', `object/list/${bucket}`, { token, body: { prefix: '', limit: 100 } });
        lists.push({ who, bucket, ok: !(Array.isArray(r.json) && r.json.length > 0) });
      }
    }
    const memberPreview = await fn('GET', `action=preview&asset_id=${themeUp.json?.asset_id}`, { token: member.token });
    const anonPreview = await fn('GET', `action=preview&asset_id=${themeUp.json?.asset_id}`);
    const mediaPreview = await fn('GET', `action=preview&asset_id=${otherUp.json?.asset_id}`, { token: media.token });
    check('C30-draft-and-uncleared-files-cannot-be-fetched-or-listed', attempts.every((a) => a.ok)
      && unclearedPublic.status >= 400 && lists.every((l) => l.ok)
      && memberPreview.status === 403 && anonPreview.status === 401
      && mediaPreview.status === 200 && mediaPreview.bytes.equals(otherPng) && /no-store/.test(mediaPreview.cache ?? ''),
      { draft_fetch_refused: `${attempts.filter((a) => a.ok).length}/${attempts.length}`, uncleared_public: unclearedPublic.status,
        listing_refused: `${lists.filter((l) => l.ok).length}/${lists.length}`, member_preview: memberPreview.status,
        anon_preview: anonPreview.status, editor_preview: mediaPreview.status });

    // ------------------------------------------------------------------ a campaign follows its event
    const campaignPath = campaign?.image?.path;
    const eventOff = await content(media.token, 'content.withdraw_event', eventLive.revision, { event_id: ids.event });
    const afterEventOff = await publicRead(undefined);
    const syncedEventOff = await sync(media.token);
    const eventOffFile = await fetchPublic(campaignPath);
    const eventBack = await content(media.token, 'content.publish_event', eventOff.revision, { event_id: ids.event });
    const syncedEventBack = await sync(media.token);
    const eventBackFile = await fetchPublic(campaignPath);
    check('C33-a-campaign-file-leaves-the-public-bucket-with-its-event', eventOff.status === 200
      && !findBanner(afterEventOff, ids.campaign) && findBanner(afterEventOff, ids.theme)
      && syncedEventOff.json?.removed >= 1 && eventOffFile.status >= 400
      && eventBack.status === 200 && syncedEventBack.json?.placed >= 1 && eventBackFile.status === 200,
      { event_withdrawn: eventOff.data?.state, campaign_listed: Boolean(findBanner(afterEventOff, ids.campaign)),
        removed: syncedEventOff.json?.removed, file_while_event_off: eventOffFile.status,
        file_after_event_back: eventBackFile.status });

    // ------------------------------------------------------------------ withdrawal and suspended rights
    const withdrawn = await content(media.token, 'content.withdraw_banner', campaignLive.revision, { banner_id: ids.campaign });
    const afterWithdraw = await publicRead(undefined);
    const syncedWithdraw = await sync(media.token);
    const withdrawnFile = await fetchPublic(campaignPath);
    const withdrawnFileAsMember = await storage('GET', `object/authenticated/content-public/${campaignPath}`, { token: member.token });
    check('C31-a-withdrawn-file-cannot-be-fetched', withdrawn.status === 200 && !findBanner(afterWithdraw, ids.campaign)
      && syncedWithdraw.json?.removed >= 1 && syncedWithdraw.json?.removals_pending === 0
      && withdrawnFile.status >= 400 && withdrawnFileAsMember.status >= 400,
      { withdrawn: withdrawn.data?.state, listed: Boolean(findBanner(afterWithdraw, ids.campaign)), removed: syncedWithdraw.json?.removed,
        anon_fetch: withdrawnFile.status, member_fetch: withdrawnFileAsMember.status });

    const ownRev = Number(psql(`select revision from app.content_items where item_id = '${ids.own}'`));
    const suspended = await content(media.token, 'content.withdraw_rights_record', ownRev, { rights_id: ids.own });
    const afterSuspend = await publicRead(undefined);
    const themePath = theme?.image?.path;
    const syncedSuspend = await sync(media.token);
    const suspendedFile = await fetchPublic(themePath);
    const reverified = await content(media.token, 'content.verify_rights_record', suspended.revision, { rights_id: ids.own });
    const syncedBack = await sync(media.token);
    const back = findBanner(await publicRead(undefined), ids.theme);
    check('C32-suspended-rights-take-the-theme-off-until-verified-again', suspended.status === 200
      && !findBanner(afterSuspend, ids.theme) && syncedSuspend.json?.removed >= 1 && suspendedFile.status >= 400
      && reverified.status === 200 && syncedBack.json?.placed >= 1 && back?.title === THEME,
      { suspended: suspended.data?.state, listed_after_suspend: Boolean(findBanner(afterSuspend, ids.theme)),
        file_after_sync: suspendedFile.status, back: Boolean(back) });

    // ------------------------------------------------------------------ no client role touches a new Content table
    const tables = [];
    for (const t of ['content_rights_revisions', 'content_banner_revisions', 'content_assets', 'content_revision_files',
      'content_asset_purposes', 'content_media_types']) {
      for (const [who, token] of [['anon', undefined], ['member', member.token], ['media', media.token]]) {
        for (const profile of ['app', 'api']) {
          const read = await http('GET', `/rest/v1/${t}?select=*`, { token, profile });
          const write = await http('POST', `/rest/v1/${t}`, { token, profile, body: { item_id: ids.theme } });
          tables.push({ t, who, refused: read.status >= 400 && write.status >= 400 && !Array.isArray(read.json) });
        }
      }
    }
    const memberStaff = await rpc('content_staff_banners', member.token);
    const anonStaff = await rpc('content_staff_banners', undefined);
    check('C40-no-client-role-reads-or-writes-a-content-table', tables.every((x) => x.refused)
      && memberStaff.status === 403 && anonStaff.status === 401,
      { attempts: tables.length, refused: tables.filter((x) => x.refused).length, member_staff: memberStaff.status, anon_staff: anonStaff.status });
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
      try { execFileSync('docker', ['rm', '-f', 'supabase_edge_runtime_church-app'], { stdio: 'ignore' }); } catch { /* not running */ }
    }
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'content-banners-e2e';
            delete from app.platform_environment_history where set_by = 'content-banners-e2e';`);
    }
    log('C99-cleanup', { users_left: Number(left), objects_removed: objectsRemoved, unmarked: marked, stopped_serve: Boolean(serve),
      items_left: Number(psql(`select count(*) from app.content_banner_revisions where title like 'SYNTHETIC % ${TAG}'`)) });
  }
  finish();
}

runMain(import.meta.url, main);
