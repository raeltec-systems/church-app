import assert from 'node:assert/strict';
import { mkdtempSync, readdirSync, rmSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import {
  DriveJournal, DriveRestClient, GENESIS_HASH, LocalSegmentJournal, buildEntry, canonical,
  entryHash, segmentName, serialize, validateEntry, verifyJournal,
} from './journal.mjs';

const SUBJECT = '00000000-0000-4000-8000-000000000001';
const OBJECT = { bucket: 'rcv-synthetic-rehearsal', object_id: '00000000-0000-4000-8000-0000000000b1' };
const T = (m) => new Date(Date.UTC(2026, 9, 3, 12, m));
const CUTOFF = T(30).toISOString();

async function fullJournal(j) {
  await j.append({ kind: 'checkpoint' }, T(1));
  await j.append({ kind: 'access_revoked', subject: SUBJECT }, T(2));
  await j.append({ kind: 'deletion_manifest', subject: SUBJECT, object: OBJECT }, T(3));
  await j.append({ kind: 'deletion_completed', object: OBJECT }, T(4));
  await j.append({ kind: 'seal', cutoff: CUTOFF }, T(31));
}

function tmp() { return mkdtempSync(join(tmpdir(), 'rcv-journal-')); }

test('canonical JSON sorts keys recursively', () => {
  assert.equal(canonical({ b: 1, a: { d: [2, { z: 1, y: 2 }], c: null } }), '{"a":{"c":null,"d":[2,{"y":2,"z":1}]},"b":1}');
});

test('entries are hash-chained from the genesis hash', () => {
  const a = buildEntry(null, { kind: 'checkpoint' }, T(1));
  const b = buildEntry(a, { kind: 'access_revoked', subject: SUBJECT }, T(2));
  assert.equal(a.seq, 1);
  assert.equal(a.prev_hash, GENESIS_HASH);
  assert.equal(b.prev_hash, a.hash);
  assert.equal(entryHash(b), b.hash);
});

test('entries refuse content and fields outside their kind', () => {
  assert.throws(() => buildEntry(null, { kind: 'access_revoked', subject: SUBJECT, name: 'Jane' }), /field name not allowed/);
  assert.throws(() => buildEntry(null, { kind: 'checkpoint', subject: SUBJECT }), /field subject not allowed/);
  assert.throws(() => buildEntry(null, { kind: 'access_revoked', subject: 'jane@example.com' }), /subject must be a uuid/);
  assert.throws(() => buildEntry(null, { kind: 'deletion_completed', object: { ...OBJECT, path: 'photos/jane.jpg' } }), /object must be/);
  assert.throws(() => buildEntry(null, { kind: 'wipe' }), /unknown kind/);
  assert.deepEqual(validateEntry(buildEntry(null, { kind: 'seal', cutoff: CUTOFF }, T(31))), []);
  assert.throws(() => buildEntry(null, { kind: 'seal', cutoff: T(45).toISOString() }, T(31)), /seal cutoff must not be after the seal/);
});

test('local segments are create-only and a complete journal verifies', async () => {
  const dir = tmp();
  try {
    const j = new LocalSegmentJournal(join(dir, 'journal'));
    assert.equal(await j.list(), null);
    await fullJournal(j);
    const names = readdirSync(join(dir, 'journal')).filter((n) => n.startsWith('seg-'));
    assert.deepEqual(names, [
      'seg-0000000001-checkpoint.json', 'seg-0000000002-access_revoked.json',
      'seg-0000000003-deletion_manifest.json', 'seg-0000000004-deletion_completed.json',
      'seg-0000000005-seal.json']);
    const v = verifyJournal(await j.list(), { cutoff: CUTOFF, databaseWatermark: 1 });
    assert.equal(v.complete, true);
    assert.equal(v.head_seq, 5);
    // Overwriting an existing segment is impossible through the adapter.
    const entries = await j.list();
    assert.throws(() => writeFileSync(join(dir, 'journal', segmentName(entries[0])), serialize(entries[0]), { flag: 'wx' }), /EEXIST/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('absent, gap, tampered, unsealed, early seal and behind-database journals are incomplete', async () => {
  const dir = tmp();
  try {
    const j = new LocalSegmentJournal(dir);
    await fullJournal(j);
    const all = await j.list();
    const reason = (entries, opts = {}) => verifyJournal(entries, { cutoff: CUTOFF, ...opts }).reason;
    assert.equal(reason(null), 'journal_absent');
    assert.equal(reason([]), 'journal_absent');
    assert.equal(reason([all[0], all[1], all[3], all[4]]), 'journal_gap');
    assert.equal(reason([all[0], { ...all[1], subject: '00000000-0000-4000-8000-000000000002' }, ...all.slice(2)]), 'journal_chain_broken');
    assert.equal(reason(all.slice(0, 4)), 'journal_unsealed');
    assert.equal(reason(all, { cutoff: T(45).toISOString() }), 'journal_seal_before_cutoff');
    assert.equal(reason(all, { databaseWatermark: 6 }), 'journal_behind_database');
    assert.equal(reason(all, { databaseAcks: [{ seq: 6, hash: all[4].hash }] }), 'journal_behind_database');
    assert.equal(reason(all, { databaseAcks: [{ seq: 1, hash: all[0].hash }, { seq: 2, hash: 'f'.repeat(64) }] }), 'journal_mismatch');
    assert.equal(reason(all, { databaseAcks: [{ seq: 1, hash: all[0].hash }] }), null);
    assert.equal(reason([...all.slice(0, 4), null, all[4]]), 'journal_malformed');
    // An unparseable segment on disk is malformed, not skipped.
    writeFileSync(join(dir, 'seg-0000000006-checkpoint.json'), '{not json');
    assert.equal(reason(await j.list()), 'journal_malformed');
    unlinkSync(join(dir, 'seg-0000000006-checkpoint.json'));
    assert.equal(reason(await j.list()), null);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('DriveJournal only creates files and reads back an identical journal', async () => {
  const files = [];
  const calls = [];
  const client = {
    async listFolder(id) { calls.push(['list', id]); return files.map(({ id: fid, title }) => ({ id: fid, title })); },
    async download(id) { calls.push(['download', id]); return files.find((f) => f.id === id).text; },
    async createFile(f) { calls.push(['create', f.parentId, f.title]); const id = `drive-${files.length + 1}`; files.push({ id, ...f }); return { id, title: f.title }; },
  };
  const drive = new DriveJournal({ client, folderId: 'folder-1' });
  assert.equal(await drive.list(), null);
  await fullJournal(drive);
  assert.equal(drive.lastCreated.title, 'seg-0000000005-seal.json');
  assert.ok(calls.every(([op]) => ['list', 'download', 'create'].includes(op)));
  assert.ok(calls.filter(([op]) => op === 'create').every(([, parent]) => parent === 'folder-1'));
  const v = verifyJournal(await drive.list(), { cutoff: CUTOFF });
  assert.equal(v.complete, true);
  // The same entries written locally hash identically (the Drive copy is a full independent journal).
  const dir = tmp();
  try {
    const local = new LocalSegmentJournal(dir);
    for (const f of files) writeFileSync(join(dir, f.title), f.text);
    assert.equal(verifyJournal(await local.list(), { cutoff: CUTOFF }).head_hash, v.head_hash);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('DriveRestClient sends the bearer token, never a permission call, and reports HTTP errors without bodies', async () => {
  const seen = [];
  const fetchImpl = async (url, init) => {
    seen.push({ url, method: init.method ?? 'GET', auth: init.headers.authorization });
    if (url.includes('/files/fail')) return new Response('secret detail', { status: 403 });
    if (url.includes('/upload/')) return new Response(JSON.stringify({ id: 'f1', name: 'seg-0000000001-checkpoint.json' }));
    if (url.includes('alt=media')) return new Response('{"x":1}');
    return new Response(JSON.stringify({ files: [{ id: 'f1', name: 'seg-0000000001-checkpoint.json' }] }));
  };
  const c = new DriveRestClient({ accessToken: 'SYNTHETIC-token', fetchImpl });
  assert.deepEqual(await c.listFolder('folder-1'), [{ id: 'f1', title: 'seg-0000000001-checkpoint.json' }]);
  assert.equal(await c.download('f1'), '{"x":1}');
  assert.deepEqual(await c.createFile({ title: 't', parentId: 'folder-1', text: '{}' }), { id: 'f1', title: 'seg-0000000001-checkpoint.json' });
  assert.ok(seen.every((s) => s.auth === 'Bearer SYNTHETIC-token' && !s.url.includes('permissions')));
  await assert.rejects(() => c.download('fail'), (e) => e.message === 'drive GET failed: HTTP 403');
  assert.throws(() => new DriveRestClient({}), /access token/);
});

test('a concurrent local append of the same seq fails instead of forking the journal', async () => {
  const dir = tmp();
  try {
    const a = new LocalSegmentJournal(dir);
    const b = new LocalSegmentJournal(dir);
    await a.append({ kind: 'checkpoint' }, T(1));
    // Writer b read the head before a's second append, then both try seq 2 with different kinds.
    const origList = b.list.bind(b);
    const stale = await origList();
    b.list = async () => stale;
    await a.append({ kind: 'access_revoked', subject: SUBJECT }, T(2));
    await assert.rejects(() => b.append({ kind: 'deletion_completed', object: OBJECT }, T(3)), /seq 2 is already claimed/);
    assert.deepEqual(readdirSync(dir).filter((n) => n.startsWith('seg-')).length, 2);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('DriveJournal fails loudly when another writer used the same seq', async () => {
  const files = [{ id: 'other', title: 'seg-0000000001-checkpoint.json', text: '' }];
  const client = {
    async listFolder() { return files.map(({ id, title }) => ({ id, title })); },
    async download() { return '{}'; },
    async createFile(f) { files.push({ id: 'mine', ...f }); return { id: 'mine', title: f.title }; },
  };
  const drive = new DriveJournal({ client, folderId: 'folder-1' });
  drive.list = async () => null; // stale view: this writer thinks the journal is empty
  await assert.rejects(() => drive.append({ kind: 'access_revoked', subject: SUBJECT }, T(2)), /journal fork: 2 Drive segments for seq 1/);
});
