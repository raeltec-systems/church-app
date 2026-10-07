/// Shared client application layer: domain ports, Riverpod controllers and
/// shared screens. Free of Supabase; adapters live in `supabase_adapters.dart`.
library;

export 'src/application/access_controllers.dart';
export 'src/application/account_controllers.dart';
export 'src/application/application_controllers.dart';
export 'src/application/fixture_counter_controller.dart';
export 'src/application/review_controllers.dart';
export 'src/application/providers.dart';
export 'src/domain/access_grants.dart';
export 'src/domain/account_auth.dart';
export 'src/domain/commands.dart';
export 'src/domain/fixture_counter.dart';
export 'src/domain/member_access.dart';
export 'src/domain/membership_application.dart';
export 'src/domain/membership_review.dart';
export 'src/domain/phone_username.dart';
export 'src/domain/platform_status.dart';
export 'src/domain/session.dart';
export 'src/presentation/access_screens.dart';
export 'src/presentation/account_screen.dart';
export 'src/presentation/fixture_command_screen.dart';
export 'src/presentation/membership_application_screen.dart';
export 'src/presentation/membership_review_screen.dart';
export 'src/presentation/platform_status_screen.dart';
export 'src/presentation/shell_routing.dart';
export 'src/presentation/sign_in_screen.dart';
