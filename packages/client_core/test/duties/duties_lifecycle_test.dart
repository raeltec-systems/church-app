// Story 4.12: membership lifecycle and handover in Duties and Follow-ups on
// the clients: the vacancy flag (coverage queue and board, never a reason),
// taking a member out of a department (confirmed first), a department's
// pending leader handover (marked done only once it has a reachable leader),
// a Confirmed by leader assignment that ended in the board's history, and a
// follow-up task handed over automatically. Fakes only; the server behaviour
// is covered by supabase/tests/duties_lifecycle_test.sql and
// tools/identity-e2e/duties-lifecycle.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _dept = '44444444-4444-4444-8444-444444444444';
const _occ = '43434343-4343-4343-8343-434343434343';
const _slot = '45454545-4545-4545-8545-454545454545';
const _slot2 = '46464646-4646-4646-8646-464646464646';
const _asg = '42424242-4242-4242-8242-424242424242';
const _ruth = '66666666-6666-4666-8666-666666666666';
const _lydia = '99999999-9999-4999-8999-999999999999';
const _obligation = '3c3c3c3c-3c3c-4c3c-8c3c-3c3c3c3c3c3c';

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
  await settle(tester);
}

bool enabled(WidgetTester tester, String key) {
  final w = tester.widget(byKey(key));
  return switch (w) {
    ButtonStyleButton b => b.onPressed != null,
    _ => throw StateError('not a button: $key'),
  };
}

Map<String, Object?> departmentData({
  int revision = 4,
  List<Map<String, Object?>>? handovers,
  bool? needsLeader,
}) => {
  'department_id': _dept,
  'name': 'SYNTHETIC Preaching Rota',
  'department_state': 'active',
  'is_synthetic': true,
  'revision': revision,
  'leaders': const <Object?>[],
  'deputies': const <Object?>[],
  'members': [
    {
      'member_id': _ruth,
      'display_name': 'SYNTHETIC Ruth',
      'account': 'app_account',
      'since': '2026-10-13T08:00:00.000000Z',
    },
  ],
  'handovers': ?handovers,
  'needs_leader': ?needsLeader,
};

AccessRead<DutyAdminOverview> adminWith(Map<String, Object?> department) =>
    AccessReadOk(
      DutyAdminOverview.fromJson({
        'departments': [department],
        'members': [
          {
            'member_id': _ruth,
            'display_name': 'SYNTHETIC Ruth',
            'account': 'app_account',
            'grants_revision': 3,
          },
          {
            'member_id': _lydia,
            'display_name': 'SYNTHETIC Lydia',
            'account': 'app_account',
            'grants_revision': 2,
          },
        ],
      }),
    );

Map<String, Object?> historyEntry({
  String endReason = 'vacated',
  String? provenance = 'member',
}) => {
  'assignment_id': _asg,
  'member_id': _ruth,
  'display_name': 'SYNTHETIC Ruth',
  'state': 'superseded',
  'end_reason': endReason,
  'ended_at': '2026-10-15T08:00:00.000000Z',
  'response': provenance == null ? 'pending' : 'accepted',
  'responded_at': provenance == null ? null : '2026-10-14T08:00:00.000000Z',
  'prior_accepted_at': null,
  'response_provenance': provenance,
  'note': null,
  'slot_revision': 1,
};

Map<String, Object?> boardDuty({List<Map<String, Object?>>? history}) => {
  'occurrence_id': _occ,
  'department_id': _dept,
  'duty_name': 'Sunday preaching',
  'starts_at': '2099-01-04T08:00:00.000000Z',
  'ends_at': null,
  'reporting_at': null,
  'location': 'SYNTHETIC Main hall',
  'instructions': null,
  'state': 'published',
  'revision': 3,
  'published_at': '2026-10-13T08:00:00.000000Z',
  'positions': [
    {
      'slot_id': _slot,
      'position_no': 1,
      'slot_revision': 2,
      'assignment': null,
      'history': history ?? [historyEntry(provenance: 'leader')],
    },
  ],
};

AccessRead<DutyLeaderBoard> boardWith(Map<String, Object?> duty) =>
    AccessReadOk(
      DutyLeaderBoard.fromJson({
        'departments': [
          {
            'department_id': _dept,
            'name': 'SYNTHETIC Preaching Rota',
            'capacity': 'department_leader',
            'can_publish': true,
            'members': const <Object?>[],
            'duties': [duty],
          },
        ],
      }),
    );

