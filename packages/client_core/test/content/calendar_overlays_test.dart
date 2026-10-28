// Epic 6 entry 19: the member's own duties and cell meetings over the
// Calendar. The wire parsing of the new Cells read (api.cells_my_meetings),
// the overlay composition (own current duties and cell meetings in the
// 31-day window, soonest first) and the mobile Calendar: no switches for a
// guest or a Pending applicant, both switches for a member, My duty and My
// cell marks, a cancelled meeting marked, honest failures, and each item
// opening duty detail or My cell. Fakes only; the server behaviour is covered
// by supabase/tests/cells_my_meetings_test.sql and
// tools/identity-e2e/calendar-overlays.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _cell = '47474747-4747-4747-8747-474747474747';
const _meetingA = '51515151-5151-4151-8151-515151515151';
const _meetingB = '52525252-5252-4252-8252-525252525252';
const _dutyMine = '42424242-4242-4242-8242-424242424242';
const _dutyDeclined = '43434343-4343-4343-8343-434343434343';
const _dutyPast = '44444444-4444-4444-8444-444444444444';
const _dutyFar = '45454545-4545-4545-8545-454545454545';
const _event = '71717171-7171-4171-8171-717171717171';

/// Whole hours from now, as a contract instant.
String inHours(int hours) {
  final now = DateTime.now().toUtc();
  final at = DateTime.utc(
    now.year,
    now.month,
    now.day,
    now.hour,
  ).add(Duration(hours: hours));
  return at.toIso8601String();
}

Map<String, Object?> meetingWire(
  String id,
  int startHours, {
  String state = 'scheduled',
}) => {
  'meeting_id': id,
  'occurrence_date': inHours(startHours).substring(0, 10),
  'state': state,
  'starts_at': inHours(startHours),
  'ends_at': inHours(startHours + 1),
};

MyDuties dutiesOf(List<Map<String, Object?>> rows) => MyDuties.fromJson({
  'member_id': '22222222-2222-4222-8222-222222222222',
  'assignments': rows,
});

List<Map<String, Object?>> sampleDuties() => [
  myDutyData(
    assignmentId: _dutyMine,
    dutyName: 'SYNTHETIC Ushering',
    startsAt: inHours(72),
    endsAt: inHours(74),
    location: 'SYNTHETIC Main door',
  ),
  myDutyData(
    assignmentId: _dutyDeclined,
    dutyName: 'SYNTHETIC Reading',
    response: 'declined',
    respondedAt: inHours(-2),
    startsAt: inHours(96),
    endsAt: inHours(97),
  ),
  myDutyData(
    assignmentId: _dutyPast,
    dutyName: 'SYNTHETIC Cleaning',
    response: 'accepted',
    respondedAt: inHours(-30),
    startsAt: inHours(-24),
    endsAt: inHours(-22),
  ),
  myDutyData(
    assignmentId: _dutyFar,
    dutyName: 'SYNTHETIC Far duty',
    startsAt: inHours(24 * 40),
    endsAt: inHours(24 * 40 + 2),
  ),
];

MyCellMeetingsWindow sampleCell() => MyCellMeetingsWindow.fromJson(
  cellMyMeetingsWire(
    cellId: _cell,
    from: DateTime.now(),
    meetings: [
      meetingWire(_meetingA, 48),
      meetingWire(_meetingB, 48 + 24 * 7, state: 'cancelled'),
    ],
  ),
);

Future<ClientTestHarness> pumpCalendar(
  WidgetTester tester, {
  void Function(ClientTestHarness h)? setUp,
  bool member = true,
  String? account = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
}) async {
  tester.view.physicalSize = const Size(390, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = ClientTestHarness(account: account);
  h.content.publicEvents = AccessReadOk(
    PublicEvents.fromJson(
      publicEventsData([
        publicEventData(
          eventId: _event,
          title: 'SYNTHETIC Harvest Thanksgiving',
          startsAt: inHours(60),
          endsAt: inHours(63),
        ),
      ]),
    ),
  );
  if (member) {
    h.grants.myAccess = AccessReadOk(syntheticGrants());
    h.memberAccess.next = MemberAccessGranted(syntheticMemberSummary());
  }
  h.duties.mine = AccessReadOk(dutiesOf(sampleDuties()));
  h.cellCalendar.mine = AccessReadOk(sampleCell());
  setUp?.call(h);
  final router = buildClientRouter(
    initialLocation: ClientPaths.calendar,
    memberHome: true,
    shell: (_, _, child) => AccessRefresher(child: child),
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: h.overrides(),
      child: MaterialApp.router(
        theme: churchMobileTheme(Brightness.light),
        routerConfig: router,
      ),
    ),
  );
  await settle(tester);
  return h;
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder byKey(String key) => find.byKey(Key(key));

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(byKey(key));
  await tester.tap(byKey(key));
  await settle(tester);
}

String textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(byKey(key)).data!;

void main() {
  group('api.cells_my_meetings wire', () {
    test('reads the window, the meetings and the cancelled state', () {
      final w = sampleCell();
      expect(w.cellId, _cell);
      expect(w.meetings.map((m) => m.meetingId), [_meetingA, _meetingB]);
      expect(w.meetings.first.cancelled, isFalse);
      expect(w.meetings.last.cancelled, isTrue);
      expect(w.until.difference(w.from), const Duration(days: 31));
    });

    test('no cell: no meetings', () {
      final w = MyCellMeetingsWindow.fromJson(
        cellMyMeetingsWire(from: DateTime.now()),
      );
      expect(w.cellId, isNull);
      expect(w.meetings, isEmpty);
    });

    test('an unknown state, a withdrawn date or an offset is refused', () {
      for (final bad in [
        meetingWire(_meetingA, 5, state: 'withdrawn'),
        meetingWire(_meetingA, 5, state: 'held'),
        {
          ...meetingWire(_meetingA, 5),
          'starts_at': '2099-01-01T10:00:00+02:00',
        },
        {...meetingWire(_meetingA, 5), 'ends_at': inHours(4)},
      ]) {
        expect(
          () => MyCellMeetingsWindow.fromJson(
            cellMyMeetingsWire(
              cellId: _cell,
              from: DateTime.now(),
              meetings: [bad],
            ),
          ),
          throwsFormatException,
        );
      }
    });

    test('meetings without a cell are refused', () {
      expect(
        () => MyCellMeetingsWindow.fromJson(
          cellMyMeetingsWire(
            from: DateTime.now(),
            meetings: [meetingWire(_meetingA, 5)],
          ),
        ),
        throwsFormatException,
      );
    });
  });

  group('overlay composition', () {
    test('own current duties in the window and the cell meetings, '
        'soonest first', () {
      final items = calendarOverlayItems(
        now: DateTime.now(),
        duties: dutiesOf(sampleDuties()),
        cell: sampleCell(),
      );
      expect(items.map((i) => i.id), [_meetingA, _dutyMine, _meetingB]);
      expect(items.map((i) => i.kind), [
        CalendarOverlayKind.cell,
        CalendarOverlayKind.duty,
        CalendarOverlayKind.cell,
      ]);
      expect(items.last.cancelled, isTrue);
      expect(items[1].place, 'SYNTHETIC Main door');
    });

    test('a switched-off overlay adds nothing', () {
      expect(
        calendarOverlayItems(
          now: DateTime.now(),
          cell: sampleCell(),
        ).map((i) => i.kind).toSet(),
        {CalendarOverlayKind.cell},
      );
      expect(calendarOverlayItems(now: DateTime.now()), isEmpty);
    });
  });

  group('mobile Calendar overlays', () {
    testWidgets('a guest sees the public calendar with no switches', (
      tester,
    ) async {
      final h = await pumpCalendar(tester, account: null, member: false);
      expect(byKey('event-row-$_event'), findsOneWidget);
      expect(byKey('calendar-overlays'), findsNothing);
      expect(byKey('calendar-overlay-duties'), findsNothing);
      expect(h.cellCalendar.calls, 0);
    });

    testWidgets('a Pending applicant (no member access) sees no switches', (
      tester,
    ) async {
      final h = await pumpCalendar(
        tester,
        member: false,
        setUp: (h) =>
            h.grants.myAccess = const AccessReadDenied(AccessDenial.notLinked),
      );
      expect(byKey('event-row-$_event'), findsOneWidget);
      expect(byKey('calendar-overlays'), findsNothing);
      expect(h.cellCalendar.calls, 0);
    });

    testWidgets('a member has both switches, off until switched on', (
      tester,
    ) async {
      final h = await pumpCalendar(tester);
      expect(byKey('calendar-overlay-duties'), findsOneWidget);
      expect(byKey('calendar-overlay-cell'), findsOneWidget);
      expect(find.byType(CalendarOverlayRow), findsNothing);
      expect(h.cellCalendar.calls, 0);
    });

    testWidgets('switching both on marks the member\'s own items among the '
        'events', (tester) async {
      final h = await pumpCalendar(tester);
      await tapKey(tester, 'calendar-overlay-duties');
      await tapKey(tester, 'calendar-overlay-cell');
      expect(h.cellCalendar.calls, 1);
      // Only the member's current duty in the window: not the declined,
      // the past or the far one.
      expect(byKey('overlay-row-duty-$_dutyMine'), findsOneWidget);
      expect(byKey('overlay-row-duty-$_dutyDeclined'), findsNothing);
      expect(byKey('overlay-row-duty-$_dutyPast'), findsNothing);
      expect(byKey('overlay-row-duty-$_dutyFar'), findsNothing);
      expect(
        tester.widget<StatusLabel>(byKey('overlay-mark-duty-$_dutyMine')).label,
        'My duty',
      );
      expect(
        textOf(tester, 'overlay-when-duty-$_dutyMine'),
        endsWith('· SYNTHETIC Main door'),
      );
      expect(
        tester.widget<StatusLabel>(byKey('overlay-mark-cell-$_meetingA')).label,
        'My cell',
      );
      // The cancelled meeting is listed and says so.
      expect(byKey('overlay-row-cell-$_meetingB'), findsOneWidget);
      expect(find.text('Cell meeting cancelled'), findsOneWidget);
      expect(
        textOf(tester, 'overlay-when-cell-$_meetingB'),
        startsWith('Cancelled · was '),
      );
      expect(byKey('calendar-overlay-window'), findsOneWidget);
      // Time order: meeting (48 h), event (60 h), duty (72 h).
      final y = [
        'overlay-row-cell-$_meetingA',
        'event-row-$_event',
        'overlay-row-duty-$_dutyMine',
      ].map((k) => tester.getTopLeft(byKey(k)).dy).toList();
      expect(y[0] < y[1] && y[1] < y[2], isTrue);
    });

    testWidgets('switching an overlay off removes its items', (tester) async {
      await pumpCalendar(tester);
      await tapKey(tester, 'calendar-overlay-duties');
      expect(byKey('overlay-row-duty-$_dutyMine'), findsOneWidget);
      await tapKey(tester, 'calendar-overlay-duties');
      expect(byKey('overlay-row-duty-$_dutyMine'), findsNothing);
      expect(byKey('event-row-$_event'), findsOneWidget);
    });

    testWidgets('a duty opens its duty detail', (tester) async {
      await pumpCalendar(tester);
      await tapKey(tester, 'calendar-overlay-duties');
      await tapKey(tester, 'overlay-row-duty-$_dutyMine');
      final screen = tester.widget<MyDutiesScreen>(find.byType(MyDutiesScreen));
      expect(screen.assignmentId, _dutyMine);
    });

    testWidgets('a cell meeting opens My cell', (tester) async {
      await pumpCalendar(tester);
      await tapKey(tester, 'calendar-overlay-cell');
      await tapKey(tester, 'overlay-row-cell-$_meetingA');
      expect(find.byType(MyCellScreen), findsOneWidget);
    });

    testWidgets('a failed overlay read is said plainly; the events stay', (
      tester,
    ) async {
      await pumpCalendar(
        tester,
        setUp: (h) {
          h.cellCalendar.mine = const AccessReadFailed(unreachable: true);
          h.duties.mine = const AccessReadFailed(unreachable: false);
        },
      );
      await tapKey(tester, 'calendar-overlay-cell');
      await tapKey(tester, 'calendar-overlay-duties');
      expect(byKey('calendar-overlay-cell-failed'), findsOneWidget);
      expect(byKey('calendar-overlay-duties-failed'), findsOneWidget);
      expect(find.byType(CalendarOverlayRow), findsNothing);
      expect(byKey('event-row-$_event'), findsOneWidget);
    });

    testWidgets('a member with no cell sees no meetings and no failure', (
      tester,
    ) async {
      await pumpCalendar(
        tester,
        setUp: (h) => h.cellCalendar.mine = AccessReadOk(
          MyCellMeetingsWindow.fromJson(
            cellMyMeetingsWire(from: DateTime.now()),
          ),
        ),
      );
      await tapKey(tester, 'calendar-overlay-cell');
      expect(find.byType(CalendarOverlayRow), findsNothing);
      expect(byKey('calendar-overlay-cell-failed'), findsNothing);
      expect(byKey('calendar-overlay-window'), findsOneWidget);
    });
  });
}
