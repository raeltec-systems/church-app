// Story 6.12: duties linked to published events. The wire parsing (the
// duty's and the rota date's event_ref, the editors' linked-duty count), the
// rota edit payloads (a link is a reference: nobody is asked again), the staff
// rota (the event a date names, the published-event picker, the refusal of an
// unpublished event), the member's duty detail (the event, opened from the
// duty; an event no longer public; a failed read) and the staff Events editor
// (the linked-duty count shown before a change, also in the withdraw
// question). Fakes only; the server behaviour is covered by
// supabase/tests/content_event_duty_links_test.sql and
// tools/identity-e2e/content-event-duty-links.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'duties_rota_test.dart'
    show assignment, byKey, occurrence, position, rotaWith, settle;

const _o1 = '51515151-5151-4151-8151-515151515151';
const _series = '50505050-5050-4050-8050-505050505050';
const _sunday = '61616161-6161-4161-8161-616161616161';
const _youth = '62626262-6262-4262-8262-626262626262';
const _asg = '42424242-4242-4242-8242-424242424242';

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? setUp,
  bool staff = true,
}) async {
  tester.view.physicalSize = Size(staff ? 1400 : 390, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = ClientTestHarness();
  setUp?.call(h);
  final router = buildClientRouter(
    initialLocation: location,
    memberHome: !staff,
    shell: (_, _, child) => AccessRefresher(child: child),
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: h.overrides(),
      child: MaterialApp.router(
        theme: staff ? churchStaffTheme() : churchMobileTheme(Brightness.light),
        routerConfig: router,
      ),
    ),
  );
  await settle(tester);
  return h;
}

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(byKey(key));
  await tester.tap(byKey(key));
  await settle(tester);
}

String textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(byKey(key)).data!;

AccessRead<PublicEvents> _published() => AccessReadOk(
  PublicEvents.fromJson(
    publicEventsData([
      publicEventData(
        eventId: _sunday,
        title: 'SYNTHETIC Sunday service',
        startsAt: '2099-01-04T07:00:00.000000Z',
        endsAt: '2099-01-04T09:00:00.000000Z',
      ),
    ]),
  ),
);

Map<String, Object?> _linked(String id, String? eventRef) => {
  ...occurrence(
    id,
    state: 'published',
    revision: 4,
    confirmed: 1,
    positions: [
      position(id, 1, 'Preacher', assignment: assignment('accepted')),
      position(id, 2, 'Reader'),
      position(id, 3, 'Usher'),
    ],
  ),
  'event_ref': eventRef,
};

