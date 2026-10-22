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
