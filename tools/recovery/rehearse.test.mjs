import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { LocalSegmentJournal, verifyJournal } from './journal.mjs';
import { deriveScenario, expectScenario, jsonLiteral, uuidLiteral } from './rehearse.mjs';

const SUBJECT = '00000000-0000-4000-8000-000000000001';
const OBJECT = { bucket: 'rcv-synthetic-rehearsal', object_id: '00000000-0000-4000-8000-0000000000b1' };

test('SQL literals refuse values that could escape their quoting', () => {
  assert.equal(jsonLiteral({ a: 1 }), '$j${"a":1}$j$::jsonb');
  assert.throws(() => jsonLiteral({ a: '$j$; drop table x; --' }), /cannot be quoted/);
  assert.equal(uuidLiteral(SUBJECT), `'${SUBJECT}'::uuid`);
  assert.throws(() => uuidLiteral("x'; select 1; --"), /not a uuid/);
});

test('scenario journals are damaged copies with the expected verdicts', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'rcv-rehearse-'));
  try {
    const live = new LocalSegmentJournal(join(dir, 'live'));
    await live.append({ kind: 'checkpoint' });
    await live.append({ kind: 'access_revoked', subject: SUBJECT });
    await live.append({ kind: 'deletion_manifest', subject: SUBJECT, object: OBJECT });
    await live.append({ kind: 'deletion_completed', object: OBJECT });
    const cutoff = new Date().toISOString();
    await live.append({ kind: 'seal', cutoff });
    const verdict = async (s) => verifyJournal(
      await new LocalSegmentJournal(deriveScenario(s, join(dir, 'live'), join(dir, s))).list(), { cutoff }).reason;
    assert.equal(await verdict('absent'), 'journal_absent');
    assert.equal(existsSync(join(dir, 'absent')), false);
    assert.equal(await verdict('gap'), 'journal_gap');
    assert.equal(await verdict('tampered'), 'journal_chain_broken');
    assert.equal(await verdict('unsealed'), 'journal_unsealed');
    assert.equal(await verdict('early_seal'), null, 'early_seal keeps the journal; the later cutoff fails it');
    // The live journal is never modified by deriving scenarios.
    assert.equal(readdirSync(join(dir, 'live')).filter((n) => n.startsWith('seg-')).length, 5);
    assert.match(readFileSync(join(dir, 'live', 'seg-0000000002-access_revoked.json'), 'utf8'), new RegExp(SUBJECT));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('scenario expectations reject a gate that opens without a complete journal', () => {
  const held = { state: 'restored_held', serving_hold: true, last_refusal: 'journal_gap', private_access_open: false, outbound_sending_open: false };
  const closed = { private_access_if_approved: false, outbound_sending_if_approved: false };
  const base = { restored: { status: held, gates_if_approved: closed } };
  assert.deepEqual(expectScenario('gap', { ...base, outcome: 'held', reason: 'journal_gap', after: { status: held, gates_if_approved: closed } }), []);
  assert.equal(expectScenario('gap', { ...base, outcome: 'held', reason: 'journal_gap',
    after: { status: held, gates_if_approved: { ...closed, private_access_if_approved: true } } }).length, 1);
  const ok = { ...base, outcome: 'reconciled',
    after: { status: { ...held, state: 'reconciled', serving_hold: false, last_refusal: null }, subject_access_revoked: true, object_present: false,
      gates_if_approved: { private_access_if_approved: true, outbound_sending_if_approved: true } } };
  assert.deepEqual(expectScenario('complete', ok), []);
  assert.match(expectScenario('complete', { ...ok, after: { ...ok.after, object_present: true } }).join(), /still present/);
});
