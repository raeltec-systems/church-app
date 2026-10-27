import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/hymn_lists.dart';
import 'supabase_api_reader.dart';

/// Supabase adapter for [HymnListsRepository] (story 6.8): the member's own
/// favourites (`api.content_my_hymn_favourites`, live member access), this
/// Sunday's public list (`api.content_public_sunday_hymns`, signed-out
/// callers too) and the editors' read (`api.content_staff_sunday_hymns`).
/// The server checks the caller on every call; this adapter only maps the
/// answer.
class SupabaseHymnListsRepository implements HymnListsRepository {
  SupabaseHymnListsRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<MyHymnFavourites>> fetchMyFavourites() => _reader.read(
    'content_my_hymn_favourites',
    const {},
    MyHymnFavourites.fromJson,
  );

  @override
  Future<AccessRead<PublicSundayHymns>> fetchPublicSundayHymns() =>
      _reader.read(
        'content_public_sunday_hymns',
        const {},
        PublicSundayHymns.fromJson,
        public: true,
      );

  @override
  Future<AccessRead<StaffSundayHymns>> fetchStaffSundayHymns() => _reader.read(
    'content_staff_sunday_hymns',
    const {},
    StaffSundayHymns.fromJson,
  );
}
