// Story 4.8: answer-by defaults, Short notice, the creator's member
// reminders (a duty, a rota, one date or this and later dates) and the
// leader's Needs contact list. Fakes only; the server behaviour is covered by
// supabase/tests/duties_reminders_test.sql and
// tools/identity-e2e/duties-reminders.mjs. CI also runs this file with
// TZ=America/New_York (church time is Africa/Lusaka whatever the device zone).
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _dept = '44444444-4444-4444-8444-444444444444';
const _assignment = '42424242-4242-4242-8242-424242424242';
const _x = '48484848-4848-4848-8848-484848484848';
const _occurrence = '43434343-4343-4343-8343-434343434343';
const _occurrence2 = '47474747-4747-4747-8747-474747474747';
const _slot = '45454545-4545-4545-8545-454545454545';
const _slot2 = '46464646-4646-4646-8646-464646464646';
const _series = '49494949-4949-4949-8949-494949494949';
const _ruth = '66666666-6666-4666-8666-666666666666';
const _lydia = '99999999-9999-4999-8999-999999999999';

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? setUp,
}) async {
  tester.view.physicalSize = const Size(1200, 8000);
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

Future<void> enter(WidgetTester tester, String key, String text) async {
  await tester.ensureVisible(byKey(key));
  await tester.enterText(byKey(key), text);
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

Map<String, Object?> assignmentData({
  String id = _assignment,
  String member = _ruth,
  String name = 'SYNTHETIC Ruth',
  String response = 'pending',
  String deadlineSource = 'default',
  bool shortNotice = false,
  Map<String, Object?>? needsContact,
}) => {
  'assignment_id': id,
  'member_id': member,
  'display_name': name,
  'response': response,
  'response_deadline': '2099-01-02T08:00:00.000000Z',
  'deadline_source': deadlineSource,
  'short_notice': shortNotice,
  'needs_contact': needsContact,
  'responded_at': response == 'pending' ? null : '2026-10-13T09:00:00.000000Z',
  'note': null,
  'revision': 1,
  'slot_revision': 1,
  'changes': null,
  'notes_updated_at': null,
};

Map<String, Object?> leaderDuty({
  String id = _occurrence,
  String slot = _slot,
  Object? reminders,
  Map<String, Object?>? assignment,
}) => {
  'occurrence_id': id,
  'department_id': _dept,
  'duty_name': 'Sunday preaching',
  'starts_at': '2099-01-04T08:00:00.000000Z',
  'ends_at': null,
  'reporting_at': null,
  'location': 'SYNTHETIC Main hall',
  'instructions': null,
  'reminders': reminders,
  'state': 'published',
  'revision': 3,
  'published_at': '2026-10-13T08:00:00.000000Z',
  'positions': [
    {
      'slot_id': slot,
      'position_no': 1,
      'slot_revision': 1,
      'assignment': assignment ?? assignmentData(),
      'history': const <Object?>[],
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
            'members': [
              {
                'member_id': _ruth,
                'display_name': 'SYNTHETIC Ruth',
                'account': 'app_account',
                'since': '2026-10-13T08:00:00.000000Z',
              },
              {
                'member_id': _lydia,
                'display_name': 'SYNTHETIC Lydia',
                'account': 'no_login',
                'since': '2026-10-13T08:00:00.000000Z',
              },
            ],
            'duties': duties,
          },
        ],
      }),
    );

Map<String, Object?> rotaOccurrence(
  String id,
  String slot, {
  Object? reminders,
}) => {
  'occurrence_id': id,
  'series_date': id == _occurrence ? '2099-01-04' : '2099-01-11',
  'state': 'published',
  'revision': 2,
  'duty_name': 'Sunday service',
  'starts_at': id == _occurrence
      ? '2099-01-04T08:00:00.000000Z'
      : '2099-01-11T08:00:00.000000Z',
  'ends_at': null,
  'reporting_at': null,
  'location': null,
  'instructions': null,
  'topic': null,
  'scripture': null,
  'event_ref': null,
  'reminders': reminders,
  'started': false,
  'required': 1,
  'confirmed': 0,
  'positions': [
    {
      'slot_id': slot,
      'position_no': 1,
      'position_name': 'Preacher',
      'draft': null,
      'assignment': {
        'assignment_id': id == _occurrence ? _assignment : _x,
        'member_id': _ruth,
        'display_name': 'SYNTHETIC Ruth',
        'response': 'pending',
        'response_deadline': '2099-01-02T08:00:00.000000Z',
        'deadline_source': 'default',
        'short_notice': id == _occurrence,
        'needs_contact': id == _occurrence
            ? {
                'reasons': ['short_notice'],
                'since': '2026-10-14T08:00:00.000000Z',
              }
            : null,
        'revision': 1,
        'available': true,
      },
    },
  ],
};

