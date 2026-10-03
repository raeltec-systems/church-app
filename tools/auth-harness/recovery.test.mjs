// Offline tests for the story 1.3 recovery harness: Edge Function guards
// (logic.mjs), redaction of grant/operator secrets, and the committed
// scenario files. Run with `node --test tools/auth-harness/*.test.mjs`.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  HEX64_RE,
  INJECTIONS,
  OWN_ISSUER,
  OWN_REF,
  buildOutcome,
  classifyCaller,
  decodeJwtPayload,
  isOwnProjectUrl,
  requestTargetsOtherProject,
  requiredCaller,
  sha256Hex as webSha256Hex,
  syntheticEmail,
} from './functions/harness-recovery/logic.mjs';
import { decodeJwtPayloadNode, scrub, sha256Hex, tag, tagUuids } from './lib.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const jwt = (claims) => `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64(claims)}.c2lnbmF0dXJlLXNpZ25hdHVyZQ`;

test('function serves only its own project URL', () => {
  assert.equal(isOwnProjectUrl(`https://${OWN_REF}.supabase.co`), true);
  assert.equal(isOwnProjectUrl(`https://${OWN_REF}.supabase.co/`), true);
  for (const bad of [
    'https://tmurpotfluignacfueki.supabase.co',
    `http://${OWN_REF}.supabase.co`,
    `https://${OWN_REF}.supabase.co.attacker.example`,
    `https://${OWN_REF}.supabase.co:8443`,
    `https://user:pw@${OWN_REF}.supabase.co`,
    `https://${OWN_REF}.supabase.co/rest/v1`,
    '',
    'not a url',
    undefined,
  ]) {
    assert.equal(isOwnProjectUrl(bad), false, String(bad));
  }
});

test('requests naming another project or URL are refused', () => {
  assert.equal(requestTargetsOtherProject({ action: 'request' }), false);
  assert.equal(requestTargetsOtherProject({ project_ref: OWN_REF }), false);
  assert.equal(requestTargetsOtherProject({ project_ref: 'tmurpotfluignacfueki' }), true);
  assert.equal(requestTargetsOtherProject({ ref: '' }), true);
  assert.equal(requestTargetsOtherProject({ url: 'https://tmurpotfluignacfueki.supabase.co' }), true);
  assert.equal(requestTargetsOtherProject({ supabase_url: `https://${OWN_REF}.supabase.co` }), false);
  assert.equal(requestTargetsOtherProject({ target_url: `https://${OWN_REF}.supabase.co.evil.example` }), true);
});

test('caller classification accepts only own anon key or own user sessions', () => {
  const anon = { iss: 'supabase', ref: OWN_REF, role: 'anon', iat: 1, exp: 2 };
  const user = { iss: OWN_ISSUER, role: 'authenticated', sub: 'u', session_id: 's', aud: 'authenticated' };
  assert.equal(classifyCaller(decodeJwtPayload(jwt(anon))), 'anon');
  assert.equal(classifyCaller(decodeJwtPayload(jwt(user))), 'user');
  assert.equal(classifyCaller({ ...anon, ref: 'tmurpotfluignacfueki' }), null);
  assert.equal(classifyCaller({ ...anon, sub: 'x' }), null);
  assert.equal(classifyCaller({ ...anon, role: 'service_role' }), null);
  assert.equal(classifyCaller({ ...user, iss: 'https://tmurpotfluignacfueki.supabase.co/auth/v1' }), null);
  assert.equal(classifyCaller({ ...user, session_id: undefined }), null);
  assert.equal(classifyCaller(decodeJwtPayload('sb_publishable_x')), null);
  assert.equal(classifyCaller(null), null);
});

test('member and operator actions need the anon key; staff actions need a user session', () => {
  for (const a of ['request', 'redeem', 'resume', 'provision']) assert.equal(requiredCaller(a), 'anon');
  for (const a of ['issue', 'relink', 'hold', 'reconcile', 'replay_complete', 'observe']) {
    assert.equal(requiredCaller(a), 'user');
  }
  assert.equal(requiredCaller('complete'), null, 'completion is never a caller action');
  assert.equal(requiredCaller('dispatch'), null);
  assert.equal(requiredCaller(''), null);
  assert.deepEqual([...INJECTIONS].sort(), ['delay_apply', 'late_apply', 'lost_response', 'stop_after_begin']);
});

