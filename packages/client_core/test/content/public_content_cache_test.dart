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

  test('an offline Give list uses the saved unsafe projection', () async {
    final h = ClientTestHarness(account: null)
      ..giving.publicMethods = const AccessReadFailed(unreachable: true)
      ..publicContentCache.givingMethods = PublicContentSnapshot(
        value: PublicGivingMethods.fromJson(
          publicGivingMethodsData([
            publicGivingMethodData(unsafe: true),
          ], sample: false),
        ),
        savedAt: _savedAt,
      );
    final container = ProviderContainer(overrides: h.overrides());
    addTearDown(container.dispose);

    await container.read(publicGivingMethodsProvider.notifier).reload();
    final state = container.read(publicGivingMethodsProvider);

    expect(state.offlineSnapshot, isTrue);
    expect(state.savedAt, _savedAt);
    expect(state.refreshFailed, isA<AccessReadFailed<PublicGivingMethods>>());
    expect(state.value?.methods.single.unsafe, isTrue);
    expect(h.publicContentCache.reads, [PublicContentCacheKeys.givingMethods]);
  });

  test('a successful Give refresh replaces the cached unsafe flag', () async {
    final h = ClientTestHarness(account: null)
      ..publicContentCache.available = true
      ..giving.publicMethods = AccessReadOk(
        PublicGivingMethods.fromJson(
          publicGivingMethodsData([publicGivingMethodData(unsafe: false)]),
        ),
      );
    final container = ProviderContainer(overrides: h.overrides());
    addTearDown(container.dispose);
    final controller = container.read(publicGivingMethodsProvider.notifier);

    await controller.reload();
    expect(
      h.publicContentCache.givingMethods?.value.methods.single.unsafe,
      isFalse,
    );

    h.giving.publicMethods = AccessReadOk(
      PublicGivingMethods.fromJson(
        publicGivingMethodsData([publicGivingMethodData(unsafe: true)]),
      ),
    );
    await controller.reload();
    expect(
      container.read(publicGivingMethodsProvider).value?.methods.single.unsafe,
      isTrue,
    );
    expect(
      h.publicContentCache.givingMethods?.value.methods.single.unsafe,
      isTrue,
    );
  });

  test(
    'a fresh giving detail reconciles the cached list and offline detail',
    () async {
      const methodId = '61616161-6161-4161-8161-616161616161';
      const bankId = '62626262-6262-4262-8262-626262626262';
      final logo = {
        'path': 'giving_method/$methodId/r1/logo.png',
        'media_type': 'image/png',
        'width': 160,
        'height': 160,
        'rights_revision': 4,
        'offline_allowed': true,
      };
      final h = ClientTestHarness(account: null)
        ..publicContentCache.available = true
        ..banners.publicImageBytes = Uint8List.fromList([1, 2, 3])
        ..giving.publicMethods = AccessReadOk(
          PublicGivingMethods.fromJson(
            publicGivingMethodsData(
              [
                publicGivingMethodData(methodId: methodId, logo: logo),
                publicBankMethodData(methodId: bankId),
              ],
              sample: true,
              truncated: true,
            ),
          ),
        )
        ..giving.publicMethod[methodId] = AccessReadOk(
          PublicGivingMethodRead(
            sample: false,
            method: PublicGivingMethod.fromJson(
              publicGivingMethodData(
                methodId: methodId,
                unsafe: true,
                logo: logo,
              ),
            ),
          ),
        );
      final container = ProviderContainer(overrides: h.overrides());
      addTearDown(container.dispose);

      await container.read(publicGivingMethodsProvider.notifier).reload();
      final initialCache = h.publicContentCache.givingMethods!;
      expect(initialCache.value.methods.map((method) => method.methodId), [
        methodId,
        bankId,
      ]);
      expect(initialCache.value.methods.first.unsafe, isFalse);
      expect(initialCache.value.methods.first.logo?.offlineBytes, isNotNull);
      expect(initialCache.value.sample, isTrue);
      expect(initialCache.value.truncated, isTrue);

      final detailProvider = publicGivingMethodProvider(methodId);
      final subscription = container.listen(detailProvider, (_, _) {});
      addTearDown(subscription.close);
      await container.read(detailProvider.notifier).reload();

      final reconciled = h.publicContentCache.givingMethods!;
      expect(reconciled.savedAt, initialCache.savedAt);
      expect(reconciled.value.sample, isTrue);
      expect(reconciled.value.truncated, isTrue);
      expect(reconciled.value.methods.map((method) => method.methodId), [
        methodId,
        bankId,
      ]);
      expect(reconciled.value.methods.first.unsafe, isTrue);
      expect(reconciled.value.methods.first.logo?.offlineBytes, isNotNull);

      h.giving.publicMethods = const AccessReadFailed(unreachable: true);
      await container.read(publicGivingMethodsProvider.notifier).reload();
      final offlineList = container.read(publicGivingMethodsProvider);
      expect(offlineList.offlineSnapshot, isTrue);
      expect(offlineList.savedAt, initialCache.savedAt);
      expect(offlineList.value?.methods.first.unsafe, isTrue);
      expect(offlineList.value?.sample, isTrue);

      h.giving.publicMethod[methodId] = const AccessReadFailed(
        unreachable: true,
      );
      await container.read(detailProvider.notifier).reload();
      final offlineDetail = container.read(detailProvider);
      expect(offlineDetail.offlineSnapshot, isTrue);
      expect(offlineDetail.savedAt, initialCache.savedAt);
      expect(offlineDetail.value?.method?.unsafe, isTrue);
      expect(offlineDetail.value?.method?.logo?.offlineBytes, isNotNull);
    },
  );

  test(
    'offline detail falls back to the list and a fresh hidden answer evicts it',
    () async {
      final h = ClientTestHarness(account: null)
        ..giving.publicMethod['61616161-6161-4161-8161-616161616161'] =
            const AccessReadFailed(unreachable: true)
        ..publicContentCache.givingMethods = PublicContentSnapshot(
          value: PublicGivingMethods.fromJson(
            publicGivingMethodsData([publicGivingMethodData(unsafe: true)]),
          ),
          savedAt: _savedAt,
        );
      final container = ProviderContainer(overrides: h.overrides());
      addTearDown(container.dispose);
      final provider = publicGivingMethodProvider(
        '61616161-6161-4161-8161-616161616161',
      );
      final subscription = container.listen(provider, (_, _) {});
      addTearDown(subscription.close);

      await container.read(provider.notifier).reload();
      final state = container.read(provider);
      expect(state.offlineSnapshot, isTrue);
      expect(state.value?.method?.unsafe, isTrue);
      expect(state.value?.method?.verifiedOn, DateTime.utc(2026, 9, 28));

      h.giving.publicMethod['61616161-6161-4161-8161-616161616161'] =
          const AccessReadOk(
            PublicGivingMethodRead(sample: true, method: null),
          );
      await container.read(provider.notifier).reload();
      expect(h.publicContentCache.removedGivingMethods, [
        '61616161-6161-4161-8161-616161616161',
      ]);
      expect(h.publicContentCache.givingMethods?.value.methods, isEmpty);
      expect(container.read(provider).offlineSnapshot, isFalse);
      expect(container.read(provider).value?.method, isNull);
    },
  );
}
