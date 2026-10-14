/// Story 3.6: the device push port (FCM on Android, FCM with APNs on iOS).
/// Free of widgets and SDKs: a real adapter (firebase_messaging) is wired by
/// the mobile composition root once the owner's Firebase app exists; until
/// then [NoPushMessaging] keeps push off and the durable inbox carries every
/// reminder.
library;

/// The operating system's answer about showing notifications.
enum PushPermission { granted, denied, notDetermined, unsupported }

/// The platform a device token belongs to (the server's `platform` values).
enum PushPlatform { android, ios }

/// What the app needs from a push provider SDK. Device tokens stay in memory
/// only long enough to register them with the server; they are never logged
/// or shown.
abstract interface class PushMessaging {
  /// False when this build or platform has no push (web, tests, no Firebase
  /// configuration): nothing is asked, registered or shown.
  bool get isSupported;

  /// The platform of this device's tokens (null when unsupported).
  PushPlatform? get platform;

  /// The current permission, without asking.
  Future<PushPermission> permission();

  /// Asks the person once (the operating system's dialog); returns the answer.
  Future<PushPermission> requestPermission();

  /// This device's current token, or null when none is available.
  Future<String?> token();

  /// New tokens issued by the provider while the app runs.
  Stream<String> get tokenRefreshes;

  /// The inbox item ids of notifications the person tapped while the app was
  /// running or in the background (already validated with [pushItemId]).
  Stream<String> get taps;

  /// The inbox item id of the notification that launched the app, if any.
  /// Answers once; later calls answer null.
  Future<String?> initialTap();

  /// Forgets this device's token at the provider (after sign-out).
  Future<void> deleteToken();
}

/// The default: push is off. The inbox and the leaders' direct-contact routes
/// carry every reminder.
class NoPushMessaging implements PushMessaging {
  const NoPushMessaging();

  @override
  bool get isSupported => false;

  @override
  PushPlatform? get platform => null;

  @override
  Future<PushPermission> permission() async => PushPermission.unsupported;

  @override
  Future<PushPermission> requestPermission() async =>
      PushPermission.unsupported;

  @override
  Future<String?> token() async => null;

  @override
  Stream<String> get tokenRefreshes => const Stream.empty();

  @override
  Stream<String> get taps => const Stream.empty();

  @override
  Future<String?> initialTap() async => null;

  @override
  Future<void> deleteToken() async {}
}

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// The inbox item id a push message's data carries (`{item_id}` and nothing
/// else is ever sent), or null when it is missing or malformed. The id is an
/// opaque pointer: opening it asks the server again, after sign-in, whether
/// the item is still the caller's and still current.
String? pushItemId(Map<String, Object?> data) {
  final id = data['item_id'];
  return id is String && _uuid.hasMatch(id) ? id : null;
}

/// The device token shape the server accepts (an FCM registration token).
bool isPushToken(String token) =>
    token.length >= 20 &&
    token.length <= 4096 &&
    RegExp(r'^[A-Za-z0-9_:.-]+$').hasMatch(token);
