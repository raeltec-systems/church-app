// Disposable Flutter Web trial (Q10): copied from apps/mobile; do not build on this.
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
