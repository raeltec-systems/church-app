import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  SYSTEM_CREDENTIAL_PATTERN,
  SYSTEM_CREDENTIAL_RE,
  UUID_RE,
  credentialFrom,
  declaredTooLarge,
  keyHeaders,
  systemEnvelope,
} from './system_access.mjs';

test('canonical UUID and system credential shapes stay lowercase and environment-bound', () => {
  assert.equal(UUID_RE.test('00000000-0000-4000-8000-000000000001'), true);
  assert.equal(UUID_RE.test('00000000-0000-4000-8000-00000000000A'), false);
  const credential = `sysc_staging_${'A'.repeat(43)}`;
  assert.equal(SYSTEM_CREDENTIAL_RE.test(credential), true);
  assert.equal(credentialFrom(credential), credential);
  assert.equal(credentialFrom(`sysc_dev_${'A'.repeat(43)}`), null);
  assert.equal(credentialFrom(`${credential}x`), null);
  assert.match(SYSTEM_CREDENTIAL_PATTERN, /^sysc_/);
});

test('Content-Length parsing is caller-limited and fails closed on malformed values', () => {
  for (const limit of [256, 1024]) {
    assert.equal(declaredTooLarge(null, limit), false);
    assert.equal(declaredTooLarge(String(limit - 1), limit), false);
    assert.equal(declaredTooLarge(String(limit), limit), false);
    assert.equal(declaredTooLarge(String(limit + 1), limit), true);
    assert.equal(declaredTooLarge('12x', limit), true);
    assert.equal(declaredTooLarge('1e3', limit), true);
  }
  assert.equal(declaredTooLarge(' 256 ', 256), false);
});

test('request helpers preserve legacy key headers and system envelope shape', () => {
  assert.deepEqual(keyHeaders('sb_publishable_x'), { apikey: 'sb_publishable_x' });
  assert.deepEqual(keyHeaders('eyJabc'), { apikey: 'eyJabc', authorization: 'Bearer eyJabc' });
  assert.deepEqual(systemEnvelope('notifications.claim', {}, 'request-1'),
    { version: 1, command: 'notifications.claim', request_id: 'request-1', payload: {} });
});
