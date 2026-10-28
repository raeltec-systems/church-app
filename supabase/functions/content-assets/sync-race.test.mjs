// Review F1 (2026-10-28): a stale asset sync must never leave a withdrawn public file behind.
//
// Adapted from the review's offline reproduction (evidence/epic6-sync-withdrawal-race.mjs). Sync A
// is paused deterministically (a promise gate, no timers) while an editor withdraws the item and
// the withdrawal's own sync B runs to completion; then A resumes. Once both syncs finish the public
// object must be absent. Each interleaving runs twice: against syncPublicFiles (logic.mjs) and
// against the production `sync` handler extracted from index.ts with its type annotations
// stripped, its plan reads and Storage calls mocked. Nothing touches the network.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';

import { planFrom, syncPublicFiles } from './logic.mjs';

const PATH = 'banner/00000000-0000-4000-8000-000000062099/r1/image.png';
const DRAFT = '00000000-0000-4000-8000-000000062098.png';

function gate() {
  let open;
  const opened = new Promise((resolve) => { open = resolve; });
  return { opened, open };
}

// The database and the public bucket: one item, desired until withdrawn.
function world() {
  const w = { desired: true, present: false, puts: 0, deletes: 0, plans: 0 };
  w.planJson = () => {
    w.plans++;
    const place = w.desired && !w.present ? [{ draft_path: DRAFT, public_path: PATH, media_type: 'image/png' }] : [];
    const remove = !w.desired && w.present ? [PATH] : [];
    return { place, remove, waiting: place.length, removals_pending: remove.length };
  };
  w.put = () => { w.present = true; w.puts++; return true; };
  w.remove = (paths) => {
    const hit = paths.includes(PATH) && w.present;
    if (hit) { w.present = false; w.deletes++; }
    return hit ? 1 : 0;
  };
  return w;
}

// pause: 'draft' (A waits while downloading the draft) or 'upload' (A waits after revalidating,
// right before its upload is stored).
function logicIo(w, pause) {
  return {
    readPlan: async () => ({ plan: planFrom(w.planJson()) }),
    readDraft: async () => { if (pause?.at === 'draft') await pause.hold(); return new Uint8Array([1]); },
    putPublic: async () => { if (pause?.at === 'upload') await pause.hold(); return w.put(); },
    removePublic: async (paths) => w.remove(paths),
  };
}

const ANNOTATIONS = [
  ['async function sync(auth: string): Promise<Response>', 'async function sync(auth)'],
  ['(p: Json, bytes: Uint8Array)', '(p, bytes)'],
  ['(p: Json)', '(p)'],
  ['(paths: string[])', '(paths)'],
  [' as Response', ''],
  [' as Json', ''],
  [' as string', ''],
];

// The production handler from index.ts, bound to a mocked asCaller and timed.
function handler(w, pauseFor) {
  const src = fs.readFileSync(new URL('./index.ts', import.meta.url), 'utf8').replace(/\r\n/g, '\n');
  let fn = src.slice(src.indexOf('async function sync('), src.indexOf('\nasync function preview('));
  for (const [from, to] of ANNOTATIONS) fn = fn.replaceAll(from, to);
  assert.ok(fn.startsWith('async function sync(auth)'), 'sync handler signature changed; update the test');
  assert.ok(!/:\s*(Json|string|Response|Uint8Array)\b/.test(fn), 'unstripped TypeScript annotation in sync');
  const reply = (status, body) => ({ status, body });
  const make = new Function('syncPublicFiles', 'planFrom', 'asCaller', 'readRefusal', 'timed', 'storageHeaders',
    'reply', 'SUPABASE_URL', 'DRAFT_BUCKET', 'PUBLIC_BUCKET', 'PUBLIC_CACHE_CONTROL', 'FILE_TIMEOUT_MS',
    'MAX_PLAN_ROUNDS', `return (${fn});`);
  return (auth) => make(syncPublicFiles, planFrom,
    async () => ({ status: 200, json: w.planJson() }),
    () => null,
    async (url, init) => {
      const pause = pauseFor(auth);
      if (init.method === 'GET') {
        if (pause?.at === 'draft') await pause.hold();
        return new Response(new Uint8Array([1]));
      }
      if (init.method === 'POST') {
        if (pause?.at === 'upload') await pause.hold();
        w.put();
        return new Response('');
      }
      if (init.method === 'DELETE') {
        const body = JSON.parse(init.body);
        const n = w.remove(body.prefixes);
        return new Response(JSON.stringify(n ? [{ name: PATH }] : []));
      }
      throw new Error(`unexpected ${init.method}`);
    },
    (h) => h ?? {}, reply, 'http://mock', 'content-drafts', 'content-public', 'max-age=300', 30000, 4)(auth);
}

