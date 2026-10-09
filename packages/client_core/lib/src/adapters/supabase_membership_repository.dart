import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/membership_application.dart';
import 'supabase_api_reader.dart';

/// Supabase adapter for [MembershipRepository] (story 2.4): the applicant's
/// own application (`api.identity_my_application`) and the safe cell chooser
/// (`api.cells_signup_options`). The server decides who may read them.
class SupabaseMembershipRepository implements MembershipRepository {
  SupabaseMembershipRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<MyApplication>> fetchMyApplication() =>
      _reader.read('identity_my_application', const {}, MyApplication.fromJson);

  @override
  Future<AccessRead<List<CellOption>>> fetchCellOptions() =>
      _reader.read('cells_signup_options', const {}, cellOptionsFromJson);
}