AccessRead<DutyRota> rotaWith({int draftSlots = 2}) => AccessReadOk(
  DutyRota.fromJson({
    'departments': [
      {
        'department_id': _dept,
        'name': 'SYNTHETIC Preaching Rota',
        'capacity': 'department_leader',
        'can_manage': true,
        'members': [
          {
            'member_id': _ruth,
            'display_name': 'SYNTHETIC Ruth',
            'account': 'app_account',
            'since': '2026-10-13T08:00:00.000000Z',
          },
        ],
        'series': [
          {
            'series_id': _series,
            'department_id': _dept,
            'duty_name': 'Sunday service',
            'every': 'week',
            'interval': 1,
            'from_date': '2099-01-04',
            'until_date': '2099-01-11',
            'start_time': '10:00',
            'end_time': null,
            'reporting_time': null,
            'location': null,
            'instructions': null,
            'topic': null,
            'scripture': null,
            'event_ref': null,
            'positions': ['Preacher'],
            'zone': 'Africa/Lusaka',
            'revision': 4,
            'draft_slots': draftSlots,
            'occurrences': [
              rotaOccurrence(_occurrence, _slot),
              rotaOccurrence(
                _occurrence2,
                _slot2,
                reminders: [
                  {'anchor': 'starts_at', 'before': '2 hours'},
                ],
              ),
            ],
          },
        ],
        'series_truncated': false,
      },
    ],
  }),
);