Map<String, Object?> coveragePosition({
  required String slot,
  String status = 'unfilled',
  Map<String, Object?>? vacated,
}) => {
  'slot_id': slot,
  'position_no': 1,
  'position_name': 'Preacher',
  'occurrence_id': _occ,
  'occurrence_revision': 5,
  'series_id': null,
  'duty_name': 'Sunday service',
  'starts_at': '2099-01-04T08:00:00.000000Z',
  'ends_at': null,
  'reporting_at': null,
  'location': 'SYNTHETIC Main hall',
  'positions_left': 2,
  'status': status,
  'needs_contact': null,
  'vacated': vacated,
  'overlaps': 0,
  'assignment': null,
  'follow_up': null,
};

Map<String, Object?> coverageCounts({int? vacated}) => {
  'required': 2,
  'confirmed': 0,
  'unfilled': 2,
  'awaiting': 0,
  'overdue': 0,
  'declined': 0,
  'needs_contact': 0,
  'conflicts': 0,
  'overdue_follow_ups': 0,
  'vacated': ?vacated,
};

AccessRead<DutyCoverage> coverageWith({int? vacatedCount = 1}) => AccessReadOk(
  DutyCoverage.fromJson({
    'window': {
      'from': '2099-01-01',
      'to': '2099-01-07',
      'zone': 'Africa/Lusaka',
    },
    'duty': null,
    'truncated': false,
    'departments': [
      {
        'department_id': _dept,
        'name': 'SYNTHETIC Preaching Rota',
        'view': 'full',
        'can_manage': true,
        'can_contact': true,
        'members': const <Object?>[],
        'counts': coverageCounts(vacated: vacatedCount),
        'contact_routes': const <String, Object?>{},
        'positions': [
          coveragePosition(
            slot: _slot,
            vacated: {'since': '2026-10-15T08:00:00.000000Z'},
          ),
          coveragePosition(slot: _slot2),
        ],
      },
    ],
  }),
);

