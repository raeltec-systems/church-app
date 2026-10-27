import 'dart:typed_data';

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
      await tester.tap(find.byKey(const Key('sermons-search-open')));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('sermons-search')), 'hope');
      await _settle(tester);
      expect(find.byKey(const Key('sermon-row-$_id')), findsOneWidget);
      expect(find.text('SYNTHETIC Another sermon'), findsNothing);
      expect(
        (h.publicContentCache.writes.single.$2 as PublicSermons).sermons,
        hasLength(2),
      );
      await tester.tap(find.byKey(const ValueKey('segment-Series')));
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
      await tester.tap(find.byKey(const Key('sermons-search-open')));
      await _settle(tester);
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
  test('links use exact lowercase hosts like the server check', () {
    expect(safeSermonLink('https://ebible.org/web/GEN01.htm'), isNotNull);
    for (final link in [
      'https://EBIBLE.ORG/',
      'https://ebible.org/a"b',
      "https://ebible.org/a'b",
      r'https://ebible.org/a\b',
      'https://ebible.org/a b',
    ]) {
      expect(safeSermonLink(link), isNull, reason: link);
    }
  });

  test(
    'the current series follows the latest sermon; dates name the weekday',
    () {
      final older = publicSermonSeriesData(
        id: '94949494-9494-4494-8494-949494949494',
        title: 'SYNTHETIC Older series',
      );
      final catalog = PublicSermons.fromJson({
        'sermons': [
          publicSermonData(series: publicSermonSeriesData()),
          publicSermonData(
            id: '93939393-9393-4393-8393-939393939393',
            series: older,
          ),
        ],
        // The older series was published (or republished) most recently.
        'series': [older, publicSermonSeriesData()],
        'truncated': false,
      });
      expect(currentSermonSeries(catalog)?.title, 'SYNTHETIC Living hope');
      expect(
        currentSermonSeries(
          PublicSermons.fromJson({
            'sermons': [publicSermonData()],
            'series': [older],
            'truncated': false,
          }),
        ),
        isNull,
      );
      expect(
        currentSermonSeries(const PublicSermons(sermons: [], series: [])),
        isNull,
      );
      final now = DateTime.utc(2026, 10, 1);
      expect(sermonDateText(DateTime.utc(2026, 9, 27), now: now), 'Sun 27 Sep');
      expect(
        sermonDateText(DateTime.utc(2025, 9, 28), now: now),
        'Sun 28 Sep 2025',
      );
    },
  );

  testWidgets(
    'the current series leads; series and speaker views group the rows',
    (tester) async {
      await _pump(tester, SermonPaths.list);
      const series = '91919191-9191-4191-8191-919191919191';
      expect(
        find.byKey(const Key('sermons-current-series-$series')),
        findsOneWidget,
      );
      expect(find.text('Current series'), findsOneWidget);
      expect(find.textContaining('1 sermon · '), findsOneWidget);
      // Latest: one list, no group headers.
      expect(
        find.byKey(const Key('sermons-group-series-$series')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('sermons-browse-series')));
      await _settle(tester);
      final inSeries = find.byKey(const Key('sermons-group-series-$series'));
      final outside = find.byKey(const Key('sermons-group-series-none'));
      expect(inSeries, findsOneWidget);
      expect(outside, findsOneWidget);
      expect(
        tester.getTopLeft(inSeries).dy,
        lessThan(tester.getTopLeft(outside).dy),
      );
      await tester.tap(find.byKey(const ValueKey('segment-Speaker')));
      await _settle(tester);
      final one = find.byKey(
        const Key('sermons-group-speaker-SYNTHETIC Speaker One'),
      );
      final two = find.byKey(
        const Key('sermons-group-speaker-SYNTHETIC Speaker Two'),
      );
      expect(one, findsOneWidget);
      expect(tester.getTopLeft(one).dy, lessThan(tester.getTopLeft(two).dy));
      await tester.tap(find.byKey(const Key('sermons-search-open')));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('sermons-search')), 'zzz');
      await _settle(tester);
      expect(find.byKey(const Key('sermons-no-results')), findsOneWidget);
      expect(find.byKey(const Key('sermons-empty')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a row marks a playable video only when the sermon has one', (
    tester,
  ) async {
    await _pump(
      tester,
      SermonPaths.list,
      setup: (h) => h.sermons.catalog = AccessReadOk(
        PublicSermons.fromJson({
          'sermons': [
            publicSermonData(),
            publicSermonData(
              id: '93939393-9393-4393-8393-939393939393',
              videoId: null,
            ),
          ],
          'series': [],
          'truncated': false,
        }),
      ),
    );
    Finder play(String id) => find.descendant(
      of: find.byKey(Key('sermon-row-$id')),
      matching: find.byIcon(Icons.play_circle_filled),
    );
    expect(play(_id), findsOneWidget);
    expect(play('93939393-9393-4393-8393-939393939393'), findsNothing);
  });

  testWidgets(
    'a withdrawn series leaves the teaching readable without its title',
    (tester) async {
      await _pump(
        tester,
        SermonPaths.detail(_id),
        setup: (h) => h.sermons.details[_id] = AccessReadOk(
          PublicSermonRead(PublicSermon.fromJson(publicSermonData())),
        ),
      );
      expect(find.byKey(const Key('sermon-title')), findsOneWidget);
      expect(find.byKey(const Key('sermon-series')), findsNothing);
      expect(find.byType(SermonNotes), findsOneWidget);
    },
  );

  testWidgets('a sermon that is no longer public says so', (tester) async {
    await _pump(
      tester,
      SermonPaths.detail(_id),
      setup: (h) =>
          h.sermons.details[_id] = const AccessReadOk(PublicSermonRead(null)),
    );
    expect(find.byKey(const Key('sermon-gone')), findsOneWidget);
    expect(find.byType(SermonNotes), findsNothing);
  });

  testWidgets(
    'staff rows carry one mark, withdraw asks first and archived items wait '
    'behind a toggle',
    (tester) async {
      Map<String, Object?> revision(int no, {String? video}) => {
        'revision_no': no,
        'title': 'SYNTHETIC Staff sermon $no',
        'speaker': 'SYNTHETIC Speaker',
        'sermon_date': '2026-10-25',
        'scripture_reference': 'Psalm 23',
        'notes': 'SYNTHETIC notes',
        'series_id': null,
        'youtube_video_id': video,
        'video_rights': video == null
            ? null
            : {
                'rights_id': '95959595-9595-4595-8595-959595959595',
                'label': 'SYNTHETIC Video rights',
                'state': 'withdrawn',
                'live_revision_no': 1,
                'display': 'not_in_force',
              },
        'saved_at': '2026-10-25T08:00:00Z',
        'saved_by': 'SYNTHETIC Editor',
      };
      Map<String, Object?> item(
        String id,
        String state, {
        Map<String, Object?>? live,
        Map<String, Object?>? draft,
      }) => {
        'sermon_id': id,
        'revision': 3,
        'state': state,
        'created_at': '2026-10-25T08:00:00Z',
        'created_by': 'SYNTHETIC Editor',
        'updated_at': '2026-10-25T08:00:00Z',
        'published_at': live == null ? null : '2026-10-25T09:00:00Z',
        'published_by': live == null ? null : 'SYNTHETIC Editor',
        'withdrawn_at': null,
        'archived_at': state == 'archived' ? '2026-10-25T10:00:00Z' : null,
        'live': live,
        'draft': draft,
      };
      const hidden = 'a1a1a1a1-a1a1-41a1-81a1-a1a1a1a1a1a1';
      const archived = 'a2a2a2a2-a2a2-42a2-82a2-a2a2a2a2a2a2';
      const draft = 'a3a3a3a3-a3a3-43a3-83a3-a3a3a3a3a3a3';
      final h = await _pump(
        tester,
        SermonPaths.staff,
        staff: true,
        setup: (h) => h.sermons.staff = AccessReadOk(
          StaffSermons.fromJson({
            'capacity': 'media',
            'sermons': [
              item(draft, 'draft', draft: revision(1)),
              item(
                hidden,
                'published',
                live: revision(1, video: 'abcdefghijk'),
              ),
              item(archived, 'archived', live: revision(1)),
            ],
            'truncated': false,
          }),
        ),
      );
      expect(find.byKey(const Key('sermon-section-waiting')), findsOneWidget);
      expect(find.text('Published, video hidden'), findsOneWidget);
      expect(find.byKey(const Key('sermon-$archived')), findsNothing);
      await tester.tap(find.byKey(const Key('sermon-show-archived')));
      await _settle(tester);
      expect(find.byKey(const Key('sermon-$archived')), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('sermon-withdraw-$hidden')),
      );
      await tester.tap(find.byKey(const Key('sermon-withdraw-$hidden')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sermon-confirm-no')));
      await tester.pumpAndSettle();
      expect(h.gateway.sent, isEmpty);
      await tester.tap(find.byKey(const Key('sermon-withdraw-$hidden')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sermon-confirm-yes')));
      await _settle(tester);
      expect(h.gateway.sent.single.request.command, SermonCommands.withdraw);
      expect(h.gateway.sent.single.request.payload, {'sermon_id': hidden});
    },
  );

  test('a series parses its poster state; a sermon has none', () {
    Map<String, Object?> series(String? image) => {
      'series_id': '96969696-9696-4696-8696-969696969696',
      'revision': 2,
      'state': 'published',
      'published_at': '2026-10-25T09:00:00Z',
      'published_by': 'SYNTHETIC Editor',
      'public_image': image,
      'live': {
        'revision_no': 1,
        'title': 'SYNTHETIC Series',
        'description': '',
        'alt_text': '',
        'poster': null,
        'rights': null,
        'saved_at': '2026-10-25T08:00:00Z',
        'saved_by': 'SYNTHETIC Editor',
      },
      'draft': null,
    };
    StaffSermonSeries parse(String? image) => StaffSermonSeries.fromJson(
      series(image),
      'series_id',
      StaffSermonSeriesRevision.fromJson,
    );
    expect(parse('waiting').publicImage, PublicImageState.waiting);
    expect(parse(null).publicImage, isNull);
    expect(() => parse('elsewhere'), throwsFormatException);
  });
  test('notes limits count characters and refuse Unicode line breaks', () {
    validateSermonNotes('${'a' * 19990}${'\u{1F600}' * 10}');
    expect(
      () => validateSermonNotes('${'a' * 19991}${'\u{1F600}' * 10}'),
      throwsFormatException,
    );
    for (final breakChar in [' ', ' ']) {
      expect(
        () => validateSermonNotes('Intro${breakChar}text'),
        throwsFormatException,
      );
    }
  });

  testWidgets('intraword underscores stay plain text', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: churchMobileTheme(Brightness.light),
          home: const Scaffold(
            body: SermonNotes(markdown: 'Read name__part__x and snake_case.'),
          ),
        ),
      ),
    );
    expect(
      find.textContaining('name__part__x and snake_case.', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('rows without a poster or video carry no empty media slot', (
    tester,
  ) async {
    await _pump(
      tester,
      SermonPaths.list,
      setup: (h) => h.sermons.catalog = AccessReadOk(
        PublicSermons.fromJson({
          'sermons': [publicSermonData(videoId: null)],
          'series': [],
          'truncated': false,
        }),
      ),
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('sermon-row-$_id')),
        matching: find.byType(ClipRRect),
      ),
      findsNothing,
    );
    expect(find.byKey(const Key('sermons-search')), findsNothing);
  });

  testWidgets(
    'the list shows before posters download; cleared posters are saved after',
    (tester) async {
      final bytes = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);
      final series = publicSermonSeriesData(poster: true);
      final h = await _pump(
        tester,
        SermonPaths.list,
        setup: (h) {
          h.publicContentCache.available = true;
          h.banners.publicImageBytes = bytes;
          h.sermons.catalog = AccessReadOk(
            PublicSermons.fromJson({
              'sermons': [publicSermonData(series: series)],
              'series': [series],
              'truncated': false,
            }),
          );
        },
      );
      await _settle(tester);
      expect(find.byKey(const Key('sermon-row-$_id')), findsOneWidget);
      final writes = h.publicContentCache.writes
          .where((w) => w.$1 == PublicContentCacheKeys.sermons)
          .toList();
      expect(writes, hasLength(2));
      expect(
        h.publicContentCache.sermons?.value.series.single.poster?.offlineBytes,
        bytes,
      );
    },
  );

  testWidgets(
    'only the current series keeps its poster offline; older series stay online only',
    (tester) async {
      final bytes = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);
      const currentId = '93939393-9393-4393-8393-939393939393';
      final current = publicSermonSeriesData(
        id: currentId,
        title: 'SYNTHETIC Current series',
        poster: true,
      );
      final older = publicSermonSeriesData(poster: true);
      final h = await _pump(
        tester,
        SermonPaths.list,
        setup: (h) {
          h.publicContentCache.available = true;
          h.banners.publicImageBytes = bytes;
          h.sermons.catalog = AccessReadOk(
            PublicSermons.fromJson({
              // Newest first, as the public read orders them.
              'sermons': [
                publicSermonData(
                  id: '94949494-9494-4494-8494-949494949494',
                  series: current,
                ),
                publicSermonData(series: older),
              ],
              'series': [current, older],
              'truncated': false,
            }),
          );
        },
      );
      await _settle(tester);
      expect(h.banners.fetchedAssets, ['$currentId/1/poster.png']);
      final saved = h.publicContentCache.sermons!.value;
      expect(saved.series.map((s) => s.seriesId), [
        currentId,
        older['series_id'],
      ]);
      expect(saved.series.first.poster?.offlineBytes, bytes);
      expect(saved.series.last.poster, isNull);
      expect(saved.sermons.map((s) => s.series?.poster?.offlineBytes != null), [
        true,
        false,
      ]);
    },
  );
}
