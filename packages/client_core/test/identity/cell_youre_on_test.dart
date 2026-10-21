// Story 5.5: You're on. The member's own published part leads mobile My cell
// with its real answer (from My duties), reporting time and instructions,
// answered through the Duties response command; Home shows My cell; the
// cell's leader records a direct confirmation on staff web. Fakes only; the
// server behaviour is covered by supabase/tests/cells_youre_on_test.sql and
// tools/identity-e2e/cells-youre-on.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _cell = '71717171-7171-4171-8171-717171717171';
const _meeting = '72727272-7272-4272-8272-727272727272';
const _programme = '73737373-7373-4373-8373-737373737373';
const _part1 = '74747474-7474-4474-8474-747474747474';
const _part2 = '75757575-7575-4575-8575-757575757575';
const _assignment = '76767676-7676-4676-8676-767676767676';
// myDutyData's occurrence.
const _occurrence = '43434343-4343-4343-8343-434343434343';

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? setUp,
  bool memberHome = false,
}) async {
  tester.view.physicalSize = const Size(1200, 5000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = ClientTestHarness();
  setUp?.call(h);
  final router = buildClientRouter(
    initialLocation: location,
    memberHome: memberHome,
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
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder byKey(String k) => find.byKey(Key(k));

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(byKey(key));
  await tester.tap(byKey(key));
  await tester.pump();
}

Map<String, Object?> meetingData() => {
  'meeting_id': _meeting,
  'cell_id': _cell,
  'occurrence_date': '2099-03-06',
  'state': 'scheduled',
  'starts_at': '2099-03-06T16:00:00.000000Z',
  'ends_at': '2099-03-06T17:30:00.000000Z',
  'nominal_starts_at': '2099-03-06T16:00:00.000000Z',
  'nominal_ends_at': '2099-03-06T17:30:00.000000Z',
  'venue_moved': false,
  'venue': 'SYNTHETIC 12 Shikoswe Road',
  'map_pin': null,
  'revision': 1,
};

AccessRead<MyCell> myCell({bool withMeeting = true}) => AccessReadOk(
  MyCell.fromJson({
    'member_id': '77777777-7777-4777-8777-777777777777',
    'revision': 3,
    'primary': {
      'membership_id': '78787878-7878-4878-8878-787878787878',
      'cell_id': _cell,
      'label': 'SYNTHETIC Shikoswe',
      'broad_area': 'SYNTHETIC Kafue East',
      'since': '2026-10-07T12:00:00.000000Z',
    },
    'open_request': null,
    'last_decision': null,
    'meetings': {
      'cell_id': _cell,
      'next': withMeeting ? meetingData() : null,
      'cancelled': const [],
    },
  }),
);

const _notice = '7a7a7a7a-7a7a-4a7a-8a7a-7a7a7a7a7a7a';

AccessRead<MeetingProgrammeRead> programme({
  bool published = true,
  bool meetingChanged = false,
  Map<String, Object?>? myAbsence,
}) => AccessReadOk(
  MeetingProgrammeRead.fromJson({
    'meeting': meetingData(),
    'programme': published
        ? {
            'programme_id': _programme,
            'meeting_id': _meeting,
            'topic': 'Rooted in love',
            'scripture': 'Ephesians 3:14-21',
            'revision': 3,
            'published_at': '2099-03-01T10:00:00Z',
            'meeting_changed': meetingChanged,
            'parts': [
              {
                'part_id': _part1,
                'label': 'Opening prayer',
                'starts_at': '2099-03-06T16:00:00Z',
                'ends_at': '2099-03-06T16:10:00Z',
                'leader': 'SYNTHETIC Member',
                'department': null,
              },
              {
                'part_id': _part2,
                'label': 'Bible study',
                'starts_at': '2099-03-06T16:10:00Z',
                'ends_at': '2099-03-06T16:50:00Z',
                'leader': 'SYNTHETIC Grace Banda',
                'department': null,
              },
            ],
          }
        : null,
    'yours': published
        ? [
            {'part_id': _part1, 'occurrence_id': _occurrence},
          ]
        : const [],
    'my_absence': myAbsence,
  }),
);

AccessRead<MyDuties> myDuties({
  String response = 'pending',
  Map<String, Object?> extra = const {},
}) => AccessReadOk(
  MyDuties.fromJson({
    'member_id': '77777777-7777-4777-8777-777777777777',
    'assignments': [
      myDutyData(
        assignmentId: _assignment,
        revision: 4,
        ownerKind: 'cell',
        dutyName: 'Opening prayer',
        response: response,
        respondedAt: response == 'pending' ? null : '2099-03-02T09:00:00Z',
        reportingAt: '2099-03-06T15:45:00.000000Z',
        startsAt: '2099-03-06T16:00:00.000000Z',
        endsAt: '2099-03-06T16:10:00.000000Z',
        extra: extra,
      ),
    ],
  }),
);

void main() {
  group('domain', () {
    test('the member read names the reader\'s own parts', () {
      final r = (programme() as AccessReadOk<MeetingProgrammeRead>).value;
      expect(r.occurrenceOf(_part1), _occurrence);
      expect(r.occurrenceOf(_part2), isNull);
      final older = MeetingProgrammeRead.fromJson({
        'meeting': meetingData(),
        'programme': null,
      });
      expect(older.yours, isEmpty);
    });

    test('a waiting part with its assignment can be confirmed by the '
        'leader', () {
      final d = PartDuty.fromJson({
        'part_id': _part1,
        'positions': [
          {
            'kind': 'owned',
            'position_key': 'lead',
            'cancelled': false,
            'assignment': {
              'assignment_id': _assignment,
              'revision': 2,
              'response': 'pending',
              'response_provenance': null,
            },
          },
        ],
      });
      expect(d.confirmable, isTrue);
      expect(d.assignmentRevision, 2);
    });
  });

  group('mobile My cell', () {
    testWidgets('You\'re on leads with the real answer, reporting time and '
        'instructions; Accept answers through Duties', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.myCell,
        setUp: (h) {
          h.cells.mine = myCell();
          h.cells.meetingProgramme = programme();
          h.duties.mine = myDuties();
        },
      );
      expect(byKey('my-cell-yours-$_part1'), findsOneWidget);
      expect(
        tester.widget<StatusLabel>(byKey('my-cell-status-$_part1')).label,
        'Awaiting your answer',
      );
      expect(find.text('Please arrive by 17:45'), findsOneWidget);
      expect(find.text('Arrive early.'), findsOneWidget);
      // Others' parts show names, never answers.
      expect(find.text('SYNTHETIC Grace Banda'), findsOneWidget);
      expect(find.text('You'), findsOneWidget);
      await tapKey(tester, 'my-cell-accept-$_part1');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'duties_command');
      expect(sent.wire['command'], 'duties.respond');
      expect(sent.wire['expected_revision'], 4);
      expect(sent.wire['payload'], {
        'assignment_id': _assignment,
        'response': 'accepted',
      });
    });

    testWidgets('Can\'t do it asks once more; a refused answer is said on '
        'the card', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.myCell,
        setUp: (h) {
          h.cells.mine = myCell();
          h.cells.meetingProgramme = programme();
          h.duties.mine = myDuties();
        },
      );
      await tapKey(tester, 'my-cell-decline-$_part1');
      await settle(tester);
      expect(h.gateway.sent, isEmpty);
      await tapKey(tester, 'my-cell-decline-confirm-$_part1');
      final sent = h.gateway.sent.single;
      expect(sent.wire['payload'], {
        'assignment_id': _assignment,
        'response': 'declined',
      });
      expect(find.text('Sending your answer…'), findsOneWidget);
      sent.refuse(ErrorCode.conflict);
      await settle(tester);
      expect(byKey('my-cell-answer-problem-$_part1'), findsOneWidget);
    });

    testWidgets('My duties loading or failing is said, never blank', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.myCell,
        setUp: (h) {
          h.cells.mine = myCell();
          h.cells.meetingProgramme = programme();
          h.duties.mine = const AccessReadFailed(unreachable: true);
        },
      );
      expect(
        find.textContaining('Your answer could not be loaded here'),
        findsOneWidget,
      );
      expect(byKey('my-cell-accept-$_part1'), findsNothing);
    });

    testWidgets('Confirmed by leader reads as such, with no buttons', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.myCell,
        setUp: (h) {
          h.cells.mine = myCell();
          h.cells.meetingProgramme = programme();
          h.duties.mine = myDuties(
            response: 'accepted',
            extra: {
              'response_provenance': 'leader',
              'confirmed_channel': 'phone',
            },
          );
        },
      );
      expect(
        tester.widget<StatusLabel>(byKey('my-cell-status-$_part1')).label,
        'Confirmed by leader',
      );
      expect(byKey('my-cell-accept-$_part1'), findsNothing);
    });

    testWidgets('story 5.6: a moved meeting says the programme is being '
        'updated', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.myCell,
        setUp: (h) {
          h.cells.mine = myCell();
          h.cells.meetingProgramme = programme(meetingChanged: true);
          h.duties.mine = myDuties();
        },
      );
      expect(byKey('my-cell-programme-updating'), findsOneWidget);
    });

    testWidgets('an unpublished programme says so', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.myCell,
        setUp: (h) {
          h.cells.mine = myCell();
          h.cells.meetingProgramme = programme(published: false);
        },
      );
      expect(byKey('my-cell-programme-none'), findsOneWidget);
      expect(byKey('my-cell-yours-$_part1'), findsNothing);
    });
  });

  group('story 5.7: Cannot attend', () {
    test('the leaders\' notice opens Cell meetings', () {
      expect(ClientPaths.isKnownDeepLink('/cells/meetings'), isTrue);
    });

    testWidgets('a member sends a notice with a note; their part is still '
        'theirs', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.myCell,
        setUp: (h) {
          h.cells.mine = myCell();
          h.cells.meetingProgramme = programme();
          h.duties.mine = myDuties();
        },
      );
      await tapKey(tester, 'my-cell-absence-start');
      await settle(tester);
      await tester.enterText(
        byKey('my-cell-absence-note'),
        'Travelling for work',
      );
      await tapKey(tester, 'my-cell-absence-send');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'cells_command');
      expect(sent.wire['command'], 'cells.send_cannot_attend');
      expect(sent.wire['expected_revision'], isNull);
      expect(sent.wire['payload'], {
        'meeting_id': _meeting,
        'note': 'Travelling for work',
      });
      h.cells.meetingProgramme = programme(
        myAbsence: {
          'notice_id': _notice,
          'meeting_id': _meeting,
          'state': 'open',
          'revision': 1,
          'note': 'Travelling for work',
          'sent_at': '2099-03-01T10:00:00Z',
          'updated_at': '2099-03-01T10:00:00Z',
        },
      );
      sent.confirm({'notice_id': _notice}, 1);
      await settle(tester);
      expect(byKey('my-cell-absence-notice-absenceSent'), findsOneWidget);
      expect(byKey('my-cell-absence-sent'), findsOneWidget);
      expect(find.text('Your note: Travelling for work'), findsOneWidget);
      expect(byKey('my-cell-absence-part'), findsOneWidget);
      // The duty answer is untouched: still waiting, with its buttons.
      expect(
        tester.widget<StatusLabel>(byKey('my-cell-status-$_part1')).label,
        'Awaiting your answer',
      );
    });

    testWidgets('the note is changed at its revision; I can come after all '
        'asks once more', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.myCell,
        setUp: (h) {
          h.cells.mine = myCell();
          h.cells.meetingProgramme = programme(
            published: false,
            myAbsence: {
              'notice_id': _notice,
              'meeting_id': _meeting,
              'state': 'open',
              'revision': 2,
              'note': 'Late',
              'sent_at': '2099-03-01T10:00:00Z',
              'updated_at': '2099-03-01T10:00:00Z',
            },
          );
        },
      );
      expect(byKey('my-cell-absence-part'), findsNothing);
      await tapKey(tester, 'my-cell-absence-change');
      await settle(tester);
      await tester.enterText(byKey('my-cell-absence-note'), 'Very late');
      await tapKey(tester, 'my-cell-absence-send');
      expect(
        h.gateway.sent.single.wire['command'],
        'cells.change_cannot_attend',
      );
      expect(h.gateway.sent.single.wire['expected_revision'], 2);
      h.gateway.sent.single.unknown();
      await settle(tester);
      // An unknown outcome keeps the form; the member closes it.
      await tapKey(tester, 'my-cell-absence-keep');
      await settle(tester);
      await tapKey(tester, 'my-cell-absence-withdraw');
      await settle(tester);
      expect(h.gateway.sent, hasLength(1));
      await tapKey(tester, 'my-cell-absence-withdraw-confirm');
      expect(
        h.gateway.sent.last.wire['command'],
        'cells.withdraw_cannot_attend',
      );
      expect(h.gateway.sent.last.wire['payload'], {'notice_id': _notice});
    });

    testWidgets('the leader sees who can\'t attend and the part at risk', (
      tester,
    ) async {
      await pumpAt(
        tester,
        CellPaths.plan(_meeting),
        setUp: (h) => h.cells.programme = AccessReadOk(
          ProgrammeRead.fromJson({
            'meeting': meetingData(),
            'cell_name': 'SYNTHETIC Shikoswe Cell',
            'view': 'full',
            'can_edit': true,
            'programme': {
              'programme_id': _programme,
              'meeting_id': _meeting,
              'state': 'published',
              'revision': 3,
              'published_revision': 3,
              'parts': [
                {
                  'part_id': _part1,
                  'position': 1,
                  'label': 'Opening prayer',
                  'starts_at': '2099-03-06T16:00:00Z',
                  'ends_at': '2099-03-06T16:10:00Z',
                  'assignee': {
                    'member_id': '79797979-7979-4979-8979-797979797979',
                    'display_name': 'SYNTHETIC Member',
                    'in_cell': true,
                  },
                },
              ],
              'gaps': 0,
            },
            'roster': const [],
            'duties': [
              {
                'part_id': _part1,
                'occurrence_state': 'published',
                'positions': [
                  {
                    'kind': 'owned',
                    'position_key': 'lead',
                    'cancelled': false,
                    'assignment': {
                      'assignment_id': _assignment,
                      'revision': 2,
                      'response': 'accepted',
                      'response_provenance': 'member',
                    },
                  },
                ],
              },
            ],
            'absences': [
              {
                'notice_id': _notice,
                'member_id': '79797979-7979-4979-8979-797979797979',
                'display_name': 'SYNTHETIC Member',
                'note': 'Travelling for work',
                'sent_at': '2099-03-01T10:00:00Z',
                'updated_at': '2099-03-01T10:00:00Z',
                'part_ids': [_part1],
              },
            ],
          }),
        ),
      );
      expect(byKey('plan-absences'), findsOneWidget);
      expect(find.text('Can\'t attend (1)'), findsOneWidget);
      expect(find.text('Travelling for work'), findsOneWidget);
      expect(byKey('published-absence-$_part1'), findsOneWidget);
      // The answer stays the member's own (Accepted), next to the warning.
      expect(
        tester.widget<StatusLabel>(byKey('published-status-$_part1')).label,
        'Accepted',
      );
    });
  });

  group('mobile Home', () {
    testWidgets('My cell shows the next meeting and You\'re on with the '
        'answer', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.home,
        memberHome: true,
        setUp: (h) {
          h.cells.mine = myCell();
          h.cells.meetingProgramme = programme();
          h.duties.mine = myDuties();
        },
      );
      expect(byKey('home-my-cell'), findsOneWidget);
      expect(
        tester.widget<Text>(byKey('home-my-cell-when')).data,
        startsWith('Friday'),
      );
      expect(byKey('home-my-cell-yours-$_part1'), findsOneWidget);
      expect(find.text('You\'re on: Opening prayer, 18:00'), findsOneWidget);
      expect(find.text('Awaiting your answer'), findsWidgets);
    });

    testWidgets('a programme that cannot be loaded is said on Home', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.home,
        memberHome: true,
        setUp: (h) {
          h.cells.mine = myCell();
          h.cells.meetingProgramme = const AccessReadFailed(unreachable: true);
        },
      );
      expect(byKey('home-my-cell-programme-unavailable'), findsOneWidget);
    });

    testWidgets('no cell, no card', (tester) async {
      await pumpAt(tester, ClientPaths.home, memberHome: true);
      expect(byKey('home-my-cell'), findsNothing);
    });
  });

  group('staff web Plan meeting', () {
    testWidgets('the leader records that a member said yes directly', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        CellPaths.plan(_meeting),
        setUp: (h) => h.cells.programme = AccessReadOk(
          ProgrammeRead.fromJson({
            'meeting': meetingData(),
            'cell_name': 'SYNTHETIC Shikoswe Cell',
            'view': 'full',
            'can_edit': true,
            'programme': {
              'programme_id': _programme,
              'meeting_id': _meeting,
              'state': 'published',
              'revision': 3,
              'published_revision': 3,
              'published_at': '2099-03-01T10:00:00Z',
              'parts': [
                {
                  'part_id': _part1,
                  'position': 1,
                  'label': 'Opening prayer',
                  'starts_at': '2099-03-06T16:00:00Z',
                  'ends_at': '2099-03-06T16:10:00Z',
                  'assignee': {
                    'member_id': '79797979-7979-4979-8979-797979797979',
                    'display_name': 'SYNTHETIC Accountless',
                    'in_cell': true,
                  },
                },
              ],
              'gaps': 0,
            },
            'roster': const [],
            'duties': [
              {
                'part_id': _part1,
                'occurrence_state': 'published',
                'positions': [
                  {
                    'kind': 'owned',
                    'position_key': 'lead',
                    'cancelled': false,
                    'assignment': {
                      'assignment_id': _assignment,
                      'revision': 2,
                      'response': 'pending',
                      'response_provenance': null,
                      'needs_contact': true,
                    },
                  },
                ],
              },
            ],
          }),
        ),
      );
      await tapKey(tester, 'confirm-part-$_part1');
      await settle(tester);
      expect(
        tester.widget<FilledButton>(byKey('confirm-save-$_part1')).onPressed,
        isNull,
      );
      await tester.enterText(
        byKey('confirm-reason-$_part1'),
        'Said yes on the phone',
      );
      await settle(tester);
      await tapKey(tester, 'confirm-save-$_part1');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'duties_command');
      expect(sent.wire['command'], 'duties.confirm_by_leader');
      expect(sent.wire['expected_revision'], 2);
      expect(sent.wire['payload'], {
        'assignment_id': _assignment,
        'channel': 'phone',
        'reason': 'Said yes on the phone',
      });
      sent.refuse(ErrorCode.conflict);
      await settle(tester);
      // A refusal keeps the form and what was typed.
      expect(byKey('confirm-form-$_part1'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(byKey('confirm-reason-$_part1'))
            .controller!
            .text,
        'Said yes on the phone',
      );
      await tapKey(tester, 'confirm-save-$_part1');
      h.gateway.sent.last.confirm({
        'assignment_id': _assignment,
        'revision': 3,
      }, 3);
      await settle(tester);
      expect(byKey('cells-notice-leaderConfirmed'), findsOneWidget);
    });
  });
}
