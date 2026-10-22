// Story 4.10: completion outcomes and assignment history (wire mapping, the
// leader's Outcomes screen: Not recorded shown as such, the response kept
// apart, No-show only for an accepted duty, recording and correcting with a
// reason and the kept earlier values, no action on the leader's own duty;
// the history screen for the member and for a leader, paging; My duties
// showing the member's own outcome). Fakes only; the server behaviour is
// covered by supabase/tests/duties_outcomes_test.sql and
// tools/identity-e2e/duties-outcomes.mjs. CI also runs this file with
// TZ=America/New_York (church time is Africa/Lusaka whatever the device zone).
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _dept = '44444444-4444-4444-8444-444444444444';
const _occ = '43434343-4343-4343-8343-434343434343';
const _slotA = '45454545-4545-4545-8545-454545454545';
const _slotB = '46464646-4646-4646-8646-464646464646';
const _slotL = '47474747-4747-4747-8747-474747474747';
const _asgA = '42424242-4242-4242-8242-424242424242';
const _asgB = '48484848-4848-4848-8848-484848484848';
const _asgL = '41414141-4141-4141-8141-414141414141';
const _ruth = '66666666-6666-4666-8666-666666666666';
const _omar = '88888888-8888-4888-8888-888888888888';
const _lydia = '99999999-9999-4999-8999-999999999999';

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? setUp,
  bool phone = false,
  double width = 1200,
}) async {
  tester.view.physicalSize = Size(width, 9000);
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

bool enabled(WidgetTester tester, String key) {
  final w = tester.widget(byKey(key));
  return switch (w) {
    ButtonStyleButton b => b.onPressed != null,
    _ => throw StateError('not a button: $key'),
  };
}

String? textOf(WidgetTester tester, String key) =>
    (tester.widget(byKey(key)) as Text).data;

Future<void> enter(WidgetTester tester, String key, String text) async {
  await tester.ensureVisible(byKey(key));
  await tester.enterText(byKey(key), text);
  await tester.pump();
}

Map<String, Object?> trailItem(
  int revision,
  String outcome, {
  String? note,
  String? reason,
  String by = 'SYNTHETIC Leader',
  String at = '2026-10-12T10:00:00.000000Z',
}) => {
  'revision': revision,
  'outcome': outcome,
  'note': note,
  'reason': reason,
  'by': by,
  'at': at,
};

Map<String, Object?> outcomeJson(List<Map<String, Object?>> trail) => {
  'outcome': trail.first['outcome'],
  'revision': trail.first['revision'],
  'note': trail.first['note'],
  'recorded_at': trail.first['at'],
  'recorded_by': trail.first['by'],
  'corrected': (trail.first['revision'] as int) > 1,
  'trail': trail,
};

Map<String, Object?> position({
  required String slot,
  required String asg,
  required String member,
  required String name,
  String response = 'accepted',
  String? provenance = 'member',
  bool own = false,
  Map<String, Object?>? outcome,
}) => {
  'slot_id': slot,
  'position_no': 1,
  'position_name': 'Preacher',
  'occurrence_id': _occ,
  'duty_name': 'Sunday service',
  'starts_at': '2026-10-11T08:00:00.000000Z',
  'ends_at': null,
  'reporting_at': null,
  'location': 'SYNTHETIC Main hall',
  'assignment': {
    'assignment_id': asg,
    'revision': 2,
    'member_id': member,
    'display_name': name,
    'own': own,
    'response': response,
    'response_provenance': response == 'pending' ? null : provenance,
    'responded_at': response == 'pending'
        ? null
        : '2026-10-05T09:00:00.000000Z',
    'outcome_state': outcome == null ? 'unrecorded' : outcome['outcome'],
    'outcome': outcome,
    'allowed': response == 'accepted'
        ? ['completed', 'excused', 'no_show']
        : ['completed', 'excused'],
  },
};

AccessRead<DutyOutcomes> outcomes(List<Map<String, Object?>> positions) =>
    AccessReadOk(
      DutyOutcomes.fromJson({
        'window': {
          'from': '2026-10-01',
          'to': '2026-10-14',
          'zone': 'Africa/Lusaka',
        },
        'duty': null,
        'truncated': false,
        'departments': [
          {
            'department_id': _dept,
            'name': 'SYNTHETIC Preaching Rota',
            'capacity': 'department_leader',
            'counts': {
              'positions': positions.length,
              'unfilled': 0,
              'unrecorded': 1,
              'completed': 0,
              'excused': 0,
              'no_show': 1,
            },
            'positions': positions,
          },
        ],
      }),
    );

List<Map<String, Object?>> standardPositions() => [
  position(slot: _slotA, asg: _asgA, member: _ruth, name: 'SYNTHETIC Ruth'),
  position(
    slot: _slotB,
    asg: _asgB,
    member: _omar,
    name: 'SYNTHETIC Omar',
    response: 'accepted',
    outcome: outcomeJson([
      trailItem(
        2,
        'no_show',
        note: 'SYNTHETIC: did not come',
        reason: 'SYNTHETIC: checked the sign-in sheet',
        by: 'SYNTHETIC Deputy',
        at: '2026-10-13T10:00:00.000000Z',
      ),
      trailItem(1, 'completed', note: 'SYNTHETIC: first note'),
    ]),
  ),
  position(
    slot: _slotL,
    asg: _asgL,
    member: _lydia,
    name: 'SYNTHETIC Lydia',
    own: true,
  ),
];

Map<String, Object?> historyJson({
  bool self = true,
  bool hasMore = false,
  List<Map<String, Object?>>? entries,
  Map<String, Object?>? kinds,
}) => {
  'member': {'member_id': _ruth, 'display_name': 'SYNTHETIC Ruth'},
  'self': self,
  'kinds': ?kinds,
  'departments': [
    {'department_id': _dept, 'name': 'SYNTHETIC Preaching Rota'},
  ],
  'summary': {
    'since': '2025-10-14T00:00:00Z',
    'held': 3,
    'accepted': 2,
    'confirmed_by_leader': 1,
    'declined': 0,
    'unanswered': 0,
    'completed': 1,
    'excused': 0,
    'no_show': 1,
    'unrecorded': 1,
    'ended': 1,
  },
  'upcoming': 2,
  'entries':
      entries ??
      [
        {
          'assignment_id': _asgA,
          'occurrence_id': _occ,
          'department_id': _dept,
          'department_name': 'SYNTHETIC Preaching Rota',
          'duty_name': 'Sunday service',
          'position_name': null,
          'starts_at': '2026-10-11T08:00:00.000000Z',
          'reporting_at': null,
          'started': true,
          'state': 'current',
          'response': 'accepted',
          'response_provenance': 'member',
          'responded_at': '2026-10-05T09:00:00.000000Z',
          'outcome_state': 'no_show',
          'outcome': outcomeJson([
            trailItem(2, 'no_show', reason: 'SYNTHETIC: sheet'),
            trailItem(1, 'completed', note: 'SYNTHETIC: first'),
          ]),
        },
        {
          'assignment_id': _asgB,
          'occurrence_id': _occ,
          'department_id': _dept,
          'department_name': 'SYNTHETIC Preaching Rota',
          'duty_name': 'Prayer meeting',
          'position_name': null,
          'starts_at': '2026-10-04T08:00:00.000000Z',
          'reporting_at': null,
          'started': true,
          'state': 'current',
          'response': 'pending',
          'response_provenance': null,
          'responded_at': null,
          'outcome_state': 'unrecorded',
          'outcome': null,
        },
        {
          'assignment_id': _asgL,
          'occurrence_id': _occ,
          'department_id': _dept,
          'department_name': 'SYNTHETIC Preaching Rota',
          'duty_name': 'Cleaning',
          'position_name': null,
          'starts_at': '2026-09-27T08:00:00.000000Z',
          'reporting_at': null,
          'started': true,
          'state': 'cancelled',
          'response': 'accepted',
          'response_provenance': 'member',
          'responded_at': '2026-09-20T09:00:00.000000Z',
          'outcome_state': 'none',
          'outcome': null,
        },
      ],
  'has_more': hasMore,
};

void main() {
  group('wire mapping', () {
    test('an unrecorded position has no outcome; a recorded one its trail', () {
      final v =
          (outcomes(standardPositions()) as AccessReadOk<DutyOutcomes>).value;
      final ps = v.departments.single.positions;
      expect(ps[0].assignment!.state, OutcomeState.unrecorded);
      expect(ps[0].assignment!.outcome, isNull);
      final o = ps[1].assignment!.outcome!;
      expect(o.outcome, DutyOutcome.noShow);
      expect(o.corrected, isTrue);
      expect(o.earlier.single.outcome, DutyOutcome.completed);
      expect(o.earlier.single.note, 'SYNTHETIC: first note');
      expect(ps[2].assignment!.own, isTrue);
    });

    test('a state that disagrees with the outcome is refused', () {
      final bad = position(slot: _slotA, asg: _asgA, member: _ruth, name: 'R');
      (bad['assignment'] as Map)['outcome_state'] = 'completed';
      expect(() => OutcomePosition.fromJson(bad), throwsFormatException);
    });

    test('queries and drafts', () {
      // Review S2: the window never reaches past today (church date).
      final now = DateTime.utc(
        2026,
        10,
        14,
        23,
        30,
      ); // 01:30 on 15 Oct in Lusaka
      expect(const OutcomesQuery().toParams(now: now), {
        'from_date': '2026-10-02',
        'to_date': '2026-10-15',
      });
      expect(const OutcomesQuery(days: 31).toParams(now: now), {
        'from_date': '2026-09-15',
        'to_date': '2026-10-15',
      });
      expect(
        const OutcomesQuery(
          from: '2026-10-01',
          days: 31,
          duty: ' Sun ',
        ).toParams(now: now),
        {'from_date': '2026-10-01', 'to_date': '2026-10-15', 'duty': 'Sun'},
      );
      expect(
        const OutcomesQuery(from: '2026-09-01', days: 7).toParams(now: now),
        {'from_date': '2026-09-01', 'to_date': '2026-09-07'},
      );
      expect(OutcomesQuery.afterToday('2026-10-16', now), isTrue);
      expect(OutcomesQuery.afterToday('2026-10-15', now), isFalse);
      final c = HistoryCursor(DateTime.utc(2026, 10, 4, 8), _asgB);
      expect(const HistoryQuery(memberId: _ruth).older(c).toParams(), {
        'member_id': _ruth,
        'before_at': '2026-10-04T08:00:00.000Z',
        'before_id': _asgB,
      });
      expect(const HistoryQuery().older(c).newer().toParams(), isEmpty);
      const d = OutcomeDraft(outcome: DutyOutcome.noShow, note: '  ');
      expect(d.errors(correction: true), {'reason': 'required'});
      expect(
        d.errors(
          correction: false,
          allowed: const [DutyOutcome.completed, DutyOutcome.excused],
        ),
        {'outcome': 'not_accepted'},
      );
      expect(d.toPayload(_asgA, correction: false), {
        'assignment_id': _asgA,
        'outcome': 'no_show',
      });
      expect(
        const OutcomeDraft(
          outcome: DutyOutcome.excused,
          note: 'SYNTHETIC: ill',
          reason: 'SYNTHETIC: told us',
        ).toPayload(_asgA, correction: true),
        {
          'assignment_id': _asgA,
          'outcome': 'excused',
          'note': 'SYNTHETIC: ill',
          'reason': 'SYNTHETIC: told us',
        },
      );
    });
  });

  group('the Outcomes screen', () {
    testWidgets('shows Not recorded, the answer apart and the trail', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.dutyOutcomes,
        setUp: (h) => h.outcomes.outcomes = outcomes(standardPositions()),
      );
      expect(byKey('outcomes-state-$_slotA'), findsOneWidget);
      expect(find.text('Not recorded'), findsWidgets);
      // The answer has its own column, apart from the outcome.
      expect(textOf(tester, 'outcomes-response-$_slotA'), 'Accepted');
      expect(
        (tester.widget(
          byKey('outcomes-outcome-$_slotB-label'),
        ) as StatusLabel).label,
        'No-show',
      );
      expect(find.textContaining('Earlier: Completed'), findsOneWidget);
      expect(
        find.textContaining('SYNTHETIC: checked the sign-in sheet'),
        findsOneWidget,
      );
      // The leader's own duty: nothing to record, explained.
      expect(byKey('outcomes-record-$_slotL'), findsNothing);
      expect(byKey('outcomes-correct-$_slotL'), findsNothing);
      expect(find.textContaining('another leader or deputy'), findsOneWidget);
    });

    testWidgets('record an outcome (nothing shown until the server answers)', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyOutcomes,
        setUp: (h) => h.outcomes.outcomes = outcomes(standardPositions()),
      );
      await tapKey(tester, 'outcomes-record-$_slotA');
      expect(enabled(tester, 'outcomes-save-$_slotA'), isFalse);
      await tapKey(tester, 'outcomes-choice-$_slotA-completed');
      await enter(tester, 'outcomes-note-$_slotA', 'SYNTHETIC: on time');
      await tapKey(tester, 'outcomes-save-$_slotA');
      final sent = h.gateway.sent.single;
      expect(sent.request.command, 'duties.record_outcome');
      expect(sent.request.expectedRevision.value, 2);
      expect(sent.request.payload, {
        'assignment_id': _asgA,
        'outcome': 'completed',
        'note': 'SYNTHETIC: on time',
      });
      expect(byKey('duties-pending'), findsOneWidget);
      sent.confirm({'outcome': 'completed', 'outcome_revision': 1}, 5);
      await settle(tester);
      expect(byKey('duties-notice-outcomeRecorded'), findsOneWidget);
      expect(byKey('outcomes-form-$_slotA'), findsNothing);
    });

    testWidgets('a declined duty offers no No-show; a refusal is explained', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyOutcomes,
        setUp: (h) => h.outcomes.outcomes = outcomes([
          position(
            slot: _slotA,
            asg: _asgA,
            member: _ruth,
            name: 'SYNTHETIC Ruth',
            response: 'declined',
          ),
        ]),
      );
      expect(textOf(tester, 'outcomes-response-$_slotA'), 'Declined');
      await tapKey(tester, 'outcomes-record-$_slotA');
      expect(byKey('outcomes-choice-$_slotA-no_show'), findsNothing);
      expect(byKey('outcomes-choice-$_slotA-excused'), findsOneWidget);
      await tapKey(tester, 'outcomes-choice-$_slotA-excused');
      await tapKey(tester, 'outcomes-save-$_slotA');
      h.gateway.sent.single.refuse(
        ErrorCode.conflict,
        fieldErrors: const {'assignment_id': 'recorded'},
      );
      await settle(tester);
      expect(byKey('duties-notice-outcomeAlreadyRecorded'), findsOneWidget);
    });

    testWidgets('a correction needs a reason and keeps the earlier value', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyOutcomes,
        setUp: (h) => h.outcomes.outcomes = outcomes(standardPositions()),
      );
      expect(byKey('outcomes-record-$_slotB'), findsNothing);
      await tapKey(tester, 'outcomes-correct-$_slotB');
      expect(find.textContaining('earlier value'), findsWidgets);
      await tapKey(tester, 'outcomes-choice-$_slotB-excused');
      expect(enabled(tester, 'outcomes-save-$_slotB'), isFalse);
      await enter(tester, 'outcomes-reason-$_slotB', 'SYNTHETIC: was ill');
      expect(enabled(tester, 'outcomes-save-$_slotB'), isTrue);
      await tapKey(tester, 'outcomes-save-$_slotB');
      final sent = h.gateway.sent.single;
      expect(sent.request.command, 'duties.correct_outcome');
      // Against the current outcome revision.
      expect(sent.request.expectedRevision.value, 2);
      expect(sent.request.payload, {
        'assignment_id': _asgB,
        'outcome': 'excused',
        'note': 'SYNTHETIC: did not come',
        'reason': 'SYNTHETIC: was ill',
      });
      sent.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'assignment_id': 'own'},
      );
      await settle(tester);
      expect(byKey('duties-notice-ownOutcome'), findsOneWidget);
    });

    testWidgets('the count to record leads; the Not recorded pill filters', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.dutyOutcomes,
        setUp: (h) => h.outcomes.outcomes = outcomes(standardPositions()),
      );
      // The server's count, first.
      expect(textOf(tester, 'outcomes-finding'), '1 position needs an outcome');
      expect(byKey('outcomes-card-$_slotB'), findsOneWidget);
      await tapKey(tester, 'outcomes-unrecorded-only');
      expect(byKey('outcomes-card-$_slotA'), findsOneWidget);
      expect(byKey('outcomes-card-$_slotL'), findsOneWidget);
      expect(byKey('outcomes-card-$_slotB'), findsNothing);
      await tapKey(tester, 'outcomes-filter-all');
      expect(byKey('outcomes-card-$_slotB'), findsOneWidget);
    });

    testWidgets('at phone width (390 px) each position is a two-line row', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.dutyOutcomes,
        phone: true,
        width: 390,
        setUp: (h) => h.outcomes.outcomes = outcomes(standardPositions()),
      );
      expect(tester.takeException(), isNull);
      expect(textOf(tester, 'outcomes-response-$_slotA'), 'Answer: Accepted');
      await tapKey(tester, 'outcomes-record-$_slotA');
      expect(byKey('outcomes-form-$_slotA'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a reader without a department scope sees the need', (
      tester,
    ) async {
      await pumpAt(tester, ClientPaths.dutyOutcomes);
      expect(find.textContaining('leaders and deputies'), findsWidgets);
      expect(byKey('outcomes-record-$_slotA'), findsNothing);
    });
  });

  group('review fixes', () {
    String today() {
      final d = OutcomesQuery.churchToday();
      String two(int v) => v.toString().padLeft(2, '0');
      return '${d.year}-${two(d.month)}-${two(d.day)}';
    }

    Future<void> chooseDays(WidgetTester tester, int days) async {
      await tapKey(tester, 'outcomes-days');
      await tester.tap(find.text('$days days').last);
      await settle(tester);
    }

    testWidgets('S2: 31 days from the shown From never asks past today', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyOutcomes,
        setUp: (h) => h.outcomes.outcomes = outcomes(standardPositions()),
      );
      await chooseDays(tester, 31);
      await tapKey(tester, 'outcomes-apply');
      final p = h.outcomes.queries.last.toParams();
      expect(p['from_date'], '2026-10-01');
      expect((p['to_date']! as String).compareTo(today()) <= 0, isTrue);
    });

    testWidgets('S2: with From cleared the window ends today', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyOutcomes,
        setUp: (h) => h.outcomes.outcomes = outcomes(standardPositions()),
      );
      await enter(tester, 'outcomes-from', '');
      await chooseDays(tester, 31);
      await tapKey(tester, 'outcomes-apply');
      final p = h.outcomes.queries.last.toParams();
      expect(p['to_date'], today());
      expect(h.outcomes.queries.last.from, isNull);
      await enter(tester, 'outcomes-from', '2099-01-01');
      final before = h.outcomes.queries.length;
      await tapKey(tester, 'outcomes-apply');
      expect(find.text('Must not be after today'), findsOneWidget);
      expect(h.outcomes.queries.length, before);
    });

    testWidgets('N2: nothing to record about an erased member', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyOutcomes,
        setUp: (h) => h.outcomes.outcomes = outcomes([
          position(
            slot: _slotA,
            asg: _asgA,
            member: '00000000-0000-0000-0000-000000000000',
            name: 'Removed member',
          ),
          position(
            slot: _slotB,
            asg: _asgB,
            member: _omar,
            name: 'SYNTHETIC Omar',
          ),
        ]),
      );
      expect(byKey('outcomes-record-$_slotA'), findsNothing);
      expect(byKey('outcomes-history-$_slotA'), findsNothing);
      expect(find.textContaining('record was removed'), findsOneWidget);
      // A member who left meanwhile: the refusal is explained.
      await tapKey(tester, 'outcomes-record-$_slotB');
      await tapKey(tester, 'outcomes-choice-$_slotB-completed');
      await tapKey(tester, 'outcomes-save-$_slotB');
      h.gateway.sent.single.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'member_id': 'inactive'},
      );
      await settle(tester);
      expect(byKey('duties-notice-outcomeMemberGone'), findsOneWidget);
    });

    testWidgets(
      'N4: an unknown outcome shows Not sent and Check again resends it',
      (tester) async {
        final h = await pumpAt(
          tester,
          ClientPaths.dutyOutcomes,
          setUp: (h) => h.outcomes.outcomes = outcomes(standardPositions()),
        );
        await tapKey(tester, 'outcomes-record-$_slotA');
        await tapKey(tester, 'outcomes-choice-$_slotA-excused');
        await tapKey(tester, 'outcomes-save-$_slotA');
        final first = h.gateway.sent.single;
        first.unknown();
        await settle(tester);
        expect(byKey('duties-notice-unconfirmed'), findsOneWidget);
        expect(byKey('duties-notice-outcomeRecorded'), findsNothing);
        // Nothing is shown as recorded.
        expect(byKey('outcomes-state-$_slotA'), findsOneWidget);
        await tester.tap(find.text('Check again'));
        await settle(tester);
        expect(h.gateway.sent, hasLength(2));
        final again = h.gateway.sent.last;
        expect(again.request.requestId, first.request.requestId);
        expect(again.request.payload, first.request.payload);
        again.confirm({'outcome': 'excused', 'outcome_revision': 1}, 5);
        await settle(tester);
        expect(byKey('duties-notice-outcomeRecorded'), findsOneWidget);
      },
    );

    testWidgets('N6: the paging buttons show keyboard focus', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.dutyHistory,
        setUp: (h) => h.outcomes.history = AccessReadOk(
          MemberHistory.fromJson(historyJson(hasMore: true)),
        ),
      );
      expect(
        find.ancestor(
          of: byKey('history-older'),
          matching: find.byType(FocusRing),
        ),
        findsOneWidget,
      );
      expect(byKey('history-summary'), findsOneWidget);
    });
  });

  group('the duty history', () {
    testWidgets('the member reads their own history, not a ranking', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyHistory,
        setUp: (h) => h.outcomes.history = AccessReadOk(
          MemberHistory.fromJson(historyJson(hasMore: true)),
        ),
      );
      expect(h.outcomes.historyQueries.last.memberId, isNull);
      // The member's own page has no name heading; the figures lead.
      expect(byKey('history-who'), findsNothing);
      expect(find.text('Last 12 months'), findsOneWidget);
      expect(find.textContaining('It is not a ranking'), findsOneWidget);
      String figure(String label) {
        final row = find
            .ancestor(
              of: find.descendant(
                of: byKey('history-summary'),
                matching: find.text(label),
              ),
              matching: find.byType(Row),
            )
            .first;
        return tester
            .widgetList<Text>(
              find.descendant(of: row, matching: find.byType(Text)),
            )
            .last
            .data!;
      }

      expect(figure('No-show'), '1');
      expect(figure('Not recorded yet'), '1');
      expect(find.text('Outcome: No-show'), findsOneWidget);
      expect(byKey('history-outcome-$_asgB'), findsOneWidget);
      expect(find.text('Not recorded'), findsOneWidget);
      expect(find.text('Cancelled'), findsOneWidget);
      await tapKey(tester, 'history-older');
      final q = h.outcomes.historyQueries.last;
      expect(q.cursor?.beforeId, _asgL);
      expect(byKey('history-newer'), findsOneWidget);
    });

    testWidgets('the member\'s cell parts are listed with a kind filter', (
      tester,
    ) async {
      const cellAsg = '61616161-6161-4161-8161-616161616161';
      final h = await pumpAt(
        tester,
        ClientPaths.dutyHistory,
        setUp: (h) => h.outcomes.history = AccessReadOk(
          MemberHistory.fromJson(
            historyJson(
              kinds: const {'department': 3, 'cell': 1},
              entries: [
                {
                  'assignment_id': cellAsg,
                  'occurrence_id': _occ,
                  'owner_kind': 'cell',
                  'department_id': null,
                  'department_name': null,
                  'cell_id': '62626262-6262-4262-8262-626262626262',
                  'duty_name': 'Opening prayer',
                  'position_name': null,
                  'starts_at': '2026-10-14T16:00:00.000000Z',
                  'reporting_at': null,
                  'started': true,
                  'state': 'current',
                  'response': 'accepted',
                  'response_provenance': 'member',
                  'responded_at': '2026-10-10T09:00:00.000000Z',
                  'outcome_state': 'not_tracked',
                  'outcome': null,
                },
              ],
            ),
          ),
        ),
      );
      expect(byKey('history-kinds'), findsOneWidget);
      expect(find.text('Cell (1)'), findsOneWidget);
      // The part reads as the cell programme; its one mark is the answer,
      // never an outcome (a cell meeting record is not a duty outcome).
      expect(find.textContaining('Cell programme · '), findsOneWidget);
      expect(
        find.descendant(
          of: byKey('history-state-$cellAsg'),
          matching: find.text('Accepted'),
        ),
        findsOneWidget,
      );
      expect(byKey('history-outcome-$cellAsg'), findsNothing);
      expect(
        find.textContaining('Cell programme parts show how they were answered'),
        findsOneWidget,
      );
      await tapKey(tester, 'segment-Cell (1)');
      final q = h.outcomes.historyQueries.last;
      expect(q.kind, DutyOwnerKind.cell);
      expect(q.toParams(), {'kind': 'cell'});
      expect(q.pages, isEmpty);
    });

    testWidgets('a leader opens a member\'s history from Outcomes', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyOutcomes,
        setUp: (h) {
          h.outcomes.outcomes = outcomes(standardPositions());
          h.outcomes.history = AccessReadOk(
            MemberHistory.fromJson(historyJson(self: false)),
          );
        },
      );
      await tapKey(tester, 'outcomes-history-$_slotA');
      await settle(tester);
      expect(h.outcomes.historyQueries.last.memberId, _ruth);
      expect(find.text('SYNTHETIC Ruth'), findsWidgets);
      expect(find.textContaining('Departments you lead'), findsOneWidget);
      // A leader sees department duties only: nothing to filter.
      expect(byKey('history-kinds'), findsNothing);
    });

    testWidgets('a refused history shows nothing private', (tester) async {
      await pumpAt(
        tester,
        DutyPaths.memberHistory(_omar),
        setUp: (h) => h.outcomes.history = const AccessReadDenied(
          AccessDenial.notGranted,
        ),
      );
      expect(find.textContaining('SYNTHETIC'), findsNothing);
      expect(byKey('history-summary'), findsNothing);
    });
  });

  group('My duties', () {
    testWidgets('the member sees their own outcome, or Not recorded yet', (
      tester,
    ) async {
      await pumpAt(
        tester,
        DutyPaths.assignment(_asgA),
        setUp: (h) => h.duties.mine = AccessReadOk(
          MyDuties.fromJson({
            'member_id': _ruth,
            'assignments': [
              myDutyData(
                response: 'accepted',
                startsAt: '2026-10-11T08:00:00.000000Z',
                endsAt: null,
                respondedAt: '2026-10-05T09:00:00.000000Z',
                extra: {
                  'outcome': outcomeJson([
                    trailItem(1, 'completed', note: 'SYNTHETIC: thank you'),
                  ]),
                },
              ),
            ],
          }),
        ),
      );
      expect(find.text('Outcome: Completed'), findsOneWidget);
      expect(find.textContaining('SYNTHETIC: thank you'), findsOneWidget);
    });

    testWidgets('a past duty nobody recorded stays Not recorded yet', (
      tester,
    ) async {
      await pumpAt(
        tester,
        DutyPaths.assignment(_asgA),
        setUp: (h) => h.duties.mine = AccessReadOk(
          MyDuties.fromJson({
            'member_id': _ruth,
            'assignments': [
              myDutyData(
                response: 'accepted',
                startsAt: '2026-10-11T08:00:00.000000Z',
                endsAt: null,
                respondedAt: '2026-10-05T09:00:00.000000Z',
              ),
            ],
          }),
        ),
      );
      expect(find.text('Outcome: not recorded yet.'), findsOneWidget);
      expect(find.textContaining('Completed'), findsNothing);
    });

    testWidgets('My duties links to the history', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.myDuties,
        setUp: (h) => h.duties.mine = AccessReadOk(
          MyDuties.fromJson({
            'member_id': _ruth,
            'assignments': [myDutyData()],
          }),
        ),
      );
      expect(byKey('my-duties-history'), findsOneWidget);
    });
  });
}
