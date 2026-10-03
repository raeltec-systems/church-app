/// Shared client application layer: domain ports, Riverpod controllers and
/// shared screens. Free of Supabase; adapters live in `supabase_adapters.dart`.
library;

export 'src/application/fixture_counter_controller.dart';
export 'src/application/providers.dart';
export 'src/domain/commands.dart';
export 'src/domain/fixture_counter.dart';
export 'src/domain/platform_status.dart';
export 'src/domain/session.dart';
export 'src/presentation/fixture_command_screen.dart';
export 'src/presentation/platform_status_screen.dart';
