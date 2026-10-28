/// Story 6.6: private Bible imports and the public, rights-cleared reader.
///
/// Public projections contain only a published chapter and whether the
/// current rights record permits offline storage. Import state remains behind
/// the Content command and staff read. Free of widgets and Supabase.
library;

import 'access_grants.dart';
import 'content_events.dart' show ContentState;
import 'wire_json.dart';

// Entry 6.16: the shared wire readers (wire_json.dart), under the short
// names this library has always used.
const _text = wireText;

class BibleBook {
  const BibleBook(this.id, this.name, this.chapterCount);
  final String id;
  final String name;
  final int chapterCount;
}

/// The 66-book Protestant canon, in navigation order. These are identifiers,
/// not translation data; verse counts come from the versioned server manifest.
const bibleBooks = <BibleBook>[
  BibleBook('GEN', 'Genesis', 50),
  BibleBook('EXO', 'Exodus', 40),
  BibleBook('LEV', 'Leviticus', 27),
  BibleBook('NUM', 'Numbers', 36),
  BibleBook('DEU', 'Deuteronomy', 34),
  BibleBook('JOS', 'Joshua', 24),
  BibleBook('JDG', 'Judges', 21),
  BibleBook('RUT', 'Ruth', 4),
  BibleBook('1SA', '1 Samuel', 31),
  BibleBook('2SA', '2 Samuel', 24),
  BibleBook('1KI', '1 Kings', 22),
  BibleBook('2KI', '2 Kings', 25),
  BibleBook('1CH', '1 Chronicles', 29),
  BibleBook('2CH', '2 Chronicles', 36),
  BibleBook('EZR', 'Ezra', 10),
  BibleBook('NEH', 'Nehemiah', 13),
  BibleBook('EST', 'Esther', 10),
  BibleBook('JOB', 'Job', 42),
  BibleBook('PSA', 'Psalms', 150),
  BibleBook('PRO', 'Proverbs', 31),
  BibleBook('ECC', 'Ecclesiastes', 12),
  BibleBook('SNG', 'Song of Solomon', 8),
  BibleBook('ISA', 'Isaiah', 66),
  BibleBook('JER', 'Jeremiah', 52),
  BibleBook('LAM', 'Lamentations', 5),
  BibleBook('EZK', 'Ezekiel', 48),
  BibleBook('DAN', 'Daniel', 12),
  BibleBook('HOS', 'Hosea', 14),
  BibleBook('JOL', 'Joel', 3),
  BibleBook('AMO', 'Amos', 9),
  BibleBook('OBA', 'Obadiah', 1),
  BibleBook('JON', 'Jonah', 4),
  BibleBook('MIC', 'Micah', 7),
  BibleBook('NAM', 'Nahum', 3),
  BibleBook('HAB', 'Habakkuk', 3),
  BibleBook('ZEP', 'Zephaniah', 3),
  BibleBook('HAG', 'Haggai', 2),
  BibleBook('ZEC', 'Zechariah', 14),
  BibleBook('MAL', 'Malachi', 4),
  BibleBook('MAT', 'Matthew', 28),
  BibleBook('MRK', 'Mark', 16),
  BibleBook('LUK', 'Luke', 24),
  BibleBook('JHN', 'John', 21),
  BibleBook('ACT', 'Acts', 28),
  BibleBook('ROM', 'Romans', 16),
  BibleBook('1CO', '1 Corinthians', 16),
  BibleBook('2CO', '2 Corinthians', 13),
  BibleBook('GAL', 'Galatians', 6),
  BibleBook('EPH', 'Ephesians', 6),
  BibleBook('PHP', 'Philippians', 4),
  BibleBook('COL', 'Colossians', 4),
  BibleBook('1TH', '1 Thessalonians', 5),
  BibleBook('2TH', '2 Thessalonians', 3),
  BibleBook('1TI', '1 Timothy', 6),
  BibleBook('2TI', '2 Timothy', 4),
  BibleBook('TIT', 'Titus', 3),
  BibleBook('PHM', 'Philemon', 1),
  BibleBook('HEB', 'Hebrews', 13),
  BibleBook('JAS', 'James', 5),
  BibleBook('1PE', '1 Peter', 5),
  BibleBook('2PE', '2 Peter', 3),
  BibleBook('1JN', '1 John', 5),
  BibleBook('2JN', '2 John', 1),
  BibleBook('3JN', '3 John', 1),
  BibleBook('JUD', 'Jude', 1),
  BibleBook('REV', 'Revelation', 22),
];

