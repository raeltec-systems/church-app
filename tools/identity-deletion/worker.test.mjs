import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { LocalSegmentJournal, validateEntry } from '../recovery/journal.mjs';
import { authClient, checkEntryFields, findJournaled, runDeletion, sameEntry, systemClient } from './worker.mjs';

const M = '00000000-0000-4000-8000-000000021101';
const A = '00000000-0000-4000-8000-000000021102';
const D = '00000000-0000-4000-8000-000000021103';

/** A fake database: the ordered steps, the expected entries and the acks it accepts. */
function fakeDb({ waitAt = null } = {}) {
  const plan = [
    ['journal_access_revoked', 'journal', { kind: 'access_revoked', subject: M }],
    ['journal_manifest_member', 'journal', { kind: 'deletion_manifest', subject: M, object: { bucket: 'identity-member', object_id: M } }],
    ['journal_manifest_account', 'journal', { kind: 'deletion_manifest', subject: M, object: { bucket: 'auth-user', object_id: A } }],
    ['auth_account', 'auth'],
    ['erase_identity', 'advance'], ['erase_owners', 'advance'], ['anonymise', 'advance'], ['verify', 'advance'],
    ['journal_completed_member', 'journal', { kind: 'deletion_completed', object: { bucket: 'identity-member', object_id: M } }],
    ['journal_completed_account', 'journal', { kind: 'deletion_completed', object: { bucket: 'auth-user', object_id: A } }],
    ['complete', 'advance'],
  ];
  const db = { i: 0, acks: [], authDone: false, calls: [], head: { seq: 0, hash: '0'.repeat(64) }, caught: [] };
  const chained = (entry) => entry.seq === db.head.seq + 1 && entry.prev_hash === db.head.hash;
  db.sys = async (command, payload) => {
    db.calls.push(command);
    const step = plan[db.i];
    if (command === 'identity.deletion_next') {
      if (!step) return { next: { action: 'done' } };
      if (waitAt === step[0]) return { next: { step: step[0], action: 'wait', reason: 'handover_pending' } };
      return { next: { step: step[0], action: step[1], ...(step[2] ? { entry: step[2], journal_head: db.head } : {}) } };
    }
    if (command === 'identity.deletion_journal_catch_up') {
      if (!chained(payload.entry)) return { acked: false, reason: 'journal_gap' };
      db.head = { seq: payload.entry.seq, hash: payload.entry.hash };
      db.caught.push(payload.entry.kind);
      return { acked: true, seq: payload.entry.seq };
    }
    if (command === 'identity.deletion_journal_ack') {
      assert.equal(payload.step, step[0]);
      if (!sameEntry(payload.entry, step[2])) return { acked: false, reason: 'entry_mismatch' };
      if (!chained(payload.entry)) return { acked: false, reason: 'journal_gap' };
      assert.deepEqual(validateEntry(payload.entry), []);
      db.head = { seq: payload.entry.seq, hash: payload.entry.hash };
      db.acks.push(payload.entry.seq);
      db.i++;
      return { acked: true, seq: payload.entry.seq };
    }
    if (command === 'identity.deletion_advance') {
      db.i++;
      return { step: step[0], outcome: step[0] === 'complete' ? 'completed' : 'done' };
    }
    throw new Error(`unexpected ${command}`);
  };
  db.auth = async () => { db.i++; db.authDone = true; return 'done'; };
  return db;
}

