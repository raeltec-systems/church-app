// Story 4.9: the coverage queue (wire mapping, filters, the leader's
// essential actions: Call / Message through the platform launcher, record a
// contact attempt, Confirmed by leader, reassign, cancel a position), the
// operational view for Pastor and Admin (nothing private, no actions they may
// not take), the leader Home Needs attention card and the member's view of a
// leader confirmation. Fakes only; the server behaviour is covered by
// supabase/tests/duties_coverage_test.sql and
// tools/identity-e2e/duties-coverage.mjs. CI also runs this file with
// TZ=America/New_York (church time is Africa/Lusaka whatever the device zone).
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _dept = '44444444-4444-4444-8444-444444444444';
const _dept2 = '55555555-5555-4555-8555-555555555555';
const _occ = '43434343-4343-4343-8343-434343434343';
const _slotA = '45454545-4545-4545-8545-454545454545';
const _slotX = '46464646-4646-4646-8646-464646464646';
const _slotO = '47474747-4747-4747-8747-474747474747';
const _slotU = '49494949-4949-4949-8949-494949494949';
const _asgA = '42424242-4242-4242-8242-424242424242';
const _asgX = '48484848-4848-4848-8848-484848484848';
const _asgO = '41414141-4141-4141-8141-414141414141';
const _ruth = '66666666-6666-4666-8666-666666666666';
const _xena = '77777777-7777-4777-8777-777777777777';
const _omar = '88888888-8888-4888-8888-888888888888';
const _lydia = '99999999-9999-4999-8999-999999999999';
const _task = '3a3a3a3a-3a3a-4a3a-8a3a-3a3a3a3a3a3a';

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? setUp,
  bool memberHome = false,
}) async {
  tester.view.physicalSize = const Size(1200, 9000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = ClientTestHarness();
  setUp?.call(h);
  final router = buildClientRouter(
    initialLocation: location,
    memberHome: memberHome,
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

Map<String, Object?> asg({
  required String id,
  required String member,
  required String name,
  String response = 'pending',
  String account = 'app_account',
  String? provenance,
  Map<String, Object?>? confirmation,
  String? note,
}) => {
  'assignment_id': id,
  'revision': 2,
  'member_id': member,
  'display_name': name,
  'account': account,
  'response': response,
  'response_provenance':
      provenance ?? (response == 'pending' ? null : 'member'),
  'response_deadline': '2099-01-02T08:00:00.000000Z',
  'deadline_source': 'default',
  'short_notice': false,
  'responded_at': response == 'pending' ? null : '2026-10-13T09:00:00.000000Z',
  'prior_accepted_at': null,
  'note': note,
  'confirmation': confirmation,
  'changes': null,
};

Map<String, Object?> pos({
  required String slot,
  required String status,
  Map<String, Object?>? assignment,
  String position = 'Preacher',
  int left = 4,
  Map<String, Object?>? needsContact,
  Map<String, Object?>? followUp,
}) => {
  'slot_id': slot,
  'position_no': 1,
  'position_name': position,
  'occurrence_id': _occ,
  'occurrence_revision': 5,
  'series_id': null,
  'duty_name': 'Sunday service',
  'starts_at': '2099-01-04T08:00:00.000000Z',
  'ends_at': null,
  'reporting_at': null,
  'location': 'SYNTHETIC Main hall',
  'positions_left': left,
  'status': status,
  'needs_contact': needsContact,
  'overlaps': 0,
  'assignment': assignment,
  'follow_up': followUp,
};

Map<String, Object?> counts({
  int required = 4,
  int confirmed = 0,
  int unfilled = 1,
  int awaiting = 1,
  int overdue = 0,
  int declined = 1,
  int needsContact = 1,
  int conflicts = 0,
  int overdueFollowUps = 0,
}) => {
  'required': required,
  'confirmed': confirmed,
  'unfilled': unfilled,
  'awaiting': awaiting,
  'overdue': overdue,
  'declined': declined,
  'needs_contact': needsContact,
  'conflicts': conflicts,
  'overdue_follow_ups': overdueFollowUps,
};

/// A leader's full view: Ruth awaiting (with a contact attempt), Xena (no
/// login, needs contact, a household number), Omar declined, Usher unfilled.
Map<String, Object?> fullDepartment() => {
  'department_id': _dept,
  'name': 'SYNTHETIC Preaching Rota',
  'view': 'full',
  'can_manage': true,
  'can_contact': true,
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
      'account': 'app_account',
      'since': '2026-10-13T08:00:00.000000Z',
    },
  ],
  'counts': counts(),
  'contact_routes': {
    _xena: [
      {
        'phone': '+447700900798',
        'belongs_to': 'household',
        'holder_label': 'SYNTHETIC sister',
      },
    ],
  },
  'positions': [
    pos(
      slot: _slotA,
      status: 'awaiting',
      assignment: asg(id: _asgA, member: _ruth, name: 'SYNTHETIC Ruth'),
      followUp: {
        'case_id': '3b3b3b3b-3b3b-4b3b-8b3b-3b3b3b3b3b3b',
        'task_id': _task,
        'opened_at': '2026-10-14T08:00:00.000000Z',
        'attempts': 1,
        'next_follow_up_at': '2099-01-01T16:00:00.000000Z',
        'overdue': false,
        'last_attempt': {
          'at': '2026-10-14T08:00:00.000000Z',
          'by': 'SYNTHETIC Leader',
          'channel': 'phone',
          'outcome': 'no_answer',
          'note': 'SYNTHETIC: try after work',
        },
      },
    ),
    pos(
      slot: _slotX,
      status: 'awaiting',
      position: 'Reader',
      assignment: asg(
        id: _asgX,
        member: _xena,
        name: 'SYNTHETIC Xena',
        account: 'no_login',
      ),
      needsContact: {
        'reasons': ['not_reached'],
        'since': '2026-10-14T08:00:00.000000Z',
      },
    ),
    pos(
      slot: _slotO,
      status: 'declined',
      position: 'Usher',
      assignment: asg(
        id: _asgO,
        member: _omar,
        name: 'SYNTHETIC Omar',
        response: 'declined',
      ),
    ),
    pos(slot: _slotU, status: 'unfilled', position: 'Steward'),
  ],
};

Map<String, Object?> operationalDepartment({bool canManage = false}) => {
  ...fullDepartment(),
  'view': 'operational',
  'can_manage': canManage,
  'can_contact': false,
  'members': const <Object?>[],
  'contact_routes': const <String, Object?>{},
};

AccessRead<DutyCoverage> coverage(List<Map<String, Object?>> departments) =>
    AccessReadOk(
      DutyCoverage.fromJson({
        'window': {
          'from': '2099-01-01',
          'to': '2099-01-07',
          'zone': 'Africa/Lusaka',
        },
        'duty': null,
        'truncated': false,
        'departments': departments,
      }),
    );

void main() {
  group('wire mapping', () {
    test('a full department: states, routes, follow-up, counts', () {
      final c =
          (coverage([fullDepartment()]) as AccessReadOk<DutyCoverage>).value;
      final d = c.departments.single;
      expect(d.full, isTrue);
      expect(d.canContact, isTrue);
      expect(d.positions.map((p) => p.status), [
        CoverageStatus.awaiting,
        CoverageStatus.awaiting,
        CoverageStatus.declined,
        CoverageStatus.unfilled,
      ]);
      expect(d.routesOf(_xena).single.label, 'Household (SYNTHETIC sister)');
      expect(d.routesOf(_ruth), isEmpty);
      final f = d.positions.first.followUp!;
      expect(f.taskId, _task);
      expect(f.lastAttempt.outcome, ContactOutcome.noAnswer);
      expect(d.positions[1].needsContact!.notReached, isTrue);
      expect(d.positions[1].assignment!.account, AccountStanding.noLogin);
      expect(d.positions[2].confirmable, isFalse);
      expect(d.positions[2].contactable, isTrue);
      expect(d.positions[3].assignment, isNull);
      expect(c.managedTotals.unfilled, 1);
      expect(c.leadsAny, isTrue);
    });

    test('Confirmed by leader is kept apart from the member\'s answer', () {
      final p = CoveragePosition.fromJson(
        pos(
          slot: _slotX,
          status: 'confirmed',
          assignment: asg(
            id: _asgX,
            member: _xena,
            name: 'SYNTHETIC Xena',
            response: 'accepted',
            provenance: 'leader',
            confirmation: {
              'by': 'SYNTHETIC Leader',
              'at': '2026-10-14T09:00:00.000000Z',
              'channel': 'phone',
              'reason': 'SYNTHETIC: confirmed with her sister',
            },
          ),
        ),
      );
      expect(p.assignment!.confirmedByLeader, isTrue);
      expect(p.assignment!.confirmation!.channel, ContactChannel.phone);
      final mine = MyDuty.fromJson(
        myDutyData(
          response: 'accepted',
          respondedAt: '2026-10-13T09:00:00.000000Z',
          extra: {
            'response_provenance': 'leader',
            'confirmed_channel': 'in_person',
          },
        ),
      );
      expect(mine.confirmedByLeader, isTrue);
      expect(mine.confirmedChannel, ContactChannel.inPerson);
      expect(MyDuty.fromJson(myDutyData()).confirmedByLeader, isFalse);
    });

    test('malformed answers fail closed', () {
      expect(
        () => CoveragePosition.fromJson(pos(slot: _slotA, status: 'gone')),
        throwsFormatException,
      );
      // Unfilled with an assignment, or a state without one.
      expect(
        () => CoveragePosition.fromJson(
          pos(
            slot: _slotA,
            status: 'unfilled',
            assignment: asg(id: _asgA, member: _ruth, name: 'R'),
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => CoveragePosition.fromJson(pos(slot: _slotA, status: 'awaiting')),
        throwsFormatException,
      );
      expect(
        () => DutyContactRoute.fromJson({
          'phone': '0977 000',
          'belongs_to': 'member',
        }),
        throwsFormatException,
      );
      expect(
        () => CoverageDepartment.fromJson({
          ...fullDepartment(),
          'view': 'everything',
        }),
        throwsFormatException,
      );
    });

    test('filters: Declined covers declines and changed duties', () {
      final d = (coverage([
        fullDepartment(),
      ]) as AccessReadOk<DutyCoverage>).value.departments.single;
      int n(CoverageFilter f) => d.positions.where(f.matches).length;
      expect(n(CoverageFilter.all), 4);
      expect(n(CoverageFilter.unfilled), 1);
      expect(n(CoverageFilter.declined), 1);
      expect(n(CoverageFilter.awaiting), 2);
      expect(n(CoverageFilter.needsContact), 1);
      expect(n(CoverageFilter.confirmed), 0);
      final changed = CoveragePosition.fromJson(
        pos(
          slot: _slotA,
          status: 'changed',
          assignment: asg(id: _asgA, member: _ruth, name: 'R'),
        ),
      );
      expect(CoverageFilter.declined.matches(changed), isTrue);
    });

    test('the query: church dates, days, department and duty', () {
      expect(const CoverageQuery().toParams(), isEmpty);
      expect(
        const CoverageQuery(
          from: '2099-01-30',
          days: 7,
          departmentId: _dept,
          duty: '  service ',
        ).toParams(),
        {
          'from_date': '2099-01-30',
          'to_date': '2099-02-05',
          'department_id': _dept,
          'duty': 'service',
        },
      );
      expect(
        const CoverageQuery(from: '2099-01-01', days: 99).toParams()['to_date'],
        '2099-01-31',
      );
    });

    test('drafts: the attempt and the confirmation payloads', () {
      final now = DateTime.utc(2099, 1, 1, 8);
      final ok = ContactAttemptDraft(
        channel: ContactChannel.phone,
        outcome: ContactOutcome.leftMessage,
        nextFollowUpAt: DateTime.utc(2099, 1, 2, 16),
        note: '  SYNTHETIC: rang  ',
      );
      expect(ok.errors(now: now, startsAt: DateTime.utc(2099, 1, 4)), isEmpty);
      expect(ok.toPayload(_asgA), {
        'assignment_id': _asgA,
        'channel': 'phone',
        'outcome': 'left_message',
        'note': 'SYNTHETIC: rang',
        'next_follow_up_at': '2099-01-02T16:00:00Z',
      });
      expect(ok.errors(now: now, startsAt: DateTime.utc(2099, 1, 2, 9)), {
        'next_follow_up_at': 'after_start',
      });
      expect(
        ContactAttemptDraft(
          channel: ContactChannel.message,
          outcome: ContactOutcome.noAnswer,
          nextFollowUpAt: DateTime.utc(2098),
        ).errors(now: now),
        {'next_follow_up_at': 'past'},
      );
      expect(
        const LeaderConfirmationDraft(
          channel: ContactChannel.phone,
          reason: '   ',
        ).errors(),
        {'reason': 'required'},
      );
      expect(
        const LeaderConfirmationDraft(
          channel: ContactChannel.inPerson,
          reason: 'SYNTHETIC: said yes',
        ).toPayload(_asgX),
        {
          'assignment_id': _asgX,
          'channel': 'in_person',
          'reason': 'SYNTHETIC: said yes',
        },
      );
    });

    test('the decline alert link is a known deep link', () {
      expect(ClientPaths.isKnownDeepLink('/duties/coverage'), isTrue);
      expect(ClientPaths.dutyCoverage, '/duties/coverage');
    });

    test('a cancelled position is not required on the board', () {
      final duty = LeaderDuty.fromJson({
        'occurrence_id': _occ,
        'department_id': _dept,
        'duty_name': 'Sunday service',
        'starts_at': '2099-01-04T08:00:00.000000Z',
        'state': 'published',
        'revision': 3,
        'positions': [
          {'slot_id': _slotA, 'position_no': 1, 'assignment': null},
          {
            'slot_id': _slotU,
            'position_no': 2,
            'cancelled': true,
            'assignment': null,
          },
        ],
      });
      expect(duty.required, 1);
      expect(duty.positions.last.cancelled, isTrue);
    });
  });

  group('the queue (leader)', () {
    testWidgets('cards, counts, filters and the contact route', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyCoverage,
        setUp: (h) => h.coverage.coverage = coverage([fullDepartment()]),
      );
      expect(find.text('Coverage'), findsWidgets);
      expect(byKey('coverage-counts-$_dept'), findsOneWidget);
      expect(
        find.textContaining('0 of 4 confirmed, 1 unfilled'),
        findsOneWidget,
      );
      expect(byKey('coverage-card-$_slotA'), findsOneWidget);
      expect(
        find.text('SYNTHETIC Xena (no login: contact them directly)'),
        findsOneWidget,
      );
      expect(byKey('coverage-needs-contact-$_slotX'), findsOneWidget);
      expect(find.textContaining('SYNTHETIC: try after work'), findsOneWidget);
      expect(byKey('coverage-task-$_slotA'), findsOneWidget);
      // Call opens the phone app through the platform launcher only.
      await tapKey(tester, 'coverage-call-$_slotX-+447700900798');
      expect(h.contact.calls, ['+447700900798']);
      expect(
        find.textContaining('Nothing is sent or recorded'),
        findsOneWidget,
      );
      await tapKey(tester, 'coverage-message-$_slotX-+447700900798');
      expect(h.contact.messages, ['+447700900798']);
      expect(h.gateway.sent, isEmpty);
      // The Declined filter.
      await tapKey(tester, 'coverage-filter-declined');
      expect(byKey('coverage-card-$_slotO'), findsOneWidget);
      expect(byKey('coverage-card-$_slotA'), findsNothing);
      await tapKey(tester, 'coverage-filter-unfilled');
      expect(byKey('coverage-card-$_slotU'), findsOneWidget);
      expect(byKey('coverage-assign-$_slotU'), findsOneWidget);
      expect(byKey('coverage-confirm-$_slotU'), findsNothing);
      expect(byKey('coverage-attempt-$_slotU'), findsNothing);
    });

    testWidgets('the window and duty filters are read from the server', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyCoverage,
        setUp: (h) => h.coverage.coverage = coverage([fullDepartment()]),
      );
      await enter(tester, 'coverage-from', '2099-01-10');
      await enter(tester, 'coverage-duty', 'service');
      await tapKey(tester, 'coverage-apply');
      expect(
        h.coverage.queries.last,
        const CoverageQuery(from: '2099-01-10', duty: 'service'),
      );
    });

    testWidgets('record a contact attempt', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyCoverage,
        setUp: (h) => h.coverage.coverage = coverage([fullDepartment()]),
      );
      await tapKey(tester, 'coverage-attempt-$_slotX');
      expect(byKey('coverage-attempt-form-$_slotX'), findsOneWidget);
      expect(
        find.textContaining('no pastoral or medical detail'),
        findsOneWidget,
      );
      await enter(tester, 'coverage-attempt-note-$_slotX', 'SYNTHETIC: sister');
      await enter(tester, 'coverage-attempt-date-$_slotX', '2099-01-02');
      await enter(tester, 'coverage-attempt-time-$_slotX', '18:00');
      await tapKey(tester, 'coverage-attempt-save-$_slotX');
      final sent = h.gateway.sent.single;
      expect(sent.request.command, 'duties.record_contact_attempt');
      expect(sent.request.expectedRevision.value, 2);
      expect(sent.request.payload, {
        'assignment_id': _asgX,
        'channel': 'phone',
        'outcome': 'no_answer',
        'note': 'SYNTHETIC: sister',
        // 18:00 in Lusaka is 16:00 UTC, whatever the device zone.
        'next_follow_up_at': '2099-01-02T16:00:00Z',
      });
      expect(byKey('duties-pending'), findsOneWidget);
      sent.confirm({'followup': 'opened'}, 5);
      await settle(tester);
      expect(byKey('duties-notice-contactRecorded'), findsOneWidget);
      expect(byKey('coverage-attempt-form-$_slotX'), findsNothing);
    });

    testWidgets('a follow-up after the duty starts is refused before sending', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyCoverage,
        setUp: (h) => h.coverage.coverage = coverage([fullDepartment()]),
      );
      await tapKey(tester, 'coverage-attempt-$_slotX');
      await enter(tester, 'coverage-attempt-date-$_slotX', '2099-01-05');
      await enter(tester, 'coverage-attempt-time-$_slotX', '10:00');
      await tapKey(tester, 'coverage-attempt-save-$_slotX');
      expect(find.text('Must be before the duty starts'), findsOneWidget);
      expect(h.gateway.sent, isEmpty);
    });

    testWidgets('Confirmed by leader needs a reason and says what it is', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyCoverage,
        setUp: (h) => h.coverage.coverage = coverage([fullDepartment()]),
      );
      await tapKey(tester, 'coverage-confirm-$_slotX');
      expect(
        find.textContaining('kept apart from an answer in the app'),
        findsOneWidget,
      );
      expect(enabled(tester, 'coverage-confirm-save-$_slotX'), isFalse);
      await enter(
        tester,
        'coverage-confirm-reason-$_slotX',
        'SYNTHETIC: confirmed by phone',
      );
      expect(enabled(tester, 'coverage-confirm-save-$_slotX'), isTrue);
      await tapKey(tester, 'coverage-confirm-save-$_slotX');
      final sent = h.gateway.sent.single;
      expect(sent.request.command, 'duties.confirm_by_leader');
      expect(sent.request.payload, {
        'assignment_id': _asgX,
        'channel': 'phone',
        'reason': 'SYNTHETIC: confirmed by phone',
      });
      sent.confirm({'provenance': 'leader'}, 5);
      await settle(tester);
      expect(byKey('duties-notice-leaderConfirmed'), findsOneWidget);
    });

    testWidgets('a decline is not confirmed: the refusal says reassign', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyCoverage,
        setUp: (h) => h.coverage.coverage = coverage([fullDepartment()]),
      );
      // The declined card offers no confirmation; a stale card's refusal is
      // explained.
      expect(byKey('coverage-confirm-$_slotO'), findsNothing);
      await tapKey(tester, 'coverage-confirm-$_slotA');
      await enter(tester, 'coverage-confirm-reason-$_slotA', 'SYNTHETIC');
      await tapKey(tester, 'coverage-confirm-save-$_slotA');
      h.gateway.sent.single.refuse(
        ErrorCode.conflict,
        fieldErrors: const {'assignment_id': 'declined'},
      );
      await settle(tester);
      expect(byKey('duties-notice-confirmDeclined'), findsOneWidget);
    });

    testWidgets('reassign the decline and cancel a position', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyCoverage,
        setUp: (h) => h.coverage.coverage = coverage([fullDepartment()]),
      );
      await tapKey(tester, 'coverage-assign-$_slotO');
      expect(
        find.textContaining(
          'SYNTHETIC Omar is told the position is no '
          'longer theirs',
        ),
        findsOneWidget,
      );
      expect(enabled(tester, 'coverage-assign-save-$_slotO'), isFalse);
      await tester.tap(byKey('coverage-who-picker-$_slotO'));
      await settle(tester);
      await tester.tap(find.text('SYNTHETIC Lydia').last);
      await settle(tester);
      await tapKey(tester, 'coverage-assign-save-$_slotO');
      final assign = h.gateway.sent.single;
      expect(assign.request.command, DutyCommands.assignSlot);
      expect(assign.request.expectedRevision.value, 5);
      expect(assign.request.payload, {'slot_id': _slotO, 'member_id': _lydia});
      assign.confirm({'state': 'published'}, 6);
      await settle(tester);
      expect(byKey('duties-notice-positionGiven'), findsOneWidget);

      await tapKey(tester, 'coverage-cancel-$_slotU');
      expect(
        find.textContaining('Only this position is cancelled'),
        findsOneWidget,
      );
      await tapKey(tester, 'coverage-cancel-confirm-$_slotU');
      final cancel = h.gateway.sent.last;
      expect(cancel.request.command, 'duties.cancel_position');
      expect(cancel.request.payload, {'slot_id': _slotU});
      cancel.confirm({'cancelled': 'position'}, 6);
      await settle(tester);
      expect(byKey('duties-notice-positionCancelled'), findsOneWidget);
    });

    testWidgets('an unknown outcome is not shown as done', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyCoverage,
        setUp: (h) => h.coverage.coverage = coverage([fullDepartment()]),
      );
      await tapKey(tester, 'coverage-confirm-$_slotX');
      await enter(tester, 'coverage-confirm-reason-$_slotX', 'SYNTHETIC');
      await tapKey(tester, 'coverage-confirm-save-$_slotX');
      h.gateway.sent.single.unknown();
      await settle(tester);
      expect(byKey('duties-notice-unconfirmed'), findsOneWidget);
      expect(find.text('Confirmed by leader'), findsWidgets);
      expect(byKey('duties-notice-leaderConfirmed'), findsNothing);
    });
  });

  group('review fixes', () {
    testWidgets('S2: no contact work on the leader\'s own duty', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyCoverage,
        setUp: (h) {
          h.grants.myAccess = AccessReadOk(syntheticGrants(memberId: _ruth));
          h.coverage.coverage = coverage([fullDepartment()]);
        },
      );
      expect(byKey('coverage-attempt-$_slotA'), findsNothing);
      expect(byKey('coverage-confirm-$_slotA'), findsNothing);
      expect(
        find.text('This is your own duty: answer it in My duties.'),
        findsOneWidget,
      );
      // Someone else's duty keeps its actions; a refusal says why.
      await tapKey(tester, 'coverage-confirm-$_slotX');
      await enter(tester, 'coverage-confirm-reason-$_slotX', 'SYNTHETIC');
      await tapKey(tester, 'coverage-confirm-save-$_slotX');
      h.gateway.sent.single.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'assignment_id': 'own'},
      );
      await settle(tester);
      expect(byKey('duties-notice-ownAssignment'), findsOneWidget);
    });

    testWidgets('N7: a malformed From date is an error, not today', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyCoverage,
        setUp: (h) => h.coverage.coverage = coverage([fullDepartment()]),
      );
      final reads = h.coverage.queries.length;
      await enter(tester, 'coverage-from', '2099-13-45');
      await tapKey(tester, 'coverage-apply');
      expect(find.text('Use YYYY-MM-DD'), findsOneWidget);
      expect(h.coverage.queries.length, reads);
    });
  });

  group('the queue (Pastor and Admin: nothing private)', () {
    testWidgets('Pastor: church-wide gaps, read only', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.dutyCoverage,
        setUp: (h) => h.coverage.coverage = coverage([
          operationalDepartment(),
          {
            ...operationalDepartment(),
            'department_id': _dept2,
            'name': 'SYNTHETIC Ushers',
            'positions': const <Object?>[],
            'counts': counts(
              required: 0,
              unfilled: 0,
              awaiting: 0,
              declined: 0,
              needsContact: 0,
            ),
          },
        ]),
      );
      expect(byKey('coverage-church-wide'), findsOneWidget);
      expect(byKey('coverage-summary-$_dept2'), findsOneWidget);
      expect(find.text('Pastor oversight (read only).'), findsNWidgets(2));
      expect(find.textContaining('+447700900798'), findsNothing);
      expect(byKey('coverage-attempt-$_slotX'), findsNothing);
      expect(byKey('coverage-confirm-$_slotX'), findsNothing);
      expect(byKey('coverage-assign-$_slotX'), findsNothing);
      expect(byKey('coverage-cancel-$_slotX'), findsNothing);
    });

    testWidgets('Admin without the scope: manage, never contact', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.dutyCoverage,
        setUp: (h) => h.coverage.coverage = coverage([
          operationalDepartment(canManage: true),
        ]),
      );
      expect(find.textContaining('Admin view'), findsOneWidget);
      expect(byKey('coverage-assign-$_slotX'), findsOneWidget);
      expect(byKey('coverage-cancel-$_slotX'), findsOneWidget);
      expect(byKey('coverage-attempt-$_slotX'), findsNothing);
      expect(byKey('coverage-confirm-$_slotX'), findsNothing);
      expect(byKey('coverage-call-$_slotX-+447700900798'), findsNothing);
    });

    testWidgets('a refused read never looks empty', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.dutyCoverage,
        setUp: (h) =>
            h.coverage.coverage = const AccessReadFailed(unreachable: true),
      );
      expect(byKey('duties-failed'), findsOneWidget);
      expect(find.text('No duties in these dates.'), findsNothing);
    });
  });

  group('labels elsewhere', () {
    testWidgets('the board says Confirmed by leader and Cancelled', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) => h.duties.board = AccessReadOk(
          DutyLeaderBoard.fromJson({
            'departments': [
              {
                'department_id': _dept,
                'name': 'SYNTHETIC Preaching Rota',
                'capacity': 'department_leader',
                'can_publish': true,
                'members': const <Object?>[],
                'duties': [
                  {
                    'occurrence_id': _occ,
                    'department_id': _dept,
                    'duty_name': 'Sunday service',
                    'starts_at': '2099-01-04T08:00:00.000000Z',
                    'state': 'published',
                    'revision': 3,
                    'positions': [
                      {
                        'slot_id': _slotX,
                        'position_no': 1,
                        'position_name': 'Reader',
                        'assignment': {
                          ...asg(
                            id: _asgX,
                            member: _xena,
                            name: 'SYNTHETIC Xena',
                            response: 'accepted',
                            provenance: 'leader',
                            confirmation: {
                              'by': 'SYNTHETIC Leader',
                              'at': '2026-10-14T09:00:00.000000Z',
                              'channel': 'phone',
                              'reason': 'SYNTHETIC: with her sister',
                            },
                          ),
                          'slot_revision': 1,
                        },
                      },
                      {
                        'slot_id': _slotU,
                        'position_no': 2,
                        'position_name': 'Usher',
                        'cancelled': true,
                        'assignment': null,
                      },
                    ],
                  },
                ],
              },
            ],
          }),
        ),
      );
      expect(find.text('1 of 1 confirmed'), findsOneWidget);
      expect(find.text('Confirmed by leader'), findsOneWidget);
      expect(find.textContaining('SYNTHETIC: with her sister'), findsOneWidget);
      expect(byKey('position-cancelled-$_slotU'), findsOneWidget);
    });

    testWidgets('the member reads Confirmed by your leader', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.myDuties,
        setUp: (h) => h.duties.mine = AccessReadOk(
          MyDuties.fromJson({
            'member_id': _ruth,
            'assignments': [
              myDutyData(
                response: 'accepted',
                respondedAt: '2026-10-13T09:00:00.000000Z',
                extra: {
                  'response_provenance': 'leader',
                  'confirmed_channel': 'phone',
                },
              ),
            ],
          }),
        ),
      );
      expect(find.text('Confirmed by your leader'), findsWidgets);
      expect(
        MyDuty.fromJson(
          myDutyData(
            response: 'accepted',
            respondedAt: '2026-10-13T09:00:00.000000Z',
            extra: {
              'response_provenance': 'leader',
              'confirmed_channel': 'phone',
            },
          ),
        ).canWithdraw(DateTime.utc(2098)),
        isFalse,
      );
      expect(find.textContaining('SYNTHETIC: with'), findsNothing);
    });
  });

  group('the leader Home card', () {
    testWidgets('leaders see Needs attention; Open coverage', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.home,
        memberHome: true,
        setUp: (h) {
          h.grants.myAccess = AccessReadOk(
            syntheticGrants(
              scopes: const [
                ScopeGrant(scopeKind: 'department_leader', scopeId: _dept),
              ],
            ),
          );
          h.coverage.coverage = coverage([
            {
              ...fullDepartment(),
              'counts': counts(
                required: 6,
                confirmed: 2,
                unfilled: 1,
                overdue: 2,
                declined: 1,
                needsContact: 3,
                conflicts: 1,
                overdueFollowUps: 1,
              ),
            },
          ]);
        },
      );
      expect(byKey('home-attention-card'), findsOneWidget);
      expect(
        tester.getSemantics(byKey('home-attention-overdue')).label,
        isNotEmpty,
      );
      expect(
        find.text('This week: 2 of 6 positions confirmed.'),
        findsOneWidget,
      );
      expect(byKey('home-attention-conflicts'), findsOneWidget);
      expect(byKey('home-attention-follow-ups'), findsOneWidget);
      await tapKey(tester, 'home-attention-open');
      expect(byKey('coverage-counts-$_dept'), findsOneWidget);
    });

    testWidgets('members without a department scope see no card', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.home,
        memberHome: true,
        setUp: (h) {
          h.grants.myAccess = AccessReadOk(syntheticGrants());
          h.coverage.coverage = coverage([fullDepartment()]);
        },
      );
      expect(byKey('home-attention-card'), findsNothing);
      expect(h.coverage.queries, isEmpty);
    });
  });
}
