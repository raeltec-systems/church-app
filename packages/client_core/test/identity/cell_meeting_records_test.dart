// Story 5.8: after the meeting. On Plan meeting the cell's leader records
// whether a started meeting was held and who actually led each part (one
// click for the parts led as planned, a change with a reason, earlier values
// shown); Cell meetings lists the last four weeks with their status. Fakes
// only; the server behaviour is covered by
// supabase/tests/cells_meeting_records_test.sql and
// tools/identity-e2e/cells-meeting-records.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _cell = '81818181-8181-4181-8181-818181818181';
const _meeting = '82828282-8282-4282-8282-828282828282';
const _programme = '83838383-8383-4383-8383-838383838383';
const _part1 = '84848484-8484-4484-8484-848484848484';
const _part2 = '85858585-8585-4585-8585-858585858585';
const _planned1 = '86868686-8686-4686-8686-868686868686';
const _planned2 = '87878787-8787-4787-8787-878787878787';
const _standIn = '88888888-8888-4888-8888-888888888888';

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? setUp,
}) async {
  tester.view.physicalSize = const Size(1200, 5000);
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

// A meeting last week.
Map<String, Object?> meetingData() => {
  'meeting_id': _meeting,
  'cell_id': _cell,
  'occurrence_date': '2026-03-06',
  'state': 'scheduled',
  'starts_at': '2026-03-06T16:00:00.000000Z',
  'ends_at': '2026-03-06T17:30:00.000000Z',
  'nominal_starts_at': '2026-03-06T16:00:00.000000Z',
  'nominal_ends_at': '2026-03-06T17:30:00.000000Z',
  'venue_moved': false,
  'venue': 'SYNTHETIC 12 Shikoswe Road',
  'map_pin': null,
  'revision': 1,
};

Map<String, Object?> part(String id, int pos, String label, String member) => {
  'part_id': id,
  'position': pos,
  'label': label,
  'starts_at': '2026-03-06T16:${pos == 1 ? '00' : '10'}:00Z',
  'ends_at': '2026-03-06T16:${pos == 1 ? '10' : '50'}:00Z',
  'assignee': {
    'member_id': member,
    'display_name': 'SYNTHETIC Planned $pos',
    'in_cell': true,
  },
};

AccessRead<ProgrammeRead> read({
  Map<String, Object?>? record,
  String status = 'unrecorded',
  bool canEdit = true,
}) => AccessReadOk(
  ProgrammeRead.fromJson({
    'meeting': meetingData(),
    'cell_name': 'SYNTHETIC Shikoswe Cell',
    'view': 'full',
    'can_edit': canEdit,
    'programme': {
      'programme_id': _programme,
      'meeting_id': _meeting,
      'state': 'published',
      'revision': 3,
      'published_revision': 3,
      'published_at': '2026-03-01T10:00:00Z',
      'parts': [
        part(_part1, 1, 'Opening prayer', _planned1),
        part(_part2, 2, 'Bible study', _planned2),
      ],
      'gaps': 0,
    },
    'roster': [
      for (final (id, name) in [
        (_planned1, 'SYNTHETIC Planned 1'),
        (_planned2, 'SYNTHETIC Planned 2'),
        (_standIn, 'SYNTHETIC Stand In'),
      ])
        {'member_id': id, 'display_name': name, 'account': 'app_account'},
    ],
    'status': status,
    'record': record,
    'can_record': canEdit,
  }),
);

Map<String, Object?> heldRecord({
  List<Map<String, Object?>> actual = const [],
}) => {
  'held': true,
  'revision': 2,
  'recorded_at': '2026-03-06T18:00:00Z',
  'updated_at': '2026-03-06T18:00:00Z',
  'history': [
    {
      'revision': 1,
      'held': true,
      'reason': null,
      'by': 'SYNTHETIC Leader',
      'at': '2026-03-06T18:00:00Z',
    },
  ],
  'actual': actual,
};

Map<String, Object?> actual(
  String partId,
  String memberId,
  String name, {
  bool substitute = false,
  String? reason,
  List<Map<String, Object?>> earlier = const [],
}) => {
  'actual_id': '89898989-8989-4989-8989-898989898989',
  'part_id': partId,
  'kind': 'member',
  'member_id': memberId,
  'display_name': name,
  'guest_name': null,
  'planned_member_id': _planned2,
  'substitute': substitute,
  'reason': reason,
  'recorded_at': '2026-03-06T18:05:00Z',
  'recorded_by': 'SYNTHETIC Leader',
  'earlier': earlier,
};

void main() {
  group('domain', () {
    test('a guest reads as a guest; a 5.7 server has no record', () {
      final a = ActualLeader.fromJson({
        ...actual(_part2, _standIn, 'x'),
        'kind': 'guest',
        'member_id': null,
        'display_name': null,
        'guest_name': 'SYNTHETIC Visiting Pastor',
        'substitute': true,
      });
      expect(a.who, 'SYNTHETIC Visiting Pastor (guest)');
      final older = ProgrammeRead.fromJson({
        'meeting': meetingData(),
        'cell_name': 'x',
        'view': 'full',
        'can_edit': true,
        'programme': null,
        'roster': const [],
      });
      expect(older.record, isNull);
      expect(older.status, isNull);
      expect(older.canRecord, isFalse);
    });

    test('nobody is sent as a null leader, a reason only when given', () {
      expect(const ActualLeaderDraft(partId: _part1).toJson(), {
        'part_id': _part1,
        'leader': null,
      });
      expect(
        const ActualLeaderDraft(
          partId: _part1,
          guestName: ' SYNTHETIC Guest ',
          reason: ' it was them ',
        ).toJson(),
        {
          'part_id': _part1,
          'leader': {'name': 'SYNTHETIC Guest'},
          'reason': 'it was them',
        },
      );
    });
  });

  group('staff web, Plan meeting after the meeting', () {
    testWidgets('a started meeting asks whether it was held; Yes records it '
        'with no revision', (tester) async {
      final h = await pumpAt(
        tester,
        CellPaths.plan(_meeting),
        setUp: (h) => h.cells.programme = read(),
      );
      expect(
        tester.widget<StatusLabel>(byKey('plan-status')).label,
        'Not recorded',
      );
      expect(find.text('Was this meeting held?'), findsOneWidget);
      await tapKey(tester, 'record-held');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'cells.record_meeting_held');
      expect(sent.wire['expected_revision'], isNull);
      expect(sent.wire['payload'], {'meeting_id': _meeting, 'held': true});
    });

    testWidgets('one click records the parts led as planned; a substitute is '
        'chosen per part', (tester) async {
      final h = await pumpAt(
        tester,
        CellPaths.plan(_meeting),
        setUp: (h) =>
            h.cells.programme = read(status: 'held', record: heldRecord()),
      );
      expect(tester.widget<StatusLabel>(byKey('record-state')).label, 'Held');
      expect(
        tester.widget<StatusLabel>(byKey('record-actual-$_part1')).label,
        'Not recorded',
      );
      expect(find.text('2 parts were led as planned'), findsOneWidget);
      await tapKey(tester, 'record-all-planned');
      final all = h.gateway.sent.single;
      expect(all.wire['command'], 'cells.record_actual_leaders');
      expect(all.wire['expected_revision'], 2);
      expect(all.wire['payload'], {
        'meeting_id': _meeting,
        'parts': [
          {
            'part_id': _part1,
            'leader': {'member_id': _planned1},
          },
          {
            'part_id': _part2,
            'leader': {'member_id': _planned2},
          },
        ],
      });
      all.refuse(ErrorCode.conflict);
      await settle(tester);
      // Per part: the planned person is preselected, another member chosen.
      await tapKey(tester, 'record-edit-$_part2');
      await settle(tester);
      expect(
        tester
            .widget<DropdownButton<String>>(byKey('record-who-$_part2'))
            .value,
        _planned2,
      );
      await tapKey(tester, 'record-who-$_part2');
      await settle(tester);
      await tester.tap(find.text('SYNTHETIC Stand In').last);
      await settle(tester);
      await tapKey(tester, 'record-save-$_part2');
      expect(h.gateway.sent.last.wire['payload'], {
        'meeting_id': _meeting,
        'parts': [
          {
            'part_id': _part2,
            'leader': {'member_id': _standIn},
          },
        ],
      });
    });

    testWidgets('a recorded part shows who stood in, the earlier value and '
        'why; a change needs a reason', (tester) async {
      final h = await pumpAt(
        tester,
        CellPaths.plan(_meeting),
        setUp: (h) => h.cells.programme = read(
          status: 'held',
          record: heldRecord(
            actual: [
              actual(
                _part2,
                _standIn,
                'SYNTHETIC Stand In',
                substitute: true,
                reason: 'SYNTHETIC it was them',
                earlier: [actual(_part2, _planned2, 'SYNTHETIC Planned 2')],
              ),
            ],
          ),
        ),
      );
      expect(
        tester.widget<StatusLabel>(byKey('record-actual-$_part2')).label,
        'Stood in: SYNTHETIC Stand In',
      );
      expect(find.text('Planned: SYNTHETIC Planned 2'), findsOneWidget);
      expect(
        find.text('Why it changed: SYNTHETIC it was them'),
        findsOneWidget,
      );
      expect(
        find.text('Earlier: SYNTHETIC Planned 2 (SYNTHETIC Leader)'),
        findsOneWidget,
      );
      // Only the unrecorded part is offered as planned.
      expect(find.text('1 part was led as planned'), findsOneWidget);
      await tapKey(tester, 'record-edit-$_part2');
      await settle(tester);
      await tapKey(tester, 'record-who-$_part2');
      await settle(tester);
      await tester.tap(find.text('Nobody led it').last);
      await settle(tester);
      expect(
        tester.widget<FilledButton>(byKey('record-save-$_part2')).onPressed,
        isNull,
        reason: 'a change waits for its reason',
      );
      await tester.enterText(
        byKey('record-part-reason-$_part2'),
        'SYNTHETIC we skipped it',
      );
      await settle(tester);
      await tapKey(tester, 'record-save-$_part2');
      final sent = h.gateway.sent.single;
      expect(sent.wire['payload'], {
        'meeting_id': _meeting,
        'parts': [
          {
            'part_id': _part2,
            'leader': null,
            'reason': 'SYNTHETIC we skipped it',
          },
        ],
      });
      sent.refuse(
        ErrorCode.validationFailed,
        fieldErrors: {'parts.0.reason': 'required'},
      );
      await settle(tester);
      // A refusal keeps the editor and what was typed.
      expect(
        tester
            .widget<TextField>(byKey('record-part-reason-$_part2'))
            .controller!
            .text,
        'SYNTHETIC we skipped it',
      );
      expect(byKey('cells-notice-programmePartRefused'), findsOneWidget);
      expect(find.text('Not saved'), findsOneWidget);
    });

    testWidgets('review fixes: a batch error lands on its part; after a save '
        'another editor opens and stays open; a person who left is not '
        'preselected', (tester) async {
      final h = await pumpAt(
        tester,
        CellPaths.plan(_meeting),
        setUp: (h) => h.cells.programme = read(
          status: 'held',
          record: heldRecord(
            actual: [
              // Recorded earlier for someone no longer on the roster.
              actual(
                _part1,
                '8a8a8a8a-8a8a-4a8a-8a8a-8a8a8a8a8a8a',
                'SYNTHETIC Moved Away',
              ),
            ],
          ),
        ),
      );
      await tapKey(tester, 'record-all-planned');
      h.gateway.sent.single.refuse(
        ErrorCode.validationFailed,
        fieldErrors: {'parts.0.member_id': 'not_in_cell'},
      );
      await settle(tester);
      // The batch had one part (part 2): its error shows on part 2.
      expect(
        find.descendant(
          of: byKey('record-part-$_part2'),
          matching: find.text(
            'They are no longer in this cell: name them as a guest.',
          ),
        ),
        findsOneWidget,
      );
      await tapKey(tester, 'record-edit-$_part2');
      await settle(tester);
      await tapKey(tester, 'record-save-$_part2');
      h.gateway.sent.last.confirm({'meeting_id': _meeting}, 3);
      await settle(tester);
      expect(byKey('record-who-$_part2'), findsNothing, reason: 'saved');
      // Opening another editor after that success keeps it open.
      await tapKey(tester, 'record-edit-$_part1');
      await settle(tester);
      expect(byKey('record-who-$_part1'), findsOneWidget);
      expect(
        tester
            .widget<DropdownButton<String>>(byKey('record-who-$_part1'))
            .value,
        isNull,
      );
    });

    testWidgets('held is corrected with a reason at the record revision', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        CellPaths.plan(_meeting),
        setUp: (h) =>
            h.cells.programme = read(status: 'held', record: heldRecord()),
      );
      await tapKey(tester, 'record-correct');
      await settle(tester);
      await tester.enterText(byKey('record-reason'), 'SYNTHETIC prayer only');
      await settle(tester);
      await tapKey(tester, 'record-correct-save');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'cells.correct_meeting_held');
      expect(sent.wire['expected_revision'], 2);
      expect(sent.wire['payload'], {
        'meeting_id': _meeting,
        'held': false,
        'reason': 'SYNTHETIC prayer only',
      });
    });

    testWidgets('Pastor oversight reads the record without controls', (
      tester,
    ) async {
      await pumpAt(
        tester,
        CellPaths.plan(_meeting),
        setUp: (h) => h.cells.programme = read(canEdit: false),
      );
      expect(byKey('record-none'), findsOneWidget);
      expect(byKey('record-held'), findsNothing);
    });
  });

  group('staff web, Cell meetings', () {
    testWidgets('the last four weeks show their status and Record', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.cellMeetings,
        setUp: (h) => h.cells.meetings = AccessReadOk(
          CellMeetingsBoard.fromJson({
            'cells': [
              {
                'cell_id': _cell,
                'name': 'SYNTHETIC Shikoswe Cell',
                'is_synthetic': true,
                'role': 'leader',
                'can_change': true,
                'can_set_schedule': false,
                'schedule': null,
                'meetings': const [],
                'recent': [
                  {...meetingData(), 'status': 'unrecorded'},
                ],
              },
            ],
          }),
        ),
      );
      expect(
        tester.widget<StatusLabel>(byKey('meeting-unrecorded-$_cell')).label,
        '1 recent meeting not recorded',
      );
      expect(byKey('recent-$_meeting'), findsOneWidget);
      expect(
        find.descendant(
          of: byKey('recent-open-$_meeting'),
          matching: find.text('Record'),
        ),
        findsOneWidget,
      );
    });
  });
}
