import 'dart:convert';
import 'dart:io';

import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A valid format-1 book as JSON, for strictness tests to break one field at
/// a time. SYNTHETIC placeholder words only.
Map<String, Object?> _bookJson() => {
  'format': 1,
  'edition': 'test-1',
  'title': 'SYNTHETIC hymn book',
  'language': 'toi',
  'items': [
    {
      'id': 'hymn-1',
      'kind': 'hymn',
      'number': 1,
      'section': 'SYNTHETIC opening',
      'title': 'SYNTHETIC hymn 1',
      'original': 'SYNTHETIC ORIGINAL',
      'reference': 'Z.H. 3',
      'key': 'A flat',
      'verses': ['Line one,\nline two.', 'Second verse.'],
      'choruses': [
        {'from_verse': 1, 'text': 'Chorus line.'},
      ],
    },
    {
      'id': 'hymn-2',
      'kind': 'hymn',
      'number': 2,
      'section': 'SYNTHETIC opening',
      'title': 'SYNTHETIC hymn 2',
      'original': null,
      'reference': null,
      'key': null,
      'verses': ['Only verse:'],
      'choruses': <Object?>[],
    },
    {
      'id': 'chorus-1',
      'kind': 'chorus',
      'number': 1,
      'section': 'SYNTHETIC choruses',
      'title': 'SYNTHETIC chorus 1',
      'original': null,
      'reference': null,
      'key': null,
      'verses': ['First.', 'Second.'],
      'choruses': [
        {'from_verse': 1, 'text': 'Refrain A.'},
        {'from_verse': 2, 'text': 'Refrain B.'},
      ],
    },
  ],
};

HymnBook _parse(Map<String, Object?> json) =>
    parseHymnBookJson(jsonEncode(json));

Map<String, Object?> _item(Map<String, Object?> book, int index) =>
    ((book['items'] as List)[index] as Map).cast<String, Object?>();

Hymn _hymn(
  HymnKind kind,
  int number,
  String title, {
  String verse = 'Plain line.',
  String? original,
}) => Hymn(
  kind: kind,
  number: number,
  section: kind == HymnKind.hymn ? 'SYNTHETIC hymns' : 'SYNTHETIC choruses',
  title: title,
  original: original,
  reference: null,
  key: null,
  verses: [verse],
  choruses: const [],
);

HymnBook _searchBook() => HymnBook(
  format: 1,
  edition: 'test-1',
  title: 'SYNTHETIC',
  language: 'toi',
  items: [
    for (var n = 1; n <= 13; n++)
      _hymn(
        HymnKind.hymn,
        n,
        switch (n) {
          2 => 'SYNTHETIC 12 days',
          3 => "SYNTHETIC ng'anda title",
          4 => 'SYNTHETIC Jésus title',
          5 => 'SYNTHETIC ŋanda title',
          7 => 'SYNTHETIC „Quoted” ‟word',
          _ => 'SYNTHETIC hymn $n',
        },
        verse: n == 6 ? 'Morning light is breaking,\nsecond line.' : 'Plain.',
        original: n == 8 ? 'AMAZING GRACE' : null,
      ),
    for (var n = 1; n <= 12; n++)
      _hymn(HymnKind.chorus, n, 'SYNTHETIC chorus $n'),
  ],
);

List<String> _ids(List<Hymn> items) => [for (final h in items) h.id];

