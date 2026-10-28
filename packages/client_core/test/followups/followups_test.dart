// Story 4.6: the Follow-ups registry on both clients: My follow-ups (every
// owner, the Home card), one task with updates, attribution for a scope
// holder recording for the owner, Admin routing metadata only, the
// supervision screen (create, reassign) and honest command states. Fakes
// only; the server behaviour is covered by
// supabase/tests/followups_registry_test.sql and tools/identity-e2e/followups.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _task = '46464646-4646-4646-8646-464646464646';
const _other = '47474747-4747-4747-8747-474747474747';
const _owner = '22222222-2222-4222-8222-222222222222';
const _o = '55555555-5555-4555-8555-555555555555';
const _x = '77777777-7777-4777-8777-777777777777';

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? setUp,
}) async {
  tester.view.physicalSize = const Size(1200, 5000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = ClientTestHarness();
  // Story 6.1: Home shows the member cards to a member only.
  if (location == ClientPaths.home) {
    h.grants.myAccess = AccessReadOk(syntheticGrants());
  }
  setUp?.call(h);
  final router = buildClientRouter(
    initialLocation: location,
    memberHome: true,
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

AccessRead<MyFollowUps> mine(List<Map<String, Object?>> tasks) => AccessReadOk(
  MyFollowUps.fromJson({
    'member_id': _owner,
    'tasks': tasks,
    'truncated': false,
  }),
);

AccessRead<FollowUpDetail> full(
  Map<String, Object?> task, {
  List<Map<String, Object?>> activity = const [],
  List<Map<String, Object?>> notes = const [],
}) => AccessReadOk(
  FollowUpDetail.fromJson({
    'view': 'full',
    'task': task,
    'activity': activity,
    'notes': notes,
  }),
);

Map<String, Object?> activityData({
  String action = 'outcome_recorded',
  String capacity = 'supervisor',
  String? actor = 'SYNTHETIC Leader',
  String? onBehalfOf,
  String? outcome = 'contacted',
}) => {
  'at': '2026-10-14T08:30:00.000000Z',
  'action': action,
  'capacity': capacity,
  'actor': actor,
  'on_behalf_of': onBehalfOf,
  'from_state': null,
  'to_state': null,
  'outcome': outcome,
  'review_at': null,
  'from_member': null,
  'to_member': null,
  'code': null,
};

Map<String, Object?> supervisionData({List<Map<String, Object?>>? tasks}) => {
  'scopes': [rosterData()],
  'purposes': [
    {
      'source_type': 'fixture_followup',
      'purpose': 'synthetic_check_in',
      'label': 'SYNTHETIC check-in',
      'scope_kinds': ['cell_leader', 'department_leader'],
      'outcomes': ['contacted', 'unreachable'],
    },
  ],
  'tasks':
      tasks ??
      [
        followUpTaskData(
          capacity: 'supervisor',
          canReassign: true,
          owner: followUpPersonData(
            memberId: _x,
            displayName: 'SYNTHETIC Accountless X',
            account: 'no_login',
          ),
        ),
      ],
  'truncated': false,
};

/// The department scope with its roster (review S2: owners come from it).
Map<String, Object?> rosterData() => {
  'scope_kind': 'department_leader',
  'scope_id': '44444444-4444-4444-8444-444444444444',
  'family': 'department',
  'candidates': [
    followUpPersonData(),
    followUpPersonData(memberId: _o, displayName: 'SYNTHETIC Member O'),
    followUpPersonData(
      memberId: _x,
      displayName: 'SYNTHETIC Accountless X',
      account: 'no_login',
    ),
  ],
};

void main() {
  group('wire parsing', () {
    test('a full task parses; Waiting needs its review date', () {
      final t = FollowUpTask.fromJson(
        followUpTaskData(
          state: 'waiting',
          reviewAt: '2099-01-10T07:00:00.000000Z',
        ),
      );
      expect(t.state, FollowUpState.waiting);
      expect(t.routing.reviewAt, DateTime.utc(2099, 1, 10, 7));
      expect(t.routing.actionableAt, DateTime.utc(2099, 1, 10, 7));
      expect(t.contextLabel, 'SYNTHETIC check-in source');
      expect(t.outcomes, ['contacted', 'no_longer_needed', 'unreachable']);
      expect(
        () => FollowUpTask.fromJson(followUpTaskData(state: 'waiting')),
        throwsFormatException,
      );
      expect(
        () => FollowUpTask.fromJson(
          followUpTaskData(state: 'done', finishedAt: null)
            ..['finished_at'] = null,
        ),
        throwsFormatException,
      );
      expect(
        () =>
            FollowUpTask.fromJson(followUpTaskData()..['capacity'] = 'pastor'),
        throwsFormatException,
      );
    });

    test('the Admin detail is routing metadata only', () {
      final d = FollowUpDetail.fromJson({
        'view': 'routing',
        'task': followUpTaskData(routing: true),
      });
      expect(d.task, isNull);
      expect(d.notes, isEmpty);
      expect(d.meta.owner.name, 'SYNTHETIC Member M');
      expect(
        () => FollowUpDetail.fromJson({'view': 'other', 'task': {}}),
        throwsFormatException,
      );
      // A routing row cannot be read as a full task (no private fields).
      expect(
        () => FollowUpTask.fromJson(followUpTaskData(routing: true)),
        throwsFormatException,
      );
    });

    test('an erased person reads as a former member; activity attribution', () {
      final p = FollowUpPerson.fromJson(
        followUpPersonData(displayName: null, account: 'no_login'),
      );
      expect(p.name, 'Former member');
      final a = FollowUpActivity.fromJson(
        activityData(onBehalfOf: 'SYNTHETIC Accountless X'),
      );
      expect(a.summary, 'Outcome: Contacted');
      expect(
        a.attribution,
        'recorded by SYNTHETIC Leader for SYNTHETIC Accountless X',
      );
      final s = FollowUpActivity.fromJson(
        activityData(
          action: 'closed_by_source',
          capacity: 'source',
          actor: null,
          outcome: null,
        )..['code'] = 'resolved',
      );
      expect(s.attribution, 'by its source');
      expect(followUpCodeLabel('no_longer_needed'), 'No longer needed');
    });

    test('payloads carry only what changed, instants in UTC', () {
      final u = FollowUpUpdate(
        status: FollowUpState.waiting,
        reviewAt: ChurchTime.parse('2099-01-10', '09:00'),
      );
      expect(u.toPayload(_task), {
        'task_id': _task,
        'status': 'waiting',
        'review_at': '2099-01-10T07:00:00.000Z',
      });
      expect(const FollowUpUpdate(note: '  ').isEmpty, isTrue);
      final purpose = FollowUpSupervision.fromJson(supervisionData())
          .purposes
          .single;
      final draft = FollowUpDraft(
        purpose: purpose,
        sourceId: _other,
        ownerMemberId: _owner,
        scope: const FollowUpScope(
          scopeKind: 'department_leader',
          scopeId: '44444444-4444-4444-8444-444444444444',
        ),
        nextAction: ' Call ',
        dueAt: DateTime.utc(2099, 1, 4, 15),
      );
      expect(draft.toPayload(), {
        'source_type': 'fixture_followup',
        'source_id': _other,
        'source_revision': 1,
        'purpose': 'synthetic_check_in',
        'owner_member_id': _owner,
        'scope_kind': 'department_leader',
        'scope_id': '44444444-4444-4444-8444-444444444444',
        'next_action': 'Call',
        'due_at': '2099-01-04T15:00:00.000Z',
      });
    });

    test('supervision navigation follows a department or cell scope', () {
      expect(supervisesFollowUps(null), isFalse);
      expect(supervisesFollowUps(syntheticGrants(roles: ['admin'])), isFalse);
      expect(
        supervisesFollowUps(
          syntheticGrants(
            scopes: const [
              ScopeGrant(
                scopeKind: 'cell_leader',
                scopeId: '44444444-4444-4444-8444-444444444444',
              ),
            ],
          ),
        ),
        isTrue,
      );
    });
  });

  testWidgets('My follow-ups lists the owner\'s tasks with an Overdue label', (
    tester,
  ) async {
    await pumpAt(
      tester,
      FollowUpPaths.mine,
      setUp: (h) => h.followUps.mine = mine([
        followUpTaskData(overdue: true, duePassed: true),
        followUpTaskData(
          taskId: _other,
          state: 'closed',
          closeReason: 'SYNTHETIC: no longer needed',
          nextAction: 'SYNTHETIC: finished one',
        ),
      ]),
    );
    expect(find.text('SYNTHETIC: phone and check in'), findsOneWidget);
    expect(
      find.descendant(
        of: byKey('followup-status-$_task'),
        matching: find.text('Overdue'),
      ),
      findsOneWidget,
    );
    expect(find.text('Finished in the last 30 days'), findsOneWidget);
    expect(
      find.descendant(
        of: byKey('followup-status-$_other'),
        matching: find.text('Closed'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'an empty My follow-ups says so; a failed read never looks empty',
    (tester) async {
      final h = await pumpAt(
        tester,
        FollowUpPaths.mine,
        setUp: (h) => h.followUps.mine = mine(const []),
      );
      expect(byKey('my-followups-empty'), findsOneWidget);
      h.followUps.mine = const AccessReadFailed(unreachable: true);
      await tapKey(tester, 'followups-reload');
      await settle(tester);
      expect(byKey('my-followups-empty'), findsNothing);
      expect(byKey('followups-failed'), findsOneWidget);
    },
  );

  testWidgets(
    'the owner starts a task; it shows In progress only after the server confirms',
    (tester) async {
      final h = await pumpAt(
        tester,
        FollowUpPaths.task(_task),
        setUp: (h) => h.followUps.task = full(followUpTaskData()),
      );
      expect(byKey('followup-actions'), findsOneWidget);
      expect(byKey('followup-recording-for-owner'), findsNothing);
      await tapKey(tester, 'followup-start');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'followups_command');
      expect(sent.wire['command'], 'followups.update_task');
      expect(sent.wire['expected_revision'], 1);
      expect(sent.wire['payload'], {'task_id': _task, 'status': 'in_progress'});
      expect(byKey('followups-pending'), findsOneWidget);
      h.followUps.task = full(
        followUpTaskData(state: 'in_progress', revision: 2),
      );
      sent.confirm(const {}, 2);
      await settle(tester);
      expect(byKey('followups-notice-updated'), findsOneWidget);
      expect(
        find.descendant(
          of: byKey('followup-status'),
          matching: find.text('In progress'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Waiting sends the review date from church time; Close needs a reason',
    (tester) async {
      final h = await pumpAt(
        tester,
        FollowUpPaths.task(_task),
        setUp: (h) => h.followUps.task = full(followUpTaskData()),
      );
      expect(enabled(tester, 'followup-wait'), isFalse);
      await tester.enterText(byKey('followup-review-date'), '2099-01-10');
      await tester.enterText(byKey('followup-review-time'), '09:00');
      await tester.pump();
      await tapKey(tester, 'followup-wait');
      final wait = h.gateway.sent.single;
      expect(wait.wire['payload'], {
        'task_id': _task,
        'status': 'waiting',
        'review_at': '2099-01-10T07:00:00.000Z',
      });
      wait.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'review_at': 'past'},
      );
      await settle(tester);
      expect(byKey('followups-notice-invalid'), findsOneWidget);
      expect(
        find.textContaining('The review date is in the past.'),
        findsOneWidget,
      );
      expect(enabled(tester, 'followup-close'), isFalse);
      await tester.enterText(
        byKey('followup-close-reason'),
        'SYNTHETIC: done elsewhere',
      );
      await tester.pump();
      await tapKey(tester, 'followup-close');
      expect(h.gateway.sent.last.wire['payload'], {
        'task_id': _task,
        'status': 'closed',
        'close_reason': 'SYNTHETIC: done elsewhere',
      });
    },
  );

  testWidgets(
    'a scope holder records for the owner, attributed; notes and activity show who',
    (tester) async {
      final h = await pumpAt(
        tester,
        FollowUpPaths.task(_task),
        setUp: (h) => h.followUps.task = full(
          followUpTaskData(
            capacity: 'supervisor',
            canReassign: true,
            owner: followUpPersonData(
              memberId: _x,
              displayName: 'SYNTHETIC Accountless X',
              account: 'no_login',
            ),
          ),
          activity: [activityData(onBehalfOf: 'SYNTHETIC Accountless X')],
          notes: [
            {
              'note_id': _other,
              'at': '2026-10-14T08:30:00.000000Z',
              'author': 'SYNTHETIC Leader',
              'on_behalf_of': 'SYNTHETIC Accountless X',
              'body': 'SYNTHETIC note: reached by phone',
              'erased': false,
            },
          ],
        ),
      );
      expect(byKey('followup-recording-for-owner'), findsOneWidget);
      expect(find.text('SYNTHETIC note: reached by phone'), findsOneWidget);
      expect(
        find.textContaining(
          'recorded by SYNTHETIC Leader for SYNTHETIC Accountless X',
        ),
        findsNWidgets(2),
      );
      await choose(tester, 'followup-outcome', 'Unreachable');
      await tapKey(tester, 'followup-record-outcome');
      expect(h.gateway.sent.single.wire['payload'], {
        'task_id': _task,
        'outcome': 'unreachable',
      });
    },
  );

  testWidgets('an Admin opening a task sees routing metadata only', (
    tester,
  ) async {
    await pumpAt(
      tester,
      FollowUpPaths.task(_task),
      setUp: (h) => h.followUps.task = AccessReadOk(
        FollowUpDetail.fromJson({
          'view': 'routing',
          'task': followUpTaskData(routing: true),
        }),
      ),
    );
    expect(byKey('followup-routing-only'), findsOneWidget);
    expect(byKey('followup-actions'), findsNothing);
    expect(byKey('followup-notes'), findsNothing);
    expect(find.text('SYNTHETIC: phone and check in'), findsNothing);
  });

  testWidgets(
    'an unknown outcome stays Not sent yet and checks again with the same request',
    (tester) async {
      final h = await pumpAt(
        tester,
        FollowUpPaths.task(_task),
        setUp: (h) => h.followUps.task = full(followUpTaskData()),
      );
      await tester.enterText(byKey('followup-note'), 'SYNTHETIC note');
      await tester.pump();
      await tapKey(tester, 'followup-add-note');
      final first = h.gateway.sent.single;
      first.unknown();
      await settle(tester);
      expect(byKey('followups-notice-unconfirmed'), findsOneWidget);
      await tapKey(tester, 'followups-check-again');
      expect(h.gateway.sent, hasLength(2));
      expect(h.gateway.sent.last.wire, first.wire);
    },
  );

  testWidgets('the supervisor creates a SYNTHETIC task and reassigns another', (
    tester,
  ) async {
    final h = await pumpAt(
      tester,
      FollowUpPaths.supervision,
      setUp: (h) => h.followUps.supervision = AccessReadOk(
        FollowUpSupervision.fromJson(supervisionData()),
      ),
    );
    expect(
      find.textContaining('Owner: SYNTHETIC Accountless X (no login)'),
      findsOneWidget,
    );
    expect(enabled(tester, 'followup-create-save'), isFalse);
    await choose(tester, 'followup-create-owner', 'SYNTHETIC Member O');
    await tester.enterText(byKey('followup-create-next'), 'SYNTHETIC: call O');
    await tester.enterText(byKey('followup-create-due-date'), '2099-01-04');
    await tester.pump();
    await tapKey(tester, 'followup-create-save');
    final create = h.gateway.sent.single;
    expect(create.wire['command'], 'followups.create_task');
    expect(create.wire['expected_revision'], isNull);
    final p = create.wire['payload'] as Map;
    expect(p['owner_member_id'], _o);
    expect(p['due_at'], '2099-01-04T15:00:00.000Z');
    expect(p['source_revision'], 1);
    expect(
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(p['source_id'] as String),
      isTrue,
    );
    create.refuse(
      ErrorCode.conflict,
      fieldErrors: const {'purpose': 'task_exists'},
    );
    await settle(tester);
    expect(byKey('followups-notice-taskExists'), findsOneWidget);
    await tapKey(tester, 'followup-reassign-$_task');
    await choose(
      tester,
      'followup-reassign-owner-$_task',
      'SYNTHETIC Member O',
    );
    await tapKey(tester, 'followup-reassign-save-$_task');
    final re = h.gateway.sent.last;
    expect(re.wire['command'], 'followups.reassign');
    expect(re.wire['payload'], {'task_id': _task, 'owner_member_id': _o});
  });

  testWidgets(
    'Admin routing shows owner, scope and status without private content',
    (tester) async {
      await pumpAt(
        tester,
        FollowUpPaths.adminRouting,
        setUp: (h) => h.followUps.routing = AccessReadOk(
          FollowUpAdminRouting.fromJson({
            'tasks': [followUpTaskData(routing: true)],
            'scopes': [rosterData()],
            'truncated': false,
          }),
        ),
      );
      expect(byKey('routing-$_task'), findsOneWidget);
      expect(find.text('Owner: SYNTHETIC Member M'), findsOneWidget);
      expect(find.text('SYNTHETIC: phone and check in'), findsNothing);
    },
  );

  testWidgets(
    'Admin routing lists what waits for handover and continues it (story 4.12)',
    (tester) async {
      final h = await pumpAt(
        tester,
        FollowUpPaths.adminRouting,
        setUp: (h) => h.followUps.routing = AccessReadOk(
          FollowUpAdminRouting.fromJson({
            'tasks': [followUpTaskData(routing: true)],
            'scopes': [rosterData()],
            'truncated': false,
            'handovers': [
              {
                'member_id': _x,
                'display_name': 'SYNTHETIC Member X',
                'membership_state': 'approved',
                'tasks': 5,
                'supervisions': 0,
              },
            ],
          }),
        ),
      );
      expect(byKey('routing-handover-$_x'), findsOneWidget);
      expect(
        find.textContaining('no longer in the task\'s group'),
        findsOneWidget,
      );
      await tapKey(tester, 'routing-continue-handover-$_x');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'followups.complete_handover');
      expect(sent.wire['expected_revision'], isNull);
      expect(sent.wire['payload'], {'member_id': _x});
      sent.confirm({'member_id': _x, 'handed_over': 0, 'remaining': 0}, 1);
      await settle(tester);
      // Review N11: nothing moved, so it does not say "handed over".
      expect(byKey('followups-notice-handoverNoneMoved'), findsOneWidget);
      await tapKey(tester, 'routing-continue-handover-$_x');
      h.gateway.sent.last.confirm({
        'member_id': _x,
        'handed_over': 5,
        'remaining': 0,
      }, 1);
      await settle(tester);
      expect(byKey('followups-notice-handoverContinued'), findsOneWidget);
    },
  );

  test('an older server without handovers still reads', () {
    final r = FollowUpAdminRouting.fromJson({
      'tasks': const <Object?>[],
      'scopes': const <Object?>[],
      'truncated': false,
    });
    expect(r.handovers, isEmpty);
  });

  testWidgets('the Home card is hidden without open work', (tester) async {
    await pumpAt(
      tester,
      ClientPaths.home,
      setUp: (h) => h.followUps.mine = mine([followUpTaskData(state: 'done')]),
    );
    expect(byKey('home-followups-card'), findsNothing);
    // Review N6: finished work stays reachable from Home.
    expect(byKey('home-followups-link'), findsOneWidget);
  });

  testWidgets('the Home card counts open and overdue work and shows the next', (
    tester,
  ) async {
    await pumpAt(
      tester,
      ClientPaths.home,
      setUp: (h) => h.followUps.mine = mine([
        followUpTaskData(
          taskId: _other,
          nextAction: 'SYNTHETIC: later one',
          dueAt: '2099-02-01T08:00:00.000000Z',
        ),
        followUpTaskData(overdue: true),
      ]),
    );
    expect(byKey('home-followups-card'), findsOneWidget);
    expect(
      tester.widget<Text>(byKey('home-followups-count')).data,
      '2 active, 1 overdue',
    );
    expect(byKey('home-followup-$_task'), findsOneWidget);
  });

  testWidgets('a failed My follow-ups read shows on the Home card', (
    tester,
  ) async {
    await pumpAt(
      tester,
      ClientPaths.home,
      setUp: (h) =>
          h.followUps.mine = const AccessReadFailed(unreachable: true),
    );
    expect(byKey('home-followups-failed'), findsOneWidget);
  });

  testWidgets(
    'review S4: after Saved the note field is empty, so a second Add note '
    'sends nothing',
    (tester) async {
      final h = await pumpAt(
        tester,
        FollowUpPaths.task(_task),
        setUp: (h) => h.followUps.task = full(followUpTaskData()),
      );
      await tester.enterText(byKey('followup-note'), 'SYNTHETIC note');
      await tester.pump();
      await tapKey(tester, 'followup-add-note');
      h.followUps.task = full(followUpTaskData(revision: 2));
      h.gateway.sent.single.confirm(const {}, 2);
      await settle(tester);
      expect(byKey('followups-notice-updated'), findsOneWidget);
      expect(enabled(tester, 'followup-add-note'), isFalse);
      await tester.tap(byKey('followup-add-note'), warnIfMissed: false);
      await tester.pump();
      expect(h.gateway.sent, hasLength(1));
    },
  );

  testWidgets(
    'review S4: re-tapping Create after an unknown outcome resends the same '
    'request and source; a confirmed create starts a new source',
    (tester) async {
      final h = await pumpAt(
        tester,
        FollowUpPaths.supervision,
        setUp: (h) => h.followUps.supervision = AccessReadOk(
          FollowUpSupervision.fromJson(supervisionData()),
        ),
      );
      await choose(tester, 'followup-create-owner', 'SYNTHETIC Member O');
      await tester.enterText(byKey('followup-create-next'), 'SYNTHETIC: call');
      await tester.enterText(byKey('followup-create-due-date'), '2099-01-04');
      await tester.pump();
      await tapKey(tester, 'followup-create-save');
      final first = h.gateway.sent.single;
      first.unknown();
      await settle(tester);
      expect(byKey('followups-notice-unconfirmed'), findsOneWidget);
      await tapKey(tester, 'followup-create-save');
      final second = h.gateway.sent.last;
      expect(h.gateway.sent, hasLength(2));
      expect(second.wire, first.wire);
      second.confirm(const {}, 1);
      await settle(tester);
      expect(byKey('followups-notice-created'), findsOneWidget);
      await choose(tester, 'followup-create-owner', 'SYNTHETIC Member O');
      await tester.enterText(byKey('followup-create-next'), 'SYNTHETIC: again');
      await tester.pump();
      await tapKey(tester, 'followup-create-save');
      final third = h.gateway.sent.last;
      expect(
        (third.wire['payload'] as Map)['source_id'],
        isNot((first.wire['payload'] as Map)['source_id']),
      );
      expect(third.wire['request_id'], isNot(first.wire['request_id']));
    },
  );

  test('candidates come from the task scope\'s roster only', () {
    final sup = FollowUpSupervision.fromJson(supervisionData());
    final task = sup.tasks.single;
    expect(
      followUpCandidatesFor(sup.scopes, task.routing.scope).map((p) => p.name),
      ['SYNTHETIC Member M', 'SYNTHETIC Member O', 'SYNTHETIC Accountless X'],
    );
    expect(
      followUpCandidatesFor(
        sup.scopes,
        const FollowUpScope(scopeKind: 'cell_leader', scopeId: 'other'),
      ),
      isEmpty,
    );
  });

  // Story 4.14 (C5): Follow-ups keeps an in-flight request pending across a
  // reload, as Duties has since 4.5, so it cannot be sent twice.
  testWidgets('a reload while an update is in flight cannot send it twice', (
    tester,
  ) async {
    final h = await pumpAt(
      tester,
      FollowUpPaths.task(_task),
      setUp: (h) => h.followUps.task = full(followUpTaskData()),
    );
    await choose(tester, 'followup-outcome', 'Unreachable');
    await tapKey(tester, 'followup-record-outcome');
    final sent = h.gateway.sent.single;
    final reads = h.followUps.taskReads.length;
    final container = ProviderScope.containerOf(
      tester.element(byKey('followup-record-outcome')),
    );
    await container.read(followUpTaskProvider(_task).notifier).reload();
    await settle(tester);
    expect(h.followUps.taskReads, hasLength(reads + 1));
    expect(byKey('followups-pending'), findsOneWidget);
    expect(enabled(tester, 'followup-record-outcome'), isFalse);
    await tester.tap(byKey('followup-record-outcome'), warnIfMissed: false);
    await tester.pump();
    expect(h.gateway.sent, hasLength(1));
    sent.unknown();
    await settle(tester);
    // The unconfirmed update is resent under the same request id.
    await tapKey(tester, 'followups-check-again');
    expect(h.gateway.sent, hasLength(2));
    expect(h.gateway.sent.last.wire['request_id'], sent.wire['request_id']);
  });
}
