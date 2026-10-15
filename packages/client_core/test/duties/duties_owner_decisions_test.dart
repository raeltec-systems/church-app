// Story 4.16: the owner's epic 4 decisions on the clients: the coarse vacancy
// reason a department's leaders and deputies read (board and coverage queue;
// nothing when the server sends none), the review notice's deep link to the
// leader board's reviews, and the refusal to remove a department's last
// reachable leader or deputy (Roles & access and Departments). Fakes only; the
// server behaviour is covered by supabase/tests/duties_owner_decisions_test.sql
// and tools/identity-e2e/duties-decisions.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _dept = '44444444-4444-4444-8444-444444444444';
const _occ = '43434343-4343-4343-8343-434343434343';
const _occ2 = '47474747-4747-4747-8747-474747474747';
const _slot = '45454545-4545-4545-8545-454545454545';
const _slot2 = '46464646-4646-4646-8646-464646464646';
const _asg = '42424242-4242-4242-8242-424242424242';
const _flag = '48484848-4848-4848-8848-484848484848';
const _ruth = '66666666-6666-4666-8666-666666666666';
const _lydia = '99999999-9999-4999-8999-999999999999';

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

Map<String, Object?> historyEntry({
  String endReason = 'vacated',
  Object? reason = 'removed_from_department',
  bool withReasonKey = true,
}) => {
  'assignment_id': _asg,
  'member_id': _ruth,
  'display_name': 'SYNTHETIC Ruth',
  'state': 'superseded',
  'end_reason': endReason,
  'ended_at': '2026-10-15T08:00:00.000000Z',
  'response': 'accepted',
  'responded_at': '2026-10-14T08:00:00.000000Z',
  'prior_accepted_at': null,
  'response_provenance': 'member',
  'note': null,
  'slot_revision': 1,
  if (withReasonKey) 'vacancy_reason': reason,
};

Map<String, Object?> boardDuty({
  String occ = _occ,
  String slot = _slot,
  List<Map<String, Object?>>? history,
  List<Map<String, Object?>> reviews = const [],
  String name = 'Sunday preaching',
}) => {
  'occurrence_id': occ,
  'department_id': _dept,
  'duty_name': name,
  'starts_at': '2099-01-04T08:00:00.000000Z',
  'ends_at': null,
  'reporting_at': null,
  'location': 'SYNTHETIC Main hall',
  'instructions': null,
  'state': 'published',
  'revision': 3,
  'published_at': '2026-10-13T08:00:00.000000Z',
  'reviews': reviews,
  'positions': [
    {
      'slot_id': slot,
      'position_no': 1,
      'slot_revision': 2,
      'assignment': null,
      'history': history ?? [historyEntry()],
    },
  ],
};

AccessRead<DutyLeaderBoard> boardWith(List<Map<String, Object?>> duties) =>
    AccessReadOk(
      DutyLeaderBoard.fromJson({
        'departments': [
          {
            'department_id': _dept,
            'name': 'SYNTHETIC Preaching Rota',
            'capacity': 'department_leader',
            'can_publish': true,
            'members': const <Object?>[],
            'duties': duties,
          },
        ],
      }),
    );

Map<String, Object?> coveragePosition({
  required String slot,
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
  'status': 'unfilled',
  'needs_contact': null,
  'vacated': vacated,
  'overlaps': 0,
  'assignment': null,
  'follow_up': null,
};

AccessRead<DutyCoverage> coverageWith({String? reason, String view = 'full'}) =>
    AccessReadOk(
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
            'view': view,
            'can_manage': true,
            'can_contact': view == 'full',
            'members': const <Object?>[],
            'counts': {
              'required': 2,
              'confirmed': 0,
              'unfilled': 2,
              'awaiting': 0,
              'overdue': 0,
              'declined': 0,
              'needs_contact': 0,
              'conflicts': 0,
              'overdue_follow_ups': 0,
              'vacated': 1,
            },
            'contact_routes': const <String, Object?>{},
            'positions': [
              coveragePosition(
                slot: _slot,
                vacated: {
                  'since': '2026-10-15T08:00:00.000000Z',
                  'reason': reason,
                },
              ),
              coveragePosition(slot: _slot2),
            ],
          },
        ],
      }),
    );