BibleBook? bibleBook(String id) {
  for (final book in bibleBooks) {
    if (book.id == id) return book;
  }
  return null;
}

class BibleChapterRef implements Comparable<BibleChapterRef> {
  const BibleChapterRef({required this.bookId, required this.chapter});
  final String bookId;
  final int chapter;

  factory BibleChapterRef.fromJson(Object? json) {
    final m = wireMap(json, 'bible chapter reference');
    final book = bibleBook(wireReq<String>(m, 'book_id'));
    final chapter = wireReq<int>(m, 'chapter');
    if (book == null || chapter < 1 || chapter > book.chapterCount) {
      throw const FormatException('unexpected chapter reference');
    }
    return BibleChapterRef(bookId: book.id, chapter: chapter);
  }

  Map<String, Object?> toJson() => {'book_id': bookId, 'chapter': chapter};

  @override
  int compareTo(BibleChapterRef other) {
    final a = bibleBooks.indexWhere((book) => book.id == bookId);
    final b = bibleBooks.indexWhere((book) => book.id == other.bookId);
    final bookOrder = a.compareTo(b);
    return bookOrder == 0 ? chapter.compareTo(other.chapter) : bookOrder;
  }

  @override
  bool operator ==(Object other) =>
      other is BibleChapterRef &&
      other.bookId == bookId &&
      other.chapter == chapter;

  @override
  int get hashCode => Object.hash(bookId, chapter);
}

class BibleVerse {
  const BibleVerse({required this.number, required this.text});
  final int number;
  final String text;

  factory BibleVerse.fromJson(Object? json) {
    final m = wireMap(json, 'bible verse');
    final number = wireReq<int>(m, 'verse');
    final text = wireReq<String>(m, 'text');
    if (number < 1 || text.trim().isEmpty) {
      throw const FormatException('unexpected bible verse');
    }
    return BibleVerse(number: number, text: text);
  }

  Map<String, Object?> toJson() => {'verse': number, 'text': text};
}

class BibleTranslation {
  const BibleTranslation({
    required this.id,
    required this.code,
    required this.name,
    required this.chapters,
    required this.offlineAllowed,
  });

  factory BibleTranslation.fromJson(Object? json) {
    final m = wireMap(json, 'bible translation');
    final code = wireReq<String>(m, 'translation_code');
    if (!isBibleTranslationCode(code)) {
      throw const FormatException('unexpected translation_code');
    }
    final chapters = wireReq<List>(
      m,
      'chapters',
    ).map(BibleChapterRef.fromJson).toList()..sort();
    if (chapters.isEmpty || chapters.toSet().length != chapters.length) {
      throw const FormatException('unexpected translation chapters');
    }
    return BibleTranslation(
      id: _text(m, 'translation_id'),
      code: code,
      name: _text(m, 'name'),
      chapters: List.unmodifiable(chapters),
      offlineAllowed: wireReq<bool>(m, 'offline_allowed'),
    );
  }

  final String id;
  final String code;
  final String name;
  final List<BibleChapterRef> chapters;
  final bool offlineAllowed;

  bool hasChapter(BibleChapterRef ref) => chapters.contains(ref);
  BibleChapterRef? get firstChapter => chapters.isEmpty ? null : chapters.first;
}

/// Translation codes are extensible, but the database only returns or accepts
/// one when its complete trusted verse-count manifest is registered.
bool isBibleTranslationCode(String code) =>
    RegExp(r'^[A-Z0-9][A-Z0-9_-]{1,15}$').hasMatch(code);

