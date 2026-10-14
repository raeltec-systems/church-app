import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  DEPARTMENT, GENERIC_TEXT, churchInstant, defaultBeforeStartHours, isFictionalDutyRemindersPhone, isGenericDutyItem,
  summarize,
} from './duties-reminders.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900670', '+447700900679']) assert.equal(isFictionalDutyRemindersPhone(p), true);
  for (const p of ['+447700900669', '+447700900680', '+12025550670', '447700900670']) {
    assert.equal(isFictionalDutyRemindersPhone(p), false);
  }
});

test('the department is the synthetic stand-in', () => {
  assert.equal(DEPARTMENT, 'SYNTHETIC Preaching Rota');
});

test('only the exact generic text of a duty kind passes', () => {
  for (const [kind, [title, body]] of Object.entries(GENERIC_TEXT)) {
    assert.equal(isGenericDutyItem({ reminder_kind: kind, title, body }), true);
    assert.equal(isGenericDutyItem({ reminder_kind: kind, title, body: `${body} SYNTHETIC Main hall` }), false);
    assert.ok(title.length <= 60 && body.length <= 160, kind);
  }
  assert.equal(isGenericDutyItem({ reminder_kind: 'followup_due', title: 'x', body: 'y' }), false);
  assert.equal(isGenericDutyItem(null), false);
  for (const [title, body] of Object.values(GENERIC_TEXT)) {
    assert.doesNotMatch(title + body, /SYNTHETIC|[{}<>@]|\d{3}/);
  }
});

test('the Q2 fixture bands: 14 days, 48 hours, otherwise 24 hours (short notice when passed)', () => {
  const H = 3_600_000;
  assert.equal(defaultBeforeStartHours(90 * 24 * H), 336);
  assert.equal(defaultBeforeStartHours(30 * 24 * H), 336);
  assert.equal(defaultBeforeStartHours(30 * 24 * H - 1), 48);
  assert.equal(defaultBeforeStartHours(4 * 24 * H), 48);
  assert.equal(defaultBeforeStartHours(72 * H), 48);
  assert.equal(defaultBeforeStartHours(6 * H), 24);
});

test('church instants are Lusaka time (UTC+2) whatever the machine zone', () => {
  assert.equal(churchInstant('2099-01-03', '23:30'), '2099-01-03T21:30:00.000Z');
  assert.equal(churchInstant('2099-01-04', '00:30'), '2099-01-03T22:30:00.000Z');
});

test('the pending summary is order independent', () => {
  assert.equal(summarize(['m:b', 'l:a']), 'l:a,m:b');
  assert.equal(summarize([]), '');
});
