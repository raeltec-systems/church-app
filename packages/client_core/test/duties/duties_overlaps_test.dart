// Story 4.4: overlap warnings and reasoned overrides on staff web: the
// candidates read (load and viewer-safe conflicts), the picker in the publish
// form, the edit form and the rota panel, the reason field and the server's
// refusal, and the recorded reason on the board and the rota. Fakes only; the
// server behaviour is covered by supabase/tests/duties_overlaps_test.sql and
// tools/identity-e2e/duties-overlaps.mjs.
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
const _slot = '45454545-4545-4545-8545-454545454545';
const _series = '50505050-5050-4050-8050-505050505050';
const _o1 = '51515151-5151-4151-8151-515151515151';
const _lydia = '99999999-9999-4999-8999-999999999999';
const _ruth = '66666666-6666-4666-8666-666666666666';
const _other = '77777777-7777-4777-8777-777777777777';
const _reason = 'SYNTHETIC: agreed to come after the first hour.';

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? setUp,
}) async {
  tester.view.physicalSize = const Size(1400, 8000);
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

Future<void> enter(WidgetTester tester, String key, String text) async {
  await tester.ensureVisible(byKey(key));
  await tester.enterText(byKey(key), text);
  await tester.pump();
}

Future<void> choose(WidgetTester tester, String key, String text) async {
  await tester.ensureVisible(byKey(key));
  await tester.tap(byKey(key));
  await settle(tester);
  await tester.tap(find.textContaining(text).last);
  await settle(tester);
}

bool enabled(WidgetTester tester, String key) {
  final w = tester.widget(byKey(key));
  return switch (w) {
    ButtonStyleButton b => b.onPressed != null,
    _ => throw StateError('not a button: $key'),
  };
}

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

/// Another department's duty as a leader may see it: busy time only.
Map<String, Object?> limitedConflict({String kind = 'department'}) => {
  'visibility': 'limited',
  'owner_kind': kind,
  'from': '2099-01-04T08:00:00.000000Z',
  'to': '2099-01-04T10:00:00.000000Z',
};

/// A duty of a department the leader manages: in full.
Map<String, Object?> fullConflict({String state = 'published'}) => {
  'visibility': 'full',
  'owner_kind': 'department',
  'occurrence_id': _o1,
  'owner_name': 'SYNTHETIC Preaching Rota',
  'duty_name': 'Evening service',
  'position_name': 'Reader',
  'state': state,
  'response': state == 'draft' ? null : 'accepted',
  'starts_at': '2099-01-04T08:30:00.000000Z',
  'ends_at': '2099-01-04T09:30:00.000000Z',
  'reporting_at': null,
  'location': 'SYNTHETIC Side room',
  'from': '2099-01-04T08:30:00.000000Z',
  'to': '2099-01-04T09:30:00.000000Z',
};

Map<String, Object?> check(
  String id,
  String name, {
  int total = 0,
  int here = 0,
  List<Map<String, Object?>> conflicts = const [],
  int? count,
  bool current = false,
  String account = 'app_account',
}) => {
  'member_id': id,
  'display_name': name,
  'account': account,
  'current': current,
  'upcoming': {'total': total, 'here': here},
  'conflicts': {'count': count ?? conflicts.length, 'items': conflicts},
};

AccessRead<DutyCandidates> candidatesWith(List<Map<String, Object?>> checks) =>
    AccessReadOk(
      DutyCandidates.fromJson({
        'department_id': _dept,
        'slot_id': null,
        'window': {
          'from': '2099-01-04T09:00:00.000000Z',
          'to': '2099-01-04T10:00:00.000000Z',
        },
        'candidates': checks,
      }),
    );

Map<String, Object?> leaderDuty({
  int overlaps = 0,
  Map<String, Object?>? override,
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
      'slot_id': _slot,
      'position_no': 1,
      'assignment': {
        'assignment_id': _assignment,
        'member_id': _ruth,
        'display_name': 'SYNTHETIC Ruth',
        'response': 'pending',
        'response_deadline': '2099-01-01T08:00:00.000000Z',
        'responded_at': null,
        'note': null,
        'revision': 1,
        'overlaps': overlaps,
        'override': override,
      },
    },
  ],
};

AccessRead<DutyLeaderBoard> boardWith({
  List<Map<String, Object?>> duties = const [],
}) => AccessReadOk(
  DutyLeaderBoard.fromJson({
    'departments': [
      {
        'department_id': _dept,
        'name': 'SYNTHETIC Preaching Rota',
        'capacity': 'department_leader',
        'can_publish': true,
        'members': [
          rosterMember(_ruth, 'SYNTHETIC Ruth'),
          rosterMember(_lydia, 'SYNTHETIC Lydia', account: 'no_login'),
        ],
        'duties': duties,
      },
    ],
  }),
);

