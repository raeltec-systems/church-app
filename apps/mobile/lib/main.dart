// Composition root: the only file in this app that reaches Supabase (through
// church_client_core's composition library) and selects the push adapter.
import 'package:church_client_core/church_client_core.dart'
    show pushMessagingProvider;
import 'package:church_client_core/composition.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'push/firebase_push_config.dart';
import 'push/firebase_push_messaging.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Story 3.6: real push only when this build carries the Firebase defines
  // for this platform; otherwise the default no-op adapter stays (the inbox
  // carries every reminder).
  final selected = await selectPushMessaging(
    FirebasePushConfig.fromEnvironment,
    platform: defaultTargetPlatform,
  );
  final overrides = await compositionOverrides(
    AppConfig.fromEnvironment,
    inboxNudges: selected.inboxNudges,
  );
  runApp(
    ProviderScope(
      overrides: [
        ...overrides,
        if (selected.push.isSupported)
          pushMessagingProvider.overrideWithValue(selected.push),
      ],
      child: const MobileApp(),
    ),
  );
}
