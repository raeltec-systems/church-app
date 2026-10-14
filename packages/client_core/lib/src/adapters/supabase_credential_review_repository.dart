import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/credential_review.dart';
import 'supabase_api_reader.dart';

/// Supabase adapter for [CredentialReviewRepository] (story 2.8): the
/// member's own sign-in details (`api.identity_my_credentials`) and the Admin
/// queue (`api.identity_admin_credential_queue`). The server decides
/// everything; this only maps the answers.
class SupabaseCredentialReviewRepository implements CredentialReviewRepository {
  SupabaseCredentialReviewRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<MyCredentials>> fetchMine() =>
      _reader.read('identity_my_credentials', const {}, MyCredentials.fromJson);

  @override
  Future<AccessRead<CredentialQueue>> fetchQueue() => _reader.read(
    'identity_admin_credential_queue',
    const {},
    CredentialQueue.fromJson,
  );
}
