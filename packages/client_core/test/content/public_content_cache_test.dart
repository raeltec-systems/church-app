import 'dart:typed_data';

import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _savedAt = DateTime.utc(2026, 10, 22, 12, 30);

void main() {
  test(
    'an offline Calendar read uses the saved snapshot and failure state',
    () async {
      final h = ClientTestHarness(account: null)
        ..content.publicEvents = const AccessReadFailed(unreachable: true)
        ..publicContentCache.events = PublicContentSnapshot(
          value: PublicEvents.fromJson(
            publicEventsData([publicEventData()], truncated: true),
          ),
          savedAt: _savedAt,
        );
      final container = ProviderContainer(overrides: h.overrides());
      addTearDown(container.dispose);

      await container.read(publicEventsProvider.notifier).reload();
      final state = container.read(publicEventsProvider);

      expect(state.offlineSnapshot, isTrue);
      expect(state.savedAt, _savedAt);
      expect(state.refreshFailed, isA<AccessReadFailed<PublicEvents>>());
      expect(state.value?.events.single.eventId, publicEventData()['event_id']);
      expect(h.publicContentCache.reads, [PublicContentCacheKeys.calendar]);
    },
  );

  test(
    'online reads save only eligible lists and never cache event detail',
    () async {
      final h = ClientTestHarness(account: null)
        ..publicContentCache.available = true
        ..content.publicEvents = AccessReadOk(
          PublicEvents.fromJson(
            publicEventsData([
              publicEventData(),
              publicEventData(
                eventId: '72727272-7272-4272-8272-727272727272',
                offlineAllowed: false,
              ),
            ], truncated: true),
          ),
        )
        ..banners.publicImageBytes = Uint8List.fromList([1, 2, 3])
        ..banners.publicBanners = AccessReadOk(
          PublicBanners.fromJson(
            publicBannersData([
              publicBannerData(),
              publicBannerData(
                bannerId: '83838383-8383-4383-8383-838383838383',
                kind: 'campaign',
                themeYear: null,
                offlineAllowed: false,
              ),
            ], truncated: true),
          ),
        );
      final container = ProviderContainer(overrides: h.overrides());
      addTearDown(container.dispose);

      await container.read(publicEventsProvider.notifier).reload();
      final eventWrite = h.publicContentCache.writes.single;
      expect(eventWrite.$1, PublicContentCacheKeys.calendar);
      expect((eventWrite.$2 as PublicEvents).events, hasLength(1));
      expect((eventWrite.$2 as PublicEvents).truncated, isTrue);

      await container.read(publicBannersProvider.notifier).reload();
      final bannerWrite = h.publicContentCache.writes.last;
      expect(bannerWrite.$1, PublicContentCacheKeys.homeBanners);
      expect((bannerWrite.$2 as PublicBanners).banners, hasLength(1));
      expect((bannerWrite.$2 as PublicBanners).truncated, isTrue);
      expect(h.publicContentCache.imageFetches, [
        '81818181-8181-4181-8181-818181818181',
      ]);

      h.content.publicEvent['71717171-7171-4171-8171-717171717171'] =
          AccessReadOk(PublicEventRead.fromJson({'event': publicEventData()}));
      final detail = publicEventProvider(
        '71717171-7171-4171-8171-717171717171',
      );
      final subscription = container.listen(detail, (_, _) {});
      addTearDown(subscription.close);
      await container.read(detail.notifier).reload();
      expect(h.publicContentCache.writes, hasLength(2));
    },
  );

  test('a first failure stays failed when no local snapshot exists', () async {
    final h = ClientTestHarness(account: null)
      ..content.publicEvents = const AccessReadFailed(unreachable: true);
    final container = ProviderContainer(overrides: h.overrides());
    addTearDown(container.dispose);

    await container.read(publicEventsProvider.notifier).reload();
    final state = container.read(publicEventsProvider);

    expect(state.value, isNull);
    expect(state.offlineSnapshot, isFalse);
    expect(state.result, isA<AccessReadFailed<PublicEvents>>());
  });

  test(
    'a failed refresh keeps the in-memory list when the cache misses',
    () async {
      final h = ClientTestHarness(account: null)
        ..publicContentCache.available = true
        ..content.publicEvents = AccessReadOk(
          PublicEvents.fromJson(publicEventsData([publicEventData()])),
        );
      final container = ProviderContainer(overrides: h.overrides());
      addTearDown(container.dispose);

      await container.read(publicEventsProvider.notifier).reload();
      final before = container.read(publicEventsProvider);
      expect(before.savedAt, h.publicContentCache.savedAt);
      h.publicContentCache.events = null;
      h.content.publicEvents = const AccessReadFailed(unreachable: true);

      await container.read(publicEventsProvider.notifier).reload();
      final state = container.read(publicEventsProvider);

      expect(state.result, same(before.result));
      expect(state.value?.events.single.eventId, publicEventData()['event_id']);
      expect(state.refreshFailed, isA<AccessReadFailed<PublicEvents>>());
      expect(state.offlineSnapshot, isFalse);
      expect(state.asOf, before.asOf);
      expect(state.savedAt, before.savedAt);
    },
  );
}