class PublicBibleTranslations {
  const PublicBibleTranslations(this.translations);
  factory PublicBibleTranslations.fromJson(Object? json) {
    final m = wireMap(json, 'public bible translations');
    final rows = wireReq<List>(
      m,
      'translations',
    ).map(BibleTranslation.fromJson).toList();
    if (rows.map((row) => row.id).toSet().length != rows.length) {
      throw const FormatException('duplicate bible translation');
    }
    return PublicBibleTranslations(List.unmodifiable(rows));
  }
  final List<BibleTranslation> translations;
}

class PublicBibleChapter {
  const PublicBibleChapter({
    required this.translationId,
    required this.translationCode,
    required this.translationName,
    required this.reference,
    required this.verses,
    this.verseCount,
    this.omittedVerses = const [],
    required this.publicationRevision,
    required this.publishedAt,
    required this.offlineAllowed,
  });

  factory PublicBibleChapter.fromJson(Object? json) {
    final m = wireMap(json, 'public bible chapter');
    final ref = BibleChapterRef.fromJson(m);
    final code = wireReq<String>(m, 'translation_code');
    if (!isBibleTranslationCode(code)) {
      throw const FormatException('unexpected translation_code');
    }
    final verses = wireReq<List>(m, 'verses').map(BibleVerse.fromJson).toList();
    final verseCount = m['verse_count'] == null
        ? verses.lastOrNull?.number ?? 0
        : wireReq<int>(m, 'verse_count');
    final omittedVerses = _optionalVerseNumbers(m['omitted_verses']);
    final omissions = omittedVerses.toSet();
    final expected = [
      for (var number = 1; number <= verseCount; number++)
        if (!omissions.contains(number)) number,
    ];
    if (verseCount < 1 ||
        verseCount > 200 ||
        omittedVerses.length != omissions.length ||
        omittedVerses.any((number) => number < 1 || number > verseCount) ||
        verses.length != expected.length ||
        verses.indexed.any((e) => e.$2.number != expected[e.$1])) {
      throw const FormatException('incomplete bible chapter');
    }
    return PublicBibleChapter(
      translationId: _text(m, 'translation_id'),
      translationCode: code,
      translationName: _text(m, 'translation_name'),
      reference: ref,
      verses: List.unmodifiable(verses),
      verseCount: verseCount,
      omittedVerses: List.unmodifiable(omittedVerses),
      publicationRevision: wireRevision(m, 'publication_revision'),
      publishedAt: wireInstant(m, 'published_at'),
      offlineAllowed: wireReq<bool>(m, 'offline_allowed'),
    );
  }

  final String translationId;
  final String translationCode;
  final String translationName;
  final BibleChapterRef reference;
  final List<BibleVerse> verses;
  final int? verseCount;
  final List<int> omittedVerses;
  final int publicationRevision;
  final DateTime publishedAt;
  final bool offlineAllowed;

  Map<String, Object?> toCacheJson() => {
    'translation_id': translationId,
    'translation_code': translationCode,
    'translation_name': translationName,
    ...reference.toJson(),
    'verse_count': verseCount ?? verses.last.number,
    'omitted_verses': omittedVerses,
    'verses': verses.map((v) => v.toJson()).toList(),
    'publication_revision': publicationRevision,
    'published_at': publishedAt.toUtc().toIso8601String(),
    'offline_allowed': offlineAllowed,
  };

  factory PublicBibleChapter.fromCacheJson(Object? json) {
    final m = wireMap(json, 'cached bible chapter');
    if (m['offline_allowed'] != true) {
      throw const FormatException('offline rights are not cleared');
    }
    return PublicBibleChapter.fromJson(m);
  }

  static PublicBibleChapter? fromReadJson(Object? json) {
    final m = wireMap(json, 'public bible chapter read');
    if (!m.containsKey('chapter')) {
      throw const FormatException('missing chapter projection');
    }
    return m['chapter'] == null
        ? null
        : PublicBibleChapter.fromJson(m['chapter']);
  }
}