// Runs the interleaving: A starts, pauses at `at`; withdrawal commits; B runs to completion; A
// resumes and finishes. Answers both syncs' results.
async function interleave(runA, runB, w, pause) {
  const a = runA();
  await pause.reached.opened;
  w.desired = false; // an editor withdraws the item
  const b = await runB();
  pause.release.open();
  return { a: await a, b };
}

function pauseAt(at) {
  const reached = gate();
  const release = gate();
  let used = false;
  return {
    at,
    reached,
    release,
    hold: async () => {
      if (used) return;
      used = true;
      reached.open();
      await release.opened;
    },
  };
}

for (const at of ['draft', 'upload']) {
  test(`F1 logic: withdrawal and its sync while A pauses at ${at}: the public object ends absent`, async () => {
    const w = world();
    const pause = pauseAt(at);
    const { a, b } = await interleave(
      () => syncPublicFiles(logicIo(w, pause), 4),
      () => syncPublicFiles(logicIo(w, null), 4),
      w, pause);
    assert.equal(w.desired, false);
    assert.equal(w.present, false, 'withdrawn file must not remain public');
    assert.equal(a.result.removals_pending, 0);
    assert.equal(b.result.removals_pending, 0);
    if (at === 'draft') assert.equal(w.puts, 0, 'revalidation must skip the stale upload');
    else assert.equal(w.deletes, 1, 'the final recheck must execute its removal');
  });

  test(`F1 handler: withdrawal and its sync while A pauses at ${at}: the public object ends absent`, async () => {
    const w = world();
    const pause = pauseAt(at);
    const sync = handler(w, (auth) => (auth === 'A' ? pause : null));
    const { a, b } = await interleave(() => sync('A'), () => sync('B'), w, pause);
    assert.equal(a.status, 200);
    assert.equal(b.status, 200);
    assert.equal(w.present, false, 'withdrawn file must not remain public');
    assert.equal(a.body.outcome, 'synced');
    assert.equal(a.body.removals_pending, 0);
    if (at === 'draft') assert.equal(w.puts, 0);
    else assert.equal(w.deletes, 1);
  });
}

test('F1: an undisturbed sync places the file once and reports nothing pending', async () => {
  const w = world();
  const { result } = await syncPublicFiles(logicIo(w, null), 4);
  assert.deepEqual(result, { placed: 1, removed: 0, waiting: 0, removals_pending: 0 });
  assert.equal(w.present, true);
});

test('F1: a refused fresh plan stops the sync before any upload', async () => {
  const w = world();
  let reads = 0;
  const io = {
    ...logicIo(w, null),
    readPlan: async () => (++reads === 1 ? { plan: planFrom(w.planJson()) } : { refused: 'forbidden' }),
  };
  assert.deepEqual(await syncPublicFiles(io, 4), { refused: 'forbidden' });
  assert.equal(w.puts, 0);
});

test('F1: removals that never succeed end after bounded rounds and stay reported as pending', async () => {
  const w = world();
  w.desired = false;
  w.present = true;
  const io = { ...logicIo(w, null), removePublic: async () => 0 };
  const { result } = await syncPublicFiles(io, 4);
  assert.equal(result.removals_pending, 1);
  assert.ok(w.plans <= 4, `plan reads bounded, got ${w.plans}`);
});
