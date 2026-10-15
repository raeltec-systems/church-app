// Story 4.11: what the clients show of the Duties owner operations. A cell
// programme part is in My duties (owner "Cell programme", the cell's leader
// and assistant by name) and can be answered; a department duty linked to a
// programme part says so, and an owner-review mismatch (a linked cell meeting
// or event changed) is shown to the department, whose leaders, deputies and
// Admin mark it reviewed (duties.clear_review). Fakes only; the server
// behaviour is covered by supabase/tests/duties_owner_operations_test.sql and
// tools/identity-e2e/duties-owner-ops.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _dept = '44444444-4444-4444-8444-444444444444';
const _assignment = '42424242-4242-4242-8242-424242424242';
const _occurrence = '43434343-4343-4343-8343-434343434343';
const _slot = '45454545-4545-4545-8545-454545454545';
const _flag = '48484848-4848-4848-8848-484848484848';
const _cell = '47474747-4747-4747-8747-474747474747';
const _ruth = '66666666-6666-4666-8666-666666666666';
const _series = '50505050-5050-4050-8050-505050505050';

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

Map<String, Object?> review({
  int revision = 2,
  String source = 'cell_part',
  List<String> changed = const ['place', 'time'],
}) => {
  'flag_id': _flag,
  'revision': revision,
  'source': source,
  'changed': changed,
  'flagged_at': '2026-10-15T08:00:00.000000Z',
  'updated_at': '2026-10-15T09:00:00.000000Z',
};

Map<String, Object?> leaderDuty({
  List<Map<String, Object?>> reviews = const [],
  int linkedParts = 0,
}) => {
  'occurrence_id': _occurrence,
  'department_id': _dept,
  'duty_name': 'SYNTHETIC Cell preaching',
  'starts_at': '2099-01-04T16:00:00.000000Z',
  'ends_at': null,
  'reporting_at': null,
  'location': 'SYNTHETIC Main hall',
  'instructions': null,
  'state': 'published',
  'revision': 3,
  'published_at': '2026-10-13T08:00:00.000000Z',
  'reviews': reviews,
  'linked_parts': linkedParts,
  'positions': [
    {
      'slot_id': _slot,
      'position_no': 1,
      'slot_revision': 1,
      'assignment': {
        'assignment_id': _assignment,
        'member_id': _ruth,
        'display_name': 'SYNTHETIC Ruth',
        'response': 'accepted',
        'response_deadline': '2099-01-01T08:00:00.000000Z',
        'responded_at': '2026-10-13T09:00:00.000000Z',
        'note': null,
        'revision': 2,
        'slot_revision': 1,
        'changes': null,
        'notes_updated_at': null,
      },
      'history': const <Object?>[],
    },
  ],
};

AccessRead<DutyLeaderBoard> boardWith(
  List<Map<String, Object?>> duties, {
  bool canPublish = true,
  String capacity = 'department_leader',
}) => AccessReadOk(
  DutyLeaderBoard.fromJson({
    'departments': [
      {
        'department_id': _dept,
        'name': 'SYNTHETIC Preaching Rota',
        'capacity': capacity,
        'can_publish': canPublish,
        'members': const <Object?>[],
        'duties': duties,
      },
    ],
  }),
);

Map<String, Object?> rotaOccurrence({
  List<Map<String, Object?>> reviews = const [],
  int linkedParts = 0,
}) => {
  'occurrence_id': _occurrence,
  'series_date': '2099-01-04',
  'state': 'published',
  'revision': 4,
  'duty_name': 'Sunday service',
  'starts_at': '2099-01-04T08:00:00.000000Z',
  'ends_at': null,
  'reporting_at': null,
  'location': 'SYNTHETIC Main hall',
  'instructions': null,
  'topic': null,
  'scripture': null,
  'event_ref': null,
  'started': false,
  'required': 1,
  'confirmed': 0,
  'reviews': reviews,
  'linked_parts': linkedParts,
  'positions': [
    {
      'slot_id': _slot,
      'position_no': 1,
      'position_name': 'Preacher',
      'slot_revision': 1,
      'draft': null,
      'assignment': null,
    },
  ],
};

