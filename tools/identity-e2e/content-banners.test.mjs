import assert from 'node:assert/strict';
import { test } from 'node:test';

import { sniffImage } from '../../supabase/functions/content-assets/logic.mjs';
import { CAMPAIGN, PUBLIC_KEYS, THEME, crc32, findBanner, isFictionalBannerPhone, sha256, solidPng } from './content-banners.mjs';

test('only the reserved fictional block +44 7700 900501-900509 is used', () => {
  assert.equal(isFictionalBannerPhone('+447700900501'), true);
  assert.equal(isFictionalBannerPhone('+447700900509'), true);
  assert.equal(isFictionalBannerPhone('+447700900500'), false);
  assert.equal(isFictionalBannerPhone('+447700900510'), false);
  assert.equal(isFictionalBannerPhone('+447700900101'), false);
});

test('the generated images are real PNGs the function measures', () => {
  assert.equal(crc32(Buffer.from('123456789')), 0xcbf43926);
  const png = solidPng(1920, 1080, [20, 36, 107]);
  assert.deepEqual(sniffImage(png), { type: 'image/png', width: 1920, height: 1080 });
  assert.ok(png.length < 64 * 1024, 'a solid colour compresses to a small file');
  const padded = solidPng(1920, 1080, [1, 2, 3], 6 * 1024 * 1024);
  assert.equal(padded.length, 6 * 1024 * 1024);
  assert.deepEqual(sniffImage(padded), { type: 'image/png', width: 1920, height: 1080 });
  assert.notEqual(sha256(png), sha256(solidPng(1920, 1080, [20, 36, 108])));
});

test('names are SYNTHETIC and the public projection keys are sorted', () => {
  assert.match(THEME, /^SYNTHETIC Theme 2026 /);
  assert.match(CAMPAIGN, /^SYNTHETIC /);
  assert.deepEqual([...PUBLIC_KEYS].sort(), PUBLIC_KEYS);
  assert.equal(findBanner({ banners: [{ banner_id: 'a' }, { banner_id: 'b' }] }, 'b').banner_id, 'b');
  assert.equal(findBanner(null, 'b'), undefined);
  assert.ok(PUBLIC_KEYS.includes('offline_allowed'));
});
