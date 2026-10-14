// Story 4.3: the staff web rota grid and its accessible list (drafts, Publish
// N draft slots, planning and giving positions, this-date and this-and-later
// edits and cancellation) and the member's view of a rota position. Fakes
// only; the server behaviour is covered by supabase/tests/duties_rota_test.sql
// and tools/identity-e2e/duties-rota.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter_test/flutter_test.dart';

const _dept = '44444444-4444-4444-8444-444444444444';
const _series = '50505050-5050-4050-8050-505050505050';
const _o1 = '51515151-5151-4151-8151-515151515151';
const _o2 = '52525252-5252-4252-8252-525252525252';
const _ruth = '66666666-6666-4666-8666-666666666666';
const _lydia = '99999999-9999-4999-8999-999999999999';
const _asg = '42424242-4242-4242-8242-424242424242';

String _slot(String occurrence, int n) => '${occurrence.substring(0, 34)}0$n';

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

bool enabled(WidgetTester tester, String key) {
  final w = tester.widget(byKey(key));
  return switch (w) {
    ButtonStyleButton b => b.onPressed != null,
    _ => throw StateError('not a button: $key'),
  };
}

Map<String, Object?> member(
  String id,
  String name, {
  String account = 'app_account',
}) => {
  'member_id': id,
  'display_name': name,
  'account': account,
  'since': '2026-10-13T08:00:00.000000Z',
};

Map<String, Object?> position(
  String occurrence,
  int n,
  String name, {
  Map<String, Object?>? draft,
  Map<String, Object?>? assignment,
}) => {
  'slot_id': _slot(occurrence, n),
  'position_no': n,
  'position_name': name,
  'slot_revision': 1,
  'draft': draft,
  'assignment': assignment,
};

Map<String, Object?> assignment(
  String response, {
  String id = _asg,
  String memberId = _ruth,
  String? name = 'SYNTHETIC Ruth',
}) => {
  'assignment_id': id,
  'member_id': memberId,
  'display_name': name,
  'response': response,
  'response_deadline': '2099-01-03T08:00:00.000000Z',
  'revision': response == 'pending' ? 1 : 2,
  'available': true,
};

/// 2099-01-04T08:00Z is Sunday 4 January 2099, 10:00 in Lusaka.
Map<String, Object?> occurrence(
  String id, {
  String state = 'draft',
  String date = '2099-01-04',
  String startsAt = '2099-01-04T08:00:00.000000Z',
  int revision = 1,
  int confirmed = 0,
  List<Map<String, Object?>>? positions,
}) => {
  'occurrence_id': id,
  'series_date': date,
  'state': state,
  'revision': revision,
  'duty_name': 'Sunday service',
  'starts_at': startsAt,
  'ends_at': null,
  'reporting_at': null,
  'location': 'SYNTHETIC Main hall',
  'instructions': null,
  'topic': null,
  'scripture': null,
  'event_ref': null,
  'started': false,
  'required': 3,
  'confirmed': confirmed,
  'positions':
      positions ??
      [
        position(id, 1, 'Preacher'),
        position(id, 2, 'Reader'),
        position(id, 3, 'Usher'),
      ],
};

AccessRead<DutyRota> rotaWith(
  List<Map<String, Object?>> occurrences, {
  int draftSlots = 6,
  int revision = 1,
  bool canManage = true,
}) => AccessReadOk(
  DutyRota.fromJson({
    'departments': [
      {
        'department_id': _dept,
        'name': 'SYNTHETIC Preaching Rota',
        'capacity': canManage ? 'department_leader' : 'pastor',
        'can_manage': canManage,
        'members': [
          member(_ruth, 'SYNTHETIC Ruth'),
          member(_lydia, 'SYNTHETIC Lydia', account: 'no_login'),
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
            'location': 'SYNTHETIC Main hall',
            'instructions': null,
            'topic': null,
            'scripture': null,
            'event_ref': null,
            'positions': ['Preacher', 'Reader', 'Usher'],
            'zone': 'Africa/Lusaka',
            'revision': revision,
            'draft_slots': draftSlots,
            'occurrences': occurrences,
          },
        ],
        'series_truncated': false,
      },
    ],
  }),
);

