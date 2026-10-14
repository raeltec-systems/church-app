// Story 3.7: inbox markers, the refresh signal, snooze, notification settings
// and the SYNTHETIC test reminders on both clients (shared client_core). Fakes
// and a mock HTTP client only; the server behaviour is covered by
// supabase/tests/notifications_inbox_screens_test.sql and
// tools/identity-e2e/inbox-screens.mjs (real Realtime signal capture).
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

const _item = '31313131-3131-4131-8131-313131313131';
const _other = '32323232-3232-4232-8232-323232323232';
const _source = '41414141-4141-4141-8141-414141414141';
const _account = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

Finder byKey(String k) => find.byKey(Key(k));

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? setUp,
  ClientTestHarness? harness,
}) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = harness ?? ClientTestHarness();
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
        theme: churchMobileTheme(Brightness.light),
        routerConfig: router,
      ),
    ),
  );
  await settle(tester);
  return h;
}

AccessRead<OpenedInboxItem> current({
  List<String> choices = const ['1 hour', '24 hours', '2 days'],
  String? snoozedUntil,
}) => AccessReadOk(
  OpenedInboxItem.fromJson(
    openedItemData(snoozeChoices: choices, snoozedUntil: snoozedUntil),
  ),
);

SentCommand lastCommand(ClientTestHarness h, String command) =>
    h.gateway.sent.lastWhere((s) => s.wire['command'] == command);

