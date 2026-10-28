import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _translationId = '61616161-6161-4161-8161-616161616161';
const _genesisOne = BibleChapterRef(bookId: 'GEN', chapter: 1);

Future<ClientTestHarness> _pumpRoute(
  WidgetTester tester,
  String location, {
  required bool staff,
  void Function(ClientTestHarness h)? configure,
}) async {
  tester.view.physicalSize = Size(staff ? 1200 : 390, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final harness = ClientTestHarness(account: null);
  configure?.call(harness);
  final router = buildClientRouter(
    initialLocation: location,
    memberHome: !staff,
    shell: (_, _, child) => Scaffold(body: AccessRefresher(child: child)),
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: harness.overrides(),
      child: MaterialApp.router(
        theme: staff ? churchStaffTheme() : churchMobileTheme(Brightness.light),
        routerConfig: router,
      ),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return harness;
}

void main() {
  testWidgets('a saved offline chapter offers an online retry', (tester) async {
    final harness = await _pumpRoute(
      tester,
      ClientPaths.bible,
      staff: false,
      configure: (harness) {
        harness.bible.translations = const AccessReadFailed(unreachable: true);
        harness.publicContentCache.bibleChapter = PublicContentSnapshot(
          savedAt: DateTime.utc(2026, 10, 26),
          value: PublicBibleChapter(
            translationId: _translationId,
            translationCode: 'WEB',
            translationName: 'SYNTHETIC Bible',
            reference: _genesisOne,
            verses: const [BibleVerse(number: 1, text: 'SYNTHETIC verse')],
            publicationRevision: 1,
            publishedAt: DateTime.utc(2026, 10, 22),
            offlineAllowed: true,
          ),
        );
      },
    );
    expect(find.byKey(const Key('bible-reconnect')), findsOneWidget);
    final before = harness.bible.translationCalls;
    await tester.tap(find.byKey(const Key('bible-reconnect')));
    await tester.pumpAndSettle();
    expect(harness.bible.translationCalls, greaterThan(before));
  });

  testWidgets('withdrawn Bible with a live revision can be republished', (
    tester,
  ) async {
    await _pumpRoute(
      tester,
      ClientPaths.contentBible,
      staff: true,
      configure: (harness) {
        harness.bible.staff = const AccessReadOk(
          StaffBibleTranslations(
            capacity: ChurchRoles.media,
            translations: [
              StaffBibleTranslation(
                id: _translationId,
                revision: 5,
                code: 'WEB',
                name: 'SYNTHETIC Bible',
                state: ContentState.withdrawn,
                lastRevisionNo: 1,
                draftRevisionNo: null,
                liveRevisionNo: 1,
                draftComplete: false,
                draftVerseCount: 0,
                displayRightsError: null,
                offlineAllowed: false,
              ),
            ],
          ),
        );
      },
    );
    final publish = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Publish'),
    );
    expect(publish.onPressed, isNotNull);
  });

  testWidgets(
    'memory-only chapter is not labeled as saved after refresh fails',
    (tester) async {
      tester.view.physicalSize = const Size(390, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final harness = ClientTestHarness(account: null)
        ..bible.translations = AccessReadOk(
          PublicBibleTranslations([
            BibleTranslation(
              id: _translationId,
              code: 'TST99',
              name: 'SYNTHETIC test translation',
              chapters: const [_genesisOne],
              offlineAllowed: true,
            ),
          ]),
        )
        ..bible.chapters[(_translationId, _genesisOne)] = AccessReadOk(
          PublicBibleChapter(
            translationId: _translationId,
            translationCode: 'TST99',
            translationName: 'SYNTHETIC test translation',
            reference: _genesisOne,
            verses: const [BibleVerse(number: 1, text: 'SYNTHETIC verse')],
            publicationRevision: 1,
            publishedAt: DateTime.utc(2026, 10, 22),
            offlineAllowed: true,
          ),
        );
      final container = ProviderContainer(overrides: harness.overrides());
      addTearDown(container.dispose);
      final router = buildClientRouter(
        initialLocation: ClientPaths.bible,
        memberHome: true,
        shell: (_, _, child) => Scaffold(body: AccessRefresher(child: child)),
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            theme: churchMobileTheme(Brightness.light),
            routerConfig: router,
          ),
        ),
      );
      await container.read(bibleReaderProvider.notifier).reload();
      await tester.pumpAndSettle();

      harness.bible.chapters[(_translationId, _genesisOne)] =
          const AccessReadFailed(unreachable: true);
      await container.read(bibleReaderProvider.notifier).reload();
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Could not refresh this chapter. The copy shown is not saved for offline reading.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Offline copy saved'), findsNothing);
    },
  );

  testWidgets('chapter read failure has retry copy, not unavailable copy', (
    tester,
  ) async {
    await _pumpRoute(
      tester,
      ClientPaths.bible,
      staff: false,
      configure: (harness) {
        harness.bible.translations = AccessReadOk(
          PublicBibleTranslations([
            BibleTranslation(
              id: _translationId,
              code: 'TST99',
              name: 'SYNTHETIC test translation',
              chapters: const [_genesisOne],
              offlineAllowed: false,
            ),
          ]),
        );
        harness.bible.chapters[(_translationId, _genesisOne)] =
            const AccessReadFailed(unreachable: true);
      },
    );

    expect(
      find.text('This chapter could not be loaded. Try again.'),
      findsOneWidget,
    );
    expect(
      find.text('This chapter is not available in the selected translation.'),
      findsNothing,
    );
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('staff catalog read failure is distinct from an empty catalog', (
    tester,
  ) async {
    final harness = await _pumpRoute(
      tester,
      ClientPaths.contentBible,
      staff: true,
      configure: (harness) {
        harness.bible.staff = const AccessReadFailed(unreachable: true);
      },
    );

    expect(
      find.text('The Bible translation catalog could not be loaded.'),
      findsOneWidget,
    );
    expect(find.text('No translations have been added yet.'), findsNothing);
    expect(find.text('Try again'), findsOneWidget);
    expect(harness.bible.staffCalls, 1);
  });
}