class BibleManifestChapter {
  const BibleManifestChapter({
    required this.reference,
    required this.verseCount,
    this.omittedVerses = const [],
  });
  final BibleChapterRef reference;

  /// Highest reference number in this chapter, including omitted slots.
  final int verseCount;
  final List<int> omittedVerses;
}

class BibleVerseManifest {
  const BibleVerseManifest({
    required this.translationCode,
    required this.version,
    required this.chapters,
  });
  factory BibleVerseManifest.fromJson(Object? json) {
    final m = wireMap(json, 'bible verse manifest');
    final code = wireReq<String>(m, 'translation_code');
    if (!isBibleTranslationCode(code)) {
      throw const FormatException('unknown manifest');
    }
    final rows = wireReq<List>(m, 'chapters').map((raw) {
      final c = wireMap(raw, 'manifest chapter');
      final count = wireReq<int>(c, 'verse_count');
      if (count < 1 || count > 200) {
        throw const FormatException('bad verse count');
      }
      final omittedVerses = _optionalVerseNumbers(c['omitted_verses']);
      if (omittedVerses.toSet().length != omittedVerses.length ||
          omittedVerses.any((number) => number < 1 || number > count)) {
        throw const FormatException('bad omitted verse numbers');
      }
      return BibleManifestChapter(
        reference: BibleChapterRef.fromJson(c),
        verseCount: count,
        omittedVerses: List.unmodifiable(omittedVerses),
      );
    }).toList();
    final refs = rows.map((row) => row.reference).toSet();
    final expectedChapterCount = bibleBooks.fold<int>(
      0,
      (total, book) => total + book.chapterCount,
    );
    final version = wireReq<int>(m, 'manifest_version');
    if (version < 1 ||
        refs.length != rows.length ||
        rows.length != expectedChapterCount) {
      throw const FormatException('incomplete Bible verse manifest');
    }
    return BibleVerseManifest(
      translationCode: code,
      version: version,
      chapters: List.unmodifiable(rows),
    );
  }
  final String translationCode;
  final int version;
  final List<BibleManifestChapter> chapters;
  int? count(BibleChapterRef ref) {
    for (final row in chapters) {
      if (row.reference == ref) return row.verseCount;
    }
    return null;
  }

  List<int> omittedVerses(BibleChapterRef ref) {
    for (final row in chapters) {
      if (row.reference == ref) return row.omittedVerses;
    }
    return const [];
  }
}

List<int> _optionalVerseNumbers(Object? value) {
  if (value == null) return const [];
  if (value is! List || value.any((number) => number is! int)) {
    throw const FormatException('bad omitted verse numbers');
  }
  final numbers = value.cast<int>();
  if (numbers.indexed.any(
    (entry) =>
        entry.$2 <= 0 || (entry.$1 > 0 && numbers[entry.$1 - 1] >= entry.$2),
  )) {
    throw const FormatException('bad omitted verse numbers');
  }
  return List.unmodifiable(numbers);
}

/// A typed Bible read. Public reads are allowed without an account; the
/// server returns only published text whose display rights are currently
/// clear. Offline writes remain a separate decision based on this projection.
abstract interface class BibleRepository {
  Future<AccessRead<PublicBibleTranslations>> fetchPublicTranslations();

  Future<AccessRead<PublicBibleChapter?>> fetchPublicChapter(
    String translationId,
    BibleChapterRef reference,
  );

  Future<AccessRead<BibleVerseManifest>> fetchVerseManifest(String code);

  Future<AccessRead<StaffBibleTranslations>> fetchStaffTranslations();
}

class UnconfiguredBibleRepository implements BibleRepository {
  const UnconfiguredBibleRepository();

