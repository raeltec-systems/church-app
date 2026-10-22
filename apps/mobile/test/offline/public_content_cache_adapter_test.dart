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

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bic-public-cache-test-');
    cache = PublicContentCacheAdapter(
      supportDirectory: () async => root,
      clock: () => savedAt,
    );
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('only the two public list reads can create a manifest', () async {
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
}
