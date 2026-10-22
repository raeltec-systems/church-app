import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  CORS_HEADERS,
  MAX_UPLOAD_BYTES,
  bearerFrom,
  commandEnvelope,
  declaredTooLarge,
  declaredTypeMismatch,
  parseRequest,
  planFrom,
  refusal,
  sha256Hex,
  sniffImage,
} from './logic.mjs';

const ID = '00000000-0000-4000-8000-000000062001';
const BASE = 'http://127.0.0.1:54321/functions/v1/content-assets';

/** A minimal PNG header (signature + IHDR) of the given size. */
export function pngHeader(width, height) {
  const b = new Uint8Array(33);
  b.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);
  new DataView(b.buffer).setUint32(16, width);
  new DataView(b.buffer).setUint32(20, height);
  b.set([8, 2, 0, 0, 0], 24);
  return b;
}

/** A minimal baseline JPEG header (SOI, an APP0 segment, SOF0) of the given size. */
export function jpegHeader(width, height) {
  const app0 = [0xff, 0xe0, 0, 16, 0x4a, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0];
  const sof = [0xff, 0xc0, 0, 17, 8, height >> 8, height & 0xff, width >> 8, width & 0xff, 3,
    1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1];
  return new Uint8Array([0xff, 0xd8, ...app0, ...sof, 0xff, 0xd9]);
}

function riff(chunk, payload) {
  const b = new Uint8Array(20 + payload.length);
  b.set([...'RIFF'].map((c) => c.charCodeAt(0)), 0);
  new DataView(b.buffer).setUint32(4, b.length - 8, true);
  b.set([...'WEBP'].map((c) => c.charCodeAt(0)), 8);
  b.set([...chunk].map((c) => c.charCodeAt(0)), 12);
  new DataView(b.buffer).setUint32(16, payload.length, true);
  b.set(payload, 20);
  return b;
}

test('PNG, JPEG and WebP are measured from their bytes', () => {
  assert.deepEqual(sniffImage(pngHeader(1920, 1080)), { type: 'image/png', width: 1920, height: 1080 });
  assert.deepEqual(sniffImage(jpegHeader(1280, 720)), { type: 'image/jpeg', width: 1280, height: 720 });
  const lossy = new Uint8Array(10);
  lossy.set([0, 0, 0, 0x9d, 0x01, 0x2a]);
  new DataView(lossy.buffer).setUint16(6, 1600, true);
  new DataView(lossy.buffer).setUint16(8, 900, true);
  assert.deepEqual(sniffImage(riff('VP8 ', lossy)), { type: 'image/webp', width: 1600, height: 900 });
  const lossless = new Uint8Array(10);
  lossless[0] = 0x2f;
  new DataView(lossless.buffer).setUint32(1, (1999) | (1124 << 14), true);
  assert.deepEqual(sniffImage(riff('VP8L', lossless)), { type: 'image/webp', width: 2000, height: 1125 });
  const extended = new Uint8Array(10);
  extended.set([0, 0, 0, 0, 1279 & 0xff, 1279 >> 8, 0, 719 & 0xff, 719 >> 8, 0]);
  assert.deepEqual(sniffImage(riff('VP8X', extended)), { type: 'image/webp', width: 1280, height: 720 });
});

test('a disguised or unknown file is refused whatever its name or declared type', () => {
  const text = new TextEncoder().encode('<svg xmlns="http://www.w3.org/2000/svg"><script>x</script></svg>');
  assert.deepEqual(sniffImage(text), { error: 'unsupported_type' });
  assert.deepEqual(sniffImage(new TextEncoder().encode('GIF89a......')), { error: 'unsupported_type' });
  assert.deepEqual(sniffImage(new Uint8Array()), { error: 'unsupported_type' });
  assert.deepEqual(sniffImage(new Uint8Array([0x4d, 0x5a, 0x90, 0])), { error: 'unsupported_type' }, 'an executable');
});

test('a right signature with an unreadable header is an invalid image', () => {
  assert.deepEqual(sniffImage(pngHeader(1920, 1080).subarray(0, 20)), { error: 'invalid_image' });
  assert.deepEqual(sniffImage(pngHeader(0, 1080)), { error: 'invalid_image' });
  assert.deepEqual(sniffImage(new Uint8Array([0xff, 0xd8, 0xff, 0xd9, 0, 0])), { error: 'invalid_image' });
  assert.deepEqual(sniffImage(new Uint8Array([0xff, 0xd8, 0xff, 0xda, 0, 4, 0, 0])), { error: 'invalid_image' },
    'scan data before any frame header');
  assert.deepEqual(sniffImage(riff('VP8 ', new Uint8Array(10))), { error: 'invalid_image' });
  assert.deepEqual(sniffImage(riff('ALPH', new Uint8Array(10))), { error: 'invalid_image' });
});

test('a declared type that contradicts the bytes is a mismatch; no declaration claims nothing', () => {
  assert.equal(declaredTypeMismatch('image/png', 'image/jpeg'), true);
  assert.equal(declaredTypeMismatch('image/png; charset=binary', 'image/png'), false);
  assert.equal(declaredTypeMismatch('IMAGE/JPG', 'image/jpeg'), false);
  assert.equal(declaredTypeMismatch('', 'image/webp'), false);
  assert.equal(declaredTypeMismatch(null, 'image/webp'), false);
  assert.equal(declaredTypeMismatch('application/octet-stream', 'image/png'), false);
  assert.equal(declaredTypeMismatch('text/html', 'image/png'), true);
});

