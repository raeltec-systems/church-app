import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/content_bible.dart';
import 'supabase_api_reader.dart';

/// Story 6.6 read adapter. Public endpoints return only currently published
/// rights-cleared projections; the staff endpoint checks Media, Pastor or
/// Admin on every read. No table access is exposed to the client.
class SupabaseBibleRepository implements BibleRepository {
  SupabaseBibleRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<PublicBibleTranslations>> fetchPublicTranslations() =>
      _reader.read(
        'content_public_bible_translations',
        const {},
        PublicBibleTranslations.fromJson,
        public: true,
      );

  @override
  Future<AccessRead<PublicBibleChapter?>> fetchPublicChapter(
    String translationId,
    BibleChapterRef reference,
  ) => _reader.read(
    'content_public_bible_chapter',
    {
      'translation_id': translationId,
      'book_id': reference.bookId,
      'chapter': reference.chapter,
    },
    PublicBibleChapter.fromReadJson,
    public: true,
  );

  @override
  Future<AccessRead<BibleVerseManifest>> fetchVerseManifest(String code) =>
      _reader.read(
        'content_bible_manifest',
        {'translation_code': code},
        BibleVerseManifest.fromJson,
        public: true,
      );

  @override
  Future<AccessRead<StaffBibleTranslations>> fetchStaffTranslations() => _reader
      .read('content_staff_bibles', const {}, StaffBibleTranslations.fromJson);
}
