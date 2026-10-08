import 'dart:async';

import 'package:bic_kafue_mobile/push/firebase_push_config.dart';
import 'package:bic_kafue_mobile/push/firebase_push_messaging.dart';
import 'package:church_client_core/church_client_core.dart'
    hide NotificationSettings;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const _item = '3f2b8c1e-4d5a-4b6c-8d7e-9f0a1b2c3d4e';

const _android = FirebasePushConfig(
  projectId: 'demo-project',
  senderId: '123',
  apiKey: 'AIzaDummy',
  androidAppId: '1:123:android:abc',
);

/// Answers only what the adapter calls; anything else fails the test.
class _FakeMessaging implements FirebaseMessaging {
  AuthorizationStatus status = AuthorizationStatus.denied;
  int requests = 0;
  int deletes = 0;
  RemoteMessage? initial;
  final refreshes = StreamController<String>.broadcast();

  NotificationSettings _settings() => NotificationSettings(
    alert: AppleNotificationSetting.notSupported,
    announcement: AppleNotificationSetting.notSupported,
    authorizationStatus: status,
    badge: AppleNotificationSetting.notSupported,
    carPlay: AppleNotificationSetting.notSupported,
    lockScreen: AppleNotificationSetting.notSupported,
    notificationCenter: AppleNotificationSetting.notSupported,
    showPreviews: AppleShowPreviewSetting.notSupported,
    timeSensitive: AppleNotificationSetting.notSupported,
    criticalAlert: AppleNotificationSetting.notSupported,
    sound: AppleNotificationSetting.notSupported,
    providesAppNotificationSettings: AppleNotificationSetting.notSupported,
  );

  @override
  Future<NotificationSettings> getNotificationSettings() async => _settings();

  @override
  Future<NotificationSettings> requestPermission({
    bool alert = true,
    bool announcement = false,
    bool badge = true,
    bool carPlay = false,
    bool criticalAlert = false,
    bool provisional = false,
    bool sound = true,
    bool providesAppNotificationSettings = false,
  }) async {
    requests++;
    return _settings();
  }

  @override
  Future<String?> getToken({
    String? serviceWorkerScriptPath,
    String? vapidKey,
  }) async => 'fcm-token-abcdefghijklmnop';

  @override
  Stream<String> get onTokenRefresh => refreshes.stream;

  @override
  Future<RemoteMessage?> getInitialMessage() async => initial;

  @override
  Future<void> deleteToken() async => deletes++;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  group('defines and adapter selection', () {
    test('no defines: the no-op adapter, Firebase never started', () async {
      var started = 0;
      final s = await selectPushMessaging(
        const FirebasePushConfig(),
        platform: TargetPlatform.android,
        isWeb: false,
        start: (o, p) async {
          started++;
          throw StateError('not expected');
        },
      );
      expect(s.push, isA<NoPushMessaging>());
      expect(s.inboxNudges, isNull);
      expect(started, 0);
    });

    test('a missing Android value keeps push off', () {
      for (final c in const [
        FirebasePushConfig(senderId: '1', apiKey: 'k', androidAppId: 'a'),
        FirebasePushConfig(projectId: 'p', apiKey: 'k', androidAppId: 'a'),
        FirebasePushConfig(projectId: 'p', senderId: '1', androidAppId: 'a'),
        FirebasePushConfig(projectId: 'p', senderId: '1', apiKey: 'k'),
        FirebasePushConfig(
          projectId: ' ',
          senderId: '1',
          apiKey: 'k',
          androidAppId: 'a',
        ),
      ]) {
        expect(c.optionsFor(TargetPlatform.android), isNull);
      }
    });

    test('Android defines map onto FirebaseOptions', () {
      final o = _android.optionsFor(TargetPlatform.android)!;
      expect(o.projectId, 'demo-project');
      expect(o.messagingSenderId, '123');
      expect(o.apiKey, 'AIzaDummy');
      expect(o.appId, '1:123:android:abc');
    });

    test('iOS needs its own app id; web never gets push', () {
      expect(_android.optionsFor(TargetPlatform.iOS), isNull);
      expect(_android.optionsFor(TargetPlatform.android, isWeb: true), isNull);
      const both = FirebasePushConfig(
        projectId: 'demo-project',
        senderId: '123',
        apiKey: 'AIzaDummy',
        androidAppId: '1:123:android:abc',
        iosAppId: '1:123:ios:def',
      );
      final o = both.optionsFor(TargetPlatform.iOS)!;
      expect(o.appId, '1:123:ios:def');
      expect(o.iosBundleId, 'zm.bickafue.bicKafueMobile');
    });

    test(
      'defines present: Firebase starts with them on that platform',
      () async {
        FirebaseOptions? seen;
        PushPlatform? seenPlatform;
        final fake = FirebasePushMessaging(
          platform: PushPlatform.android,
          messaging: _FakeMessaging(),
          openedApp: const Stream.empty(),
          foreground: const Stream.empty(),
        );
        final s = await selectPushMessaging(
          _android,
          platform: TargetPlatform.android,
          isWeb: false,
          start: (o, p) async {
            seen = o;
            seenPlatform = p;
            return (push: fake, inboxNudges: const Stream<void>.empty());
          },
        );
        expect(s.push, same(fake));
        expect(s.inboxNudges, isNotNull);
        expect(seen!.appId, '1:123:android:abc');
        expect(seenPlatform, PushPlatform.android);
      },
    );

    test('a Firebase that fails to start falls back to no push', () async {
      final s = await selectPushMessaging(
        _android,
        platform: TargetPlatform.android,
        isWeb: false,
        start: (o, p) async => throw FirebaseException(plugin: 'core'),
      );
      expect(s.push, isA<NoPushMessaging>());
    });
  });

