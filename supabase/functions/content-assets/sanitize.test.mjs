// The content-assets sanitiser (story 6.2 review): only a structurally complete PNG, JPEG or WebP
// is kept, without metadata or anything appended after its end.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { deflateSync } from 'node:zlib';

import { crc32, pngDataLength, sanitizeImage } from './logic.mjs';
import { jpegHeader, pngHeader } from './test-fixtures.mjs';

const NUL = String.fromCharCode(0);

function pngChunk(type, data) {
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, 'latin1');
  Buffer.from(data).copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
}

/** A complete RGB PNG, with optional extra chunks before IDAT and bytes after IEND. */
function fullPng(width, height, { extra = [], trailing = Buffer.alloc(0), rows = height } = {}) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr.set([8, 2, 0, 0, 0], 8);
  const raw = Buffer.alloc(rows * (1 + width * 3), 7);
  for (let y = 0; y < rows; y++) raw[y * (1 + width * 3)] = 0;
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), pngChunk('IHDR', ihdr),
    ...extra, pngChunk('IDAT', deflateSync(raw)), pngChunk('IEND', Buffer.alloc(0)), trailing]);
}

const has = (bytes, text) => Buffer.from(bytes).includes(Buffer.from(text, 'latin1'));

test('a complete PNG keeps its pixels; text chunks and appended bytes are dropped', async () => {
  const polyglot = fullPng(1280, 720, {
    extra: [pngChunk('tEXt', Buffer.from(`Comment${NUL}SYNTHETIC-GPS 15.4S 28.2E`, 'latin1')),
      pngChunk('pHYs', Buffer.from([0, 0, 11, 19, 0, 0, 11, 19, 1]))],
    trailing: Buffer.from('<html><script>alert(1)</script></html>'),
  });
  const r = await sanitizeImage(polyglot);
  assert.equal(r.type, 'image/png');
  assert.deepEqual([r.width, r.height], [1280, 720]);
  assert.equal(has(r.bytes, 'SYNTHETIC-GPS'), false, 'the text chunk is dropped');
  assert.equal(has(r.bytes, '<script>'), false, 'the appended HTML is dropped');
  assert.equal(has(r.bytes, 'pHYs'), true, 'size meaning is kept');
  assert.equal(Buffer.from(r.bytes.subarray(r.bytes.length - 8, r.bytes.length - 4)).toString('latin1'), 'IEND');
  const again = await sanitizeImage(r.bytes);
  assert.deepEqual(Buffer.from(again.bytes), Buffer.from(r.bytes), 'sanitising is stable');
});

test('a PNG header alone, a truncated, corrupted or short PNG is an invalid image', async () => {
  assert.deepEqual(await sanitizeImage(pngHeader(1920, 1080)), { error: 'invalid_image' });
  const good = fullPng(1280, 720);
  assert.deepEqual(await sanitizeImage(good.subarray(0, good.length - 20)), { error: 'invalid_image' });
  const flipped = Buffer.from(good);
  flipped[40] ^= 0xff;
  assert.deepEqual(await sanitizeImage(flipped), { error: 'invalid_image' }, 'a bad checksum');
  assert.deepEqual(await sanitizeImage(fullPng(1280, 720, { rows: 719 })), { error: 'invalid_image' },
    'pixel data for fewer rows than the header claims');
  assert.deepEqual(await sanitizeImage(pngHeader(7000, 7000)), { error: 'too_large' }, 'an area over 6000 x 6000');
  assert.equal(pngDataLength(1920, 1080, 24, false), 1080 * (1 + 5760));
  assert.equal(pngDataLength(1, 1, 24, true), 4, 'one pixel interlaced is one row in the first pass');
});

/** A structurally complete baseline JPEG with optional Exif, a comment and bytes after its end. */
function fullJpeg({ exif = true, comment = true, scan = true, end = true, trailing = '' } = {}) {
  const seg = (marker, payload) => [0xff, marker, (payload.length + 2) >> 8, (payload.length + 2) & 0xff, ...payload];
  const text = (s) => [...Buffer.from(s, 'latin1')];
  return Buffer.from([0xff, 0xd8,
    ...seg(0xe0, [...text(`JFIF${NUL}`), 1, 1, 0, 0, 1, 0, 1, 0, 0]),
    ...(exif ? seg(0xe1, text(`Exif${NUL}${NUL}SYNTHETIC-GPS 15.4S 28.2E SERIAL-0000`)) : []),
    ...(comment ? seg(0xfe, text('SYNTHETIC comment')) : []),
    ...seg(0xdb, [0, ...Array(64).fill(1)]),
    ...seg(0xc0, [8, 0x02, 0xd0, 0x05, 0x00, 3, 1, 0x22, 0, 2, 0x11, 0, 3, 0x11, 0]),
    ...seg(0xc4, [0, 1, ...Array(15).fill(0), 0]),
    ...(scan ? [...seg(0xda, [3, 1, 0, 2, 0x11, 3, 0x11, 0, 0x3f, 0]), 0x12, 0x34, 0xff, 0x00, 0x56, 0xff, 0xd0, 0x78] : []),
    ...(end ? [0xff, 0xd9] : []), ...text(trailing)]);
}

