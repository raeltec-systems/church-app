// Composition root: the only file in this app that reaches Supabase (through
// church_client_core's composition library) and selects the push adapter.
import 'package:church_client_core/church_client_core.dart'
    show
        contactLauncherProvider,
        givingDiallerLauncherProvider,
        dutyCalendarExportProvider,
        publicContentCacheProvider,
        publicContentReconnectsProvider,
        pushMessagingProvider;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:church_client_core/composition.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'calendar/share_calendar_export.dart';
import 'contact/url_contact_launcher.dart';
import 'offline/public_content_cache_adapter.dart';
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
        // Story 4.5: Add to calendar hands the .ics file to the share sheet.
        dutyCalendarExportProvider.overrideWithValue(
          const ShareCalendarExport(),
        ),
        // Story 4.9: Call and Message open the phone's dialler or messages.
        contactLauncherProvider.overrideWithValue(const UrlContactLauncher()),
        givingDiallerLauncherProvider.overrideWithValue(
          const UrlGivingDiallerLauncher(),
        ),
        publicContentCacheProvider.overrideWithValue(
          PublicContentCacheAdapter(),
        ),
        publicContentReconnectsProvider.overrideWith((ref) {
          final connectivity = Connectivity();
          return Stream<void>.multi((controller) {
            bool? wasOnline;
            void update(List<ConnectivityResult> results) {
              final online = results.any(
                (result) => result != ConnectivityResult.none,
              );
              if (wasOnline == false && online) controller.add(null);
              wasOnline = online;
            }

            connectivity.checkConnectivity().then(update).catchError((_) {});
            final subscription = connectivity.onConnectivityChanged.listen(
              update,
            );
            ref.onDispose(subscription.cancel);
            controller.onCancel = subscription.cancel;
          });
        }),
      ],
      // The launch screen carries into the app and fades into the first
      // screen.
      child: const MobileApp(launchCurtain: true),
    ),
  );
}
