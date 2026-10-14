// Story 3.2: opening one inbox item on both clients (mapping of
// api.notifications_open_item, the shared item screen and the Supabase
// adapter). Fakes and a mock HTTP client only; the server behaviour is
// covered by supabase/tests/notifications_source_contracts_test.sql and
// tools/identity-e2e/source-contracts.mjs.
import 'dart:convert';

import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/supabase_adapters.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

const _item = '31313131-3131-4131-8131-313131313131';
const _target = '/fixture/reminders/41414141-4141-4141-8141-414141414141';

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder byKey(String k) => find.byKey(Key(k));

/// The shared client router at [location], or a minimal router whose item
/// screen knows [knownTarget] (to prove the Open path).
Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? setUp,
  bool Function(String)? knownTarget,
}) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = ClientTestHarness();
  setUp?.call(h);
  final router = knownTarget == null
      ? buildClientRouter(
          initialLocation: location,
          shell: (_, _, child) => AccessRefresher(child: child),
        )
      : GoRouter(
          initialLocation: location,
          routes: [
            GoRoute(
              path: '/inbox/:itemId',
              builder: (_, state) => InboxItemScreen(
                itemId: state.pathParameters['itemId']!,
                knownTarget: knownTarget,
              ),
            ),
            GoRoute(
              path: '/fixture/reminders/:id',
              builder: (_, _) => const Text('target screen'),
            ),
          ],
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
    'phone': '447700900822',
    'app_metadata': <String, Object?>{},
    'user_metadata': <String, Object?>{},
    'created_at': '2026-10-08T07:00:00Z',
  },
};

