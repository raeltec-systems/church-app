// Story 3.6 client follow-up: the real push adapter (FCM; FCM with APNs on
// iOS) behind client_core's PushMessaging port. Only lib/main.dart selects
// it, and only when the build carries the Firebase defines.
import 'dart:async';

import 'package:church_client_core/church_client_core.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'firebase_push_config.dart';

/// The operating system's answer as the port names it. The SDK reports
/// "never asked" as notDetermined on Android 13+ too, so the person is asked
/// once; a permanent denial is a denial (only system settings can undo it).
PushPermission pushPermissionOf(AuthorizationStatus status) => switch (status) {
  AuthorizationStatus.authorized ||
  AuthorizationStatus.provisional => PushPermission.granted,
  AuthorizationStatus.notDetermined => PushPermission.notDetermined,
  AuthorizationStatus.denied ||
  AuthorizationStatus.deniedPermanently => PushPermission.denied,
};

/// The inbox item a tapped notification opens (`data.item_id`, validated),
/// or null. Nothing else in the message is read.
String? tappedItemId(RemoteMessage? message) =>
    message == null ? null : pushItemId(message.data);

class FirebasePushMessaging implements PushMessaging {
  FirebasePushMessaging({
    required this.platform,
    FirebaseMessaging? messaging,
    Stream<RemoteMessage>? openedApp,
    Stream<RemoteMessage>? foreground,
  }) : _messaging = messaging ?? FirebaseMessaging.instance,
       _openedApp = openedApp ?? FirebaseMessaging.onMessageOpenedApp,
       _foreground = foreground ?? FirebaseMessaging.onMessage;

  final FirebaseMessaging _messaging;
  final Stream<RemoteMessage> _openedApp;
  final Stream<RemoteMessage> _foreground;
  bool _initialAnswered = false;

  @override
  final PushPlatform platform;

  @override
  bool get isSupported => true;

  /// A content-free event (broadcast) per message received while the app is open. The
  /// app only re-reads the inbox; it never shows the message itself (on
  /// Android and iOS the SDK shows nothing in the foreground by default).
  Stream<void> get foregroundMessages => _foreground.map((_) {});

  @override
  Future<PushPermission> permission() async {
    try {
      final settings = await _messaging.getNotificationSettings();
      return pushPermissionOf(settings.authorizationStatus);
    } catch (_) {
      return PushPermission.unsupported;
    }
  }

  @override
  Future<PushPermission> requestPermission() async {
    try {
      final settings = await _messaging.requestPermission();
      return pushPermissionOf(settings.authorizationStatus);
    } catch (_) {
      return PushPermission.unsupported;
    }
  }

  @override
  Future<String?> token() async {
    try {
      // On iOS the FCM token needs the APNs token first; without the APNs
      // setup (runbook step 5) there is none and push stays off.
      if (platform == PushPlatform.ios &&
          await _messaging.getAPNSToken() == null) {
        return null;
      }
      return await _messaging.getToken();
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<String> get tokenRefreshes =>
      _messaging.onTokenRefresh.handleError((Object _) {});

  @override
  Stream<String> get taps => _openedApp
      .map(tappedItemId)
      .where((id) => id != null)
      .cast<String>()
      .handleError((Object _) {});

  @override
  Future<String?> initialTap() async {
    if (_initialAnswered) return null;
    _initialAnswered = true;
    try {
      return tappedItemId(await _messaging.getInitialMessage());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> deleteToken() => _messaging.deleteToken();
}

/// What main() needs: the adapter, plus the foreground nudges for the inbox
/// (null with the no-op adapter).
typedef SelectedPush = ({PushMessaging push, Stream<void>? inboxNudges});

typedef FirebaseStarter = Future<SelectedPush> Function(
  FirebaseOptions options,
  PushPlatform p,
);

/// Chooses the push adapter for this build: [NoPushMessaging] unless the
/// Firebase defines for this platform are present and Firebase starts.
Future<SelectedPush> selectPushMessaging(
  FirebasePushConfig config, {
  required TargetPlatform platform,
  bool isWeb = kIsWeb,
  FirebaseStarter start = startFirebasePush,
}) async {
  const off = (push: NoPushMessaging(), inboxNudges: null);
  final options = config.optionsFor(platform, isWeb: isWeb);
  if (options == null) return off;
  final pushPlatform = platform == TargetPlatform.iOS
      ? PushPlatform.ios
      : PushPlatform.android;
  try {
    return await start(options, pushPlatform);
  } catch (_) {
    // A Firebase that cannot start never blocks the app: the inbox still
    // carries every reminder.
    return off;
  }
}

Future<SelectedPush> startFirebasePush(
  FirebaseOptions options,
  PushPlatform platform,
) async {
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: options);
  }
  final push = FirebasePushMessaging(platform: platform);
  return (push: push, inboxNudges: push.foregroundMessages);
}
