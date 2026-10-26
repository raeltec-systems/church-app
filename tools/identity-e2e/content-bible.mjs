// Local-only Story 6.6 E2E for rights-cleared Bible translation imports.
// KJV and WEB are labels for SYNTHETIC placeholders; no translation text is shipped.
// Published revisions are immutable, so run against a fresh local database (`npx supabase db reset`).
// The run removes its synthetic Auth identities and anonymizes attribution; immutable content fixtures
// remain in that disposable local database until it is reset.
// Usage: node tools/identity-e2e/content-bible.mjs [--evidence <file.jsonl>]
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

import { localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';

export const TRANSLATION_CODES = ['KJV', 'WEB'];
export const SYNTHETIC_PHONES = ['+447700900881', '+447700900882', '+447700900883'];
export const PUBLIC_CHAPTER_KEYS = [
  'book_id', 'chapter', 'offline_allowed', 'omitted_verses', 'publication_revision', 'published_at',
  'translation_code', 'translation_id', 'translation_name', 'verse_count', 'verses',
];
export const CANONICAL_BOOKS = [
  'GEN', 'EXO', 'LEV', 'NUM', 'DEU', 'JOS', 'JDG', 'RUT', '1SA', '2SA', '1KI', '2KI',
  '1CH', '2CH', 'EZR', 'NEH', 'EST', 'JOB', 'PSA', 'PRO', 'ECC', 'SNG', 'ISA', 'JER',
  'LAM', 'EZK', 'DAN', 'HOS', 'JOL', 'AMO', 'OBA', 'JON', 'MIC', 'NAM', 'HAB', 'ZEP',
  'HAG', 'ZEC', 'MAL', 'MAT', 'MRK', 'LUK', 'JHN', 'ACT', 'ROM', '1CO', '2CO', 'GAL',
  'EPH', 'PHP', 'COL', '1TH', '2TH', '1TI', '2TI', 'TIT', 'PHM', 'HEB', 'JAS', '1PE',
  '2PE', '1JN', '2JN', '3JN', 'JUD', 'REV',
];
const localPhoneAuthScript = fileURLToPath(new URL('../auth-harness/local-phone-auth.mjs', import.meta.url));

/** A fully synthetic import row. Never use licensed translation text here. */
export function syntheticVerseRows(code, bookId, chapter, verseCount) {
  if (!TRANSLATION_CODES.includes(code) || !CANONICAL_BOOKS.includes(bookId)
      || !Number.isInteger(chapter) || chapter < 1 || !Number.isInteger(verseCount)
      || verseCount < 1 || verseCount > 200) {
    throw new TypeError('invalid synthetic Bible fixture dimensions');
  }
  return Array.from({ length: verseCount }, (_, index) => ({
    book_id: bookId,
    chapter,
    verse: index + 1,
    text: `SYNTHETIC ${code} ${bookId} ${chapter} verse ${index + 1} (6.6 E2E)`,
  }));
}

/** Sort and step across a translation's available chapters in canonical order. */
export function nextAvailableChapter(refs, current, direction = 1) {
  const ordered = [...refs].sort((a, b) => {
    const bookDelta = CANONICAL_BOOKS.indexOf(a.book_id) - CANONICAL_BOOKS.indexOf(b.book_id);
    return bookDelta || a.chapter - b.chapter;
  });
  const index = ordered.findIndex((ref) => ref.book_id === current.book_id && ref.chapter === current.chapter);
  const next = index + direction;
  return index >= 0 && next >= 0 && next < ordered.length ? ordered[next] : null;
}

export function sortedKeys(value) {
  return Object.keys(value ?? {}).sort();
}

export function isFictionalBiblePhone(phone) {
  return SYNTHETIC_PHONES.includes(phone);
}

async function main() {
  const { log, check, finish } = startRun();
  const keys = localKey();
  const http = localHttp(keys);
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const envelope = (fn, token, command, expected, payload) => rpc(fn, token, {
    version: 1, command, request_id: randomUUID(), expected_revision: expected, payload,
  }).then((response) => ({ status: response.status, ...response.json }));
  const content = (token, command, expected, payload) => envelope('content_command', token, command, expected, payload);
  const publicCatalog = async () => (await rpc('content_public_bible_translations', undefined)).json;
  const publicChapter = async (translationId, bookId, chapter) => (await rpc('content_public_bible_chapter', undefined,
    { translation_id: translationId, book_id: bookId, chapter })).json?.chapter ?? null;

  const prefix = 'SYNTHETIC Bible 6.6 E2E';
  const people = {
    admin: { phone: SYNTHETIC_PHONES[0], name: `${prefix} Admin` },
    media: { phone: SYNTHETIC_PHONES[1], name: `${prefix} Media` },
    member: { phone: SYNTHETIC_PHONES[2], name: `${prefix} Member` },
  };
  const users = new Set();
  const phones = Object.values(people).map((person) => `'${person.phone.slice(1)}'`).join(',');
  const cleanup = () => {
    const ids = [...users].filter(Boolean).map((id) => `'${id}'`);
    const byId = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    return psql(`
      create temp table gone_users as select u.id from auth.users u where ${byId}u.phone in (${phones});
      create temp table gone_members as
        select distinct m.member_id from app.identity_members m
        join app.identity_account_links l on l.member_id=m.member_id
        join gone_users u on u.id=l.auth_user_id;
      select app.content_erase_member(jsonb_build_object('member_id',l.member_id,'account_id',l.auth_user_id,
        'deletion_id',gen_random_uuid(),'phase','erase'))
        from app.identity_account_links l join gone_users u on u.id=l.auth_user_id;
      delete from app.identity_access_audit a where a.target_member_id in (select member_id from gone_members)
        or a.actor_member_id in (select member_id from gone_members);
      delete from app.identity_grants g where g.member_id in (select member_id from gone_members);
      delete from app.identity_grant_sets s where s.member_id in (select member_id from gone_members);
      delete from app.identity_holds h where h.member_id in (select member_id from gone_members);
      delete from app.identity_binding_history h using app.identity_account_links l
        where h.link_id=l.link_id and (l.member_id in (select member_id from gone_members)
          or l.auth_user_id in (select id from gone_users));
      delete from app.identity_credential_events e using app.identity_account_links l
        where e.link_id=l.link_id and (l.member_id in (select member_id from gone_members)
          or l.auth_user_id in (select id from gone_users));
      delete from app.identity_account_links l where l.member_id in (select member_id from gone_members)
        or l.auth_user_id in (select id from gone_users);
      delete from app.identity_members m where m.member_id in (select member_id from gone_members);
      delete from app.cmd_receipts r where r.actor_id in (select id from gone_users);
      delete from auth.users u where u.id in (select id from gone_users);
      select count(*) from auth.users u where ${byId}u.phone in (${phones});
    `);
  };

  let marked = false;
  let cleaned = false;
  let phoneAuthRestored = false;
  const restorePhoneAuth = () => {
    if (phoneAuthRestored) return;
    phoneAuthRestored = true;
    try {
      execFileSync(process.execPath, [localPhoneAuthScript, 'off'], { stdio: 'inherit' });
    } catch (error) {
      console.error(`could not restore local phone auth: ${error.message}`);
      process.exitCode = 1;
    }
  };
  const cleanupLocalState = () => {
    if (cleaned) return;
    cleaned = true;
    const left = Number(cleanup().split(/\r?\n/).at(-1).trim());
    if (!Number.isInteger(left) || left !== 0) throw new Error('synthetic Auth cleanup did not finish');
    if (marked) {
      psql(`delete from app.platform_environment where set_by='content-bible-e2e';
            delete from app.platform_environment_history where set_by='content-bible-e2e';`);
      marked = false;
    }
    log('B99-cleanup', { synthetic_accounts_left: left, immutable_fixtures_retained: true,
      instruction: 'reset the local Supabase database before a second run' });
  };
  const onSignal = (exitCode) => {
    try {
      cleanupLocalState();
    } catch (error) {
      console.error(`local fixture cleanup failed: ${error.message}`);
    } finally {
      restorePhoneAuth();
      process.exit(exitCode);
    }
  };
  const onInterrupt = () => onSignal(130);
  const onTerminate = () => onSignal(143);
  process.once('SIGINT', onInterrupt);
  process.once('SIGTERM', onTerminate);
  try {
    const settings = await http('GET', '/auth/v1/settings');
    if (settings.json?.external?.phone !== true) {
      throw new Error('the local phone provider is off: run `node tools/auth-harness/local-phone-auth.mjs on` first');
    }
    const existing = Number(psql(`select count(*) from app.content_bible_translation_keys where translation_code in ('KJV','WEB')`));
    if (existing !== 0) throw new Error('KJV or WEB fixture already exists; reset the local stack before this one-shot E2E');
    const marker = psql(`select coalesce((select environment from app.platform_environment), '')`);
    if (marker === '') {
      psql(`select app.platform_set_environment('local', 'content-bible-e2e')`);
      marked = true;
    } else if (marker !== 'local') {
      throw new Error(`local database is marked ${marker}`);
    }
    log('B00-precondition', { phone_auth_enabled: true, existing_fixtures: existing });

    const { admin, media, member } = people;
    for (const person of Object.values(people)) {
      person.password = password();
      const created = await http('POST', '/auth/v1/admin/users', {
        admin: true,
        body: { phone: person.phone, phone_confirm: true, password: person.password },
      });
      person.user = created.json?.id;
      users.add(person.user);
      if (!person.user) throw new Error('local Auth did not create a synthetic user');
      person.member = psql(`select app.identity_seed_synthetic_link('${person.user}', '${person.name}', 'content-bible-e2e')`);
      person.token = (await signIn(person.phone, person.password)).json?.access_token;
      if (!person.token) throw new Error('local Auth did not return a session');
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}', 'israel')`);
    const grants = await envelope('identity_grant_command', admin.token, 'identity.grant_role',
      Number(psql(`select revision from app.identity_grant_sets where member_id='${media.member}'`)),
      { member_id: media.member, role: 'media' });
    check('B01-media-role', grants.status === 200 && grants.data?.roles?.includes('media'),
      { status: grants.status, media_role: grants.data?.roles?.includes('media') === true });

    let rights = await content(media.token, 'content.create_rights_record', null, {
      label: `${prefix} display-only rights`, source_key: 'church-art', holder: 'SYNTHETIC church team',
      basis: 'church_owned', clears_display: true, clears_offline: false, clears_audio: false,
      evidence: 'SYNTHETIC local placeholder; not a translation grant.',
    });
    const rightsId = rights.data?.rights_id;
    if (rights.status !== 200 || !rightsId) throw new Error(`rights fixture was not created (${rights.status})`);
    rights = await content(media.token, 'content.verify_rights_record', rights.revision, { rights_id: rightsId });
    if (rights.status !== 200 || rights.code) throw new Error(`rights fixture was not verified (${rights.code ?? rights.status})`);

    let webRights = await content(media.token, 'content.create_rights_record', null, {
      label: `${prefix} World English Bible (WEB) source`, source_key: 'web',
      holder: 'SYNTHETIC WEB contributors', basis: 'public_domain',
      clears_display: true, clears_offline: false, clears_audio: false,
      evidence: 'SYNTHETIC source verification: https://ebible.org/engwebp/copyright.htm',
    });
    const webRightsId = webRights.data?.rights_id;
    if (webRights.status !== 200 || !webRightsId) throw new Error('WEB rights fixture was not created');
    webRights = await content(media.token, 'content.verify_rights_record', webRights.revision, { rights_id: webRightsId });
    if (webRights.status !== 200 || webRights.code) throw new Error('WEB rights fixture was not verified');

    const manifests = {};
    for (const code of TRANSLATION_CODES) {
      const response = await rpc('content_bible_manifest', undefined, { translation_code: code });
      if (response.status !== 200 || response.json?.translation_code !== code) throw new Error(`${code} manifest is unavailable`);
      manifests[code] = response.json;
    }
    const count = (code, book, chapter) => manifests[code].chapters.find((row) =>
      row.book_id === book && row.chapter === chapter)?.verse_count;
    const create = async (code) => {
      const result = await content(media.token, 'content.create_bible_translation', null, {
        translation_code: code,
        name: `${prefix} ${code}`,
        rights_id: code === 'WEB' ? webRightsId : rightsId,
        manifest_version: manifests[code].manifest_version,
      });
      if (result.status !== 200 || result.code || !result.data?.translation_id) throw new Error(`${code} draft creation failed (${result.code ?? result.status})`);
      return { id: result.data.translation_id, revision: result.revision };
    };
    const importRows = async (translation, code, rows) => {
      const result = await content(media.token, 'content.import_bible_verses', translation.revision, {
        translation_id: translation.id, revision_no: 1, rows,
      });
      if (result.status !== 200 || result.code) throw new Error(`${code} import failed (${result.code ?? result.status})`);
      translation.revision = result.revision;
      return result;
    };
    const finalize = async (translation) => {
      const result = await content(media.token, 'content.finalize_bible_revision', translation.revision, {
        translation_id: translation.id, revision_no: 1,
      });
      if (result.status === 200 && !result.code) translation.revision = result.revision;
      return result;
    };
    const publish = async (translation) => {
      const result = await content(media.token, 'content.publish_bible_translation', translation.revision,
        { translation_id: translation.id });
      if (result.status === 200 && !result.code) translation.revision = result.revision;
      return result;
    };

    const kjv = await create('KJV');
    const web = await create('WEB');
    const privateList = await publicCatalog();
    const privateCodes = (privateList?.translations ?? []).map((row) => row.translation_code);
    check('B02-drafts-are-private', !privateCodes.includes('KJV') && !privateCodes.includes('WEB'),
      { visible_translation_count: privateCodes.length });

    const kjvGenesis = syntheticVerseRows('KJV', 'GEN', 1, count('KJV', 'GEN', 1));
    const missingTail = await importRows(kjv, 'KJV', kjvGenesis.slice(0, -1));
    const incomplete = await finalize(kjv);
    check('B03-missing-terminal-verse-stays-private', missingTail.status === 200
      && incomplete.code === 'validation_failed' && incomplete.field_errors?.revision_no === 'incomplete_chapter',
    { imported_rows: kjvGenesis.length - 1, finalize_code: incomplete.code });
    const kjvExodus = syntheticVerseRows('KJV', 'EXO', 1, count('KJV', 'EXO', 1));
    const completedTail = await importRows(kjv, 'KJV', [kjvGenesis.at(-1), ...kjvExodus]);
    const kjvFinal = await finalize(kjv);
    const kjvPublished = await publish(kjv);
    const webRows = syntheticVerseRows('WEB', 'GEN', 1, count('WEB', 'GEN', 1));
    await importRows(web, 'WEB', webRows);
    const webFinal = await finalize(web);
    const webPublished = await publish(web);

    const publicList = await publicCatalog();
    const publicTranslations = publicList?.translations ?? [];
    const kjvProjection = publicTranslations.find((row) => row.translation_code === 'KJV');
    const webProjection = publicTranslations.find((row) => row.translation_code === 'WEB');
    const kjvChapter = await publicChapter(kjv.id, 'GEN', 1);
    const webChapter = await publicChapter(web.id, 'GEN', 1);
    const hiddenMemberCommand = await content(member.token, 'content.create_bible_translation', null, {
      translation_code: 'KJV', name: `${prefix} forbidden`, rights_id: rightsId, manifest_version: 1,
    });
    check('B04-KJV-WEB-publish-and-read-anonymously', completedTail.status === 200
      && !kjvFinal.code && !kjvPublished.code && !webFinal.code && !webPublished.code
      && Boolean(kjvProjection) && Boolean(webProjection) && kjvChapter?.verses?.length === count('KJV', 'GEN', 1)
      && webChapter?.verses?.length === count('WEB', 'GEN', 1)
      && JSON.stringify(sortedKeys(kjvChapter)) === JSON.stringify(PUBLIC_CHAPTER_KEYS),
    { codes: publicTranslations.map((row) => row.translation_code).sort(), kjv_verses: kjvChapter?.verses?.length ?? 0,
      web_verses: webChapter?.verses?.length ?? 0, chapter_keys_match: JSON.stringify(sortedKeys(kjvChapter)) === JSON.stringify(PUBLIC_CHAPTER_KEYS) });
    check('B05-display-only-rights-deny-offline-and-members-cannot-edit', kjvChapter?.offline_allowed === false
      && webChapter?.offline_allowed === false && hiddenMemberCommand.code === 'forbidden',
    { offline_allowed: [kjvChapter?.offline_allowed, webChapter?.offline_allowed], member_command: hiddenMemberCommand.code });

    const kjvRefs = kjvProjection?.chapters ?? [];
    const webRefs = webProjection?.chapters ?? [];
    check('B06-navigation-follows-available-canonical-chapters',
      nextAvailableChapter(kjvRefs, { book_id: 'GEN', chapter: 1 })?.book_id === 'EXO'
        && nextAvailableChapter(webRefs, { book_id: 'GEN', chapter: 1 }) === null,
    { kjv_next_book: nextAvailableChapter(kjvRefs, { book_id: 'GEN', chapter: 1 })?.book_id ?? null,
      web_next: nextAvailableChapter(webRefs, { book_id: 'GEN', chapter: 1 }) });
    const staff = await rpc('content_staff_bibles', media.token);
    const staffCodes = (staff.json?.translations ?? []).map((row) => row.translation_code).sort();
    check('B07-Media-reads-the-private-catalog', staff.status === 200
      && JSON.stringify(staffCodes) === JSON.stringify(['KJV', 'WEB']),
    { status: staff.status, translation_codes: staffCodes });
  } finally {
    try {
      cleanupLocalState();
    } finally {
      restorePhoneAuth();
      process.removeListener('SIGINT', onInterrupt);
      process.removeListener('SIGTERM', onTerminate);
    }
  }
  finish();
}

runMain(import.meta.url, main);
