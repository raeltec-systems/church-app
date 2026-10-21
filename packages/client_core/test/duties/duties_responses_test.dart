// Story 4.5: My duties on mobile: segments with their own empty copy, the
// detail screen's sticky footer, Can't make it (anymore) through a sheet with
// an optional note and Cancel, accepting several listed dates together after
// a confirmation, Sending and Not sent per duty until the server confirms
// (a retry keeps the request id), Add to calendar with the stale-export
// caveat, the Home My duties card, and the leader's "Can't make it anymore".
// Fakes only; the server behaviour is covered by
// supabase/tests/duties_responses_test.sql and
// tools/identity-e2e/duties-responses.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _dept = '44444444-4444-4444-8444-444444444444';
const _a1 = '42424242-4242-4242-8242-424242424241';
const _a2 = '42424242-4242-4242-8242-424242424242';
const _a3 = '42424242-4242-4242-8242-424242424243';
const _a4 = '42424242-4242-4242-8242-424242424244';
const _ruth = '66666666-6666-4666-8666-666666666666';
const _occ = '43434343-4343-4343-8343-434343434343';
const _slot = '45454545-4545-4545-8545-454545454545';

class _FakeCalendar implements DutyCalendarExport {
  _FakeCalendar(this.answer);
  final CalendarHandoff answer;
  final List<(String, String)> exported = [];
  final List<ShareOrigin?> origins = [];

