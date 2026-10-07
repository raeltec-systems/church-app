import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/member_deletion.dart';
import 'supabase_api_reader.dart';

/// Supabase adapter for [MemberDeletionRepository] (story 2.11): the Admin
/// read `api.identity_admin_deletions`. The server decides; this only maps
/// the answer.
class SupabaseMemberDeletionRepository implements MemberDeletionRepository {
  SupabaseMemberDeletionRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<MemberDeletionOverview>> fetchOverview() => _reader.read(
    'identity_admin_deletions',
    const {},
    MemberDeletionOverview.fromJson,
  );
}
