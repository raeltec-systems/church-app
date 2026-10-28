// Owner decision 2026-10-28: a saved Calendar event opens offline, read from
// the saved Calendar list. Unknown and withdrawn events never come back.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _saved = '71717171-7171-4171-8171-717171717171';
const _other = '72727272-7272-4272-8272-727272727272';
const _unknown = '73737373-7373-4373-8373-737373737373';
const _offline = AccessReadFailed<PublicEventRead>(unreachable: true);

void main() {
  late ClientTestHarness h;
  final savedAt = DateTime.utc(2026, 10, 27, 9);

  setUp(() {
    h = ClientTestHarness();
    h.publicContentCache
      ..available = true
      ..events = PublicContentSnapshot(
        value: PublicEvents.fromJson(
          publicEventsData([
            publicEventData(eventId: _saved),
            publicEventData(eventId: _other, title: 'SYNTHETIC Youth night'),
          ]),
        ),
        savedAt: savedAt,
      );
    h.content.publicEvents = const AccessReadFailed(unreachable: true);
    for (final id in [_saved, _other, _unknown]) {
      h.content.publicEvent[id] = _offline;
    }
  });

  ProviderContainer open() {
    final c = ProviderContainer(overrides: h.overrides());
    addTearDown(c.dispose);
    return c;
  }

  Future<PublicReadState<PublicEventRead>> detail(
    ProviderContainer c,
    String id,
  ) async {
    final sub = c.listen(publicEventProvider(id), (_, _) {});
    addTearDown(sub.close);
    await pumpEventQueue();
    return c.read(publicEventProvider(id));
  }

  test('a saved event opens offline and says when it was saved', () async {
    final s = await detail(open(), _saved);
    expect(s.value?.event?.eventId, _saved);
    expect(s.offlineSnapshot, isTrue);
    expect(s.savedAt, savedAt);
    expect(s.refreshFailed, isNotNull);
  });

  test('an event the saved list does not hold is an honest failure', () async {
    final s = await detail(open(), _unknown);
    expect(s.value, isNull);
    expect(s.result, isA<AccessReadFailed<PublicEventRead>>());
    expect(s.offlineSnapshot, isFalse);
  });

  test(
    'a withdrawn event leaves the saved Calendar and never opens offline again',
    () async {
      h.content.publicEvent[_saved] = const AccessReadOk(PublicEventRead(null));
      final online = open();
      final list = online.listen(publicEventsProvider, (_, _) {});
      addTearDown(list.close);
      final fresh = await detail(online, _saved);
      await pumpEventQueue();
      expect(fresh.value?.event, isNull);
      expect(h.publicContentCache.removedEvents, [_saved]);
      final listed = online.read(publicEventsProvider).value!.events;
      expect(listed.map((e) => e.eventId), [_other]);

      // Reopened offline: the withdrawn event is gone, the other one opens.
      h.content.publicEvent[_saved] = _offline;
      final reopened = open();
      expect((await detail(reopened, _saved)).value, isNull);
      expect((await detail(reopened, _other)).value?.event?.eventId, _other);
    },
  );
}
