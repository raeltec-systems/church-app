// Story 6.10: a sermon's public Facebook video or live link beside YouTube.
// All fixtures are SYNTHETIC; Facebook page names and ids are invented.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _id = '92929292-9292-4292-8292-929292929292';
const _fb = 'https://www.facebook.com/SyntheticChurch/videos/1061000000000001/';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

PublicSermons _catalog({String? facebook = _fb}) => PublicSermons.fromJson({
  'sermons': [publicSermonData(facebookUrl: facebook)],
  'series': [],
  'truncated': false,
});

Future<ClientTestHarness> _pump(
  WidgetTester tester,
  String path, {
  void Function(ClientTestHarness)? setup,
  bool staff = false,
  SermonFacebookPlayerBuilder? facebookPlayer,
  SermonPlayerBuilder? youtubePlayer,
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
        if (facebookPlayer != null)
          sermonFacebookPlayerBuilderProvider.overrideWithValue(facebookPlayer),
        if (youtubePlayer != null)
          sermonPlayerBuilderProvider.overrideWithValue(youtubePlayer),
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

void _staffSetup(ClientTestHarness h) {
  h.sermons.staff = const AccessReadOk(
    StaffSermons(capacity: 'media', sermons: []),
  );
  h.sermons.staffSeries = const AccessReadOk(
    StaffSermonSeriesCatalog(capacity: 'media', series: []),
  );
  h.banners.staffRights = const AccessReadOk(
    StaffRights(capacity: 'media', rights: [], truncated: false),
  );
}

void main() {
  group('the Facebook link allowlist matches the server', () {
    test('accepted forms are normalised to the stored form', () {
      const cases = {
        'https://www.facebook.com/SyntheticChurch/videos/1234567890123456/':
            'https://www.facebook.com/SyntheticChurch/videos/1234567890123456/',
        'https://facebook.com/SyntheticChurch/videos/1234567890123456':
            'https://www.facebook.com/SyntheticChurch/videos/1234567890123456/',
        'https://m.facebook.com/synthetic.church/videos/1234567890?mibextid=abc123':
            'https://www.facebook.com/synthetic.church/videos/1234567890/',
        'https://web.facebook.com/Synthetic-Church-1234/videos/987654321/#top':
            'https://www.facebook.com/Synthetic-Church-1234/videos/987654321/',
        'https://WWW.Facebook.com/SyntheticChurch/videos/1234567890/':
            'https://www.facebook.com/SyntheticChurch/videos/1234567890/',
        'https://www.facebook.com/watch?v=1234567890123456':
            'https://www.facebook.com/watch/?v=1234567890123456',
        'https://www.facebook.com/watch/?v=1234567890123456&ref=sharing':
            'https://www.facebook.com/watch/?v=1234567890123456',
        'https://www.facebook.com/watch/live/?ref=watch_permalink&v=1234567890123456':
            'https://www.facebook.com/watch/?v=1234567890123456',
        '  https://fb.watch/aBc_12-XyZ/  ': 'https://fb.watch/aBc_12-XyZ/',
        'https://fb.watch/aBc12?mibextid=x': 'https://fb.watch/aBc12/',
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        final result = normalizeSermonFacebookUrl(key);
        expect(result.url, value, reason: key);
        expect(result.problem, isNull, reason: key);
        expect(isNormalFacebookVideoUrl(value), isTrue, reason: value);
        expect(normalizeSermonFacebookUrl(value).url, value, reason: value);
      }
    });

    test('refused links name the same reason as the server', () {
      const cases = {
        'https://www.youtube.com/watch?v=abcdefghijk':
            SermonFacebookProblem.notFacebook,
        'https://facebook.com.evil.test/SyntheticChurch/videos/1234567890/':
            SermonFacebookProblem.notFacebook,
        'https://evilfacebook.com/SyntheticChurch/videos/1234567890/':
            SermonFacebookProblem.notFacebook,
        'http://www.facebook.com/SyntheticChurch/videos/1234567890/':
            SermonFacebookProblem.invalid,
        'https://user@www.facebook.com/SyntheticChurch/videos/1234567890/':
            SermonFacebookProblem.invalid,
        'https://www.facebook.com:443/SyntheticChurch/videos/1234567890/':
            SermonFacebookProblem.invalid,
        'https://www.facebook.com/SyntheticChurch/videos/12ab34/':
            SermonFacebookProblem.invalid,
        'https://www.facebook.com/SyntheticChurch/posts/1234567890/':
            SermonFacebookProblem.invalid,
        'https://www.facebook.com/share/v/AbCdEf123/':
            SermonFacebookProblem.invalid,
        'https://www.facebook.com/watch/?v=123&v=456789':
            SermonFacebookProblem.invalid,
        'https://www.facebook.com/%53ynthetic/videos/1234567890/':
            SermonFacebookProblem.invalid,
        'javascript:alert(1)': SermonFacebookProblem.invalid,
        'https://fb.watch/ab/': SermonFacebookProblem.invalid,
        'https://www.facebook.com/SyntheticChurch/live':
            SermonFacebookProblem.notEmbeddable,
        'https://www.facebook.com/SyntheticChurch/live_videos/':
            SermonFacebookProblem.notEmbeddable,
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        final result = normalizeSermonFacebookUrl(key);
        expect(result.problem, value, reason: key);
        expect(result.url, isNull, reason: key);
      }
      expect(
        normalizeSermonFacebookUrl(
          'https://www.facebook.com/SyntheticChurch/videos/${'1' * 490}',
        ).problem,
        SermonFacebookProblem.tooLong,
      );
      expect(normalizeSermonFacebookUrl('   ').url, isNull);
      expect(normalizeSermonFacebookUrl('   ').problem, isNull);
    });

    test('the embedded player URL carries the stored link and no autoplay', () {
      final uri = facebookSermonEmbedUri(_fb);
      expect(uri.scheme, 'https');
      expect(uri.host, 'www.facebook.com');
      expect(uri.path, '/plugins/video.php');
      expect(uri.queryParameters['href'], _fb);
      expect(uri.queryParameters['autoplay'], 'false');
      expect(uri.queryParameters.containsKey('width'), isFalse);
      final sized = facebookSermonEmbedUri(_fb, width: 358);
      expect(sized.queryParameters['width'], '358');
      expect(sized.queryParameters['height'], '201');
      expect(
        facebookSermonEmbedUri(_fb, width: 100).queryParameters['width'],
        '220',
      );
      expect(
        () => facebookSermonEmbedUri('https://m.facebook.com/x/videos/12345/'),
        throwsArgumentError,
      );
    });
  });

  test('the strict public model accepts one stored Facebook link', () {
    final sermon = PublicSermon.fromJson(publicSermonData(facebookUrl: _fb));
    expect(sermon.facebookVideoUrl, _fb);
    expect(sermon.youtubeVideoId, isNull);
    expect(sermon.hasVideo, isTrue);
    expect(
      PublicSermon.fromJson(publicSermonData(videoId: null)).hasVideo,
      isFalse,
    );
    for (final bad in [
      {
        ...publicSermonData(facebookUrl: _fb),
        'youtube_video_id': 'abcdefghijk',
      },
      {...publicSermonData(facebookUrl: _fb), 'rights_revision': null},
      publicSermonData(
        facebookUrl: 'https://m.facebook.com/SyntheticChurch/videos/12345/',
      ),
      publicSermonData(facebookUrl: 'https://evil.test/x/videos/12345/'),
    ]) {
      expect(() => PublicSermon.fromJson(bad), throwsFormatException);
    }
    final withoutKey = {...publicSermonData()}..remove('facebook_video_url');
    expect(() => PublicSermon.fromJson(withoutKey), throwsFormatException);
  });

  test('saved teaching never keeps a Facebook link', () {
    final cached = _catalog().toCacheJson();
    final sermon = (cached['sermons']! as List).single as Map;
    expect(sermon['facebook_video_url'], isNull);
    expect(sermon['rights_revision'], isNull);
    final restored = PublicSermons.fromJson(cached);
    expect(restored.sermons.single.hasVideo, isFalse);
  });

  testWidgets('a Facebook sermon is marked playable in the list', (
    tester,
  ) async {
    await _pump(tester, SermonPaths.list);
    expect(find.byKey(const Key('sermon-row-$_id')), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_filled), findsOneWidget);
  });

  testWidgets(
    'the detail plays a Facebook video in its own player and keeps the notes',
    (tester) async {
      final played = <String>[];
      await _pump(
        tester,
        SermonPaths.detail(_id),
        facebookPlayer: (context, url) {
          played.add(url);
          return const SizedBox(key: Key('fake-facebook-player'), height: 90);
        },
        youtubePlayer: (_, _) => throw StateError('YouTube player invoked'),
      );
      expect(played, [_fb]);
      expect(find.byKey(const Key('fake-facebook-player')), findsOneWidget);
      expect(find.text('John 1:1'), findsOneWidget);
      expect(find.byType(SermonNotes), findsOneWidget);
    },
  );

  testWidgets(
    'an unavailable Facebook video shows the unavailable state above the notes',
    (tester) async {
      await _pump(tester, SermonPaths.detail(_id));
      // The default seam (no platform player) is the unavailable state.
      expect(find.byKey(const Key('sermon-video-unavailable')), findsOneWidget);
      expect(
        find.text('This video is unavailable. You can read the notes below.'),
        findsOneWidget,
      );
      expect(find.byType(SermonNotes), findsOneWidget);
    },
  );

  testWidgets('offline, a Facebook sermon never starts the player', (
    tester,
  ) async {
    await _pump(
      tester,
      SermonPaths.detail(_id),
      setup: (h) {
        h.publicContentCache.available = true;
        h.publicContentCache.sermons = PublicContentSnapshot(
          value: PublicSermons.fromJson(_catalog().toCacheJson()),
          savedAt: DateTime.utc(2026, 10, 26, 8, 30),
        );
        h.sermons.catalog = const AccessReadFailed(unreachable: true);
        h.sermons.details[_id] = const AccessReadFailed(unreachable: true);
      },
      facebookPlayer: (_, _) => throw StateError('offline player invoked'),
    );
    expect(
      find.text('Video needs a connection. You can read the notes below.'),
      findsOneWidget,
    );
    expect(find.byType(SermonNotes), findsOneWidget);
  });

  testWidgets(
    'staff paste a Facebook link and the draft sends the stored form',
    (tester) async {
      final h = await _pump(
        tester,
        '${SermonPaths.staff}/new',
        staff: true,
        setup: _staffSetup,
      );
      await tester.enterText(
        find.byKey(const Key('sermon-field-title')),
        'SYNTHETIC Facebook draft',
      );
      await tester.enterText(
        find.byKey(const Key('sermon-field-facebook_video_url')),
        'https://m.facebook.com/SyntheticChurch/videos/1061000000000001/?mibextid=x',
      );
      await tester.ensureVisible(find.byKey(const Key('sermon-save-draft')));
      await tester.tap(find.byKey(const Key('sermon-save-draft')));
      await _settle(tester);
      final payload = h.gateway.sent.single.request.payload;
      expect(h.gateway.sent.single.request.command, SermonCommands.create);
      expect(payload['facebook_video_url'], _fb);
      expect(payload['youtube_video_id'], isNull);
    },
  );

  testWidgets(
    'staff see a non-Facebook link, a page Live address and two videos refused before sending',
    (tester) async {
      final h = await _pump(
        tester,
        '${SermonPaths.staff}/new',
        staff: true,
        setup: _staffSetup,
      );
      await tester.enterText(
        find.byKey(const Key('sermon-field-title')),
        'SYNTHETIC Facebook draft',
      );
      final field = find.byKey(const Key('sermon-field-facebook_video_url'));
      final save = find.byKey(const Key('sermon-save-draft'));
      Future<void> attempt(String link) async {
        await tester.enterText(field, link);
        await tester.ensureVisible(save);
        await tester.tap(save);
        await _settle(tester);
      }

      await attempt('https://example.org/SyntheticChurch/videos/1234567890/');
      expect(
        find.textContaining('This is not a Facebook link'),
        findsOneWidget,
      );
      await attempt('https://www.facebook.com/SyntheticChurch/live/');
      expect(
        find.textContaining("A page's Live address cannot play"),
        findsOneWidget,
      );
      await attempt('https://www.facebook.com/SyntheticChurch/videos/abc/');
      expect(
        find.textContaining('Paste the HTTPS link of one public Facebook'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('sermon-field-youtube_video_id')),
        'abcdefghijk',
      );
      await attempt(_fb);
      expect(find.textContaining('Clear the YouTube field or this one'), findsOneWidget);
      expect(h.gateway.sent, isEmpty);
      // Typed input stays for the editor to fix.
      expect(tester.widget<TextField>(field).controller!.text, _fb);
    },
  );

  testWidgets(
    'a server refusal of the Facebook link is explained on the field',
    (tester) async {
      final h = await _pump(
        tester,
        '${SermonPaths.staff}/new',
        staff: true,
        setup: _staffSetup,
      );
      await tester.enterText(
        find.byKey(const Key('sermon-field-title')),
        'SYNTHETIC Facebook draft',
      );
      await tester.enterText(
        find.byKey(const Key('sermon-field-facebook_video_url')),
        _fb,
      );
      await tester.ensureVisible(find.byKey(const Key('sermon-save-draft')));
      await tester.tap(find.byKey(const Key('sermon-save-draft')));
      await _settle(tester);
      h.gateway.sent.single.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'facebook_video_url': 'not_embeddable'},
      );
      await _settle(tester);
      expect(
        find.textContaining("A page's Live address cannot play"),
        findsWidgets,
      );
    },
  );
}