  @override
  Future<AccessRead<PublicBibleTranslations>> fetchPublicTranslations() async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<PublicBibleChapter?>> fetchPublicChapter(
    String translationId,
    BibleChapterRef reference,
  ) async => const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<BibleVerseManifest>> fetchVerseManifest(
    String code,
  ) async => const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<StaffBibleTranslations>> fetchStaffTranslations() async =>
      const AccessReadDenied(AccessDenial.unavailable);
}

class SavedBibleChapter {
  const SavedBibleChapter({required this.chapter, required this.savedAt});
  final PublicBibleChapter chapter;
  final DateTime savedAt;
}

class StaffBibleTranslation {
  const StaffBibleTranslation({
    required this.id,
    required this.revision,
    required this.code,
    required this.name,
    required this.state,
    required this.lastRevisionNo,
    required this.draftRevisionNo,
    required this.liveRevisionNo,
    required this.draftComplete,
    required this.draftVerseCount,
    required this.displayRightsError,
    required this.offlineAllowed,
  });
  factory StaffBibleTranslation.fromJson(Object? json) {
    final m = wireMap(json, 'staff bible translation');
    return StaffBibleTranslation(
      id: _text(m, 'translation_id'),
      revision: wireRevision(m),
      code: wireReq<String>(m, 'translation_code'),
      name: _text(m, 'name'),
      state: ContentState.parse(m['state']),
      lastRevisionNo: wireReq<int>(m, 'last_revision_no'),
      draftRevisionNo: wireOpt<int>(m, 'draft_revision_no'),
      liveRevisionNo: wireOpt<int>(m, 'live_revision_no'),
      draftComplete: wireReq<bool>(m, 'draft_complete'),
      draftVerseCount: wireReq<int>(m, 'draft_verse_count'),
      displayRightsError: wireOpt<String>(m, 'display_rights_error'),
      offlineAllowed: wireReq<bool>(m, 'offline_allowed'),
    );
  }
  final String id;
  final int revision;
  final String code;
  final String name;
  final ContentState state;
  final int lastRevisionNo;
  final int? draftRevisionNo;
  final int? liveRevisionNo;
  final bool draftComplete;
  final int draftVerseCount;
  final String? displayRightsError;
  final bool offlineAllowed;
}

class StaffBibleTranslations {
  const StaffBibleTranslations({
    required this.capacity,
    required this.translations,
  });
  factory StaffBibleTranslations.fromJson(Object? json) {
    final m = wireMap(json, 'staff bible translations');
    final capacity = wireReq<String>(m, 'capacity');
    if (!const [
      ChurchRoles.admin,
      ChurchRoles.pastor,
      ChurchRoles.media,
    ].contains(capacity)) {
      throw const FormatException('unexpected capacity');
    }
    return StaffBibleTranslations(
      capacity: capacity,
      translations: List.unmodifiable(
        wireReq<List>(m, 'translations').map(StaffBibleTranslation.fromJson),
      ),
    );
  }
  final String capacity;
  final List<StaffBibleTranslation> translations;
}

abstract final class BibleCommands {
  static const create = 'content.create_bible_translation';
  static const beginRevision = 'content.begin_bible_revision';
  static const importVerses = 'content.import_bible_verses';
  static const finalize = 'content.finalize_bible_revision';
  static const publish = 'content.publish_bible_translation';
  static const withdraw = 'content.withdraw_bible_translation';
  static const archive = 'content.archive_bible_translation';
  static const commandFunction = 'content_command';
}

const bibleCsvMaxBytes = 10 * 1024 * 1024;

const bibleCsvBatchSize = 200;

class BibleCsvRow {
  const BibleCsvRow({
    required this.bookId,
    required this.chapter,
    required this.verse,
    required this.text,
    required this.row,
  });
  final String bookId;
  final int chapter;
  final int verse;
  final String text;
  final int row;
  Map<String, Object?> toJson() => {
    'book_id': bookId,
    'chapter': chapter,
    'verse': verse,
    'text': text,
  };
}

class BibleCsvError {
  const BibleCsvError(this.row, this.field, this.message);
  final int row;
  final String field;
  final String message;
  @override
  String toString() => 'Row $row · $field: $message';
}

