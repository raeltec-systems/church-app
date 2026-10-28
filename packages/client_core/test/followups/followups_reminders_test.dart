// Story 4.7: follow-up task reminders on both clients: the reminders a task
// shows, the creator's reminder choice on the staff create form (and a
// source's fixed schedule), the deep link a follow-up reminder opens, and the
// owner decision on Q4 (owners from the task's own group or a Pastor). Fakes
// only; the server behaviour is covered by
// supabase/tests/followups_reminders_test.sql and
// tools/identity-e2e/followups-reminders.mjs.
import 'dart:async';
import 'dart:convert';

import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/supabase_adapters.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart' hide ErrorCode;

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
      expect(
        r.ownerText(),
        'Owner reminders: 24 hours before, at the due time.',
      );
      expect(
        r.supervisorText(),
        'Supervisor alert: 1 day after a missed deadline.',
      );
      // Review N5: while Waiting the review date is the deadline.
      expect(
        r.ownerText(waiting: true),
        'Owner reminders: 24 hours before the review date, at the review time.',
      );
      expect(
        r.supervisorText(waiting: true),
        'Supervisor alert: 1 day after a missed review date.',
      );
      expect(
        FollowUpReminders.fromJson({
          'schedule': 'default',
          'owner': null,
          'supervisor': <Object?>[],
          'on_assignment': false,
        }).ownerText(),
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

    test('candidates come only from the roster the server sent', () {
      final sup = FollowUpSupervision.fromJson(supervisionData());
      final names = followUpCandidatesFor(
        sup.scopes,
        const FollowUpScope(scopeKind: 'department_leader', scopeId: _scope),
      ).map((p) => p.name);
      expect(names, ['SYNTHETIC Member M', 'SYNTHETIC Pastor']);
    });
  });

  // Review N6: the same screens over the REAL SupabaseCommandGateway and
  // SupabaseFollowUpsRepository (mock HTTP only): the request that goes out
  // and how the server's refusal envelope maps to what the leader reads.
  group('over the real adapters', () {
    for (final (fieldErrors, code, expected) in [
      (
        {'owner_member_id': 'not_in_scope'},
        'validation_failed',
        'The owner must belong to this task\'s group or be a Pastor.',
      ),
      (
        {'reminders': 'fixed_by_source'},
        'validation_failed',
        'This source sets its own reminders.',
      ),
      ({'policy': 'gate_closed'}, 'unavailable', 'Not available yet'),
    ]) {
      testWidgets('a create refused $code ${jsonEncode(fieldErrors)} is '
          'explained', (tester) async {
        final sent = <http.Request>[];
        final h = await pumpAt(
          tester,
          FollowUpPaths.supervision,
          setUp: (h) => h.followUps.supervision = AccessReadOk(
            FollowUpSupervision.fromJson(supervisionData()),
          ),
        );
        // A second harness is not needed: swap the gateway before acting.
        final real = (await tester.runAsync(
          () async => _realGateway(
            (body) => {
              'request_id': body['request_id'],
              'code': code,
              'message': 'The request is not valid.',
              'field_errors': fieldErrors,
            },
            sent: sent,
          ),
        ))!;
        await tester.pumpWidget(const SizedBox());
        h.commandGateway = _RealZoneGateway(real);
        final router = buildClientRouter(
          initialLocation: FollowUpPaths.supervision,
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
        await _realSettle(tester);
        await choose(tester, 'followup-create-owner', 'SYNTHETIC Pastor');
        await tester.enterText(
          byKey('followup-create-next'),
          'SYNTHETIC: call',
        );
        await tester.enterText(byKey('followup-create-due-date'), '2099-01-04');
        await tester.pump();
        await tapKey(tester, 'followup-create-save');
        await _realSettle(tester);
        final request = sent.single;
        expect(request.url.path, '/rest/v1/rpc/followups_command');
        expect(request.headers['content-profile'], 'api');
        final body = jsonDecode(request.body) as Map;
        expect(body['command'], 'followups.create_task');
        expect((body['payload'] as Map)['owner_member_id'], _pastor);
        expect(find.textContaining(expected), findsOneWidget);
      });
    }

    test('the task read asks followups_task for that id and reads its '
        'reminders; a closed gate is a denial, not a failure', () async {
      final requests = <http.Request>[];
      var answer = (
        jsonEncode({
          'view': 'full',
          'task': followUpTaskData(
            state: 'waiting',
            reviewAt: '2099-01-05T08:00:00.000000Z',
            reminders: {
              'schedule': 'custom',
              'owner': [
                {'anchor': 'deadline', 'before': '0 minutes'},
              ],
              'supervisor': [
                {'anchor': 'deadline', 'after': '1 day'},
              ],
              'on_assignment': true,
            },
          ),
          'activity': <Object?>[],
          'notes': <Object?>[],
        }),
        200,
      );
      final client = SupabaseClient(
        'http://localhost:54321',
        'sb_publishable_test',
        httpClient: MockClient((request) async {
          if (request.url.path.startsWith('/auth/')) {
            return http.Response(
              jsonEncode(_session()),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          requests.add(request);
          return http.Response(
            answer.$1,
            answer.$2,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);
      await client.auth.signInWithPassword(
        phone: '+447700900372',
        password: 'p',
      );
      final repo = SupabaseFollowUpsRepository(client);
      final read = await repo.fetchTask(_task);
      expect(requests.single.url.path, '/rest/v1/rpc/followups_task');
      expect(jsonDecode(requests.single.body), {'p_task_id': _task});
      final task = (read as AccessReadOk<FollowUpDetail>).value.task!;
      expect(task.reminders!.schedule, FollowUpReminderSchedule.custom);
      expect(
        task.reminders!.ownerText(waiting: task.state == FollowUpState.waiting),
        'Owner reminders: at the review time.',
      );
      answer = (
        jsonEncode({
          'code': 'PT403',
          'message': 'unavailable',
          'details': 'unavailable',
          'hint': null,
        }),
        403,
      );
      final denied = await repo.fetchTask(_task);
      expect(denied, isA<AccessReadDenied<FollowUpDetail>>());
      expect(
        (denied as AccessReadDenied<FollowUpDetail>).denial,
        AccessDenial.unavailable,
      );
    });
  });
}

/// A real SupabaseCommandGateway whose HTTP client answers every RPC with
/// [answer]; [sent] collects the requests.
SupabaseCommandGateway _realGateway(
  Map<String, Object?> Function(Map<String, Object?> sent) answer, {
  required List<http.Request> sent,
}) {
  final client = SupabaseClient(
    'http://localhost:54321',
    'sb_publishable_test',
    httpClient: MockClient((request) async {
      sent.add(request);
      final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
      return http.Response(
        jsonEncode(answer(body)),
        200,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    }),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  return SupabaseCommandGateway(client);
}

/// Runs the real gateway outside a widget test's fake clock.
class _RealZoneGateway implements CommandGateway {
  _RealZoneGateway(this._inner);
  final CommandGateway _inner;

  @override
  Future<CommandOutcome> send(String function, CommandRequest request) =>
      Zone.root.run(() => _inner.send(function, request));
}

Future<void> _realSettle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

const _sub = '11111111-1111-4111-8111-111111111111';

String _testJwt(String sub) {
  String b64(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${b64({'alg': 'none'})}.${b64({
    'sub': sub,
    'exp': 4102444800,
    'amr': [
      {'method': 'password', 'timestamp': 1790000000},
    ],
    'role': 'authenticated',
  })}.x';
}

Map<String, Object?> _session() => {
  'access_token': _testJwt(_sub),
  'token_type': 'bearer',
  'expires_in': 3600,
  'expires_at': 4102444800,
  'refresh_token': 'test-refresh',
  'user': {
    'id': _sub,
    'aud': 'authenticated',
    'role': 'authenticated',
    'phone': '447700900372',
    'app_metadata': <String, Object?>{},
    'user_metadata': <String, Object?>{},
    'created_at': '2026-10-14T07:00:00Z',
  },
};
