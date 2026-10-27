import assert from 'node:assert/strict';
import { test } from 'node:test';

import { CAMP, CONFERENCE, LAST_SEAT, PUBLIC_KEYS, RSVP_KEYS, isFictionalRsvpPhone, raceTally } from './content-event-rsvp.mjs';

test('only the reserved fictional block +44 7700 900584-900598 is used', () => {
  assert.equal(isFictionalRsvpPhone('+447700900584'), true);
  assert.equal(isFictionalRsvpPhone('+447700900589'), true);
  assert.equal(isFictionalRsvpPhone('+447700900590'), true);
  assert.equal(isFictionalRsvpPhone('+447700900598'), true);
  assert.equal(isFictionalRsvpPhone('+447700900583'), false);
  assert.equal(isFictionalRsvpPhone('+447700900599'), false);
  assert.equal(isFictionalRsvpPhone('+447700900501'), false);
});

test('a race tally counts going, full and anything else', () => {
  const full = { code: 'validation_failed', field_errors: { event_id: 'full' } };
  assert.deepEqual(raceTally([{ data: { rsvp_state: 'going' } }, full, full]), { going: 1, full: 2, other: 0 });
  assert.deepEqual(raceTally([{ code: 'unavailable' }, full]), { going: 0, full: 1, other: 1 });
  assert.deepEqual(raceTally([]), { going: 0, full: 0, other: 0 });
});

test('names are SYNTHETIC and the public keys are sorted, counts only', () => {
  for (const t of [CAMP, CONFERENCE, LAST_SEAT]) assert.match(t, /^SYNTHETIC /);
  assert.deepEqual([...PUBLIC_KEYS].sort(), PUBLIC_KEYS);
  assert.deepEqual([...RSVP_KEYS].sort(), RSVP_KEYS);
  assert.ok(PUBLIC_KEYS.includes('poster') && PUBLIC_KEYS.includes('rsvp'));
  assert.ok(!RSVP_KEYS.some((k) => /name|member/.test(k)), 'the public RSVP names nobody');
});