Map<String, Object?> rotaOccurrence({
  String state = 'published',
  Map<String, Object?>? draft,
  Map<String, Object?>? assignment,
}) => {
  'occurrence_id': _o1,
  'series_date': '2099-01-04',
  'state': state,
  'revision': 3,
  'duty_name': 'Sunday service',
  'starts_at': '2099-01-04T08:00:00.000000Z',
  'ends_at': null,
  'reporting_at': null,
  'location': null,
  'instructions': null,
  'topic': null,
  'scripture': null,
  'event_ref': null,
  'started': false,
  'required': 1,
  'confirmed': 0,
  'positions': [
    {
      'slot_id': _slot,
      'position_no': 1,
      'position_name': 'Preacher',
      'slot_revision': 1,
      'draft': draft,
      'assignment': assignment,
    },
  ],
};

AccessRead<DutyRota> rotaWith(Map<String, Object?> occurrence) => AccessReadOk(
  DutyRota.fromJson({
    'departments': [
      {
        'department_id': _dept,
        'name': 'SYNTHETIC Preaching Rota',
        'capacity': 'department_leader',
        'can_manage': true,
        'members': [
          rosterMember(_ruth, 'SYNTHETIC Ruth'),
          rosterMember(_lydia, 'SYNTHETIC Lydia', account: 'no_login'),
        ],
        'series': [
          {
            'series_id': _series,
            'department_id': _dept,
            'duty_name': 'Sunday service',
            'every': 'week',
            'interval': 1,
            'from_date': '2099-01-04',
            'until_date': '2099-01-04',
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
            'revision': 2,
            'draft_slots': occurrence['state'] == 'draft' ? 1 : 0,
            'occurrences': [occurrence],
          },
        ],
        'series_truncated': false,
      },
    ],
  }),
);

