/// Supabase adapters for the client ports. Only composition roots (each app's
/// `main.dart`) import this library; presentation never does.
library;

export 'src/adapters/supabase_account_auth_gateway.dart';
export 'src/adapters/supabase_assisted_recovery.dart';
export 'src/adapters/supabase_cells_repository.dart';
export 'src/adapters/supabase_command_gateway.dart';
export 'src/adapters/supabase_credential_review_repository.dart';
export 'src/adapters/supabase_grants_repository.dart';
export 'src/adapters/supabase_inbox_repository.dart';
export 'src/adapters/supabase_member_access_repository.dart';
export 'src/adapters/supabase_member_deletion_repository.dart';
export 'src/adapters/supabase_membership_lifecycle_repository.dart';
export 'src/adapters/supabase_membership_repository.dart';
export 'src/adapters/supabase_password_recovery_gateway.dart';
export 'src/adapters/supabase_platform_status_repository.dart';
export 'src/adapters/supabase_recovery_email_repository.dart';
export 'src/adapters/supabase_review_repository.dart';
export 'src/adapters/supabase_session_repository.dart';
