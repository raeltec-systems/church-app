// Disposable Flutter Web trial (Q10): copied from apps/mobile; do not build on this.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'platform_status/platform_status.dart';
import 'platform_status/platform_status_screen.dart';
import 'platform_status/supabase_platform_status_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const config = AppConfig.fromEnvironment;
  if (!config.isComplete) {
    runApp(const MainApp(home: MissingConfigScreen()));
    return;
  }
  final supabase = await Supabase.initialize(
    url: config.supabaseUrl,
    publishableKey: config.publishableKey,
    postgrestOptions: const PostgrestClientOptions(schema: 'api'),
    // The tracer has no sign-in: keep any session in memory and ignore links.
    authOptions: const FlutterAuthClientOptions(
      persistSession: false,
      detectSessionInUri: false,
    ),
  );
  final PlatformStatusRepository repository = SupabasePlatformStatusRepository(
    supabase.client,
  );
  runApp(MainApp(home: PlatformStatusScreen(repository: repository)));
}

class MainApp extends StatelessWidget {
  const MainApp({super.key, required this.home});

  final Widget home;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BIC Kafue staff web trial',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF14246B)),
      home: home,
    );
  }
}

class MissingConfigScreen extends StatelessWidget {
  const MissingConfigScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'App not configured: build with --dart-define=SUPABASE_URL=… and '
            '--dart-define=SUPABASE_PUBLISHABLE_KEY=…',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