void main() {
  group('wire mapping', () {
    test('My duties reads the deadline source, Short notice and reminders', () {
      final d = MyDuty.fromJson(
        myDutyData(
          extra: {
            'deadline_source': 'default',
            'short_notice': true,
            'reminders': null,
          },
        ),
      );
      expect(d.deadlineSource, DutyDeadlineSource.churchDefault);
      expect(d.shortNotice, isTrue);
      expect(d.answerNow(DateTime.utc(2098)), isTrue);
      expect(d.reminders!.isDefault, isTrue);
      final custom = MyDuty.fromJson(
        myDutyData(
          extra: {
            'deadline_source': 'creator',
            'short_notice': false,
            'reminders': [
              {'anchor': 'response_deadline', 'before': '2 days'},
              {'anchor': 'starts_at', 'before': '1 hour'},
            ],
          },
        ),
      );
      expect(
        custom.reminders!.text,
        'Reminders: 2 days before the answer-by time, 1 hour before the start.',
      );
      // A server before 4.8 sends none of the keys.
      final legacy = MyDuty.fromJson(myDutyData());
      expect(legacy.deadlineSource, DutyDeadlineSource.creator);
      expect(legacy.shortNotice, isFalse);
      expect(legacy.reminders, isNull);
      expect(
        () => MyDuty.fromJson(myDutyData(extra: {'deadline_source': 'leader'})),
        throwsFormatException,
      );
      expect(
        () => MyDuty.fromJson(
          myDutyData(
            extra: {
              'reminders': [
                {'anchor': 'deadline', 'before': '1 day'},
              ],
            },
          ),
        ),
        throwsFormatException,
      );
    });

    test('reminder labels and the defaults read plainly', () {
      expect(
        const DutyReminderSpec.before(
          DutyReminderAnchor.deadline,
          '0 minutes',
        ).label,
        'at the answer-by time',
      );
      expect(
        const DutyReminderSpec.before(DutyReminderAnchor.start, '1 days').label,
        '1 day before the start',
      );
      expect(
        const DutyReminders().text,
        contains('24 hours before and at the answer-by time'),
      );
      expect(const DutyReminders([]).text, 'Reminders: none.');
      expect(const DutyReminders().toWire(), isNull);
      expect(const DutyReminders([]).toWire(), isEmpty);
    });

    test('Needs contact parses strictly and never says why', () {
      final n = DutyContactNeed.fromJsonOrNull({
        'reasons': ['short_notice', 'not_reached'],
        'since': '2026-10-14T08:00:00.000000Z',
      })!;
      expect(n.shortNotice && n.notReached, isTrue);
      expect(n.text, contains('cannot reach them in the app'));
      expect(n.text.toLowerCase(), isNot(contains('hold')));
      expect(DutyContactNeed.fromJsonOrNull(null), isNull);
      expect(
        () => DutyContactNeed.fromJsonOrNull({
          'reasons': ['held'],
          'since': '2026-10-14T08:00:00.000000Z',
        }),
        throwsFormatException,
      );
    });

    test('a duty without an answer-by time sends none (the default)', () {
      final draft = DutyDraft(
        departmentId: _dept,
        dutyName: 'Sunday preaching',
        startsAt: DateTime.utc(2099, 1, 4, 8),
        memberId: _ruth,
        reminders: const [
          DutyReminderSpec.before(DutyReminderAnchor.start, '2 hours'),
        ],
      ).toPayload();
      expect(draft.containsKey('response_deadline'), isFalse);
      expect(draft['reminders'], [
        {'anchor': 'starts_at', 'before': '2 hours'},
      ]);
      expect(
        DutyDraft(
          departmentId: _dept,
          dutyName: 'x',
          startsAt: DateTime.utc(2099),
          memberId: _ruth,
        ).toPayload().containsKey('reminders'),
        isFalse,
      );
    });

    test('the leaders\' alerts open the Duties board', () {
      expect(ClientPaths.isKnownDeepLink('/duties/leader'), isTrue);
    });
  });

  group('staff web: publishing with the defaults or chosen reminders', () {
    testWidgets('no answer-by time and two chosen reminders', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) => h.duties.board = boardWith(const []),
      );
      await enter(tester, 'publish-name-$_dept', 'Sunday preaching');
      await enter(tester, 'publish-date-$_dept', '2099-01-04');
      await enter(tester, 'publish-start-$_dept', '10:00');
      await choose(tester, 'publish-member-$_dept', 'SYNTHETIC Ruth');
      expect(
        enabled(tester, 'publish-save-$_dept'),
        isTrue,
        reason: 'no answer-by time: the church default',
      );
      expect(find.textContaining('Leave the answer-by time empty'), findsOne);
      await tapKey(tester, 'publish-$_dept-reminders-custom');
      await tapKey(tester, 'publish-$_dept-reminder-1');
      await tapKey(tester, 'publish-$_dept-reminder-4');
      await tapKey(tester, 'publish-save-$_dept');
      final payload = h.gateway.sent.single.wire['payload'] as Map;
      expect(payload.containsKey('response_deadline'), isFalse);
      // Church time (Lusaka, UTC+2), whatever the device zone is.
      expect(payload['starts_at'], '2099-01-04T08:00:00.000Z');
      expect(payload['reminders'], [
        {'anchor': 'response_deadline', 'before': '24 hours'},
        {'anchor': 'starts_at', 'before': '2 hours'},
      ]);
    });

    testWidgets('a refused reminder list says so', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) => h.duties.board = boardWith(const []),
      );
      await enter(tester, 'publish-name-$_dept', 'Sunday preaching');
      await enter(tester, 'publish-date-$_dept', '2099-01-04');
      await enter(tester, 'publish-start-$_dept', '10:00');
      await choose(tester, 'publish-member-$_dept', 'SYNTHETIC Ruth');
      await tapKey(tester, 'publish-save-$_dept');
      h.gateway.sent.single.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'reminders': 'out_of_range'},
      );
      await settle(tester);
      expect(byKey('publish-$_dept-reminders-error'), findsOneWidget);
    });
  });

  group('staff web: Short notice, Needs contact and changing reminders', () {
    testWidgets('the board flags direct contact and lists it', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) => h.duties.board = boardWith([
          leaderDuty(
            assignment: assignmentData(
              shortNotice: true,
              needsContact: {
                'reasons': ['short_notice'],
                'since': '2026-10-14T08:00:00.000000Z',
              },
            ),
          ),
          leaderDuty(
            id: _occurrence2,
            slot: _slot2,
            assignment: assignmentData(
              id: _x,
              member: _lydia,
              name: 'SYNTHETIC Lydia',
              deadlineSource: 'creator',
              needsContact: {
                'reasons': ['not_reached'],
                'since': '2026-10-14T08:00:00.000000Z',
              },
            ),
          ),
        ]),
      );
      expect(byKey('short-notice-$_assignment'), findsOneWidget);
      expect(byKey('needs-contact-$_assignment'), findsOneWidget);
      expect(find.textContaining('answer requested now'), findsOneWidget);
      expect(byKey('needs-contact-$_x'), findsOneWidget);
      expect(byKey('short-notice-$_x'), findsNothing);
      expect(find.text('Needs contact (2)'), findsOneWidget);
      expect(byKey('needs-contact-row-$_x'), findsOneWidget);
      expect(
        tester.widget<Text>(byKey('needs-contact-row-$_x')).data,
        contains('Reminders cannot reach them in the app'),
      );
      expect(find.textContaining('(church default)'), findsNothing);
    });

    testWidgets('changing a duty\'s reminders asks nobody again', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) => h.duties.board = boardWith([leaderDuty()]),
      );
      expect(
        tester.widget<Text>(byKey('leader-$_occurrence-reminders-text')).data,
        const DutyReminders().text,
      );
      expect(find.textContaining('(church default)'), findsOneWidget);
      await tapKey(tester, 'leader-$_occurrence-reminders-change');
      await tapKey(tester, 'leader-$_occurrence-edit-reminders-custom');
      await tapKey(tester, 'leader-$_occurrence-reminders-save');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'duties.set_reminders');
      expect(sent.wire['expected_revision'], 3);
      expect(sent.wire['payload'], {
        'occurrence_id': _occurrence,
        'reminders': <Object?>[],
      });
      h.duties.board = boardWith([leaderDuty(reminders: const [])]);
      sent.confirm({'occurrence_id': _occurrence, 'revision': 4}, 4);
      await settle(tester);
      expect(byKey('duties-notice-remindersSet'), findsOneWidget);
    });
  });

  group('staff web: rota', () {
    testWidgets('Publish N with the church default sends no lead time', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyRota,
        setUp: (h) => h.duties.rota = rotaWith(),
      );
      await tapKey(tester, 'rota-publish-$_series');
      await choose(
        tester,
        'rota-publish-lead-$_series',
        'the church default (by lead time)',
      );
      await tapKey(tester, 'rota-publish-confirm-$_series');
      expect(h.gateway.sent.single.wire['payload'], {
        'series_id': _series,
        'slot_count': 2,
      });
    });

    testWidgets('the grid marks Short notice and Needs contact', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.dutyRota,
        setUp: (h) => h.duties.rota = rotaWith(),
      );
      expect(find.textContaining('short notice; needs contact'), findsWidgets);
    });

    testWidgets('reminders for this and later dates use the series', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyRota,
        setUp: (h) => h.duties.rota = rotaWith(),
      );
      await tapKey(tester, 'rota-date-$_occurrence2');
      expect(
        tester.widget<Text>(byKey('rota-$_occurrence2-reminders-text')).data,
        'Reminders: 2 hours before the start.',
      );
      await tapKey(tester, 'rota-reminders-future-$_occurrence2');
      await tapKey(tester, 'rota-$_occurrence2-reminders-change');
      await tapKey(tester, 'rota-$_occurrence2-edit-reminders-custom');
      await tapKey(tester, 'rota-$_occurrence2-reminders-save');
      final sent = h.gateway.sent.single;
      expect(sent.wire['expected_revision'], 4);
      expect(sent.wire['payload'], {
        'series_id': _series,
        'from_occurrence_id': _occurrence2,
        'reminders': null,
      });
    });

    testWidgets('a new rota carries the chosen reminders', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyRota,
        setUp: (h) => h.duties.rota = rotaWith(),
      );
      await tapKey(tester, 'rota-new-$_dept');
      await enter(tester, 'series-name-$_dept', 'Evening prayer');
      await enter(tester, 'series-from-$_dept', '2099-01-04');
      await enter(tester, 'series-until-$_dept', '2099-01-25');
      await enter(tester, 'series-start-$_dept', '18:00');
      await enter(tester, 'series-positions-$_dept', 'Leader');
      await tapKey(tester, 'series-$_dept-reminders-custom');
      await tapKey(tester, 'series-$_dept-reminder-3');
      await tapKey(tester, 'series-create-$_dept');
      final payload = h.gateway.sent.single.wire['payload'] as Map;
      expect(payload['reminders'], [
        {'anchor': 'starts_at', 'before': '24 hours'},
      ]);
    });
  });

  group('mobile: Short notice', () {
    testWidgets('a short-notice duty asks for an answer now', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.myDuties,
        setUp: (h) => h.duties.mine = AccessReadOk(
          MyDuties.fromJson({
            'member_id': _ruth,
            'assignments': [
              myDutyData(
                extra: {
                  'deadline_source': 'default',
                  'short_notice': true,
                  'reminders': null,
                },
              ),
            ],
          }),
        ),
      );
      expect(byKey('duty-short-notice-$_assignment'), findsWidgets);
      expect(find.text('Short notice: please answer now'), findsWidgets);
    });
  });
}
