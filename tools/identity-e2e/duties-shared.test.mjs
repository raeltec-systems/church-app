// Story 4.14: the shared Duties and Follow-ups E2E helpers answer as the copies they replaced
// (offline; no stack needed).
import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  churchClock, churchInstant, churchSunday, genericItemCheck, jsonLiteral, oneWinner, refusedTableQuery,
  sessionClaims, summarize,
} from './duties-shared.mjs';
import * as coverage from './duties-coverage.mjs';
import * as pilot from './duties-pilot.mjs';
import * as reminders from './duties-reminders.mjs';
import * as rota from './duties-rota.mjs';

test('church instants and clocks (UTC+02:00 all year) match both replaced forms', () => {
  assert.equal(churchInstant('2026-10-18', '09:00'), '2026-10-18T07:00:00.000Z');
  assert.equal(churchInstant('2026-10-18', '01:30'), '2026-10-17T23:30:00.000Z');
  for (let d = Date.UTC(2026, 0, 1); d < Date.UTC(2027, 0, 1); d += 86_400_000 * 3 + 3_600_000 * 7) {
    const date = new Date(d).toISOString().slice(0, 10);
    const hhmm = new Date(d).toISOString().slice(11, 16);
    // The 4.8 and 4.13 copies used the zone suffix form.
    assert.equal(churchInstant(date, hhmm), new Date(`${date}T${hhmm}:00+02:00`).toISOString());
    assert.equal(churchClock(churchInstant(date, hhmm)), hhmm);
  }
  assert.throws(() => churchInstant('2026-13-40', '09:00'), RangeError);
});

test('churchSunday is a church Sunday at least four days ahead', () => {
  const now = Date.UTC(2026, 9, 15, 23, 0); // Friday 16 October 01:00 in Lusaka
  assert.equal(churchSunday(now, 0), '2026-10-25');
  assert.equal(churchSunday(now, 2), '2026-11-08');
  assert.equal(new Date(`${churchSunday(Date.UTC(2026, 9, 13, 12), 0)}T00:00:00Z`).getUTCDay(), 0);
});

test('answer predicates', () => {
  assert.equal(oneWinner([{ status: 200 }, { status: 409, code: 'conflict' }]), true);
  assert.equal(oneWinner([{ status: 200 }, { status: 200 }]), false);
  assert.equal(refusedTableQuery({ status: 404, json: { code: 'PGRST' } }), true);
  assert.equal(refusedTableQuery({ status: 200, json: [] }), false);
  assert.equal(summarize(['b', 'a', 'c']), 'a,b,c');
  const generic = genericItemCheck({ k: ['Title', 'Body'] });
  assert.equal(generic({ reminder_kind: 'k', title: 'Title', body: 'Body' }), true);
  assert.equal(generic({ reminder_kind: 'k', title: 'Title', body: 'SYNTHETIC private' }), false);
  assert.equal(generic({ reminder_kind: 'other', title: 'Title', body: 'Body' }), false);
  assert.equal(generic(null), false);
});

test('session claims and jsonb literals', () => {
  const claims = { sub: 'u', session_id: 's' };
  const jwt = `x.${Buffer.from(JSON.stringify(claims)).toString('base64url')}.y`;
  assert.deepEqual(sessionClaims(jwt), claims);
  assert.throws(() => sessionClaims(undefined), /no session token/);
  assert.equal(jsonLiteral({ a: 1 }), '$j${"a":1}$j$::jsonb');
  assert.throws(() => jsonLiteral({ a: '$j$' }), /unexpected quote tag/);
});

test('scripts re-export the shared helpers their tests import', () => {
  assert.equal(rota.churchSunday, churchSunday);
  assert.equal(rota.churchClock, churchClock);
  assert.equal(reminders.churchInstant, churchInstant);
  assert.equal(pilot.churchInstant, churchInstant);
  assert.equal(coverage.summarize, summarize);
  assert.equal(reminders.isGenericDutyItem({ reminder_kind: 'nope' }), false);
  const [kind, [title, body]] = Object.entries(pilot.GENERIC_TEXT)[0];
  assert.equal(pilot.isGenericItem({ reminder_kind: kind, title, body }), true);
});
