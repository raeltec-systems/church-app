// Story 3.1: the member's durable inbox on both clients (domain mapping, the
// shared screen and the Supabase adapter). Fakes and a mock HTTP client only;
// the server behaviour is covered by supabase/tests/notifications_inbox_test.sql
// and tools/identity-e2e/inbox.mjs.
import 'dart:convert';

import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/supabase_adapters.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

const _item = '31313131-3131-4131-8131-313131313131';
const _other = '32323232-3232-4232-8232-323232323232';

Future<ClientTestHarness> pumpInbox(
  WidgetTester tester, {
  void Function(ClientTestHarness h)? setUp,
}) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = ClientTestHarness();
  setUp?.call(h);
  final router = buildClientRouter(
    initialLocation: ClientPaths.inbox,
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

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder byKey(String k) => find.byKey(Key(k));

// A syntactically valid, unsigned test JWT (not a credential): header.payload.x
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

void main() {
  group('inbox mapping', () {
    test('an item carries its kind and UTC times only', () {
      final inbox = Inbox.fromJson({
        'items': [inboxItemData(), inboxItemData(id: _other, kind: 'other')],
      });
      expect(inbox.items, hasLength(2));
      expect(inbox.items.first.itemId, _item);
      expect(inbox.items.first.title, 'SYNTHETIC test reminder');
      expect(inbox.items.last.title, 'Reminder');
      expect(inbox.items.first.dueAt, DateTime.utc(2026, 10, 8, 7));
    });

    test('anything else is a format error', () {
      expect(() => Inbox.fromJson({'items': 'x'}), throwsFormatException);
      expect(() => Inbox.fromJson([]), throwsFormatException);
      expect(
        () => InboxItem.fromJson({...inboxItemData(), 'due_at': 7}),
        throwsFormatException,
      );
      expect(
        () => InboxItem.fromJson({
          ...inboxItemData(),
          'due_at': '2026-10-08T07:00:00',
        }),
        throwsFormatException,
      );
    });
  });

  group('inbox screen (both clients)', () {
    testWidgets('shows each item the server returns', (tester) async {
      final h = await pumpInbox(
        tester,
        setUp: (h) => h.inbox.inbox = AccessReadOk(
          Inbox.fromJson({
            'items': [inboxItemData()],
          }),
        ),
      );
      expect(byKey('inbox-item-$_item'), findsOneWidget);
      expect(find.text('SYNTHETIC test reminder'), findsOneWidget);
      expect(find.text('1 reminder'), findsOneWidget);
      expect(h.inbox.calls, greaterThanOrEqualTo(1));
    });

    testWidgets('an empty inbox says so', (tester) async {
      await pumpInbox(tester);
      expect(byKey('inbox-empty'), findsOneWidget);
    });

    testWidgets('Check again asks the server again', (tester) async {
      final h = await pumpInbox(tester);
      final before = h.inbox.calls;
      h.inbox.inbox = AccessReadOk(
        Inbox.fromJson({
          'items': [inboxItemData()],
        }),
      );
      await tester.tap(byKey('refresh-inbox'));
      await settle(tester);
      expect(h.inbox.calls, greaterThan(before));
      expect(byKey('inbox-item-$_item'), findsOneWidget);
    });

    testWidgets('a denial shows the server\'s reason and no items', (
      tester,
    ) async {
      await pumpInbox(
        tester,
        setUp: (h) =>
            h.inbox.inbox = const AccessReadDenied(AccessDenial.notLinked),
      );
      expect(byKey('inbox-denied-notLinked'), findsOneWidget);
      expect(byKey('inbox-item-$_item'), findsNothing);
    });

    testWidgets('an unreachable server shows nothing it cannot confirm', (
      tester,
    ) async {
      await pumpInbox(
        tester,
        setUp: (h) =>
            h.inbox.inbox = const AccessReadFailed(unreachable: true),
      );
      expect(byKey('inbox-failed'), findsOneWidget);
      expect(find.text('No connection'), findsOneWidget);
    });

    testWidgets('signing out drops the items at once', (tester) async {
      final h = await pumpInbox(
        tester,
        setUp: (h) => h.inbox.inbox = AccessReadOk(
          Inbox.fromJson({
            'items': [inboxItemData()],
          }),
        ),
      );
      expect(byKey('inbox-item-$_item'), findsOneWidget);
      h.session.switchTo(null);
      await settle(tester);
      expect(byKey('inbox-item-$_item'), findsNothing);
      expect(byKey('inbox-denied-signedOut'), findsOneWidget);
    });

    testWidgets('another account never sees the previous account\'s items', (
      tester,
    ) async {
      final h = await pumpInbox(
        tester,
        setUp: (h) => h.inbox.inbox = AccessReadOk(
          Inbox.fromJson({
            'items': [inboxItemData()],
          }),
        ),
      );
      h.inbox.inbox = const AccessReadOk(Inbox(items: []));
      h.session.switchTo('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
      await settle(tester);
      expect(byKey('inbox-item-$_item'), findsNothing);
      expect(byKey('inbox-empty'), findsOneWidget);
    });
  });

  group('SupabaseInboxRepository', () {
    late List<http.Request> sent;

    SupabaseClient clientWith(
      Future<http.Response> Function(http.Request) rest,
    ) {
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
          return rest(r);
        }),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);
      return client;
    }

    test('signed out: no request, denied signedOut', () async {
      final repo = SupabaseInboxRepository(
        clientWith((r) async => http.Response('{}', 200)),
      );
      final out = await repo.fetchMyInbox();
      expect(
        out,
        isA<AccessReadDenied<Inbox>>().having(
          (d) => d.denial,
          'denial',
          AccessDenial.signedOut,
        ),
      );
      expect(sent, isEmpty);
    });

    test('posts to api.notifications_my_inbox and maps the items', () async {
      final client = clientWith(
        (r) async => http.Response(
          jsonEncode({
            'items': [inboxItemData()],
          }),
          200,
          headers: {'content-type': 'application/json'},
          request: r,
        ),
      );
      await client.auth.signInWithPassword(
        phone: '+447700900820',
        password: 'p',
      );
      final out = await SupabaseInboxRepository(client).fetchMyInbox();
      expect(out, isA<AccessReadOk<Inbox>>());
      expect((out as AccessReadOk<Inbox>).value.items.single.itemId, _item);
      final rpc = sent.last;
      expect(rpc.method, 'POST');
      expect(rpc.url.path, '/rest/v1/rpc/notifications_my_inbox');
      expect(rpc.headers['Content-Profile'], 'api');
    });

    test('the live-access denial maps to the caller\'s reason', () async {
      final client = clientWith(
        (r) async => http.Response(
          jsonEncode({
            'code': 'PT403',
            'message': 'forbidden',
            'details': 'not_linked',
            'hint': null,
          }),
          403,
          headers: {'content-type': 'application/json'},
          request: r,
        ),
      );
      await client.auth.signInWithPassword(
        phone: '+447700900820',
        password: 'p',
      );
      final out = await SupabaseInboxRepository(client).fetchMyInbox();
      expect(
        out,
        isA<AccessReadDenied<Inbox>>().having(
          (d) => d.denial,
          'denial',
          AccessDenial.notLinked,
        ),
      );
    });
  });
}
