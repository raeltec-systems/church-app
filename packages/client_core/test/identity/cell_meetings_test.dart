// Story 5.1: a cell's weekly schedule and meetings on staff web, and the next
// meeting on mobile My cell, with honest command states and church time.
// Fakes only; the server behaviour is covered by
// supabase/tests/cells_meetings_test.sql and tools/identity-e2e/cells-meetings.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _cell = '51515151-5151-4151-8151-515151515151';
const _meeting = '52525252-5252-4252-8252-525252525252';
const _cancelled = '53535353-5353-4353-8353-535353535353';

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? setUp,
}) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = ClientTestHarness();
  setUp?.call(h);
  final router = buildClientRouter(
    initialLocation: location,
    shell: (_, _, child) => AccessRefresher(child: child),
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: h.overrides(),
      child: MaterialApp.router(
        theme: churchStaffTheme(),
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

/// A Friday meeting far ahead, 18:00-19:30 church time (16:00-17:30 UTC).
Map<String, Object?> meetingData({
  String id = _meeting,
  String state = 'scheduled',
  String? venue = 'SYNTHETIC 12 Shikoswe Road',
  bool venueMoved = false,
  bool pin = true,
  int revision = 2,
}) => {
  'meeting_id': id,
  'cell_id': _cell,
  'occurrence_date': '2099-03-06',
  'state': state,
  'starts_at': '2099-03-06T16:00:00.000000Z',
  'ends_at': '2099-03-06T17:30:00.000000Z',
  'nominal_starts_at': '2099-03-06T16:00:00.000000Z',
  'nominal_ends_at': '2099-03-06T17:30:00.000000Z',
  'venue_moved': venueMoved,
  'venue': venue,
  'map_pin': pin && venue != null ? {'lat': -15.77123, 'lng': 28.18456} : null,
  'revision': revision,
};

Map<String, Object?> scheduleData({bool private = true}) => {
  'weekday': 5,
  'start_time': '18:00',
  'end_time': '19:30',
  'from_date': '2026-10-21',
  'zone': 'Africa/Lusaka',
  'policy_version': 1,
  'venue_set': true,
  'pin_set': true,
  'venue': private ? 'SYNTHETIC 12 Shikoswe Road' : null,
  'map_pin': private ? {'lat': -15.77123, 'lng': 28.18456} : null,
};

AccessRead<CellMeetingsBoard> boardWith({
  String role = 'leader',
  bool canChange = true,
  bool canSet = false,
  Map<String, Object?>? schedule,
  List<Map<String, Object?>>? meetings,
}) => AccessReadOk(
  CellMeetingsBoard.fromJson({
    'cells': [
      {
        'cell_id': _cell,
        'name': 'SYNTHETIC Shikoswe Cell',
        'is_synthetic': true,
        'role': role,
        'can_change': canChange,
        'can_set_schedule': canSet,
        'cell_revision': canSet ? 4 : null,
        'schedule': schedule ?? scheduleData(private: role != 'admin'),
        'meetings':
            meetings ??
            [
              meetingData(
                venue: role == 'admin' ? null : 'SYNTHETIC 12 Shikoswe Road',
              ),
            ],
      },
    ],
  }),
);

Map<String, Object?> myCellData({Object? meetings}) => {
  'member_id': '54545454-5454-4454-8454-545454545454',
  'revision': 3,
  'primary': {
    'membership_id': '55555555-5555-4555-8555-555555555555',
    'cell_id': _cell,
    'label': 'SYNTHETIC Shikoswe',
    'broad_area': 'SYNTHETIC Kafue East',
    'since': '2026-10-07T12:00:00.000000Z',
  },
  'open_request': null,
  'last_decision': null,
  'meetings': meetings,
};

void main() {
  group('wire parsing', () {
    test('My cell carries the next meeting and the cancelled ones', () {
      final cell = MyCell.fromJson(
        myCellData(
          meetings: {
            'cell_id': _cell,
            'next': meetingData(state: 'moved', venueMoved: true, pin: false),
            'cancelled': [
              {
                'meeting_id': _cancelled,
                'occurrence_date': '2099-02-27',
                'nominal_starts_at': '2099-02-27T16:00:00.000000Z',
              },
            ],
          },
        ),
      );
      final m = cell.meetings!;
      expect(m.next!.moved, isTrue);
      expect(m.next!.venue, 'SYNTHETIC 12 Shikoswe Road');
      expect(m.next!.mapPin, isNull);
      expect(m.cancelled.single.meetingId, _cancelled);
    });

    test('a cell without a schedule has no meetings; older answers parse', () {
      expect(MyCell.fromJson(myCellData()).meetings, isNull);
      final older = Map.of(myCellData())..remove('meetings');
      expect(MyCell.fromJson(older).meetings, isNull);
    });

    test('unexpected meeting shapes are refused, never guessed', () {
      expect(
        () => CellMeeting.fromJson(meetingData(state: 'withdrawn')),
        throwsFormatException,
      );
      expect(
        () => CellMeeting.fromJson({
          ...meetingData(),
          'starts_at': '2099-03-06T18:00:00+02:00',
        }),
        throwsFormatException,
      );
      expect(
        () => MeetingSchedule.fromJson({...scheduleData(), 'weekday': 8}),
        throwsFormatException,
      );
      expect(
        () => StaffMeetingCell.fromJson({
          'cell_id': _cell,
          'name': 'SYNTHETIC Shikoswe Cell',
          'is_synthetic': true,
          'role': 'admin',
          'can_change': true,
          'can_set_schedule': true,
          'cell_revision': null,
          'schedule': null,
          'meetings': [],
        }),
        throwsFormatException,
        reason: 'an Admin cell must carry the revision of cells.set_schedule',
      );
    });
  });

  group('staff web: cell meetings', () {
    testWidgets('the leader reads the venue and moves one meeting in church '
        'time under its revision', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.cellMeetings,
        setUp: (h) => h.cells.meetings = boardWith(),
      );
      expect(h.cells.meetingsCalls, 1);
      // The next meeting leads its card; its facts are labelled values.
      expect(
        tester.widget<Text>(byKey('meeting-next-$_cell')).data,
        startsWith('Friday'),
      );
      expect(
        tester.widget<Text>(byKey('meeting-venue-$_cell')).data,
        'SYNTHETIC 12 Shikoswe Road',
      );
      expect(
        tester.widget<Text>(byKey('meeting-schedule-$_cell')).data,
        'Fridays, 18:00-19:30',
      );
      expect(byKey('schedule-form-$_cell'), findsNothing);

      await tapKey(tester, 'meeting-move-$_meeting');
      await settle(tester);
      expect(byKey('meeting-move-form-$_meeting'), findsOneWidget);
      await tester.enterText(byKey('move-date-$_meeting'), '2099-03-07');
      await tester.enterText(byKey('move-start-$_meeting'), '10:00');
      await tester.enterText(byKey('move-end-$_meeting'), '11:30');
      await tester.enterText(
        byKey('move-venue-$_meeting'),
        'SYNTHETIC Church hall',
      );
      await settle(tester);
      await tapKey(tester, 'move-save-$_meeting');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'cells_command');
      expect(sent.wire['command'], 'cells.move_meeting');
      expect(sent.wire['expected_revision'], 2);
      expect(sent.wire['payload'], {
        'meeting_id': _meeting,
        'starts_at': '2099-03-07T08:00:00.000Z',
        'ends_at': '2099-03-07T09:30:00.000Z',
        'venue': 'SYNTHETIC Church hall',
      });
      expect(byKey('cells-pending'), findsOneWidget);
      sent.confirm(meetingData(state: 'moved', venueMoved: true), 3);
      await settle(tester);
      expect(byKey('cells-notice-meetingMoved'), findsOneWidget);
      expect(h.cells.meetingsCalls, 2);
    });

    testWidgets('a cancel with an unknown outcome is checked again under the '
        'same request', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.cellMeetings,
        setUp: (h) => h.cells.meetings = boardWith(),
      );
      await tapKey(tester, 'meeting-cancel-$_meeting');
      final first = h.gateway.sent.single;
      expect(first.wire['command'], 'cells.cancel_meeting');
      expect(first.wire['payload'], {'meeting_id': _meeting});
      first.unknown();
      await settle(tester);
      expect(byKey('cells-notice-unconfirmed'), findsOneWidget);
      await tapKey(tester, 'cells-check-again');
      expect(h.gateway.sent, hasLength(2));
      expect(h.gateway.sent.last.wire, first.wire);
      h.gateway.sent.last.refuse(
        ErrorCode.conflict,
        fieldErrors: const {'meeting_id': 'cancelled'},
      );
      await settle(tester);
      expect(byKey('cells-notice-alreadyCancelled'), findsOneWidget);
    });

    testWidgets('a cancelled meeting can be brought back; a started one is '
        'reported, not changed', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.cellMeetings,
        setUp: (h) => h.cells.meetings = boardWith(
          meetings: [meetingData(state: 'cancelled', revision: 3)],
        ),
      );
      expect(byKey('meeting-move-$_meeting'), findsNothing);
      await tapKey(tester, 'meeting-reinstate-$_meeting');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'cells.reinstate_meeting');
      expect(sent.wire['expected_revision'], 3);
      sent.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'meeting_id': 'started'},
      );
      await settle(tester);
      expect(byKey('cells-notice-meetingStarted'), findsOneWidget);
    });

    testWidgets('an assistant reads meetings but has no change actions', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.cellMeetings,
        setUp: (h) =>
            h.cells.meetings = boardWith(role: 'assistant', canChange: false),
      );
      expect(byKey('meeting-$_meeting'), findsOneWidget);
      expect(byKey('meeting-move-$_meeting'), findsNothing);
      expect(byKey('meeting-cancel-$_meeting'), findsNothing);
    });

    testWidgets('an Admin sets the schedule and sees that a venue is set, '
        'never the venue', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.cellMeetings,
        setUp: (h) => h.cells.meetings = boardWith(role: 'admin', canSet: true),
      );
      expect(find.textContaining('SYNTHETIC 12 Shikoswe Road'), findsNothing);
      expect(
        tester.widget<Text>(byKey('meeting-venue-$_cell')).data,
        startsWith('Set (only'),
      );
      expect(tester.widget<Text>(byKey('meeting-pin-$_cell')).data, 'Set');
      // The meetings lead; the rare schedule change waits behind a button.
      expect(byKey('schedule-form-$_cell'), findsNothing);
      await tapKey(tester, 'schedule-edit-$_cell');
      await settle(tester);
      await tester.enterText(byKey('schedule-start-$_cell'), '17:30');
      await tester.enterText(byKey('schedule-end-$_cell'), '19:00');
      await tester.enterText(
        byKey('schedule-venue-$_cell'),
        'SYNTHETIC 14 Shikoswe Road',
      );
      await tester.enterText(byKey('schedule-lat-$_cell'), '-15.7');
      await tester.enterText(byKey('schedule-lng-$_cell'), '28.1');
      await settle(tester);
      await tapKey(tester, 'schedule-save-$_cell');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'cells.set_schedule');
      expect(sent.wire['expected_revision'], 4);
      expect(sent.wire['payload'], {
        'cell_id': _cell,
        'weekday': 5,
        'start_time': '17:30',
        'end_time': '19:00',
        'venue': 'SYNTHETIC 14 Shikoswe Road',
        'map_pin': {'lat': -15.7, 'lng': 28.1},
      });
      sent.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'venue': 'invalid'},
      );
      await settle(tester);
      expect(byKey('cells-notice-invalid'), findsOneWidget);
      expect(find.textContaining('start with "SYNTHETIC "'), findsOneWidget);
    });

    testWidgets('the first schedule needs a venue before it can be saved', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.cellMeetings,
        setUp: (h) => h.cells.meetings = AccessReadOk(
          CellMeetingsBoard.fromJson({
            'cells': [
              {
                'cell_id': _cell,
                'name': 'SYNTHETIC Shikoswe Cell',
                'is_synthetic': true,
                'role': 'admin',
                'can_change': true,
                'can_set_schedule': true,
                'cell_revision': 1,
                'schedule': null,
                'meetings': [],
              },
            ],
          }),
        ),
      );
      expect(byKey('meeting-no-schedule-$_cell'), findsOneWidget);
      expect(enabled(tester, 'schedule-save-$_cell'), isFalse);
      await tester.enterText(
        byKey('schedule-venue-$_cell'),
        'SYNTHETIC 12 Shikoswe Road',
      );
      await settle(tester);
      await tapKey(tester, 'schedule-save-$_cell');
      expect(h.gateway.sent.single.wire['payload'], {
        'cell_id': _cell,
        'weekday': 4,
        'start_time': '18:00',
        'end_time': '19:30',
        'venue': 'SYNTHETIC 12 Shikoswe Road',
      });
    });

    testWidgets('the next meeting leads with Plan the programme; Keep as is '
        'closes a move without sending', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.cellMeetings,
        setUp: (h) => h.cells.meetings = boardWith(),
      );
      await tapKey(tester, 'meeting-move-$_meeting');
      await settle(tester);
      expect(byKey('meeting-move-form-$_meeting'), findsOneWidget);
      await tapKey(tester, 'move-cancel-$_meeting');
      await settle(tester);
      expect(byKey('meeting-move-form-$_meeting'), findsNothing);
      expect(h.gateway.sent, isEmpty);
      await tapKey(tester, 'meeting-next-plan-$_cell');
      await settle(tester);
      expect(h.cells.programmeAsked, [_meeting]);
    });

    testWidgets('an Admin closes a schedule change with Keep as is', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.cellMeetings,
        setUp: (h) => h.cells.meetings = boardWith(role: 'admin', canSet: true),
      );
      // An Admin plans nothing: the leader or assistant does.
      expect(byKey('meeting-next-plan-$_cell'), findsNothing);
      await tapKey(tester, 'schedule-edit-$_cell');
      await settle(tester);
      expect(byKey('schedule-form-$_cell'), findsOneWidget);
      await tapKey(tester, 'schedule-cancel-$_cell');
      await settle(tester);
      expect(byKey('schedule-form-$_cell'), findsNothing);
      expect(h.gateway.sent, isEmpty);
    });

    testWidgets('without a cell scope or Admin the server\'s denial shows', (
      tester,
    ) async {
      await pumpAt(tester, ClientPaths.cellMeetings);
      expect(byKey('cells-denied-notGranted'), findsOneWidget);
    });
  });

  group('story 5.2: reminders and members to tell directly', () {
    Map<String, Object?> withReminders(List<String>? befores, int rev) => {
      ...scheduleData(),
      'reminders': [
        for (final b in befores ?? const ['24 hours']) {'before': b},
      ],
      'reminders_default': befores == null,
      'reminders_revision': rev,
    };

    testWidgets(
      'the leader changes the cell\'s reminders under their revision',
      (tester) async {
        final h = await pumpAt(
          tester,
          ClientPaths.cellMeetings,
          setUp: (h) =>
              h.cells.meetings = boardWith(schedule: withReminders(null, 3)),
        );
        expect(
          tester.widget<Text>(byKey('meeting-reminders-$_cell')).data,
          '1 day before (usual)',
        );
        await tapKey(tester, 'reminders-edit-$_cell');
        await settle(tester);
        await tapKey(tester, 'reminder-choice-$_cell-24 hours');
        await tapKey(tester, 'reminder-choice-$_cell-2 hours');
        await settle(tester);
        await tapKey(tester, 'reminders-save-$_cell');
        final sent = h.gateway.sent.single;
        expect(sent.wire['command'], 'cells.set_meeting_reminders');
        expect(sent.wire['expected_revision'], 3);
        expect(sent.wire['payload'], {
          'cell_id': _cell,
          'reminders': [
            {'before': '2 hours'},
          ],
        });
        sent.confirm({'cell_id': _cell}, 4);
        await settle(tester);
        expect(byKey('cells-notice-remindersSet'), findsOneWidget);
      },
    );

    testWidgets(
      'back to the usual sends null; an assistant cannot change them',
      (tester) async {
        final h = await pumpAt(
          tester,
          ClientPaths.cellMeetings,
          setUp: (h) => h.cells.meetings = boardWith(
            schedule: withReminders(['2 hours'], 5),
          ),
        );
        expect(
          tester.widget<Text>(byKey('meeting-reminders-$_cell')).data,
          '2 hours before',
        );
        await tapKey(tester, 'reminders-edit-$_cell');
        await settle(tester);
        await tapKey(tester, 'reminders-default-$_cell');
        expect(h.gateway.sent.single.wire['payload'], {
          'cell_id': _cell,
          'reminders': null,
        });
      },
    );

    testWidgets(
      'an offset set elsewhere is offered as a choice and kept on save',
      (tester) async {
        final h = await pumpAt(
          tester,
          ClientPaths.cellMeetings,
          setUp: (h) => h.cells.meetings = boardWith(
            schedule: withReminders(['3 hours', '24 hours'], 6),
          ),
        );
        await tapKey(tester, 'reminders-edit-$_cell');
        await settle(tester);
        expect(byKey('reminder-choice-$_cell-3 hours'), findsOneWidget);
        await tapKey(tester, 'reminder-choice-$_cell-1 hour');
        await settle(tester);
        await tapKey(tester, 'reminders-save-$_cell');
        expect(h.gateway.sent.single.wire['payload'], {
          'cell_id': _cell,
          'reminders': [
            {'before': '1 hour'},
            {'before': '24 hours'},
            {'before': '3 hours'},
          ],
        });
      },
    );

    testWidgets('an assistant reads the reminders but has no change button', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.cellMeetings,
        setUp: (h) => h.cells.meetings = boardWith(
          role: 'assistant',
          canChange: false,
          schedule: withReminders(['2 hours'], 5),
        ),
      );
      expect(byKey('meeting-reminders-$_cell'), findsOneWidget);
      expect(byKey('reminders-edit-$_cell'), findsNothing);
    });

    testWidgets('members the app could not reach are named on the meeting', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.cellMeetings,
        setUp: (h) => h.cells.meetings = boardWith(
          meetings: [
            {
              ...meetingData(),
              'contact_needs': [
                {
                  'member_id': '56565656-5656-4656-8656-565656565656',
                  'display_name': 'SYNTHETIC Grace Banda',
                  'kinds': ['cells_meeting_reminder'],
                },
              ],
            },
          ],
        ),
      );
      expect(find.text('Tell directly: SYNTHETIC Grace Banda'), findsOneWidget);
    });

    test('meeting reminders and notices open My cell', () {
      expect(ClientPaths.isKnownDeepLink('/my-cell'), isTrue);
      expect(ClientPaths.isKnownDeepLink('/my-cell/x'), isFalse);
    });
  });

  group('mobile: My cell', () {
    testWidgets('shows the next meeting with its venue and pin, and the '
        'cancelled meeting before it', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.myCell,
        setUp: (h) => h.cells.mine = AccessReadOk(
          MyCell.fromJson(
            myCellData(
              meetings: {
                'cell_id': _cell,
                'next': meetingData(),
                'cancelled': [
                  {
                    'meeting_id': _cancelled,
                    'occurrence_date': '2099-02-27',
                    'nominal_starts_at': '2099-02-27T16:00:00.000000Z',
                  },
                ],
              },
            ),
          ),
        ),
      );
      expect(byKey('my-cell-next-meeting'), findsOneWidget);
      expect(
        tester.widget<Text>(byKey('my-cell-next-when')).data,
        contains('18:00–19:30'),
      );
      expect(find.text('SYNTHETIC 12 Shikoswe Road'), findsOneWidget);
      expect(find.text('Map pin: -15.77123, 28.18456'), findsOneWidget);
      expect(byKey('my-cell-cancelled-$_cancelled'), findsOneWidget);
    });

    testWidgets('no schedule: no meeting card; nothing planned: said so', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.myCell,
        setUp: (h) =>
            h.cells.mine = AccessReadOk(MyCell.fromJson(myCellData())),
      );
      expect(byKey('my-cell-current'), findsOneWidget);
      expect(byKey('my-cell-next-meeting'), findsNothing);
    });

    testWidgets('a cell with every meeting cancelled says nothing is planned', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.myCell,
        setUp: (h) => h.cells.mine = AccessReadOk(
          MyCell.fromJson(
            myCellData(
              meetings: {'cell_id': _cell, 'next': null, 'cancelled': []},
            ),
          ),
        ),
      );
      expect(byKey('my-cell-no-meeting'), findsOneWidget);
      expect(find.textContaining('Venue:'), findsNothing);
    });
  });
}
