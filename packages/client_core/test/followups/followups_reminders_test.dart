// Story 4.7: follow-up task reminders on both clients: the reminders a task
// shows, the creator's reminder choice on the staff create form (and a
// source's fixed schedule), the deep link a follow-up reminder opens, and the
// owner decision on Q4 (owners from the task's own group or a Pastor). Fakes
// only; the server behaviour is covered by
// supabase/tests/followups_reminders_test.sql and
// tools/identity-e2e/followups-reminders.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _task = '46464646-4646-4646-8646-464646464646';
const _pastor = '88888888-8888-4888-8888-888888888888';
const _scope = '44444444-4444-4444-8444-444444444444';

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

Map<String, Object?> purposeData({bool fixed = false}) => {
  'source_type': 'fixture_followup',
  'purpose': 'synthetic_check_in',
  'label': 'SYNTHETIC check-in',
  'scope_kinds': ['department_leader'],
  'outcomes': ['contacted'],
  'fixed_reminders': fixed,
};

/// The department's roster as the server answers it since the Q4 owner
/// decision: its members and leaders plus the current Pastors.
Map<String, Object?> supervisionData({bool fixed = false}) => {
  'scopes': [
    {
      'scope_kind': 'department_leader',
      'scope_id': _scope,
      'family': 'department',
      'candidates': [
        followUpPersonData(),
        followUpPersonData(memberId: _pastor, displayName: 'SYNTHETIC Pastor'),
      ],
    },
  ],
  'purposes': [purposeData(fixed: fixed)],
  'tasks': <Object?>[],
  'truncated': false,
};

Future<SentCommand> createWith(
  WidgetTester tester,
  ClientTestHarness h, {
  String owner = 'SYNTHETIC Member M',
  List<int>? reminders,
}) async {
  await choose(tester, 'followup-create-owner', owner);
  await tester.enterText(byKey('followup-create-next'), 'SYNTHETIC: call');
  await tester.enterText(byKey('followup-create-due-date'), '2099-01-04');
  await tester.pump();
  if (reminders != null) {
    await tapKey(tester, 'followup-create-reminders-custom');
    // The first choice (at the due time) starts selected.
    for (var i = 0; i < followUpReminderChoices.length; i++) {
      final on = i == 0;
      if (reminders.contains(i) != on) {
        await tapKey(tester, 'followup-create-reminder-$i');
      }
    }
  }
  await tapKey(tester, 'followup-create-save');
  return h.gateway.sent.last;
}

