// Story 4.2: a leader changes a published duty on staff web (a material
// change asks the member again with a new deadline and keeps the earlier
// answer in history; an instructions-only change keeps the answer), and the
// member's answer to an old version is refused with what changed. Fakes only;
// the server behaviour is covered by supabase/tests/duties_revisions_test.sql
// and tools/identity-e2e/duties-revisions.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _dept = '44444444-4444-4444-8444-444444444444';
const _assignment = '42424242-4242-4242-8242-424242424242';
const _old = '41414141-4141-4141-8141-414141414141';
const _occurrence = '43434343-4343-4343-8343-434343434343';
const _slot = '45454545-4545-4545-8545-454545454545';
const _lydia = '99999999-9999-4999-8999-999999999999';
const _ruth = '66666666-6666-4666-8666-666666666666';

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? setUp,
}) async {
  tester.view.physicalSize = const Size(1200, 6000);
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

Future<void> enter(WidgetTester tester, String key, String text) async {
  await tester.ensureVisible(byKey(key));
  await tester.enterText(byKey(key), text);
  await tester.pump();
}

AccessRead<MyDuties> mineWith(List<Map<String, Object?>> duties) =>
    AccessReadOk(
      MyDuties.fromJson({'member_id': _ruth, 'assignments': duties}),
    );

Map<String, Object?> rosterMember(
  String id,
  String name, {
  String account = 'app_account',
}) => {
  'member_id': id,
  'display_name': name,
  'account': account,
  'since': '2026-10-13T08:00:00.000000Z',
};

Map<String, Object?> leaderDuty({
  int revision = 1,
  String assignmentId = _assignment,
  String response = 'accepted',
  String? respondedAt = '2026-10-13T09:00:00.000000Z',
  String startsAt = '2099-01-04T08:00:00.000000Z',
  String? instructions = 'Arrive early.',
  int slotRevision = 1,
  List<String>? changes,
  List<Map<String, Object?>> history = const [],
}) => {
  'occurrence_id': _occurrence,
  'department_id': _dept,
  'duty_name': 'Sunday preaching',
  'starts_at': startsAt,
  'ends_at': null,
  'reporting_at': null,
  'location': 'SYNTHETIC Main hall',
  'instructions': instructions,
  'state': 'published',
  'revision': revision,
  'published_at': '2026-10-13T08:00:00.000000Z',
  'positions': [
    {
      'slot_id': _slot,
      'position_no': 1,
      'slot_revision': slotRevision,
      'assignment': {
        'assignment_id': assignmentId,
        'member_id': _ruth,
        'display_name': 'SYNTHETIC Ruth',
        'response': response,
        'response_deadline': '2099-01-01T08:00:00.000000Z',
        'responded_at': response == 'pending' ? null : respondedAt,
        'note': null,
        'revision': response == 'pending' ? 1 : 2,
        'slot_revision': slotRevision,
        'changes': changes,
        'notes_updated_at': null,
      },
      'history': history,
    },
  ],
};

Map<String, Object?> historyEntry() => {
  'assignment_id': _old,
  'member_id': _ruth,
  'display_name': 'SYNTHETIC Ruth',
  'state': 'superseded',
  'end_reason': 'revised',
  'ended_at': '2026-10-14T08:00:00.000000Z',
  'response': 'accepted',
  'responded_at': '2026-10-13T09:00:00.000000Z',
  'response_provenance': 'member',
  'note': 'Happy to serve.',
  'slot_revision': 1,
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
        'members': [
          rosterMember(_ruth, 'SYNTHETIC Ruth'),
          rosterMember(_lydia, 'SYNTHETIC Lydia', account: 'no_login'),
        ],
        'duties': duties,
      },
    ],
  }),
);

LeaderDuty _duty() => (boardWith([
  leaderDuty(),
]) as AccessReadOk<DutyLeaderBoard>).value.departments.single.duties.single;

