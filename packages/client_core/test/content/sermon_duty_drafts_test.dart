// Story 6.18: a preaching duty's topic and scripture sent to Media as a
// sermon draft. Wire parsing (the status read, the editors' from_duty mark),
// the mobile duty detail (the assignee sends; sent, already sent, refused,
// unconfirmed and failed states; no section without a topic, for a cell part
// or after declining), the staff rota (a manager sends) and the staff sermon
// list and editor (marked as from a duty). Fakes only; the server behaviour
// is covered by supabase/tests/content_sermon_duty_drafts_test.sql and
// tools/identity-e2e/content-sermon-duty-drafts.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../duties/duties_rota_test.dart'
    show assignment, byKey, occurrence, position, rotaWith, settle;

const _asg = '42424242-4242-4242-8242-424242424242';
const _occ = '43434343-4343-4343-8343-434343434343';
const _o1 = '51515151-5151-4151-8151-515151515151';
const _sermon = 'a4a4a4a4-a4a4-44a4-84a4-a4a4a4a4a4a4';

Future<ClientTestHarness> _pumpAt(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? setUp,
  bool staff = false,
}) async {
  tester.view.physicalSize = Size(staff ? 1400 : 390, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = ClientTestHarness();
  setUp?.call(h);
  final router = buildClientRouter(
    initialLocation: location,
    memberHome: !staff,
    shell: (_, _, child) => AccessRefresher(child: child),
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: h.overrides(),
      child: MaterialApp.router(
        theme: staff ? churchStaffTheme() : churchMobileTheme(Brightness.light),
        routerConfig: router,
      ),
    ),
  );
  await settle(tester);
  return h;
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(byKey(key));
  await tester.tap(byKey(key));
  await settle(tester);
}

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(byKey(key)).data!;

AccessRead<DutySermonDraft> _status({
  bool canSend = true,
  String? sentAt,
  bool published = false,
  String occurrenceId = _occ,
}) => AccessReadOk(
  DutySermonDraft.fromJson({
    'occurrence_id': occurrenceId,
    'can_send': canSend,
    'draft': sentAt == null
        ? null
        : {'sent_at': sentAt, 'published': published},
  }),
);

void _mine(
  ClientTestHarness h, {
  String? topic = 'SYNTHETIC Walking in the light',
  String? scripture = 'SYNTHETIC 1 John 1:5-10',
  String ownerKind = 'department',
  String response = 'pending',
}) => h.duties.mine = AccessReadOk(
  MyDuties.fromJson({
    'member_id': '66666666-6666-4666-8666-666666666666',
    'assignments': [
      {
        ...myDutyData(
          response: response,
          ownerKind: ownerKind,
          respondedAt: response == 'pending' ? null : '2098-12-30T08:00:00Z',
        ),
        'topic': topic,
        'scripture': scripture,
      },
    ],
  }),
);

