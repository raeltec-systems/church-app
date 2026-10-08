// Story 3.6: the FCM HTTP v1 adapter against an injected fake transport. The service account key
// is generated for each run (never stored); tokens are synthetic.
import assert from 'node:assert/strict';
import { createPublicKey, generateKeyPairSync, verify } from 'node:crypto';
import { test } from 'node:test';

import {
  FCM_SCOPE,
  GOOGLE_TOKEN_URL,
  ProviderUnavailable,
  buildMessage,
  classifyFcm,
  createFcmSender,
  fcmEndpoints,
  parseServiceAccount,
  signAssertion,
} from './fcm.mjs';

const { privateKey, publicKey } = generateKeyPairSync('rsa', {
  modulusLength: 2048,
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  publicKeyEncoding: { type: 'spki', format: 'pem' },
});
const ACCOUNT_JSON = {
  type: 'service_account', project_id: 'bic-kafue-test', private_key_id: 'x',
  private_key: privateKey, client_email: 'push-sender@bic-kafue-test.iam.gserviceaccount.com',
};
const ITEM = '00000000-0000-4000-8000-000000036001';
const DEVICE = '00000000-0000-4000-8000-000000036002';
const TOKEN = `fcm-${'a'.repeat(40)}:APA91b`;
const MESSAGE = { notification_id: ITEM, item_id: ITEM, title: 'SYNTHETIC test reminder',
  body: 'A test reminder is waiting for you.', ttl_seconds: 3600, expires_at_epoch: 1791000000 };
const fcmError = (status, code, extra = []) => ({
  error: { code: status, status: code, message: 'x',
    details: [{ '@type': 'type.googleapis.com/google.firebase.fcm.v1.FcmError', errorCode: code }, ...extra] },
});
const reply = (status, json) => ({ ok: status >= 200 && status < 300, status, json: async () => json });

test('the service account is the console JSON or its base64; anything else fails closed', () => {
  const parsed = parseServiceAccount(JSON.stringify(ACCOUNT_JSON));
  assert.equal(parsed.projectId, 'bic-kafue-test');
  assert.equal(parsed.clientEmail, ACCOUNT_JSON.client_email);
  assert.deepEqual(parseServiceAccount(Buffer.from(JSON.stringify(ACCOUNT_JSON)).toString('base64')), parsed);
  for (const bad of [undefined, '', 'not json', '{}', JSON.stringify({ ...ACCOUNT_JSON, type: 'user' }),
    JSON.stringify({ ...ACCOUNT_JSON, project_id: 'Bad Project' }),
    JSON.stringify({ ...ACCOUNT_JSON, client_email: 'someone@gmail.com' }),
    JSON.stringify({ ...ACCOUNT_JSON, private_key: 'nope' })]) {
    assert.equal(parseServiceAccount(bad), null);
  }
});

test('the provider URLs are Google\'s; only a local stack may use a fake endpoint', () => {
  assert.deepEqual(fcmEndpoints({ projectId: 'p-12345', supabaseUrl: 'https://abc.supabase.co' }),
    { tokenUrl: GOOGLE_TOKEN_URL, sendUrl: 'https://fcm.googleapis.com/v1/projects/p-12345/messages:send', test: false });
  assert.equal(fcmEndpoints({ projectId: 'p-12345', supabaseUrl: 'https://abc.supabase.co',
    testEndpoint: 'http://host.docker.internal:9999' }).test, false, 'a hosted project ignores the override');
  const local = fcmEndpoints({ projectId: 'p-12345', supabaseUrl: 'http://kong:8000', testEndpoint: 'http://host.docker.internal:9999' });
  assert.deepEqual(local, { tokenUrl: 'http://host.docker.internal:9999/token',
    sendUrl: 'http://host.docker.internal:9999/v1/projects/p-12345/messages:send', test: true });
  assert.equal(fcmEndpoints({ projectId: 'p-12345', supabaseUrl: 'http://kong:8000',
    testEndpoint: 'http://evil.example/x?y' }).test, false, 'only a bare http origin');
});

test('the OAuth assertion is RS256-signed by the service account for the FCM scope', async () => {
  const account = parseServiceAccount(JSON.stringify(ACCOUNT_JSON));
  const jwt = await signAssertion({ ...account, tokenUrl: GOOGLE_TOKEN_URL, nowSec: 1790000000 });
  const [h, c, s] = jwt.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(h, 'base64url')), { alg: 'RS256', typ: 'JWT' });
  assert.deepEqual(JSON.parse(Buffer.from(c, 'base64url')), {
    iss: ACCOUNT_JSON.client_email, scope: FCM_SCOPE, aud: GOOGLE_TOKEN_URL, iat: 1790000000, exp: 1790003600,
  });
  assert.ok(verify('sha256', Buffer.from(`${h}.${c}`), createPublicKey(publicKey), Buffer.from(s, 'base64url')));
});

