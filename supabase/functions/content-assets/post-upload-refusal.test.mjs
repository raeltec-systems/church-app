// Follow-up review F1 (2026-10-28): a sync whose plan read is refused AFTER it placed a public
// object must not leave that object public.
//
// Adapted from the follow-up review's witness (f1-post-upload-plan-failure.test.mjs), which asserted
// the unsafe state; here the same two-sync interleaving asserts the safe one. Sync A revalidates its
// plan and starts its server-authority upload; the upload is held before it commits. An editor
// withdraws the item and the withdrawal's sync B completes (nothing to remove yet: the object is not
// there). A's editor access is then revoked or the plan RPC becomes unavailable, and A's upload
// commits. A's next plan read is refused with 401, 403 or 503 (or the RPC call times out). The
// production `sync` handler from index.ts runs with its type annotations stripped; only I/O is
// mocked. Nothing touches the network.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';

import { planFrom, syncPublicFiles } from './logic.mjs';

const PATH = 'banner/00000000-0000-4000-8000-000000062099/r1/image.png';
const DRAFT = '00000000-0000-4000-8000-000000062098.png';
const SOURCE = fs.readFileSync(new URL('./index.ts', import.meta.url), 'utf8').replace(/\r\n/g, '\n');

function gate() {
  let resolve;
  const promise = new Promise((r) => { resolve = r; });
  return { promise, resolve };
}

class Unavailable extends Error {}

function extracted() {
  let sync = SOURCE.slice(SOURCE.indexOf('async function sync('), SOURCE.indexOf('\nasync function preview('));
  for (const [from, to] of [
    ['async function sync(auth: string): Promise<Response>', 'async function sync(auth)'],
    ['(p: Json, bytes: Uint8Array)', '(p, bytes)'], ['(p: Json)', '(p)'],
    ['(paths: string[])', '(paths)'], [' as Response', ''], [' as Json', ''], [' as string', ''],
  ]) sync = sync.replaceAll(from, to);
  assert.ok(sync.startsWith('async function sync(auth)'), 'sync handler signature changed; update the test');
  assert.ok(!/:\s*(Json|string|Response|Uint8Array)\b/.test(sync), 'unstripped TypeScript annotation in sync');
  let refusal = SOURCE.slice(SOURCE.indexOf('function readRefusal('), SOURCE.indexOf('\n// A Content command'));
  refusal = refusal.replace('status: number', 'status').replace(': Response | null', '');
  return { sync, refusal };
}

// world: the database's desired state and the public bucket. `denied` applies to editor A only:
// a status (401/403/503) or 'timeout' (the RPC call throws, as asCaller does when fetch fails).
function productionHandler(world, hold) {
  const { sync, refusal } = extracted();
  const reply = (status, body) => new Response(JSON.stringify(body), {
    status, headers: { 'content-type': 'application/json' },
  });
  const readRefusal = new Function('reply', `return (${refusal});`)(reply);
  const asCaller = async (auth) => {
    const denied = auth === 'A' ? world.denied : null;
    world.calls.push({ kind: 'plan', auth, denied });
    if (denied === 'timeout') throw new Unavailable();
    if (denied) return { status: denied, json: null };
    const place = world.desired && !world.present
      ? [{ draft_path: DRAFT, public_path: PATH, media_type: 'image/png' }] : [];
    const remove = !world.desired && world.present ? [PATH] : [];
    return { status: 200, json: { place, remove, waiting: place.length, removals_pending: remove.length } };
  };
  const timed = async (url, init) => {
    if (init.method === 'GET' && url.endsWith(`/content-drafts/${DRAFT}`)) return new Response(new Uint8Array([1]));
    if (init.method === 'POST' && url.endsWith(`/content-public/${PATH}`)) {
      world.calls.push({ kind: 'upload-started' });
      if (hold) await hold();
      world.present = true;
      world.puts++;
      world.calls.push({ kind: 'upload-committed', desired: world.desired });
      return new Response('');
    }
    if (init.method === 'DELETE' && url.endsWith('/content-public')) {
      const prefixes = JSON.parse(init.body).prefixes;
      if (world.storageDown) {
        world.calls.push({ kind: 'remove-failed' });
        return new Response('', { status: 503 });
      }
      const hit = world.present && prefixes.includes(PATH);
      if (hit) world.present = false;
      world.calls.push({ kind: 'remove', hit, prefixes });
      return new Response(JSON.stringify(hit ? [{ name: PATH }] : []));
    }
    throw new Error(`Unexpected mocked route: ${init.method} ${url}`);
  };
  const storageHeaders = (extra) => ({ 'test-only-storage-authority': 'service-role', ...extra });
  const make = new Function('syncPublicFiles', 'planFrom', 'asCaller', 'readRefusal', 'timed', 'storageHeaders',
    'reply', 'SUPABASE_URL', 'DRAFT_BUCKET', 'PUBLIC_BUCKET', 'PUBLIC_CACHE_CONTROL', 'FILE_TIMEOUT_MS',
    'MAX_PLAN_ROUNDS', `return (${sync});`);
  return make(syncPublicFiles, planFrom, asCaller, readRefusal, timed, storageHeaders, reply,
    'http://mock-only.invalid', 'content-drafts', 'content-public', 'max-age=300', 30000, 4);
}

function newWorld() {
  return { desired: true, present: false, denied: null, storageDown: false, puts: 0, calls: [] };
}