test('provisioning only ever targets owner-approved synthetic plus-addresses', () => {
  assert.equal(syntheticEmail('r13-ma'), 'israelmuyoba+bicauth-r13-ma@gmail.com');
  for (const bad of ['', 'A', '-x', 'x@evil.example', 'x y', 'a'.repeat(25), 'x+y']) {
    assert.throws(() => syntheticEmail(bad), /validation_failed/, bad);
  }
});

test('the function reports Auth facts only; the DB decides success', () => {
  assert.deepEqual(buildOutcome({ adminStatus: 200, adminThrew: false, transport: 'ok' }),
    { admin_status: 200, applied: true, transport: 'ok' });
  assert.deepEqual(buildOutcome({ adminStatus: 200, adminThrew: false, transport: 'lost' }),
    { admin_status: 200, applied: true, transport: 'lost' });
  assert.deepEqual(buildOutcome({ adminStatus: 422, adminThrew: false, transport: 'ok' }),
    { admin_status: 422, applied: false, transport: 'ok' });
  // A network failure is never a definitive failure: it is reported as lost.
  assert.deepEqual(buildOutcome({ adminStatus: null, adminThrew: true, transport: 'ok' }),
    { admin_status: null, applied: false, transport: 'lost' });
  assert.equal('revoked' in buildOutcome({ adminStatus: 200 }), false, 'revocation is not self-reported');
});

test('function and harness compute the same grant digest', async () => {
  const secret = 'hg_' + 'A'.repeat(43);
  const d = await webSha256Hex(secret);
  assert.match(d, HEX64_RE);
  assert.equal(d, sha256Hex(secret));
  assert.equal(d, createHash('sha256').update(secret).digest('hex'));
});

test('grant secrets, operator tokens and grant fields never survive redaction', () => {
  const grant = 'hg_' + 'b'.repeat(43);
  const op = 'ho_' + 'c'.repeat(43);
  const out = JSON.stringify(scrub({
    grant,
    grant_digest: 'f'.repeat(64),
    operator: op,
    note: `secret ${grant} and ${op}`,
    nested: { 'x-harness-operator': op },
  }));
  assert.ok(!out.includes(grant) && !out.includes(op) && !out.includes('f'.repeat(64)), out);
  assert.match(out, /\[redacted-grant\]/);
  assert.match(out, /\[redacted-operator\]/);
});

test('evidence ids are digests, never raw UUIDs', () => {
  const id = '6f1b0a52-6a43-4d6e-9d0b-6e1d1c1a2b3c';
  const out = tagUuids({ op_id: id, list: [`op ${id}`], n: 3 });
  assert.equal(out.op_id, tag(id));
  assert.equal(out.list[0], `op ${tag(id)}`);
  assert.equal(out.n, 3);
  assert.equal(decodeJwtPayloadNode('not.a.jwt'), null);
});

test('committed scenarios only use the r13 synthetic accounts and known commands', () => {
  const dir = join(HERE, 'scenarios');
  const allowed = new Set([
    'login', 'probe', 'refresh', 'set-password',
    'rc-provision', 'rc-request', 'rc-issue', 'rc-redeem', 'rc-resume', 'rc-relink',
    'rc-hold', 'rc-reconcile', 'rc-replay', 'rc-probe', 'rc-call', 'rc-observe',
  ]);
  const files = readdirSync(dir).filter((f) => f.startsWith('1.3-'));
  assert.ok(files.length >= 3);
  for (const f of files) {
    for (const raw of readFileSync(join(dir, f), 'utf8').split('\n')) {
      const line = raw.replace(/#.*$/, '').trim();
      if (!line || line.startsWith('@sleep')) continue;
      const [cmd] = line.replace(/^\?/, '').split(/\s+/);
      assert.ok(allowed.has(cmd), `${f}: ${cmd}`);
      for (const email of line.match(/[^\s]+@[^\s]+\.[a-z]+/g) ?? []) {
        assert.match(email, /^israelmuyoba\+bicauth-r13-[a-z0-9-]+@gmail\.com$/, `${f}: ${email}`);
      }
      assert.ok(!/hg_|ho_|Hx!|eyJ/.test(line), `${f}: secret-shaped text`);
    }
  }
});
