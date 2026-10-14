import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { assertLocalOrigin, localHttp, redact, startRun } from './harness.mjs';
import * as run from './run.mjs';

test('run.mjs keeps re-exporting the moved helpers', () => {
  assert.equal(run.assertLocalOrigin, assertLocalOrigin);
  assert.equal(run.redact, redact);
  assert.equal(run.LOCAL_ORIGIN, 'http://127.0.0.1:54321');
});

test('startRun writes redacted evidence and finish reports failures', (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'harness-test-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const file = join(dir, 'e.jsonl');
  const logs = [];
  t.mock.method(console, 'log', (line) => logs.push(line));
  const { results, check, log, finish } = startRun(['node', 'x.mjs', '--evidence', file]);
  check('S1', true, { password: 'p', status: 200 });
  check('S2', false, {});
  log('S3', { access_token: 't' });
  const prev = process.exitCode;
  finish();
  assert.equal(process.exitCode, 1);
  process.exitCode = prev;
  const lines = readFileSync(file, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  assert.deepEqual(lines.map((l) => [l.step, l.target, l.verdict]), [['S1', 'LOCAL', 'pass'], ['S2', 'LOCAL', 'FAIL'], ['S3', 'LOCAL', undefined]]);
  assert.equal(lines[0].password, '[redacted]');
  assert.equal(lines[2].access_token, '[redacted]');
  assert.deepEqual(results, [{ step: 'S1', ok: true }, { step: 'S2', ok: false }]);
  assert.ok(logs.includes('\n1/2 checks passed'));
  assert.ok(logs.includes('FAILED: S2'));
});

test('localHttp builds the same headers as the per-run clients did', async (t) => {
  const calls = [];
  t.mock.method(globalThis, 'fetch', async (url, init) => {
    calls.push({ url, init });
    return new Response('{"ok":true}', { status: 200, headers: { location: 'x://y' } });
  });
  const keys = { origin: 'http://127.0.0.1:54321', key: 'pub', secret: 'sec', service: 'svc' };
  const seen = [];
  const http = localHttp(keys);
  const sink = [];
  assert.deepEqual(await http('POST', '/rest/v1/rpc/f', { token: 'tok', body: {}, profile: 'api', sink, xff: '192.0.2.1' }),
    { status: 200, json: { ok: true } });
  await http('GET', '/auth/v1/admin/users', { admin: true, profile: 'auth', headers: { 'x-extra': '1' } });
  const manual = localHttp(keys, { redirect: 'manual', onText: (text, { token }) => seen.push([text, token]) });
  assert.deepEqual(await manual('POST', '/auth/v1/verify', { token: 'tok2' }), { status: 200, json: { ok: true }, location: 'x://y' });
  assert.equal(calls[0].url, 'http://127.0.0.1:54321/rest/v1/rpc/f');
  assert.deepEqual(calls[0].init.headers, { apikey: 'pub', 'Content-Type': 'application/json', Authorization: 'Bearer tok',
    'Content-Profile': 'api', 'X-Forwarded-For': '192.0.2.1' });
  assert.equal(calls[0].init.body, '{}');
  assert.equal(calls[0].init.redirect, undefined);
  assert.deepEqual(sink, ['{"ok":true}']);
  assert.deepEqual(calls[1].init.headers, { apikey: 'sec', 'Content-Type': 'application/json', 'x-extra': '1',
    Authorization: 'Bearer svc', 'Accept-Profile': 'auth' });
  assert.equal(calls[1].init.body, undefined);
  assert.equal(calls[2].init.redirect, 'manual');
  assert.deepEqual(seen, [['{"ok":true}', 'tok2']]);
});
