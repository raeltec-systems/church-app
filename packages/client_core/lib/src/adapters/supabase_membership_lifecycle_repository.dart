import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/membership_lifecycle.dart';
import 'supabase_api_reader.dart';

/// Supabase adapter for [MembershipLifecycleRepository] (story 2.10): the
/// account's own status (`api.identity_my_membership_status`) and the Admin
/// overview (`api.identity_admin_membership_lifecycle`). The server decides;
/// this only maps the answers.
class SupabaseMembershipLifecycleRepository
    implements MembershipLifecycleRepository {
  SupabaseMembershipLifecycleRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<MyMembershipStatus>> fetchMyStatus() => _reader.read(
    'identity_my_membership_status',
    const {},
    MyMembershipStatus.fromJson,
  );

  @override
  Future<AccessRead<MembershipLifecycleOverview>> fetchOverview() =>
      _reader.read(
        'identity_admin_membership_lifecycle',
        const {},
        MembershipLifecycleOverview.fromJson,
      );
}
