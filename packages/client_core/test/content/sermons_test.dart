import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _id = '92929292-9292-4292-8292-929292929292';

PublicSermons _catalog() => PublicSermons.fromJson({
  'sermons': [
    publicSermonData(series: publicSermonSeriesData()),
    publicSermonData(
      id: '93939393-9393-4393-8393-939393939393',
      title: 'SYNTHETIC Another sermon',
      speaker: 'SYNTHETIC Speaker Two',
    ),
  ],
  'series': [publicSermonSeriesData()],
  'truncated': false,
});

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Future<ClientTestHarness> _pump(
  WidgetTester tester,
  String path, {
  void Function(ClientTestHarness)? setup,
  bool staff = false,
  SermonPlayerBuilder? player,
}) async {
  tester.view.physicalSize = Size(staff ? 1280 : 390, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final harness = ClientTestHarness(
    account: staff ? 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' : null,
  );
  harness.sermons.catalog = AccessReadOk(_catalog());
  harness.sermons.details[_id] = AccessReadOk(
    PublicSermonRead(_catalog().sermons.first),
  );
  setup?.call(harness);
  final router = buildClientRouter(
    initialLocation: path,
    memberHome: !staff,
    shell: (_, _, child) => child,
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...harness.overrides(),
        if (player != null)
          sermonPlayerBuilderProvider.overrideWithValue(player),
      ],
      child: MaterialApp.router(
        theme: staff ? churchStaffTheme() : churchMobileTheme(Brightness.light),
        routerConfig: router,
      ),
    ),
  );
  await _settle(tester);
  return harness;
}