test('the message is generic: fixed text, the item id as data and stable notification id, expiring', () => {
  const body = buildMessage({ device_id: DEVICE, platform: 'android', token: TOKEN }, MESSAGE);
  assert.deepEqual(body, {
    message: {
      token: TOKEN,
      notification: { title: 'SYNTHETIC test reminder', body: 'A test reminder is waiting for you.' },
      data: { item_id: ITEM },
      android: { ttl: '3600s', collapse_key: ITEM, priority: 'high', notification: { tag: ITEM } },
      apns: {
        headers: { 'apns-expiration': '1791000000', 'apns-collapse-id': ITEM, 'apns-priority': '10', 'apns-push-type': 'alert' },
        payload: { aps: { sound: 'default' } },
      },
    },
  });
  assert.equal(buildMessage({ token: TOKEN }, { ...MESSAGE, ttl_seconds: 99999999 }).message.android.ttl, '2419200s',
    'at most FCM\'s 28 days');
});

// Error bodies shaped like FCM's documented v1 answers.
const UNREGISTERED_BODY = { error: { code: 404, message: 'Requested entity was not found.', status: 'NOT_FOUND',
  details: [{ '@type': 'type.googleapis.com/google.firebase.fcm.v1.FcmError', errorCode: 'UNREGISTERED' }] } };
const BAD_TOKEN_BODY = { error: { code: 400, message: 'The registration token is not a valid FCM registration token',
  status: 'INVALID_ARGUMENT',
  details: [{ '@type': 'type.googleapis.com/google.firebase.fcm.v1.FcmError', errorCode: 'INVALID_ARGUMENT' }] } };
const BAD_TTL_BODY = { error: { code: 400,
  message: 'Invalid value at \'message.android.ttl\' (type.googleapis.com/google.protobuf.Duration), Field \'ttl\', Illegal duration format',
  status: 'INVALID_ARGUMENT',
  details: [{ '@type': 'type.googleapis.com/google.rpc.BadRequest',
    fieldViolations: [{ field: 'message.android.ttl', description: 'Invalid value at \'message.android.ttl\'' }] }] } };
const SENDER_BODY = { error: { code: 403, message: 'SenderId mismatch', status: 'PERMISSION_DENIED',
  details: [{ '@type': 'type.googleapis.com/google.firebase.fcm.v1.FcmError', errorCode: 'SENDER_ID_MISMATCH' }] } };

test('FCM answers are classified; only answers about the token retire it', () => {
  const c = (status, json) => { const r = classifyFcm(status, json); return `${r.result}|${r.code}|${r.stop}|${r.fatal}`; };
  assert.equal(c(200, { name: 'projects/p/messages/1' }), 'accepted|null|false|null');
  assert.equal(c(404, UNREGISTERED_BODY), 'token_invalid|UNREGISTERED|false|null');
  assert.equal(c(400, BAD_TOKEN_BODY), 'token_invalid|INVALID_ARGUMENT|false|null',
    'FcmError INVALID_ARGUMENT saying the registration token is not valid retires it');
  assert.equal(c(400, fcmError(400, 'INVALID_ARGUMENT', [{ '@type': 'type.googleapis.com/google.rpc.BadRequest',
    fieldViolations: [{ field: 'message.token', description: 'Invalid registration token' }] }])),
  'token_invalid|INVALID_ARGUMENT|false|null');
  assert.equal(c(400, BAD_TTL_BODY), 'rejected|INVALID_ARGUMENT|false|null', 'a payload problem never retires the token');
  assert.equal(c(400, fcmError(400, 'INVALID_ARGUMENT')), 'rejected|INVALID_ARGUMENT|false|null',
    'an INVALID_ARGUMENT that does not name the token keeps it');
  assert.equal(c(403, SENDER_BODY), 'null|SENDER_ID_MISMATCH|true|sender_mismatch',
    'a sender mismatch is our configuration: no token is retired, the run stops');
  assert.equal(c(404, { error: { status: 'NOT_FOUND' } }), 'rejected|NOT_FOUND|false|null', 'a wrong project retires nothing');
  assert.equal(c(429, fcmError(429, 'QUOTA_EXCEEDED')), 'transient|QUOTA_EXCEEDED|true|null');
  assert.equal(c(503, fcmError(503, 'UNAVAILABLE')), 'transient|UNAVAILABLE|false|null');
  assert.equal(c(500, null), 'transient|INTERNAL|false|null');
  assert.equal(c(401, fcmError(401, 'THIRD_PARTY_AUTH_ERROR')), 'transient|THIRD_PARTY_AUTH_ERROR|false|null',
    'an APNs credential problem is retried for that device');
  assert.equal(c(401, { error: { status: 'UNAUTHENTICATED' } }), 'null|UNAUTHENTICATED|true|provider_auth');
  assert.equal(c(403, { error: { status: 'PERMISSION_DENIED' } }), 'null|PERMISSION_DENIED|true|provider_auth');
  assert.equal(c(418, { error: { status: 'lower case' } }), 'rejected|OTHER|false|null');
});

