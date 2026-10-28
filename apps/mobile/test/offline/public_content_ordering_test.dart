import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bic_kafue_mobile/offline/public_content_cache_adapter.dart';
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// Follow-up review F3 and C1: controller and real file adapter together, with
// repository answers gated by the test so the shared write queue, the old
// catalog read and the follow-up refresh interleave exactly as on a phone.

/// Catalog reads answer from [pending] when [gated]; otherwise at once.
class _GatedSermons extends FakeSermons {
  bool gated = false;
  final pending = <Completer<AccessRead<PublicSermons>>>[];

  @override
  Future<AccessRead<PublicSermons>> fetchPublicSermons() {
    catalogCalls++;
    if (!gated) return Future.value(catalog);
    final c = Completer<AccessRead<PublicSermons>>();
    pending.add(c);
    return c.future;
  }
}

class _GatedContent extends FakeContent {
  bool gated = false;
  final pending = <Completer<AccessRead<PublicEvents>>>[];

  @override
  Future<AccessRead<PublicEvents>> fetchPublicEvents() {
    publicEventsCalls++;
    if (!gated) return Future.value(publicEvents);
    final c = Completer<AccessRead<PublicEvents>>();
    pending.add(c);
    return c.future;
  }
}

/// Every public asset download waits for [gate] when it is set.
class _GatedAssets extends FakeBanners {
  Completer<Uint8List?>? gate;

  @override
  Future<Uint8List?> fetchPublicAsset(
    String path,
    String mediaType, {
    int maxBytes = 2 * 1024 * 1024,
  }) async {
    fetchedAssets.add(path);
    final g = gate;
    if (g != null) return g.future;
    return publicImageBytes;
  }
}

