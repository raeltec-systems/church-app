import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:church_contracts/church_contracts.dart';
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _translationId = '61616161-6161-4161-8161-616161616161';
const _webId = '62626262-6262-4262-8262-626262626262';
const _rightsId = '71717171-7171-4171-8171-717171717171';
final _savedAt = DateTime.utc(2026, 10, 23, 8, 30);

BibleChapterRef _ref(String book, int chapter) =>
    BibleChapterRef(bookId: book, chapter: chapter);

PublicBibleChapter _chapter(
  String translationId,
  String code,
  String name,
  BibleChapterRef reference, {
  bool offlineAllowed = true,
  int verseCount = 2,
}) => PublicBibleChapter(
  translationId: translationId,
  translationCode: code,
  translationName: name,
  reference: reference,
  verses: List.generate(
    verseCount,
    (index) =>
        BibleVerse(number: index + 1, text: 'SYNTHETIC verse ${index + 1}'),
  ),
  publicationRevision: 1,
  publishedAt: DateTime.utc(2026, 10, 22),
  offlineAllowed: offlineAllowed,
);

BibleVerseManifest _manifest({
  int genesisOne = 2,
  int genesisTwo = 2,
  String translationCode = 'KJV',
  List<int> genesisOneOmitted = const [],
}) {
  final chapters = [
    for (final book in bibleBooks)
      for (var chapter = 1; chapter <= book.chapterCount; chapter++)
        BibleManifestChapter(
          reference: _ref(book.id, chapter),
          verseCount: book.id == 'GEN' && chapter == 1
              ? genesisOne
              : book.id == 'GEN' && chapter == 2
              ? genesisTwo
              : 1,
          omittedVerses: book.id == 'GEN' && chapter == 1
              ? genesisOneOmitted
              : const [],
        ),
  ];
  return BibleVerseManifest(
    translationCode: translationCode,
    version: translationCode == 'WEB' ? 2 : 1,
    chapters: chapters,
  );
}

Map<String, Object?> _manifestWire({int? missingLast = 0}) {
  final all = [
    for (final book in bibleBooks)
      for (var chapter = 1; chapter <= book.chapterCount; chapter++)
        {
          'book_id': book.id,
          'chapter': chapter,
          'verse_count': book.id == 'GEN' && chapter == 1 ? 2 : 1,
        },
  ];
  if (missingLast != 0) all.removeLast();
  return {'translation_code': 'KJV', 'manifest_version': 1, 'chapters': all};
}

