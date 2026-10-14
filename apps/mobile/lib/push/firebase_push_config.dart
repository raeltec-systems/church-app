// Story 3.6 client follow-up: the Firebase app identifiers, supplied only
// through `--dart-define` at build time (never committed). They are the
// non-secret values from the owner's google-services.json and
// GoogleService-Info.plist (runbook notifications.md, Story 3.6, step 6).
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show TargetPlatform;

class FirebasePushConfig {
  const FirebasePushConfig({
    this.projectId = '',
    this.senderId = '',
    this.apiKey = '',
    this.androidAppId = '',
    this.iosAppId = '',
  });

  static const FirebasePushConfig fromEnvironment = FirebasePushConfig(
    projectId: String.fromEnvironment('FIREBASE_PROJECT_ID'),
    senderId: String.fromEnvironment('FIREBASE_SENDER_ID'),
    apiKey: String.fromEnvironment('FIREBASE_API_KEY'),
    androidAppId: String.fromEnvironment('FIREBASE_ANDROID_APP_ID'),
    iosAppId: String.fromEnvironment('FIREBASE_IOS_APP_ID'),
  );

  final String projectId;
  final String senderId;
  final String apiKey;
  final String androidAppId;

  /// Optional: without it iPhones keep push off.
  final String iosAppId;

  bool get _shared =>
      projectId.trim().isNotEmpty &&
      senderId.trim().isNotEmpty &&
      apiKey.trim().isNotEmpty;

  /// The options for [platform], or null when this build has no Firebase app
  /// for it (push then stays off: the no-op adapter).
  FirebaseOptions? optionsFor(TargetPlatform platform, {bool isWeb = false}) {
    if (isWeb || !_shared) return null;
    final appId = switch (platform) {
      TargetPlatform.android => androidAppId.trim(),
      TargetPlatform.iOS => iosAppId.trim(),
      _ => '',
    };
    if (appId.isEmpty) return null;
    return FirebaseOptions(
      apiKey: apiKey.trim(),
      appId: appId,
      messagingSenderId: senderId.trim(),
      projectId: projectId.trim(),
      iosBundleId: platform == TargetPlatform.iOS
          ? 'zm.bickafue.bicKafueMobile'
          : null,
    );
  }
}