void main() {
  group('mapping', () {
    test('items carry the opened marker and the snooze, nothing else', () {
      final item = InboxItem.fromJson(
        inboxItemData(
          opened: false,
          snoozedUntil: '2026-10-09T07:00:00.000000Z',
        ),
      );
      expect(item.opened, isFalse);
      expect(item.snoozedUntil, DateTime.utc(2026, 10, 9, 7));
      expect(InboxItem.fromJson(inboxItemData()).opened, isNull);
      expect(
        () => InboxItem.fromJson({...inboxItemData(), 'opened': 'yes'}),
        throwsFormatException,
      );
      expect(
        () => InboxItem.fromJson({
          ...inboxItemData(),
          'snoozed_until': '2026-10-09 07:00',
        }),
        throwsFormatException,
      );
    });

    test('a current item carries the policy snooze choices', () {
      final opened = (current() as AccessReadOk<OpenedInboxItem>).value;
      expect(opened.snoozeChoices, ['1 hour', '24 hours', '2 days']);
      expect(OpenedInboxItem.fromJson(openedItemData()).snoozeChoices, isEmpty);
      expect(
        () => OpenedInboxItem.fromJson({
          ...openedItemData(),
          'snooze_choices': ['soon'],
        }),
        throwsFormatException,
      );
    });

    test('a snooze answer says when, and whether it was clamped', () {
      final s = SnoozeConfirmation.fromJson({
        'item_id': _item,
        'scheduled_at': '2026-10-09T03:00:00Z',
        'clamped': true,
        'expires_at': '2026-10-09T03:00:00Z',
      });
      expect(s.clamped, isTrue);
      expect(s.scheduledAt, DateTime.utc(2026, 10, 9, 3));
      expect(
        () => SnoozeConfirmation.fromJson({'scheduled_at': 'x'}),
        throwsFormatException,
      );
    });

    test('settings map categories and count live devices, never tokens', () {
      final s = NotificationSettings.fromJson({
        'categories': [
          pushCategoryData(),
          pushCategoryData(
            kind: 'fixture_reply',
            pushEnabled: false,
            revision: 2,
          ),
        ],
        'devices': [
          {'device_id': _other, 'platform': 'android', 'retired': false},
        ],
      });
      expect(s.categories, hasLength(2));
      expect(s.categories.first.revision, isNull);
      expect(s.categories.last.pushEnabled, isFalse);
      expect(s.liveDevices, 1);
      expect(
        () => NotificationSettings.fromJson({'categories': 'x'}),
        throwsFormatException,
      );
    });
  });

  group('inbox list (both clients)', () {
    testWidgets('markers say only what the member did in the app', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.inbox,
        setUp: (h) => h.inbox.inbox = AccessReadOk(
          Inbox.fromJson({
            'items': [
              inboxItemData(opened: false),
              inboxItemData(
                id: _other,
                opened: true,
                snoozedUntil: '2026-10-09T07:00:00.000000Z',
              ),
            ],
          }),
        ),
      );
      expect(byKey('inbox-item-new-$_item'), findsOneWidget);
      expect(byKey('inbox-item-opened-$_other'), findsOneWidget);
      expect(byKey('inbox-item-snoozed-$_other'), findsOneWidget);
      expect(byKey('inbox-item-new-$_other'), findsNothing);
      for (final claim in ['Delivered', 'Read', 'Seen', 'Sent']) {
        expect(find.textContaining(claim), findsNothing);
      }
    });

    testWidgets('the server signal re-reads the open inbox', (tester) async {
      final h = await pumpAt(tester, ClientPaths.inbox);
      expect(h.signals.subscribed, [_account]);
      expect(h.signals.listening, 1);
      final before = h.inbox.calls;
      h.signals.signal();
      await settle(tester);
      expect(h.inbox.calls, before + 1);
    });

    testWidgets('without signals it still re-reads every 2 minutes', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.inbox);
      final before = h.inbox.calls;
      await tester.pump(inboxPollInterval);
      await settle(tester);
      expect(h.inbox.calls, before + 1);
    });

    testWidgets('pull to refresh asks the server again', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.inbox,
        setUp: (h) => h.inbox.inbox = AccessReadOk(
          Inbox.fromJson({
            'items': [inboxItemData()],
          }),
        ),
      );
      final before = h.inbox.calls;
      await tester.fling(byKey('inbox-count'), const Offset(0, 400), 1000);
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(h.inbox.calls, greaterThan(before));
    });

    testWidgets('an account change leaves the old channel for the new one', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.inbox);
      h.session.switchTo('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
      await settle(tester);
      expect(h.signals.subscribed.last, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
      expect(h.signals.listening, 1);
      h.session.switchTo(null);
      await settle(tester);
      expect(h.signals.listening, 0);
    });

    Inbox page(List<String> ids, {String? nextAfter}) => Inbox.fromJson({
      'items': [for (final id in ids) inboxItemData(id: id)],
      'next': nextAfter == null
          ? null
          : {
              'after_delivered_at': '2026-10-08T07:00:05.000000Z',
              'after_item_id': nextAfter,
            },
    });
    const newer = '30303030-3030-4030-8030-303030303030';
    const older = '29292929-2929-4929-8929-292929292929';

    testWidgets('a refresh after Show older keeps the older pages', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.inbox,
        setUp: (h) {
          h.inbox.inbox = AccessReadOk(page([_item], nextAfter: _item));
          h.inbox.olderPages[_item] = AccessReadOk(page([older]));
        },
      );
      await tester.tap(byKey('inbox-older'));
      await settle(tester);
      expect(byKey('inbox-item-$older'), findsOneWidget);
      h.inbox.inbox = AccessReadOk(page([newer, _item], nextAfter: _item));
      h.signals.signal();
      await settle(tester);
      expect(byKey('inbox-item-$newer'), findsOneWidget);
      expect(byKey('inbox-item-$_item'), findsOneWidget);
      expect(byKey('inbox-item-$older'), findsOneWidget);
    });

    testWidgets('a signal while older reminders load is not lost', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.inbox,
        setUp: (h) {
          h.inbox.inbox = AccessReadOk(page([_item], nextAfter: _item));
          h.inbox.olderPages[_item] = AccessReadOk(page([older]));
          h.inbox.holdOlder = Completer<void>();
        },
      );
      await tester.tap(byKey('inbox-older'));
      await tester.pump();
      final before = h.inbox.calls;
      h.inbox.inbox = AccessReadOk(page([newer, _item], nextAfter: _item));
      h.signals.signal();
      await tester.pump();
      expect(h.inbox.calls, before, reason: 'held while older loads');
      h.inbox.holdOlder!.complete();
      await settle(tester);
      expect(h.inbox.calls, before + 1);
      expect(byKey('inbox-item-$newer'), findsOneWidget);
      expect(byKey('inbox-item-$older'), findsOneWidget);
    });

    testWidgets('in the background the channel and poll stop; back, it '
        're-reads', (tester) async {
      final h = await pumpAt(tester, ClientPaths.inbox);
      expect(h.signals.listening, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await settle(tester);
      expect(h.signals.listening, 0);
      final before = h.inbox.calls;
      await tester.pump(inboxPollInterval);
      expect(h.inbox.calls, before, reason: 'no poll in the background');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      expect(h.signals.listening, 1);
      expect(h.inbox.calls, greaterThan(before));
    });

    testWidgets('a failed background poll keeps the list and says so', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.inbox,
        setUp: (h) => h.inbox.inbox = AccessReadOk(page([_item])),
      );
      h.inbox.inbox = const AccessReadFailed(unreachable: true);
      await tester.pump(inboxPollInterval);
      await settle(tester);
      expect(byKey('inbox-item-$_item'), findsOneWidget);
      expect(byKey('inbox-refresh-failed'), findsOneWidget);
      expect(byKey('inbox-failed'), findsNothing);
      h.inbox.inbox = AccessReadOk(page([_item]));
      await tester.tap(byKey('refresh-inbox'));
      await settle(tester);
      expect(byKey('inbox-refresh-failed'), findsNothing);
    });

    testWidgets('a failure is recoverable with Check again', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.inbox,
        setUp: (h) => h.inbox.inbox = const AccessReadFailed(unreachable: true),
      );
      expect(byKey('inbox-failed'), findsOneWidget);
      h.inbox.inbox = const AccessReadOk(Inbox(items: []));
      await tester.tap(byKey('refresh-inbox'));
      await settle(tester);
      expect(byKey('inbox-empty'), findsOneWidget);
    });

    testWidgets('the inbox links to notification settings', (tester) async {
      await pumpAt(tester, ClientPaths.inbox);
      await tester.tap(byKey('open-notification-settings'));
      await settle(tester);
      expect(byKey('notification-settings-intro'), findsOneWidget);
    });
  });

  group('snooze', () {
    Future<ClientTestHarness> openItem(WidgetTester tester) => pumpAt(
      tester,
      ClientPaths.inboxItem(_item),
      setUp: (h) => h.inbox.opened[_item] = current(),
    );

    testWidgets('offers the policy choices and sends the member command', (
      tester,
    ) async {
      final h = await openItem(tester);
      expect(byKey('snooze-1-hour'), findsOneWidget);
      expect(byKey('snooze-24-hours'), findsOneWidget);
      expect(byKey('snooze-2-days'), findsOneWidget);
      await tester.tap(byKey('snooze-24-hours'));
      await tester.pump();
      final sent = lastCommand(h, 'notifications.snooze_item');
      expect(sent.function, 'notifications_command');
      expect(sent.wire.containsKey('expected_revision'), isFalse);
      expect(sent.wire['payload'], {'item_id': _item, 'choice': '24 hours'});
      expect(byKey('snooze-sending'), findsOneWidget);
      h.inbox.opened[_item] = current(snoozedUntil: '2026-10-09T07:00:00Z');
      sent.confirm({
        'item_id': _item,
        'scheduled_at': '2026-10-09T07:00:00Z',
        'clamped': false,
        'expires_at': null,
      }, 2);
      await settle(tester);
      expect(byKey('snooze-confirmed'), findsOneWidget);
      expect(byKey('inbox-item-snoozed-until'), findsOneWidget);
      expect(h.inbox.openedIds.length, greaterThanOrEqualTo(2));
    });

    testWidgets('a snooze past the end is clamped and says so', (tester) async {
      final h = await openItem(tester);
      await tester.tap(byKey('snooze-2-days'));
      await tester.pump();
      lastCommand(h, 'notifications.snooze_item').confirm({
        'item_id': _item,
        'scheduled_at': '2026-10-09T03:00:00Z',
        'clamped': true,
        'expires_at': '2026-10-09T03:00:00Z',
      }, 2);
      await settle(tester);
      expect(byKey('snooze-clamped'), findsOneWidget);
      expect(find.textContaining('stops mattering'), findsOneWidget);
    });

    testWidgets('an answered or cancelled source cannot be snoozed', (
      tester,
    ) async {
      final h = await openItem(tester);
      await tester.tap(byKey('snooze-1-hour'));
      await tester.pump();
      h.inbox.opened[_item] = AccessReadOk(
        OpenedInboxItem.fromJson(
          openedItemData(state: 'superseded', target: null),
        ),
      );
      lastCommand(
        h,
        'notifications.snooze_item',
      ).refuse(ErrorCode.conflict, fieldErrors: {'item_id': 'superseded'});
      await settle(tester);
      expect(byKey('snooze-out-of-date'), findsOneWidget);
      expect(byKey('inbox-item-superseded'), findsOneWidget);
      expect(byKey('inbox-item-snooze'), findsNothing);
    });

    testWidgets('an expired reminder says it ended', (tester) async {
      final h = await openItem(tester);
      await tester.tap(byKey('snooze-1-hour'));
      await tester.pump();
      lastCommand(
        h,
        'notifications.snooze_item',
      ).refuse(ErrorCode.conflict, fieldErrors: {'item_id': 'expired'});
      await settle(tester);
      expect(byKey('snooze-expired'), findsOneWidget);
    });

    testWidgets('an unknown outcome resends the identical request', (
      tester,
    ) async {
      final h = await openItem(tester);
      await tester.tap(byKey('snooze-1-hour'));
      await tester.pump();
      final first = lastCommand(h, 'notifications.snooze_item');
      first.unknown();
      await settle(tester);
      expect(byKey('snooze-unknown'), findsOneWidget);
      await tester.tap(byKey('snooze-retry'));
      await tester.pump();
      final second = lastCommand(h, 'notifications.snooze_item');
      expect(identical(first, second), isFalse);
      expect(second.wire, first.wire);
    });

    testWidgets('no choices from the policy: no snooze offered', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.inboxItem(_item),
        setUp: (h) => h.inbox.opened[_item] = current(choices: const []),
      );
      expect(byKey('inbox-item-title'), findsOneWidget);
      expect(byKey('inbox-item-snooze'), findsNothing);
    });

    testWidgets('the fixture link is followed to its test source', (
      tester,
    ) async {
      await openItem(tester);
      await tester.tap(byKey('inbox-item-open-target'));
      await settle(tester);
      expect(byKey('fixture-reminder-source'), findsOneWidget);
    });
  });

  group('notification settings (both clients)', () {
    Future<ClientTestHarness> openSettings(
      WidgetTester tester, {
      int? revision,
    }) => pumpAt(
      tester,
      ClientPaths.notificationSettings,
      setUp: (h) => h.notificationSettings.settings = AccessReadOk(
        NotificationSettings.fromJson({
          'categories': [pushCategoryData(revision: revision)],
          'devices': [],
        }),
      ),
    );

    testWidgets('turning a category off says the inbox keeps it', (
      tester,
    ) async {
      final h = await openSettings(tester);
      expect(find.textContaining('Phone notifications on'), findsOneWidget);
      await tester.tap(byKey('push-category-fixture_reminder-fixture_due'));
      await tester.pump();
      final sent = lastCommand(h, 'notifications.set_push_category');
      expect(sent.wire.containsKey('expected_revision'), isFalse);
      expect(sent.wire['payload'], {
        'source_type': 'fixture_reminder',
        'reminder_kind': 'fixture_due',
        'push_enabled': false,
      });
      h.notificationSettings.settings = AccessReadOk(
        NotificationSettings.fromJson({
          'categories': [pushCategoryData(pushEnabled: false, revision: 1)],
        }),
      );
      sent.confirm({'push_enabled': false}, 1);
      await settle(tester);
      expect(byKey('push-setting-saved'), findsOneWidget);
      expect(find.textContaining('Still in your Inbox'), findsOneWidget);
    });

    testWidgets('an existing setting changes at its revision; a conflict '
        'reloads', (tester) async {
      final h = await openSettings(tester, revision: 3);
      await tester.tap(byKey('push-category-fixture_reminder-fixture_due'));
      await tester.pump();
      final sent = lastCommand(h, 'notifications.set_push_category');
      expect(sent.wire['expected_revision'], 3);
      final reads = h.notificationSettings.calls;
      sent.refuse(ErrorCode.conflict, currentRevision: const Optional.of(4));
      await settle(tester);
      expect(byKey('push-setting-changed-elsewhere'), findsOneWidget);
      expect(h.notificationSettings.calls, reads + 1);
    });

    testWidgets('an unknown outcome resends the identical request', (
      tester,
    ) async {
      final h = await openSettings(tester);
      await tester.tap(byKey('push-category-fixture_reminder-fixture_due'));
      await tester.pump();
      final first = lastCommand(h, 'notifications.set_push_category');
      first.unknown();
      await settle(tester);
      await tester.tap(byKey('push-setting-retry'));
      await tester.pump();
      expect(
        lastCommand(h, 'notifications.set_push_category').wire,
        first.wire,
      );
    });

    testWidgets('a failed read is recoverable', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.notificationSettings,
        setUp: (h) => h.notificationSettings.settings = const AccessReadFailed(
          unreachable: true,
        ),
      );
      expect(byKey('notification-settings-failed'), findsOneWidget);
      h.notificationSettings.settings = AccessReadOk(
        NotificationSettings.fromJson({
          'categories': [pushCategoryData()],
        }),
      );
      await tester.tap(byKey('refresh-notification-settings'));
      await settle(tester);
      expect(
        byKey('push-category-fixture_reminder-fixture_due'),
        findsOneWidget,
      );
    });
  });

  group('SYNTHETIC test reminders', () {
    testWidgets('create a reminder due now and a request', (tester) async {
      final h = await pumpAt(tester, ClientPaths.fixtureReminders);
      await tester.tap(byKey('fixture-reminder-create-due'));
      await tester.pump();
      final due = lastCommand(h, 'fixture.reminder_create');
      expect(due.function, 'fixture_reminder_command');
      expect((due.wire['payload'] as Map).keys, ['due_at']);
      due.confirm({
        'source_id': _source,
        'reminder_kind': 'fixture_due',
        'state': 'active',
      }, 1);
      await settle(tester);
      expect(byKey('fixture-reminder-done'), findsOneWidget);
      await tester.tap(byKey('fixture-reminder-create-request'));
      await tester.pump();
      final request = lastCommand(h, 'fixture.reminder_schedule');
      final startsAt = DateTime.parse(
        (request.wire['payload'] as Map)['starts_at'] as String,
      );
      expect(startsAt.isUtc, isTrue);
      expect(
        startsAt.difference(DateTime.now()).inHours,
        inInclusiveRange(19, 20),
      );
      request.confirm({
        'source_id': _source,
        'reminder_kind': 'fixture_reply',
        'state': 'active',
      }, 1);
      await settle(tester);
      await tester.tap(byKey('fixture-reminder-respond'));
      await tester.pump();
      final respond = lastCommand(h, 'fixture.reminder_respond');
      expect(respond.wire['expected_revision'], 1);
      expect(respond.wire['payload'], {'source_id': _source});
    });

    testWidgets('from a link, a changed source is retried at its revision', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.fixtureReminder(_source));
      await tester.tap(byKey('fixture-reminder-cancel'));
      await tester.pump();
      lastCommand(
        h,
        'fixture.reminder_cancel',
      ).refuse(ErrorCode.conflict, currentRevision: const Optional.of(2));
      await settle(tester);
      expect(byKey('fixture-reminder-changed'), findsOneWidget);
      await tester.tap(byKey('fixture-reminder-cancel'));
      await tester.pump();
      expect(
        lastCommand(h, 'fixture.reminder_cancel').wire['expected_revision'],
        2,
      );
    });
  });

  group('Supabase adapters', () {
    test('settings post to api.notifications_my_push_settings', () async {
      final sent = <http.Request>[];
      final client = SupabaseClient(
        'http://localhost:54321',
        'sb_publishable_test',
        httpClient: MockClient((r) async {
          sent.add(r);
          if (r.url.path.startsWith('/auth/')) {
            return http.Response(
              jsonEncode(_session()),
              200,
              headers: {'content-type': 'application/json'},
              request: r,
            );
          }
          return http.Response(
            jsonEncode({
              'categories': [pushCategoryData()],
              'devices': [],
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: r,
          );
        }),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);
      final repo = SupabaseNotificationSettingsRepository(client);
      expect(
        await repo.fetchMySettings(),
        isA<AccessReadDenied<NotificationSettings>>(),
      );
      expect(sent, isEmpty);
      await client.auth.signInWithPassword(
        phone: '+447700900820',
        password: 'p',
      );
      final out = await repo.fetchMySettings();
      expect(out, isA<AccessReadOk<NotificationSettings>>());
      expect(sent.last.url.path, '/rest/v1/rpc/notifications_my_push_settings');
      expect(sent.last.headers['Content-Profile'], 'api');
    });
  });
}

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

const _sub = '11111111-1111-4111-8111-111111111111';

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
    'phone': '447700900820',
    'app_metadata': <String, Object?>{},
    'user_metadata': <String, Object?>{},
    'created_at': '2026-10-08T07:00:00Z',
  },
};
