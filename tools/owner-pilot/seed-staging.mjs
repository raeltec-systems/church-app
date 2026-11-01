#!/usr/bin/env node
// Hosted staging fixture preparation only. Default dry-run; no admin/database credentials.
import { createHash, randomUUID } from 'node:crypto';
import { closeSync, existsSync, fsyncSync, mkdirSync, openSync, readFileSync,
  renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildManifest, churchDate, HYMN_EDITION, PROJECT_REF, STAGING_URL } from './manifest.mjs';

const ROOT = fileURLToPath(new URL('../../', import.meta.url));
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const KINDS = Object.freeze({
  event: { key: 'event_id', list: 'events', staff: 'content_staff_events', public: 'content_public_events' },
  sermon_series: { key: 'series_id', list: 'series', staff: 'content_staff_sermon_series', public: 'content_public_sermons' },
  sermon: { key: 'sermon_id', list: 'sermons', staff: 'content_staff_sermons', public: 'content_public_sermons' },
  announcement: { key: 'announcement_id', list: 'announcements', staff: 'content_staff_announcements', public: 'content_public_announcements' },
});
const READS = new Set([...Object.values(KINDS).flatMap((x) => [x.staff, x.public]),
  'content_public_bible_translations', 'content_public_sunday_hymns']);
const fail = (message) => { throw new Error(message); };
const canonical = (value) => JSON.stringify(value, (_, v) => v && typeof v === 'object' && !Array.isArray(v)
  ? Object.fromEntries(Object.keys(v).sort().map((key) => [key, v[key]])) : v);
const hash = (value) => createHash('sha256').update(typeof value === 'string' ? value : canonical(value)).digest('hex');
const same = (a, b) => canonical(a) === canonical(b);

export function validateCredentials(config, token, now = Date.now()) {
  if (config?.SUPABASE_URL !== STAGING_URL) fail('Client config is not the pinned hosted staging URL.');
  if (!/^sb_publishable_[A-Za-z0-9_-]{20,}$/.test(config?.SUPABASE_PUBLISHABLE_KEY ?? '')) {
    fail('A client publishable key is required; privileged keys and legacy JWT keys are refused.');
  }
  let claims;
  try {
    if (typeof token !== 'string' || token.split('.').length !== 3 || token.length > 12000) throw new Error();
    claims = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf8'));
  } catch { fail('Supply an existing editor access token through the private token file or environment.'); }
  if (claims.iss !== STAGING_URL + '/auth/v1' || claims.role !== 'authenticated'
      || !UUID.test(claims.sub ?? '') || !(claims.aud === 'authenticated' || (Array.isArray(claims.aud) && claims.aud.includes('authenticated')))
      || !Number.isFinite(claims.exp) || claims.exp * 1000 <= now + 120000) {
    fail('Editor token must belong to this staging project, be authenticated and have at least two minutes left.');
  }
  return { subject: claims.sub, keyHash: hash(config.SUPABASE_PUBLISHABLE_KEY) };
}

export function makeClient(config, token, { apply = false, confirmation, fetchImpl = fetch, now = Date.now() } = {}) {
  const identity = validateCredentials(config, token, now);
  if (apply && confirmation !== PROJECT_REF) fail('Apply requires --confirm-project ' + PROJECT_REF + '.');
  async function request(path, body, authenticated) {
    const headers = { apikey: config.SUPABASE_PUBLISHABLE_KEY, Accept: 'application/json' };
    if (authenticated) headers.Authorization = 'Bearer ' + token;
    if (body !== undefined) {
      headers['Content-Type'] = 'application/json';
      headers['Content-Profile'] = 'api';
      headers['Accept-Profile'] = 'api';
    }
    let response;
    try {
      response = await fetchImpl(STAGING_URL + path, {
        method: body === undefined ? 'GET' : 'POST', headers,
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        redirect: 'error', signal: AbortSignal.timeout(20000),
      });
    } catch { fail('Network request failed or timed out. Preserve the receipt; retry the same command IDs.'); }
    let value;
    try { value = await response.json(); } catch { fail('Server returned an unreadable response. Preserve the receipt.'); }
    if (!response.ok || value?.code) {
      // No server body, credentials, names or private rows are logged.
      const code = /^[a-z_]{1,60}$/.test(value?.code ?? '') ? value.code : 'request_failed';
      fail('Staging API refused the request (HTTP ' + response.status + ', ' + code + '). No automatic bypass is attempted.');
    }
    return value;
  }
  return {
    ...identity,
    async authenticate() {
      const user = await request('/auth/v1/user', undefined, true);
      if (user?.id !== identity.subject) fail('Authenticated user does not match the supplied editor token.');
    },
    async read(name) {
      if (!READS.has(name)) fail('Unapproved read endpoint.');
      return request('/rest/v1/rpc/' + name, {}, name.includes('_staff_'));
    },
    async command(envelope) {
      if (!apply || confirmation !== PROJECT_REF) fail('Content writes are disabled in dry-run.');
      const match = /^content\.(create|publish)_(event|sermon_series|sermon|announcement)$/.exec(envelope.command ?? '');
      if (!match || !UUID.test(envelope.request_id ?? '') || envelope.version !== 1) fail('Unapproved command.');
      if (match[1] === 'create' && !envelope.payload?.title?.startsWith('SYNTHETIC PILOT ')) fail('Fixture title is missing the namespace.');
      if (envelope.command === 'content.publish_announcement' && envelope.payload?.notify !== false) fail('Notifications are prohibited.');
      return request('/rest/v1/rpc/content_command', envelope, true);
    },
  };
}