  group('taps', () {
    test('data.item_id opens that inbox item; anything else is ignored', () {
      expect(
        tappedItemId(const RemoteMessage(data: {'item_id': _item})),
        _item,
      );
      expect(
        ClientPaths.inboxItem(
          tappedItemId(const RemoteMessage(data: {'item_id': _item}))!,
        ),
        '/inbox/$_item',
      );
      expect(tappedItemId(const RemoteMessage()), isNull);
      expect(
        tappedItemId(const RemoteMessage(data: {'item_id': '../account'})),
        isNull,
      );
      expect(tappedItemId(null), isNull);
    });

    test('opened-app taps stream only valid item ids', () async {
      final opened = StreamController<RemoteMessage>();
      final push = FirebasePushMessaging(
        platform: PushPlatform.android,
        messaging: _FakeMessaging(),
        openedApp: opened.stream,
        foreground: const Stream.empty(),
      );
      final got = push.taps.toList();
      opened
        ..add(const RemoteMessage(data: {'item_id': 'nope'}))
        ..add(const RemoteMessage(data: {'item_id': _item}));
      await opened.close();
      expect(await got, [_item]);
    });

    test('the launch tap answers once', () async {
      final m = _FakeMessaging()
        ..initial = const RemoteMessage(data: {'item_id': _item});
      final push = FirebasePushMessaging(
        platform: PushPlatform.android,
        messaging: m,
        openedApp: const Stream.empty(),
        foreground: const Stream.empty(),
      );
      expect(await push.initialTap(), _item);
      expect(await push.initialTap(), isNull);
    });
  });

  group('permission, token and foreground', () {
    test('permission, request, token and delete', () async {
      final m = _FakeMessaging()..status = AuthorizationStatus.notDetermined;
      final push = FirebasePushMessaging(
        platform: PushPlatform.android,
        messaging: m,
        openedApp: const Stream.empty(),
        foreground: const Stream.empty(),
      );
      expect(await push.permission(), PushPermission.notDetermined);
      m.status = AuthorizationStatus.denied;
      expect(await push.requestPermission(), PushPermission.denied);
      expect(m.requests, 1);
      expect(await push.permission(), PushPermission.denied);
      m.status = AuthorizationStatus.authorized;
      expect(await push.permission(), PushPermission.granted);
      expect(await push.token(), 'fcm-token-abcdefghijklmnop');
      await push.deleteToken();
      expect(m.deletes, 1);
    });

    test('status mapping', () {
      expect(
        pushPermissionOf(AuthorizationStatus.denied),
        PushPermission.denied,
      );
      expect(
        pushPermissionOf(AuthorizationStatus.deniedPermanently),
        PushPermission.denied,
      );
      expect(
        pushPermissionOf(AuthorizationStatus.provisional),
        PushPermission.granted,
      );
    });

    test('a foreground message is only a content-free nudge', () async {
      final fg = StreamController<RemoteMessage>.broadcast();
      final push = FirebasePushMessaging(
        platform: PushPlatform.android,
        messaging: _FakeMessaging(),
        openedApp: const Stream.empty(),
        foreground: fg.stream,
      );
      var nudges = 0;
      final sub = push.foregroundMessages.listen((_) => nudges++);
      fg.add(const RemoteMessage(data: {'item_id': _item}));
      await Future<void>.delayed(Duration.zero);
      expect(nudges, 1);
      await sub.cancel();
      await fg.close();
    });

    test('nudges are merged into the inbox refresh signal', () async {
      final nudges = StreamController<void>.broadcast();
      final signals = NudgedInboxSignals(const NoInboxSignals(), nudges.stream);
      var changes = 0;
      final sub = signals.changes('acct').listen((_) => changes++);
      nudges.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(changes, 1);
      await sub.cancel();
      await nudges.close();
    });
  });
}