class BibleCsvResult {
  const BibleCsvResult({required this.rows, required this.errors});
  final List<BibleCsvRow> rows;
  final List<BibleCsvError> errors;
  bool get valid => errors.isEmpty && rows.isNotEmpty;
}

/// Parses UTF-8 CSV (`book,chapter,verse,text`) without a third-party parser.
/// All validation runs before a command is sent. A chapter included in the
/// file must match its trusted translation manifest exactly; omitted chapters
/// are allowed for partial corpora.
BibleCsvResult parseBibleCsv(String input, BibleVerseManifest manifest) {
  if (input.startsWith('\uFEFF')) input = input.substring(1);
  final errors = <BibleCsvError>[];
  final matrix = _parseCsv(input, errors);
  if (matrix.isEmpty) {
    return BibleCsvResult(rows: const [], errors: List.unmodifiable(errors));
  }
  final header = matrix.first.map((v) => v.trim().toLowerCase()).toList();
  if (header.length != 4 || header.join(',') != 'book,chapter,verse,text') {
    errors.add(
      const BibleCsvError(1, 'header', 'Expected book,chapter,verse,text'),
    );
    return BibleCsvResult(rows: const [], errors: List.unmodifiable(errors));
  }
  final rows = <BibleCsvRow>[];
  final seen = <String, int>{};
  final counts = <BibleChapterRef, List<int>>{};
  final chapterFirstRow = <BibleChapterRef, int>{};
  final codeByName = {
    for (final b in bibleBooks) _normalBookName(b.name): b.id,
  };
  for (var index = 1; index < matrix.length; index++) {
    final line = index + 1;
    final fields = matrix[index];
    if (fields.length != 4) {
      errors.add(BibleCsvError(line, 'row', 'Expected 4 fields'));
      continue;
    }
    final rawBook = fields[0].trim();
    final bookId =
        bibleBook(rawBook.toUpperCase())?.id ??
        codeByName[_normalBookName(rawBook)];
    final chapter = int.tryParse(fields[1].trim());
    final verse = int.tryParse(fields[2].trim());
    final text = fields[3].trim();
    if (bookId == null) {
      errors.add(BibleCsvError(line, 'book', 'Unknown canonical book'));
    }
    if (chapter == null ||
        chapter < 1 ||
        (bookId != null && chapter > bibleBook(bookId)!.chapterCount)) {
      errors.add(
        BibleCsvError(line, 'chapter', 'Chapter is outside this book'),
      );
    }
    if (verse == null || verse < 1 || verse > 200) {
      errors.add(BibleCsvError(line, 'verse', 'Verse must be 1–200'));
    }
    if (bookId == null || chapter == null || verse == null) {
      if (text.isEmpty) {
        errors.add(BibleCsvError(line, 'text', 'Verse text is required'));
      }
      continue;
    }
    final ref = BibleChapterRef(bookId: bookId, chapter: chapter);
    final expected = manifest.count(ref);
    if (expected == null) {
      errors.add(
        BibleCsvError(
          line,
          'chapter',
          'No trusted ${manifest.translationCode} manifest entry',
        ),
      );
      continue;
    }
    final omitted = manifest.omittedVerses(ref).contains(verse);
    if (text.isEmpty != omitted) {
      errors.add(
        BibleCsvError(
          line,
          'text',
          omitted
              ? 'This verse must stay blank in the trusted source'
              : 'Verse text is required',
        ),
      );
      continue;
    }
    final key = '${ref.bookId}:$chapter:$verse';
    final first = seen.putIfAbsent(key, () => line);
    if (first != line) {
      errors.add(
        BibleCsvError(line, 'verse', 'Duplicate verse (first at row $first)'),
      );
      continue;
    }
    if (verse > expected) {
      errors.add(
        BibleCsvError(
          line,
          'verse',
          'Exceeds the ${manifest.translationCode} chapter count ($expected)',
        ),
      );
      continue;
    }
    rows.add(
      BibleCsvRow(
        bookId: bookId,
        chapter: chapter,
        verse: verse,
        text: text,
        row: line,
      ),
    );
    chapterFirstRow.putIfAbsent(ref, () => line);
    (counts[ref] ??= <int>[]).add(verse);
  }
  for (final entry in counts.entries) {
    final actual = entry.value..sort();
    final expected = manifest.count(entry.key)!;
    final good =
        actual.length == expected &&
        actual.first == 1 &&
        actual.last == expected &&
        actual.indexed.every((e) => e.$1 + 1 == e.$2);
    if (!good) {
      errors.add(
        BibleCsvError(
          chapterFirstRow[entry.key] ?? 2,
          entry.key.bookId,
          'Chapter ${entry.key.chapter} must contain all $expected verses in order',
        ),
      );
    }
  }
  return BibleCsvResult(
    rows: List.unmodifiable(rows),
    errors: List.unmodifiable(errors),
  );
}