async function catalogs(client, onlyKind) {
  const rows = {};
  await Promise.all(Object.entries(KINDS).filter(([kind]) => !onlyKind || kind === onlyKind).map(async ([kind, def]) => {
    const value = await client.read(def.staff);
    if (!value?.capacity || value.truncated !== false || !Array.isArray(value[def.list])) {
      fail('Live editor access and a complete ' + kind + ' catalog are required; no writes on incomplete preflight.');
    }
    rows[kind] = value[def.list];
  }));
  return rows;
}

function payloadFor(item, state) {
  const payload = { ...item.fields };
  if (item.series_key) {
    const id = state.items[item.series_key]?.create?.result?.id;
    if (!id) fail('The owned series must be created before its sermons.');
    payload.series_id = id;
  }
  return payload;
}

function matchesFields(row, payload) {
  return Object.entries(payload).every(([key, expected]) => {
    let actual = key === 'video_rights_id' ? row?.video_rights?.rights_id ?? null : row?.[key];
    if (key === 'starts_at' || key === 'ends_at') return Date.parse(actual) === Date.parse(expected);
    return same(actual, expected);
  });
}

function findOwned(item, entry, rows, { allowPending = true } = {}) {
  const def = KINDS[item.kind];
  const names = rows[item.kind].filter((row) => row.live?.title === item.fields.title || row.draft?.title === item.fields.title);
  if (names.length > 1) fail('Duplicate fixture names found for ' + item.key + '; stop for manual review.');
  const created = entry?.create?.result;
  if (!created) {
    if (names.length && !(allowPending && entry?.create?.envelope)) {
      fail('Existing content has this fixture name without an owned receipt: ' + item.key + '.');
    }
    return null; // A pending create may only be recovered by replaying its exact request ID.
  }
  const row = rows[item.kind].find((r) => r[def.key] === created.id);
  if (!row || names.length !== 1 || names[0][def.key] !== created.id) fail('Owned fixture was removed or renamed: ' + item.key + '.');
  const published = entry.publish?.result;
  const pendingPublish = entry.publish?.envelope && !published;
  const allowed = published
    ? row.state === 'published' && row.revision === published.revision && !row.draft
    : (row.state === 'draft' && row.revision === created.revision)
      || (pendingPublish && row.state === 'published' && row.revision === created.revision + 1 && !row.draft);
  if (!allowed) fail('Fixture changed since the recorded command: ' + item.key + '. No overwrite is allowed.');
  return row;
}

function validateState(state, manifest, client) {
  if (state.format !== 1 || state.project_ref !== PROJECT_REF || state.url !== STAGING_URL
      || state.actor_id !== client.subject || state.key_hash !== client.keyHash
      || state.manifest_hash !== hash(manifest) || state.anchor_date !== manifest.anchor_date
      || !state.items || typeof state.items !== 'object' || Array.isArray(state.items)
      || Object.keys(state.items).some((key) => !manifest.items.some((item) => item.key === key))) {
    fail('Receipt does not match this actor, pinned client key, target and exact manifest.');
  }
}

