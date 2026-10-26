import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bic_kafue_mobile/offline/public_content_cache_adapter.dart';
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late PublicContentCacheAdapter cache;
  final savedAt = DateTime.utc(2026, 10, 22, 12, 30);
  final imageBytes = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);
  late DateTime cacheClock;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bic-public-cache-test-');
    cacheClock = savedAt;
    cache = PublicContentCacheAdapter(
      supportDirectory: () async => root,
      clock: () => cacheClock,
    );
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  PublicSermons sermons({bool posterOffline = true, int rightsRevision = 1}) {
    final series = publicSermonSeriesData(
      poster: true,
      posterOffline: posterOffline,
      rightsRevision: rightsRevision,
    );
    return PublicSermons.fromJson({
      'sermons': [publicSermonData(series: series)],
      'series': [series],
      'truncated': false,
    });
  }

  test('sermon snapshot stores notes and cleared posters, never YouTube media or playable IDs', () async {
    var fetched = 0;
    expect(
      await cache.writeRead(
        PublicContentCacheKeys.sermons,
        sermons(),
        loadSermonPoster: (_) async {
          fetched++;
          return imageBytes;
        },
      ),
      isA<PublicContentCacheSaved>(),
    );
    final cold = PublicContentCacheAdapter(supportDirectory: () async => root);
    final snapshot = await cold.readSermons();
    expect(snapshot?.savedAt, savedAt);
    expect(snapshot?.value.sermons.single.notes, contains('SYNTHETIC Notes'));
    expect(snapshot?.value.sermons.single.youtubeVideoId, isNull);
    expect(snapshot?.value.series.single.poster?.offlineBytes, imageBytes);
    expect(fetched, 1);
    final files = root.listSync(recursive: true).whereType<File>().toList();
    expect(files, hasLength(2));
    final text = await files
        .singleWhere((f) => f.path.endsWith('manifest.json'))
        .readAsString();
    expect(text, isNot(contains('abcdefghijk')));
    expect(text, isNot(contains('saved_by')));
  });

  test(
    'sermon poster display rights never authorize offline download',
    () async {
      var fetched = 0;
      await cache.writeRead(
        PublicContentCacheKeys.sermons,
        sermons(posterOffline: false),
        loadSermonPoster: (_) async {
          fetched++;
          return imageBytes;
        },
      );
      final snapshot = await cache.readSermons();
      expect(snapshot?.value.sermons, hasLength(1));
      expect(snapshot?.value.series.single.poster, isNull);
      expect(snapshot?.value.sermons.single.series?.poster, isNull);
      expect(fetched, 0);
    },
  );

  test('successful canonical refresh evicts withdrawn sermons and poster rights revisions', () async {
    await cache.writeRead(
      PublicContentCacheKeys.sermons,
      sermons(),
      loadSermonPoster: (_) async => imageBytes,
    );
    await cache.writeRead(
      PublicContentCacheKeys.sermons,
      sermons(rightsRevision: 2),
      loadSermonPoster: (_) async => imageBytes,
    );
    final images = root
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.png'))
        .toList();
    expect(images, hasLength(1));
    expect(images.single.path, contains('-r2.png'));
    await cache.writeRead(
      PublicContentCacheKeys.sermons,
      const PublicSermons(sermons: [], series: []),
    );
    expect((await cache.readSermons())?.value.sermons, isEmpty);
    expect(
      root
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.png')),
      isEmpty,
    );
  });

  test(
    'refused sermon refresh preserves the prior teaching snapshot',
    () async {
      await cache.writeRead(
        PublicContentCacheKeys.sermons,
        sermons(),
        loadSermonPoster: (_) async => imageBytes,
      );
      expect(
        await cache.writeRead(PublicContentCacheKeys.sermons, {
          'draft': 'private',
        }),
        isA<PublicContentCacheRefused>(),
      );
      expect((await cache.readSermons())?.value.sermons, hasLength(1));
    },
  );

  test(
    'strict sermon restore refuses injected attribution and unsafe links',
    () async {
      await cache.writeRead(
        PublicContentCacheKeys.sermons,
        sermons(),
        loadSermonPoster: (_) async => imageBytes,
      );
      final file = root
          .listSync(recursive: true)
          .whereType<File>()
          .singleWhere((f) => f.path.endsWith('manifest.json'));
      final original = jsonDecode(await file.readAsString()) as Map;
      final entry = original['reads'][PublicContentCacheKeys.sermons] as Map;
      entry['projection']['sermons'][0]['saved_by'] = 'private';
      await file.writeAsString(jsonEncode(original));
      expect(await cache.readSermons(), isNull);
      (entry['projection']['sermons'][0] as Map).remove('saved_by');
      entry['projection']['sermons'][0]['notes'] =
          '[unsafe](https://evil.test)';
      await file.writeAsString(jsonEncode(original));
      expect(await cache.readSermons(), isNull);
    },
  );

  test(
    'failed sermon commit preserves the prior catalog and image bytes',
    () async {
      await cache.writeRead(
        PublicContentCacheKeys.sermons,
        sermons(),
        loadSermonPoster: (_) async => imageBytes,
      );
      final failing = PublicContentCacheAdapter(
        supportDirectory: () async => root,
        clock: () =>
            throw const FileSystemException('SYNTHETIC clock unavailable'),
      );
      expect(
        await failing.writeRead(
          PublicContentCacheKeys.sermons,
          const PublicSermons(sermons: [], series: []),
        ),
        isA<PublicContentCacheUnavailable>(),
      );
      expect(
        (await cache.readSermons())?.value.series.single.poster?.offlineBytes,
        imageBytes,
      );
      expect((await cache.readSermons())?.value.sermons, hasLength(1));
    },
  );

  test(
    'sermon and calendar writes share the same serialized manifest queue',
    () async {
      final poster = Completer<Uint8List?>();
      final first = cache.writeRead(
        PublicContentCacheKeys.sermons,
        sermons(),
        loadSermonPoster: (_) => poster.future,
      );
      final second = cache.writeRead(
        PublicContentCacheKeys.calendar,
        PublicEvents.fromJson(publicEventsData([publicEventData()])),
      );
      poster.complete(imageBytes);
      await Future.wait([first, second]);
      expect((await cache.readSermons())?.value.sermons, hasLength(1));
      expect((await cache.readEvents())?.value.events, hasLength(1));
    },
  );

  test('only allowlisted public list reads can create a manifest', () async {
    final outcome = await cache.writeRead(
      'content_staff_events',
      PublicEvents.fromJson(publicEventsData([publicEventData()])),
    );

    expect(outcome, isA<PublicContentCacheRefused>());
    expect(
      (outcome as PublicContentCacheRefused).reason,
      PublicContentCacheRefusal.unsupportedRead,
    );
    expect(root.listSync(), isEmpty);
  });

  test('calendar round trip stores only explicitly eligible rows', () async {
    final events = PublicEvents.fromJson(
      publicEventsData([publicEventData()], truncated: true),
    );
    final saved = await cache.writeRead(
      PublicContentCacheKeys.calendar,
      events,
    );

    expect(saved, isA<PublicContentCacheSaved>());
    final snapshot = await cache.readEvents();
    expect(snapshot?.savedAt, savedAt);
    expect(snapshot?.value.truncated, isTrue);
    expect(snapshot?.value.events.single.offlineAllowed, isTrue);

    final refused = await cache.writeRead(
      PublicContentCacheKeys.calendar,
      PublicEvents.fromJson(
        publicEventsData([publicEventData(offlineAllowed: false)]),
      ),
    );
    expect(refused, isA<PublicContentCacheRefused>());
    expect((await cache.readEvents())?.value.events, hasLength(1));
  });

  test(
    'banner snapshots keep eligible bytes and evict withdrawn revisions',
    () async {
      final banners = PublicBanners.fromJson(
        publicBannersData([
          publicBannerData(publicationRevision: 2, rightsRevision: 4),
        ], truncated: true),
      );
      final saved = await cache.writeRead(
        PublicContentCacheKeys.homeBanners,
        banners,
        loadBannerImage: (_) async => imageBytes,
      );

      expect(saved, isA<PublicContentCacheSaved>());
      final directory = Directory(
        '${root.path}${Platform.pathSeparator}'
        'bic-kafue${Platform.pathSeparator}public-content-v1',
      );
      final imageName =
          'banner-offline-81818181-8181-4181-8181-818181818181'
          '-p2-r4.png';
      expect(
        File('${directory.path}${Platform.pathSeparator}$imageName')
            .existsSync(),
        isTrue,
      );
      final snapshot = await cache.readBanners();
      expect(snapshot?.value.truncated, isTrue);
      expect(snapshot?.value.banners.single.offlineImageBytes, imageBytes);
      final manifest = jsonDecode(
        await File('${directory.path}${Platform.pathSeparator}manifest.json')
            .readAsString(),
      ) as Map<String, dynamic>;
      expect(jsonEncode(manifest), isNot(contains('offlineImageBytes')));

      final replaced = await cache.writeRead(
        PublicContentCacheKeys.homeBanners,
        const PublicBanners([]),
      );
      expect(replaced, isA<PublicContentCacheSaved>());
      expect((await cache.readBanners())?.value.banners, isEmpty);
      expect(
        File('${directory.path}${Platform.pathSeparator}$imageName')
            .existsSync(),
        isFalse,
      );
    },
  );

  test('rights uncleared for offline use refuses without writing', () async {
    final outcome = await cache.writeRead(
      PublicContentCacheKeys.homeBanners,
      PublicBanners.fromJson(
        publicBannersData([publicBannerData(offlineAllowed: false)]),
      ),
      loadBannerImage: (_) async => imageBytes,
    );

    expect(outcome, isA<PublicContentCacheRefused>());
    expect(
      (outcome as PublicContentCacheRefused).reason,
      PublicContentCacheRefusal.offlineRightsNotCleared,
    );
    expect(root.listSync(), isEmpty);
  });

  test('Bible cache restores a validated chapter and its reference after a cold start', () async {
    final chapter = PublicBibleChapter(
      translationId: '61616161-6161-4161-8161-616161616161',
      translationCode: 'KJV',
      translationName: 'King James Version',
      reference: const BibleChapterRef(bookId: 'GEN', chapter: 1),
      verses: const [
        BibleVerse(number: 1, text: 'SYNTHETIC verse one'),
        BibleVerse(number: 2, text: 'SYNTHETIC verse two'),
      ],
      publicationRevision: 3,
      publishedAt: DateTime.utc(2026, 10, 22),
      offlineAllowed: true,
    );
    final saved = await cache.writeRead(
      PublicContentCacheKeys.bibleChapter,
      chapter,
    );
    expect(saved, isA<PublicContentCacheSaved>());

    final coldStart = PublicContentCacheAdapter(
      supportDirectory: () async => root,
      clock: () => cacheClock,
    );
    final restored = await coldStart.readBibleChapter();
    expect(restored?.value.translationId, chapter.translationId);
    expect(
      restored?.value.reference,
      const BibleChapterRef(bookId: 'GEN', chapter: 1),
    );
    expect(restored?.value.verses, hasLength(2));
    expect(restored?.savedAt, savedAt);

    final directory = Directory(
      '${root.path}${Platform.pathSeparator}bic-kafue'
      '${Platform.pathSeparator}public-content-v1',
    );
    final manifest = jsonDecode(
      await File('${directory.path}${Platform.pathSeparator}manifest.json')
          .readAsString(),
    ) as Map<String, dynamic>;
    final entry =
        (manifest['reads']
                as Map<String, dynamic>)[PublicContentCacheKeys.bibleChapter]
            as Map<String, dynamic>;
    expect(entry['projection']['book_id'], 'GEN');
    expect(entry['projection']['chapter'], 1);
    expect(entry['projection']['translation_id'], chapter.translationId);
  });

  test('a refused Bible refresh keeps the previous offline chapter', () async {
    final original = PublicBibleChapter(
      translationId: '61616161-6161-4161-8161-616161616161',
      translationCode: 'KJV',
      translationName: 'King James Version',
      reference: const BibleChapterRef(bookId: 'GEN', chapter: 1),
      verses: const [BibleVerse(number: 1, text: 'SYNTHETIC saved verse')],
      publicationRevision: 3,
      publishedAt: DateTime.utc(2026, 10, 22),
      offlineAllowed: true,
    );
    expect(
      await cache.writeRead(PublicContentCacheKeys.bibleChapter, original),
      isA<PublicContentCacheSaved>(),
    );

    final refused = PublicBibleChapter(
      translationId: original.translationId,
      translationCode: original.translationCode,
      translationName: original.translationName,
      reference: const BibleChapterRef(bookId: 'GEN', chapter: 2),
      verses: const [BibleVerse(number: 1, text: 'SYNTHETIC blocked refresh')],
      publicationRevision: 4,
      publishedAt: DateTime.utc(2026, 10, 23),
      offlineAllowed: false,
    );
    expect(
      await cache.writeRead(PublicContentCacheKeys.bibleChapter, refused),
      isA<PublicContentCacheRefused>(),
    );
    final restored = await cache.readBibleChapter();
    expect(restored?.value.reference, original.reference);
    expect(restored?.value.verses.single.text, 'SYNTHETIC saved verse');
  });

  test(
    'Bible cache refuses display-only chapters and rejects tampered metadata',
    () async {
      final displayOnly = PublicBibleChapter(
        translationId: '61616161-6161-4161-8161-616161616161',
        translationCode: 'KJV',
        translationName: 'King James Version',
        reference: const BibleChapterRef(bookId: 'GEN', chapter: 1),
        verses: const [BibleVerse(number: 1, text: 'SYNTHETIC verse one')],
        publicationRevision: 1,
        publishedAt: DateTime.utc(2026, 10, 22),
        offlineAllowed: false,
      );
      final refused = await cache.writeRead(
        PublicContentCacheKeys.bibleChapter,
        displayOnly,
      );
      expect(refused, isA<PublicContentCacheRefused>());
      expect(
        (refused as PublicContentCacheRefused).reason,
        PublicContentCacheRefusal.offlineRightsNotCleared,
      );
      expect(root.listSync(), isEmpty);

      final eligible = PublicBibleChapter(
        translationId: displayOnly.translationId,
        translationCode: displayOnly.translationCode,
        translationName: displayOnly.translationName,
        reference: displayOnly.reference,
        verses: displayOnly.verses,
        publicationRevision: displayOnly.publicationRevision,
        publishedAt: displayOnly.publishedAt,
        offlineAllowed: true,
      );
      expect(
        await cache.writeRead(PublicContentCacheKeys.bibleChapter, eligible),
        isA<PublicContentCacheSaved>(),
      );
      final directory = Directory(
        '${root.path}${Platform.pathSeparator}bic-kafue'
        '${Platform.pathSeparator}public-content-v1',
      );
      final manifestFile = File(
        '${directory.path}${Platform.pathSeparator}manifest.json',
      );
      final manifest =
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      final reads = manifest['reads'] as Map<String, dynamic>;
      final entry =
          reads[PublicContentCacheKeys.bibleChapter] as Map<String, dynamic>;
      final projection = entry['projection'] as Map<String, dynamic>;
      projection['translation_code'] = 'not valid';
      await manifestFile.writeAsString(jsonEncode(manifest));
      expect(await cache.readBibleChapter(), isNull);
    },
  );

  test(
    'an unavailable image is omitted and a later server snapshot evicts it',
    () async {
      final banners = PublicBanners.fromJson(
        publicBannersData([publicBannerData()]),
      );
      final first = await cache.writeRead(
        PublicContentCacheKeys.homeBanners,
        banners,
        loadBannerImage: (_) async => null,
      );
      expect((first as PublicContentCacheSaved).omittedRows, 1);
      expect((await cache.readBanners())?.value.banners, isEmpty);
    },
  );

  test('giving cache keeps unsafe instructions and only offline-cleared logo bytes', () async {
    final method = publicGivingMethodData(
      unsafe: true,
      logo: {
        'path': 'providers/sample.png',
        'media_type': 'image/png',
        'width': 160,
        'height': 160,
        'rights_revision': 4,
        'offline_allowed': true,
      },
    );
    final giving = PublicGivingMethods.fromJson(
      publicGivingMethodsData([method], truncated: true),
    );
    final saved = await cache.writeRead(
      PublicContentCacheKeys.givingMethods,
      giving,
      loadGivingLogo: (_) async => imageBytes,
    );

    expect(saved, isA<PublicContentCacheSaved>());
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}'
      'bic-kafue${Platform.pathSeparator}public-content-v1',
    );
    final logoName =
        'giving-logo-offline-61616161-6161-4161-8161-616161616161-p1-r4.png';
    expect(
      File('${directory.path}${Platform.pathSeparator}$logoName').existsSync(),
      isTrue,
    );
    final snapshot = await cache.readGivingMethods();
    expect(snapshot?.value.sample, isTrue);
    expect(snapshot?.value.truncated, isTrue);
    expect(snapshot?.value.methods.single.unsafe, isTrue);
    expect(snapshot?.value.methods.single.logo?.offlineBytes, imageBytes);
    final manifest = jsonDecode(
      await File('${directory.path}${Platform.pathSeparator}manifest.json')
          .readAsString(),
    ) as Map<String, dynamic>;
    expect(jsonEncode(manifest), isNot(contains('offlineBytes')));

    await cache.writeRead(
      PublicContentCacheKeys.givingMethods,
      const PublicGivingMethods(sample: true, methods: [], truncated: false),
    );
    expect((await cache.readGivingMethods())?.value.methods, isEmpty);
    expect(
      File('${directory.path}${Platform.pathSeparator}$logoName').existsSync(),
      isFalse,
    );
  });

  test(
    'giving refresh keeps the last snapshot and loads logos concurrently',
    () async {
      const oldId = '61616161-6161-4161-8161-616161616161';
      const firstNewId = '63636363-6363-4363-8363-636363636363';
      const secondNewId = '64646464-6464-4464-8464-646464646464';
      final oldLogo = {
        'path': 'providers/old.png',
        'media_type': 'image/png',
        'width': 160,
        'height': 160,
        'rights_revision': 4,
        'offline_allowed': true,
      };
      final oldProjection = PublicGivingMethods.fromJson(
        publicGivingMethodsData([
          publicGivingMethodData(methodId: oldId, logo: oldLogo),
        ]),
      );
      var fetchedLogos = 0;
      final firstWrite = await cache.writeRead(
        PublicContentCacheKeys.givingMethods,
        oldProjection,
        loadGivingLogo: (_) async {
          fetchedLogos++;
          return imageBytes;
        },
      );
      expect(firstWrite, isA<PublicContentCacheSaved>());

      final firstNewLogo = {...oldLogo, 'path': 'providers/first-new.png'};
      final secondNewLogo = {...oldLogo, 'path': 'providers/second-new.png'};
      final refreshed = PublicGivingMethods.fromJson(
        publicGivingMethodsData([
          publicGivingMethodData(methodId: oldId, logo: oldLogo),
          publicGivingMethodData(methodId: firstNewId, logo: firstNewLogo),
          publicGivingMethodData(methodId: secondNewId, logo: secondNewLogo),
        ]),
      );
      final firstNewBytes = Completer<Uint8List?>();
      final secondNewBytes = Completer<Uint8List?>();
      final bothFetchesStarted = Completer<void>();
      final newLogos = {
        firstNewLogo['path']: firstNewBytes,
        secondNewLogo['path']: secondNewBytes,
      };
      final refresh = cache.writeRead(
        PublicContentCacheKeys.givingMethods,
        refreshed,
        loadGivingLogo: (logo) {
          fetchedLogos++;
          if (fetchedLogos == 3) bothFetchesStarted.complete();
          return newLogos[logo.path]!.future;
        },
      );

      await bothFetchesStarted.future.timeout(const Duration(seconds: 2));
      expect(
        (await cache.readGivingMethods())?.value.methods.map((m) => m.methodId),
        [oldId],
        reason: 'the last good list remains readable while new logos load',
      );
      firstNewBytes.complete(imageBytes);
      secondNewBytes.complete(imageBytes);
      expect(await refresh, isA<PublicContentCacheSaved>());
      final fresh = await cache.readGivingMethods();
      expect(fresh?.value.methods.map((m) => m.methodId), [
        oldId,
        firstNewId,
        secondNewId,
      ]);
      expect(fresh?.value.methods.map((m) => m.logo?.offlineBytes), [
        imageBytes,
        imageBytes,
        imageBytes,
      ]);

      final repeat = await cache.writeRead(
        PublicContentCacheKeys.givingMethods,
        refreshed,
        loadGivingLogo: (_) async {
          fetchedLogos++;
          return null;
        },
      );
      expect(repeat, isA<PublicContentCacheSaved>());
      expect(fetchedLogos, 3, reason: 'unchanged cached logos are reused');
    },
  );

  test('giving logo downloads are capped at four in flight', () async {
    const ids = [
      '61616161-6161-4161-8161-616161616161',
      '63636363-6363-4363-8363-636363636363',
      '64646464-6464-4464-8464-646464646464',
      '65656565-6565-4565-8565-656565656565',
      '67676767-6767-4767-8767-676767676767',
      '68686868-6868-4868-8868-686868686868',
    ];
    final logo = {
      'media_type': 'image/png',
      'width': 160,
      'height': 160,
      'rights_revision': 4,
      'offline_allowed': true,
    };
    final projection = PublicGivingMethods.fromJson(
      publicGivingMethodsData([
        for (var i = 0; i < ids.length; i++)
          publicGivingMethodData(
            methodId: ids[i],
            logo: {...logo, 'path': 'providers/logo-$i.png'},
          ),
      ]),
    );
    final completions = <Completer<Uint8List?>>[];
    final started = List.generate(ids.length, (_) => Completer<void>());
    var active = 0;
    var maximumActive = 0;
    final saving = cache.writeRead(
      PublicContentCacheKeys.givingMethods,
      projection,
      loadGivingLogo: (_) {
        active++;
        if (active > maximumActive) maximumActive = active;
        final completion = Completer<Uint8List?>();
        completions.add(completion);
        started[completions.length - 1].complete();
        return completion.future.whenComplete(() => active--);
      },
    );

    await started[3].future.timeout(const Duration(seconds: 2));
    expect(completions, hasLength(4));
    expect(maximumActive, 4);

    completions.first.complete(imageBytes);
    await started[4].future.timeout(const Duration(seconds: 2));
    expect(maximumActive, 4);
    for (final completion in completions) {
      if (!completion.isCompleted) completion.complete(imageBytes);
    }
    await started[5].future.timeout(const Duration(seconds: 2));
    for (final completion in completions) {
      if (!completion.isCompleted) completion.complete(imageBytes);
    }

    expect(await saving, isA<PublicContentCacheSaved>());
    expect(maximumActive, 4);
    expect(
      (await cache.readGivingMethods())?.value.methods,
      hasLength(ids.length),
    );
  });

  test(
    'fresh giving detail keeps list time and reconciles eligible logos',
    () async {
      const methodId = '61616161-6161-4161-8161-616161616161';
      final logo = {
        'path': 'giving_method/$methodId/r1/logo.png',
        'media_type': 'image/png',
        'width': 160,
        'height': 160,
        'rights_revision': 4,
        'offline_allowed': true,
      };
      final saved = await cache.writeRead(
        PublicContentCacheKeys.givingMethods,
        PublicGivingMethods.fromJson(
          publicGivingMethodsData(
            [
              publicGivingMethodData(methodId: methodId, logo: logo),
              publicBankMethodData(),
            ],
            sample: true,
            truncated: true,
          ),
        ),
        loadGivingLogo: (_) async => imageBytes,
      );
      expect(saved, isA<PublicContentCacheSaved>());

      cacheClock = savedAt.add(const Duration(hours: 2));
      var redundantLogoFetch = false;
      await cache.reconcileGivingMethod(
        PublicGivingMethod.fromJson(
          publicGivingMethodData(methodId: methodId, unsafe: true, logo: logo),
        ),
        loadGivingLogo: (_) async {
          redundantLogoFetch = true;
          return null;
        },
      );
      final refreshed = await cache.readGivingMethods();
      expect(refreshed?.savedAt, savedAt);
      expect(refreshed?.value.sample, isTrue);
      expect(refreshed?.value.truncated, isTrue);
      expect(refreshed?.value.methods.map((method) => method.methodId), [
        methodId,
        '62626262-6262-4262-8262-626262626262',
      ]);
      expect(refreshed?.value.methods.first.unsafe, isTrue);
      expect(refreshed?.value.methods.first.logo?.offlineBytes, imageBytes);
      expect(redundantLogoFetch, isFalse);

      final changedLogo = {
        ...logo,
        'path': 'giving_method/$methodId/r2/logo.png',
        'rights_revision': 5,
      };
      final changedBytes = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x02]);
      var changedLogoFetch = false;
      await cache.reconcileGivingMethod(
        PublicGivingMethod.fromJson(
          publicGivingMethodData(
            methodId: methodId,
            publicationRevision: 2,
            unsafe: false,
            logo: changedLogo,
          ),
        ),
        loadGivingLogo: (_) async {
          changedLogoFetch = true;
          return changedBytes;
        },
      );
      final updated = await cache.readGivingMethods();
      expect(updated?.savedAt, savedAt);
      expect(updated?.value.methods.first.unsafe, isFalse);
      expect(updated?.value.methods.first.logo?.rightsRevision, 5);
      expect(updated?.value.methods.first.logo?.offlineBytes, changedBytes);
      expect(changedLogoFetch, isTrue);
    },
  );

  test(
    'display-only logo is omitted while its giving instructions remain cached',
    () async {
      final giving = PublicGivingMethods.fromJson(
        publicGivingMethodsData([
          publicGivingMethodData(
            unsafe: true,
            logo: {
              'path': 'providers/display-only.webp',
              'media_type': 'image/webp',
              'width': 160,
              'height': 160,
              'rights_revision': 5,
              'offline_allowed': false,
            },
          ),
        ]),
      );
      var fetchCalled = false;
      final saved = await cache.writeRead(
        PublicContentCacheKeys.givingMethods,
        giving,
        loadGivingLogo: (_) async {
          fetchCalled = true;
          return imageBytes;
        },
      );

      expect(saved, isA<PublicContentCacheSaved>());
      expect((saved as PublicContentCacheSaved).omittedRows, 1);
      expect(fetchCalled, isFalse);
      final method = (await cache.readGivingMethods())?.value.methods.single;
      expect(method?.unsafe, isTrue);
      expect(method?.name, 'SAMPLE Airtel Money');
      expect(method?.logo, isNull);
    },
  );
}