/// Reads the bundled eBible.org VPL package, preserving its canonical verse
/// references and the source's explicitly blank verse slots.
BibleCsvResult parseBibleVpl(String input, BibleVerseManifest manifest) {
  final errors = <BibleCsvError>[];
  final rows = <BibleCsvRow>[];
  final seen = <String, int>{};
  final counts = <BibleChapterRef, List<int>>{};
  const aliases = {
    '1JO': '1JN',
    '2JO': '2JN',
    '3JO': '3JN',
    'EZE': 'EZK',
    'JAM': 'JAS',
    'JOE': 'JOL',
    'JOH': 'JHN',
    'MAR': 'MRK',
    'NAH': 'NAM',
    'PHI': 'PHP',
    'SOL': 'SNG',
  };
  final chapterFirstRow = <BibleChapterRef, int>{};
  final lines = input.split('\n');
  for (var index = 0; index < lines.length; index++) {
    final raw = lines[index].replaceFirst(RegExp(r'\r$'), '');
    if (raw.isEmpty) continue;
    final firstSpace = raw.indexOf(' ');
    final secondSpace = firstSpace < 0 ? -1 : raw.indexOf(' ', firstSpace + 1);
    final line = index + 1;
    if (firstSpace < 1 || secondSpace < 0) {
      errors.add(BibleCsvError(line, 'row', 'Invalid WEB package row'));
      continue;
    }
    final bookId =
        aliases[raw.substring(0, firstSpace)] ?? raw.substring(0, firstSpace);
    final ref = raw.substring(firstSpace + 1, secondSpace).split(':');
    if (ref.length != 2) {
      errors.add(BibleCsvError(line, 'reference', 'Invalid WEB reference'));
      continue;
    }
    final chapter = int.tryParse(ref[0]);
    final verse = int.tryParse(ref[1]);
    final text = raw.substring(secondSpace + 1).trim();
    final book = bibleBook(bookId);
    if (book == null ||
        chapter == null ||
        chapter < 1 ||
        chapter > book.chapterCount ||
        verse == null ||
        verse < 1 ||
        verse > 200) {
      errors.add(BibleCsvError(line, 'reference', 'Invalid WEB reference'));
      continue;
    }
    final chapterRef = BibleChapterRef(bookId: bookId, chapter: chapter);
    final maximum = manifest.count(chapterRef);
    if (maximum == null || verse > maximum) {
      errors.add(
        BibleCsvError(
          line,
          'reference',
          'Reference is outside the WEB manifest',
        ),
      );
      continue;
    }
    final omitted = manifest.omittedVerses(chapterRef).contains(verse);
    if (text.isEmpty != omitted) {
      errors.add(
        BibleCsvError(
          line,
          'text',
          omitted
              ? 'This verse must stay blank in the trusted source'
              : 'WEB package verse text is missing',
        ),
      );
      continue;
    }
    final key = '$bookId:$chapter:$verse';
    final first = seen.putIfAbsent(key, () => line);
    if (first != line) {
      errors.add(BibleCsvError(line, 'reference', 'Duplicate WEB reference'));
      continue;
    }
    rows.add(
      BibleCsvRow(
        bookId: bookId,
        chapter: chapter,
        verse: verse,
        text: text,
        row: line,
      ),
    );
    chapterFirstRow.putIfAbsent(chapterRef, () => line);
    (counts[chapterRef] ??= <int>[]).add(verse);
  }

  for (final chapter in manifest.chapters) {
    final actual = counts[chapter.reference] ?? const <int>[];
    final good =
        actual.length == chapter.verseCount &&
        actual.indexed.every((entry) => entry.$1 + 1 == entry.$2);
    if (!good) {
      errors.add(
        BibleCsvError(
          chapterFirstRow[chapter.reference] ?? 1,
          chapter.reference.bookId,
          'WEB package chapter ${chapter.reference.chapter} is incomplete',
        ),
      );
    }
  }
  rows.sort((a, b) {
    final refOrder = BibleChapterRef(
      bookId: a.bookId,
      chapter: a.chapter,
    ).compareTo(BibleChapterRef(bookId: b.bookId, chapter: b.chapter));
    return refOrder == 0 ? a.verse.compareTo(b.verse) : refOrder;
  });
  return BibleCsvResult(
    rows: List.unmodifiable(rows),
    errors: List.unmodifiable(errors),
  );
}

