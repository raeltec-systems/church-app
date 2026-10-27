import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/content_sermons.dart';
import 'supabase_api_reader.dart';

class SupabaseSermonsRepository implements SermonsRepository {
  SupabaseSermonsRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);
  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<PublicSermons>> fetchPublicSermons() => _reader.read(
    'content_public_sermons',
    const {},
    PublicSermons.fromJson,
    public: true,
  );
  @override
  Future<AccessRead<PublicSermonRead>> fetchPublicSermon(String sermonId) =>
      _reader.read(
        'content_public_sermon',
        {'sermon_id': sermonId},
        PublicSermonRead.fromJson,
        public: true,
      );
  @override
  Future<AccessRead<StaffSermons>> fetchStaffSermons() =>
      _reader.read('content_staff_sermons', const {}, StaffSermons.fromJson);
  @override
  Future<AccessRead<StaffSermonSeriesCatalog>> fetchStaffSeries() =>
      _reader.read(
        'content_staff_sermon_series',
        const {},
        StaffSermonSeriesCatalog.fromJson,
      );
}
