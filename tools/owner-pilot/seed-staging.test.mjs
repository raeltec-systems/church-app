import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { buildManifest, PROJECT_REF, STAGING_URL } from './manifest.mjs';
import { makeClient, runPilot, validateCredentials } from './seed-staging.mjs';

const NOW = Date.parse('2026-11-02T08:00:00Z');
const SUBJECT = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const config = { SUPABASE_URL: STAGING_URL, SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_SYNTHETIC_TEST_KEY_NOT_REAL' };
function token(overrides = {}) {
  return 'e30.' + Buffer.from(JSON.stringify({
    iss: STAGING_URL + '/auth/v1', role: 'authenticated', aud: 'authenticated',
    sub: SUBJECT, exp: NOW / 1000 + 3600, ...overrides,
  })).toString('base64url') + '.SYNTHETIC';
}
const manifest = () => buildManifest('2026-11-02');
const defs = {
  event: ['events', 'event_id'], sermon_series: ['series', 'series_id'],
  sermon: ['sermons', 'sermon_id'], announcement: ['announcements', 'announcement_id'],
};
function fixtureServer({ loseReply, truncated = false } = {}) {
  const rows = Object.fromEntries(Object.keys(defs).map((kind) => [kind, []]));
  const commands = [];
  const receipts = new Map();
  let lost = false;
  const client = {
    subject: SUBJECT, keyHash: 'fake-client-key-hash',
    async authenticate() {},
    async read(name) {
      if (name === 'content_public_bible_translations') return { translations: [{ translation_code: 'WEB' }] };
      if (name === 'content_public_sunday_hymns') return { items: [] };
      if (name === 'content_public_sermons') return {
        series: rows.sermon_series.filter((r) => r.live).map((r) => ({ series_id: r.series_id, ...r.live })),
        sermons: rows.sermon.filter((r) => r.live).map((r) => ({ sermon_id: r.sermon_id, ...r.live })),
      };
      for (const [kind, [list, idKey]] of Object.entries(defs)) {
        if (name === 'content_staff_' + (kind === 'sermon_series' ? 'sermon_series' : list)) {
          return structuredClone({ capacity: 'media', truncated, [list]: rows[kind] });
        }
        if (name === 'content_public_' + list) return { [list]: rows[kind].filter((r) => r.live)
          .map((r) => ({ [idKey]: r[idKey], ...r.live })) };
      }
      throw new Error('Unexpected read: ' + name);
    },
    async command(envelope) {
      commands.push(structuredClone(envelope));
      if (receipts.has(envelope.request_id)) return structuredClone(receipts.get(envelope.request_id));
      const [, phase, kind] = /^content\.(create|publish)_(event|sermon_series|sermon|announcement)$/.exec(envelope.command);
      const [, idKey] = defs[kind];
      let row;
      if (phase === 'create') {
        row = { [idKey]: randomUUID(), revision: 1, state: 'draft', live: null, draft: { ...envelope.payload } };
        rows[kind].push(row);
      } else {
        row = rows[kind].find((r) => r[idKey] === envelope.payload[idKey]);
        assert.equal(row.revision, envelope.expected_revision);
        row.live = row.draft; row.draft = null; row.state = 'published'; row.revision++;
      }
      const result = { request_id: envelope.request_id, revision: row.revision,
        data: { [idKey]: row[idKey], state: row.state } };
      receipts.set(envelope.request_id, structuredClone(result));
      if (!lost && loseReply === phase) { lost = true; throw new Error('SYNTHETIC lost response'); }
      return result;
    },
  };
  return { client, rows, commands };
}
function options(server, extra = {}) {
  return { client: server.client, manifest: manifest(), now: NOW, ...extra };
}

test('manifest uses future Lusaka dates, fictional labels and no executable giving/media/hymn changes', () => {
  const m = manifest();
  assert.equal(m.items.length, 12);
  assert.ok(m.items.every((i) => i.fields.title.startsWith(m.namespace)));
  assert.ok(m.items.filter((i) => i.kind === 'event').every((i) => Date.parse(i.fields.starts_at) > NOW));
  assert.equal(m.items.find((i) => i.key === 'event-sunday').fields.starts_at, '2026-11-08T07:00:00.000Z');
  assert.equal(buildManifest('2026-11-08').sunday_hymns.sunday, '2026-11-15');
  assert.ok(m.items.filter((i) => i.kind === 'sermon').every((i) => i.fields.youtube_video_id === null
    && i.fields.facebook_video_url === null && i.fields.video_rights_id === null));
  assert.equal(m.giving_proposal.payment_destination, null);
  assert.equal(m.giving_proposal.publish, false);
  assert.equal(m.sunday_hymns.status, 'suggestion_only_no_write');
});

test('credentials refuse wrong origin, privileged key, issuer, role, audience or expiry', () => {
  assert.equal(validateCredentials(config, token(), NOW).subject, SUBJECT);
  for (const overrides of [
    { iss: 'https://another-project.supabase.co/auth/v1' }, { role: 'service_role' },
    { aud: 'unauthenticated' }, { exp: NOW / 1000 },
  ]) assert.throws(() => validateCredentials(config, token(overrides), NOW));
  assert.throws(() => validateCredentials({ ...config, SUPABASE_URL: STAGING_URL + '.evil.test' }, token(), NOW));
  assert.throws(() => validateCredentials({ ...config, SUPABASE_PUBLISHABLE_KEY: 'sb_secret_FORBIDDEN' }, token(), NOW));
});

test('transport blocks dry-run commands, wrong apply confirmation and any notifications before fetch', async () => {
  let fetched = 0;
  const fetchImpl = async () => { fetched++; throw new Error('Must not reach the network'); };
  const make = (extra = {}) => makeClient(config, token(), { now: NOW, fetchImpl, ...extra });
  const envelope = { version: 1, request_id: randomUUID(), command: 'content.create_event',
    expected_revision: null, payload: { title: 'SYNTHETIC PILOT test' } };
  await assert.rejects(make().command(envelope), /dry-run/);
  assert.throws(() => make({ apply: true, confirmation: 'production' }));
  const apply = make({ apply: true, confirmation: PROJECT_REF });
  await assert.rejects(apply.command({ ...envelope, command: 'content.create_giving_method' }), /Unapproved/);
  await assert.rejects(apply.command({ ...envelope, command: 'content.publish_announcement', payload: { notify: true } }), /prohibited/);
  assert.equal(fetched, 0);
});

test('default dry-run authenticates and preflights but never mutates or writes a receipt', async () => {
  const server = fixtureServer();
  let saves = 0;
  const result = await runPilot(options(server, { save: () => saves++ }));
  assert.equal(result.summary.mode, 'dry-run');
  assert.equal(result.summary.published_web_available, true);
  assert.equal(result.summary.content_commands_sent, 0);
  assert.equal(server.commands.length, 0);
  assert.equal(saves, 0);
});

test('unowned exact title and truncated catalog stop before any command', async () => {
  const server = fixtureServer();
  server.rows.event.push({ event_id: randomUUID(), draft: { title: manifest().items.find((i) => i.kind === 'event').fields.title } });
  await assert.rejects(runPilot(options(server)), /without an owned receipt/);
  assert.equal(server.commands.length, 0);
  const truncated = fixtureServer({ truncated: true });
  await assert.rejects(runPilot(options(truncated, { apply: true, confirmation: PROJECT_REF })), /complete/);
  assert.equal(truncated.commands.length, 0);
});

for (const phase of ['create', 'publish']) test('lost ' + phase + ' reply resumes the same request without duplicating fixtures', async () => {
  const server = fixtureServer({ loseReply: phase });
  const existingId = randomUUID();
  server.rows.event.push({ event_id: existingId, revision: 9, state: 'published',
    live: { title: 'Existing real event: must remain untouched' }, draft: null });
  let saved;
  const save = (value) => { saved = structuredClone(value); };
  const apply = { apply: true, confirmation: PROJECT_REF, save };
  await assert.rejects(runPilot(options(server, apply)), /lost response/);
  assert.ok(saved.items['series-neighbour'][phase].envelope.request_id);
  const originalId = saved.items['series-neighbour'][phase].envelope.request_id;
  const done = await runPilot(options(server, { ...apply, state: saved }));
  assert.equal(done.summary.published_items, 12);
  assert.equal(server.commands.filter((e) => e.request_id === originalId).length, 2);
  assert.equal(server.rows.event.length, 5);
  assert.equal(server.rows.event.find((r) => r.event_id === existingId).revision, 9);
  assert.ok(server.commands.filter((e) => e.command === 'content.publish_announcement').every((e) => e.payload.notify === false));
  const before = server.commands.length;
  await runPilot(options(server, { ...apply, state: saved }));
  assert.equal(server.commands.length, before, 'completed receipts send no additional commands');
  server.rows.sermon[0].revision++;
  await assert.rejects(runPilot(options(server, { ...apply, state: saved })), /changed since/);
  assert.equal(server.commands.length, before);
  await assert.rejects(runPilot({ ...options(server, { state: saved }), client: { ...server.client, subject: randomUUID() } }), /Receipt does not match/);
});
