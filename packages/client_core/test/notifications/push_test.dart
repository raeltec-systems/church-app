// Story 3.6: device push registration, push-tap handling and the sign-in
// continuation on the shared client layer. Fakes only (no Firebase): the
// server side is covered by supabase/tests/notifications_push_test.sql and
// tools/identity-e2e/push.mjs; real-device evidence is an owner step.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _item = '31313131-3131-4131-8131-313131313131';
const _device = '51515151-5151-4151-8151-515151515151';
const _token = 'synthetic-AAAAAAAAAAAAAAAAAAAAAAAA:APA91b';
const _other = '00000000-0000-4000-8000-0000000000bb';

Finder byKey(String k) => find.byKey(Key(k));

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> drain() => Future<void>.delayed(Duration.zero);

ProviderContainer containerFor(ClientTestHarness h) {
  final c = ProviderContainer(overrides: h.overrides());
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('payload and token shapes', () {
    test('only a well-formed item id is taken from a push', () {
      expect(pushItemId({'item_id': _item}), _item);
      expect(pushItemId({'item_id': 'not-an-id'}), isNull);
      expect(
        pushItemId({'item_id': 'ABCDEF01-2345-4678-89AB-CDEF01234567'}),
        isNull,
      );
      expect(pushItemId({}), isNull);
      expect(pushItemId({'item_id': 42}), isNull);
    });

    test('device tokens have the server\'s shape', () {
      expect(isPushToken(_token), isTrue);
      expect(isPushToken('short'), isFalse);
      expect(isPushToken('has space ${'a' * 30}'), isFalse);
    });

    test('a sign-in continues only to an inbox item', () {
      expect(
        ClientPaths.signInThen(ClientPaths.inboxItem(_item)),
        '/sign-in?then=%2Finbox%2F$_item',
      );
      expect(ClientPaths.continuationFrom('/inbox/$_item'), '/inbox/$_item');
      expect(ClientPaths.continuationFrom('https://evil.example'), isNull);
      expect(ClientPaths.continuationFrom('/admin/grants'), isNull);
      expect(ClientPaths.continuationFrom('/inbox/$_item/x'), isNull);
      expect(ClientPaths.continuationFrom(null), isNull);
    });
  });

  group('registration', () {
    test(
      'no push SDK (every build today): unsupported, nothing sent',
      () async {
        final h = ClientTestHarness();
        final c = containerFor(h);
        expect(
          c.read(pushRegistrationProvider).status,
          PushRegistrationStatus.unsupported,
        );
        await c.read(pushRegistrationProvider.notifier).sync(prompt: true);
        expect(h.gateway.sent, isEmpty);
      },
    );

    test(
      'asked once, granted: the token is registered for the account',
      () async {
        final push = FakePushMessaging(deviceToken: _token);
        final h = ClientTestHarness()..push = push;
        final c = containerFor(h);
        final done = c
            .read(pushRegistrationProvider.notifier)
            .sync(prompt: true);
        await drain();
        expect(push.requests, 1);
        expect(
          c.read(pushRegistrationProvider).status,
          PushRegistrationStatus.registering,
        );
        final sent = h.gateway.sent.single;
        expect(sent.function, 'notifications_command');
        expect(sent.wire['command'], 'notifications.register_device');
        expect(sent.wire.containsKey('expected_revision'), isFalse);
        expect(sent.wire['payload'], {'token': _token, 'platform': 'android'});
        sent.confirm({'device_id': _device, 'platform': 'android'}, 1);
        await done;
        final s = c.read(pushRegistrationProvider);
        expect(s.status, PushRegistrationStatus.registered);
        expect(s.deviceId, _device);
        expect(s.revision, 1);
      },
    );

    test(
      'denied: nothing is registered (the inbox still has everything)',
      () async {
        final push = FakePushMessaging(
          deviceToken: _token,
          answer: PushPermission.denied,
        );
        final h = ClientTestHarness()..push = push;
        final c = containerFor(h);
        await c.read(pushRegistrationProvider.notifier).sync(prompt: true);
        expect(
          c.read(pushRegistrationProvider).status,
          PushRegistrationStatus.permissionDenied,
        );
        expect(h.gateway.sent, isEmpty);
      },
    );

    test('not asked without a prompt; not sent while signed out', () async {
      final push = FakePushMessaging(deviceToken: _token);
      final h = ClientTestHarness()..push = push;
      final c = containerFor(h);
      await c.read(pushRegistrationProvider.notifier).sync();
      expect(push.requests, 0);
      expect(
        c.read(pushRegistrationProvider).status,
        PushRegistrationStatus.permissionDenied,
      );
      final out = ClientTestHarness(account: null)
        ..push = FakePushMessaging(
          deviceToken: _token,
          current: PushPermission.granted,
        );
      final c2 = containerFor(out);
      await c2.read(pushRegistrationProvider.notifier).sync(prompt: true);
      expect(out.gateway.sent, isEmpty);
    });

    test(
      'a refused or unknown registration is failed, never registered',
      () async {
        final push = FakePushMessaging(
          deviceToken: _token,
          current: PushPermission.granted,
        );
        final h = ClientTestHarness()..push = push;
        final c = containerFor(h);
        final done = c.read(pushRegistrationProvider.notifier).sync();
        await drain();
        h.gateway.sent.single.refuse(ErrorCode.forbidden);
        await done;
        expect(
          c.read(pushRegistrationProvider).status,
          PushRegistrationStatus.failed,
        );
      },
    );

    test('a refreshed token is registered again', () async {
      final push = FakePushMessaging(
        deviceToken: _token,
        current: PushPermission.granted,
      );
      final h = ClientTestHarness()..push = push;
      final c = containerFor(h);
      final done = c.read(pushRegistrationProvider.notifier).sync();
      await drain();
      h.gateway.sent.single.confirm({'device_id': _device}, 1);
      await done;
      push.refreshToken('${_token}2');
      await drain();
      expect(h.gateway.sent, hasLength(2));
      expect(
        (h.gateway.sent.last.wire['payload'] as Map)['token'],
        '${_token}2',
      );
    });

    test(
      'an account change drops the registration state (memory only)',
      () async {
        final push = FakePushMessaging(
          deviceToken: _token,
          current: PushPermission.granted,
        );
        final h = ClientTestHarness()..push = push;
        final c = containerFor(h);
        final done = c.read(pushRegistrationProvider.notifier).sync();
        await drain();
        h.gateway.sent.single.confirm({'device_id': _device}, 1);
        await done;
        h.session.switchTo(_other);
        await drain();
        final s = c.read(pushRegistrationProvider);
        expect(s.status, PushRegistrationStatus.idle);
        expect(s.deviceId, isNull);
      },
    );

    test('a late answer for the previous account is discarded', () async {
      final push = FakePushMessaging(
        deviceToken: _token,
        current: PushPermission.granted,
      );
      final h = ClientTestHarness()..push = push;
      final c = containerFor(h);
      final done = c.read(pushRegistrationProvider.notifier).sync();
      await drain();
      h.session.switchTo(_other);
      await drain();
      h.gateway.sent.single.confirm({'device_id': _device}, 1);
      await done;
      expect(c.read(pushRegistrationProvider).deviceId, isNull);
    });

    test(
      'before sign-out the device is retired and the token forgotten',
      () async {
        final push = FakePushMessaging(
          deviceToken: _token,
          current: PushPermission.granted,
        );
        final h = ClientTestHarness()..push = push;
        final c = containerFor(h);
        final done = c.read(pushRegistrationProvider.notifier).sync();
        await drain();
        h.gateway.sent.single.confirm({'device_id': _device}, 3);
        await done;
        final retiring = c
            .read(pushRegistrationProvider.notifier)
            .retireBeforeSignOut();
        await drain();
        final retire = h.gateway.sent.last;
        expect(retire.wire['command'], 'notifications.retire_device');
        expect(retire.wire['expected_revision'], 3);
        expect(retire.wire['payload'], {'device_id': _device});
        retire.confirm({'device_id': _device, 'retired': true}, 4);
        await retiring;
        expect(push.deletes, 1);
        expect(
          c.read(pushRegistrationProvider).status,
          PushRegistrationStatus.idle,
        );
      },
    );
    test('a failing SDK or command never blocks sign-out', () async {
      final push = FakePushMessaging(
        deviceToken: _token,
        current: PushPermission.granted,
      )..failDelete = true;
      final h = ClientTestHarness()..push = push;
      final c = containerFor(h);
      final done = c.read(pushRegistrationProvider.notifier).sync();
      await drain();
      h.gateway.sent.single.confirm({'device_id': _device}, 1);
      await done;
      final retiring = c
          .read(pushRegistrationProvider.notifier)
          .retireBeforeSignOut();
      await drain();
      h.gateway.sent.last.refuse(ErrorCode.unavailable);
      await retiring;
      expect(push.deletes, 1);
      expect(
        c.read(pushRegistrationProvider).status,
        PushRegistrationStatus.idle,
      );
    });
  });

  group('push tap and sign-in continuation', () {
    Future<ClientTestHarness> pumpApp(
      WidgetTester tester,
      ClientTestHarness h,
    ) async {
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final router = buildClientRouter(
        shell: (_, _, child) => AccessRefresher(child: child),
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: h.overrides(),
          child: PushBridge(
            router: router,
            child: MaterialApp.router(
              theme: churchMobileTheme(Brightness.light),
              routerConfig: router,
            ),
          ),
        ),
      );
      await settle(tester);
      return h;
    }

    AccessRead<OpenedInboxItem> current() => AccessReadOk(
      OpenedInboxItem.fromJson({
        ...inboxItemData(id: _item),
        'state': 'current',
        'target': '/fixture/reminders/41414141-4141-4141-8141-414141414141',
      }),
    );

    testWidgets('a tap opens the item, which the server checks again', (
      tester,
    ) async {
      final push = FakePushMessaging(deviceToken: _token);
      final h = ClientTestHarness()..push = push;
      h.inbox.opened[_item] = current();
      await pumpApp(tester, h);
      push.tap(_item);
      await settle(tester);
      expect(byKey('inbox-item-title'), findsOneWidget);
      expect(h.inbox.openedIds, [_item]);
      push.tap('../admin');
      await settle(tester);
      expect(h.inbox.openedIds, [_item], reason: 'a malformed id is ignored');
    });

    testWidgets('the notification that launched the app opens its item', (
      tester,
    ) async {
      final h = ClientTestHarness()
        ..push = FakePushMessaging(deviceToken: _token, launchedBy: _item);
      h.inbox.opened[_item] = current();
      await pumpApp(tester, h);
      expect(byKey('inbox-item-title'), findsOneWidget);
    });

    testWidgets('member access registers the device once', (tester) async {
      final push = FakePushMessaging(deviceToken: _token);
      final h = ClientTestHarness()..push = push;
      h.grants.myAccess = AccessReadOk(syntheticGrants());
      await pumpApp(tester, h);
      await settle(tester);
      expect(push.requests, 1);
      expect(
        h.gateway.sent.where(
          (s) => s.wire['command'] == 'notifications.register_device',
        ),
        hasLength(1),
      );
    });

    testWidgets(
      'signed out, the tapped item offers sign-in and returns to the item',
      (tester) async {
        final push = FakePushMessaging(deviceToken: _token);
        final h = ClientTestHarness(account: null)..push = push;
        h.inbox.opened[_item] = current();
        await pumpApp(tester, h);
        push.tap(_item);
        await settle(tester);
        expect(byKey('inbox-item-denied-signedOut'), findsOneWidget);
        expect(
          h.inbox.openedIds,
          isEmpty,
          reason: 'nothing is asked signed out',
        );
        await tester.tap(byKey('inbox-item-sign-in'));
        await settle(tester);
        await tester.enterText(byKey('phone-field'), '+12025550101');
        await tester.enterText(byKey('password-field'), 'Synthetic-pw-1');
        await tester.tap(byKey('submit-button'));
        await settle(tester);
        h.auth.succeed('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
        await settle(tester);
        expect(byKey('inbox-item-title'), findsOneWidget);
        expect(h.inbox.openedIds, [_item]);
      },
    );
  });
}