// The review's exact interleaving. `withdraw` false keeps the item wanted (only A's access goes).
async function interleave(world, denied, { withdraw = true } = {}) {
  const reached = gate();
  const resume = gate();
  let held = false;
  const syncA = productionHandler(world, async () => {
    if (held) return;
    held = true;
    reached.resolve();
    await resume.promise; // the Storage write has not committed yet
  });
  const syncB = productionHandler(world, null);
  const runA = syncA('A').then((r) => ({ response: r }), (error) => ({ error }));
  await reached.promise; // A revalidated and started its upload
  if (withdraw) world.desired = false; // another editor withdraws the item or its rights
  const responseB = await syncB('B');
  const resultB = await responseB.json();
  world.denied = denied; // A's role or session revoked, or the plan RPC unavailable
  resume.resolve();
  return { a: await runA, responseB, resultB, sync: productionHandler(world, null) };
}

for (const denied of [401, 403, 503]) {
  test(`F1 follow-up: post-upload plan refused with ${denied}: the withdrawn origin object ends absent`, async () => {
    const world = newWorld();
    const { a, responseB, resultB } = await interleave(world, denied);
    assert.equal(responseB.status, 200);
    assert.equal(resultB.outcome, 'synced');
    assert.equal(resultB.removals_pending, 0, 'B saw nothing to remove: the object was not there yet');
    assert.ok(!a.error, `sync A threw: ${a.error}`);
    assert.equal(a.response.status, denied, 'the refusal is still answered to the caller');
    assert.equal(world.desired, false);
    assert.equal(world.puts, 1, 'A did upload after B finished');
    assert.equal(world.present, false, 'withdrawn object must not remain at its public origin');
    const removes = world.calls.filter((c) => c.kind === 'remove');
    assert.deepEqual(removes.map((c) => c.prefixes), [[PATH]], 'only the path this sync placed is removed');
  });

  test(`F1 follow-up: after the ${denied} refusal every retry ends in a safe terminal state`, async () => {
    const world = newWorld();
    const { sync } = await interleave(world, denied);
    // A retries while still refused: refused before any upload, nothing becomes public.
    const retryA = await sync('A');
    assert.equal(retryA.status, denied);
    assert.equal(world.puts, 1);
    assert.equal(world.present, false);
    // An authorized editor's sync: nothing waiting, nothing to remove, twice in a row.
    for (let i = 0; i < 2; i++) {
      const r = await (await sync('B')).json();
      assert.deepEqual({ outcome: r.outcome, waiting: r.waiting, removals_pending: r.removals_pending },
        { outcome: 'synced', waiting: 0, removals_pending: 0 });
    }
    assert.equal(world.present, false);
    assert.equal(world.puts, 1, 'a withdrawn file is never uploaded again');
  });
}

test('F1 follow-up: post-upload plan read times out: the withdrawn origin object ends absent', async () => {
  const world = newWorld();
  const { a } = await interleave(world, 'timeout');
  // The handler either answers 503 or throws Unavailable to the top-level catch (which answers 503).
  if (a.response) assert.equal(a.response.status, 503);
  else assert.ok(a.error instanceof Unavailable);
  assert.equal(world.present, false, 'withdrawn object must not remain at its public origin');
});

test('F1 follow-up: a still-wanted file removed after a refusal is restored by the next authorized sync', async () => {
  const world = newWorld();
  const { a, sync } = await interleave(world, 403, { withdraw: false });
  assert.equal(a.response.status, 403);
  // Fail closed: A cannot confirm the file is still wanted, so the file it placed is taken back.
  assert.equal(world.present, false);
  const r = await (await sync('B')).json();
  assert.equal(r.outcome, 'synced');
  assert.equal(r.placed, 1);
  assert.equal(r.waiting, 0);
  assert.equal(world.present, true);
});

test('F1 follow-up: a cleanup delete that fails is retried a bounded number of times, then the next sync removes it', async () => {
  const world = newWorld();
  world.storageDown = true;
  const { a, sync } = await interleave(world, 401);
  assert.equal(a.response.status, 401);
  const failed = world.calls.filter((c) => c.kind === 'remove-failed').length;
  assert.ok(failed >= 1 && failed <= 5, `bounded cleanup attempts, got ${failed}`);
  assert.equal(world.present, true, 'Storage refused every delete');
  world.storageDown = false;
  const r = await (await sync('B')).json();
  assert.equal(r.removals_pending, 0);
  assert.equal(world.present, false, 'the plan lists the leftover object and the next sync removes it');
});

test('F1 follow-up: logic: a refused read after placement removes exactly the placed paths', async () => {
  const placedPaths = [];
  let reads = 0;
  const removed = [];
  const io = {
    readPlan: async () => {
      reads++;
      if (reads <= 2) {
        return { plan: planFrom({ place: [{ draft_path: DRAFT, public_path: PATH, media_type: 'image/png' }],
          remove: ['banner/old/r1/image.png'], waiting: 1, removals_pending: 1 }) };
      }
      return { refused: 'forbidden' };
    },
    readDraft: async () => new Uint8Array([1]),
    putPublic: async (p) => { placedPaths.push(p.public_path); return true; },
    removePublic: async (paths) => { removed.push(paths); return paths.length; },
  };
  const out = await syncPublicFiles(io, 4);
  assert.equal(out.refused, 'forbidden');
  assert.deepEqual(placedPaths, [PATH]);
  // The plan's own removal (read while authorized), then the compensation of the placed path.
  assert.deepEqual(removed, [['banner/old/r1/image.png'], [PATH]]);
});
