// Composition root: the only file in this app that touches Supabase.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/supabase_adapters.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'config.dart';

/// Kept for the app's lifetime so the browser semantics tree is always built:
/// a screen-reader user should not need Flutter's hidden "enable
/// accessibility" button (1.6 finding 10).
late final SemanticsHandle semanticsHandle;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  semanticsHandle = SemanticsBinding.instance.ensureSemantics();
  const config = AppConfig.fromEnvironment;
  final overrides = config.isComplete
      ? await supabaseOverrides(config)
      : const <Override>[];
  runApp(ProviderScope(overrides: overrides, child: const StaffApp()));
}

Future<List<Override>> supabaseOverrides(AppConfig config) async {
  final supabase = await Supabase.initialize(
    url: config.supabaseUrl,
    publishableKey: config.publishableKey,
    postgrestOptions: const PostgrestClientOptions(schema: 'api'),
    // AD-13: no persisted session; protected state lives in memory only.
    authOptions: const FlutterAuthClientOptions(
      persistSession: false,
      detectSessionInUri: false,
    ),
  );
  final client = supabase.client;
  return [
    platformStatusRepositoryProvider.overrideWithValue(
      SupabasePlatformStatusRepository(client),
    ),
    commandGatewayProvider.overrideWithValue(SupabaseCommandGateway(client)),
    sessionRepositoryProvider.overrideWithValue(
      SupabaseSessionRepository(client),
    ),
  ];
}