void main() {
  group('opened item mapping', () {
    test('a current item carries its in-app target', () {
      final o = OpenedInboxItem.fromJson(openedItemData());
      expect(o.state, InboxItemState.current);
      expect(o.target, _target);
      expect(o.item?.title, 'SYNTHETIC test reminder');
      expect(o.item?.body, 'A test reminder is waiting for you.');
    });

    test('a superseded item has no target', () {
      final o = OpenedInboxItem.fromJson(
        openedItemData(state: 'superseded', target: null),
      );
      expect(o.state, InboxItemState.superseded);
      expect(o.target, isNull);
      expect(o.item?.itemId, _item);
    });

    test('not found carries nothing else', () {
      final o = OpenedInboxItem.fromJson({'state': 'not_found'});
      expect(o.state, InboxItemState.notFound);
      expect(o.item, isNull);
      expect(
        () =>
            OpenedInboxItem.fromJson({'state': 'not_found', 'item_id': _item}),
        throwsFormatException,
      );
    });

    test('a target on a superseded item, or outside the app, is refused', () {
      expect(
        () => OpenedInboxItem.fromJson(openedItemData(state: 'superseded')),
        throwsFormatException,
      );
      for (final bad in [
        null,
        'https://example.org/x',
        '//example.org/x',
        '/x?y=1',
        'x/y',
        '/X',
      ]) {
        expect(
          () => OpenedInboxItem.fromJson(openedItemData(target: bad)),
          throwsFormatException,
          reason: '$bad',
        );
      }
      expect(
        () => OpenedInboxItem.fromJson(openedItemData(state: 'revoked')),
        throwsFormatException,
      );
    });

    test('in-app paths', () {
      expect(isInAppPath(_target), isTrue);
      expect(isInAppPath('/inbox'), isTrue);
      expect(isInAppPath('/'), isFalse);
      expect(isInAppPath('/a#b'), isFalse);
    });
  });

  group('inbox item screen (both clients)', () {
    testWidgets('tapping an inbox item opens it and asks the server', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.inbox,
        setUp: (h) {
          h.inbox.inbox = AccessReadOk(
            Inbox.fromJson({
              'items': [inboxItemData()],
            }),
          );
          h.inbox.opened[_item] = AccessReadOk(
            OpenedInboxItem.fromJson(
              openedItemData(state: 'superseded', target: null),
            ),
          );
        },
      );
      expect(find.text('A test reminder is waiting for you.'), findsOneWidget);
      await tester.tap(byKey('open-inbox-item-$_item'));
      await settle(tester);
      expect(h.inbox.openedIds, [_item]);
      expect(byKey('inbox-item-superseded'), findsOneWidget);
    });

    testWidgets('a superseded item says only that it is out of date', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.inboxItem(_item),
        setUp: (h) => h.inbox.opened[_item] = AccessReadOk(
          OpenedInboxItem.fromJson(
            openedItemData(state: 'superseded', target: null),
          ),
        ),
      );
      expect(byKey('inbox-item-title'), findsOneWidget);
      expect(byKey('inbox-item-superseded'), findsOneWidget);
      expect(byKey('inbox-item-open-target'), findsNothing);
      expect(byKey('inbox-item-later-version'), findsNothing);
    });

    testWidgets('a current item whose screen is not in this build says so', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.inboxItem(_item),
        // Story 3.7 registered the SYNTHETIC fixture link; a future
        // source's link is not in this build yet.
        setUp: (h) => h.inbox.opened[_item] = AccessReadOk(
          OpenedInboxItem.fromJson(
            openedItemData(
              target: '/duties/41414141-4141-4141-8141-414141414141',
            ),
          ),
        ),
      );
      expect(byKey('inbox-item-later-version'), findsOneWidget);
      expect(byKey('inbox-item-open-target'), findsNothing);
    });

    testWidgets('a current item with a known screen opens its target', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.inboxItem(_item),
        knownTarget: (t) => t.startsWith('/fixture/reminders/'),
        setUp: (h) => h.inbox.opened[_item] = AccessReadOk(
          OpenedInboxItem.fromJson(openedItemData()),
        ),
      );
      await tester.tap(byKey('inbox-item-open-target'));
      await settle(tester);
      expect(find.text('target screen'), findsOneWidget);
    });

    testWidgets('an item that is not the caller\'s shows nothing of it', (
      tester,
    ) async {
      await pumpAt(tester, ClientPaths.inboxItem(_item));
      expect(byKey('inbox-item-not-found'), findsOneWidget);
      expect(byKey('inbox-item-title'), findsNothing);
    });

    testWidgets('a denial and an unreachable server show no item', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.inboxItem(_item),
        setUp: (h) => h.inbox.opened[_item] = const AccessReadDenied(
          AccessDenial.notLinked,
        ),
      );
      expect(byKey('inbox-item-denied-notLinked'), findsOneWidget);
      expect(byKey('inbox-item-title'), findsNothing);
    });

    testWidgets('Check again asks the server again', (tester) async {
      final h = await pumpAt(tester, ClientPaths.inboxItem(_item));
      expect(h.inbox.openedIds, [_item]);
      h.inbox.opened[_item] = const AccessReadFailed(unreachable: true);
      await tester.tap(byKey('refresh-inbox-item'));
      await settle(tester);
      expect(h.inbox.openedIds, [_item, _item]);
      expect(byKey('inbox-item-failed'), findsOneWidget);
      h.inbox.opened[_item] = const AccessReadFailed(unreachable: false);
      await tester.tap(byKey('refresh-inbox-item'));
      await settle(tester);
      expect(find.text('Couldn\'t open this reminder'), findsOneWidget);
      expect(find.text('Couldn\'t load your inbox'), findsNothing);
    });

    testWidgets('signing out drops the opened item at once', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.inboxItem(_item),
        setUp: (h) => h.inbox.opened[_item] = AccessReadOk(
          OpenedInboxItem.fromJson(openedItemData()),
        ),
      );
      expect(byKey('inbox-item-title'), findsOneWidget);
      h.session.switchTo(null);
      await settle(tester);
      expect(byKey('inbox-item-title'), findsNothing);
      expect(byKey('inbox-item-denied-signedOut'), findsOneWidget);
    });
  });

  group('SupabaseInboxRepository.openItem', () {
    late List<http.Request> sent;

    SupabaseClient clientWith(Object body, int status) {
      sent = [];
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
            jsonEncode(body),
            status,
            headers: {'content-type': 'application/json'},
            request: r,
          );
        }),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);
      return client;
    }

    test('posts the item id to api.notifications_open_item', () async {
      final client = clientWith(openedItemData(), 200);
      await client.auth.signInWithPassword(
        phone: '+447700900822',
        password: 'p',
      );
      final out = await SupabaseInboxRepository(client).openItem(_item);
      expect(
        (out as AccessReadOk<OpenedInboxItem>).value.state,
        InboxItemState.current,
      );
      expect(sent.last.url.path, '/rest/v1/rpc/notifications_open_item');
      expect(sent.last.headers['Content-Profile'], 'api');
      expect(jsonDecode(sent.last.body), {'item_id': _item});
    });

    test('an unexpected answer is a failure, never an item', () async {
      final client = clientWith({
        'state': 'current',
        'target': 'https://x',
      }, 200);
      await client.auth.signInWithPassword(
        phone: '+447700900822',
        password: 'p',
      );
      expect(
        await SupabaseInboxRepository(client).openItem(_item),
        isA<AccessReadFailed<OpenedInboxItem>>(),
      );
    });

    test('signed out: no request', () async {
      final client = clientWith({}, 200);
      expect(
        await SupabaseInboxRepository(client).openItem(_item),
        isA<AccessReadDenied<OpenedInboxItem>>(),
      );
      expect(sent, isEmpty);
    });
  });
}