void main() {
  group('Bible projections and CSV import', () {
    test('the canonical book map has 66 books in navigation order', () {
      expect(bibleBooks, hasLength(66));
      expect(bibleBooks.first.id, 'GEN');
      expect(bibleBooks.last.id, 'REV');
      expect(_ref('GEN', 1).compareTo(_ref('EXO', 1)), lessThan(0));
      expect(_ref('EXO', 1).compareTo(_ref('GEN', 50)), greaterThan(0));
    });

    test(
      'public chapter parser rejects display-only text from offline cache',
      () {
        final chapter = _chapter(
          _translationId,
          'KJV',
          'King James Version',
          _ref('GEN', 1),
          offlineAllowed: false,
        );
        expect(
          () => PublicBibleChapter.fromCacheJson(chapter.toCacheJson()),
          throwsFormatException,
        );
        expect(
          PublicBibleChapter.fromCacheJson(
            _chapter(
              _translationId,
              'KJV',
              'KJV',
              _ref('GEN', 1),
            ).toCacheJson(),
          ).reference,
          _ref('GEN', 1),
        );
      },
    );

    test('trusted manifests are complete, unique, and versioned', () {
      final parsed = BibleVerseManifest.fromJson(_manifestWire());
      expect(parsed.version, 1);
      expect(parsed.count(_ref('GEN', 1)), 2);
      expect(isBibleTranslationCode('TST99'), isTrue);
      expect(isBibleTranslationCode('invalid code'), isFalse);
      final incomplete = _manifestWire(missingLast: 1);
      expect(
        () => BibleVerseManifest.fromJson(incomplete),
        throwsFormatException,
      );
    });

    test('public WEB chapters retain omitted verse numbers', () {
      final chapter = PublicBibleChapter.fromJson({
        'translation_id': _webId,
        'translation_code': 'WEB',
        'translation_name': 'World English Bible',
        'book_id': 'GEN',
        'chapter': 1,
        'verse_count': 3,
        'omitted_verses': [2],
        'verses': [
          {'verse': 1, 'text': 'SYNTHETIC first'},
          {'verse': 3, 'text': 'SYNTHETIC third'},
        ],
        'publication_revision': 1,
        'published_at': '2026-10-22T08:00:00Z',
        'offline_allowed': true,
      });
      expect(chapter.verses.map((verse) => verse.number), [1, 3]);
      expect(chapter.omittedVerses, [2]);
      expect(
        PublicBibleChapter.fromCacheJson(chapter.toCacheJson()).omittedVerses,
        [2],
      );
      expect(
        () => PublicBibleChapter.fromJson({
          ...chapter.toCacheJson(),
          'omitted_verses': <int>[],
        }),
        throwsFormatException,
      );
    });

    test('CSV accepts a partial corpus and quoted commas after validating full chapters', () {
      final result = parseBibleCsv(
        '\uFEFFbook,chapter,verse,text\r\n'
        'Genesis,1,1,"SYNTHETIC first, verse"\r\n'
        'GEN,1,2,"SYNTHETIC said ""hello"""\r\n'
        'Exodus,1,1,SYNTHETIC partial second book\r\n',
        _manifest(),
      );
      expect(result.valid, isTrue, reason: '${result.errors}');
      expect(result.rows, hasLength(3));
      expect(result.rows.first.text, 'SYNTHETIC first, verse');
      expect(result.rows[1].text, 'SYNTHETIC said "hello"');
      expect(result.rows.last.bookId, 'EXO');
    });

    test('CSV reports missing terminal, duplicate, invalid and empty rows', () {
      final missingTerminal = parseBibleCsv(
        'book,chapter,verse,text\nGenesis,1,1,one\n',
        _manifest(),
      );
      expect(missingTerminal.valid, isFalse);
      expect(missingTerminal.errors, hasLength(1));
      expect(missingTerminal.errors.single.message, contains('all 2 verses'));

      final invalid = parseBibleCsv(
        'book,chapter,verse,text\n'
        'Genesis,1,1,one\n'
        'GEN,1,1,duplicate\n'
        'Unknown,0,201,  \n',
        _manifest(),
      );
      expect(invalid.valid, isFalse);
      expect(
        invalid.errors.map((e) => e.field),
        containsAll(['verse', 'book', 'chapter', 'text']),
      );
      expect(
        invalid.errors.any((e) => e.message.contains('Duplicate')),
        isTrue,
      );
    });

    test('CSV preserves only manifest-declared blank verse slots', () {
      final manifest = _manifest(
        genesisOne: 3,
        genesisTwo: 1,
        translationCode: 'WEB',
        genesisOneOmitted: const [2],
      );
      final accepted = parseBibleCsv(
        'book,chapter,verse,text\n'
        'GEN,1,1,SYNTHETIC first\n'
        'GEN,1,2,\n'
        'GEN,1,3,SYNTHETIC third\n',
        manifest,
      );
      expect(accepted.valid, isTrue, reason: '${accepted.errors}');
      expect(accepted.rows[1].text, isEmpty);
      final invented = parseBibleCsv(
        'book,chapter,verse,text\n'
        'GEN,1,1,SYNTHETIC first\n'
        'GEN,1,2,SYNTHETIC invented\n'
        'GEN,1,3,SYNTHETIC third\n',
        manifest,
      );
      expect(invented.valid, isFalse);
      expect(
        invented.errors.any(
          (error) => error.message.contains('must stay blank'),
        ),
        isTrue,
      );
    });

    test('WEB VPL parser validates all chapters and source omissions', () {
      final manifest = _manifest(
        genesisOne: 3,
        genesisTwo: 1,
        translationCode: 'WEB',
        genesisOneOmitted: const [2],
      );
      final source = StringBuffer();
      for (final book in bibleBooks) {
        for (var chapter = 1; chapter <= book.chapterCount; chapter++) {
          final reference = _ref(book.id, chapter);
          for (var verse = 1; verse <= manifest.count(reference)!; verse++) {
            final omitted = manifest.omittedVerses(reference).contains(verse);
            source.writeln(
              '${book.id} $chapter:$verse ${omitted ? '' : 'SYNTHETIC ${book.id} $chapter $verse'}',
            );
          }
        }
      }
      final result = parseBibleVpl(source.toString(), manifest);
      expect(result.valid, isTrue, reason: '${result.errors}');
      expect(result.rows, hasLength(1191));
      expect(
        result.rows
            .singleWhere(
              (row) =>
                  row.bookId == 'GEN' && row.chapter == 1 && row.verse == 2,
            )
            .text,
        isEmpty,
      );
      expect(
        parseBibleVpl('GEN 1:1 SYNTHETIC incomplete\n', manifest).valid,
        isFalse,
      );
    });
  });

  group('Bible reader controller', () {
    test(
      'cold launch restores an offline chapter before a failed catalog read',
      () async {
        final h = ClientTestHarness(account: null)
          ..bible.translations = const AccessReadFailed(unreachable: true)
          ..publicContentCache.bibleChapter = PublicContentSnapshot(
            value: _chapter(
              _translationId,
              'KJV',
              'King James Version',
              _ref('GEN', 1),
            ),
            savedAt: _savedAt,
          );
        final container = ProviderContainer(overrides: h.overrides());
        addTearDown(container.dispose);
        final sub = container.listen(bibleReaderProvider, (_, _) {});
        addTearDown(sub.close);

        await container.read(bibleReaderProvider.notifier).reload();
        final state = container.read(bibleReaderProvider);
        expect(state.value?.translationCode, 'KJV');
        expect(state.reference, _ref('GEN', 1));
        expect(state.savedAt, _savedAt);
        expect(state.offlineSnapshot, isTrue);
        expect(
          state.catalogError,
          isA<AccessReadFailed<PublicBibleTranslations>>(),
        );
        expect(
          h.publicContentCache.reads.first,
          PublicContentCacheKeys.bibleChapter,
        );
      },
    );

    test('empty catalog keeps a saved chapter available offline', () async {
      final savedChapter = _chapter(
        _translationId,
        'KJV',
        'King James Version',
        _ref('GEN', 1),
      );
      final h = ClientTestHarness(account: null)
        ..bible.translations = AccessReadOk(PublicBibleTranslations(const []))
        ..publicContentCache.bibleChapter = PublicContentSnapshot(
          value: savedChapter,
          savedAt: _savedAt,
        );
      final container = ProviderContainer(overrides: h.overrides());
      addTearDown(container.dispose);
      final sub = container.listen(bibleReaderProvider, (_, _) {});
      addTearDown(sub.close);

      await container.read(bibleReaderProvider.notifier).reload();
      final state = container.read(bibleReaderProvider);
      expect(state.translations?.translations, isEmpty);
      expect(state.value, savedChapter);
      expect(state.reference, _ref('GEN', 1));
      expect(state.translationId, _translationId);
      expect(state.offlineSnapshot, isTrue);
      expect(state.savedOffline, isTrue);
    });

    test(
      'switches translation and follows only available canonical chapters',
      () async {
        final kjv = BibleTranslation(
          id: _translationId,
          code: 'KJV',
          name: 'King James Version',
          chapters: [_ref('GEN', 1), _ref('EXO', 1)],
          offlineAllowed: false,
        );
        final web = BibleTranslation(
          id: _webId,
          code: 'WEB',
          name: 'World English Bible',
          chapters: [_ref('GEN', 1)],
          offlineAllowed: false,
        );
        final h = ClientTestHarness(account: null)
          ..bible.translations = AccessReadOk(
            PublicBibleTranslations([kjv, web]),
          )
          ..bible.chapters[(_translationId, _ref('GEN', 1))] = AccessReadOk(
            _chapter(
              _translationId,
              'KJV',
              'King James Version',
              _ref('GEN', 1),
            ),
          )
          ..bible.chapters[(_translationId, _ref('EXO', 1))] = AccessReadOk(
            _chapter(
              _translationId,
              'KJV',
              'King James Version',
              _ref('EXO', 1),
            ),
          )
          ..bible.chapters[(_webId, _ref('GEN', 1))] = AccessReadOk(
            _chapter(_webId, 'WEB', 'World English Bible', _ref('GEN', 1)),
          );
        final container = ProviderContainer(overrides: h.overrides());
        addTearDown(container.dispose);
        final sub = container.listen(bibleReaderProvider, (_, _) {});
        addTearDown(sub.close);
        final controller = container.read(bibleReaderProvider.notifier);

        await controller.reload();
        expect(container.read(bibleReaderProvider).next, _ref('EXO', 1));
        await controller.chooseTranslation(_webId);
        expect(
          container.read(bibleReaderProvider).selectedTranslation?.code,
          'WEB',
        );
        expect(container.read(bibleReaderProvider).next, isNull);
        await controller.chooseTranslation(_translationId);
        await controller.move(true);
        expect(container.read(bibleReaderProvider).reference, _ref('EXO', 1));
        expect(h.bible.chapterCalls.last, (_translationId, _ref('EXO', 1)));
      },
    );

    test('reconnect restores browsing after a saved offline launch', () async {
      final saved = _chapter(
        _translationId,
        'KJV',
        'SYNTHETIC Bible',
        _ref('GEN', 1),
      );
      final h = ClientTestHarness(account: null)
        ..bible.translations = const AccessReadFailed(unreachable: true)
        ..publicContentCache.bibleChapter = PublicContentSnapshot(
          value: saved,
          savedAt: _savedAt,
        );
      final reconnects = StreamController<void>.broadcast(sync: true);
      addTearDown(reconnects.close);
      final container = ProviderContainer(
        overrides: [
          ...h.overrides(),
          publicContentReconnectsProvider.overrideWith(
            (ref) => reconnects.stream,
          ),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(bibleReaderProvider, (_, _) {});
      addTearDown(sub.close);
      await container.read(bibleReaderProvider.notifier).reload();
      expect(container.read(bibleReaderProvider).offlineSnapshot, isTrue);

      h.bible.translations = AccessReadOk(
        PublicBibleTranslations([
          BibleTranslation(
            id: _translationId,
            code: 'KJV',
            name: 'SYNTHETIC Bible',
            chapters: [_ref('GEN', 1), _ref('EXO', 1)],
            offlineAllowed: true,
          ),
        ]),
      );
      h.bible.chapters[(_translationId, _ref('GEN', 1))] = AccessReadOk(saved);
      reconnects.add(null);
      await Future<void>.delayed(Duration.zero);
      await container.pump();

      expect(container.read(bibleReaderProvider).offlineSnapshot, isFalse);
      expect(container.read(bibleReaderProvider).next, _ref('EXO', 1));
      expect(container.read(bibleReaderProvider).catalogError, isNull);
    });

    test('a delayed save cannot mark a different chapter as saved', () async {
      final h = ClientTestHarness(account: null)
        ..bible.translations = AccessReadOk(
          PublicBibleTranslations([
            BibleTranslation(
              id: _translationId,
              code: 'KJV',
              name: 'SYNTHETIC Bible',
              chapters: [_ref('GEN', 1), _ref('EXO', 1)],
              offlineAllowed: true,
            ),
          ]),
        );
      for (final book in ['GEN', 'EXO']) {
        h.bible.chapters[(_translationId, _ref(book, 1))] = AccessReadOk(
          _chapter(_translationId, 'KJV', 'SYNTHETIC Bible', _ref(book, 1)),
        );
      }
      final cache = _DelayedBibleCache();
      final container = ProviderContainer(
        overrides: [
          ...h.overrides(configured: false),
          bibleRepositoryProvider.overrideWithValue(h.bible),
          publicContentCacheProvider.overrideWithValue(cache),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(bibleReaderProvider, (_, _) {});
      addTearDown(sub.close);
      final controller = container.read(bibleReaderProvider.notifier);
      await controller.reload();
      final pending = controller.saveOffline();
      expect(container.read(bibleReaderProvider).saving, isTrue);
      await controller.move(true);
      cache.pending.complete(
        PublicContentCacheSaved(savedAt: _savedAt, savedRows: 2),
      );
      await pending;

      final state = container.read(bibleReaderProvider);
      expect(state.reference, _ref('EXO', 1));
      expect(state.saving, isFalse);
      expect(state.savedOffline, isFalse);
      expect(state.savedAt, isNull);
      expect(state.message, isNull);
    });

    test('saves only an offline-cleared public projection', () async {
      final translation = BibleTranslation(
        id: _translationId,
        code: 'KJV',
        name: 'King James Version',
        chapters: [_ref('GEN', 1)],
        offlineAllowed: true,
      );
      final chapter = _chapter(
        _translationId,
        'KJV',
        'King James Version',
        _ref('GEN', 1),
      );
      final h = ClientTestHarness(account: null)
        ..bible.translations = AccessReadOk(
          PublicBibleTranslations([translation]),
        )
        ..bible.chapters[(_translationId, _ref('GEN', 1))] = AccessReadOk(
          chapter,
        )
        ..publicContentCache.available = true;
      final container = ProviderContainer(overrides: h.overrides());
      addTearDown(container.dispose);
      final sub = container.listen(bibleReaderProvider, (_, _) {});
      addTearDown(sub.close);
      final controller = container.read(bibleReaderProvider.notifier);

      await controller.reload();
      await controller.saveOffline();
      expect(
        h.publicContentCache.writes.single.$1,
        PublicContentCacheKeys.bibleChapter,
      );
      expect(
        h.publicContentCache.bibleChapter?.value.reference,
        _ref('GEN', 1),
      );
      expect(container.read(bibleReaderProvider).savedOffline, isTrue);
    });

    test(
      'failed refresh does not claim an in-memory chapter was saved',
      () async {
        final translation = BibleTranslation(
          id: _translationId,
          code: 'KJV',
          name: 'King James Version',
          chapters: [_ref('GEN', 1)],
          offlineAllowed: true,
        );
        final chapter = _chapter(
          _translationId,
          'KJV',
          'King James Version',
          _ref('GEN', 1),
        );
        final h = ClientTestHarness(account: null)
          ..bible.translations = AccessReadOk(
            PublicBibleTranslations([translation]),
          )
          ..bible.chapters[(_translationId, _ref('GEN', 1))] = AccessReadOk(
            chapter,
          );
        final container = ProviderContainer(overrides: h.overrides());
        addTearDown(container.dispose);
        final sub = container.listen(bibleReaderProvider, (_, _) {});
        addTearDown(sub.close);
        final controller = container.read(bibleReaderProvider.notifier);

        await controller.reload();
        h.bible.chapters[(_translationId, _ref('GEN', 1))] =
            const AccessReadFailed(unreachable: true);
        await controller.reload();

        final state = container.read(bibleReaderProvider);
        expect(state.value?.reference, _ref('GEN', 1));
        expect(state.offlineSnapshot, isFalse);
        expect(state.savedOffline, isFalse);
        expect(state.savedAt, isNull);
        expect(
          state.chapterError,
          isA<AccessReadFailed<PublicBibleChapter?>>(),
        );
      },
    );
  });

  test(
    'staff imports validate before creating and chunk complete revisions',
    () async {
      final manifest = _manifest(genesisOne: 150, genesisTwo: 51);
      final current = StaffBibleTranslation(
        id: _translationId,
        revision: 7,
        code: 'KJV',
        name: 'King James Version',
        state: ContentState.draft,
        lastRevisionNo: 4,
        draftRevisionNo: 4,
        liveRevisionNo: null,
        draftComplete: false,
        draftVerseCount: 0,
        displayRightsError: null,
        offlineAllowed: false,
      );
      final h = ClientTestHarness()
        ..bible.staff = AccessReadOk(
          StaffBibleTranslations(
            capacity: ChurchRoles.media,
            translations: [current],
          ),
        )
        ..bible.manifests['KJV'] = AccessReadOk(manifest);
      final gateway = _BibleAutoGateway();
      h.commandGateway = gateway;
      final container = ProviderContainer(overrides: h.overrides());
      addTearDown(container.dispose);
      final sub = container.listen(bibleStaffProvider, (_, _) {});
      addTearDown(sub.close);
      final controller = container.read(bibleStaffProvider.notifier);
      await controller.reload();

      final incomplete = 'book,chapter,verse,text\nGenesis,1,1,one\n';
      await controller.importCsv(
        translationId: _translationId,
        code: 'KJV',
        name: current.name,
        rightsId: _rightsId,
        file: PickedFile(
          name: 'bad.csv',
          declaredType: 'text/csv',
          bytes: Uint8List.fromList(utf8.encode(incomplete)),
        ),
      );
      expect(gateway.requests, isEmpty);
      expect(container.read(bibleStaffProvider).errors, isNotEmpty);

      final csv = StringBuffer('book,chapter,verse,text\n');
      for (var verse = 1; verse <= 150; verse++) {
        csv.writeln('GEN,1,$verse,SYNTHETIC Genesis 1 verse $verse');
      }
      for (var verse = 1; verse <= 51; verse++) {
        csv.writeln('GEN,2,$verse,SYNTHETIC Genesis 2 verse $verse');
      }
      await controller.importCsv(
        translationId: _translationId,
        code: 'KJV',
        name: current.name,
        rightsId: _rightsId,
        file: PickedFile(
          name: 'valid.csv',
          declaredType: 'text/csv',
          bytes: Uint8List.fromList(utf8.encode(csv.toString())),
        ),
      );

      expect(gateway.requests.map((r) => r.command), [
        BibleCommands.beginRevision,
        BibleCommands.importVerses,
        BibleCommands.importVerses,
        BibleCommands.finalize,
      ]);
      expect(gateway.requests.first.expectedRevision.value, 7);
      expect(gateway.requests.first.payload['manifest_version'], 1);
      expect(gateway.requests[1].payload['revision_no'], 5);
      expect((gateway.requests[1].payload['rows'] as List), hasLength(200));
      expect((gateway.requests[2].payload['rows'] as List), hasLength(1));
      expect(container.read(bibleStaffProvider).busy, isFalse);
      expect(
        container.read(bibleStaffProvider).message,
        contains('Complete draft'),
      );
    },
  );

  test('staff installs bundled WEB without a file upload', () async {
    final manifest = _manifest(
      genesisOne: 3,
      genesisTwo: 1,
      translationCode: 'WEB',
      genesisOneOmitted: const [2],
    );
    final source = StringBuffer();
    for (final book in bibleBooks) {
      for (var chapter = 1; chapter <= book.chapterCount; chapter++) {
        final reference = _ref(book.id, chapter);
        for (var verse = 1; verse <= manifest.count(reference)!; verse++) {
          final omitted = manifest.omittedVerses(reference).contains(verse);
          source.writeln(
            '${book.id} $chapter:$verse ${omitted ? '' : 'SYNTHETIC ${book.id} $chapter $verse'}',
          );
        }
      }
    }
    final h = ClientTestHarness()
      ..bible.staff = const AccessReadOk(
        StaffBibleTranslations(capacity: ChurchRoles.media, translations: []),
      )
      ..bible.manifests['WEB'] = AccessReadOk(manifest)
      ..biblePackageSource.worldEnglishBibleVpl = source.toString();
    final gateway = _BibleAutoGateway();
    h.commandGateway = gateway;
    final container = ProviderContainer(overrides: h.overrides());
    addTearDown(container.dispose);
    final sub = container.listen(bibleStaffProvider, (_, _) {});
    addTearDown(sub.close);
    final controller = container.read(bibleStaffProvider.notifier);
    await controller.reload();

    await controller.installWorldEnglishBible(rightsId: _rightsId);

    expect(gateway.requests.first.command, BibleCommands.create);
    expect(gateway.requests.first.payload['translation_code'], 'WEB');
    expect(gateway.requests.first.payload['manifest_version'], 2);
    final imports = gateway.requests
        .where((request) => request.command == BibleCommands.importVerses)
        .toList();
    expect(imports, hasLength(6));
    final omitted = imports
        .expand((request) => request.payload['rows'] as List)
        .cast<Map<String, Object?>>()
        .singleWhere((row) => row['book_id'] == 'GEN' && row['verse'] == 2);
    expect(omitted['text'], isEmpty);
    expect(gateway.requests.last.command, BibleCommands.finalize);
    expect(
      container.read(bibleStaffProvider).message,
      contains('Complete draft'),
    );
  });

  // Review F2: the preflight reads (manifest, bundled package) are bound to
  // the account and operation that started them, and hold the busy guard.
  group('Bible import preflight lifecycle', () {
    final webManifest = _manifest(
      genesisOne: 1,
      genesisTwo: 1,
      translationCode: 'WEB',
    );

    ({
      ClientTestHarness h,
      _BibleAutoGateway gateway,
      ProviderContainer container,
      NotifierProvider<_Gen, int> gen,
    })
    setUpStaff() {
      final source = StringBuffer();
      for (final book in bibleBooks) {
        for (var chapter = 1; chapter <= book.chapterCount; chapter++) {
          source.writeln('${book.id} $chapter:1 SYNTHETIC ${book.id} $chapter');
        }
      }
      final h = ClientTestHarness()
        ..bible.staff = const AccessReadOk(
          StaffBibleTranslations(capacity: ChurchRoles.media, translations: []),
        )
        ..bible.manifests['WEB'] = AccessReadOk(webManifest)
        ..bible.manifests['KJV'] = AccessReadOk(_manifest())
        ..biblePackageSource.worldEnglishBibleVpl = source.toString();
      final gateway = _BibleAutoGateway();
      h.commandGateway = gateway;
      final gen = NotifierProvider<_Gen, int>(_Gen.new);
      final container = ProviderContainer(
        overrides: [
          ...h.overrides(),
          accountGenerationProvider.overrideWith((ref) => ref.watch(gen)),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(bibleStaffProvider, (_, _) {});
      addTearDown(sub.close);
      return (h: h, gateway: gateway, container: container, gen: gen);
    }

    PickedFile kjvCsv() => PickedFile(
      name: 'kjv.csv',
      declaredType: 'text/csv',
      bytes: Uint8List.fromList(
        utf8.encode(
          'book,chapter,verse,text\nGEN,1,1,SYNTHETIC one\nGEN,1,2,SYNTHETIC two\n',
        ),
      ),
    );

    test(
      'an account switch during the CSV manifest read sends nothing',
      () async {
        final s = setUpStaff();
        final controller = s.container.read(bibleStaffProvider.notifier);
        await controller.reload();
        final gate = s.h.bible.manifestGate = Completer<void>();

        final import = controller.importCsv(
          translationId: null,
          code: 'KJV',
          name: 'King James Version',
          rightsId: _rightsId,
          file: kjvCsv(),
        );
        expect(s.container.read(bibleStaffProvider).busy, isTrue);
        await pumpEventQueue();
        s.container.read(s.gen.notifier).bump();
        gate.complete();
        await import;
        await pumpEventQueue();

        expect(s.gateway.requests, isEmpty);
        expect(s.container.read(bibleStaffProvider).busy, isFalse);
      },
    );

    test(
      'an account switch during the WEB manifest read sends nothing',
      () async {
        final s = setUpStaff();
        final controller = s.container.read(bibleStaffProvider.notifier);
        await controller.reload();
        final gate = s.h.bible.manifestGate = Completer<void>();

        final install = controller.installWorldEnglishBible(
          rightsId: _rightsId,
        );
        await pumpEventQueue();
        s.container.read(s.gen.notifier).bump();
        gate.complete();
        await install;
        await pumpEventQueue();

        expect(s.gateway.requests, isEmpty);
        expect(s.container.read(bibleStaffProvider).busy, isFalse);
      },
    );

    test('an account switch during the WEB package load sends nothing, even '
        'before the controller rebuilds', () async {
      final s = setUpStaff();
      final controller = s.container.read(bibleStaffProvider.notifier);
      await controller.reload();
      final gate = s.h.biblePackageSource.gate = Completer<void>();

      final install = controller.installWorldEnglishBible(rightsId: _rightsId);
      await pumpEventQueue();
      // The generation changes and the load answers in the same turn, so
      // the continuation runs before Riverpod rebuilds the controller.
      s.container.read(s.gen.notifier).bump();
      gate.complete();
      await install;

      expect(s.gateway.requests, isEmpty);
    });

    test('a reset before the WEB lookup neither throws nor sends', () async {
      final s = setUpStaff();
      final controller = s.container.read(bibleStaffProvider.notifier);
      await controller.reload();
      final gate = s.h.biblePackageSource.gate = Completer<void>();

      final install = controller.installWorldEnglishBible(rightsId: _rightsId);
      await pumpEventQueue();
      // The reset drops the loaded catalog the WEB lookup reads.
      s.container.invalidate(bibleStaffProvider);
      s.container.read(bibleStaffProvider);
      gate.complete();
      await expectLater(install, completes);
      await pumpEventQueue();

      expect(s.gateway.requests, isEmpty);
      expect(s.container.read(bibleStaffProvider).busy, isFalse);
    });

    test('a double tap starts one import', () async {
      final s = setUpStaff();
      final controller = s.container.read(bibleStaffProvider.notifier);
      await controller.reload();
      final gate = s.h.bible.manifestGate = Completer<void>();

      final first = controller.installWorldEnglishBible(rightsId: _rightsId);
      final second = controller.installWorldEnglishBible(rightsId: _rightsId);
      final third = controller.importCsv(
        translationId: null,
        code: 'KJV',
        name: 'King James Version',
        rightsId: _rightsId,
        file: kjvCsv(),
      );
      await pumpEventQueue();
      expect(s.h.bible.manifestCalls, ['WEB']);
      gate.complete();
      await Future.wait([first, second, third]);

      expect(
        s.gateway.requests.where((r) => r.command == BibleCommands.create),
        hasLength(1),
      );
      expect(s.gateway.requests.last.command, BibleCommands.finalize);
      expect(s.container.read(bibleStaffProvider).busy, isFalse);
    });
  });
}

class _Gen extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

class _BibleAutoGateway implements CommandGateway {
  final requests = <CommandRequest>[];

  @override
  Future<CommandOutcome> send(String function, CommandRequest request) async {
    requests.add(request);
    final data = switch (request.command) {
      BibleCommands.beginRevision => {
        'translation_id': _translationId,
        'draft_revision_no': 5,
      },
      _ => {'translation_id': _translationId},
    };
    return CommandConfirmed(
      CommandSuccess(
        requestId: request.requestId,
        data: data,
        revision: (request.expectedRevision.value ?? 0) + 1,
      ),
    );
  }
}

class _DelayedBibleCache extends FakePublicContentCache {
  final pending = Completer<PublicContentCacheWrite>();

  @override
  Future<PublicContentCacheWrite> writeRead(
    String readKey,
    Object projection, {
    Future<Uint8List?> Function(PublicBanner banner)? loadBannerImage,
    Future<Uint8List?> Function(PublicGivingLogo logo)? loadGivingLogo,
    Future<Uint8List?> Function(SermonPoster poster)? loadSermonPoster,
    int? readGeneration,
  }) => pending.future;
}