export async function runPilot({ client, manifest, apply = false, confirmation, state: previous,
  save = () => {}, now = Date.now() }) {
  if (apply && confirmation !== PROJECT_REF) fail('Explicit staging confirmation is required.');
  if (manifest.project_ref !== PROJECT_REF || manifest.namespace !== 'SYNTHETIC PILOT ' + manifest.anchor_date
      || manifest.items.some((item) => !KINDS[item.kind] || !item.fields.title.startsWith(manifest.namespace + ' | '))) {
    fail('Unapproved fixture manifest.');
  }
  const state = previous ?? {
    format: 1, project_ref: PROJECT_REF, url: STAGING_URL, actor_id: client.subject,
    key_hash: client.keyHash, anchor_date: manifest.anchor_date, manifest_hash: hash(manifest),
    created_at: new Date(now).toISOString(), items: {},
  };
  validateState(state, manifest, client);
  const complete = manifest.items.every((item) => state.items[item.key]?.publish?.result);
  if (!complete && manifest.items.some((item) => item.kind === 'event' && Date.parse(item.fields.starts_at) <= now)) {
    fail('A planned event has already started. Do not redate an existing receipt; review the incomplete pilot.');
  }
  await client.authenticate();
  let rows = await catalogs(client);
  const [bible, sunday] = await Promise.all([
    client.read('content_public_bible_translations'), client.read('content_public_sunday_hymns'),
  ]);
  if (!Array.isArray(bible?.translations)) fail('Bible catalog preflight returned an unexpected shape.');
  for (const item of manifest.items) findOwned(item, state.items[item.key], rows);
  const summary = {
    mode: apply ? 'apply' : 'dry-run', project_ref: PROJECT_REF, namespace: manifest.namespace,
    plan: manifest.items.map(({ key, kind, fields }) => ({ key, kind, title: fields.title })),
    existing_counts: Object.fromEntries(Object.entries(rows).map(([k, v]) => [k, v.length])),
    published_web_available: bible.translations.some((x) => x?.translation_code?.toUpperCase() === 'WEB'),
    sunday_list_present: Boolean(sunday?.list ?? sunday?.sunday ?? sunday?.items?.length),
    content_commands_sent: 0, notifications_requested: 0,
    deferred: ['Sunday hymn list changes', 'Giving publication', 'Media and rights', 'Bible import', 'Membership and role changes'],
  };
  if (!apply) return { summary, state };

  async function command(item, phase, payload, expected) {
    const entry = state.items[item.key] ??= {};
    const expectedBody = { version: 1, command: 'content.' + phase + '_' + item.kind,
      expected_revision: expected, payload };
    let step = entry[phase];
    if (!step) {
      step = entry[phase] = { envelope: { ...expectedBody, request_id: randomUUID() } };
      save(state); // Durable intent BEFORE the network call; retries retain the exact UUID/body.
    }
    const { request_id, ...body } = step.envelope ?? {};
    if (!UUID.test(request_id ?? '') || !same(body, expectedBody)) fail('Receipt command differs from the planned operation.');
    if (step.result) return step.result;
    summary.content_commands_sent++;
    const result = await client.command(step.envelope);
    const id = result.data?.[KINDS[item.kind].key];
    if (result.request_id !== request_id || !UUID.test(id ?? '') || !Number.isSafeInteger(result.revision)
        || result.revision < 1 || result.data?.state !== (phase === 'create' ? 'draft' : 'published')
        || (phase === 'publish' && id !== payload[KINDS[item.kind].key])) {
      fail('Command result is uncertain. Preserve the receipt and retry the same request ID.');
    }
    step.result = { request_id, id, revision: result.revision, state: result.data.state };
    save(state);
    return step.result;
  }

  save(state);
  for (const item of manifest.items) {
    rows = await catalogs(client, item.kind);
    findOwned(item, state.items[item.key], rows);
    const payload = payloadFor(item, state);
    const created = await command(item, 'create', payload, null);
    rows = await catalogs(client, item.kind);
    const row = findOwned(item, state.items[item.key], rows, { allowPending: false });
    if (!matchesFields(row.draft ?? row.live, payload)) fail('Fixture content changed before publication: ' + item.key + '.');
    const publishPayload = { [KINDS[item.kind].key]: created.id,
      ...(item.kind === 'announcement' ? { notify: false } : {}) };
    await command(item, 'publish', publishPayload, created.revision);
  }
  const visible = {};
  await Promise.all([...new Set(Object.values(KINDS).map((x) => x.public))].map(async (name) => {
    visible[name] = await client.read(name);
  }));
  for (const item of manifest.items) {
    const def = KINDS[item.kind];
    const ownId = state.items[item.key].publish.result.id;
    const match = visible[def.public]?.[def.list]?.filter((row) => row[def.key] === ownId) ?? [];
    if (match.length !== 1 || match[0].title !== item.fields.title) fail('Published fixture visibility could not be confirmed: ' + item.key + '.');
  }
  state.verified_at = new Date().toISOString();
  save(state);
  summary.status = 'published_and_read_back';
  summary.published_items = manifest.items.length;
  return { summary, state };
}

