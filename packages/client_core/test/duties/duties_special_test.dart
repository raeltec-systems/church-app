// Special assignments (owner decision 2026-10-21): wire mapping (the owner
// kind, the due date, the Pastors' read, the give and change payloads, the
// calendar entry, the history kind), My duties on the phone (a due date reads
// "Due 30 Nov", never a time; the member answers to the Pastor), the Pastors'
// staff screen (what needs them first, giving, changing, cancelling,
// Confirmed by the Pastor, recording an outcome) and the history filter.
// Fakes only; the server behaviour is covered by
// supabase/tests/duties_special_assignments_test.sql. CI also runs this file
// with TZ=America/New_York (church time is Africa/Lusaka whatever the zone).
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _ruth = '66666666-6666-4666-8666-666666666666';
const _omar = '88888888-8888-4888-8888-888888888888';
const _occ = '61616161-6161-4161-8161-616161616161';
const _occ2 = '71717171-7171-4171-8171-717171717171';
const _occ3 = '72727272-7272-4272-8272-727272727272';
const _asg = '63636363-6363-4363-8363-636363636363';
const _mine = '42424242-4242-4242-8242-424242424242';

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? setUp,
  bool phone = false,
  double width = 1200,
}) async {
  tester.view.physicalSize = Size(width, 6000);
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
        theme: phone ? churchMobileTheme(Brightness.light) : churchStaffTheme(),
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

Future<void> enter(WidgetTester tester, String key, String text) async {
  await tester.ensureVisible(byKey(key));
  await tester.enterText(byKey(key), text);
  await tester.pump();
}

bool enabled(WidgetTester tester, String key) {
  final w = tester.widget(byKey(key));
  return switch (w) {
    ButtonStyleButton b => b.onPressed != null,
    _ => throw StateError('not a button: $key'),
  };
}

String statusOf(WidgetTester tester, String key) =>
    (tester.widget(byKey(key)) as StatusLabel).label;

/// A special assignment in My duties: a due date (30 Nov 2099) unless
/// [dueOn] is null.
Map<String, Object?> mySpecial({
  String? dueOn = '2099-11-30',
  String response = 'pending',
  String? respondedAt,
}) => myDutyData(
  assignmentId: _mine,
  ownerKind: 'special',
  dutyName: 'SYNTHETIC Prepare the Christmas programme',
  startsAt: dueOn == null
      ? '2099-11-29T08:00:00.000000Z'
      : '${dueOn}T16:00:00.000000Z',
  endsAt: dueOn == null ? '2099-11-29T10:00:00.000000Z' : null,
  responseDeadline: '2099-11-28T16:00:00.000000Z',
  response: response,
  respondedAt: respondedAt,
  location: null,
  leaders: const [
    {'display_name': 'SYNTHETIC Pastor Banda', 'role': 'pastor'},
  ],
  extra: {
    'due_on': dueOn,
    'deadline_source': 'default',
    'short_notice': false,
    'reminders': null,
  },
);

AccessRead<SpecialAssignments> specialRead(List<Map<String, Object?>> items) =>
    AccessReadOk(
      SpecialAssignments.fromJson({
        'assignments': items,
        'truncated': false,
        'members': [
          {
            'member_id': _ruth,
            'display_name': 'SYNTHETIC Ruth Mwale',
            'account': 'app_account',
          },
          {
            'member_id': _omar,
            'display_name': 'SYNTHETIC Omar Phiri',
            'account': 'no_login',
          },
        ],
        'members_truncated': false,
      }),
    );

void main() {
  group('wire mapping and pure rules', () {
    test('a special assignment in My duties: no department, a due date', () {
      final d = MyDuty.fromJson(mySpecial());
      expect(d.ownerKind, DutyOwnerKind.special);
      expect(d.departmentId, isNull);
      expect(d.cellId, isNull);
      expect(d.ownerLabel, 'Special assignment');
      expect(d.answerable, isTrue);
      expect(d.answersTo, 'the Pastor');
      expect(d.times.isDue, isTrue);
      expect(d.times.dueOn, DateTime.utc(2099, 11, 30));
      expect(d.leaders.single.roleLabel, 'Pastor');
      expect(d.needsResponse(DateTime.utc(2099, 11, 1)), isTrue);
      // Past its due moment (18:00 church time on the due date) it has
      // started: no answer any more.
      expect(d.needsResponse(DateTime.utc(2099, 11, 30, 16, 1)), isFalse);
      expect(
        () => MyDuty.fromJson({...mySpecial(), 'due_on': '2099-02-30'}),
        throwsFormatException,
      );
      expect(MyDuty.fromJson(mySpecial(dueOn: null)).times.isDue, isFalse);
    });

    test('due dates read "Due 30 Nov"; a typed date parses strictly', () {
      expect(DutySpecial.dueText(DateTime.utc(2099, 11, 30)), 'Due 30 Nov');
      expect(DutySpecial.parseDate('2099-11-30'), DateTime.utc(2099, 11, 30));
      expect(DutySpecial.parseDate('2099-02-30'), isNull);
      expect(DutySpecial.parseDate('30/11/2099'), isNull);
      expect(
        DutySpecial.dueMoment(DateTime.utc(2099, 11, 30)),
        DateTime.utc(2099, 11, 30, 16),
      );
    });

    test('the Pastors\' read parses strictly', () {
      final v = (specialRead([
        specialAssignmentData(dueOn: '2099-11-30'),
        specialAssignmentData(
          occurrenceId: _occ2,
          assignment: null,
          vacancy: {
            'reason': 'member_inactive',
            'since': '2099-01-01T08:00:00.000000Z',
          },
        ),
      ]) as AccessReadOk<SpecialAssignments>).value;
      expect(v.assignments.first.isDue, isTrue);
      expect(v.assignments.first.holder!.name, 'SYNTHETIC Ruth Mwale');
      expect(v.assignments.last.holder, isNull);
      expect(v.assignments.last.needsSomeone, isTrue);
      expect(v.assignments.last.vacancy!.reason, 'member_inactive');
      expect(v.members.map((m) => m.account), [
        AccountStanding.appAccount,
        AccountStanding.noLogin,
      ]);
      expect(
        () => SpecialAssignment.fromJson({
          ...specialAssignmentData(dueOn: '2099-11-30'),
          'timing': 'time',
        }),
        throwsFormatException,
      );
    });

    test('a give sends a fixed time or a due date, never both', () {
      final due = SpecialDraft(
        memberId: _ruth,
        dutyName: ' SYNTHETIC  Report ',
        timing: SpecialTiming.due,
        dueOn: DateTime.utc(2099, 11, 30),
        instructions: '  ',
      ).toPayload();
      expect(due, {
        'member_id': _ruth,
        'duty_name': 'SYNTHETIC Report',
        'due_on': '2099-11-30',
      });
      final time = SpecialDraft(
        memberId: _ruth,
        dutyName: 'SYNTHETIC Lead',
        timing: SpecialTiming.time,
        startsAt: DateTime.utc(2099, 1, 4, 8),
        endsAt: DateTime.utc(2099, 1, 4, 10),
        location: 'SYNTHETIC Chapel',
        overrideReason: 'SYNTHETIC agreed',
      ).toPayload();
      expect(time, {
        'member_id': _ruth,
        'duty_name': 'SYNTHETIC Lead',
        'starts_at': '2099-01-04T08:00:00.000Z',
        'ends_at': '2099-01-04T10:00:00.000Z',
        'location': 'SYNTHETIC Chapel',
        'override_reason': 'SYNTHETIC agreed',
      });
    });

    test('a change sends what changed; the timing whole', () {
      final item = SpecialAssignment.fromJson(
        specialAssignmentData(dueOn: '2099-11-30', instructions: 'Old'),
      );
      SpecialEdit edit({
        String? dutyName,
        SpecialTiming timing = SpecialTiming.due,
        DateTime? dueOn,
        DateTime? startsAt,
        String? instructions = 'Old',
        String? memberId,
      }) => SpecialEdit(
        item: item,
        dutyName: dutyName ?? item.dutyName,
        timing: timing,
        dueOn: dueOn ?? DateTime.utc(2099, 11, 30),
        startsAt: startsAt,
        location: item.location,
        instructions: instructions,
        memberId: memberId,
      );
      expect(edit().changed, isEmpty);
      final moved = edit(dueOn: DateTime.utc(2099, 12, 15));
      expect(moved.material, isTrue);
      expect(moved.toPayload(), {
        'occurrence_id': _occ,
        'due_on': '2099-12-15',
      });
      final notes = edit(instructions: 'New');
      expect(notes.material, isFalse);
      expect(notes.toPayload(), {'occurrence_id': _occ, 'instructions': 'New'});
      final switched = edit(
        timing: SpecialTiming.time,
        startsAt: DateTime.utc(2099, 11, 29, 8),
      );
      expect(switched.toPayload(), {
        'occurrence_id': _occ,
        'starts_at': '2099-11-29T08:00:00.000Z',
        'ends_at': null,
      });
      expect(edit(memberId: _omar).toPayload(), {
        'occurrence_id': _occ,
        'member_id': _omar,
      });
    });

    test('an overlap with a special assignment and the Pastor\'s check', () {
      final c = DutyConflict.fromJson({
        'visibility': 'limited',
        'owner_kind': 'special',
        'from': '2099-01-04T08:00:00.000000Z',
        'to': '2099-01-04T10:00:00.000000Z',
      });
      expect(c.isSpecial, isTrue);
      expect(c.ownerLabel, 'Special assignment');
      expect(
        CandidateQuery.special(startsAt: DateTime.utc(2099, 1, 4, 8))
            .toParams(),
        {'starts_at': '2099-01-04T08:00:00.000Z'},
      );
      final read = DutyCandidates.fromJson({
        'department_id': null,
        'slot_id': null,
        'window': {
          'from': '2099-01-04T08:00:00.000000Z',
          'to': '2099-01-04T10:00:00.000000Z',
        },
        'candidates': [],
      });
      expect(read.departmentId, isNull);
    });

    test('a due date is an all-day calendar entry on its date', () {
      final ics = DutyCalendar.ics(
        MyDuty.fromJson(mySpecial()),
        now: DateTime.utc(2099, 1, 1),
      );
      expect(ics, contains('DTSTART;VALUE=DATE:20991130'));
      expect(ics, contains('DTEND;VALUE=DATE:20991201'));
      expect(ics, contains('SUMMARY:Due: SYNTHETIC Prepare the Christmas'));
      expect(ics, contains('Special assignment\\, due 30 nov.'));
      expect(
        DutyCalendar.fileName(MyDuty.fromJson(mySpecial())),
        'duty-2099-11-30.ics',
      );
    });

    test('history: the special kind, its count and its owner', () {
      final h = MemberHistory.fromJson({
        'member': {'member_id': _ruth, 'display_name': 'SYNTHETIC Ruth'},
        'self': true,
        'kinds': {'department': 2, 'cell': 0, 'special': 3},
        'departments': [],
        'summary': {
          'held': 1,
          'accepted': 1,
          'confirmed_by_leader': 0,
          'declined': 0,
          'unanswered': 0,
          'completed': 1,
          'excused': 0,
          'no_show': 0,
          'unrecorded': 0,
          'ended': 0,
        },
        'upcoming': 0,
        'entries': [
          {
            'assignment_id': _asg,
            'occurrence_id': _occ,
            'owner_kind': 'special',
            'department_id': null,
            'department_name': null,
            'duty_name': 'SYNTHETIC Report',
            'starts_at': '2099-11-30T16:00:00.000000Z',
            'reporting_at': null,
            'due_on': '2099-11-30',
            'started': true,
            'state': 'current',
            'response': 'accepted',
            'response_provenance': 'leader',
            'responded_at': '2099-11-01T08:00:00.000000Z',
            'outcome_state': 'unrecorded',
            'outcome': null,
          },
        ],
        'has_more': false,
      });
      expect(h.specialCount, 3);
      expect(h.kindsPresent, 2);
      expect(h.allCount, 5);
      expect(h.entries.single.ownerName, 'Special assignment');
      expect(h.entries.single.stateLabel, 'Confirmed by the Pastor');
      expect(h.entries.single.times.dueOn, DateTime.utc(2099, 11, 30));
      expect(const HistoryQuery().ofKind(DutyOwnerKind.special).toParams(), {
        'kind': 'special',
      });
    });
  });

  group('My duties (mobile)', () {
    testWidgets('a due date reads "Due 30 Nov" on the row and the duty', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.myDuties,
        phone: true,
        setUp: (h) => h.duties.mine = AccessReadOk(
          MyDuties.fromJson({
            'member_id': _ruth,
            'assignments': [mySpecial()],
          }),
        ),
      );
      expect(find.text('Special assignment · Due 30 Nov'), findsOneWidget);
      await tapKey(tester, 'duty-accept-$_mine');
      final sent = h.gateway.sent.single;
      expect(sent.request.command, 'duties.respond');
      sent.confirm({'response': 'accepted'}, 2);
      await settle(tester);
      expect(byKey('duties-notice-accepted'), findsOneWidget);
      expect(find.textContaining('The Pastor now sees it'), findsOneWidget);
    });

    testWidgets('the duty shows its due date, the Pastor and the note label', (
      tester,
    ) async {
      await pumpAt(
        tester,
        DutyPaths.assignment(_mine),
        phone: true,
        setUp: (h) => h.duties.mine = AccessReadOk(
          MyDuties.fromJson({
            'member_id': _ruth,
            'assignments': [mySpecial()],
          }),
        ),
      );
      expect(find.text('Due'), findsOneWidget);
      expect(find.text('Time'), findsNothing);
      expect(find.text('Pastor'), findsOneWidget);
      expect(find.text('Note for the Pastor (optional)'), findsOneWidget);
      expect(find.textContaining('24 hours before it is due'), findsOneWidget);
      await tapKey(tester, 'duty-decline-$_mine');
      expect(find.textContaining('The Pastor sees at once'), findsOneWidget);
    });
  });

  testWidgets('at phone width (390 px) the row and the duty fit', (
    tester,
  ) async {
    for (final location in [
      ClientPaths.myDuties,
      DutyPaths.assignment(_mine),
    ]) {
      await pumpAt(
        tester,
        location,
        phone: true,
        width: 390,
        setUp: (h) => h.duties.mine = AccessReadOk(
          MyDuties.fromJson({
            'member_id': _ruth,
            'assignments': [mySpecial(), mySpecial(dueOn: null)],
          }),
        ),
      );
      expect(tester.takeException(), isNull, reason: location);
    }
  });

  group('the Pastors\' screen (staff web)', () {
    final past = specialAssignmentData(
      occurrenceId: _occ3,
      dutyName: 'SYNTHETIC Visit the sick',
      started: true,
      assignment: {
        'revision': 3,
        'response': 'accepted',
        'response_provenance': 'member',
        'responded_at': '2099-01-01T08:00:00.000000Z',
        'allowed': ['completed', 'excused', 'no_show'],
      },
    );

    testWidgets('what needs the Pastor comes first, with its one action', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutySpecial,
        setUp: (h) => h.special.special = specialRead([
          specialAssignmentData(dueOn: '2099-11-30'),
          specialAssignmentData(
            occurrenceId: _occ2,
            dutyName: 'SYNTHETIC Count the offering',
            assignment: null,
            vacancy: {
              'reason': 'member_inactive',
              'since': '2099-01-01T08:00:00.000000Z',
            },
          ),
          past,
        ]),
      );
      expect(h.special.reads, greaterThan(0));
      expect(byKey('special-needs'), findsOneWidget);
      expect(byKey('special-upcoming'), findsOneWidget);
      expect(
        find.textContaining('1 to record'),
        findsOneWidget,
        reason: 'the finding under the title',
      );
      // One mark per row; the due date reads as a date, never a time.
      expect(statusOf(tester, 'special-mark-$_occ'), 'Awaiting answer');
      expect(
        (tester.widget(byKey('special-sub-$_occ')) as Text).data,
        'SYNTHETIC Ruth Mwale · Due 30 Nov',
      );
      expect(statusOf(tester, 'special-mark-$_occ2'), 'Needs someone');
      expect(statusOf(tester, 'special-mark-$_occ3'), 'Not recorded');
      expect(byKey('special-reassign-$_occ2'), findsOneWidget);
      // Record the past one's outcome straight from its row.
      await tapKey(tester, 'special-record-$_occ3');
      await tapKey(tester, 'special-choice-$_occ3-completed');
      await tapKey(tester, 'special-outcome-save-$_occ3');
      final sent = h.gateway.sent.single;
      expect(sent.request.command, 'duties.record_outcome');
      expect(sent.request.expectedRevision.value, 3);
      expect(sent.request.payload, {
        'assignment_id': _asg,
        'outcome': 'completed',
      });
      sent.confirm({'outcome': 'completed', 'outcome_revision': 1}, 4);
      await settle(tester);
      expect(byKey('duties-notice-outcomeRecorded'), findsOneWidget);
      expect(find.textContaining('the Pastors'), findsWidgets);
    });

    testWidgets('give a special assignment with a due date', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutySpecial,
        setUp: (h) => h.special.special = specialRead([]),
      );
      expect(find.textContaining('No special assignments'), findsWidgets);
      await tapKey(tester, 'special-give');
      await enter(tester, 'special-new-name', 'SYNTHETIC Write the report');
      await tapKey(tester, 'special-new-timing');
      await tester.tap(find.text('Done by a date'));
      await settle(tester);
      await enter(tester, 'special-new-due', '2099-11-30');
      expect(enabled(tester, 'special-new-save'), isFalse);
      await tapKey(tester, 'special-new-member');
      await tester.tap(find.text('SYNTHETIC Ruth Mwale').last);
      await settle(tester);
      expect(enabled(tester, 'special-new-save'), isTrue);
      await tapKey(tester, 'special-new-save');
      final sent = h.gateway.sent.single;
      expect(sent.request.command, 'duties.give_special');
      expect(sent.request.expectedRevision.value, isNull);
      expect(sent.request.payload, {
        'member_id': _ruth,
        'duty_name': 'SYNTHETIC Write the report',
        'due_on': '2099-11-30',
      });
      sent.confirm({'occurrence_id': _occ, 'timing': 'due'}, 1);
      await settle(tester);
      expect(byKey('duties-notice-specialGiven'), findsOneWidget);
      expect(byKey('special-give-form'), findsNothing);
    });

    testWidgets('a Pastor cannot give one to themselves (explained)', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutySpecial,
        setUp: (h) => h.special.special = specialRead([]),
      );
      await tapKey(tester, 'special-give');
      await enter(tester, 'special-new-name', 'SYNTHETIC Self');
      await enter(tester, 'special-new-date', '2099-01-04');
      await enter(tester, 'special-new-start', '10:00');
      await tapKey(tester, 'special-new-member');
      await tester.tap(find.text('SYNTHETIC Ruth Mwale').last);
      await settle(tester);
      await tapKey(tester, 'special-new-save');
      final sent = h.gateway.sent.single;
      expect(sent.request.payload['starts_at'], '2099-01-04T08:00:00.000Z');
      sent.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'member_id': 'own'},
      );
      await settle(tester);
      expect(byKey('duties-notice-specialOwn'), findsOneWidget);
    });

    testWidgets('change a due date, then cancel', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutySpecial,
        setUp: (h) => h.special.special = specialRead([
          specialAssignmentData(dueOn: '2099-11-30', revision: 4),
        ]),
      );
      await tapKey(tester, 'special-open-$_occ');
      await tapKey(tester, 'special-change-$_occ');
      await enter(tester, 'special-$_occ-due', '2099-12-15');
      await tapKey(tester, 'special-$_occ-save');
      final sent = h.gateway.sent.single;
      expect(sent.request.command, 'duties.revise_special');
      expect(sent.request.expectedRevision.value, 4);
      expect(sent.request.payload, {
        'occurrence_id': _occ,
        'due_on': '2099-12-15',
      });
      sent.confirm({'change': 'material'}, 5);
      await settle(tester);
      expect(byKey('duties-notice-revised'), findsOneWidget);
      await tapKey(tester, 'special-cancel-$_occ');
      await tapKey(tester, 'special-cancel-yes');
      final cancel = h.gateway.sent.last;
      expect(cancel.request.command, 'duties.cancel_special');
      expect(cancel.request.payload, {'occurrence_id': _occ});
    });

    testWidgets('Confirmed by the Pastor for a member reached by phone', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutySpecial,
        setUp: (h) => h.special.special = specialRead([
          specialAssignmentData(
            assignment: {'account': 'no_login', 'revision': 2},
          ),
        ]),
      );
      await tapKey(tester, 'special-open-$_occ');
      expect(find.textContaining('has no login'), findsOneWidget);
      await tapKey(tester, 'special-confirm-$_occ');
      expect(enabled(tester, 'special-confirm-save-$_occ'), isFalse);
      await enter(
        tester,
        'special-confirm-reason-$_occ',
        'SYNTHETIC said yes after the service',
      );
      await tapKey(tester, 'special-confirm-save-$_occ');
      final sent = h.gateway.sent.single;
      expect(sent.request.command, 'duties.confirm_by_leader');
      expect(sent.request.expectedRevision.value, 2);
      expect(sent.request.payload, {
        'assignment_id': _asg,
        'channel': 'phone',
        'reason': 'SYNTHETIC said yes after the service',
      });
      sent.confirm({'response': 'accepted', 'provenance': 'leader'}, 3);
      await settle(tester);
      expect(find.text('Confirmed by the Pastor'), findsWidgets);
    });

    testWidgets('anyone but a Pastor is refused by the server', (tester) async {
      await pumpAt(tester, ClientPaths.dutySpecial);
      expect(byKey('duties-denied-notGranted'), findsOneWidget);
      expect(find.textContaining('given by the Pastors'), findsOneWidget);
    });
  });

  group('My duty history', () {
    testWidgets('the Special filter is offered with another kind', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyHistory,
        phone: true,
        setUp: (h) => h.outcomes.history = AccessReadOk(
          MemberHistory.fromJson({
            'member': {'member_id': _ruth, 'display_name': 'SYNTHETIC Ruth'},
            'self': true,
            'kinds': {'department': 1, 'cell': 0, 'special': 1},
            'departments': [],
            'summary': {
              'held': 1,
              'accepted': 1,
              'confirmed_by_leader': 0,
              'declined': 0,
              'unanswered': 0,
              'completed': 0,
              'excused': 0,
              'no_show': 0,
              'unrecorded': 1,
              'ended': 0,
            },
            'upcoming': 0,
            'entries': [
              {
                'assignment_id': _asg,
                'occurrence_id': _occ,
                'owner_kind': 'special',
                'department_id': null,
                'department_name': null,
                'duty_name': 'SYNTHETIC Report',
                'starts_at': '2099-11-30T16:00:00.000000Z',
                'reporting_at': null,
                'due_on': '2099-11-30',
                'started': true,
                'state': 'current',
                'response': 'accepted',
                'response_provenance': 'member',
                'responded_at': '2099-11-01T08:00:00.000000Z',
                'outcome_state': 'unrecorded',
                'outcome': null,
              },
            ],
            'has_more': false,
          }),
        ),
      );
      expect(find.text('Special (1)'), findsOneWidget);
      expect(find.text('Cell (0)'), findsNothing);
      expect(
        find.text('Special assignment · Due 30 Nov · Accepted'),
        findsOneWidget,
      );
      expect(find.textContaining('given by the Pastors'), findsOneWidget);
      await tester.tap(find.text('Special (1)'));
      await settle(tester);
      expect(h.outcomes.historyQueries.last.kind, DutyOwnerKind.special);
    });
  });
}