  @override
  Future<CalendarHandoff> export({
    required String fileName,
    required String ics,
    ShareOrigin? origin,
  }) async {
    exported.add((fileName, ics));
    origins.add(origin);
    return answer;
  }
}

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? setUp,
  DutyCalendarExport? calendar,
}) async {
  tester.view.physicalSize = const Size(1200, 5000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = ClientTestHarness();
  setUp?.call(h);
  final router = buildClientRouter(
    initialLocation: location,
    memberHome: true,
    shell: (_, _, child) => AccessRefresher(child: child),
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...h.overrides(),
        if (calendar != null)
          dutyCalendarExportProvider.overrideWithValue(calendar),
      ],
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
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder byKey(String k) => find.byKey(Key(k));

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(byKey(key));
  await tester.tap(byKey(key));
  await tester.pump();
}

bool enabled(WidgetTester tester, String key) {
  final w = tester.widget(byKey(key));
  return switch (w) {
    ButtonStyleButton b => b.onPressed != null,
    _ => throw StateError('not a button: $key'),
  };
}

String statusOf(WidgetTester tester, String key) =>
    (tester.widget(byKey(key)) as StatusLabel).label;

AccessRead<MyDuties> mineWith(List<Map<String, Object?>> duties) =>
    AccessReadOk(
      MyDuties.fromJson({'member_id': _ruth, 'assignments': duties}),
    );

/// Duty k of a weekly rota, Sunday 4 January 2099 + k weeks, 10:00 church.
Map<String, Object?> sunday(
  String id,
  int k, {
  String response = 'pending',
  int revision = 1,
  String? respondedAt,
  String? priorAcceptedAt,
}) {
  final start = DateTime.utc(2099, 1, 4, 8).add(Duration(days: 7 * k));
  String iso(DateTime t) => t.toIso8601String().replaceFirst('Z', '000Z');
  return myDutyData(
    assignmentId: id,
    revision: revision,
    response: response,
    respondedAt: respondedAt,
    priorAcceptedAt: priorAcceptedAt,
    startsAt: iso(start),
    endsAt: iso(start.add(const Duration(hours: 2))),
    responseDeadline: iso(start.subtract(const Duration(days: 3))),
    dutyName: 'Sunday preaching $k',
  );
}

const _accepted = '2026-10-13T09:00:00.000000Z';

void main() {
  group('wire mapping and pure rules', () {
    test('the earlier acceptance and leader names parse strictly', () {
      final d = MyDuty.fromJson(
        myDutyData(
          response: 'declined',
          respondedAt: '2026-10-14T09:00:00.000000Z',
          priorAcceptedAt: _accepted,
          leaders: const [
            {'display_name': 'SYNTHETIC Leader', 'role': 'leader'},
            {'display_name': 'SYNTHETIC Deputy', 'role': 'deputy'},
          ],
        ),
      );
      expect(d.declinedLater, isTrue);
      expect(d.leaders.map((l) => (l.displayName, l.isDeputy)), [
        ('SYNTHETIC Leader', false),
        ('SYNTHETIC Deputy', true),
      ]);
      for (final bad in [
        // An earlier acceptance only ever sits on a declined answer.
        myDutyData(
          response: 'accepted',
          respondedAt: _accepted,
          priorAcceptedAt: _accepted,
        ),
        // Special assignments: `pastor` is a known role now; an unknown
        // one still fails.
        {
          ...myDutyData(),
          'leaders': [
            {'display_name': 'x', 'role': 'bishop'},
          ],
        },
        {...myDutyData(), 'leaders': 'x'},
      ]) {
        expect(() => MyDuty.fromJson(bad), throwsFormatException);
      }
    });

    test('a department duty or a cell part can be answered (fail closed)', () {
      final now = DateTime.utc(2099, 1, 1);
      final dept = MyDuty.fromJson(myDutyData());
      expect(dept.ownerKind, DutyOwnerKind.department);
      expect(dept.needsResponse(now), isTrue);
      // A server before 4.5 sends no owner kind: department-owned only.
      expect(
        MyDuty.fromJson({...myDutyData()}..remove('owner_kind')).answerable,
        isTrue,
      );
      // Story 4.11: a cell programme part is answered like a department duty.
      final cell = MyDuty.fromJson(myDutyData(ownerKind: 'cell'));
      expect(cell.answerable, isTrue);
      expect(cell.needsResponse(now), isTrue);
      for (final kind in ['care']) {
        final d = MyDuty.fromJson(myDutyData(ownerKind: kind));
        expect(d.answerable, isFalse, reason: kind);
        expect(d.needsResponse(now), isFalse, reason: kind);
        final accepted = MyDuty.fromJson(
          myDutyData(
            ownerKind: kind,
            response: 'accepted',
            respondedAt: _accepted,
          ),
        );
        expect(accepted.canWithdraw(now), isFalse, reason: kind);
      }
      expect(
        () => MyDuty.fromJson({...myDutyData(), 'owner_kind': 3}),
        throwsFormatException,
      );
    });

    test(
      'segments: needs a response, upcoming (accepted or declined), past',
      () {
        final now = DateTime.utc(2099, 1, 10);
        final all = [
          MyDuty.fromJson(sunday(_a4, 3)),
          MyDuty.fromJson(sunday(_a2, 1)),
          MyDuty.fromJson(
            sunday(_a3, 2, response: 'accepted', respondedAt: _accepted),
          ),
          MyDuty.fromJson(sunday(_a1, 0)),
          MyDuty.fromJson(
            sunday(
              '42424242-4242-4242-8242-424242424245',
              4,
              response: 'declined',
              respondedAt: _accepted,
            ),
          ),
        ];
        final s = MyDutySegments.of(all, now);
        expect(s.needsResponse.map((d) => d.assignmentId), [_a2, _a4]);
        expect(s.upcoming.map((d) => d.assignmentId), [
          _a3,
          '42424242-4242-4242-8242-424242424245',
        ]);
        expect(s.past.map((d) => d.assignmentId), [_a1]);
        expect(s.next?.assignmentId, _a2);
        expect(
          MyDutySegments.of([all[2]], now).next?.assignmentId,
          _a3,
          reason: 'with nothing to answer, the next accepted duty',
        );
        expect(MyDuty.fromJson(sunday(_a1, 0)).canWithdraw(now), isFalse);
        expect(all[2].canWithdraw(now), isTrue);
      },
    );

    test('a bulk action touches every selected date', () {
      final a = DutyAction(
        function: DutyCommands.function,
        request: CommandRequest(
          command: DutyCommands.acceptMany,
          requestId: '00000000-0000-4000-8000-000000000001',
          expectedRevision: const Optional.of(null),
          payload: {
            'assignments': [
              {'assignment_id': _a1, 'revision': 1},
              {'assignment_id': _a2, 'revision': 3},
            ],
          },
        ),
        subject: '2 duties',
      );
      expect(a.assignmentIds, [_a1, _a2]);
      expect(a.touches(_a2), isTrue);
      expect(a.touches(_a3), isFalse);
    });

    test('the calendar file: church date name, UTC times, no instructions, '
        'escaped and folded lines', () {
      final d = MyDuty.fromJson(
        myDutyData(
          assignmentId: _a1,
          startsAt: '2099-01-03T23:00:00.000000Z',
          endsAt: null,
          reportingAt: '2099-01-03T22:30:00.000000Z',
          location: 'SYNTHETIC Hall, side room; door B',
          positionName: 'Reader',
        ),
      );
      // 00:30 church time on 4 January (UTC+2), whatever the device zone.
      expect(DutyCalendar.fileName(d), 'duty-2099-01-04.ics');
      final ics = DutyCalendar.ics(d, now: DateTime.utc(2026, 10, 14, 7));
      final lines = ics.split('\r\n');
      expect(lines.first, 'BEGIN:VCALENDAR');
      expect(ics.endsWith('END:VCALENDAR\r\n'), isTrue);
      // The occurrence and its position: the same entry after a material
      // change replaces the assignment; SEQUENCE is the slot revision.
      // A long UID line is folded at 75 octets.
      final unfoldedLines = ics.replaceAll('\r\n ', '').split('\r\n');
      expect(unfoldedLines, contains('UID:duty-$_occ-$_slot@bickafue.app'));
      expect(lines, contains('SEQUENCE:1'));
      final moved = MyDuty.fromJson(
        myDutyData(
          assignmentId: _a2,
          slotRevision: 2,
          changes: const ['starts_at'],
          startsAt: '2099-01-03T23:00:00.000000Z',
        ),
      );
      final movedIcs = DutyCalendar.ics(moved, now: DateTime.utc(2026, 10, 15));
      expect(
        movedIcs.replaceAll('\r\n ', ''),
        contains('UID:duty-$_occ-$_slot@bickafue.app'),
      );
      expect(movedIcs, contains('SEQUENCE:2'));
      expect(lines, contains('DTSTAMP:20261014T070000Z'));
      // From the reporting time; two hours from the start with no end.
      expect(lines, contains('DTSTART:20990103T223000Z'));
      expect(lines, contains('DTEND:20990104T010000Z'));
      expect(lines, contains('SUMMARY:Sunday preaching: Reader'));
      expect(lines, contains(r'LOCATION:SYNTHETIC Hall\, side room\; door B'));
      expect(ics, isNot(contains('Arrive early')));
      final unfolded = ics.replaceAll('\r\n ', '');
      expect(unfolded, contains('does not update if the duty changes'));
      for (final l in lines) {
        expect(l.length, lessThanOrEqualTo(75));
      }
    });
  });

  group('My duties', () {
    testWidgets('segments carry counts and their own empty copy; a failed '
        'read is not empty', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.myDuties,
        setUp: (h) => h.duties.mine = mineWith([
          sunday(_a1, 1, response: 'accepted', respondedAt: _accepted),
        ]),
      );
      expect(find.text('Needs a response (0)'), findsOneWidget);
      expect(find.text('Upcoming (1)'), findsOneWidget);
      expect(find.text('Past (0)'), findsOneWidget);
      // Nothing to answer: Upcoming is shown first.
      expect(byKey('my-duty-$_a1'), findsOneWidget);
      await tester.tap(find.text('Needs a response (0)'));
      await settle(tester);
      expect(find.text('Nothing waiting for your response.'), findsOneWidget);
      await tester.tap(find.text('Past (0)'));
      await settle(tester);
      expect(find.text('No past duties yet.'), findsOneWidget);
    });

    testWidgets('Can\'t make it: Cancel sends nothing; the note goes with '
        'the answer', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.myDuties,
        setUp: (h) => h.duties.mine = mineWith([sunday(_a1, 1)]),
      );
      await tapKey(tester, 'duty-decline-$_a1');
      await settle(tester);
      expect(find.text('Can\'t make it?'), findsOneWidget);
      await tapKey(tester, 'decline-cancel');
      await settle(tester);
      expect(h.gateway.sent, isEmpty);
      await tapKey(tester, 'duty-decline-$_a1');
      await settle(tester);
      await tester.enterText(byKey('decline-note'), ' Travelling ');
      await tapKey(tester, 'decline-confirm');
      await settle(tester);
      expect(h.gateway.sent.single.wire['payload'], {
        'assignment_id': _a1,
        'response': 'declined',
        'note': 'Travelling',
      });
    });

    testWidgets('detail: Can\'t make it anymore after accepting; Not sent '
        'until the server answers; Check again keeps the request id', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        '/duties/assignments/$_a1',
        setUp: (h) => h.duties.mine = mineWith([
          {
            ...sunday(
              _a1,
              1,
              response: 'accepted',
              revision: 2,
              respondedAt: _accepted,
            ),
            'leaders': [
              {'display_name': 'SYNTHETIC Leader', 'role': 'leader'},
            ],
          },
        ]),
      );
      expect(byKey('duty-footer'), findsOneWidget);
      expect(byKey('duty-accept-$_a1'), findsNothing);
      expect(
        find.descendant(
          of: byKey('duty-leaders-$_a1'),
          matching: find.text('SYNTHETIC Leader'),
        ),
        findsOneWidget,
      );
      await tapKey(tester, 'duty-withdraw-$_a1');
      await settle(tester);
      expect(find.text('Can\'t make it anymore?'), findsOneWidget);
      await tester.enterText(byKey('decline-note'), 'Car broke down');
      await tapKey(tester, 'decline-confirm');
      await settle(tester);
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'duties.withdraw_acceptance');
      expect(sent.wire['expected_revision'], 2);
      expect(sent.wire['payload'], {
        'assignment_id': _a1,
        'note': 'Car broke down',
      });
      expect(statusOf(tester, 'my-duty-status-$_a1'), 'Sending…');
      expect(enabled(tester, 'duty-withdraw-$_a1'), isFalse);
      // Airplane mode or a timeout: the outcome is unknown.
      sent.unknown();
      await settle(tester);
      expect(statusOf(tester, 'my-duty-status-$_a1'), 'Not sent');
      expect(byKey('duties-notice-unconfirmed'), findsOneWidget);
      await tapKey(tester, 'duties-check-again');
      expect(h.gateway.sent, hasLength(2));
      expect(h.gateway.sent.last.wire, sent.wire);
      h.duties.mine = mineWith([
        sunday(
          _a1,
          1,
          response: 'declined',
          revision: 3,
          respondedAt: '2026-10-14T09:00:00.000000Z',
          priorAcceptedAt: _accepted,
        ),
      ]);
      h.gateway.sent.last.confirm(const {'response': 'declined'}, 3);
      await settle(tester);
      expect(byKey('duties-notice-withdrawn'), findsOneWidget);
      expect(statusOf(tester, 'my-duty-status-$_a1'), 'Can\'t make it anymore');
      expect(byKey('duty-withdraw-$_a1'), findsNothing);
    });

    testWidgets('an unknown outcome the server did record: after a reload '
        'the server\'s answer shows, not Not sent', (tester) async {
      final h = await pumpAt(
        tester,
        '/duties/assignments/$_a1',
        setUp: (h) => h.duties.mine = mineWith([
          sunday(
            _a1,
            1,
            response: 'accepted',
            revision: 2,
            respondedAt: _accepted,
          ),
        ]),
      );
      await tapKey(tester, 'duty-withdraw-$_a1');
      await settle(tester);
      await tapKey(tester, 'decline-confirm');
      await settle(tester);
      h.gateway.sent.single.unknown();
      await settle(tester);
      expect(statusOf(tester, 'my-duty-status-$_a1'), 'Not sent');
      // A reload that still shows the duty accepted keeps Not sent.
      await tapKey(tester, 'duties-reload');
      await settle(tester);
      expect(statusOf(tester, 'my-duty-status-$_a1'), 'Not sent');
      expect(byKey('duties-notice-unconfirmed'), findsOneWidget);
      // The server did record it; the list is read again (resume, Reload).
      h.duties.mine = mineWith([
        sunday(
          _a1,
          1,
          response: 'declined',
          revision: 3,
          respondedAt: '2026-10-14T09:00:00.000000Z',
          priorAcceptedAt: _accepted,
        ),
      ]);
      await tapKey(tester, 'duties-reload');
      await settle(tester);
      expect(statusOf(tester, 'my-duty-status-$_a1'), 'Can\'t make it anymore');
      expect(byKey('duties-notice-unconfirmed'), findsNothing);
      expect(byKey('duties-check-again'), findsNothing);
      expect(h.gateway.sent, hasLength(1));
    });

    testWidgets('Accept carries the optional note from the detail card to '
        'the footer', (tester) async {
      final h = await pumpAt(
        tester,
        '/duties/assignments/$_a1',
        setUp: (h) => h.duties.mine = mineWith([sunday(_a1, 1)]),
      );
      await tester.enterText(byKey('duty-note-$_a1'), ' Bringing the slides ');
      await tapKey(tester, 'duty-accept-$_a1');
      expect(h.gateway.sent.single.wire['payload'], {
        'assignment_id': _a1,
        'response': 'accepted',
        'note': 'Bringing the slides',
      });
    });

    testWidgets('bulk: select three of four dates, confirm the dates, one '
        'all-or-nothing request', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.myDuties,
        setUp: (h) => h.duties.mine = mineWith([
          sunday(_a1, 1),
          sunday(_a2, 2, revision: 3),
          sunday(_a3, 3),
          sunday(_a4, 4),
        ]),
      );
      expect(enabled(tester, 'duties-accept-selected'), isFalse);
      for (final id in [_a3, _a1, _a2]) {
        await tapKey(tester, 'duty-select-$id');
      }
      expect(find.text('Accept selected (3)'), findsOneWidget);
      await tapKey(tester, 'duties-accept-selected');
      await settle(tester);
      expect(find.text('Accept 3 duties?'), findsOneWidget);
      for (final id in [_a1, _a2, _a3]) {
        expect(byKey('bulk-date-$id'), findsOneWidget);
      }
      expect(byKey('bulk-date-$_a4'), findsNothing);
      // Bulk acceptance carries no note (decision recorded in the plan).
      expect(byKey('duties-bulk-no-note'), findsOneWidget);
      await tapKey(tester, 'duties-bulk-cancel');
      await settle(tester);
      expect(h.gateway.sent, isEmpty);
      await tapKey(tester, 'duties-accept-selected');
      await settle(tester);
      await tapKey(tester, 'duties-bulk-confirm');
      await settle(tester);
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'duties.accept_many');
      expect(sent.wire['expected_revision'], isNull);
      expect(sent.wire['payload'], {
        'assignments': [
          {'assignment_id': _a1, 'revision': 1},
          {'assignment_id': _a2, 'revision': 3},
          {'assignment_id': _a3, 'revision': 1},
        ],
      });
      for (final id in [_a1, _a2, _a3]) {
        expect(statusOf(tester, 'my-duty-status-$id'), 'Sending…');
      }
      expect(statusOf(tester, 'my-duty-status-$_a4'), 'Awaiting response');
      // One date changed meanwhile: nothing was accepted; the list reloads.
      final calls = h.duties.mineCalls;
      sent.refuse(
        ErrorCode.conflict,
        fieldErrors: const {
          'assignments': 'changed',
          'assignment:$_a2': 'superseded',
        },
      );
      await settle(tester);
      expect(byKey('duties-notice-bulkChanged'), findsOneWidget);
      expect(h.duties.mineCalls, calls + 1);
      for (final id in [_a1, _a2, _a3, _a4]) {
        expect(statusOf(tester, 'my-duty-status-$id'), 'Awaiting response');
      }
    });

    testWidgets('bulk: confirmed, the accepted dates move to Upcoming', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.myDuties,
        setUp: (h) =>
            h.duties.mine = mineWith([sunday(_a1, 1), sunday(_a2, 2)]),
      );
      await tapKey(tester, 'duty-select-$_a1');
      await tapKey(tester, 'duty-select-$_a2');
      await tapKey(tester, 'duties-accept-selected');
      await settle(tester);
      await tapKey(tester, 'duties-bulk-confirm');
      await settle(tester);
      h.duties.mine = mineWith([
        sunday(
          _a1,
          1,
          response: 'accepted',
          revision: 2,
          respondedAt: _accepted,
        ),
        sunday(
          _a2,
          2,
          response: 'accepted',
          revision: 2,
          respondedAt: _accepted,
        ),
      ]);
      h.gateway.sent.single.confirm(const {'count': 2}, 2);
      await settle(tester);
      expect(byKey('duties-notice-bulkAccepted'), findsOneWidget);
      expect(find.textContaining('accepted 2 duties'), findsOneWidget);
      expect(find.text('Upcoming (2)'), findsOneWidget);
      expect(statusOf(tester, 'my-duty-status-$_a1'), 'Accepted');
    });

    testWidgets('Add to calendar hands over the file and says it is a copy', (
      tester,
    ) async {
      final calendar = _FakeCalendar(CalendarHandoff.handedOver);
      await pumpAt(
        tester,
        '/duties/assignments/$_a1',
        calendar: calendar,
        setUp: (h) => h.duties.mine = mineWith([
          sunday(
            _a1,
            1,
            response: 'accepted',
            revision: 2,
            respondedAt: _accepted,
          ),
        ]),
      );
      expect(find.text(DutyCalendar.staleCaveat), findsOneWidget);
      await tapKey(tester, 'duty-calendar-$_a1');
      await settle(tester);
      expect(calendar.exported.single.$1, 'duty-2099-01-11.ics');
      expect(
        calendar.exported.single.$2.replaceAll('\r\n ', ''),
        contains('UID:duty-$_occ-$_slot@'),
      );
      // The share sheet is anchored to the button (iPad popover).
      final origin = calendar.origins.single!;
      expect(origin.width, greaterThan(0));
      expect(origin.height, greaterThan(0));
      expect(
        tester.widget<Text>(byKey('duty-calendar-result-$_a1')).data,
        contains('can\'t tell whether it was saved'),
      );
    });

    testWidgets('without a handoff the app says so instead of pretending', (
      tester,
    ) async {
      await pumpAt(
        tester,
        '/duties/assignments/$_a1',
        setUp: (h) => h.duties.mine = mineWith([sunday(_a1, 1)]),
      );
      await tapKey(tester, 'duty-calendar-$_a1');
      await settle(tester);
      expect(
        find.textContaining('isn\'t available in this version'),
        findsOneWidget,
      );
    });
  });

  group('Home My duties card', () {
    testWidgets('awaiting count, the next duty, inline answers, See all', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.home,
        setUp: (h) => h.duties.mine = mineWith([
          sunday(_a2, 2),
          sunday(_a1, 1),
          sunday(_a3, 3, response: 'accepted', respondedAt: _accepted),
        ]),
      );
      expect(find.text('2 awaiting your response'), findsOneWidget);
      expect(byKey('home-duty-$_a1'), findsOneWidget);
      expect(find.text('Sunday preaching 1'), findsOneWidget);
      await tapKey(tester, 'home-duty-accept-$_a1');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'duties.respond');
      expect(statusOf(tester, 'home-duty-status-$_a1'), 'Sending…');
      sent.unknown();
      await settle(tester);
      expect(statusOf(tester, 'home-duty-status-$_a1'), 'Not sent');
      expect(byKey('home-duties-check-again'), findsOneWidget);
      await tapKey(tester, 'home-duties-see-all');
      await settle(tester);
      expect(byKey('my-duties-list'), findsOneWidget);
    });

    testWidgets('Can\'t make it from Home opens the sheet', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.home,
        setUp: (h) => h.duties.mine = mineWith([sunday(_a1, 1)]),
      );
      await tapKey(tester, 'home-duty-decline-$_a1');
      await settle(tester);
      await tapKey(tester, 'decline-confirm');
      await settle(tester);
      expect(h.gateway.sent.single.wire['payload'], {
        'assignment_id': _a1,
        'response': 'declined',
      });
    });

    testWidgets('the member Home is registered on mobile only', (tester) async {
      final h = ClientTestHarness();
      h.duties.mine = mineWith([sunday(_a1, 1)]);
      final router = buildClientRouter(
        initialLocation: ClientPaths.home,
        shell: (_, _, child) => child,
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: h.overrides(),
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await settle(tester);
      expect(find.byType(MemberHomeScreen), findsNothing);
      expect(find.byType(MyDutiesHomeCard), findsNothing);
    });

    testWidgets('empty and failed reads differ', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.home,
        setUp: (h) => h.duties.mine = mineWith(const []),
      );
      expect(byKey('home-duties-empty'), findsOneWidget);
      expect(byKey('home-duties-failed'), findsNothing);
    });

    testWidgets('a network failure is not an empty list', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.home,
        setUp: (h) => h.duties.mine = const AccessReadFailed(unreachable: true),
      );
      expect(byKey('home-duties-failed'), findsOneWidget);
      expect(byKey('home-duties-empty'), findsNothing);
    });
  });

  group('leader view', () {
    testWidgets('a later decline reads "Can\'t make it anymore" on the board', (
      tester,
    ) async {
      await pumpAt(
        tester,
        DutyPaths.leader,
        setUp: (h) => h.duties.board = AccessReadOk(
          DutyLeaderBoard.fromJson({
            'departments': [
              {
                'department_id': _dept,
                'name': 'SYNTHETIC Preaching Rota',
                'capacity': 'department_leader',
                'can_publish': true,
                'members': const <Object?>[],
                'duties': [
                  {
                    'occurrence_id': '43434343-4343-4343-8343-434343434343',
                    'department_id': _dept,
                    'duty_name': 'Sunday preaching',
                    'starts_at': '2099-01-04T08:00:00.000000Z',
                    'ends_at': null,
                    'reporting_at': null,
                    'location': null,
                    'instructions': null,
                    'state': 'published',
                    'revision': 1,
                    'published_at': '2026-10-13T08:00:00.000000Z',
                    'positions': [
                      {
                        'slot_id': '45454545-4545-4545-8545-454545454545',
                        'position_no': 1,
                        'assignment': {
                          'assignment_id': _a1,
                          'member_id': _ruth,
                          'display_name': 'SYNTHETIC Ruth',
                          'response': 'declined',
                          'response_deadline': '2099-01-01T08:00:00.000000Z',
                          'responded_at': '2026-10-14T09:00:00.000000Z',
                          'prior_accepted_at': _accepted,
                          'note': 'SYNTHETIC: travelling',
                          'revision': 3,
                        },
                      },
                    ],
                  },
                ],
              },
            ],
          }),
        ),
      );
      expect(statusOf(tester, 'response-$_a1'), 'Can\'t make it anymore');
      expect(find.textContaining('Had accepted'), findsOneWidget);
    });
  });
}