function fakeTransport(script) {
  const calls = [];
  const fetch = async (url, init) => {
    calls.push({ url, init });
    const step = script(url, init, calls.length);
    if (step instanceof Error) throw step;
    return step;
  };
  return { calls, fetch };
}

test('the sender gets one access token, caches it and sends with it', async () => {
  const account = parseServiceAccount(JSON.stringify(ACCOUNT_JSON));
  const endpoints = fcmEndpoints({ projectId: account.projectId, supabaseUrl: 'https://x.supabase.co' });
  const { calls, fetch } = fakeTransport((url) => (url === GOOGLE_TOKEN_URL
    ? reply(200, { access_token: 'ya29.synthetic', expires_in: 3599, token_type: 'Bearer' })
    : reply(200, { name: 'projects/bic-kafue-test/messages/0:1' })));
  const sender = createFcmSender({ account, endpoints, fetch, now: () => 1790000000000 });
  const target = { device_id: DEVICE, platform: 'android', token: TOKEN };
  assert.deepEqual(await sender.send(target, MESSAGE), { result: 'accepted', provider_status: 200, stop: false });
  assert.deepEqual(await sender.send(target, MESSAGE), { result: 'accepted', provider_status: 200, stop: false });
  assert.equal(calls.filter((c) => c.url === GOOGLE_TOKEN_URL).length, 1, 'the access token is cached');
  const tokenCall = new URLSearchParams(calls[0].init.body);
  assert.equal(tokenCall.get('grant_type'), 'urn:ietf:params:oauth:grant-type:jwt-bearer');
  assert.equal(calls[1].url, 'https://fcm.googleapis.com/v1/projects/bic-kafue-test/messages:send');
  assert.equal(calls[1].init.headers.authorization, 'Bearer ya29.synthetic');
  assert.deepEqual(JSON.parse(calls[1].init.body), buildMessage(target, MESSAGE));
});

test('provider failures: invalid token, quota, network, and our own configuration refused', async () => {
  const account = parseServiceAccount(JSON.stringify(ACCOUNT_JSON));
  const endpoints = fcmEndpoints({ projectId: account.projectId, supabaseUrl: 'https://x.supabase.co' });
  const answers = [reply(404, UNREGISTERED_BODY), reply(429, fcmError(429, 'QUOTA_EXCEEDED')),
    new Error('socket hang up'), reply(401, { error: { status: 'UNAUTHENTICATED' } }), reply(403, SENDER_BODY)];
  let tokenCalls = 0;
  const { fetch } = fakeTransport((url) => {
    if (url === GOOGLE_TOKEN_URL) { tokenCalls += 1; return reply(200, { access_token: `ya29.t${tokenCalls}`, expires_in: 3600 }); }
    return answers.shift();
  });
  const sender = createFcmSender({ account, endpoints, fetch, now: () => 1790000000000 });
  const target = { device_id: DEVICE, platform: 'ios', token: TOKEN };
  assert.deepEqual(await sender.send(target, MESSAGE), { result: 'token_invalid', provider_status: 404, provider_code: 'UNREGISTERED', stop: false });
  assert.deepEqual(await sender.send(target, MESSAGE), { result: 'transient', provider_status: 429, provider_code: 'QUOTA_EXCEEDED', stop: true });
  assert.deepEqual(await sender.send(target, MESSAGE), { result: 'transient', provider_code: 'NETWORK', stop: false },
    'a lost answer is transient: the provider may have accepted it');
  await assert.rejects(sender.send(target, MESSAGE), (e) => e instanceof ProviderUnavailable && e.code === 'provider_auth',
    'our own access token refused: nothing to record for the device');
  await assert.rejects(sender.send(target, MESSAGE), (e) => e instanceof ProviderUnavailable && e.code === 'sender_mismatch',
    'a sender mismatch: nothing recorded, no token retired');
  assert.equal(tokenCalls, 2, 'a refused access token is dropped and fetched again');

  const refused = createFcmSender({ account, endpoints, fetch: async () => reply(400, { error: 'invalid_grant' }) });
  await assert.rejects(refused.send(target, MESSAGE), (e) => e instanceof ProviderUnavailable && e.code === 'oauth_refused');
  const unreachable = createFcmSender({ account, endpoints, fetch: async () => { throw new Error('dns'); } });
  await assert.rejects(unreachable.send(target, MESSAGE), (e) => e instanceof ProviderUnavailable && e.code === 'oauth_unreachable');
});
