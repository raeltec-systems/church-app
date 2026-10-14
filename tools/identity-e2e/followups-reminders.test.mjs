import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  DEPARTMENT, GENERIC_TEXT, PURPOSE, REPORT_PURPOSE, SOURCE_TYPE, isFictionalRemindersPhone, isGenericFollowupItem,
  summarize, taskLink,
} from './followups-reminders.mjs';

test('only the reserved fictional numbers of this run are accepted', () => {
  for (const p of ['+447700900370', '+447700900379']) assert.equal(isFictionalRemindersPhone(p), true);
  for (const p of ['+447700900369', '+447700900380', '+12025550370', '447700900370']) {
    assert.equal(isFictionalRemindersPhone(p), false);
  }
});

test('the department, source and purposes are the synthetic stand-ins', () => {
  assert.match(DEPARTMENT, /^SYNTHETIC /);
  assert.equal(SOURCE_TYPE, 'fixture_followup');
  assert.equal(PURPOSE, 'synthetic_check_in');
  assert.equal(REPORT_PURPOSE, 'synthetic_report_due');
});

test('a follow-up reminder links to the task only', () => {
  assert.equal(taskLink('abc'), '/followups/tasks/abc');
});

test('only the exact generic text of a follow-up kind passes', () => {
  for (const [kind, [title, body]] of Object.entries(GENERIC_TEXT)) {
    assert.equal(isGenericFollowupItem({ reminder_kind: kind, title, body }), true);
    assert.equal(isGenericFollowupItem({ reminder_kind: kind, title, body: `${body} SYNTHETIC: call X` }), false);
  }
  assert.equal(isGenericFollowupItem({ reminder_kind: 'duty_assigned', title: 'x', body: 'y' }), false);
  assert.equal(isGenericFollowupItem(null), false);
  for (const [title, body] of Object.values(GENERIC_TEXT)) {
    assert.doesNotMatch(title + body, /SYNTHETIC|[{}<>@]|\d{3}/);
  }
});

test('the pending summary is order independent', () => {
  assert.equal(summarize(['b@x', 'a@y']), 'a@y,b@x');
  assert.equal(summarize([]), '');
});
