// Story 4.1: departments (Admin) and publishing with responses (leaders) on
// staff web, and the member's duties with Accept / Can't make it on mobile,
// with honest command states. Fakes only; the server behaviour is covered by
// supabase/tests/duties_tracer_test.sql and tools/identity-e2e/duties.mjs.
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
const _lydia = '99999999-9999-4999-8999-999999999999';
const _ruth = '66666666-6666-4666-8666-666666666666';

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

bool enabled(WidgetTester tester, String key) {
  final w = tester.widget(byKey(key));
  return switch (w) {
    ButtonStyleButton b => b.onPressed != null,
    _ => throw StateError('not a button: $key'),
  };
}

Future<void> choose(
  WidgetTester tester,
  String dropdownKey,
  String text,
) async {
  await tester.ensureVisible(byKey(dropdownKey));
  await tester.tap(byKey(dropdownKey));
  await settle(tester);
  await tester.tap(find.text(text).last);
  await settle(tester);
}

AccessRead<MyDuties> mineWith(List<Map<String, Object?>> duties) =>
    AccessReadOk(
      MyDuties.fromJson({'member_id': _ruth, 'assignments': duties}),
    );

Map<String, Object?> departmentData({
  int revision = 1,
  List<Map<String, Object?>> leaders = const [],
  List<Map<String, Object?>> members = const [],
}) => {
  'department_id': _dept,
  'name': 'SYNTHETIC Preaching Rota',
  'department_state': 'active',
  'is_synthetic': true,
  'revision': revision,
  'leaders': leaders,
  'deputies': const <Object?>[],
  'members': members,
};

Map<String, Object?> candidate(
  String id,
  String name, {
  String account = 'app_account',
  int grants = 3,
}) => {
  'member_id': id,
  'display_name': name,
  'account': account,
  'grants_revision': grants,
};

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
  String response = 'pending',
  String? note,
  String? respondedAt,
}) => {
  'occurrence_id': _occurrence,
  'department_id': _dept,
  'duty_name': 'Sunday preaching',
  'starts_at': '2099-01-04T08:00:00.000000Z',
  'ends_at': null,
  'reporting_at': null,
  'location': 'SYNTHETIC Main hall',
  'instructions': null,
  'state': 'published',
  'revision': 1,
  'published_at': '2026-10-13T08:00:00.000000Z',
  'positions': [
    {
      'slot_id': '45454545-4545-4545-8545-454545454545',
      'position_no': 1,
      'assignment': {
        'assignment_id': _assignment,
        'member_id': _ruth,
        'display_name': 'SYNTHETIC Ruth',
        'response': response,
        'response_deadline': '2099-01-01T08:00:00.000000Z',
        'responded_at': respondedAt,
        'note': note,
        'revision': response == 'pending' ? 1 : 2,
      },
    },
  ],
};