void main() {
  group('wire', () {
    test('the status read is strict and says when it was sent', () {
      final none = _status() as AccessReadOk<DutySermonDraft>;
      expect(none.value.sent, isFalse);
      expect(none.value.canSend, isTrue);
      final sent = _status(
        sentAt: '2099-01-01T08:00:00Z',
        published: true,
      ) as AccessReadOk<DutySermonDraft>;
      expect(sent.value.sent, isTrue);
      expect(sent.value.published, isTrue);
      expect(
        () => DutySermonDraft.fromJson({
          'occurrence_id': _occ,
          'can_send': true,
          'draft': null,
          'topic': 'x',
        }),
        throwsFormatException,
      );
      expect(
        () => DutySermonDraft.fromJson({
          'occurrence_id': _occ,
          'can_send': true,
          'draft': {'sent_at': '2099-01-01T08:00:00Z'},
        }),
        throwsFormatException,
      );
    });

    test(
      'an editor\'s sermon carries where it came from, never who sent it',
      () {
        final d = SermonFromDuty.fromJson({
          'duty_name': 'SYNTHETIC Sunday preaching',
          'duty_starts_at': '2099-01-04T07:00:00Z',
          'sent_at': '2099-01-01T08:00:00Z',
        });
        expect(d.dutyName, 'SYNTHETIC Sunday preaching');
        expect(fromDutyLine(d), startsWith('From a duty: SYNTHETIC Sunday'));
        expect(
          () => SermonFromDuty.fromJson({
            'duty_name': 'x',
            'duty_starts_at': '2099-01-04T07:00:00Z',
            'sent_at': '2099-01-01T08:00:00Z',
            'sent_by': 'SYNTHETIC Member',
          }),
          throwsFormatException,
        );
      },
    );
  });

  group('mobile duty detail', () {
    testWidgets('the assignee sends the topic and scripture to Media', (
      tester,
    ) async {
      final h = await _pumpAt(
        tester,
        DutyPaths.assignment(_asg),
        setUp: (h) {
          _mine(h);
          h.sermons.dutyDrafts[_occ] = _status();
        },
      );
      expect(h.sermons.dutyDraftCalls, [_occ]);
      expect(find.text('Sermon'), findsOneWidget);
      await _tap(tester, 'duty-sermon-$_occ-send');
      final sent = h.gateway.sent.single;
      expect(sent.function, ContentCommands.function);
      expect(sent.request.command, SermonCommands.draftFromDuty);
      expect(sent.request.payload, {'occurrence_id': _occ});
      expect(sent.wire['expected_revision'], isNull);
      h.sermons.dutyDrafts[_occ] = _status(sentAt: '2099-01-01T08:00:00Z');
      sent.confirm({
        'occurrence_id': _occ,
        'sermon_id': _sermon,
        'created': true,
        'sent_at': '2099-01-01T08:00:00Z',
      }, 1);
      await settle(tester);
      expect(
        _text(tester, 'duty-sermon-$_occ-notice'),
        'Sent. Media will prepare the sermon.',
      );
      expect(
        _text(tester, 'duty-sermon-$_occ-sent'),
        allOf(startsWith('Sent to Media on '), endsWith('publishes it.')),
      );
      expect(byKey('duty-sermon-$_occ-send'), findsNothing);
    });

    testWidgets('a second send says Media already has it', (tester) async {
      final h = await _pumpAt(
        tester,
        DutyPaths.assignment(_asg),
        setUp: (h) {
          _mine(h);
          h.sermons.dutyDrafts[_occ] = _status();
        },
      );
      await _tap(tester, 'duty-sermon-$_occ-send');
      h.sermons.dutyDrafts[_occ] = _status(sentAt: '2099-01-01T08:00:00Z');
      h.gateway.sent.single.confirm({'created': false}, 1);
      await settle(tester);
      expect(
        _text(tester, 'duty-sermon-$_occ-notice'),
        'Media already has this duty\'s sermon draft.',
      );
    });

    testWidgets('a refusal and an unconfirmed send are honest', (tester) async {
      final h = await _pumpAt(
        tester,
        DutyPaths.assignment(_asg),
        setUp: (h) {
          _mine(h);
          h.sermons.dutyDrafts[_occ] = _status();
        },
      );
      await _tap(tester, 'duty-sermon-$_occ-send');
      h.gateway.sent.single.unknown();
      await settle(tester);
      expect(
        _text(tester, 'duty-sermon-$_occ-notice'),
        'We could not confirm it was sent. Check again.',
      );
      expect(find.text('Check again'), findsOneWidget);
      final first = h.gateway.sent.single.request.requestId;
      await _tap(tester, 'duty-sermon-$_occ-send');
      expect(h.gateway.sent.last.request.requestId, first, reason: 'resent');
      h.gateway.sent.last.refuse(ErrorCode.notFound);
      await settle(tester);
      expect(
        _text(tester, 'duty-sermon-$_occ-notice'),
        'Only the person on this duty or its leaders can send it.',
      );
    });

    testWidgets('published by Media, and a failed read, say so', (
      tester,
    ) async {
      await _pumpAt(
        tester,
        DutyPaths.assignment(_asg),
        setUp: (h) {
          _mine(h);
          h.sermons.dutyDrafts[_occ] = _status(
            sentAt: '2099-01-01T08:00:00Z',
            published: true,
          );
        },
      );
      expect(
        _text(tester, 'duty-sermon-$_occ-sent'),
        endsWith('Media has published the sermon.'),
      );
    });

    testWidgets('a failed read never looks like nothing to send', (
      tester,
    ) async {
      final h = await _pumpAt(
        tester,
        DutyPaths.assignment(_asg),
        setUp: (h) {
          _mine(h);
          h.sermons.dutyDrafts[_occ] = const AccessReadFailed(
            unreachable: true,
          );
        },
      );
      expect(byKey('duty-sermon-$_occ-failed'), findsOneWidget);
      h.sermons.dutyDrafts[_occ] = _status();
      await _tap(tester, 'duty-sermon-$_occ-retry');
      expect(byKey('duty-sermon-$_occ-send'), findsOneWidget);
    });

    testWidgets('no section without a topic, for a cell part or declined', (
      tester,
    ) async {
      for (final setUp in <void Function(ClientTestHarness)>[
        (h) => _mine(h, topic: null, scripture: null),
        (h) => _mine(h, ownerKind: 'cell'),
        (h) => _mine(h, response: 'declined'),
      ]) {
        final h = await _pumpAt(
          tester,
          DutyPaths.assignment(_asg),
          setUp: (h) {
            setUp(h);
            h.sermons.dutyDrafts[_occ] = _status();
          },
        );
        expect(byKey('duty-sermon-$_occ'), findsNothing);
        expect(h.sermons.dutyDraftCalls, isEmpty);
      }
    });

    testWidgets('a refused read (no longer the assignee) shows nothing', (
      tester,
    ) async {
      await _pumpAt(tester, DutyPaths.assignment(_asg), setUp: (h) => _mine(h));
      expect(byKey('duty-sermon-$_occ'), findsNothing);
      expect(find.text('Sermon'), findsNothing);
    });
  });

  group('staff web rota', () {
    Map<String, Object?> date({String? topic = 'SYNTHETIC Topic'}) => {
      ...occurrence(
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
      'topic': topic,
    };

    testWidgets('a manager sends a date with a topic to Media', (tester) async {
      final h = await _pumpAt(
        tester,
        ClientPaths.dutyRota,
        staff: true,
        setUp: (h) {
          h.duties.rota = rotaWith(draftSlots: 0, revision: 3, [date()]);
          h.sermons.dutyDrafts[_o1] = _status(occurrenceId: _o1);
        },
      );
      await _tap(tester, 'rota-date-$_o1');
      await _tap(tester, 'rota-sermon-$_o1-send');
      expect(
        h.gateway.sent.single.request.command,
        'content.draft_sermon_from_duty',
      );
      expect(h.gateway.sent.single.request.payload, {'occurrence_id': _o1});
    });

    testWidgets('a date without a topic offers nothing', (tester) async {
      final h = await _pumpAt(
        tester,
        ClientPaths.dutyRota,
        staff: true,
        setUp: (h) {
          h.duties.rota = rotaWith(draftSlots: 0, [date(topic: null)]);
          h.sermons.dutyDrafts[_o1] = _status(occurrenceId: _o1);
        },
      );
      await _tap(tester, 'rota-date-$_o1');
      expect(byKey('rota-sermon-$_o1'), findsNothing);
      expect(h.sermons.dutyDraftCalls, isEmpty);
    });
  });

  group('staff web sermons', () {
    Map<String, Object?> revision() => {
      'revision_no': 1,
      'title': 'SYNTHETIC Walking in the light',
      'speaker': '',
      'sermon_date': '2099-01-04',
      'scripture_reference': 'SYNTHETIC 1 John 1:5-10',
      'notes': '',
      'series_id': null,
      'youtube_video_id': null,
      'facebook_video_url': null,
      'video_rights': null,
      'saved_at': '2099-01-01T08:00:00Z',
      'saved_by': 'SYNTHETIC Member',
    };
    AccessRead<StaffSermons> staff() => AccessReadOk(
      StaffSermons.fromJson({
        'capacity': 'media',
        'sermons': [
          {
            'sermon_id': _sermon,
            'revision': 1,
            'state': 'draft',
            'created_at': '2099-01-01T08:00:00Z',
            'created_by': 'SYNTHETIC Member',
            'updated_at': '2099-01-01T08:00:00Z',
            'published_at': null,
            'published_by': null,
            'withdrawn_at': null,
            'archived_at': null,
            'live': null,
            'draft': revision(),
            'from_duty': {
              'duty_name': 'SYNTHETIC Sunday preaching',
              'duty_starts_at': '2099-01-04T07:00:00Z',
              'sent_at': '2099-01-01T08:00:00Z',
            },
          },
        ],
        'truncated': false,
      }),
    );

    testWidgets('a draft from a duty is marked in the list and the editor', (
      tester,
    ) async {
      await _pumpAt(
        tester,
        SermonPaths.staff,
        staff: true,
        setUp: (h) => h.sermons.staff = staff(),
      );
      expect(byKey('sermon-section-waiting'), findsOneWidget);
      expect(
        _text(tester, 'sermon-from-duty-$_sermon'),
        startsWith('From a duty: SYNTHETIC Sunday preaching, '),
      );
      expect(find.textContaining('Speaker not added'), findsOneWidget);
      await _tap(tester, 'sermon-edit-$_sermon');
      expect(
        _text(tester, 'sermon-form-from-duty'),
        allOf(
          startsWith('From a duty: SYNTHETIC Sunday preaching'),
          endsWith('Nothing is public until you do.'),
        ),
      );
    });
  });
}
