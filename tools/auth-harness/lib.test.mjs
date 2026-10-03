// Offline tests for the Auth harness helpers: run with `node --test tools/auth-harness/`.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  amrHasPassword,
  maskIdentifier,
  parseRedirectLocation,
  parseVerifyLink,
  scrub,
  summarizeJwt,
  summarizeSession,
  tag,
} from './lib.mjs';

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const fakeJwt = (claims) =>
  `${b64({ alg: 'ES256', kid: 'k1', typ: 'JWT' })}.${b64(claims)}.c2lnbmF0dXJlLXNpZ25hdHVyZQ`;
const JWT_SHAPE = /eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/;

const claims = {
  iss: 'https://example.supabase.co/auth/v1',
  aud: 'authenticated',
  role: 'authenticated',
  aal: 'aal1',
  amr: [{ method: 'password', timestamp: 1 }],
  sub: '00000000-0000-0000-0000-000000000001',
  session_id: '00000000-0000-0000-0000-0000000000aa',
  email: 'someone+bicauth-t@gmail.com',
  iat: 100,
  exp: 3700,
};

test('scrub redacts secret keys at any depth and token-shaped strings', () => {
  const jwt = fakeJwt(claims);
  const out = scrub({
    access_token: jwt,
    refresh_token: 'abc123',
    nested: { password: 'p', token_hash: 'x', keep: 'ok', list: [{ otp: '123456' }] },
    note: `Bearer ${jwt}`,
    link: 'https://h/auth/v1/verify?token=deadbeef&type=recovery',
    frag: 'http://localhost:3000/#access_token=AAA&refresh_token=BBB&type=recovery',
    key: 'sb_' + 'publishable_abcDEF123',
    error_code: 'invalid_credentials',
    code: 400,
  });
  const s = JSON.stringify(out);
  assert.equal(out.access_token, '[redacted]');
  assert.equal(out.refresh_token, '[redacted]');
  assert.equal(out.nested.password, '[redacted]');
  assert.equal(out.nested.token_hash, '[redacted]');
  assert.equal(out.nested.list[0].otp, '[redacted]');
  assert.equal(out.nested.keep, 'ok');
  assert.equal(out.error_code, 'invalid_credentials');
  assert.equal(out.code, 400);
  assert.doesNotMatch(s, JWT_SHAPE);
  assert.doesNotMatch(s, /deadbeef|AAA|BBB|abcDEF123/);
});

test('summarizeJwt keeps header and trust claims, digests ids, drops identifiers', () => {
  const sum = summarizeJwt(fakeJwt(claims));
  assert.deepEqual(sum.header, { alg: 'ES256', kid: 'k1', typ: 'JWT' });
  assert.deepEqual(sum.claims.amr, [{ method: 'password', timestamp: 1 }]);
  assert.equal(sum.claims.sub, tag(claims.sub));
  assert.equal(sum.claims.session_id, tag(claims.session_id));
  assert.equal(sum.claims.lifetime_s, 3600);
  assert.equal(sum.claims.has_email_claim, true);
  const s = JSON.stringify(sum);
  assert.doesNotMatch(s, /someone|0000000001/);
  assert.equal(summarizeJwt('not-a-jwt'), null);
});

test('summarizeSession never carries the raw tokens', () => {
  const sum = summarizeSession({ access_token: fakeJwt(claims), refresh_token: 'r', expires_in: 3600 });
  assert.equal(sum.has_refresh_token, true);
  assert.doesNotMatch(JSON.stringify(scrub(sum)), JWT_SHAPE);
  assert.ok(sum.jwt_summary.claims.amr);
});

test('amrHasPassword: only an explicit password entry is trusted', () => {
  assert.equal(amrHasPassword([{ method: 'password' }]), true);
  assert.equal(amrHasPassword([{ method: 'otp' }, { method: 'password' }]), true);
  for (const m of ['otp', 'recovery', 'magiclink', 'email/signup', 'email_change', 'anonymous']) {
    assert.equal(amrHasPassword([{ method: m }]), false, m);
  }
  assert.equal(amrHasPassword([]), false);
  assert.equal(amrHasPassword(undefined), false);
  assert.equal(amrHasPassword('password'), false);
});

test('parseVerifyLink extracts token/type/redirect and rejects other URLs', () => {
  const p = parseVerifyLink(
    'https://ref.supabase.co/auth/v1/verify?token=abc&type=recovery&redirect_to=http://localhost:3000',
  );
  assert.deepEqual(p, {
    origin: 'https://ref.supabase.co',
    token: 'abc',
    type: 'recovery',
    redirectTo: 'http://localhost:3000',
  });
  assert.throws(() => parseVerifyLink('https://evil.example/login?token=a&type=b'));
  assert.throws(() => parseVerifyLink('https://ref.supabase.co/auth/v1/verify?type=signup'));
});

test('parseRedirectLocation distinguishes session, error, pkce and empty redirects', () => {
  const s = parseRedirectLocation(
    'http://localhost:3000/#access_token=A&expires_in=3600&refresh_token=R&token_type=bearer&type=recovery',
  );
  assert.equal(s.kind, 'session');
  assert.equal(s.type, 'recovery');
  const e = parseRedirectLocation(
    'http://localhost:3000/#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid',
  );
  assert.equal(e.kind, 'error');
  assert.equal(e.error_code, 'otp_expired');
  assert.equal(parseRedirectLocation('myapp://cb?code=xyz').kind, 'pkce_code');
  assert.equal(parseRedirectLocation(null).kind, 'none');
});

test('maskIdentifier keeps only plus-tag or last digits', () => {
  assert.equal(maskIdentifier('person+bicauth-e1@gmail.com'), '…+bicauth-e1@gmail.com');
  assert.equal(maskIdentifier('+260970000101'), '…0101');
});