AccessRead<DutyLeaderBoard> boardWith({
  List<Map<String, Object?>> duties = const [],
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

void main() {
  group('wire mapping', () {
    test('a member duty parses strictly', () {
      final d = MyDuty.fromJson(myDutyData());
      expect(d.response, DutyResponse.pending);
      expect(d.times.startsAt.isUtc, isTrue);
      expect(d.needsResponse(DateTime.utc(2026, 10, 13)), isTrue);
      expect(d.needsResponse(DateTime.utc(2099, 1, 5)), isFalse);
      for (final bad in [
        {...myDutyData(), 'revision': 0},
        {...myDutyData(), 'response': 'maybe'},
        {...myDutyData(), 'starts_at': '2099-01-04 08:00'},
        // An answer always carries its time.
        {...myDutyData(), 'response': 'accepted'},
      ]) {
        expect(() => MyDuty.fromJson(bad), throwsFormatException);
      }
    });

    test('the leader board and overview parse; grants drive the nav', () {
      final b = (boardWith(
        duties: [
          leaderDuty(
            response: 'accepted',
            respondedAt: '2026-10-13T09:00:00.000000Z',
          ),
        ],
      ) as AccessReadOk<DutyLeaderBoard>).value;
      expect(b.departments.single.duties.single.accepted, 1);
      expect(
        () => DutyLeaderBoard.fromJson({
          'departments': [
            {
              'department_id': _dept,
              'name': 'x',
              'capacity': 'cell_leader',
              'can_publish': false,
              'members': const <Object?>[],
              'duties': const <Object?>[],
            },
          ],
        }),
        throwsFormatException,
      );
      final o = DutyAdminOverview.fromJson({
        'departments': [departmentData()],
        'members': [candidate(_ruth, 'SYNTHETIC Ruth')],
      });
      expect(o.departments.single.revision, 1);
      expect(
        seesDutyBoard(
          syntheticGrants(
            scopes: const [
              ScopeGrant(scopeKind: 'department_deputy', scopeId: _dept),
            ],
          ),
        ),
        isTrue,
      );
      expect(seesDutyBoard(syntheticGrants(roles: const ['pastor'])), isTrue);
      expect(
        seesDutyBoard(
          syntheticGrants(
            scopes: const [
              ScopeGrant(scopeKind: 'cell_leader', scopeId: _dept),
            ],
          ),
        ),
        isFalse,
      );
      expect(seesDutyBoard(null), isFalse);
    });

    test('a draft sends UTC instants and drops empty optional text', () {
      final p = DutyDraft(
        departmentId: _dept,
        dutyName: ' Sunday preaching ',
        startsAt: DateTime.utc(2099, 1, 4, 8),
        memberId: _ruth,
        responseDeadline: DateTime.utc(2099, 1, 1, 8),
        location: '  ',
      ).toPayload();
      expect(p, {
        'department_id': _dept,
        'duty_name': 'Sunday preaching',
        'starts_at': '2099-01-04T08:00:00.000Z',
        'member_id': _ruth,
        'response_deadline': '2099-01-01T08:00:00.000Z',
      });
    });

    test('church time is Africa/Lusaka (UTC+2) whatever the device zone', () {
      // Run this file with TZ=America/New_York (and the default zone) to
      // prove device independence; see docs/runbooks/duties.md.
      expect(
        ChurchTime.parse('2099-01-04', '08:00'),
        DateTime.utc(2099, 1, 4, 6),
      );
      expect(
        ChurchTime.parse('2099-01-01', '00:30'),
        DateTime.utc(2098, 12, 31, 22, 30),
      );
      expect(ChurchTime.parse('2099-02-30', '08:00'), isNull);
      expect(ChurchTime.parse('2099-01-04', '24:00'), isNull);
      final w = ChurchTime.wall(DateTime.utc(2099, 1, 4, 23));
      expect([w.year, w.month, w.day, w.hour], [2099, 1, 5, 1]);
      expect(ChurchTime.wall(DateTime.utc(2099, 1, 4, 6).toLocal()).hour, 8);
    });

    test('truncation is explicit', () {
      expect(
        MyDuties.fromJson({
          'member_id': _ruth,
          'assignments': const <Object?>[],
          'truncated': true,
        }).truncated,
        isTrue,
      );
      expect(
        DutyAdminOverview.fromJson({
          'departments': const <Object?>[],
          'members': const <Object?>[],
          'members_truncated': true,
        }).membersTruncated,
        isTrue,
      );
    });

    test('the reminder link is a known deep link', () {
      expect(
        ClientPaths.isKnownDeepLink('/duties/assignments/$_assignment'),
        isTrue,
      );
      expect(ClientPaths.isKnownDeepLink('/duties/assignments/x'), isFalse);
    });
  });

  group('staff web: Admin departments', () {
    testWidgets('adds SYNTHETIC Preaching Rota', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminDepartments,
        setUp: (h) => h.duties.admin = AccessReadOk(
          DutyAdminOverview.fromJson({
            'departments': const [],
            'members': const [],
          }),
        ),
      );
      expect(h.duties.adminCalls, 1);
      expect(enabled(tester, 'create-department-save'), isFalse);
      await tester.enterText(
        byKey('create-department-name'),
        ' SYNTHETIC Preaching Rota ',
      );
      await tester.pump();
      await tapKey(tester, 'create-department-save');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'duties_command');
      expect(sent.wire['command'], 'duties.create_department');
      expect(sent.wire['expected_revision'], isNull);
      expect(sent.wire['payload'], {'name': 'SYNTHETIC Preaching Rota'});
      sent.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'name': 'invalid'},
      );
      await settle(tester);
      expect(byKey('duties-notice-invalid'), findsOneWidget);
      expect(find.textContaining('start with "SYNTHETIC "'), findsOneWidget);
    });

    testWidgets(
      'a leader is an Identity scope grant; members join by revision',
      (tester) async {
        final h = await pumpAt(
          tester,
          ClientPaths.adminDepartments,
          setUp: (h) => h.duties.admin = AccessReadOk(
            DutyAdminOverview.fromJson({
              'departments': [departmentData(revision: 4)],
              'members': [
                candidate(
                  _lydia,
                  'SYNTHETIC Lydia',
                  account: 'no_login',
                  grants: 2,
                ),
                candidate(_ruth, 'SYNTHETIC Ruth', grants: 5),
              ],
            }),
          ),
        );
        await choose(tester, 'staff-member-$_dept', 'SYNTHETIC Ruth');
        await tapKey(tester, 'assign-staff-$_dept');
        final grant = h.gateway.sent.single;
        expect(grant.function, 'identity_grant_command');
        expect(grant.wire['command'], 'identity.grant_scope');
        expect(grant.wire['expected_revision'], 5);
        expect(grant.wire['payload'], {
          'member_id': _ruth,
          'scope_kind': 'department_leader',
          'scope_id': _dept,
        });
        grant.confirm(grantsData(memberId: _ruth), 6);
        await settle(tester);
        expect(byKey('duties-notice-staffAssigned'), findsOneWidget);
        expect(h.duties.adminCalls, 2);

        await choose(tester, 'add-member-$_dept', 'SYNTHETIC Lydia (no login)');
        await tapKey(tester, 'add-member-save-$_dept');
        final add = h.gateway.sent.last;
        expect(add.wire['command'], 'duties.add_member');
        expect(add.wire['expected_revision'], 4);
        expect(add.wire['payload'], {
          'department_id': _dept,
          'member_id': _lydia,
        });
        add.refuse(ErrorCode.conflict, currentRevision: const Optional.of(5));
        await settle(tester);
        expect(byKey('duties-notice-changedElsewhere'), findsOneWidget);
        expect(h.duties.adminCalls, 3);
      },
    );
  });

  group('staff web: leader board', () {
    testWidgets('publishes one duty with a deadline, then shows Accepted', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) => h.duties.board = boardWith(),
      );
      expect(byKey('no-duties-$_dept'), findsOneWidget);
      expect(enabled(tester, 'publish-save-$_dept'), isFalse);
      await tester.enterText(byKey('publish-name-$_dept'), 'Sunday preaching');
      await tester.enterText(byKey('publish-date-$_dept'), '2099-01-04');
      await tester.enterText(byKey('publish-start-$_dept'), '08:00');
      await tester.enterText(
        byKey('publish-location-$_dept'),
        'SYNTHETIC Main hall',
      );
      await choose(tester, 'publish-member-$_dept', 'SYNTHETIC Ruth');
      await tester.enterText(
        byKey('publish-deadline-date-$_dept'),
        '2099-01-01',
      );
      await tester.pump();
      expect(
        enabled(tester, 'publish-save-$_dept'),
        isFalse,
        reason: 'needs a deadline time',
      );
      await tester.enterText(byKey('publish-deadline-time-$_dept'), '08:00');
      await tester.pump();
      await tapKey(tester, 'publish-save-$_dept');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'duties.publish_duty');
      expect(sent.wire['expected_revision'], isNull);
      final payload = sent.wire['payload'] as Map;
      expect(payload['member_id'], _ruth);
      expect(payload['location'], 'SYNTHETIC Main hall');
      // Church time (Africa/Lusaka, UTC+2), whatever the device zone is.
      expect(payload['starts_at'], '2099-01-04T06:00:00.000Z');
      expect(payload['response_deadline'], '2099-01-01T06:00:00.000Z');
      expect(payload.containsKey('ends_at'), isFalse);
      expect(byKey('duties-pending'), findsOneWidget);
      // Unknown outcome: never shown as published; Check again resends it.
      sent.unknown();
      await settle(tester);
      expect(byKey('duties-notice-unconfirmed'), findsOneWidget);
      await tapKey(tester, 'duties-check-again');
      expect(h.gateway.sent, hasLength(2));
      expect(h.gateway.sent.last.wire, sent.wire);
      h.duties.board = boardWith(
        duties: [
          leaderDuty(
            response: 'accepted',
            note: 'Happy to serve.',
            respondedAt: '2026-10-13T09:00:00.000000Z',
          ),
        ],
      );
      h.gateway.sent.last.confirm(leaderDuty(), 1);
      await settle(tester);
      expect(byKey('duties-notice-published'), findsOneWidget);
      expect(find.text('Accepted'), findsOneWidget);
      expect(find.text('1 of 1 confirmed'), findsOneWidget);
      expect(byKey('note-$_assignment'), findsOneWidget);
    });

    testWidgets('an end past midnight and a reporting time are church time', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) => h.duties.board = boardWith(),
      );
      await tester.enterText(byKey('publish-name-$_dept'), 'Night vigil');
      await tester.enterText(byKey('publish-date-$_dept'), '2099-01-04');
      await tester.enterText(byKey('publish-start-$_dept'), '22:00');
      await tester.enterText(byKey('publish-end-date-$_dept'), '2099-01-05');
      await tester.enterText(byKey('publish-end-$_dept'), '01:00');
      await tester.enterText(byKey('publish-reporting-$_dept'), '21:30');
      await choose(tester, 'publish-member-$_dept', 'SYNTHETIC Ruth');
      await tester.enterText(
        byKey('publish-deadline-date-$_dept'),
        '2099-01-01',
      );
      await tester.enterText(byKey('publish-deadline-time-$_dept'), '18:00');
      await tester.pump();
      await tapKey(tester, 'publish-save-$_dept');
      final payload = h.gateway.sent.single.wire['payload'] as Map;
      expect(payload['starts_at'], '2099-01-04T20:00:00.000Z');
      expect(payload['ends_at'], '2099-01-04T23:00:00.000Z');
      expect(payload['reporting_at'], '2099-01-04T19:30:00.000Z');
      expect(payload['response_deadline'], '2099-01-01T16:00:00.000Z');
    });

    testWidgets('times are shown in church time', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) => h.duties.board = boardWith(duties: [leaderDuty()]),
      );
      // 08:00Z is 10:00 in Lusaka.
      expect(find.textContaining('10:00'), findsWidgets);
      expect(find.textContaining('(church time)'), findsWidgets);
    });

    testWidgets('a refusal names the field; Pastor oversight cannot publish', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) => h.duties.board = boardWith(
          capacity: 'pastor',
          canPublish: false,
          duties: [leaderDuty()],
        ),
      );
      expect(byKey('publish-$_dept'), findsNothing);
      expect(find.text('Pastor oversight (read only)'), findsOneWidget);
      expect(find.text('Awaiting response'), findsOneWidget);
      expect(h.gateway.sent, isEmpty);
    });

    testWidgets('no department scope: the server\'s denial is shown', (
      tester,
    ) async {
      await pumpAt(tester, ClientPaths.dutyLeader);
      expect(byKey('duties-denied-notGranted'), findsOneWidget);
    });
  });

  group('mobile: my duties', () {
    testWidgets('accepts a duty; Accepted only after the server confirms', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.myDuties,
        setUp: (h) => h.duties.mine = mineWith([myDutyData()]),
      );
      expect(find.text('Needs a response (1)'), findsOneWidget);
      await tester.enterText(byKey('duty-note-$_assignment'), ' On my way ');
      await tapKey(tester, 'duty-accept-$_assignment');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'duties_command');
      expect(sent.wire['command'], 'duties.respond');
      expect(sent.wire['expected_revision'], 1);
      expect(sent.wire['payload'], {
        'assignment_id': _assignment,
        'response': 'accepted',
        'note': 'On my way',
      });
      expect(find.text('Sending…'), findsWidgets);
      expect(find.text('Accepted'), findsNothing);
      sent.unknown();
      await settle(tester);
      expect(find.text('Not sent'), findsOneWidget);
      expect(find.text('Accepted'), findsNothing);
      await tapKey(tester, 'duties-check-again');
      expect(h.gateway.sent.last.wire, sent.wire);
      h.duties.mine = mineWith([
        myDutyData(
          revision: 2,
          response: 'accepted',
          respondedAt: '2026-10-13T09:00:00.000000Z',
          note: 'On my way',
        ),
      ]);
      h.gateway.sent.last.confirm(const {}, 2);
      await settle(tester);
      expect(byKey('duties-notice-accepted'), findsOneWidget);
      expect(find.text('Upcoming (1)'), findsOneWidget);
      expect(
        find.descendant(
          of: byKey('my-duty-status-$_assignment'),
          matching: find.text('Accepted'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a reload while an answer is in flight cannot send it twice', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.myDuties,
        setUp: (h) => h.duties.mine = mineWith([myDutyData()]),
      );
      await tapKey(tester, 'duty-accept-$_assignment');
      final sent = h.gateway.sent.single;
      final calls = h.duties.mineCalls;
      // A resume while the request is out does not reload.
      for (final st in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(st);
      }
      await settle(tester);
      expect(h.duties.mineCalls, calls);
      // Even a reload that does run keeps the request pending.
      final container = ProviderScope.containerOf(
        tester.element(byKey('duties-reload')),
      );
      await container.read(myDutiesProvider.notifier).reload();
      await settle(tester);
      expect(h.duties.mineCalls, calls + 1);
      expect(byKey('duties-pending'), findsOneWidget);
      expect(enabled(tester, 'duty-accept-$_assignment'), isFalse);
      expect(enabled(tester, 'duty-decline-$_assignment'), isFalse);
      await tester.tap(byKey('duty-accept-$_assignment'), warnIfMissed: false);
      await tester.pump();
      expect(h.gateway.sent, hasLength(1));
      sent.unknown();
      await settle(tester);
      // The unconfirmed answer is resent under the same request id.
      await tapKey(tester, 'duty-accept-$_assignment');
      expect(h.gateway.sent, hasLength(2));
      expect(h.gateway.sent.last.wire['request_id'], sent.wire['request_id']);
    });

    testWidgets('Can\'t make it; a stale answer reloads', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.myDuties,
        setUp: (h) => h.duties.mine = mineWith([myDutyData()]),
      );
      await tapKey(tester, 'duty-decline-$_assignment');
      final sent = h.gateway.sent.single;
      expect(sent.wire['payload'], {
        'assignment_id': _assignment,
        'response': 'declined',
      });
      sent.refuse(
        ErrorCode.conflict,
        fieldErrors: const {'assignment_id': 'responded'},
        currentRevision: const Optional.of(2),
      );
      await settle(tester);
      expect(byKey('duties-notice-alreadyAnswered'), findsOneWidget);
      expect(h.duties.mineCalls, 2);
    });

    testWidgets('empty, failed and denied reads differ', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.myDuties,
        setUp: (h) => h.duties.mine = mineWith(const []),
      );
      expect(byKey('my-duties-empty'), findsOneWidget);
    });

    testWidgets('a network failure is not an empty rota', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.myDuties,
        setUp: (h) => h.duties.mine = const AccessReadFailed(unreachable: true),
      );
      expect(byKey('duties-failed'), findsOneWidget);
      expect(byKey('my-duties-empty'), findsNothing);
    });

    testWidgets('the deep link shows that one duty in full', (tester) async {
      await pumpAt(
        tester,
        '/duties/assignments/$_assignment',
        setUp: (h) => h.duties.mine = mineWith([
          myDutyData(),
          myDutyData(
            assignmentId: '47474747-4747-4747-8747-474747474747',
            dutyName: 'Reading',
          ),
        ]),
      );
      expect(byKey('my-duty-$_assignment'), findsOneWidget);
      expect(byKey('duty-instructions-$_assignment'), findsOneWidget);
      expect(find.text('Reading'), findsNothing);
    });

    testWidgets('a deep link to a duty that is not yours says so', (
      tester,
    ) async {
      await pumpAt(
        tester,
        '/duties/assignments/$_occurrence',
        setUp: (h) => h.duties.mine = mineWith([myDutyData()]),
      );
      expect(byKey('duty-not-available'), findsOneWidget);
    });
  });
}