void main() {
  group('the vacancy reason (owner item 8)', () {
    test('only a vacated history entry carries a known reason code', () {
      for (final code in [
        DutyVacancyReasons.removedFromDepartment,
        DutyVacancyReasons.memberInactive,
        DutyVacancyReasons.memberDeleted,
      ]) {
        final e = AssignmentHistoryEntry.fromJson(historyEntry(reason: code));
        expect(e.vacancyReason, code);
      }
      // Not sent (another reader), null, unknown or on another end reason.
      expect(
        AssignmentHistoryEntry.fromJson(historyEntry(withReasonKey: false))
            .vacancyReason,
        isNull,
      );
      expect(
        AssignmentHistoryEntry.fromJson(historyEntry(reason: null))
            .vacancyReason,
        isNull,
      );
      expect(
        AssignmentHistoryEntry.fromJson(
          historyEntry(reason: 'SYNTHETIC free text'),
        ).vacancyReason,
        isNull,
      );
      expect(
        AssignmentHistoryEntry.fromJson(historyEntry(endReason: 'revised'))
            .vacancyReason,
        isNull,
      );
      expect(
        DutyVacancyReasons.label('removed_from_department'),
        'Removed from the department',
      );
      expect(
        DutyVacancyReasons.label('member_inactive'),
        'No longer an active member',
      );
      expect(DutyVacancyReasons.label('member_deleted'), 'Member deleted');
    });

    test('a position and a coverage entry expose it only when vacated', () {
      final b =
          (boardWith([boardDuty()]) as AccessReadOk<DutyLeaderBoard>).value;
      final p = b.departments.single.duties.single.positions.single;
      expect(p.vacated, isTrue);
      expect(p.vacancyReason, DutyVacancyReasons.removedFromDepartment);
      final c = (coverageWith(
        reason: 'member_deleted',
      ) as AccessReadOk<DutyCoverage>).value;
      expect(
        c.departments.single.positions.first.vacancyReason,
        DutyVacancyReasons.memberDeleted,
      );
      expect(c.departments.single.positions.last.vacancyReason, isNull);
    });

    testWidgets('the board shows the reason line to a leader', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) => h.duties.board = boardWith([boardDuty()]),
      );
      expect(byKey('position-vacated-$_slot'), findsOneWidget);
      expect(byKey('position-vacancy-reason-$_slot'), findsOneWidget);
      expect(find.text('Reason: Removed from the department'), findsOneWidget);
    });

    testWidgets('no reason line when the server sends none', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) => h.duties.board = boardWith([
          boardDuty(history: [historyEntry(reason: null)]),
        ]),
      );
      expect(byKey('position-vacated-$_slot'), findsOneWidget);
      expect(byKey('position-vacancy-reason-$_slot'), findsNothing);
      expect(find.textContaining('Reason:'), findsNothing);
    });

    testWidgets('the coverage queue shows the reason (staff web and mobile)', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.dutyCoverage,
        setUp: (h) =>
            h.coverage.coverage = coverageWith(reason: 'member_inactive'),
      );
      expect(byKey('coverage-vacancy-reason-$_slot'), findsOneWidget);
      expect(find.text('Reason: No longer an active member'), findsOneWidget);
      expect(byKey('coverage-vacancy-reason-$_slot2'), findsNothing);
    });

    testWidgets('the operational view (no reason sent) shows only the flag', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.dutyCoverage,
        setUp: (h) => h.coverage.coverage = coverageWith(
          reason: null,
          view: 'operational',
        ),
      );
      expect(byKey('coverage-vacated-$_slot'), findsOneWidget);
      expect(byKey('coverage-vacancy-reason-$_slot'), findsNothing);
    });
  });

  group('the review notice deep link (owner item 7)', () {
    test('the notice link is a known deep link', () {
      expect(DutyPaths.leaderReviews, '/duties/leader/reviews');
      expect(ClientPaths.isKnownDeepLink('/duties/leader/reviews'), isTrue);
      expect(ClientPaths.isKnownDeepLink('/duties/leader/reviews/x'), isFalse);
    });

    testWidgets('it opens the board with only the duties to review', (
      tester,
    ) async {
      await pumpAt(
        tester,
        DutyPaths.leaderReviews,
        setUp: (h) => h.duties.board = boardWith([
          boardDuty(
            name: 'Reviewed duty',
            history: [historyEntry(endReason: 'revised')],
            reviews: [
              {
                'flag_id': _flag,
                'revision': 1,
                'source': 'event',
                'changed': ['time'],
                'flagged_at': '2026-10-15T08:00:00.000000Z',
              },
            ],
          ),
          boardDuty(
            occ: _occ2,
            slot: _slot2,
            name: 'Quiet duty',
            history: [historyEntry(endReason: 'revised')],
          ),
        ]),
      );
      expect(byKey('leader-reviews-only'), findsOneWidget);
      expect(byKey('leader-duty-row-$_occ'), findsOneWidget);
      expect(byKey('leader-duty-row-$_occ2'), findsNothing);
      expect(find.text('Needs review (1)'), findsOneWidget);
      await tapKey(tester, 'leader-show-all');
      expect(byKey('leader-reviews-only'), findsNothing);
      expect(byKey('leader-duty-row-$_occ2'), findsOneWidget);
    });
  });

  group('removing the last reachable leader or deputy (owner item 10)', () {
    testWidgets('Roles & access explains the refusal', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminGrants,
        setUp: (h) =>
            h.grants.myAccess = AccessReadOk(syntheticGrants(roles: ['admin'])),
      );
      h.grants.answerRoster(
        AccessReadOk(
          GrantRoster(
            members: [
              RosterMember(
                memberId: _ruth,
                displayName: 'SYNTHETIC Ruth',
                isSynthetic: true,
                account: AccountStanding.appAccount,
                grants: syntheticGrants(
                  memberId: _ruth,
                  revision: 3,
                  scopes: const [
                    ScopeGrant(scopeKind: 'department_leader', scopeId: _dept),
                  ],
                ),
              ),
            ],
            roles: const [RoleOption('admin', available: true)],
            next: null,
          ),
        ),
      );
      await settle(tester);
      await tapKey(tester, 'remove-scope-$_ruth-$_dept');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'identity.revoke_scope');
      sent.refuse(
        ErrorCode.conflict,
        fieldErrors: const {'member_id': 'handover_required'},
        currentRevision: const Optional.of(3),
      );
      await settle(tester);
      expect(byKey('grant-notice-handoverRequired'), findsOneWidget);
      expect(find.text('Hand over first'), findsOneWidget);
      expect(byKey('grant-notice-changedElsewhere'), findsNothing);
    });

    testWidgets('Departments explains the refusal', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminDepartments,
        setUp: (h) => h.duties.admin = AccessReadOk(
          DutyAdminOverview.fromJson({
            'departments': [
              {
                'department_id': _dept,
                'name': 'SYNTHETIC Preaching Rota',
                'department_state': 'active',
                'is_synthetic': true,
                'revision': 4,
                'leaders': [
                  {
                    'member_id': _lydia,
                    'display_name': 'SYNTHETIC Lydia',
                    'grants_revision': 2,
                  },
                ],
                'deputies': const <Object?>[],
                'members': const <Object?>[],
              },
            ],
            'members': const <Object?>[],
          }),
        ),
      );
      await tapKey(tester, 'remove-department_leader-$_dept-$_lydia');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'identity_grant_command');
      expect(sent.wire['command'], 'identity.revoke_scope');
      sent.refuse(
        ErrorCode.conflict,
        fieldErrors: const {'member_id': 'handover_required'},
      );
      await settle(tester);
      expect(byKey('duties-notice-staffHandoverRequired'), findsOneWidget);
      expect(find.text('Hand over first'), findsOneWidget);
    });
  });
}