void main() {
  group('wire parsing', () {
    test('a task\'s reminders parse with plain labels', () {
      final r = FollowUpReminders.fromJson({
        'schedule': 'custom',
        'owner': [
          {'anchor': 'deadline', 'before': '24 hours'},
          {'anchor': 'deadline', 'before': '0 minutes'},
        ],
        'supervisor': [
          {'anchor': 'deadline', 'after': '1 day'},
        ],
        'on_assignment': true,
      });
      expect(r.schedule, FollowUpReminderSchedule.custom);
      expect(r.ownerText, 'Owner reminders: 24 hours before, at the due time.');
      expect(
        r.supervisorText,
        'Supervisor alert: 1 day after a missed deadline.',
      );
      expect(
        FollowUpReminders.fromJson({
          'schedule': 'default',
          'owner': null,
          'supervisor': <Object?>[],
          'on_assignment': false,
        }).ownerText,
        'Owner reminders: the church default.',
      );
    });

    test('a malformed reminder is refused', () {
      expect(
        () => FollowUpReminderSpec.fromJson({
          'anchor': 'deadline',
          'before': '1 hour',
          'after': '1 hour',
        }),
        throwsFormatException,
      );
      expect(
        () => FollowUpReminderSpec.fromJson({
          'anchor': 'starts_at',
          'before': '1 hour',
        }),
        throwsFormatException,
      );
      expect(
        () => FollowUpReminderSchedule.fromWire('weekly'),
        throwsFormatException,
      );
    });

    test('an older server without reminders still parses', () {
      final t = FollowUpTask.fromJson(followUpTaskData());
      expect(t.reminders, isNull);
    });

    test('a follow-up reminder deep-links to the task, nothing else', () {
      expect(ClientPaths.isKnownDeepLink(FollowUpPaths.task(_task)), isTrue);
      expect(
        ClientPaths.isKnownDeepLink('/followups/tasks/not-an-id'),
        isFalse,
      );
      expect(ClientPaths.isKnownDeepLink('/followups/supervision'), isFalse);
      expect(
        ClientPaths.isKnownDeepLink('/followups/tasks/$_task?x=1'),
        isFalse,
      );
    });

    test(
      'the draft sends the creator\'s reminders, never for a fixed source',
      () {
        FollowUpDraft draft(bool fixed, List<FollowUpReminderSpec>? r) =>
            FollowUpDraft(
              purpose: FollowUpPurpose.fromJson(purposeData(fixed: fixed)),
              sourceId: _task,
              ownerMemberId: _pastor,
              scope: const FollowUpScope(
                scopeKind: 'department_leader',
                scopeId: _scope,
              ),
              nextAction: 'SYNTHETIC: call',
              dueAt: DateTime.utc(2099, 1, 4),
              reminders: r,
            );
        expect(
          draft(false, null).toPayload().containsKey('reminders'),
          isFalse,
        );
        expect(draft(false, const []).toPayload()['reminders'], isEmpty);
        expect(
          draft(false, const [
            FollowUpReminderSpec.before('1 hour'),
          ]).toPayload()['reminders'],
          [
            {'anchor': 'deadline', 'before': '1 hour'},
          ],
        );
        expect(
          draft(true, const [
            FollowUpReminderSpec.before('1 hour'),
          ]).toPayload().containsKey('reminders'),
          isFalse,
        );
      },
    );
  });

  testWidgets('the task shows which reminders apply', (tester) async {
    await pumpAt(
      tester,
      FollowUpPaths.task(_task),
      setUp: (h) => h.followUps.task = AccessReadOk(
        FollowUpDetail.fromJson({
          'view': 'full',
          'task': followUpTaskData(
            reminders: {
              'schedule': 'source',
              'owner': [
                {'anchor': 'deadline', 'before': '0 minutes'},
                {'anchor': 'deadline', 'after': '2 days'},
              ],
              'supervisor': <Object?>[],
              'on_assignment': false,
            },
          ),
          'activity': <Object?>[],
          'notes': <Object?>[],
        }),
      ),
    );
    final text = tester.widget<Text>(byKey('followup-reminders-text')).data!;
    expect(text, contains('Reminders set by this task\'s source.'));
    expect(text, contains('at the due time, 2 days after'));
    expect(text, contains('No supervisor alert.'));
  });

  testWidgets(
    'the creator picks the owner\'s reminders, or keeps the default',
    (tester) async {
      final h = await pumpAt(
        tester,
        FollowUpPaths.supervision,
        setUp: (h) => h.followUps.supervision = AccessReadOk(
          FollowUpSupervision.fromJson(supervisionData()),
        ),
      );
      final first = await createWith(tester, h, reminders: [0, 2]);
      final p = first.wire['payload'] as Map;
      expect(p['reminders'], [
        {'anchor': 'deadline', 'before': '0 minutes'},
        {'anchor': 'deadline', 'before': '24 hours'},
      ]);
      first.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'reminders': 'fixed_by_source'},
      );
      await settle(tester);
      expect(
        find.textContaining('This source sets its own reminders.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('a source with its own schedule offers no reminder choice', (
    tester,
  ) async {
    final h = await pumpAt(
      tester,
      FollowUpPaths.supervision,
      setUp: (h) => h.followUps.supervision = AccessReadOk(
        FollowUpSupervision.fromJson(supervisionData(fixed: true)),
      ),
    );
    expect(byKey('followup-create-reminders-fixed'), findsOneWidget);
    expect(byKey('followup-create-reminders-custom'), findsNothing);
    final sent = await createWith(tester, h);
    expect((sent.wire['payload'] as Map).containsKey('reminders'), isFalse);
  });

  group('owner decision Q4: the task\'s own group or a Pastor', () {
    testWidgets('a Pastor outside the group is offered and accepted', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        FollowUpPaths.supervision,
        setUp: (h) => h.followUps.supervision = AccessReadOk(
          FollowUpSupervision.fromJson(supervisionData()),
        ),
      );
      final sent = await createWith(tester, h, owner: 'SYNTHETIC Pastor');
      final p = sent.wire['payload'] as Map;
      expect(p['owner_member_id'], _pastor);
      expect(p.containsKey('reminders'), isFalse);
      sent.confirm({'task_id': _task, 'revision': 1, 'state': 'open'}, 1);
      await settle(tester);
      expect(byKey('followups-notice-created'), findsOneWidget);
    });

    testWidgets('a refusal for an owner outside the group (or a former '
        'Pastor) is explained', (tester) async {
      final h = await pumpAt(
        tester,
        FollowUpPaths.supervision,
        setUp: (h) => h.followUps.supervision = AccessReadOk(
          FollowUpSupervision.fromJson(supervisionData()),
        ),
      );
      final sent = await createWith(tester, h, owner: 'SYNTHETIC Pastor');
      sent.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'owner_member_id': 'not_in_scope'},
      );
      await settle(tester);
      expect(
        find.textContaining('belong to this task\'s group or be a Pastor'),
        findsOneWidget,
      );
    });

    test('candidates come only from the roster the server sent', () {
      final sup = FollowUpSupervision.fromJson(supervisionData());
      final names = followUpCandidatesFor(
        sup.scopes,
        const FollowUpScope(scopeKind: 'department_leader', scopeId: _scope),
      ).map((p) => p.name);
      expect(names, ['SYNTHETIC Member M', 'SYNTHETIC Pastor']);
    });
  });
}