function writeState(path, state) {
  const temporary = path + '.' + randomUUID() + '.tmp';
  const fd = openSync(temporary, 'wx', 0o600);
  try { writeFileSync(fd, JSON.stringify(state, null, 2) + '\n'); fsyncSync(fd); }
  finally { closeSync(fd); }
  renameSync(temporary, path);
}

function privateReceiptPath(value) {
  const path = resolve(ROOT, value);
  const rel = relative(resolve(ROOT, '.owner-local'), path);
  if (rel === '' || rel.startsWith('..') || isAbsolute(rel)) fail('Receipt must be inside this checkout\'s ignored .owner-local directory.');
  return path;
}

export async function main(argv = process.argv.slice(2), env = process.env) {
  const opts = { clientConfig: resolve(ROOT, '.owner-local/client-staging.json'),
    receipt: '.owner-local/owner-pilot-receipt.json' };
  const args = new Map([['--client-config', 'clientConfig'], ['--token-file', 'tokenFile'],
    ['--receipt', 'receipt'], ['--anchor-date', 'anchorDate'], ['--confirm-project', 'confirmation']]);
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--apply') opts.apply = true;
    else if (argv[i] === '--preview') opts.preview = true;
    else if (args.has(argv[i]) && argv[i + 1] && !argv[i + 1].startsWith('--')) opts[args.get(argv[i])] = argv[++i];
    else fail('Unknown or incomplete option. See docs/runbooks/owner-pilot-data-2026-11-02.md.');
  }
  if (opts.preview && opts.apply) fail('--preview cannot be combined with --apply.');
  const receiptPath = privateReceiptPath(opts.receipt);
  const previous = existsSync(receiptPath) ? JSON.parse(readFileSync(receiptPath, 'utf8')) : undefined;
  const manifest = buildManifest(opts.anchorDate ?? previous?.anchor_date ?? churchDate());
  const hymnBook = JSON.parse(readFileSync(resolve(ROOT, 'packages/client_core/assets/hymn_book/hymn_book.json'), 'utf8'));
  if (hymnBook.edition !== HYMN_EDITION || manifest.sunday_hymns.items.some((h) => !hymnBook.items.some(
    (candidate) => candidate.id === h.id && candidate.number === h.number && candidate.title === h.title))) {
    fail('Suggested hymns do not match the bundled edition.');
  }
  if (opts.preview) {
    process.stdout.write(JSON.stringify({ status: 'prepared_only_no_network', ...manifest }, null, 2) + '\n');
    return;
  }
  const config = JSON.parse(readFileSync(resolve(ROOT, opts.clientConfig), 'utf8'));
  if (opts.tokenFile && env.OWNER_PILOT_EDITOR_TOKEN) fail('Choose one token source, not both.');
  const token = (opts.tokenFile ? readFileSync(resolve(ROOT, opts.tokenFile), 'utf8') : env.OWNER_PILOT_EDITOR_TOKEN ?? '').trim();
  const client = makeClient(config, token, { apply: opts.apply, confirmation: opts.confirmation });
  let lock;
  try {
    if (opts.apply) {
      mkdirSync(dirname(receiptPath), { recursive: true });
      lock = openSync(receiptPath + '.lock', 'wx', 0o600);
      writeFileSync(lock, JSON.stringify({ pid: process.pid, project_ref: PROJECT_REF }));
    }
    const result = await runPilot({
      client, manifest, apply: opts.apply, confirmation: opts.confirmation, state: previous,
      save: (state) => writeState(receiptPath, state),
    });
    process.stdout.write(JSON.stringify(result.summary, null, 2) + '\n');
  } finally {
    if (lock !== undefined) { closeSync(lock); unlinkSync(receiptPath + '.lock'); }
  }
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    // File/system errors may contain private paths; only print our controlled messages.
    const message = error?.code ? 'Local input/state could not be read or locked. Check the private files and receipt lock.' : error.message;
    process.stderr.write('Owner pilot stopped: ' + message + '\n');
    process.exitCode = 1;
  });
}