AccessRead<DutyRota> rotaWith(List<Map<String, Object?>> occurrences) =>
    AccessReadOk(
      DutyRota.fromJson({
        'departments': [
          {
            'department_id': _dept,
            'name': 'SYNTHETIC Preaching Rota',
            'capacity': 'department_leader',
            'can_manage': true,
            'members': const <Object?>[],
            'series': [
              {
                'series_id': _series,
                'department_id': _dept,
                'duty_name': 'Sunday service',
                'every': 'week',
                'interval': 1,
                'from_date': '2099-01-04',
                'until_date': '2099-01-04',
                'start_time': '10:00',
                'end_time': null,
                'reporting_time': null,
                'location': 'SYNTHETIC Main hall',
                'instructions': null,
                'topic': null,
                'scripture': null,
                'event_ref': null,
                'positions': ['Preacher'],
                'zone': 'Africa/Lusaka',
                'revision': 1,
                'draft_slots': 0,
                'occurrences': occurrences,
              },
            ],
            'series_truncated': false,
          },
        ],
      }),
    );

void main() {
  group('wire mapping', () {
    test('a cell programme part names its cell and no department', () {
      final d = MyDuty.fromJson(
        myDutyData(
          ownerKind: 'cell',
          leaders: const [
            {'display_name': 'SYNTHETIC Cell leader', 'role': 'leader'},
            {'display_name': 'SYNTHETIC Cell assistant', 'role': 'assistant'},
          ],
        ),
      );
      expect(d.ownerKind, DutyOwnerKind.cell);
      expect(d.departmentId, isNull);
      expect(d.departmentName, isNull);
      expect(d.cellId, _cell);
      expect(d.ownerLabel, 'Cell programme');
      expect(d.answerable, isTrue);
      expect(d.leaders.map((l) => l.roleLabel), ['Leader', 'Assistant']);
      expect(
        MyDuty.fromJson(myDutyData()).ownerLabel,
        'SYNTHETIC Preaching Rota',
      );
      // A cell part without its cell, or a department duty without its
      // department, fails closed.
      expect(
        () => MyDuty.fromJson(
          {...myDutyData(ownerKind: 'cell')}..remove('cell_id'),
        ),
        throwsFormatException,
      );
      expect(
        () => MyDuty.fromJson({...myDutyData(), 'department_name': null}),
        throwsFormatException,
      );
    });

    test('a cell part goes into the calendar without a department', () {
      final ics = DutyCalendar.ics(
        MyDuty.fromJson(myDutyData(ownerKind: 'cell')),
        now: DateTime.utc(2099, 1, 1),
      );
      expect(ics, contains('Cell programme part.'));
      expect(ics, isNot(contains('Department:')));
    });

    test(
      'owner reviews and linked parts parse; anything else fails closed',
      () {
        final d = LeaderDuty.fromJson(
          leaderDuty(reviews: [review()], linkedParts: 1),
        );
        expect(d.linkedParts, 1);
        expect(d.reviews.single.flagId, _flag);
        expect(d.reviews.single.revision, 2);
        expect(
          d.reviews.single.summary,
          'A linked cell meeting changed (time, place)',
        );
        expect(
          DutyReview.fromJson(
            review(source: 'event', changed: const ['cancelled']),
          ).summary,
          'The linked event changed (cancelled)',
        );
        // A server before 4.11 sends neither.
        final old = LeaderDuty.fromJson(
          {...leaderDuty()}
            ..remove('reviews')
            ..remove('linked_parts'),
        );
        expect(old.reviews, isEmpty);
        expect(old.linkedParts, 0);
        for (final bad in [
          review(source: 'cells'),
          review(changed: const []),
          review(changed: const ['venue']),
          {...review()}..remove('flag_id'),
        ]) {
          expect(() => DutyReview.fromJson(bad), throwsFormatException);
        }
        expect(
          () => LeaderDuty.fromJson({...leaderDuty(), 'linked_parts': -1}),
          throwsFormatException,
        );
        expect(
          () => LeaderDuty.fromJson({...leaderDuty(), 'reviews': 'x'}),
          throwsFormatException,
        );
        final o = RotaOccurrence.fromJson(
          rotaOccurrence(reviews: [review()], linkedParts: 2),
        );
        expect(o.reviews.single.changed, ['place', 'time']);
        expect(o.linkedParts, 2);
      },
    );
  });

  group('mobile: a cell part in My duties', () {
    testWidgets(
      'shows the cell programme and its leaders and can be accepted',
      (tester) async {
        final h = await pumpAt(
          tester,
          ClientPaths.myDuties,
          setUp: (h) => h.duties.mine = AccessReadOk(
            MyDuties.fromJson({
              'member_id': _ruth,
              'assignments': [
                myDutyData(
                  ownerKind: 'cell',
                  dutyName: 'SYNTHETIC Worship part',
                  leaders: const [
                    {'display_name': 'SYNTHETIC Cell leader', 'role': 'leader'},
                    {
                      'display_name': 'SYNTHETIC Cell assistant',
                      'role': 'assistant',
                    },
                  ],
                ),
              ],
            }),
          ),
        );
        expect(byKey('duty-owner-$_assignment'), findsOneWidget);
        expect(find.text('Cell programme'), findsOneWidget);
        await tapKey(tester, 'duty-accept-$_assignment');
        final sent = h.gateway.sent.single;
        expect(sent.wire['command'], 'duties.respond');
        expect(sent.wire['payload'], {
          'assignment_id': _assignment,
          'response': 'accepted',
        });
      },
    );
  });

  group('staff web: a linked department duty and its review', () {
    testWidgets('the leader sees the review and marks it reviewed', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) => h.duties.board = boardWith([
          leaderDuty(reviews: [review()], linkedParts: 1),
        ]),
      );
      expect(byKey('linked-parts-$_occurrence'), findsOneWidget);
      expect(find.textContaining('Shown on 1 cell programme part'), findsOne);
      expect(byKey('review-$_flag'), findsOneWidget);
      expect(find.text('Needs review'), findsOneWidget);
      expect(
        find.textContaining('A linked cell meeting changed (time, place)'),
        findsOne,
      );
      await tapKey(tester, 'clear-review-$_flag');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'duties_command');
      expect(sent.wire['command'], 'duties.clear_review');
      expect(sent.wire['expected_revision'], 2);
      expect(sent.wire['payload'], {'flag_id': _flag});
      // Unknown outcome: Check again resends the same request.
      sent.unknown();
      await settle(tester);
      expect(byKey('duties-notice-unconfirmed'), findsOneWidget);
      await tapKey(tester, 'duties-check-again');
      expect(h.gateway.sent.last.wire, sent.wire);
      h.duties.board = boardWith([leaderDuty(linkedParts: 1)]);
      h.gateway.sent.last.confirm(const {'cleared': true}, 3);
      await settle(tester);
      expect(byKey('duties-notice-reviewCleared'), findsOneWidget);
      expect(byKey('review-$_flag'), findsNothing);
      expect(byKey('linked-parts-$_occurrence'), findsOneWidget);
    });

    testWidgets('a review someone else cleared first reloads', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) => h.duties.board = boardWith([
          leaderDuty(reviews: [review()]),
        ]),
      );
      await tapKey(tester, 'clear-review-$_flag');
      h.duties.board = boardWith([leaderDuty()]);
      h.gateway.sent.single.refuse(
        ErrorCode.conflict,
        fieldErrors: const {'flag_id': 'cleared'},
      );
      await settle(tester);
      expect(byKey('duties-notice-reviewAlreadyCleared'), findsOneWidget);
      expect(h.duties.boardCalls, 2);
      expect(byKey('review-$_flag'), findsNothing);
    });

    testWidgets('oversight sees the review but cannot mark it', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) => h.duties.board = boardWith(
          [
            leaderDuty(reviews: [review(source: 'event')]),
          ],
          canPublish: false,
          capacity: 'pastor',
        ),
      );
      expect(byKey('review-$_flag'), findsOneWidget);
      expect(
        find.textContaining('The linked event changed (time, place)'),
        findsOne,
      );
      expect(byKey('clear-review-$_flag'), findsNothing);
      expect(byKey('linked-parts-$_occurrence'), findsNothing);
    });

    testWidgets('a rota date shows its review and marks it reviewed', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyRota,
        setUp: (h) => h.duties.rota = rotaWith([
          rotaOccurrence(reviews: [review(revision: 5)], linkedParts: 1),
        ]),
      );
      await tapKey(tester, 'rota-date-$_occurrence');
      await settle(tester);
      expect(byKey('review-$_flag'), findsOneWidget);
      expect(byKey('linked-parts-$_occurrence'), findsOneWidget);
      await tapKey(tester, 'clear-review-$_flag');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'duties.clear_review');
      expect(sent.wire['expected_revision'], 5);
      expect(sent.wire['payload'], {'flag_id': _flag});
    });
  });
}