void main() {
  group('wire mapping', () {
    test('the candidates read parses load and both kinds of conflict', () {
      final r = (candidatesWith([
        check(
          _ruth,
          'SYNTHETIC Ruth',
          total: 3,
          here: 1,
          conflicts: [limitedConflict(), fullConflict()],
          count: 12,
        ),
        check(_lydia, 'SYNTHETIC Lydia', account: 'no_login'),
      ]) as AccessReadOk<DutyCandidates>).value;
      final ruth = r.of(_ruth)!;
      expect(ruth.loadLabel, '3 upcoming (1 here)');
      expect(ruth.overlaps, isTrue);
      expect(ruth.conflictCount, 12);
      final limited = ruth.conflicts.first;
      expect(limited.full, isFalse);
      expect(limited.ownerLabel, 'Another department\'s duty');
      expect(limited.dutyName, isNull);
      expect(limited.location, isNull);
      final full = ruth.conflicts.last;
      expect(full.ownerLabel, 'SYNTHETIC Preaching Rota');
      expect(full.response, DutyResponse.accepted);
      expect(full.times?.endsAt, DateTime.utc(2099, 1, 4, 9, 30));
      expect(
        DutyConflict.fromJson(limitedConflict(kind: 'cell')).ownerLabel,
        'A cell programme part',
      );
      expect(r.of(_lydia)!.overlaps, isFalse);
      expect(r.of(_lydia)!.loadLabel, '0 upcoming');
      expect(r.of(_other), isNull);
    });

    test('malformed candidates are refused', () {
      for (final bad in [
        check(_ruth, 'R', total: 1, here: 2),
        check(_ruth, 'R', conflicts: [limitedConflict()], count: 0),
        check(
          _ruth,
          'R',
          conflicts: [
            {...limitedConflict(), 'visibility': 'secret'},
          ],
        ),
        check(
          _ruth,
          'R',
          conflicts: [
            {...limitedConflict(), 'owner_kind': 'care'},
          ],
        ),
        check(
          _ruth,
          'R',
          conflicts: [
            {...fullConflict(), 'state': 'cancelled'},
          ],
        ),
      ]) {
        expect(() => CandidateCheck.fromJson(bad), throwsFormatException);
      }
    });

    test('recorded overrides and overlap counts parse', () {
      final a = PositionAssignment.fromJson(
        (leaderDuty(
                  overlaps: 2,
                  override: {
                    'reason': _reason,
                    'overlaps': 1,
                    'at': '2026-10-14T08:00:00.000000Z',
                    'by': 'SYNTHETIC Leader',
                  },
                )['positions']!
                as List)
            .first['assignment'],
      );
      expect(a.overlaps, 2);
      expect(a.override?.reason, _reason);
      expect(a.override?.by, 'SYNTHETIC Leader');
      // Older servers send neither.
      final old = PositionAssignment.fromJson(
        {...(leaderDuty()['positions']! as List).first['assignment'] as Map}
          ..remove('overlaps'),
      );
      expect(old.overlaps, 0);
      expect(old.override, isNull);
      final p = RotaPerson.fromJson({
        'member_id': _ruth,
        'display_name': 'SYNTHETIC Ruth',
        'available': true,
        'overlaps': 1,
        'override_reason': _reason,
      });
      expect(p.overlaps, 1);
      expect(p.overrideReason, _reason);
    });

    test('payloads carry a trimmed reason only when given', () {
      final draft = DutyDraft(
        departmentId: _dept,
        dutyName: 'Sunday preaching',
        startsAt: DateTime.utc(2099, 1, 4, 8),
        memberId: _ruth,
        responseDeadline: DateTime.utc(2099, 1, 1, 8),
        overrideReason: '  $_reason  ',
      );
      expect(draft.toPayload()['override_reason'], _reason);
      final blank = DutyDraft(
        departmentId: _dept,
        dutyName: 'Sunday preaching',
        startsAt: DateTime.utc(2099, 1, 4, 8),
        memberId: _ruth,
        responseDeadline: DateTime.utc(2099, 1, 1, 8),
        overrideReason: '   ',
      );
      expect(blank.toPayload().containsKey('override_reason'), isFalse);
      final duty = LeaderDuty.fromJson(leaderDuty());
      final notes = DutyEdit(
        duty: duty,
        dutyName: 'Sunday preaching',
        startsAt: duty.times.startsAt,
        memberId: _ruth,
        location: 'SYNTHETIC Main hall',
        instructions: 'New notes',
        overrideReason: _reason,
      );
      expect(
        notes.toPayload().containsKey('override_reason'),
        isFalse,
        reason: 'a notes-only change asks nobody, so needs no reason',
      );
      final moved = DutyEdit(
        duty: duty,
        dutyName: 'Sunday preaching',
        startsAt: DateTime.utc(2099, 1, 4, 9),
        memberId: _ruth,
        location: 'SYNTHETIC Main hall',
        responseDeadline: DateTime.utc(2099, 1, 1, 8),
        overrideReason: _reason,
      );
      expect(moved.toPayload()['override_reason'], _reason);
    });

    test('candidate queries are named parameters and compare by value', () {
      final a = CandidateQuery.window(
        departmentId: _dept,
        startsAt: DateTime.utc(2099, 1, 4, 8),
        endsAt: DateTime.utc(2099, 1, 4, 9),
      );
      expect(a.toParams(), {
        'department_id': _dept,
        'starts_at': '2099-01-04T08:00:00.000Z',
        'ends_at': '2099-01-04T09:00:00.000Z',
      });
      expect(
        a,
        CandidateQuery.window(
          departmentId: _dept,
          startsAt: DateTime.utc(2099, 1, 4, 8),
          endsAt: DateTime.utc(2099, 1, 4, 9),
        ),
      );
      expect(const CandidateQuery.slot(_slot).toParams(), {'slot_id': _slot});
      expect(
        CandidateQuery.slot(
          _slot,
          startsAt: DateTime.utc(2099, 1, 4, 9),
        ).toParams(),
        {'slot_id': _slot, 'starts_at': '2099-01-04T09:00:00.000Z'},
      );
      expect(const CandidateQuery.slot(_slot) == a, isFalse);
    });
  });

  group('staff web: publishing with overlap warnings', () {
    Future<ClientTestHarness> fillPublish(
      WidgetTester tester,
      AccessRead<DutyCandidates> candidates,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) {
          h.duties.board = boardWith();
          h.duties.candidates = candidates;
        },
      );
      await enter(tester, 'publish-name-$_dept', 'Sunday preaching');
      await enter(tester, 'publish-date-$_dept', '2099-01-04');
      await enter(tester, 'publish-start-$_dept', '11:00');
      await enter(tester, 'publish-end-$_dept', '12:00');
      await enter(tester, 'publish-deadline-date-$_dept', '2099-01-01');
      await enter(tester, 'publish-deadline-time-$_dept', '08:00');
      await settle(tester);
      return h;
    }

    testWidgets(
      'another department\'s duty shows as a busy time; a reason is sent',
      (tester) async {
        final h = await fillPublish(
          tester,
          candidatesWith([
            check(
              _ruth,
              'SYNTHETIC Ruth',
              total: 2,
              conflicts: [limitedConflict()],
            ),
            check(_lydia, 'SYNTHETIC Lydia', account: 'no_login'),
          ]),
        );
        // The picker asked about the busy time entered (church time).
        expect(
          h.duties.candidateQueries.last,
          CandidateQuery.window(
            departmentId: _dept,
            startsAt: DateTime.utc(2099, 1, 4, 9),
            endsAt: DateTime.utc(2099, 1, 4, 10),
          ),
        );
        await choose(tester, 'publish-member-$_dept', 'SYNTHETIC Ruth');
        expect(
          find.textContaining('2 upcoming (0 here), overlaps 1 at this time'),
          findsWidgets,
        );
        expect(byKey('publish-member-$_dept-overlaps'), findsOneWidget);
        expect(
          find.textContaining('SYNTHETIC Ruth has 1 other duty at that time'),
          findsOneWidget,
        );
        expect(
          find.textContaining('- Another department\'s duty, '),
          findsOneWidget,
        );
        expect(byKey('publish-member-$_dept-reason'), findsOneWidget);
        await enter(tester, 'publish-member-$_dept-reason', _reason);
        await tapKey(tester, 'publish-save-$_dept');
        final sent = h.gateway.sent.single;
        expect(sent.wire['command'], 'duties.publish_duty');
        final payload = sent.wire['payload'] as Map;
        expect(payload['member_id'], _ruth);
        expect(payload['override_reason'], _reason);
        sent.confirm(const {'override_recorded': true}, 1);
        await settle(tester);
        expect(byKey('duties-notice-published'), findsOneWidget);
      },
    );

    testWidgets('a refusal for the overlap asks for the reason', (
      tester,
    ) async {
      // The check failed (read refused), so only the server's answer warns.
      final h = await fillPublish(
        tester,
        const AccessReadDenied(AccessDenial.unavailable),
      );
      await choose(tester, 'publish-member-$_dept', 'SYNTHETIC Ruth');
      expect(byKey('publish-member-$_dept-check-failed'), findsOneWidget);
      expect(byKey('publish-member-$_dept-reason'), findsNothing);
      await tapKey(tester, 'publish-save-$_dept');
      h.gateway.sent.single.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {
          'member_id': 'overlap',
          'override_reason': 'required',
        },
      );
      await settle(tester);
      expect(byKey('duties-notice-overlapNeedsReason'), findsOneWidget);
      expect(byKey('publish-member-$_dept-reason'), findsOneWidget);
      expect(
        find.text('Give a reason, or choose someone else'),
        findsOneWidget,
      );
      expect(find.text('Has another duty at that time'), findsOneWidget);
    });

    testWidgets('no overlap: no reason, and no claim that they are free', (
      tester,
    ) async {
      final h = await fillPublish(
        tester,
        candidatesWith([check(_ruth, 'SYNTHETIC Ruth', total: 1, here: 1)]),
      );
      await choose(tester, 'publish-member-$_dept', 'SYNTHETIC Ruth');
      expect(byKey('publish-member-$_dept-no-overlap'), findsOneWidget);
      expect(
        find.textContaining('This does not mean they are free'),
        findsOneWidget,
      );
      expect(byKey('publish-member-$_dept-reason'), findsNothing);
      await tapKey(tester, 'publish-save-$_dept');
      final payload = h.gateway.sent.single.wire['payload'] as Map;
      expect(payload.containsKey('override_reason'), isFalse);
    });

    testWidgets('the board shows overlaps and the recorded reason', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) => h.duties.board = boardWith(
          duties: [
            leaderDuty(
              overlaps: 1,
              override: {
                'reason': _reason,
                'overlaps': 1,
                'at': '2026-10-14T08:00:00.000000Z',
                'by': 'SYNTHETIC Leader',
              },
            ),
          ],
        ),
      );
      expect(find.text('Overlaps 1 other duty'), findsOneWidget);
      expect(
        tester.widget<Text>(byKey('override-$_assignment')).data,
        contains('Assigned despite an overlap: "$_reason" (SYNTHETIC Leader'),
      );
    });

    testWidgets('changing a duty asks about the person at the new times', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyLeader,
        setUp: (h) {
          h.duties.board = boardWith(duties: [leaderDuty()]);
          h.duties.candidates = candidatesWith([
            check(
              _ruth,
              'SYNTHETIC Ruth',
              current: true,
              total: 2,
              here: 2,
              conflicts: [fullConflict()],
            ),
          ]);
        },
      );
      await tapKey(tester, 'edit-$_occurrence');
      await enter(tester, 'edit-start-$_occurrence', '10:30');
      await settle(tester);
      expect(
        h.duties.candidateQueries.last,
        CandidateQuery.slot(_slot, startsAt: DateTime.utc(2099, 1, 4, 8, 30)),
      );
      expect(
        find.textContaining(
          '- SYNTHETIC Preaching Rota: Evening service (Reader), ',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('at SYNTHETIC Side room, Accepted'),
        findsOneWidget,
      );
      await enter(tester, 'edit-member-$_occurrence-reason', _reason);
      await enter(tester, 'edit-deadline-date-$_occurrence', '2099-01-02');
      await enter(tester, 'edit-deadline-time-$_occurrence', '08:00');
      await tapKey(tester, 'edit-save-$_occurrence');
      final payload = h.gateway.sent.single.wire['payload'] as Map;
      expect(payload['override_reason'], _reason);
      expect(payload['starts_at'], '2099-01-04T08:30:00.000Z');
    });
  });

  group('staff web: the rota picker', () {
    testWidgets('giving a published position with a reason', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyRota,
        setUp: (h) {
          h.duties.rota = rotaWith(rotaOccurrence());
          h.duties.candidates = candidatesWith([
            check(
              _ruth,
              'SYNTHETIC Ruth',
              total: 1,
              conflicts: [limitedConflict(kind: 'cell')],
            ),
          ]);
        },
      );
      await tapKey(tester, 'rota-date-$_o1');
      expect(h.duties.candidateQueries.last, const CandidateQuery.slot(_slot));
      await choose(tester, 'rota-pick-$_slot', 'SYNTHETIC Ruth');
      expect(find.textContaining('- A cell programme part, '), findsOneWidget);
      await enter(tester, 'rota-pick-$_slot-reason', _reason);
      await tapKey(tester, 'rota-save-$_slot');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'duties.assign_slot');
      expect((sent.wire['payload'] as Map)['override_reason'], _reason);
    });

    testWidgets('a planned person keeps their plan with a new reason', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyRota,
        setUp: (h) {
          h.duties.rota = rotaWith(
            rotaOccurrence(
              state: 'draft',
              draft: {
                'member_id': _ruth,
                'display_name': 'SYNTHETIC Ruth',
                'available': true,
                'overlaps': 1,
              },
            ),
          );
          h.duties.candidates = candidatesWith([
            check(
              _ruth,
              'SYNTHETIC Ruth',
              current: true,
              conflicts: [limitedConflict()],
            ),
          ]);
        },
      );
      expect(
        find.textContaining('Planned: SYNTHETIC Ruth; overlaps 1 other duty'),
        findsWidgets,
      );
      await tapKey(tester, 'rota-date-$_o1');
      await settle(tester);
      expect(enabled(tester, 'rota-save-$_slot'), isFalse);
      await enter(tester, 'rota-pick-$_slot-reason', _reason);
      expect(enabled(tester, 'rota-save-$_slot'), isTrue);
      expect(find.text('Save the reason'), findsOneWidget);
      await tapKey(tester, 'rota-save-$_slot');
      final payload = h.gateway.sent.single.wire['payload'] as Map;
      expect(payload, {
        'slot_id': _slot,
        'member_id': _ruth,
        'override_reason': _reason,
      });
    });

    testWidgets('a recorded override shows on the position', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.dutyRota,
        setUp: (h) => h.duties.rota = rotaWith(
          rotaOccurrence(
            assignment: {
              'assignment_id': _assignment,
              'member_id': _ruth,
              'display_name': 'SYNTHETIC Ruth',
              'response': 'pending',
              'response_deadline': '2099-01-03T08:00:00.000000Z',
              'revision': 1,
              'available': true,
              'overlaps': 1,
              'override': {
                'reason': _reason,
                'overlaps': 1,
                'at': '2026-10-14T08:00:00.000000Z',
                'by': 'SYNTHETIC Leader',
              },
            },
          ),
        ),
      );
      expect(
        find.textContaining(
          'SYNTHETIC Ruth: Awaiting response; overlaps 1 other duty (reason '
          'given)',
        ),
        findsWidgets,
      );
      await tapKey(tester, 'rota-date-$_o1');
      expect(byKey('rota-override-$_slot'), findsOneWidget);
    });
  });
}
