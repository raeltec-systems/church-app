// Story 5.3: a meeting's programme draft on staff web (Plan meeting): the
// leader drafts timed parts with people from the cell, gaps stay visible,
// refused parts are shown on their row, Pastor oversight reads and an
// Admin-only reader sees counts. Fakes only; the server behaviour is covered
// by supabase/tests/cells_programmes_test.sql and
// tools/identity-e2e/cells-programmes.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _cell = '61616161-6161-4161-8161-616161616161';
const _meeting = '62626262-6262-4262-8262-626262626262';
const _programme = '63636363-6363-4363-8363-636363636363';
const _part1 = '64646464-6464-4464-8464-646464646464';
const _part2 = '65656565-6565-4565-8565-656565656565';
const _grace = '66666666-6666-4666-8666-666666666666';
const _abel = '67676767-6767-4767-8767-676767676767';
const _gone = '68686868-6868-4868-8868-686868686868';

Future<ClientTestHarness> pumpPlan(
  WidgetTester tester, {
  required AccessRead<ProgrammeRead> read,
  Size size = const Size(1200, 4000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = ClientTestHarness();
  h.cells.programme = read;
  final router = buildClientRouter(
    initialLocation: CellPaths.plan(_meeting),
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

/// A Friday meeting far ahead, 18:00-19:30 church time (16:00-17:30 UTC).
Map<String, Object?> meetingData({String state = 'scheduled'}) => {
  'meeting_id': _meeting,
  'cell_id': _cell,
  'occurrence_date': '2099-03-06',
  'state': state,
  'starts_at': '2099-03-06T16:00:00.000000Z',
  'ends_at': '2099-03-06T17:30:00.000000Z',
  'nominal_starts_at': '2099-03-06T16:00:00.000000Z',
  'nominal_ends_at': '2099-03-06T17:30:00.000000Z',
  'venue_moved': false,
  'venue': 'SYNTHETIC 12 Shikoswe Road',
  'map_pin': null,
  'revision': 1,
};

Map<String, Object?> part(
  String id,
  int position,
  String label,
  String start,
  String end, {
  Map<String, Object?>? assignee,
}) => {
  'part_id': id,
  'position': position,
  'label': label,
  'starts_at': start,
  'ends_at': end,
  'assignee': assignee,
};

Map<String, Object?> programmeData({
  String state = 'draft',
  int revision = 2,
  List<Map<String, Object?>>? parts,
}) {
  final ps =
      parts ??
      [
        part(
          _part1,
          1,
          'Opening prayer',
          '2099-03-06T16:00:00Z',
          '2099-03-06T16:10:00Z',
          assignee: {
            'member_id': _grace,
            'display_name': 'SYNTHETIC Grace Banda',
            'in_cell': true,
          },
        ),
        part(
          _part2,
          2,
          'Bible study',
          '2099-03-06T16:10:00Z',
          '2099-03-06T16:50:00Z',
        ),
      ];
  return {
    'programme_id': _programme,
    'meeting_id': _meeting,
    'state': state,
    'revision': revision,
    'topic': 'Rooted in love',
    'scripture': 'Ephesians 3:14-21',
    'study_notes': 'Ask about prayer partners.',
    'parts': ps,
    'gaps': ps.where((p) => p['assignee'] == null).length,
  };
}

final _roster = [
  {
    'member_id': _abel,
    'display_name': 'SYNTHETIC Abel Sakala',
    'account': 'no_login',
  },
  {
    'member_id': _grace,
    'display_name': 'SYNTHETIC Grace Banda',
    'account': 'app_account',
  },
];

AccessRead<ProgrammeRead> readWith({
  Map<String, Object?>? programme,
  bool none = false,
  bool canEdit = true,
  String view = 'full',
  String meetingState = 'scheduled',
}) => AccessReadOk(
  ProgrammeRead.fromJson({
    'meeting': meetingData(state: meetingState),
    'cell_name': 'SYNTHETIC Shikoswe Cell',
    'view': view,
    'can_edit': canEdit,
    'programme': none ? null : (programme ?? programmeData()),
    'roster': view == 'full' ? _roster : const [],
  }),
);

void main() {
  group('domain', () {
    test('the full read parses parts, gaps, assignees and the roster', () {
      final r = (readWith() as AccessReadOk<ProgrammeRead>).value;
      final p = r.programme!;
      expect(r.full, isTrue);
      expect(r.canEdit, isTrue);
      expect(p.draft, isTrue);
      expect(p.parts.map((x) => x.label), ['Opening prayer', 'Bible study']);
      expect(p.parts.first.assignee!.displayName, 'SYNTHETIC Grace Banda');
      expect(p.parts.last.gap, isTrue);
      expect(p.gaps, 1);
      expect(p.partCount, 2);
      expect(r.roster.first.offApp, isTrue);
      expect(ProgrammePartDraft.of(p.parts.first).toJson(), {
        'part_id': _part1,
        'label': 'Opening prayer',
        'start_time': '18:00',
        'end_time': '18:10',
        'assignee_member_id': _grace,
      });
    });

    test('the metadata read carries counts only', () {
      final r = ProgrammeRead.fromJson({
        'meeting': meetingData(),
        'cell_name': 'SYNTHETIC Shikoswe Cell',
        'view': 'metadata',
        'can_edit': false,
        'programme': {
          'programme_id': _programme,
          'meeting_id': _meeting,
          'state': 'draft',
          'revision': 3,
          'part_count': 4,
          'gaps': 1,
        },
        'roster': const [],
      });
      expect(r.full, isFalse);
      expect(r.programme!.parts, isEmpty);
      expect(r.programme!.partCount, 4);
      expect(r.programme!.topic, isNull);
    });

    test('unexpected shapes are refused, never guessed', () {
      Map<String, Object?> base() => {
        'meeting': meetingData(),
        'cell_name': 'C',
        'view': 'full',
        'can_edit': true,
        'programme': programmeData(),
        'roster': _roster,
      };
      expect(
        () => ProgrammeRead.fromJson({...base(), 'view': 'all'}),
        throwsFormatException,
      );
      expect(
        () => ProgrammeRead.fromJson({...base(), 'view': 'metadata'}),
        throwsFormatException,
        reason: 'metadata readers never edit',
      );
      expect(
        () => ProgrammeRead.fromJson({
          ...base(),
          'programme': {...programmeData(), 'state': 'published'},
        }),
        throwsFormatException,
      );
      expect(
        () => ProgrammeRead.fromJson({
          ...base(),
          'programme': programmeData(
            parts: [part(_part1, 1, 'X', '2099-03-06T18:00:00+02:00', 'x')],
          ),
        }),
        throwsFormatException,
      );
    });
  });

  group('Plan meeting (staff web)', () {
    testWidgets('answers how planned the meeting is first, with the gap '
        'in view and a member preview', (tester) async {
      final h = await pumpPlan(tester, read: readWith());
      expect(h.cells.programmeAsked, [_meeting]);
      expect(
        tester.widget<Text>(byKey('plan-when')).data,
        startsWith('Friday'),
      );
      expect(find.text('2 parts, 1 gap'), findsOneWidget);
      expect(byKey('plan-state-draft'), findsOneWidget);
      expect(byKey('part-gap-1'), findsOneWidget);
      expect(byKey('part-gap-0'), findsNothing);
      expect(byKey('plan-preview'), findsOneWidget);
      expect(find.text('Open: nobody yet'), findsOneWidget);
      // Members without a login are on the roster, marked.
      await tapKey(tester, 'part-assignee-1');
      await settle(tester);
      expect(find.text('SYNTHETIC Abel Sakala (no app login)'), findsWidgets);
    });

    testWidgets('a save sends the whole draft at the programme revision, '
        'keeping part ids and leaving gaps open', (tester) async {
      final h = await pumpPlan(tester, read: readWith());
      await tester.enterText(byKey('plan-topic'), '  Rooted and grounded ');
      await tapKey(tester, 'plan-add-part');
      await settle(tester);
      // The new part starts where the last one ends.
      expect(
        tester.widget<TextField>(byKey('part-start-2')).controller!.text,
        '18:50',
      );
      expect(
        tester.widget<TextField>(byKey('part-end-2')).controller!.text,
        '19:05',
      );
      await tester.enterText(byKey('part-label-2'), 'Closing prayer');
      await settle(tester);
      await tapKey(tester, 'plan-save');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'cells_command');
      expect(sent.wire['command'], 'cells.save_programme');
      expect(sent.wire['expected_revision'], 2);
      expect(sent.wire['payload'], {
        'programme_id': _programme,
        'topic': 'Rooted and grounded',
        'scripture': 'Ephesians 3:14-21',
        'study_notes': 'Ask about prayer partners.',
        'parts': [
          {
            'part_id': _part1,
            'label': 'Opening prayer',
            'start_time': '18:00',
            'end_time': '18:10',
            'assignee_member_id': _grace,
          },
          {
            'part_id': _part2,
            'label': 'Bible study',
            'start_time': '18:10',
            'end_time': '18:50',
            'assignee_member_id': null,
          },
          {
            'label': 'Closing prayer',
            'start_time': '18:50',
            'end_time': '19:05',
            'assignee_member_id': null,
          },
        ],
      });
      sent.confirm(programmeData(revision: 3), 3);
      await settle(tester);
      expect(byKey('cells-notice-programmeSaved'), findsOneWidget);
      expect(h.cells.programmeAsked, hasLength(2));
    });

    testWidgets('refused parts are shown on their own row; the typed draft '
        'is kept', (tester) async {
      final h = await pumpPlan(tester, read: readWith());
      await tester.enterText(byKey('part-start-1'), '17:30');
      await settle(tester);
      await tapKey(tester, 'plan-save');
      h.gateway.sent.single.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'parts.1': 'outside_meeting'},
      );
      await settle(tester);
      expect(byKey('cells-notice-invalid'), findsOneWidget);
      expect(
        tester.widget<Text>(byKey('part-error-1')).data,
        'Keep it inside the meeting (18:00-19:30)',
      );
      expect(byKey('part-error-0'), findsNothing);
      expect(
        tester.widget<TextField>(byKey('part-start-1')).controller!.text,
        '17:30',
      );
      // Invalid input is not a reason to ask the server again.
      expect(h.cells.programmeAsked, hasLength(1));
    });

    testWidgets('a stale save is a conflict: the page reloads the server\'s '
        'draft', (tester) async {
      final h = await pumpPlan(tester, read: readWith());
      await tester.enterText(byKey('plan-topic'), 'Mine');
      await tapKey(tester, 'plan-save');
      h.cells.programme = readWith(
        programme: {...programmeData(revision: 5), 'topic': 'Theirs'},
      );
      h.gateway.sent.single.refuse(ErrorCode.conflict);
      await settle(tester);
      expect(byKey('cells-notice-changedElsewhere'), findsOneWidget);
      expect(
        tester.widget<TextField>(byKey('plan-topic')).controller!.text,
        'Theirs',
      );
    });

    testWidgets('a part whose person left the cell says so and can be '
        'reassigned', (tester) async {
      await pumpPlan(
        tester,
        read: readWith(
          programme: programmeData(
            parts: [
              part(
                _part1,
                1,
                'Worship',
                '2099-03-06T16:00:00Z',
                '2099-03-06T16:20:00Z',
                assignee: {
                  'member_id': _gone,
                  'display_name': 'SYNTHETIC Ruth Zulu',
                  'in_cell': false,
                },
              ),
            ],
          ),
        ),
      );
      expect(
        find.text('This person has left the cell. Choose someone else.'),
        findsOneWidget,
      );
      expect(find.text('SYNTHETIC Ruth Zulu (left the cell)'), findsWidgets);
    });

    testWidgets('a meeting without a programme is started by the leader', (
      tester,
    ) async {
      final h = await pumpPlan(tester, read: readWith(none: true));
      expect(byKey('plan-state-none'), findsOneWidget);
      await tapKey(tester, 'plan-create');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'cells.create_programme');
      expect(sent.wire['expected_revision'], isNull);
      expect(sent.wire['payload'], {'meeting_id': _meeting});
      h.cells.programme = readWith(
        programme: programmeData(revision: 1, parts: const []),
      );
      sent.confirm(programmeData(revision: 1, parts: const []), 1);
      await settle(tester);
      expect(byKey('cells-notice-programmeCreated'), findsOneWidget);
      expect(byKey('plan-no-parts'), findsOneWidget);
      expect(find.text('No parts yet'), findsOneWidget);
    });

    testWidgets('cancelling asks once more, then sends the revision', (
      tester,
    ) async {
      final h = await pumpPlan(tester, read: readWith());
      await tapKey(tester, 'plan-cancel');
      await settle(tester);
      expect(h.gateway.sent, isEmpty);
      await tapKey(tester, 'plan-cancel-confirm');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'cells.cancel_programme');
      expect(sent.wire['expected_revision'], 2);
      expect(sent.wire['payload'], {'programme_id': _programme});
    });

    testWidgets('Pastor oversight reads the draft without an editor', (
      tester,
    ) async {
      await pumpPlan(tester, read: readWith(canEdit: false));
      expect(byKey('plan-save'), findsNothing);
      expect(byKey('plan-topic'), findsNothing);
      expect(find.text('Read only.'), findsOneWidget);
      expect(find.text('Rooted in love'), findsOneWidget);
      expect(find.text('SYNTHETIC Grace Banda'), findsOneWidget);
    });

    testWidgets('an Admin-only reader sees counts, never content or names', (
      tester,
    ) async {
      await pumpPlan(
        tester,
        read: AccessReadOk(
          ProgrammeRead.fromJson({
            'meeting': {...meetingData(), 'venue': null},
            'cell_name': 'SYNTHETIC Shikoswe Cell',
            'view': 'metadata',
            'can_edit': false,
            'programme': {
              'programme_id': _programme,
              'meeting_id': _meeting,
              'state': 'draft',
              'revision': 3,
              'part_count': 4,
              'gaps': 1,
            },
            'roster': const [],
          }),
        ),
      );
      expect(find.text('4 parts, 1 gap'), findsOneWidget);
      expect(byKey('plan-preview'), findsNothing);
      expect(byKey('plan-save'), findsNothing);
      expect(find.textContaining('Rooted'), findsNothing);
    });

    testWidgets('a cancelled programme is read-only', (tester) async {
      await pumpPlan(
        tester,
        read: readWith(programme: programmeData(state: 'cancelled')),
      );
      expect(byKey('plan-state-cancelled'), findsOneWidget);
      expect(byKey('plan-save'), findsNothing);
    });

    testWidgets('the server\'s denial shows; nothing is drawn', (tester) async {
      await pumpPlan(
        tester,
        read: const AccessReadDenied(AccessDenial.notGranted),
      );
      expect(byKey('cells-denied-notGranted'), findsOneWidget);
      expect(byKey('plan-when'), findsNothing);
    });

    testWidgets('a phone-width editor stacks each part', (tester) async {
      await pumpPlan(tester, read: readWith(), size: const Size(400, 5000));
      expect(byKey('part-label-0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Cell meetings', () {
    testWidgets('the leader opens Plan from a meeting row', (tester) async {
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final h = ClientTestHarness();
      h.cells.meetings = AccessReadOk(
        CellMeetingsBoard.fromJson({
          'cells': [
            {
              'cell_id': _cell,
              'name': 'SYNTHETIC Shikoswe Cell',
              'is_synthetic': true,
              'role': 'assistant',
              'can_change': false,
              'can_set_schedule': false,
              'schedule': {
                'weekday': 5,
                'start_time': '18:00',
                'end_time': '19:30',
                'from_date': '2026-10-21',
                'zone': 'Africa/Lusaka',
                'venue_set': true,
                'pin_set': false,
                'venue': 'SYNTHETIC 12 Shikoswe Road',
              },
              'meetings': [meetingData()],
            },
          ],
        }),
      );
      h.cells.programme = readWith();
      final router = buildClientRouter(
        initialLocation: ClientPaths.cellMeetings,
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
      await tapKey(tester, 'meeting-plan-$_meeting');
      await settle(tester);
      expect(h.cells.programmeAsked, [_meeting]);
      expect(byKey('plan-when'), findsOneWidget);
    });
  });
}