void main() {
  test('strict public models refuse private fields and unsafe notes', () {
    expect(PublicSermon.fromJson(publicSermonData()).publicationRevision, 1);
    for (final extra in [
      'saved_by',
      'draft',
      'source_duty_id',
      'private_provenance',
    ]) {
      expect(
        () => PublicSermon.fromJson({...publicSermonData(), extra: 'private'}),
        throwsFormatException,
      );
    }
    expect(
      () => PublicSermon.fromJson(
        publicSermonData(notes: '<script>bad</script>'),
      ),
      throwsFormatException,
    );
    expect(
      () => PublicSermonSeries.fromJson({
        ...publicSermonSeriesData(),
        'created_by': 'private',
      }),
      throwsFormatException,
    );
  });

  test('notes accept the supported subset and exact-host links', () {
    validateSermonNotes(
      '# Heading\n\nParagraph with **bold** and *emphasis*.\n\n- Item\n1. Item\n\n[Read](https://ebible.org/web/GEN01.htm)',
    );
    for (final host in sermonLinkHosts) {
      expect(safeSermonLink('https://$host/path?q=1#verse'), isNotNull);
    }
  });
  for (final notes in [
    '<b>text</b>',
    '![image](https://ebible.org/image.png)',
    '[link](javascript:alert)',
    '[link](http://ebible.org)',
    '[link](https://ebible.org.evil.test)',
    '[link](https://person@ebible.org)',
    '[link](https://ebible.org:443)',
    '[link](https://%65bible.org)',
    '[ref][id]\n\n[id]: https://ebible.org',
    '<https://ebible.org>',
    'https://ebible.org',
    '[link](https://example.com)',
    '`code`',
    '> quote',
    '~~text~~',
  ]) {
    test(
      'notes refuse $notes',
      () => expect(() => validateSermonNotes(notes), throwsFormatException),
    );
  }
  test('YouTube paste normalization preserves strict IDs and rejects disguised hosts', () {
    for (final value in [
      'abcdefghijk',
      'https://youtube.com/watch?v=abcdefghijk&t=30',
      'https://www.youtube.com/shorts/abcdefghijk',
      'https://youtube.com/embed/abcdefghijk',
      'https://youtu.be/abcdefghijk',
    ]) {
      expect(normalizeSermonVideoId(value), 'abcdefghijk');
    }
    for (final value in [
      'https://youtube.com.evil.test/watch?v=abcdefghijk',
      'https://evil@youtube.com/watch?v=abcdefghijk',
      'http://youtu.be/abcdefghijk',
      'https://youtube.com:443/embed/abcdefghijk',
      'https://youtube.com/watch?v=abcdefghijk&v=XXXXXXXXXXX',
      'not-an-id',
    ]) {
      expect(normalizeSermonVideoId(value), isNull);
    }
  });

  test('catalog filters local title, series and speaker without changing the canonical rows', () {
    final catalog = _catalog();
    expect(catalog.filter(query: 'hope'), hasLength(1));
    expect(
      catalog.filter(speaker: 'SYNTHETIC Speaker Two').single.title,
      'SYNTHETIC Another sermon',
    );
    expect(
      catalog.filter(seriesId: catalog.series.single.seriesId),
      hasLength(1),
    );
    expect(catalog.sermons, hasLength(2));
  });

  testWidgets(
    'guest searches, chooses series and opens readable teaching with a fake player',
    (tester) async {
      final h = await _pump(
        tester,
        SermonPaths.list,
        player: (_, videoId) => Text('FAKE player $videoId'),
      );
      await tester.enterText(find.byKey(const Key('sermons-search')), 'hope');
      await _settle(tester);
      expect(find.byKey(const Key('sermon-row-$_id')), findsOneWidget);
      expect(find.text('SYNTHETIC Another sermon'), findsNothing);
      expect(
        (h.publicContentCache.writes.single.$2 as PublicSermons).sermons,
        hasLength(2),
      );
      await tester.tap(find.byKey(const Key('sermons-filter-series')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('sermon-row-$_id')));
      await _settle(tester);
      expect(find.text('FAKE player abcdefghijk'), findsOneWidget);
      expect(find.text('John 1:1'), findsOneWidget);
      expect(find.byType(SermonNotes), findsOneWidget);
      expect(h.sermons.detailCalls, [_id]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an unavailable video leaves scripture and notes readable', (
    tester,
  ) async {
    await _pump(
      tester,
      SermonPaths.detail(_id),
      setup: (h) {
        h.sermons.details[_id] = AccessReadOk(
          PublicSermonRead(
            PublicSermon.fromJson(publicSermonData(videoId: null)),
          ),
        );
      },
    );
    expect(find.byKey(const Key('sermon-video-unavailable')), findsOneWidget);
    expect(find.text('John 1:1'), findsOneWidget);
    expect(find.byType(SermonNotes), findsOneWidget);
  });

  testWidgets(
    'offline snapshot is labelled, searchable, and used for detail without invoking the player',
    (tester) async {
      final h = await _pump(
        tester,
        SermonPaths.list,
        setup: (h) {
          h.publicContentCache.available = true;
          h.publicContentCache.sermons = PublicContentSnapshot(
            value: _catalog(),
            savedAt: DateTime.utc(2026, 10, 26, 8, 30),
          );
          h.sermons.catalog = const AccessReadFailed(unreachable: true);
          h.sermons.details[_id] = const AccessReadFailed(unreachable: true);
        },
        player: (_, _) => throw StateError('offline player invoked'),
      );
      expect(find.textContaining('Offline · saved at'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('sermons-search')),
        'Speaker One',
      );
      await _settle(tester);
      expect(find.byKey(const Key('sermon-row-$_id')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sermon-row-$_id')));
      await _settle(tester);
      expect(find.byKey(const Key('sermon-video-unavailable')), findsOneWidget);
      expect(find.byType(SermonNotes), findsOneWidget);
      expect(h.publicContentCache.writes, isEmpty);
    },
  );

  testWidgets(
    'failed first catalog read is an honest failure, never an empty state',
    (tester) async {
      await _pump(
        tester,
        SermonPaths.list,
        setup: (h) =>
            h.sermons.catalog = const AccessReadFailed(unreachable: true),
      );
      expect(find.text('No connection'), findsOneWidget);
      expect(find.byKey(const Key('sermons-empty')), findsNothing);
    },
  );

  testWidgets(
    'staff draft saves normalized video and retains typed notes on server field refusal',
    (tester) async {
      final h = await _pump(
        tester,
        '${SermonPaths.staff}/new',
        staff: true,
        setup: (h) {
          h.sermons.staff = const AccessReadOk(
            StaffSermons(capacity: 'media', sermons: []),
          );
          h.sermons.staffSeries = const AccessReadOk(
            StaffSermonSeriesCatalog(capacity: 'media', series: []),
          );
          h.banners.staffRights = const AccessReadOk(
            StaffRights(capacity: 'media', rights: [], truncated: false),
          );
        },
      );
      await tester.enterText(
        find.byKey(const Key('sermon-field-title')),
        'SYNTHETIC Draft',
      );
      await tester.tap(find.byKey(const Key('sermon-field-sermon_date')));
      await tester.pumpAndSettle();
      expect(find.byType(CalendarDatePicker), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('sermon-field-notes')),
        'SYNTHETIC keep this input',
      );
      await tester.enterText(
        find.byKey(const Key('sermon-field-youtube_video_id')),
        'https://youtu.be/abcdefghijk',
      );
      await tester.ensureVisible(find.byKey(const Key('sermon-save-draft')));
      await tester.tap(find.byKey(const Key('sermon-save-draft')));
      await _settle(tester);
      expect(h.gateway.sent.single.request.command, SermonCommands.create);
      expect(
        h.gateway.sent.single.request.payload['youtube_video_id'],
        'abcdefghijk',
      );
      expect(
        h.gateway.sent.single.request.payload['sermon_date'],
        matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')),
      );
      h.gateway.sent.single.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'notes': 'invalid'},
      );
      await _settle(tester);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('sermon-field-notes')))
            .controller!
            .text,
        'SYNTHETIC keep this input',
      );
      expect(find.byKey(const Key('sermon-notice-invalid')), findsOneWidget);
    },
  );
}