void main() {
  group('wire', () {
    test('a duty and a rota date carry their linked event', () {
      final mine = MyDuty.fromJson({...myDutyData(), 'event_ref': _sunday});
      expect(mine.eventRef, _sunday);
      expect(MyDuty.fromJson(myDutyData()).eventRef, isNull);
      expect(RotaOccurrence.fromJson(_linked(_o1, _sunday)).eventRef, _sunday);
    });

    test('a link is a reference: no answer-by, nobody asked again', () {
      final o = RotaOccurrence.fromJson(_linked(_o1, null));
      RotaEdit edit(String? ref) => RotaEdit(
        occurrence: o,
        dutyName: o.dutyName,
        startTime: RotaEdit.hm(o.times.startsAt),
        location: o.location,
        eventRef: ref,
        lead: '1 day',
      );
      expect(edit(_sunday).changed, [DutyFields.eventRef]);
      expect(edit(_sunday).material, isFalse);
      expect(edit(_sunday).needsLead, isFalse);
      expect(edit(_sunday).thisPayload(), {
        'occurrence_id': _o1,
        'event_ref': _sunday,
      });
      expect(edit(_sunday).futurePayload(_series), {
        'series_id': _series,
        'from_occurrence_id': _o1,
        'event_ref': _sunday,
      });
      expect(edit(null).changed, isEmpty);
      final kept = RotaEdit(
        occurrence: RotaOccurrence.fromJson(_linked(_o1, _sunday)),
        dutyName: o.dutyName,
        startTime: RotaEdit.hm(o.times.startsAt),
        location: o.location,
      );
      expect(kept.changed, isEmpty, reason: 'left alone, the link is kept');
      expect(DutyFields.describe([DutyFields.eventRef]), 'linked event');
    });

    test('the editors\' count: counts only, with a plain line', () {
      final l = EventDutyLinks.fromJson({
        'event_id': _sunday,
        'linked_duties': 2,
        'reviews_open': 1,
        'truncated': false,
      });
      expect(
        l.notice,
        '2 duties are linked to this event. Publishing a new time or place, '
        'or withdrawing it, asks their leaders to review them.',
      );
      expect(
        EventDutyLinks(eventId: _sunday, linkedDuties: 1).notice,
        startsWith('1 duty is linked'),
      );
      expect(
        EventDutyLinks(
          eventId: _sunday,
          linkedDuties: 200,
          truncated: true,
        ).notice,
        startsWith('200 or more duties are linked'),
      );
      expect(EventDutyLinks(eventId: _sunday, linkedDuties: 0).notice, isNull);
      final unknown = EventDutyLinks.fromJson({
        'event_id': _sunday,
        'linked_duties': null,
      });
      expect(unknown.linkedDuties, isNull);
      expect(unknown.notice, isNull);
      expect(
        () =>
            EventDutyLinks.fromJson({'event_id': _sunday, 'linked_duties': -1}),
        throwsFormatException,
      );
    });
  });

  group('staff web rota', () {
    testWidgets('a date shows its event; the picker links a published one', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyRota,
        setUp: (h) {
          h.duties.rota = rotaWith(draftSlots: 0, revision: 3, [
            _linked(_o1, _youth),
          ]);
          h.content.publicEvents = _published();
          h.content.publicEvent[_youth] = AccessReadOk(
            PublicEventRead.fromJson(const {'event': null}),
          );
        },
      );
      await tapKey(tester, 'rota-date-$_o1');
      expect(
        textOf(tester, 'rota-event-$_o1'),
        'Event: no longer on the public calendar',
      );
      await tapKey(tester, 'rota-change-$_o1');
      await tester.ensureVisible(byKey('rota-edit-event-$_o1'));
      await tester.tap(byKey('rota-edit-event-$_o1'));
      await settle(tester);
      // The published event, nothing for an event that is no longer public
      // except the current link (kept or removed).
      expect(find.text('The linked event (no longer public)'), findsWidgets);
      await tester.tap(find.textContaining('SYNTHETIC Sunday service').last);
      await settle(tester);
      expect(
        find.text('Only linked event change: answers stand.'),
        findsOneWidget,
      );
      await tapKey(tester, 'rota-edit-save-$_o1');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'duties.revise_duty');
      expect(sent.wire['expected_revision'], 4);
      expect(sent.wire['payload'], {
        'occurrence_id': _o1,
        'event_ref': _sunday,
      });
      sent.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'event_ref': 'not_published'},
      );
      await settle(tester);
      expect(
        find.text(
          'That event is not on the public calendar: choose a published event',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a date names its published event; a failed list says so', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.dutyRota,
        setUp: (h) {
          h.duties.rota = rotaWith(draftSlots: 0, [_linked(_o1, _sunday)]);
          h.content.publicEvents = const AccessReadDenied(
            AccessDenial.unavailable,
          );
          h.content.publicEvent[_sunday] = AccessReadOk(
            PublicEventRead.fromJson({
              'event': publicEventData(
                eventId: _sunday,
                title: 'SYNTHETIC Sunday service',
              ),
            }),
          );
        },
      );
      await tapKey(tester, 'rota-date-$_o1');
      expect(
        textOf(tester, 'rota-event-$_o1'),
        startsWith('Event: SYNTHETIC Sunday service · '),
      );
      await tapKey(tester, 'rota-change-$_o1');
      expect(byKey('rota-edit-event-failed-$_o1'), findsOneWidget);
    });
  });

  group('mobile duty detail', () {
    void mine(ClientTestHarness h) => h.duties.mine = AccessReadOk(
      MyDuties.fromJson({
        'member_id': '66666666-6666-4666-8666-666666666666',
        'assignments': [
          {...myDutyData(), 'event_ref': _sunday},
        ],
      }),
    );

    testWidgets('the duty shows its event and opens it', (tester) async {
      await pumpAt(
        tester,
        DutyPaths.assignment(_asg),
        staff: false,
        setUp: (h) {
          mine(h);
          h.content.publicEvent[_sunday] = AccessReadOk(
            PublicEventRead.fromJson({
              'event': publicEventData(
                eventId: _sunday,
                title: 'SYNTHETIC Sunday service',
              ),
            }),
          );
        },
      );
      expect(byKey('duty-event-$_asg'), findsOneWidget);
      expect(find.text('SYNTHETIC Sunday service'), findsOneWidget);
      await tapKey(tester, 'duty-event-$_asg');
      expect(byKey('duty-event-$_asg'), findsNothing);
      expect(find.text('SYNTHETIC Sunday service'), findsWidgets);
    });

    testWidgets('an event no longer public, and a failed read, say so', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        DutyPaths.assignment(_asg),
        staff: false,
        setUp: (h) {
          mine(h);
          h.content.publicEvent[_sunday] = AccessReadOk(
            PublicEventRead.fromJson(const {'event': null}),
          );
        },
      );
      expect(byKey('duty-event-gone-$_asg'), findsOneWidget);
      expect(h.content.publicEventAsked, contains(_sunday));
    });

    testWidgets('a duty with no event shows none', (tester) async {
      await pumpAt(
        tester,
        DutyPaths.assignment(_asg),
        staff: false,
        setUp: (h) => h.duties.mine = AccessReadOk(
          MyDuties.fromJson({
            'member_id': '66666666-6666-4666-8666-666666666666',
            'assignments': [myDutyData()],
          }),
        ),
      );
      expect(find.text('Event'), findsNothing);
      expect(byKey('duty-event-failed-$_asg'), findsNothing);
    });
  });

  group('staff web Events', () {
    AccessRead<StaffEvents> published() => AccessReadOk(
      StaffEvents.fromJson(
        staffEventsData([
          staffEventData(
            eventId: _sunday,
            revision: 2,
            state: 'published',
            live: staffEventRevisionData(title: 'SYNTHETIC Sunday service'),
            publishedBy: 'SYNTHETIC Media Phiri',
            publishedAt: '2099-09-01T08:00:00.000000Z',
          ),
        ]),
      ),
    );

    testWidgets('the editor sees the linked duties before a change', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.contentEvents,
        setUp: (h) {
          h.content.staffEvents = published();
          h.content.dutyLinks[_sunday] = AccessReadOk(
            EventDutyLinks(eventId: _sunday, linkedDuties: 2, reviewsOpen: 1),
          );
        },
      );
      expect(h.content.dutyLinksAsked, isEmpty, reason: 'asked when opened');
      await tapKey(tester, 'event-open-$_sunday');
      expect(
        textOf(tester, 'event-duty-links-$_sunday'),
        '2 duties are linked to this event. Publishing a new time or place, '
        'or withdrawing it, asks their leaders to review them. 1 review is '
        'still open.',
      );
      await tapKey(tester, 'event-withdraw-$_sunday');
      expect(
        find.textContaining('asks their leaders to review them'),
        findsWidgets,
      );
      await tapKey(tester, 'event-confirm-no');
      expect(h.gateway.sent, isEmpty);
    });

    testWidgets('no linked duty shows nothing; a failed read says so', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.contentEvents,
        setUp: (h) => h.content.staffEvents = published(),
      );
      await tapKey(tester, 'event-open-$_sunday');
      expect(byKey('event-duty-links-$_sunday'), findsNothing);
      expect(byKey('event-duty-links-failed-$_sunday'), findsNothing);
    });

    testWidgets('a failed count read never looks like none', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.contentEvents,
        setUp: (h) {
          h.content.staffEvents = published();
          h.content.dutyLinks[_sunday] = const AccessReadDenied(
            AccessDenial.unavailable,
          );
        },
      );
      await tapKey(tester, 'event-open-$_sunday');
      expect(byKey('event-duty-links-failed-$_sunday'), findsOneWidget);
    });
  });
}
