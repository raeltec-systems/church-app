// Review section 8: a successful public read shows before its offline save
// (and any optional image downloads) finishes; the save still runs.
import 'dart:async';

import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ClientTestHarness h;
  late Completer<void> gate;
  late ProviderContainer c;

  setUp(() {
    h = ClientTestHarness();
    gate = Completer<void>();
    h.publicContentCache
      ..available = true
      ..writeGate = gate;
    c = ProviderContainer(overrides: h.overrides());
    addTearDown(c.dispose);
  });

  test(
    'Home banners show before a slow offline save, then say saved',
    () async {
      final sub = c.listen(publicBannersProvider, (_, _) {});
      addTearDown(sub.close);
      await pumpEventQueue();

      final shown = c.read(publicBannersProvider);
      expect(shown.result, isA<AccessReadOk<PublicBanners>>());
      expect(shown.loading, isFalse);
      expect(shown.savedAt, isNull);
      expect(h.publicContentCache.writes.map((w) => w.$1), [
        PublicContentCacheKeys.homeBanners,
      ]);

      gate.complete();
      await pumpEventQueue();
      final saved = c.read(publicBannersProvider);
      expect(saved.savedAt, h.publicContentCache.savedAt);
      expect(identical(saved.result, shown.result), isTrue);
    },
  );

  test('a save finishing after a newer read never relabels it', () async {
    final sub = c.listen(publicEventsProvider, (_, _) {});
    addTearDown(sub.close);
    await pumpEventQueue();
    h.content.publicEvents = const AccessReadFailed(unreachable: true);
    await c.read(publicEventsProvider.notifier).reload();
    gate.complete();
    await pumpEventQueue();
    final s = c.read(publicEventsProvider);
    // The failed refresh keeps the events on screen and is not marked
    // saved by the earlier read's late save.
    expect(s.value, isNotNull);
    expect(s.refreshFailed, isNotNull);
    expect(s.savedAt, isNull);
  });
}
