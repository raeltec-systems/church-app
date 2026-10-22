import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  BANK, MOBILE, PUBLIC_KEYS, bankPayload, churchDaysAgo, detail, findMethod, isFictionalGivingPhone, mobilePayload,
  savePayload, sortedKeys,
} from './content-giving.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900510', '+447700900518']) assert.equal(isFictionalGivingPhone(p), true);
  for (const p of ['+447700900509', '+447700900519', '+447700900520', '+12025550181', '447700900510']) {
    assert.equal(isFictionalGivingPhone(p), false);
  }
});

test('every method is a SAMPLE, as the q3 fixture requires', () => {
  assert.match(MOBILE, /^SAMPLE /);
  assert.match(BANK, /^SAMPLE /);
});

test('the payloads carry no amount or payer field and none of the prototype values', () => {
  const text = JSON.stringify([mobilePayload(MOBILE), bankPayload(BANK, '9900 1234 5678')]);
  for (const banned of ['amount', 'payer', 'donor', 'proof', 'transaction', 'gift_', 'receipt', 'sender']) {
    assert.equal(text.includes(banned), false, banned);
  }
  assert.equal(text.includes('"000000"'), false);
  assert.equal(text.includes('*000#'), false);
});

test('a save payload drops the type and names the method', () => {
  const saved = savePayload('m1', bankPayload(BANK, '9900 1234 5678'));
  assert.equal(saved.method_id, 'm1');
  assert.equal('method_type' in saved, false);
  assert.equal(saved.account_number, '9900 1234 5678');
});

test('church dates are Lusaka dates (UTC+2)', () => {
  // 2099-01-03 23:30 UTC is already Sunday 4 January in Lusaka.
  const now = Date.parse('2099-01-03T23:30:00Z');
  assert.equal(churchDaysAgo(now, 0), '2099-01-04');
  assert.equal(churchDaysAgo(now, 2), '2099-01-02');
});

test('the public projection keys are compared sorted', () => {
  assert.deepEqual(PUBLIC_KEYS, [...PUBLIC_KEYS].sort());
  assert.deepEqual(sortedKeys({ name: 1, method_id: 2 }), ['method_id', 'name']);
  assert.deepEqual(sortedKeys(undefined), []);
});

test('a method and its copyable values are found by key', () => {
  const list = { methods: [{ method_id: 'a', details: [{ key: 'merchant_id', value: '990177' }] }, { method_id: 'b' }] };
  assert.equal(detail(findMethod(list, 'a'), 'merchant_id'), '990177');
  assert.equal(detail(findMethod(list, 'b'), 'merchant_id'), undefined);
  assert.equal(findMethod(null, 'a'), undefined);
});