test('requests: three actions, each with exactly its parameters and method', () => {
  assert.deepEqual(parseRequest('POST', `${BASE}?action=upload&item_id=${ID}&purpose=banner_image`),
    { ok: true, value: { action: 'upload', itemId: ID, purpose: 'banner_image' } });
  assert.deepEqual(parseRequest('POST', `${BASE}?action=sync`), { ok: true, value: { action: 'sync' } });
  assert.deepEqual(parseRequest('GET', `${BASE}?action=preview&asset_id=${ID}`),
    { ok: true, value: { action: 'preview', assetId: ID } });
  assert.equal(parseRequest('GET', `${BASE}?action=upload&item_id=${ID}&purpose=banner_image`).error, 'method');
  assert.equal(parseRequest('POST', `${BASE}?action=upload&item_id=x&purpose=banner_image`).error, 'invalid_item_id');
  assert.equal(parseRequest('POST', `${BASE}?action=upload&item_id=${ID}&purpose=Banner`).error, 'invalid_purpose');
  assert.equal(parseRequest('POST', `${BASE}?action=upload&item_id=${ID}&purpose=banner_image&public=1`).error,
    'unknown_parameter');
  assert.equal(parseRequest('POST', `${BASE}?action=sync&bucket=content-public`).error, 'unknown_parameter');
  assert.equal(parseRequest('GET', `${BASE}?action=preview&asset_id=../x`).error, 'invalid_asset_id');
  assert.equal(parseRequest('POST', `${BASE}?action=delete`).error, 'invalid_action');
  assert.equal(parseRequest('POST', 'not a url').error, 'invalid_url');
});

test('only a bearer token is accepted as the caller', () => {
  const jwt = `Bearer ${'eyJ'.padEnd(40, 'a')}.${'b'.repeat(30)}.${'c'.repeat(30)}`;
  assert.equal(bearerFrom(jwt), jwt);
  assert.equal(bearerFrom(null), null);
  assert.equal(bearerFrom('Basic abc'), null);
  assert.equal(bearerFrom('Bearer short'), null);
  assert.equal(bearerFrom('Bearer a b c d e f g h i j k l m'), null);
});

test('size: the declared length and the 10 MiB body cap', () => {
  assert.equal(MAX_UPLOAD_BYTES, 10485760);
  assert.equal(declaredTooLarge('10485760'), false);
  assert.equal(declaredTooLarge('10485761'), true);
  assert.equal(declaredTooLarge('12abc'), true);
  assert.equal(declaredTooLarge(null), false);
});

test('database refusals map to statuses carrying only codes', () => {
  assert.deepEqual(refusal({ code: 'forbidden', message: 'x' }), { status: 403, body: { outcome: 'forbidden' } });
  assert.deepEqual(refusal({ code: 'unauthenticated' }), { status: 401, body: { outcome: 'unauthenticated' } });
  assert.deepEqual(refusal({ code: 'validation_failed', field_errors: { byte_size: 'too_large' } }),
    { status: 413, body: { outcome: 'refused', code: 'validation_failed', field_errors: { byte_size: 'too_large' } } });
  assert.deepEqual(refusal({ code: 'validation_failed', field_errors: { width: 'too_small', height: 'too_small', 'Bad Key': 'x' } }),
    { status: 422, body: { outcome: 'refused', code: 'validation_failed', field_errors: { width: 'too_small', height: 'too_small' } } });
  assert.equal(refusal({ code: 'conflict' }).status, 409);
  assert.deepEqual(refusal({ code: 'unavailable' }), { status: 503, body: { outcome: 'unavailable' } });
  assert.deepEqual(refusal(null), { status: 503, body: { outcome: 'unavailable' } });
});

test('a sync plan keeps only well-formed entries', () => {
  const pub = `banner/${ID}/r2/image.png`;
  const draft = `${ID}.png`;
  const plan = planFrom({
    place: [{ public_path: pub, draft_path: draft, media_type: 'image/png' },
      { public_path: '../etc/passwd', draft_path: draft, media_type: 'image/png' },
      { public_path: pub, draft_path: 'x/../../y', media_type: 'image/png' },
      { public_path: pub, draft_path: draft, media_type: 'text/html' }],
    remove: [`banner/${ID}/r1/image.png`, '.emptyFolderPlaceholder', '../escape', 42],
    waiting: 3,
    removals_pending: -1,
  });
  assert.deepEqual(plan, {
    place: [{ public_path: pub, draft_path: draft, media_type: 'image/png' }],
    remove: [`banner/${ID}/r1/image.png`, '.emptyFolderPlaceholder'],
    waiting: 3,
    removals_pending: 0,
  });
  assert.deepEqual(planFrom(null), { place: [], remove: [], waiting: 0, removals_pending: 0 });
});

test('uploads are creates (expected null); CORS allows staff web without cookies', async () => {
  assert.deepEqual(commandEnvelope('content.begin_asset_upload', { a: 1 }, ID),
    { version: 1, command: 'content.begin_asset_upload', request_id: ID, expected_revision: null, payload: { a: 1 } });
  assert.equal(CORS_HEADERS['access-control-allow-origin'], '*');
  assert.equal('access-control-allow-credentials' in CORS_HEADERS, false);
  assert.match(CORS_HEADERS['access-control-allow-headers'], /authorization/);
  assert.equal(await sha256Hex(new TextEncoder().encode('abc')),
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
});