/// A translation package reader is supplied by the client composition root.
abstract interface class BibleTranslationPackageSource {
  Future<String> loadWorldEnglishBibleVpl();
}

class NoBibleTranslationPackageSource implements BibleTranslationPackageSource {
  const NoBibleTranslationPackageSource();

  @override
  Future<String> loadWorldEnglishBibleVpl() =>
      Future.error(UnsupportedError('No Bible package source is configured'));
}

String _normalBookName(String name) =>
    name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

List<List<String>> _parseCsv(String input, List<BibleCsvError> errors) {
  final rows = <List<String>>[];
  final row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  var quoteClosed = false;
  var line = 1;
  for (var i = 0; i < input.length; i++) {
    final ch = input[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < input.length && input[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
          quoteClosed = true;
        }
      } else {
        field.write(ch);
        if (ch == '\n') line++;
      }
    } else if (quoteClosed && ch == ',') {
      row.add(field.toString());
      field.clear();
      quoteClosed = false;
    } else if (quoteClosed && ch == '\n') {
      row.add(field.toString().replaceFirst(RegExp(r'\r$'), ''));
      field.clear();
      if (row.any((v) => v.trim().isNotEmpty)) rows.add(List.unmodifiable(row));
      row.clear();
      line++;
      quoteClosed = false;
    } else if (quoteClosed && (ch == ' ' || ch == '\t' || ch == '\r')) {
      // RFC 4180 permits no text after a closing quote; tolerate surrounding horizontal space.
    } else if (quoteClosed) {
      errors.add(
        BibleCsvError(line, 'csv', 'Unexpected text after a closing quote'),
      );
      field.write(ch);
      quoteClosed = false;
    } else if (ch == '"' && field.isEmpty) {
      quoted = true;
    } else if (ch == '"') {
      errors.add(BibleCsvError(line, 'csv', 'Quote must begin a field'));
      field.write(ch);
    } else if (ch == ',') {
      row.add(field.toString());
      field.clear();
    } else if (ch == '\n') {
      row.add(field.toString().replaceFirst(RegExp(r'\r$'), ''));
      field.clear();
      if (row.any((v) => v.trim().isNotEmpty)) rows.add(List.unmodifiable(row));
      row.clear();
      line++;
    } else {
      field.write(ch);
    }
  }
  if (quoted) errors.add(BibleCsvError(line, 'csv', 'Unclosed quoted field'));
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString().replaceFirst(RegExp(r'\r$'), ''));
    if (row.any((v) => v.trim().isNotEmpty)) rows.add(List.unmodifiable(row));
  }
  return rows;
}
