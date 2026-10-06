/// Composition root shared by the apps: configuration from `--dart-define`
/// and the Supabase adapters behind the port providers. Only each app's
/// `lib/main.dart` imports this library.
library;

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/application/providers.dart';
import 'supabase_adapters.dart';

export 'package:flutter_riverpod/misc.dart' show Override;

/// Client configuration, supplied only through `--dart-define`.
///
/// Only the project URL and the publishable key belong here. Never pass a
/// secret or service-role key to a client build.
class AppConfig {
  const AppConfig({required this.supabaseUrl, required this.publishableKey});

  static const AppConfig fromEnvironment = AppConfig(
    supabaseUrl: String.fromEnvironment('SUPABASE_URL'),
    publishableKey: String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
  );

  final String supabaseUrl;
  final String publishableKey;

  bool get isComplete => supabaseUrl.isNotEmpty && publishableKey.isNotEmpty;
}

/// Provider overrides for [config]: the Supabase adapters when the build is
/// configured, otherwise none (the screens then explain the missing
/// configuration and commands are reported as not sent).
Future<List<Override>> compositionOverrides(AppConfig config) async {
  if (!config.isComplete) return const [];
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