void main() {
  late Directory root;
  final imageBytes = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);
  const withdrawn = '92929292-9292-4292-8292-929292929292';
  const unrelated = '93939393-9393-4393-8393-939393939393';
  const withdrawnEvent = '71717171-7171-4171-8171-717171717171';
  const unrelatedEvent = '72727272-7272-4272-8272-727272727272';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bic-public-order-test-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  PublicContentCacheAdapter adapter() =>
      PublicContentCacheAdapter(supportDirectory: () async => root);

  ProviderContainer container({
    required PublicContentCache cache,
    SermonsRepository? sermons,
    ContentRepository? content,
    GivingRepository? giving,
    BannerRepository? assets,
  }) {
    final c = ProviderContainer(
      overrides: [
        sessionRepositoryProvider.overrideWithValue(FakeSession(null)),
        publicContentCacheProvider.overrideWithValue(cache),
        sermonsRepositoryProvider.overrideWithValue(sermons ?? FakeSermons()),
        contentRepositoryProvider.overrideWithValue(content ?? FakeContent()),
        givingRepositoryProvider.overrideWithValue(giving ?? FakeGiving()),
        bannerRepositoryProvider.overrideWithValue(assets ?? FakeBanners()),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// Real file I/O finishes on the event loop, not in microtasks.
  Future<void> settle(bool Function() done) async {
    for (var i = 0; i < 400 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(done(), isTrue, reason: 'the awaited step never happened');
  }

  /// Holds the shared adapter queue on a banner download until released.
  Completer<Uint8List?> blockQueue(PublicContentCacheAdapter cache) {
    final gate = Completer<Uint8List?>();
    unawaited(
      cache.writeRead(
        PublicContentCacheKeys.homeBanners,
        PublicBanners.fromJson(publicBannersData([publicBannerData()])),
        loadBannerImage: (_) => gate.future,
      ),
    );
    return gate;
  }

  PublicSermons catalog() => PublicSermons.fromJson({
    'sermons': [
      publicSermonData(id: withdrawn, title: 'SYNTHETIC Withdrawn'),
      publicSermonData(id: unrelated, title: 'SYNTHETIC Kept'),
    ],
    'series': [],
    'truncated': false,
  });

  PublicEvents calendar() => PublicEvents.fromJson(
    publicEventsData([
      publicEventData(eventId: withdrawnEvent),
      publicEventData(eventId: unrelatedEvent, title: 'SYNTHETIC Kept'),
    ]),
  );

  test('F3: an old catalog read cannot bring back a withdrawn sermon through the blocked queue', () async {
    final cache = adapter();
    final repo = _GatedSermons()..catalog = AccessReadOk(catalog());
    final c = container(cache: cache, sermons: repo);
    final list = c.listen(publicSermonsProvider, (_, _) {});
    addTearDown(list.close);

    // Seeded: both sermons on screen and on disk.
    await settle(() => c.read(publicSermonsProvider).savedAt != null);
    expect((await cache.readSermons())?.value.byId(withdrawn), isNotNull);

    // The shared queue is held by a slow banner download.
    final queue = blockQueue(cache);
    // Old catalog request A starts.
    repo.gated = true;
    unawaited(c.read(publicSermonsProvider.notifier).reload());
    await settle(() => repo.pending.length == 1);

    // A fresh detail read says the sermon is withdrawn; removal queues.
    repo.details[withdrawn] = const AccessReadOk(PublicSermonRead(null));
    final detail = c.listen(publicSermonProvider(withdrawn), (_, _) {});
    addTearDown(detail.close);
    await settle(() => repo.detailCalls.contains(withdrawn));
    await pumpEventQueue();

    // A answers with the withdrawn sermon still present.
    repo.pending[0].complete(AccessReadOk(catalog()));
    await pumpEventQueue();
    // The old answer is stale: it never reaches the screen.
    expect(c.read(publicSermonsProvider).value?.byId(withdrawn), isNull);

    // The queue drains: banner, removal, and any stale catalog save.
    queue.complete(imageBytes);
    // A no-op queued last: once it runs, every earlier write has finished.
    await cache.removeEvent('00000000-0000-4000-8000-000000000000');

    // The follow-up refresh fails after the stale save finished.
    await settle(() => repo.pending.length == 2);
    repo.pending[1].complete(const AccessReadFailed(unreachable: true));
    await settle(() => !c.read(publicSermonsProvider).loading);

    final now = c.read(publicSermonsProvider);
    expect(now.value?.byId(withdrawn), isNull, reason: 'on screen');
    expect(now.value?.byId(unrelated), isNotNull);

    // A fresh offline container on a cold adapter.
    final cold = adapter();
    final saved = await cold.readSermons();
    expect(saved?.value.byId(withdrawn), isNull, reason: 'on disk');
    expect(saved?.value.byId(unrelated), isNotNull);
    final offline = container(
      cache: cold,
      sermons: FakeSermons()
        ..catalog = const AccessReadFailed(unreachable: true)
        ..details[withdrawn] = const AccessReadFailed(unreachable: true),
    );
    final again = offline.listen(publicSermonsProvider, (_, _) {});
    addTearDown(again.close);
    final gone = offline.listen(publicSermonProvider(withdrawn), (_, _) {});
    addTearDown(gone.close);
    await settle(
      () =>
          !offline.read(publicSermonsProvider).loading &&
          !offline.read(publicSermonProvider(withdrawn)).loading,
    );
    expect(offline.read(publicSermonsProvider).value?.byId(withdrawn), isNull);
    expect(
      offline.read(publicSermonsProvider).value?.byId(unrelated),
      isNotNull,
    );
    expect(offline.read(publicSermonProvider(withdrawn)).value, isNull);
  });

  test('F3: an old Calendar read cannot bring back a withdrawn event through the blocked queue', () async {
    final cache = adapter();
    final repo = _GatedContent()..publicEvents = AccessReadOk(calendar());
    final c = container(cache: cache, content: repo);
    final list = c.listen(publicEventsProvider, (_, _) {});
    addTearDown(list.close);

    await settle(() => c.read(publicEventsProvider).savedAt != null);
    expect((await cache.readEvents())?.value.events.map((e) => e.eventId), [
      withdrawnEvent,
      unrelatedEvent,
    ]);

    final queue = blockQueue(cache);
    repo.gated = true;
    unawaited(c.read(publicEventsProvider.notifier).reload());
    await settle(() => repo.pending.length == 1);

    repo.publicEvent[withdrawnEvent] = const AccessReadOk(
      PublicEventRead(null),
    );
    final detail = c.listen(publicEventProvider(withdrawnEvent), (_, _) {});
    addTearDown(detail.close);
    await settle(() => repo.publicEventAsked.contains(withdrawnEvent));
    await pumpEventQueue();

    repo.pending[0].complete(AccessReadOk(calendar()));
    await pumpEventQueue();
    expect(c.read(publicEventsProvider).value?.events.map((e) => e.eventId), [
      unrelatedEvent,
    ]);

    queue.complete(imageBytes);
    await cache.removeSermon('00000000-0000-4000-8000-000000000000');

    await settle(() => repo.pending.length == 2);
    repo.pending[1].complete(const AccessReadFailed(unreachable: true));
    await settle(() => !c.read(publicEventsProvider).loading);

    final now = c.read(publicEventsProvider);
    expect(now.value?.events.map((e) => e.eventId), [
      unrelatedEvent,
    ], reason: 'on screen');

    final cold = adapter();
    expect((await cold.readEvents())?.value.events.map((e) => e.eventId), [
      unrelatedEvent,
    ], reason: 'on disk');
    final offline = container(
      cache: cold,
      content: FakeContent()
        ..publicEvents = const AccessReadFailed(unreachable: true)
        ..publicEvent[withdrawnEvent] = const AccessReadFailed(
          unreachable: true,
        ),
    );
    final again = offline.listen(publicEventsProvider, (_, _) {});
    addTearDown(again.close);
    final gone = offline.listen(publicEventProvider(withdrawnEvent), (_, _) {});
    addTearDown(gone.close);
    await settle(
      () =>
          !offline.read(publicEventsProvider).loading &&
          !offline.read(publicEventProvider(withdrawnEvent)).loading,
    );
    expect(
      offline.read(publicEventsProvider).value?.events.map((e) => e.eventId),
      [unrelatedEvent],
    );
    expect(offline.read(publicEventProvider(withdrawnEvent)).value, isNull);
  });

  test(
    'C1: fresh giving detail shows before a changed logo finishes downloading',
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
      final changedLogo = {
        ...logo,
        'path': 'giving_method/$methodId/r2/logo.png',
        'rights_revision': 5,
      };
      final cache = adapter();
      // A cached method with its logo on disk.
      expect(
        await cache.writeRead(
          PublicContentCacheKeys.givingMethods,
          PublicGivingMethods.fromJson(
            publicGivingMethodsData([
              publicGivingMethodData(methodId: methodId, logo: logo),
            ]),
          ),
          loadGivingLogo: (_) async => imageBytes,
        ),
        isA<PublicContentCacheSaved>(),
      );

      // The detail now has new text and a new logo; the logo download stalls.
      final assets = _GatedAssets()..gate = Completer<Uint8List?>();
      final giving = FakeGiving()
        ..publicMethod[methodId] = AccessReadOk(
          PublicGivingMethodRead(
            sample: false,
            method: PublicGivingMethod.fromJson(
              publicGivingMethodData(
                methodId: methodId,
                name: 'SAMPLE Airtel Money (renamed)',
                publicationRevision: 2,
                logo: changedLogo,
              ),
            ),
          ),
        );
      final c = container(cache: cache, giving: giving, assets: assets);
      final detail = c.listen(publicGivingMethodProvider(methodId), (_, _) {});
      addTearDown(detail.close);

      await settle(() => assets.fetchedAssets.isNotEmpty);
      await settle(() => !c.read(publicGivingMethodProvider(methodId)).loading);
      final state = c.read(publicGivingMethodProvider(methodId));
      expect(state.offlineSnapshot, isFalse);
      expect(state.value?.method?.name, 'SAMPLE Airtel Money (renamed)');

      // The saved row already follows the fresh text and never keeps the
      // superseded logo while the new one downloads.
      final during = await adapter().readGivingMethods();
      expect(
        during?.value.methods.single.name,
        'SAMPLE Airtel Money (renamed)',
      );
      expect(during?.value.methods.single.logo?.offlineBytes, isNull);

      // Released, the new logo is saved for offline use.
      final changedBytes = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x02]);
      assets.gate!.complete(changedBytes);
      Uint8List? savedLogo;
      await settle(() {
        unawaited(
          cache.readGivingMethods().then(
            (s) => savedLogo = s?.value.methods.single.logo?.offlineBytes,
          ),
        );
        return savedLogo != null;
      });
      expect(savedLogo, changedBytes);
      final cold = await adapter().readGivingMethods();
      expect(cold?.value.methods.single.logo?.rightsRevision, 5);
      expect(cold?.value.methods.single.logo?.offlineBytes, changedBytes);
    },
  );

  test('F3 adapter: a save from a read begun before a removal leaves the removed rows out', () async {
    final cache = adapter();
    await cache.writeRead(PublicContentCacheKeys.sermons, catalog());
    await cache.writeRead(PublicContentCacheKeys.calendar, calendar());
    final before = cache.readGeneration;

    final queue = blockQueue(cache);
    final removals = [
      cache.removeSermon(withdrawn),
      cache.removeEvent(withdrawnEvent),
    ];
    expect(cache.readGeneration, before + 2);
    // Stale saves queued after the removals, from reads begun before them.
    final stale = [
      cache.writeRead(
        PublicContentCacheKeys.sermons,
        catalog(),
        readGeneration: before,
      ),
      cache.writeRead(
        PublicContentCacheKeys.calendar,
        calendar(),
        readGeneration: before,
      ),
    ];
    queue.complete(imageBytes);
    await Future.wait(removals);
    expect(
      await Future.wait(stale),
      everyElement(isA<PublicContentCacheSaved>()),
    );

    final cold = adapter();
    final sermons = (await cold.readSermons())!.value;
    expect(sermons.byId(withdrawn), isNull);
    expect(sermons.byId(unrelated), isNotNull);
    expect((await cold.readEvents())!.value.events.map((e) => e.eventId), [
      unrelatedEvent,
    ]);

    // A read begun after the removal (say the sermon is published again)
    // saves it as usual.
    await cache.writeRead(
      PublicContentCacheKeys.sermons,
      catalog(),
      readGeneration: cache.readGeneration,
    );
    expect((await adapter().readSermons())!.value.byId(withdrawn), isNotNull);
  });

  test(
    'C1 adapter: a background logo never returns after the method is hidden',
    () async {
      const methodId = '61616161-6161-4161-8161-616161616161';
      Map<String, Object?> logo(int rights) => {
        'path': 'giving_method/$methodId/r$rights/logo.png',
        'media_type': 'image/png',
        'width': 160,
        'height': 160,
        'rights_revision': rights,
        'offline_allowed': true,
      };
      final cache = adapter();
      await cache.writeRead(
        PublicContentCacheKeys.givingMethods,
        PublicGivingMethods.fromJson(
          publicGivingMethodsData([
            publicGivingMethodData(methodId: methodId, logo: logo(1)),
            publicBankMethodData(),
          ]),
        ),
        loadGivingLogo: (_) async => imageBytes,
      );
      final fresh = PublicGivingMethod.fromJson(
        publicGivingMethodData(
          methodId: methodId,
          publicationRevision: 2,
          logo: logo(2),
        ),
      );
      await cache.reconcileGivingMethod(fresh);
      final slow = Completer<Uint8List?>();
      final logoSave = cache.saveGivingLogo(
        fresh,
        loadGivingLogo: (_) => slow.future,
      );
      await pumpEventQueue();
      await cache.removeGivingMethod(methodId);
      slow.complete(imageBytes);
      await logoSave;

      final saved = (await adapter().readGivingMethods())!.value;
      expect(saved.methods.map((m) => m.methodId), [
        '62626262-6262-4262-8262-626262626262',
      ]);
      final logos = root
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.uri.pathSegments.last.startsWith('giving-logo-'));
      expect(logos, isEmpty);
    },
  );
}