test('a JPEG keeps its frame and scans; Exif, comments and appended bytes are dropped', async () => {
  const r = await sanitizeImage(fullJpeg({ trailing: 'MOTION-PHOTO-SYNTHETIC' }));
  assert.equal(r.type, 'image/jpeg');
  assert.deepEqual([r.width, r.height], [1280, 720]);
  for (const t of ['Exif', 'SYNTHETIC-GPS', 'SYNTHETIC comment', 'MOTION-PHOTO']) assert.equal(has(r.bytes, t), false, t);
  assert.equal(has(r.bytes, 'JFIF'), true);
  assert.deepEqual([...r.bytes.subarray(r.bytes.length - 2)], [0xff, 0xd9]);
  assert.ok(Buffer.from(r.bytes).includes(Buffer.from([0x12, 0x34, 0xff, 0x00, 0x56, 0xff, 0xd0, 0x78])),
    'the scan data is kept byte for byte');
  assert.deepEqual(await sanitizeImage(fullJpeg({ scan: false })), { error: 'invalid_image' }, 'no image data');
  assert.deepEqual(await sanitizeImage(fullJpeg({ end: false })), { error: 'invalid_image' }, 'no end of image');
  assert.deepEqual(await sanitizeImage(jpegHeader(1280, 720)), { error: 'invalid_image' }, 'a header alone');
});

function webpFile(chunks, trailing = Buffer.alloc(0)) {
  const body = Buffer.concat(chunks.map(([fourcc, payload]) => {
    const head = Buffer.alloc(8);
    head.write(fourcc, 0, 'latin1');
    head.writeUInt32LE(payload.length, 4);
    return Buffer.concat([head, Buffer.from(payload), Buffer.alloc(payload.length % 2)]);
  }));
  const head = Buffer.alloc(12);
  head.write('RIFF', 0, 'latin1');
  head.writeUInt32LE(4 + body.length, 4);
  head.write('WEBP', 8, 'latin1');
  return Buffer.concat([head, body, trailing]);
}

const vp8 = (w, h) => {
  const p = Buffer.alloc(30, 3);
  p.set([0x10, 0x02, 0x00, 0x9d, 0x01, 0x2a]);
  p.writeUInt16LE(w, 6);
  p.writeUInt16LE(h, 8);
  return p;
};
const vp8x = (flags, w, h) => {
  const p = Buffer.alloc(10);
  p[0] = flags;
  p.writeUIntLE(w - 1, 4, 3);
  p.writeUIntLE(h - 1, 7, 3);
  return p;
};

test('a WebP keeps its image; Exif, XMP and appended bytes are dropped; animation is refused', async () => {
  const simple = await sanitizeImage(webpFile([['VP8 ', vp8(1600, 900)]], Buffer.from('<html>')));
  assert.deepEqual([simple.type, simple.width, simple.height], ['image/webp', 1600, 900]);
  assert.equal(has(simple.bytes, '<html>'), false);
  const extended = await sanitizeImage(webpFile([['VP8X', vp8x(0x08 | 0x04, 1600, 900)], ['VP8 ', vp8(1600, 900)],
    ['EXIF', Buffer.from('SYNTHETIC-GPS 15.4S')], ['XMP ', Buffer.from('<x:xmpmeta>SYNTHETIC</x:xmpmeta>')]]));
  assert.equal(extended.type, 'image/webp');
  assert.equal(has(extended.bytes, 'SYNTHETIC'), false, 'Exif and XMP are dropped');
  assert.equal(extended.bytes[20] & 0x0c, 0, 'and their flags cleared');
  assert.equal(Buffer.from(extended.bytes).readUInt32LE(4), extended.bytes.length - 8, 'the RIFF size is rewritten');
  assert.deepEqual(await sanitizeImage(webpFile([['VP8X', vp8x(0, 1600, 900)]])), { error: 'invalid_image' },
    'a header with no image');
  assert.deepEqual(await sanitizeImage(webpFile([['VP8X', vp8x(0x02, 1600, 900)], ['ANIM', Buffer.alloc(6)],
    ['ANMF', Buffer.alloc(20)], ['VP8 ', vp8(1600, 900)]])), { error: 'unsupported_type' }, 'animation');
});