RotaOccurrence _occ(Map<String, Object?> json) => RotaOccurrence.fromJson(json);

void main() {
  group('wire mapping', () {
    test('a rota parses with its coverage', () {
      final r = (rotaWith([occurrence(_o1)]) as AccessReadOk<DutyRota>).value;
      final s = r.departments.single.series.single;
      expect(s.repeatLabel, 'Every week');
      expect(s.occurrences.single.positions.map((p) => p.label), [
        'Preacher',
        'Reader',
        'Usher',
      ]);
      expect(s.occurrences.single.state, RotaState.draft);
    });

    test('coverage that does not match the positions is refused', () {
      expect(
        () => _occ({...occurrence(_o1), 'confirmed': 4}),
        throwsFormatException,
      );
      expect(
        () => _occ({...occurrence(_o1), 'required': 2}),
        throwsFormatException,
      );
      expect(
        () => _occ({...occurrence(_o1), 'state': 'archived'}),
        throwsFormatException,
      );
    });

    test('a new series is sent in church-local dates and times', () {
      final d = SeriesDraft.parse(
        departmentId: _dept,
        dutyName: ' Sunday  service ',
        every: 'week',
        interval: '',
        fromDate: '2099-01-04',
        untilDate: '2099-03-29',
        startTime: '00:30',
        endTime: '',
        reportingTime: '',
        location: '',
        instructions: '',
        topic: 'SYNTHETIC Hope',
        scripture: '',
        positions: 'Preacher, Reader,, Usher ',
      )!;
      expect(d.toPayload(), {
        'department_id': _dept,
        'duty_name': 'Sunday service',
        'every': 'week',
        'from_date': '2099-01-04',
        'until_date': '2099-03-29',
        'start_time': '00:30',
        'topic': 'SYNTHETIC Hope',
        'positions': ['Preacher', 'Reader', 'Usher'],
      });
      expect(
        SeriesDraft.parse(
          departmentId: _dept,
          dutyName: 'x',
          every: 'week',
          interval: '1',
          fromDate: '2099-02-30',
          untilDate: '2099-03-29',
          startTime: '10:00',
          endTime: '',
          reportingTime: '',
          location: '',
          instructions: '',
          topic: '',
          scripture: '',
          positions: 'A',
        ),
        isNull,
        reason: 'a day that does not exist',
      );
    });

    test('this date is sent as instants on its own church date', () {
      final o = _occ(
        occurrence(
          _o1,
          state: 'published',
          positions: [
            position(_o1, 1, 'Preacher', assignment: assignment('accepted')),
            position(_o1, 2, 'Reader'),
            position(_o1, 3, 'Usher'),
          ],
          confirmed: 1,
        ),
      );
      // 00:30 church time on Sunday 4 January is 22:30 UTC on Saturday.
      final e = RotaEdit(
        occurrence: o,
        dutyName: 'Sunday service',
        startTime: '00:30',
        endTime: '00:15',
        location: 'SYNTHETIC Main hall',
        lead: '1 day',
      );
      expect(e.material, isTrue);
      expect(e.needsLead, isTrue);
      expect(e.thisPayload(), {
        'occurrence_id': _o1,
        'starts_at': '2099-01-03T22:30:00.000Z',
        'ends_at': '2099-01-04T22:15:00.000Z',
        'response_deadline': '2099-01-02T22:30:00.000Z',
      });
      expect(e.futurePayload(_series), {
        'series_id': _series,
        'from_occurrence_id': _o1,
        'start_time': '00:30',
        'end_time': '00:15',
        'deadline_before': '1 day',
      });
      final notes = RotaEdit(
        occurrence: o,
        dutyName: 'Sunday service',
        startTime: '10:00',
        location: 'SYNTHETIC Main hall',
        scripture: 'Psalm 23',
        lead: '1 day',
      );
      expect(notes.material, isFalse);
      expect(notes.thisPayload(), {
        'occurrence_id': _o1,
        'scripture': 'Psalm 23',
      });
    });
  });

  group('staff web: the rota grid', () {
    testWidgets('drafts, the accessible list and Publish N draft slots', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyRota,
        setUp: (h) => h.duties.rota = rotaWith([
          occurrence(
            _o1,
            positions: [
              position(
                _o1,
                1,
                'Preacher',
                draft: {
                  'member_id': _ruth,
                  'display_name': 'SYNTHETIC Ruth',
                  'available': true,
                },
              ),
              position(_o1, 2, 'Reader'),
              position(
                _o1,
                3,
                'Usher',
                draft: {
                  'member_id': _lydia,
                  'display_name': 'SYNTHETIC Lydia',
                  'available': false,
                },
              ),
            ],
          ),
          occurrence(
            _o2,
            date: '2099-01-11',
            startsAt: '2099-01-11T08:00:00.000000Z',
          ),
        ]),
      );
      expect(byKey('rota-grid-$_series'), findsOneWidget);
      expect(
        tester.widget<Text>(byKey('rota-cell-${_slot(_o1, 1)}')).data,
        'Planned: SYNTHETIC Ruth',
      );
      expect(
        tester.widget<Text>(byKey('rota-cell-${_slot(_o1, 3)}')).data,
        'Planned: SYNTHETIC Lydia (can\'t serve now)',
      );
      expect(find.text('Not planned'), findsNWidgets(4));
      // The accessible list says the same in plain text.
      await tapKey(tester, 'rota-view-$_series');
      expect(byKey('rota-list-$_series'), findsOneWidget);
      expect(find.text('Preacher: Planned: SYNTHETIC Ruth'), findsOneWidget);
      // Publish N draft slots asks for confirmation first.
      expect(find.text('Publish 6 draft slots'), findsOneWidget);
      await tapKey(tester, 'rota-publish-$_series');
      expect(h.gateway.sent, isEmpty);
      expect(
        find.textContaining('2 planned people are asked to answer'),
        findsOneWidget,
      );
      await tapKey(tester, 'rota-publish-confirm-$_series');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'duties.publish_drafts');
      expect(sent.wire['expected_revision'], 1);
      expect(sent.wire['payload'], {
        'series_id': _series,
        'slot_count': 6,
        'deadline_before': '2 days',
      });
      expect(byKey('duties-pending'), findsOneWidget);
      // A reload while it is out keeps it pending (not sent twice).
      await tapKey(tester, 'rota-view-$_series');
      expect(byKey('duties-pending'), findsOneWidget);
      // Unknown outcome: Check again resends the same request id.
      sent.unknown();
      await settle(tester);
      expect(byKey('duties-notice-unconfirmed'), findsOneWidget);
      await tapKey(tester, 'duties-check-again');
      expect(h.gateway.sent.last.wire, sent.wire);
      h.gateway.sent.last.refuse(
        ErrorCode.conflict,
        fieldErrors: const {'slot_count': 'changed'},
        currentRevision: const Optional.of(2),
      );
      await settle(tester);
      expect(byKey('duties-notice-draftCountChanged'), findsOneWidget);
      expect(h.duties.rotaCalls, greaterThanOrEqualTo(2));
    });

    testWidgets('a published date shows 2 of 3 confirmed; give a position', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyRota,
        setUp: (h) => h.duties.rota = rotaWith(draftSlots: 0, [
          occurrence(
            _o1,
            state: 'published',
            revision: 4,
            confirmed: 2,
            positions: [
              position(_o1, 1, 'Preacher', assignment: assignment('accepted')),
              position(
                _o1,
                2,
                'Reader',
                assignment: assignment(
                  'accepted',
                  id: '42424242-4242-4242-8242-424242424243',
                  memberId: _lydia,
                  name: 'SYNTHETIC Lydia',
                ),
              ),
              position(_o1, 3, 'Usher'),
            ],
          ),
        ]),
      );
      expect(tester.widget<Text>(byKey('rota-confirmed-$_o1')).data, '2 of 3');
      expect(find.text('Unfilled'), findsOneWidget);
      expect(byKey('rota-publish-$_series'), findsNothing);
      await tapKey(tester, 'rota-date-$_o1');
      expect(enabled(tester, 'rota-save-${_slot(_o1, 3)}'), isFalse);
      await tapKey(tester, 'rota-pick-${_slot(_o1, 3)}');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(
        find.text('SYNTHETIC Lydia (no login: contact them directly)').last,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tapKey(tester, 'rota-save-${_slot(_o1, 3)}');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'duties.assign_slot');
      expect(sent.wire['expected_revision'], 4);
      expect(sent.wire['payload'], {
        'slot_id': _slot(_o1, 3),
        'member_id': _lydia,
        // 2 days before 10:00 church time on 4 January.
        'response_deadline': '2099-01-02T08:00:00.000Z',
      });
      sent.confirm(const {'state': 'published'}, 5);
      await settle(tester);
      expect(byKey('duties-notice-positionGiven'), findsOneWidget);
    });

    testWidgets('change this and later dates, then cancel one date', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyRota,
        setUp: (h) => h.duties.rota = rotaWith(draftSlots: 0, revision: 3, [
          occurrence(
            _o1,
            state: 'published',
            revision: 4,
            confirmed: 1,
            positions: [
              position(_o1, 1, 'Preacher', assignment: assignment('accepted')),
              position(_o1, 2, 'Reader'),
              position(_o1, 3, 'Usher'),
            ],
          ),
        ]),
      );
      await tapKey(tester, 'rota-date-$_o1');
      await tapKey(tester, 'rota-change-$_o1');
      await tapKey(tester, 'rota-scope-future-$_o1');
      await enter(tester, 'rota-edit-start-$_o1', '09:00');
      expect(
        find.textContaining('Everyone assigned is asked to answer again'),
        findsOneWidget,
      );
      expect(byKey('rota-edit-lead-$_o1'), findsOneWidget);
      await tapKey(tester, 'rota-edit-save-$_o1');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'duties.revise_series');
      expect(sent.wire['expected_revision'], 3);
      expect(sent.wire['payload'], {
        'series_id': _series,
        'from_occurrence_id': _o1,
        'start_time': '09:00',
        'deadline_before': '2 days',
      });
      sent.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'deadline_before': 'passed'},
      );
      await settle(tester);
      expect(byKey('duties-notice-leadPassed'), findsOneWidget);
      // Cancel this date only.
      await tapKey(tester, 'rota-edit-close-$_o1');
      await tapKey(tester, 'rota-cancel-$_o1');
      expect(find.textContaining('People who were waiting to answer or had accepted'), findsOneWidget);
      await tapKey(tester, 'rota-cancel-confirm-$_o1');
      final cancel = h.gateway.sent.last;
      expect(cancel.wire['command'], 'duties.cancel_occurrence');
      expect(cancel.wire['expected_revision'], 4);
      expect(cancel.wire['payload'], {'occurrence_id': _o1});
      h.duties.rota = rotaWith(draftSlots: 0, revision: 3, [
        occurrence(_o1, state: 'cancelled', revision: 5),
      ]);
      cancel.confirm(const {'state': 'cancelled'}, 5);
      await settle(tester);
      expect(byKey('duties-notice-occurrenceCancelled'), findsOneWidget);
      expect(find.text('Cancelled'), findsWidgets);
    });

    testWidgets('a refused answer-by shows on the lead picker', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyRota,
        setUp: (h) => h.duties.rota = rotaWith(draftSlots: 0, [
          occurrence(
            _o1,
            state: 'published',
            revision: 4,
            positions: [
              position(_o1, 1, 'Preacher'),
              position(_o1, 2, 'Reader'),
              position(_o1, 3, 'Usher'),
            ],
          ),
        ]),
      );
      await tapKey(tester, 'rota-date-$_o1');
      await tapKey(tester, 'rota-pick-${_slot(_o1, 1)}');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('SYNTHETIC Ruth').last);
      await tester.pump(const Duration(milliseconds: 300));
      await tapKey(tester, 'rota-save-${_slot(_o1, 1)}');
      h.gateway.sent.single.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'response_deadline': 'past'},
      );
      await settle(tester);
      expect(byKey('rota-assign-lead-$_o1-error'), findsOneWidget);
      expect(
        find.text('This is in the past: choose a later time'),
        findsOneWidget,
      );
    });

    testWidgets('a series edit refused for a later date names and opens it', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyRota,
        setUp: (h) => h.duties.rota = rotaWith(draftSlots: 0, revision: 3, [
          occurrence(
            _o1,
            state: 'published',
            revision: 4,
            positions: [
              position(_o1, 1, 'Preacher', assignment: assignment('accepted')),
              position(_o1, 2, 'Reader'),
              position(_o1, 3, 'Usher'),
            ],
          ),
          occurrence(
            _o2,
            state: 'published',
            date: '2099-01-11',
            startsAt: '2099-01-11T08:00:00.000000Z',
          ),
        ]),
      );
      await tapKey(tester, 'rota-date-$_o1');
      await tapKey(tester, 'rota-change-$_o1');
      await tapKey(tester, 'rota-scope-future-$_o1');
      await enter(tester, 'rota-edit-start-$_o1', '09:00');
      await tapKey(tester, 'rota-edit-save-$_o1');
      h.gateway.sent.single.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {
          'member_id': 'required_reassign',
          'occurrence:$_o2': 'required_reassign',
        },
      );
      await settle(tester);
      expect(byKey('rota-edit-member-error-$_o1'), findsOneWidget);
      expect(
        find.textContaining('Someone assigned can no longer serve'),
        findsOneWidget,
      );
      await tapKey(tester, 'rota-edit-open-$_o2');
      await settle(tester);
      expect(byKey('rota-change-$_o2'), findsOneWidget);
    });

    testWidgets('a publish refused for one date names it', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyRota,
        setUp: (h) => h.duties.rota = rotaWith([occurrence(_o1)]),
      );
      await tapKey(tester, 'rota-publish-$_series');
      await tapKey(tester, 'rota-publish-confirm-$_series');
      h.gateway.sent.single.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {
          'member_id': 'unavailable',
          'occurrence:$_o1': 'unavailable',
        },
      );
      await settle(tester);
      expect(byKey('rota-publish-error-$_series'), findsOneWidget);
      expect(byKey('duties-notice-plannedUnavailable'), findsOneWidget);
      await tapKey(tester, 'rota-publish-open-$_o1');
      expect(byKey('rota-change-$_o1'), findsOneWidget);
    });

    testWidgets('screen readers can open a date from the grid and the list', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpAt(
        tester,
        ClientPaths.dutyRota,
        setUp: (h) => h.duties.rota = rotaWith([occurrence(_o1)]),
      );
      final date = find.bySemanticsLabel(RegExp('Open this date'));
      expect(date, findsOneWidget);
      expect(
        tester
            .getSemantics(date)
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isTrue,
      );
      tester.semantics.tap(find.semantics.byLabel(RegExp('Open this date')));
      await tester.pump();
      expect(byKey('rota-close-$_o1'), findsOneWidget);
      await tapKey(tester, 'rota-close-$_o1');
      await tapKey(tester, 'rota-view-$_series');
      // The list names the date on its button, and each date is a header.
      expect(find.textContaining('Manage '), findsOneWidget);
      expect(
        tester
            .getSemantics(find.textContaining('(church time): Draft'))
            .getSemanticsData()
            .flagsCollection.isHeader,
        isTrue,
      );
      handle.dispose();
    });

    testWidgets('a linked-event-only change says no notice was sent', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyRota,
        setUp: (h) => h.duties.rota = rotaWith([occurrence(_o1)]),
      );
      await tapKey(tester, 'rota-date-$_o1');
      await tapKey(tester, 'rota-change-$_o1');
      await enter(tester, 'rota-edit-topic-$_o1', 'SYNTHETIC Hope');
      await tapKey(tester, 'rota-edit-save-$_o1');
      h.gateway.sent.single.confirm(const {'change': 'reference'}, 2);
      await settle(tester);
      expect(byKey('duties-notice-referenceUpdated'), findsOneWidget);
    });

    testWidgets('Pastor oversight is read only', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.dutyRota,
        setUp: (h) =>
            h.duties.rota = rotaWith([occurrence(_o1)], canManage: false),
      );
      expect(find.text('Pastor oversight (read only)'), findsOneWidget);
      expect(byKey('rota-publish-$_series'), findsNothing);
      expect(byKey('rota-new-$_dept'), findsNothing);
      await tapKey(tester, 'rota-date-$_o1');
      expect(byKey('rota-change-$_o1'), findsNothing);
      expect(byKey('rota-pick-${_slot(_o1, 1)}'), findsNothing);
    });

    testWidgets('a member without a department scope sees nothing', (
      tester,
    ) async {
      await pumpAt(tester, ClientPaths.dutyRota);
      expect(byKey('duties-denied-notGranted'), findsOneWidget);
      expect(byKey('rota-grid-$_series'), findsNothing);
    });

    testWidgets('a new rota is generated as drafts', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.dutyRota,
        setUp: (h) => h.duties.rota = rotaWith(const []),
      );
      await tapKey(tester, 'rota-new-$_dept');
      expect(enabled(tester, 'series-create-$_dept'), isFalse);
      await enter(tester, 'series-name-$_dept', 'Sunday service');
      await enter(tester, 'series-from-$_dept', '2099-01-04');
      await enter(tester, 'series-until-$_dept', '2099-03-29');
      await enter(tester, 'series-start-$_dept', '10:00');
      await enter(tester, 'series-positions-$_dept', 'Preacher, Reader, Usher');
      await tapKey(tester, 'series-create-$_dept');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'duties.create_series');
      expect(sent.wire['expected_revision'], isNull);
      expect(sent.wire['payload'], {
        'department_id': _dept,
        'duty_name': 'Sunday service',
        'every': 'week',
        'from_date': '2099-01-04',
        'until_date': '2099-03-29',
        'start_time': '10:00',
        'positions': ['Preacher', 'Reader', 'Usher'],
      });
      sent.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'until_date': 'too_many'},
      );
      await settle(tester);
      expect(
        find.text('At most 60 dates: choose an earlier end date'),
        findsOneWidget,
      );
    });
  });

  testWidgets('mobile: a rota position shows its name, topic and scripture', (
    tester,
  ) async {
    await pumpAt(
      tester,
      ClientPaths.myDuties,
      setUp: (h) => h.duties.mine = AccessReadOk(
        MyDuties.fromJson({
          'member_id': _ruth,
          'assignments': [
            {
              ...myDutyData(),
              'position_name': 'Preacher',
              'topic': 'SYNTHETIC Hope',
              'scripture': 'Psalm 23',
            },
          ],
        }),
      ),
    );
    expect(find.text('Sunday preaching: Preacher'), findsOneWidget);
    expect(find.text('Topic: SYNTHETIC Hope'), findsOneWidget);
    expect(find.text('Scripture: Psalm 23'), findsOneWidget);
  });
}