void main() {
  group('wire mapping', () {
    test('a department carries its pending handovers and leader state', () {
      final d = AdminDepartment.fromJson(
        departmentData(
          handovers: [
            {
              'obligation_id': _obligation,
              'recorded_at': '2026-10-15T08:00:00.000000Z',
            },
          ],
          needsLeader: true,
        ),
      );
      expect(d.handovers.single.obligationId, _obligation);
      expect(d.handovers.single.recordedAt.isUtc, isTrue);
      expect(d.needsLeader, isTrue);
      // An older server sends neither: nothing pending.
      final old = AdminDepartment.fromJson(departmentData());
      expect(old.handovers, isEmpty);
      expect(old.needsLeader, isFalse);
      expect(
        () => AdminDepartment.fromJson(
          departmentData(
            handovers: [
              {'obligation_id': _obligation},
            ],
          ),
        ),
        throwsFormatException,
      );
    });

    test('a vacated position on the board, never a reason', () {
      final b = (boardWith(boardDuty()) as AccessReadOk<DutyLeaderBoard>).value;
      final p = b.departments.single.duties.single.positions.single;
      expect(p.vacated, isTrue);
      expect(p.history.single.provenance, 'leader');
      final reassigned = (boardWith(
        boardDuty(history: [historyEntry(endReason: 'revised')]),
      ) as AccessReadOk<DutyLeaderBoard>).value;
      expect(
        reassigned.departments.single.duties.single.positions.single.vacated,
        isFalse,
      );
    });

    test('the coverage queue flags and counts vacated positions', () {
      final c = (coverageWith() as AccessReadOk<DutyCoverage>).value;
      final d = c.departments.single;
      expect(d.positions.first.vacated, isTrue);
      expect(d.positions.first.vacatedSince!.isUtc, isTrue);
      expect(d.positions.last.vacated, isFalse);
      expect(d.counts.vacated, 1);
      // An older server sends no count.
      final old = (coverageWith(
        vacatedCount: null,
      ) as AccessReadOk<DutyCoverage>).value;
      expect(old.departments.single.counts.vacated, 0);
      // Only an unfilled position can be vacated.
      expect(
        () => CoveragePosition.fromJson(
          coveragePosition(
            slot: _slot,
            status: 'awaiting',
            vacated: {'since': '2026-10-15T08:00:00.000000Z'},
          ),
        ),
        throwsFormatException,
      );
    });

    test('a task handed over automatically says so (never why)', () {
      final a = FollowUpActivity.fromJson({
        'at': '2026-10-15T08:00:00.000000Z',
        'action': 'reassigned',
        'capacity': 'source',
        'actor': null,
        'on_behalf_of': null,
        'from_state': null,
        'to_state': null,
        'outcome': null,
        'review_at': null,
        'from_member': 'SYNTHETIC Ruth',
        'to_member': 'SYNTHETIC Lydia',
        'code': 'handover',
      });
      expect(a.summary, 'Reassigned to SYNTHETIC Lydia');
      expect(a.attribution, 'handed over automatically');
    });
  });

  group('staff web: departments (Admin)', () {
    testWidgets('removing a member is confirmed, then sent by revision', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminDepartments,
        setUp: (h) => h.duties.admin = adminWith(departmentData()),
      );
      await tapKey(tester, 'remove-member-$_dept-$_ruth');
      expect(byKey('remove-member-explain'), findsOneWidget);
      await tapKey(tester, 'remove-member-cancel');
      expect(h.gateway.sent, isEmpty);

      await tapKey(tester, 'remove-member-$_dept-$_ruth');
      await tapKey(tester, 'remove-member-confirm');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'duties_command');
      expect(sent.wire['command'], 'duties.remove_member');
      expect(sent.wire['expected_revision'], 4);
      expect(sent.wire['payload'], {
        'department_id': _dept,
        'member_id': _ruth,
      });
      sent.confirm({
        'department_id': _dept,
        'revision': 5,
        'vacated': 2,
        'drafts_cleared': 0,
        'notices_skipped': false,
      }, 5);
      await settle(tester);
      expect(byKey('duties-notice-memberRemoved'), findsOneWidget);
      expect(find.textContaining('Needs a new person'), findsOneWidget);
    });

    testWidgets('a pending handover is marked done only with a leader', (
      tester,
    ) async {
      final pending = [
        {
          'obligation_id': _obligation,
          'recorded_at': '2026-10-15T08:00:00.000000Z',
        },
      ];
      await pumpAt(
        tester,
        ClientPaths.adminDepartments,
        setUp: (h) => h.duties.admin = adminWith(
          departmentData(handovers: pending, needsLeader: true),
        ),
      );
      expect(byKey('department-handover-$_dept'), findsOneWidget);
      expect(find.text('Handover pending'), findsOneWidget);
      expect(enabled(tester, 'resolve-handover-$_dept'), isFalse);
    });

    testWidgets('marking it done; a missing leader is explained', (
      tester,
    ) async {
      final pending = [
        {
          'obligation_id': _obligation,
          'recorded_at': '2026-10-15T08:00:00.000000Z',
        },
      ];
      final h = await pumpAt(
        tester,
        ClientPaths.adminDepartments,
        setUp: (h) => h.duties.admin = adminWith(
          departmentData(handovers: pending, needsLeader: false),
        ),
      );
      expect(enabled(tester, 'resolve-handover-$_dept'), isTrue);
      await tapKey(tester, 'resolve-handover-$_dept');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'duties.resolve_handover');
      expect(sent.wire['expected_revision'], 4);
      expect(sent.wire['payload'], {'department_id': _dept});
      sent.refuse(
        ErrorCode.conflict,
        fieldErrors: const {'department_id': 'leader_required'},
      );
      await settle(tester);
      expect(byKey('duties-notice-leaderRequired'), findsOneWidget);
      await tapKey(tester, 'resolve-handover-$_dept');
      h.gateway.sent.last.confirm({
        'department_id': _dept,
        'revision': 5,
        'resolved': 1,
      }, 5);
      await settle(tester);
      expect(byKey('duties-notice-handoverResolved'), findsOneWidget);
    });
  });

  group('staff web: the vacancy flag', () {
    testWidgets('the coverage queue flags the position, without a reason', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.dutyCoverage,
        setUp: (h) => h.coverage.coverage = coverageWith(),
      );
      expect(byKey('coverage-vacated-$_slot'), findsOneWidget);
      expect(byKey('coverage-vacated-$_slot2'), findsNothing);
      expect(find.textContaining('1 need a new person'), findsOneWidget);
      expect(
        find.textContaining('can no longer serve it. Give it to someone else'),
        findsOneWidget,
      );
      for (final reason in ['deactivat', 'deleted', 'hold', 'moved']) {
        expect(find.textContaining(reason), findsNothing);
      }
    });

    testWidgets('the board shows Needs a new person', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) => h.duties.board = boardWith(boardDuty()),
      );
      expect(byKey('position-vacated-$_slot'), findsOneWidget);
      expect(find.text('Needs a new person'), findsOneWidget);
    });
  });
}