void main() {
  group('wire mapping', () {
    test('a changed revision parses with the earlier answer and ids', () {
      final d = MyDuty.fromJson(
        myDutyData(
          slotRevision: 2,
          changes: const ['starts_at', 'location'],
          previousResponse: 'accepted',
          previousAssignmentIds: const [_old],
        ),
      );
      expect(d.isChanged, isTrue);
      expect(d.changes, ['starts_at', 'location']);
      expect(d.previousResponse, DutyResponse.accepted);
      expect(d.slotRevision, 2);
      final list = MyDuties.fromJson({
        'member_id': _ruth,
        'assignments': [
          myDutyData(previousAssignmentIds: const [_old]),
        ],
      });
      expect(list.find(_old), isNull);
      expect(list.findCurrent(_old)?.assignmentId, _assignment);
      expect(
        () => MyDuty.fromJson({
          ...myDutyData(),
          'changes': [1],
        }),
        throwsFormatException,
      );
      expect(
        () => MyDuty.fromJson({...myDutyData(), 'previous_response': 'maybe'}),
        throwsFormatException,
      );
      // A 4.1 server without the new keys still parses.
      final legacy = {...myDutyData()}
        ..remove('slot_revision')
        ..remove('changes')
        ..remove('previous_assignment_ids');
      expect(MyDuty.fromJson(legacy).isChanged, isFalse);
    });

    test('history entries parse strictly', () {
      final b = (boardWith([
        leaderDuty(history: [historyEntry()]),
      ]) as AccessReadOk<DutyLeaderBoard>).value;
      final h = b.departments.single.duties.single.positions.single.history;
      expect(h.single.response, DutyResponse.accepted);
      expect(h.single.provenance, 'member');
      expect(
        () => AssignmentHistoryEntry.fromJson({
          ...historyEntry(),
          'state': 'current',
        }),
        throwsFormatException,
      );
      expect(
        () => AssignmentHistoryEntry.fromJson({
          ...historyEntry(),
          'response_provenance': 'leader',
        }),
        throwsFormatException,
      );
    });

    test('an edit sends only what changed, in UTC', () {
      final d = _duty();
      final notes = DutyEdit(
        duty: d,
        dutyName: ' Sunday  preaching ',
        startsAt: d.times.startsAt,
        memberId: _ruth,
        location: 'SYNTHETIC Main hall',
        instructions: ' Bring a Bible. ',
        responseDeadline: DateTime.utc(2099, 1, 2),
      );
      expect(notes.changed, ['instructions']);
      expect(notes.material, isFalse);
      expect(notes.toPayload(), {
        'occurrence_id': _occurrence,
        'instructions': 'Bring a Bible.',
      });
      final moved = DutyEdit(
        duty: d,
        dutyName: 'Sunday preaching',
        startsAt: ChurchTime.parse('2099-01-05', '10:00')!,
        endsAt: ChurchTime.parse('2099-01-05', '12:00'),
        memberId: _lydia,
        location: '',
        instructions: 'Arrive early.',
        responseDeadline: ChurchTime.parse('2099-01-03', '18:00'),
      );
      expect(moved.material, isTrue);
      expect(moved.toPayload(), {
        'occurrence_id': _occurrence,
        'starts_at': '2099-01-05T08:00:00.000Z',
        'ends_at': '2099-01-05T10:00:00.000Z',
        'location': null,
        'member_id': _lydia,
        'response_deadline': '2099-01-03T16:00:00.000Z',
      });
      expect(
        DutyEdit(
          duty: d,
          dutyName: 'Sunday preaching',
          startsAt: d.times.startsAt,
          memberId: _ruth,
          location: 'SYNTHETIC Main hall',
          instructions: 'Arrive early.',
        ).changed,
        isEmpty,
      );
    });

    test('a refusal names what changed in plain words', () {
      final f = DutyFields.changedIn(const {
        'assignment_id': 'superseded',
        'location': 'changed',
        'starts_at': 'changed',
      });
      expect(f, ['starts_at', 'location']);
      expect(DutyFields.describe(f), 'date or start time, place');
    });

    test('the released notice opens My duties', () {
      expect(ClientPaths.isKnownDeepLink('/duties'), isTrue);
      // Story 4.8: the leaders' alerts open the board; the rota is no link.
      expect(ClientPaths.isKnownDeepLink('/duties/leader'), isTrue);
      expect(ClientPaths.isKnownDeepLink('/duties/rota'), isFalse);
    });
  });

  group('staff web: changing a duty', () {
    testWidgets('a time change asks again with a new deadline; history kept', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) => h.duties.board = boardWith([leaderDuty()]),
      );
      await tapKey(tester, 'edit-$_occurrence');
      // Prefilled in church time: 08:00Z is 10:00 in Lusaka.
      expect(
        tester
            .widget<TextField>(byKey('edit-start-$_occurrence'))
            .controller!
            .text,
        '10:00',
      );
      expect(enabled(tester, 'edit-save-$_occurrence'), isFalse);
      await enter(tester, 'edit-start-$_occurrence', '11:00');
      expect(find.textContaining('will be asked to answer again'), findsOne);
      expect(
        enabled(tester, 'edit-save-$_occurrence'),
        isTrue,
        reason: 'story 4.8: without a new answer-by time the default applies',
      );
      expect(find.textContaining('the church default applies'), findsOne);
      await enter(tester, 'edit-deadline-date-$_occurrence', '2099-01-02');
      await enter(tester, 'edit-deadline-time-$_occurrence', '18:00');
      await tapKey(tester, 'edit-save-$_occurrence');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'duties_command');
      expect(sent.wire['command'], 'duties.revise_duty');
      expect(sent.wire['expected_revision'], 1);
      expect(sent.wire['payload'], {
        'occurrence_id': _occurrence,
        'starts_at': '2099-01-04T09:00:00.000Z',
        'response_deadline': '2099-01-02T16:00:00.000Z',
      });
      expect(byKey('duties-pending'), findsOneWidget);
      // Unknown outcome: Check again resends the same request.
      sent.unknown();
      await settle(tester);
      expect(byKey('duties-notice-unconfirmed'), findsOneWidget);
      await tapKey(tester, 'duties-check-again');
      expect(h.gateway.sent.last.wire, sent.wire);
      h.duties.board = boardWith([
        leaderDuty(
          revision: 2,
          response: 'pending',
          startsAt: '2099-01-04T09:00:00.000000Z',
          slotRevision: 2,
          changes: const ['starts_at'],
          history: [historyEntry()],
        ),
      ]);
      h.gateway.sent.last.confirm(const {'change': 'material'}, 2);
      await settle(tester);
      expect(byKey('duties-notice-revised'), findsOneWidget);
      expect(byKey('changed-$_assignment'), findsOneWidget);
      expect(find.text('Changed: date or start time'), findsOneWidget);
      expect(find.text('Awaiting response'), findsOneWidget);
      expect(byKey('history-$_old'), findsOneWidget);
      expect(find.textContaining('SYNTHETIC Ruth: Accepted'), findsOneWidget);
      expect(find.textContaining('note: Happy to serve.'), findsOneWidget);
      // The new revision closed the form.
      expect(byKey('edit-card-$_occurrence'), findsNothing);
    });

    testWidgets('an instructions-only change keeps the answer', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) => h.duties.board = boardWith([leaderDuty()]),
      );
      await tapKey(tester, 'edit-$_occurrence');
      await enter(tester, 'edit-instructions-$_occurrence', 'Bring a Bible.');
      expect(find.textContaining('the answer stands'), findsOne);
      expect(enabled(tester, 'edit-save-$_occurrence'), isTrue);
      await tapKey(tester, 'edit-save-$_occurrence');
      final sent = h.gateway.sent.single;
      expect(sent.wire['payload'], {
        'occurrence_id': _occurrence,
        'instructions': 'Bring a Bible.',
      });
      h.duties.board = boardWith([
        leaderDuty(revision: 2, instructions: 'Bring a Bible.'),
      ]);
      sent.confirm(const {'change': 'notes'}, 2);
      await settle(tester);
      expect(byKey('duties-notice-notesUpdated'), findsOneWidget);
      expect(find.text('Accepted'), findsOneWidget);
    });

    testWidgets('a concurrent change by another leader is a conflict', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) => h.duties.board = boardWith([leaderDuty()]),
      );
      await tapKey(tester, 'edit-$_occurrence');
      await enter(tester, 'edit-instructions-$_occurrence', 'Mine.');
      await tapKey(tester, 'edit-save-$_occurrence');
      h.duties.board = boardWith([
        leaderDuty(revision: 2, instructions: 'Theirs.'),
      ]);
      h.gateway.sent.single.refuse(
        ErrorCode.conflict,
        currentRevision: const Optional.of(2),
      );
      await settle(tester);
      expect(byKey('duties-notice-changedElsewhere'), findsOneWidget);
      expect(h.duties.boardCalls, 2);
      expect(find.text('Instructions: Theirs.'), findsOneWidget);
    });

    testWidgets('a refused deadline is shown on the edit, not on publish', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) => h.duties.board = boardWith([leaderDuty()]),
      );
      await tapKey(tester, 'edit-$_occurrence');
      await enter(tester, 'edit-location-$_occurrence', 'SYNTHETIC Side hall');
      await enter(tester, 'edit-deadline-date-$_occurrence', '2099-01-05');
      await enter(tester, 'edit-deadline-time-$_occurrence', '18:00');
      await tapKey(tester, 'edit-save-$_occurrence');
      h.gateway.sent.single.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'response_deadline': 'after_start'},
      );
      await settle(tester);
      expect(byKey('duties-notice-invalid'), findsOneWidget);
      expect(find.text('Must be before the duty starts'), findsOneWidget);
    });

    testWidgets('a duty that started meanwhile gets the leader notice', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) => h.duties.board = boardWith([leaderDuty()]),
      );
      await tapKey(tester, 'edit-$_occurrence');
      await enter(tester, 'edit-instructions-$_occurrence', 'Late.');
      await tapKey(tester, 'edit-save-$_occurrence');
      h.gateway.sent.single.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'occurrence_id': 'started'},
      );
      await settle(tester);
      expect(byKey('duties-notice-dutyStarted'), findsOneWidget);
      expect(find.textContaining('can no longer be changed'), findsOneWidget);
      expect(find.textContaining('answered here'), findsNothing);
    });

    testWidgets('Pastor oversight sees history but cannot change', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) => h.duties.board = boardWith(
          [
            leaderDuty(history: [historyEntry()]),
          ],
          canPublish: false,
          capacity: 'pastor',
        ),
      );
      expect(byKey('edit-$_occurrence'), findsNothing);
      expect(byKey('history-$_old'), findsOneWidget);
    });
  });

  group('mobile: a changed duty', () {
    testWidgets(
      'a late answer to an old version is refused with what changed',
      (tester) async {
        final h = await pumpAt(
          tester,
          ClientPaths.myDuties,
          setUp: (h) =>
              h.duties.mine = mineWith([myDutyData(assignmentId: _old)]),
        );
        await tapKey(tester, 'duty-accept-$_old');
        final sent = h.gateway.sent.single;
        expect(sent.wire['payload'], {
          'assignment_id': _old,
          'response': 'accepted',
        });
        h.duties.mine = mineWith([
          myDutyData(
            slotRevision: 2,
            changes: const ['starts_at', 'location'],
            previousResponse: 'pending',
            previousAssignmentIds: const [_old],
          ),
        ]);
        sent.refuse(
          ErrorCode.conflict,
          fieldErrors: const {
            'assignment_id': 'superseded',
            'starts_at': 'changed',
            'location': 'changed',
          },
        );
        await settle(tester);
        expect(byKey('duties-notice-superseded'), findsOneWidget);
        expect(
          find.textContaining('the date or start time, place changed'),
          findsOneWidget,
        );
        expect(find.text('Accepted'), findsNothing);
        expect(byKey('duty-changed-$_assignment'), findsOneWidget);
        expect(find.text('What changed: date or start time, place.'), findsOne);
        expect(find.text('Needs a response (1)'), findsOneWidget);
        expect(h.duties.mineCalls, 2);
      },
    );

    testWidgets('a duty given to someone else says so', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.myDuties,
        setUp: (h) =>
            h.duties.mine = mineWith([myDutyData(assignmentId: _old)]),
      );
      await tapKey(tester, 'duty-decline-$_old');
      // Story 4.5: Can't make it asks in a sheet first.
      await settle(tester);
      await tapKey(tester, 'decline-confirm');
      await settle(tester);
      h.duties.mine = mineWith(const []);
      h.gateway.sent.single.refuse(
        ErrorCode.conflict,
        fieldErrors: const {
          'assignment_id': 'superseded',
          'member_id': 'changed',
        },
      );
      await settle(tester);
      expect(find.textContaining('no longer assigned to you'), findsOneWidget);
      expect(byKey('my-duties-empty'), findsOneWidget);
    });

    testWidgets('a duty that is yours again does not say it was taken away', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.myDuties,
        setUp: (h) =>
            h.duties.mine = mineWith([myDutyData(assignmentId: _old)]),
      );
      await tapKey(tester, 'duty-accept-$_old');
      h.duties.mine = mineWith([
        myDutyData(previousAssignmentIds: const [_old]),
      ]);
      h.gateway.sent.single.refuse(
        ErrorCode.conflict,
        fieldErrors: const {'assignment_id': 'superseded'},
      );
      await settle(tester);
      expect(
        find.textContaining('this duty changed since you opened it'),
        findsOne,
      );
      expect(find.textContaining('no longer assigned'), findsNothing);
    });

    testWidgets('an earlier pending answer is not shown as an answer', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.myDuties,
        setUp: (h) => h.duties.mine = mineWith([
          myDutyData(
            changes: const ['starts_at'],
            previousResponse: 'pending',
            previousAssignmentIds: const [_old],
          ),
        ]),
      );
      expect(find.textContaining('Your earlier answer'), findsNothing);
      expect(byKey('duty-changed-$_assignment'), findsOneWidget);
    });

    testWidgets('an old link to an answered current version does not ask', (
      tester,
    ) async {
      await pumpAt(
        tester,
        '/duties/assignments/$_old',
        setUp: (h) => h.duties.mine = mineWith([
          myDutyData(
            revision: 2,
            response: 'accepted',
            respondedAt: '2026-10-13T09:00:00.000000Z',
            previousAssignmentIds: const [_old],
          ),
        ]),
      );
      expect(byKey('duty-was-changed'), findsOneWidget);
      expect(find.textContaining('your answer is needed'), findsNothing);
    });

    testWidgets('an accepted change keeps the earlier answer visible', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.myDuties,
        setUp: (h) => h.duties.mine = mineWith([
          myDutyData(
            slotRevision: 2,
            changes: const ['starts_at'],
            previousResponse: 'accepted',
            previousAssignmentIds: const [_old],
          ),
        ]),
      );
      expect(
        find.textContaining('Your earlier answer was "Accepted"'),
        findsOneWidget,
      );
      expect(find.textContaining('Please answer again.'), findsOneWidget);
    });

    testWidgets('an old reminder link opens the current version', (
      tester,
    ) async {
      await pumpAt(
        tester,
        '/duties/assignments/$_old',
        setUp: (h) => h.duties.mine = mineWith([
          myDutyData(
            slotRevision: 2,
            changes: const ['starts_at'],
            previousAssignmentIds: const [_old],
          ),
        ]),
      );
      expect(byKey('duty-was-changed'), findsOneWidget);
      expect(byKey('my-duty-$_assignment'), findsOneWidget);
      expect(byKey('duty-accept-$_assignment'), findsOneWidget);
    });

    testWidgets('an instructions update keeps Accepted', (tester) async {
      await pumpAt(
        tester,
        '/duties/assignments/$_assignment',
        setUp: (h) => h.duties.mine = mineWith([
          myDutyData(
            revision: 2,
            response: 'accepted',
            respondedAt: '2026-10-13T09:00:00.000000Z',
            notesUpdatedAt: '2026-10-14T08:00:00.000000Z',
          ),
        ]),
      );
      expect(find.textContaining('Your answer stands.'), findsOneWidget);
      expect(
        find.descendant(
          of: byKey('my-duty-status-$_assignment'),
          matching: find.text('Accepted'),
        ),
        findsOneWidget,
      );
    });
  });
}