test('a deletion runs to completion, journaling each entry once before the steps it guards', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'deletion-worker-'));
  try {
    const db = fakeDb();
    const journal = new LocalSegmentJournal(dir);
    const r = await runDeletion({ deletionId: D, sys: db.sys, journal, auth: db.auth });
    assert.equal(r.result, 'done');
    const entries = await journal.list();
    assert.deepEqual(entries.map((e) => e.kind),
      ['access_revoked', 'deletion_manifest', 'deletion_manifest', 'deletion_completed', 'deletion_completed']);
    assert.deepEqual(db.acks, [1, 2, 3, 4, 5]);
    assert.ok(entries.every((e) => validateEntry(e).length === 0), 'only opaque, valid entries');
    assert.ok(db.authDone);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('interrupted after an append and before its ack: the resumed run acks the existing entry', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'deletion-worker-'));
  try {
    const db = fakeDb();
    const journal = new LocalSegmentJournal(dir);
    const first = await runDeletion({ deletionId: D, sys: db.sys, journal, auth: db.auth, maxSteps: 1 });
    assert.equal(first.result, 'stopped');
    assert.equal(first.stopped_before, 'journal_manifest_member');
    // A crash right after the next append: the entry is in the journal, the database never heard.
    await journal.append({ kind: 'deletion_manifest', subject: M, object: { bucket: 'identity-member', object_id: M } });
    const resumed = await runDeletion({ deletionId: D, sys: db.sys, journal, auth: db.auth });
    assert.equal(resumed.result, 'done');
    assert.equal(resumed.steps[0].outcome, 'acked_existing');
    assert.equal((await journal.list()).length, 5, 'no entry was appended twice');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('entries other writers appended after the database head are caught up first, in order', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'deletion-worker-'));
  try {
    const db = fakeDb();
    const journal = new LocalSegmentJournal(dir);
    await journal.append({ kind: 'checkpoint' });
    await journal.append({ kind: 'seal', cutoff: new Date(Date.now() - 1000).toISOString() });
    const r = await runDeletion({ deletionId: D, sys: db.sys, journal, auth: db.auth });
    assert.equal(r.result, 'done');
    assert.deepEqual(db.caught, ['checkpoint', 'seal']);
    assert.deepEqual(db.acks, [3, 4, 5, 6, 7]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a waiting step stops the run with its reason; a refused ack stops it as failed', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'deletion-worker-'));
  try {
    const db = fakeDb({ waitAt: 'erase_identity' });
    const r = await runDeletion({ deletionId: D, sys: db.sys, journal: new LocalSegmentJournal(dir), auth: db.auth });
    assert.equal(r.result, 'wait:handover_pending');
    const bad = fakeDb();
    const refusing = async (c, p) => (c === 'identity.deletion_journal_ack' ? { acked: false, reason: 'journal_mismatch' } : bad.sys(c, p));
    const f = await runDeletion({ deletionId: D, sys: refusing, journal: new LocalSegmentJournal(join(dir, 'b')), auth: bad.auth });
    assert.equal(f.result, 'failed:journal_mismatch');
    const unreachable = await runDeletion({ deletionId: D, sys: fakeDb().sys, journal: new LocalSegmentJournal(join(dir, 'c')),
      auth: async () => 'unreachable' });
    assert.equal(unreachable.result, 'failed:auth_unreachable');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('only opaque journal fields are accepted from the database', () => {
  assert.doesNotThrow(() => checkEntryFields({ kind: 'access_revoked', subject: M }));
  assert.throws(() => checkEntryFields({ kind: 'access_revoked', subject: M, display_name: 'x' }), /unexpected journal field/);
  assert.throws(() => checkEntryFields({ kind: 'deletion_manifest', subject: M, object: { bucket: 'photos', object_id: M } }), /object/);
  assert.throws(() => checkEntryFields({ kind: 'seal' }), /unexpected journal kind/);
  assert.throws(() => checkEntryFields({ kind: 'access_revoked', subject: '+447700900601' }), /uuid/);
  assert.equal(findJournaled([{ kind: 'access_revoked', subject: A, seq: 1 }], { kind: 'access_revoked', subject: M }), null);
  assert.equal(findJournaled([{ kind: 'access_revoked', subject: M, seq: 1 }], { kind: 'access_revoked', subject: M }, 1), null);
});

test('the clients send the credential only as a header and never a service key', async () => {
  const seen = [];
  const fetchImpl = async (url, init) => {
    seen.push({ url, headers: init.headers, body: JSON.parse(init.body) });
    return { ok: true, status: 200, json: async () => (url.includes('system_command') ? { data: { ok: 1 } } : { outcome: 'done' }) };
  };
  const credential = `sysc_local_${'Q'.repeat(43)}`;
  const sys = systemClient({ url: 'http://127.0.0.1:54321', publishableKey: 'sb_publishable_x', credential, fetchImpl });
  assert.deepEqual(await sys('identity.deletion_queue', {}), { ok: 1 });
  const auth = authClient({ functionUrl: 'http://127.0.0.1:54321/functions/v1/identity-deletion', publishableKey: 'sb_publishable_x', credential, fetchImpl });
  assert.equal(await auth(D), 'done');
  assert.ok(seen.every((s) => s.headers['x-system-credential'] === credential && s.headers.apikey === 'sb_publishable_x'
    && !('authorization' in s.headers) && !JSON.stringify(s.body).includes(credential)));
  assert.deepEqual(seen[1].body, { action: 'auth_delete', deletion_id: D });
  assert.throws(() => systemClient({ url: 'x', publishableKey: 'k', credential: 'nope' }), /malformed/);
  const down = authClient({ functionUrl: 'http://x', publishableKey: 'k', credential, fetchImpl: async () => { throw new Error('ECONNREFUSED'); } });
  assert.equal(await down(D), 'unreachable');
});
