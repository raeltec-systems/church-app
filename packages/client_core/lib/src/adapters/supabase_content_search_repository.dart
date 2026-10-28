import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/content_search.dart';
import 'supabase_api_reader.dart';

/// Supabase adapter for [ContentSearchRepository] (epic 6 entry 14): the
/// public search read `api.content_public_search`, which answers signed-out
/// callers too. This adapter only maps the answer.
class SupabaseContentSearchRepository implements ContentSearchRepository {
  SupabaseContentSearchRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<PublicSearchResults>> search(String query) => _reader.read(
    'content_public_search',
    {'query': query},
    PublicSearchResults.fromJson,
    public: true,
  );
}
