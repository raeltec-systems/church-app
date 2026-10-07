/// Supabase adapters for the client ports. Only composition roots (each app's
/// `main.dart`) import this library; presentation never does.
library;

export 'src/adapters/supabase_account_auth_gateway.dart';
export 'src/adapters/supabase_command_gateway.dart';
export 'src/adapters/supabase_grants_repository.dart';
export 'src/adapters/supabase_member_access_repository.dart';
export 'src/adapters/supabase_membership_repository.dart';
export 'src/adapters/supabase_platform_status_repository.dart';
export 'src/adapters/supabase_review_repository.dart';
export 'src/adapters/supabase_session_repository.dart';