Future<ClientTestHarness> _pumpRoute(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? configure,
}) async {
  tester.view.physicalSize = const Size(390, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final harness = ClientTestHarness(account: null);
  configure?.call(harness);
  final router = buildClientRouter(
    initialLocation: location,
    memberHome: true,
    shell: (_, _, child) => Scaffold(body: AccessRefresher(child: child)),
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: harness.overrides(),
      child: MaterialApp.router(
        theme: churchMobileTheme(Brightness.light),
        routerConfig: router,
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return harness;
}

class _TextBundle extends CachingAssetBundle {
  _TextBundle(this.files);

  final Map<String, String> files;
  final requested = <String>[];

  @override
  Future<ByteData> load(String key) async {
    requested.add(key);
    final text = files[key];
    if (text == null) throw FlutterError('missing asset $key');
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(text)));
  }
}

/// The code points a TrueType font maps (cmap formats 4 and 12).
Set<int> _fontCodePoints(String path) {
  final data = ByteData.sublistView(File(path).readAsBytesSync());
  final tables = data.getUint16(4);
  var cmap = -1;
  for (var i = 0; i < tables; i++) {
    final record = 12 + 16 * i;
    final tag = String.fromCharCodes([
      for (var k = 0; k < 4; k++) data.getUint8(record + k),
    ]);
    if (tag == 'cmap') cmap = data.getUint32(record + 8);
  }
  final points = <int>{};
  final subtables = data.getUint16(cmap + 2);
  for (var i = 0; i < subtables; i++) {
    final at = cmap + data.getUint32(cmap + 4 + 8 * i + 4);
    final format = data.getUint16(at);
    if (format == 4) {
      final segments = data.getUint16(at + 6) ~/ 2;
      for (var s = 0; s < segments; s++) {
        final end = data.getUint16(at + 14 + 2 * s);
        final start = data.getUint16(at + 16 + 2 * segments + 2 * s);
        if (start == 0xffff) continue;
        for (var cp = start; cp <= end; cp++) {
          points.add(cp);
        }
      }
    } else if (format == 12) {
      final groups = data.getUint32(at + 12);
      for (var g = 0; g < groups; g++) {
        final start = data.getUint32(at + 16 + 12 * g);
        final end = data.getUint32(at + 20 + 12 * g);
        for (var cp = start; cp <= end; cp++) {
          points.add(cp);
        }
      }
    }
  }
  return points;
}

void main() {
  group('the shipped hymn book', () {
    final text = File('assets/hymn_book/hymn_book.json').readAsStringSync();

    test('is the church book: hymns 1..199 and choruses 1..67', () {
      final book = parseHymnBookJson(text);
      expect(book.edition, 'bicc-tonga-2012');
      expect(book.language, 'toi');
      expect(
        [for (final h in book.hymns) h.number],
        [for (var n = 1; n <= 199; n++) n],
      );
      expect(
        [for (final c in book.choruses) c.number],
        [for (var n = 1; n <= 67; n++) n],
      );
      for (final item in book.items) {
        expect(item.title, isNotEmpty);
        expect(item.section, isNotEmpty);
        expect(item.verses, isNotEmpty);
        expect(item.firstLine, isNotEmpty);
      }
      expect(book.items.first.section, 'Kutalika Mubungano');
      expect(book.choruses.map((c) => c.section).toSet(), {'Ziindululo'});
      expect(book.byId('hymn-1')?.key, 'F');
      expect(book.byId('chorus-24')?.choruses, hasLength(2));
      expect(text.contains('‟'), isFalse, reason: 'normalised to U+2019');
    });

    test('uses only characters both bundled fonts carry', () {
      final used = {
        for (final rune in text.runes)
          if (rune > 0x7e) rune,
      };
      for (final font in [
        '../design_system/fonts/Figtree-Regular.ttf',
        '../design_system/fonts/Outfit-Bold.ttf',
      ]) {
        final missing = used.difference(_fontCodePoints(font));
        expect(
          missing.map((cp) => 'U+${cp.toRadixString(16)}'),
          isEmpty,
          reason: font,
        );
      }
      // Tonga letters the converter may meet in a later edition.
      final figtree = _fontCodePoints(
        '../design_system/fonts/Figtree-Regular.ttf',
      );
      for (final cp in [0x14a, 0x14b, 0x2019, 0xe1, 0xe9, 0x308]) {
        expect(
          figtree.contains(cp),
          isTrue,
          reason: 'U+${cp.toRadixString(16)}',
        );
      }
    });

    test('is declared as a package asset under the key the apps read', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('- assets/hymn_book/hymn_book.json'));
      expect(
        BundledHymnBookSource.assetKey,
        'packages/church_client_core/assets/hymn_book/hymn_book.json',
      );
    });
  });

  group('the strict reader', () {
    test('reads hymns, then choruses, with their sections and choruses', () {
      final book = _parse(_bookJson());
      expect(_ids(book.items), ['hymn-1', 'hymn-2', 'chorus-1']);
      final first = book.byId('hymn-1')!;
      expect(first.firstLine, 'Line one');
      expect(first.original, 'SYNTHETIC ORIGINAL');
      expect(first.reference, 'Z.H. 3');
      expect(first.key, 'A flat');
      expect(first.chorusAfterVerse(1), 'Chorus line.');
      expect(first.chorusAfterVerse(2), 'Chorus line.');
      expect(book.byId('hymn-2')!.firstLine, 'Only verse');
      expect(book.byId('hymn-2')!.chorusAfterVerse(1), isNull);
      final chorus = book.byId('chorus-1')!;
      expect(chorus.chorusAfterVerse(1), 'Refrain A.');
      expect(chorus.chorusAfterVerse(2), 'Refrain B.');
      expect(book.byId('hymn-3'), isNull);
      expect(book.byId('chorus-01'), isNull);
      expect(book.byId('psalm-1'), isNull);
    });

    final broken = <String, void Function(Map<String, Object?> book)>{
      'an unknown top-level field': (b) => b['extra'] = true,
      'a missing field': (b) => b.remove('language'),
      'another format': (b) => b['format'] = 2,
      'a fractional format': (b) => b['format'] = 1.5,
      'a bad edition': (b) => b['edition'] = 'SYNTHETIC Book',
      'a bad language': (b) => b['language'] = 'Tonga',
      'no items': (b) => b['items'] = <Object?>[],
      'a gap': (b) => _item(b, 1)
        ..['number'] = 3
        ..['id'] = 'hymn-3',
      'a repeated number': (b) => _item(b, 1)
        ..['number'] = 1
        ..['id'] = 'hymn-1',
      'a chorus before the hymns': (b) =>
          (b['items'] as List).removeRange(0, 2),
      'a hymn after the choruses': (b) =>
          (b['items'] as List).add(_item(_bookJson(), 1)),
      'a mismatched id': (b) => _item(b, 0)['id'] = 'hymn-9',
      'an unknown kind': (b) => _item(b, 2)['kind'] = 'psalm',
      'an unknown item field': (b) => _item(b, 0)['audio'] = 'x',
      'a missing choruses field': (b) => _item(b, 1).remove('choruses'),
      'a blank section': (b) => _item(b, 0)['section'] = '',
      'a blank title': (b) => _item(b, 0)['title'] = ' ',
      'a two-line title': (b) => _item(b, 0)['title'] = 'One\nTwo',
      'a long title': (b) => _item(b, 0)['title'] = 'T' * 121,
      'a bad key': (b) => _item(b, 0)['key'] = 'H',
      'a key in symbols': (b) => _item(b, 0)['key'] = 'A♭',
      'no verses': (b) => _item(b, 0)['verses'] = <Object?>[],
      'a blank line in a verse': (b) => _item(b, 0)['verses'] = ['One\n\nTwo'],
      'an untrimmed line': (b) => _item(b, 0)['verses'] = ['One \nTwo'],
      'a long line': (b) => _item(b, 0)['verses'] = ['x' * 201],
      'too many verses': (b) => _item(b, 0)['verses'] = List.filled(41, 'V'),
      'a chorus after a missing verse': (b) => _item(b, 1)['choruses'] = [
        {'from_verse': 2, 'text': 'X'},
      ],
      'choruses out of order': (b) => _item(b, 2)['choruses'] = [
        {'from_verse': 2, 'text': 'B'},
        {'from_verse': 1, 'text': 'A'},
      ],
      'a blank chorus': (b) => _item(b, 0)['choruses'] = [
        {'from_verse': 1, 'text': ''},
      ],
      'a control character': (b) => _item(b, 0)['verses'] = ['Bell\u0007'],
      'a bidirectional override': (b) => _item(b, 0)['title'] = 'A\u202eB',
    };
    for (final MapEntry(key: what, value: breakIt) in broken.entries) {
      test('refuses $what', () {
        final json = _bookJson();
        breakIt(json);
        expect(() => _parse(json), throwsFormatException);
      });
    }

    test('refuses text that is not JSON', () {
      expect(() => parseHymnBookJson('{'), throwsFormatException);
      expect(() => parseHymnBookJson('[]'), throwsFormatException);
    });
  });

  group('on-device search', () {
    test('folds case, punctuation, quotation marks, diacritics and eng', () {
      expect(foldHymnText("Ng'anda"), 'nganda');
      expect(foldHymnText('NG’ANDA'), 'nganda');
      expect(foldHymnText('ng‟anda ngʼanda'), 'nganda nganda');
      expect(foldHymnText('Ŋanda ŋanda'), 'nganda nganda');
      expect(foldHymnText('Jésus, Æon!'), 'jesus aeon');
      expect(foldHymnText('Je\u0301sus'), 'jesus');
      expect(foldHymnText('“Kwamana,” „Zibi'), 'kwamana zibi');
      expect(foldHymnText('  Holy,  holy -- holy!  '), 'holy holy holy');
      expect(hymnQueryTokens('a b c d e f g h i j'), hasLength(8));
      expect(hymnQueryTokens('${'x' * 100}tail'), ['x' * 100]);
    });

    test('puts the exact number first, the hymn before the chorus', () {
      final book = _searchBook();
      expect(_ids(book.search('12')), ['hymn-12', 'chorus-12', 'hymn-2']);
      expect(_ids(book.search('1')), [
        'hymn-1',
        'chorus-1',
        'hymn-2', // "SYNTHETIC 12 days": digits in a title match too
        'hymn-10',
        'hymn-11',
        'hymn-12',
        'hymn-13',
        'chorus-10',
        'chorus-11',
        'chorus-12',
      ]);
    });

    test('matches every word of the title, first line or English title', () {
      final book = _searchBook();
      expect(_ids(book.search('nganda')), ['hymn-3', 'hymn-5']);
      expect(_ids(book.search("NG'ANDA title")), ['hymn-3', 'hymn-5']);
      expect(_ids(book.search('jesus')), ['hymn-4']);
      expect(_ids(book.search('quoted word')), ['hymn-7']);
      expect(_ids(book.search('morning breaking')), ['hymn-6']);
      expect(_ids(book.search('amazing grace')), ['hymn-8']);
      expect(book.search('second line'), isEmpty, reason: 'first line only');
      expect(book.search('morning zebra'), isEmpty);
      expect(book.search('   '), hasLength(25));
    });
  });

  group('the bundled source', () {
    test('reads the package asset key without caching', () async {
      final bundle = _TextBundle({
        BundledHymnBookSource.assetKey: jsonEncode(_bookJson()),
      });
      final book = await BundledHymnBookSource(bundle: bundle).load();
      expect(book.items, hasLength(3));
      expect(bundle.requested, [BundledHymnBookSource.assetKey]);
    });

    test(
      'parses a large book off the UI thread with the same result',
      () async {
        final json = _bookJson();
        json['items'] = [
          for (var n = 1; n <= 300; n++)
            {
              'id': 'hymn-$n',
              'kind': 'hymn',
              'number': n,
              'section': 'SYNTHETIC section',
              'title': 'SYNTHETIC hymn $n',
              'original': null,
              'reference': null,
              'key': null,
              'verses': [
                for (var v = 1; v <= 4; v++)
                  List.filled(4, 'Placeholder verse $v line text').join('\n'),
              ],
              'choruses': <Object?>[],
            },
        ];
        final text = jsonEncode(json);
        expect(text.length, greaterThan(64 * 1024));
        final book = await BundledHymnBookSource(
          bundle: _TextBundle({BundledHymnBookSource.assetKey: text}),
        ).load();
        expect(book.hymns, hasLength(300));
        expect(book.byId('hymn-300')?.title, 'SYNTHETIC hymn 300');
      },
    );

    test('a missing or malformed asset fails loudly', () async {
      await expectLater(
        BundledHymnBookSource(bundle: _TextBundle({})).load(),
        throwsA(isA<FlutterError>()),
      );
      await expectLater(
        BundledHymnBookSource(
          bundle: _TextBundle({BundledHymnBookSource.assetKey: '{"format":1}'}),
        ).load(),
        throwsFormatException,
      );
    });
  });

  group('the Hymn book screens', () {
    testWidgets('the tab opens on the Bible and switches to the hymn book in '
        'its printed sections', (tester) async {
      await _pumpRoute(tester, ClientPaths.bible);
      expect(find.byKey(const Key('bible-hymns-segment')), findsOneWidget);
      expect(find.byType(BibleReaderScreen), findsOneWidget);
      expect(find.byType(HymnBookView), findsNothing);
      await tester.tap(find.text('Hymn book'));
      await tester.pumpAndSettle();
      expect(find.byType(BibleReaderScreen), findsNothing);
      expect(find.text('SYNTHETIC opening'), findsOneWidget);
      expect(find.text('SYNTHETIC praise'), findsOneWidget);
      expect(find.text('SYNTHETIC choruses'), findsOneWidget);
      final opening = tester.getTopLeft(find.text('SYNTHETIC opening')).dy;
      final praise = tester.getTopLeft(find.text('SYNTHETIC praise')).dy;
      final choruses = tester.getTopLeft(find.text('SYNTHETIC choruses')).dy;
      expect(opening, lessThan(praise));
      expect(praise, lessThan(choruses));
      for (final id in ['hymn-1', 'hymn-2', 'hymn-3', 'chorus-1', 'chorus-2']) {
        expect(find.byKey(Key('hymn-row-$id')), findsOneWidget);
      }
      expect(
        tester.getTopLeft(find.byKey(const Key('hymn-row-hymn-3'))).dy,
        greaterThan(praise),
      );
      expect(find.text('SYNTHETIC hymn 1 verse one, line one'), findsOneWidget);
      expect(find.textContaining('Chorus ·'), findsNothing);
    });

    testWidgets('a link with view=hymns opens the hymn book, and the choice '
        'is remembered after a hymn', (tester) async {
      await _pumpRoute(tester, ClientPaths.hymnBook);
      expect(find.byType(HymnBookView), findsOneWidget);
      await tester.tap(find.byKey(const Key('hymn-row-hymn-2')));
      await tester.pumpAndSettle();
      expect(find.byType(HymnDetailScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(HymnBookView), findsOneWidget);
    });

    testWidgets('search lists results flat, the hymn before the chorus, and '
        'says when nothing matches', (tester) async {
      await _pumpRoute(tester, ClientPaths.hymnBook);
      final search = find.byKey(const Key('hymn-search'));
      await tester.enterText(search, '2');
      await tester.pump();
      expect(find.byKey(const Key('hymn-section-0')), findsNothing);
      final hymn = tester.getTopLeft(find.byKey(const Key('hymn-row-hymn-2')));
      final chorus = tester.getTopLeft(
        find.byKey(const Key('hymn-row-chorus-2')),
      );
      expect(hymn.dy, lessThan(chorus.dy));
      expect(find.byKey(const Key('hymn-row-hymn-1')), findsNothing);
      expect(
        find.text('Chorus · SYNTHETIC chorus 2 stanza, line one'),
        findsOneWidget,
      );
      await tester.enterText(search, 'SYNTHETIC hymn 3');
      await tester.pump();
      expect(find.byKey(const Key('hymn-row-hymn-3')), findsOneWidget);
      expect(find.byKey(const Key('hymn-row-hymn-2')), findsNothing);
      await tester.enterText(search, 'zzz');
      await tester.pump();
      expect(find.text('No hymns match "zzz".'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byKey(const Key('hymn-search-empty')),
          matching: find.byKey(const Key('hymn-search-empty-frame')),
        ),
        findsOneWidget,
        reason: 'the list keeps its frame with one sentence in it',
      );
      expect(find.byKey(const Key('hymn-results')), findsNothing);
      await tester.tap(find.byKey(const Key('hymn-search-clear')));
      await tester.pump();
      expect(find.byKey(const Key('hymn-section-0')), findsOneWidget);
      expect(find.byKey(const Key('hymn-search-empty')), findsNothing);
    });

    testWidgets('a book that cannot be read shows an error, never an empty '
        'list, and Try again reads it again', (tester) async {
      final h = await _pumpRoute(
        tester,
        ClientPaths.hymnBook,
        configure: (h) =>
            h.hymnBook.error = const FormatException('broken asset'),
      );
      expect(find.byKey(const Key('hymn-book-error')), findsOneWidget);
      expect(find.byKey(const Key('hymn-section-0')), findsNothing);
      expect(find.byKey(const Key('hymn-search-empty')), findsNothing);
      expect(h.hymnBook.loads, 1);
      h.hymnBook.error = null;
      await tester.tap(find.byKey(const Key('hymn-book-retry')));
      await tester.pumpAndSettle();
      expect(h.hymnBook.loads, 2);
      expect(find.byKey(const Key('hymn-book-error')), findsNothing);
      expect(find.byKey(const Key('hymn-row-hymn-1')), findsOneWidget);
    });

    testWidgets('a hymn shows its number, title, English title, key, numbered '
        'verses and the italic chorus in 19/1.55 text', (tester) async {
      await _pumpRoute(tester, ClientPaths.hymn('hymn-1'));
      expect(find.text('Hymn 1'), findsOneWidget);
      expect(find.text('SYNTHETIC hymn 1'), findsOneWidget);
      expect(find.text('SYNTHETIC ORIGINAL'), findsOneWidget);
      expect(find.text('Key of A flat'), findsOneWidget);
      expect(find.bySemanticsLabel('Verse 1'), findsOneWidget);
      expect(find.byKey(const Key('hymn-verse-2')), findsOneWidget);
      final verse = tester.widget<Text>(
        find.text(
          'SYNTHETIC hymn 1 verse one, line one,\nSYNTHETIC hymn 1 verse one, line two.',
        ),
      );
      expect(verse.style?.fontSize, 19);
      expect(verse.style?.height, 1.55);
      expect(verse.style?.fontStyle, isNot(FontStyle.italic));
      final chorus = tester.widgetList<Text>(
        find.text('SYNTHETIC chorus line one,\nSYNTHETIC chorus line two.'),
      );
      expect(chorus, hasLength(2), reason: 'the chorus follows each verse');
      for (final text in chorus) {
        expect(text.style?.fontStyle, FontStyle.italic);
        expect(text.style?.fontSize, 19);
        expect(text.style?.height, 1.55);
      }
      expect(find.text('Chorus'), findsNWidgets(2));
      final verseLeft = tester
          .getTopLeft(
            find.text(
              'SYNTHETIC hymn 1 verse one, line one,\n'
              'SYNTHETIC hymn 1 verse one, line two.',
            ),
          )
          .dx;
      final chorusLeft = tester
          .getTopLeft(find.byKey(const Key('hymn-chorus-1')))
          .dx;
      expect(chorusLeft - verseLeft, 14, reason: 'handoff: 14 px inside');
    });

    testWidgets('a row is a button that screen readers can open', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _pumpRoute(tester, ClientPaths.hymnBook);
      final row = find.bySemanticsLabel(RegExp(r'^Hymn 2, SYNTHETIC hymn 2\.'));
      expect(
        tester.getSemantics(row),
        containsSemantics(isButton: true, hasTapAction: true),
      );
      tester.semantics.tap(
        find.semantics.byLabel(RegExp(r'^Hymn 2, SYNTHETIC hymn 2\.')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(HymnDetailScreen), findsOneWidget);
      expect(find.text('Hymn 2'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('a three-digit number keeps every digit at twice the text '
        'size', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: churchMobileTheme(Brightness.light),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: HymnRow(hymn: _hymn(HymnKind.hymn, 199, 'SYNTHETIC hymn')),
            ),
          ),
        ),
      );
      expect(find.text('199'), findsOneWidget);
      expect(tester.getSize(find.text('199')).width, greaterThan(40));
      expect(tester.takeException(), isNull);
    });

    testWidgets('back from a hymn opened by its link shows the hymn book', (
      tester,
    ) async {
      await _pumpRoute(tester, ClientPaths.hymn('hymn-2'));
      expect(find.byType(HymnDetailScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(HymnBookView), findsOneWidget);
      expect(find.byType(BibleReaderScreen), findsNothing);
    });

    testWidgets('a single-stanza chorus has no verse number, key or English '
        'title', (tester) async {
      await _pumpRoute(tester, ClientPaths.hymn('chorus-2'));
      expect(find.text('Chorus 2'), findsOneWidget);
      expect(find.text('SYNTHETIC chorus 2'), findsOneWidget);
      expect(find.byKey(const Key('hymn-key')), findsNothing);
      expect(find.byKey(const Key('hymn-original')), findsNothing);
      expect(find.bySemanticsLabel('Verse 1'), findsNothing);
      expect(find.byKey(const Key('hymn-chorus-1')), findsNothing);
    });

    testWidgets('an unknown hymn says so and leads back to the book', (
      tester,
    ) async {
      await _pumpRoute(tester, ClientPaths.hymn('hymn-99'));
      expect(find.byKey(const Key('hymn-missing')), findsOneWidget);
      expect(find.text('Hymn 99'), findsOneWidget);
      await tester.tap(find.byKey(const Key('hymn-missing-book')));
      await tester.pumpAndSettle();
      expect(find.byType(HymnBookView), findsOneWidget);
    });

    testWidgets('a link that is not an item id is not a hymn', (tester) async {
      await _pumpRoute(tester, '/bible/hymns/12');
      expect(find.byKey(const Key('hymn-missing')), findsOneWidget);
      expect(find.text('Hymn'), findsOneWidget);
    });
  });
}
