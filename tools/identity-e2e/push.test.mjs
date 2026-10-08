import assert from 'node:assert/strict';
import { test } from 'node:test';

import { isFictionalPushPhone, isGenericMessage, leaks, syntheticDeviceToken } from './push.mjs';

const ITEM = '00000000-0000-4000-8000-000000036001';
const generic = (token) => ({
  message: {
    token,
    notification: { title: 'T', body: 'B' },
    data: { item_id: ITEM },
    android: { ttl: '60s', collapse_key: ITEM, priority: 'high', notification: { tag: ITEM } },
    apns: { headers: { 'apns-expiration': '1791000000', 'apns-collapse-id': ITEM, 'apns-priority': '10', 'apns-push-type': 'alert' },
      payload: { aps: { sound: 'default' } } },
  },
});

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900910', '+447700900919']) assert.equal(isFictionalPushPhone(p), true);
  for (const p of ['+447700900909', '+447700900920', '447700900910']) assert.equal(isFictionalPushPhone(p), false);
});

test('synthetic device tokens have the stored shape and differ each time', () => {
  const a = syntheticDeviceToken();
  assert.match(a, /^[A-Za-z0-9_:.-]{20,4096}$/);
  assert.notEqual(a, syntheticDeviceToken());
});

test('a generic message carries only the fixed text and the item id', () => {
  const token = syntheticDeviceToken();
  const expect = { token, itemId: ITEM, title: 'T', text: 'B' };
  assert.equal(isGenericMessage(generic(token), expect), true);
  const extra = generic(token);
  extra.message.data.source_id = 'x';
  assert.equal(isGenericMessage(extra, expect), false, 'no other data');
  const text = generic(token);
  text.message.notification.body = 'Private visit note';
  assert.equal(isGenericMessage(text, expect), false, 'no other text');
  const collapse = generic(token);
  collapse.message.android.collapse_key = 'other';
  assert.equal(isGenericMessage(collapse, expect), false, 'the item id is the collapse id');
  const top = generic(token);
  top.message.webpush = {};
  assert.equal(isGenericMessage(top, expect), false);
});

test('leaks lists only the values found in the text', () => {
  assert.deepEqual(leaks('{"accepted":1}', ['secret', null]), []);
  assert.deepEqual(leaks('x tok-1 y', ['secret', 'tok-1']), ['tok-1']);
});
