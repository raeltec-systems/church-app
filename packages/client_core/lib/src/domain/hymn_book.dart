/// Story 6.7: the church's hymn book, built into the app (owner decision
/// 2026-10-27): "Inyimbo zya Bakristo", the Brethren in Christ Church Tonga
/// hymn book.
///
/// One checked-in JSON file in this package
/// (`assets/hymn_book/hymn_book.json`, format 1) holds the book: hymns 1..N,
/// then the choruses (ziindululo) 1..M, each with its section from the
/// book's topical index. It is produced from the printed book by
/// `tools/hymn-book/convert.mjs`, which enforces the same limits as
/// [HymnBook.fromJson]. The server stores no hymn text; later entries refer
/// to an item by its [Hymn.id] (`hymn-12`, `chorus-12`). Free of widgets and
/// Supabase.
library;

import 'dart:convert';

/// The limits the converter also enforces.
abstract final class HymnBookLimits {
  static const maxNumber = 999;
  static const maxTitle = 120;
  static const maxOriginal = 200;
  static const maxReference = 60;
  static const maxVerses = 40;
  static const maxLinesPerBlock = 40;
  static const maxLine = 200;
}

final _keyPattern = RegExp(
  r'^[A-G](?: flat| sharp)?(?: or [A-G](?: flat| sharp)?)?$',
);
final _editionPattern = RegExp(r'^[a-z0-9][a-z0-9.-]{0,63}$');
final _languagePattern = RegExp(r'^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$');

// Control and bidirectional formatting characters (a line break is allowed
// only inside verses and choruses, where it separates lines).
final _forbidden = RegExp(
  r'[\u0000-\u0009\u000b-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]',
);

/// The book's two number sequences.
enum HymnKind {
  hymn('hymn'),
  chorus('chorus');

  const HymnKind(this.wire);
  final String wire;

  static HymnKind? parse(Object? value) {
    for (final kind in values) {
      if (kind.wire == value) return kind;
    }
    return null;
  }
}

/// A chorus as printed: sung after verse [fromVerse] and every later verse
/// until the next chorus (the book prints it once, after verse 1).
class HymnChorus {
  const HymnChorus({required this.fromVerse, required this.text});

  final int fromVerse;

  /// Lines separated by `\n`.
  final String text;
}

/// One item of the book: a hymn or a chorus.
class Hymn {
  const Hymn({
    required this.kind,
    required this.number,
    required this.section,
    required this.title,
    required this.original,
    required this.reference,
    required this.key,
    required this.verses,
    required this.choruses,
  });

  final HymnKind kind;

  /// Its number in its own sequence (hymns and choruses both start at 1).
  final int number;

  /// The book's section (topical index), shown as a group header.
  final String section;

  /// The Tonga title, as printed.
  final String title;

  /// The English original title or tune name printed under the heading.
  final String? original;

  /// The hymnal reference (Z.H. = Zulu Hymnal, M.H. = Methodist Hymn Book).
  final String? reference;

  /// The key in words ("F", "A flat", "A flat or D"), or null.
  final String? key;

  /// The verses in order; lines are separated by `\n`.
  final List<String> verses;

  /// The choruses as printed, by the verse they first follow.
  final List<HymnChorus> choruses;

  /// The stable reference later features use: `hymn-12`, `chorus-12`.
  String get id => '${kind.wire}-$number';

  /// Verse 1's first line, the item's first line in the book's index.
  String get firstLine => hymnFirstLine(verses.first);

  /// The chorus sung after verse [verseNumber] (1-based), or null.
  String? chorusAfterVerse(int verseNumber) {
    String? chorus;
    for (final c in choruses) {
      if (c.fromVerse <= verseNumber) chorus = c.text;
    }
    return chorus;
  }
}

/// A verse's first line without a trailing comma, semicolon or colon.
String hymnFirstLine(String verse) =>
    verse.split('\n').first.replaceFirst(RegExp(r'[\s,;:]+$'), '');

/// The built-in hymn book: hymns 1..N, then choruses 1..M.
class HymnBook {
  HymnBook({
    required this.format,
    required this.edition,
    required this.title,
    required this.language,
    required List<Hymn> items,
  }) : items = List.unmodifiable(items),
       hymns = List.unmodifiable(items.where((i) => i.kind == HymnKind.hymn)),
       choruses = List.unmodifiable(
         items.where((i) => i.kind == HymnKind.chorus),
       );

  /// The strict reader: any unexpected field, gap, repeat, empty verse or
  /// limit breach throws a [FormatException] (the app then says the book
  /// could not be opened rather than showing part of it).
  factory HymnBook.fromJson(Object? json) {
    final m = _object(json, 'the hymn book', const {
      'format',
      'edition',
      'title',
      'language',
      'items',
    });
    final format = m['format'];
    if (format is! int || format != 1) {
      throw const FormatException('unsupported hymn book format');
    }
    final edition = m['edition'];
    if (edition is! String || !_editionPattern.hasMatch(edition)) {
      throw const FormatException('invalid hymn book edition');
    }
    final language = m['language'];
    if (language is! String || !_languagePattern.hasMatch(language)) {
      throw const FormatException('invalid hymn book language');
    }
    final rows = m['items'];
    if (rows is! List || rows.isEmpty) {
      throw const FormatException('the hymn book has no hymns');
    }
    final items = <Hymn>[];
    var kind = HymnKind.hymn;
    var expected = 1;
    for (final row in rows) {
      final item = _item(row);
      if (item.kind == HymnKind.chorus && kind == HymnKind.hymn) {
        if (expected == 1) {
          throw const FormatException('the book starts with a chorus');
        }
        kind = HymnKind.chorus;
        expected = 1;
      }
      if (item.kind != kind || item.number != expected) {
        throw FormatException(
          '${item.id} found where ${kind.wire} $expected belongs',
        );
      }
      expected++;
      items.add(item);
    }
    return HymnBook(
      format: format,
      edition: edition,
      title: _line(m['title'], 'the hymn book title', HymnBookLimits.maxTitle),
      language: language,
      items: items,
    );
  }

  final int format;

  /// Which conversion of the printed book this is (`bicc-tonga-2012`); a
  /// corrected book ships with a new edition.
  final String edition;
  final String title;

  /// The text's language tag (`toi`, Tonga).
  final String language;

  /// Hymns 1..N, then choruses 1..M: the printed book's order.
  final List<Hymn> items;
  final List<Hymn> hymns;
  final List<Hymn> choruses;

  late final List<String> _searchText = [
    for (final item in items)
      foldHymnText('${item.title} ${item.firstLine} ${item.original ?? ''}'),
  ];

  /// The item with this id (`hymn-12`, `chorus-3`), or null.
  Hymn? byId(String id) {
    final match = RegExp(r'^(hymn|chorus)-([1-9][0-9]{0,2})$').firstMatch(id);
    if (match == null) return null;
    final number = int.parse(match.group(2)!);
    final list = match.group(1) == 'hymn' ? hymns : choruses;
    return number <= list.length ? list[number - 1] : null;
  }

  /// On-device search by number, title, first line and English title. Case,
  /// punctuation, apostrophes, quotation marks and diacritics are ignored
  /// (`nganda` finds `ng'anda` and `ŋanda`); every word must match; a word
  /// of digits also matches a number that starts with it. Items whose number
  /// equals a word come first, the hymn before the chorus, then the rest in
  /// the book's order. A blank query lists the whole book.
  List<Hymn> search(String query) {
    final tokens = hymnQueryTokens(query);
    if (tokens.isEmpty) return items;
    final exact = <Hymn>[];
    final others = <Hymn>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final number = '${item.number}';
      var matches = true;
      var exactNumber = false;
      for (final token in tokens) {
        if (_digits.hasMatch(token) && number.startsWith(token)) {
          if (number == token) exactNumber = true;
          continue;
        }
        if (_searchText[i].contains(token)) continue;
        matches = false;
        break;
      }
      if (matches) (exactNumber ? exact : others).add(item);
    }
    return [...exact, ...others];
  }
}

/// Parses the book file's text (top level, so it can run in an isolate).
HymnBook parseHymnBookJson(String text) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw const FormatException('the hymn book is not valid JSON');
  }
  return HymnBook.fromJson(decoded);
}

/// Reads the built-in book. Implementations throw when it cannot be read.
abstract interface class HymnBookSource {
  Future<HymnBook> load();
}

final _digits = RegExp(r'^[0-9]+$');

/// The words of a search: the folded first 100 characters, at most 8 words.
List<String> hymnQueryTokens(String query) {
  final head = query.length > 100 ? query.substring(0, 100) : query;
  return foldHymnText(head)
      .split(' ')
      .where((word) => word.isNotEmpty)
      .take(8)
      .toList();
}

/// Search folding: lower case; apostrophes, quotation marks and combining
/// marks dropped (`ng'anda`, `ng’anda` and `ng‟anda` become `nganda`);
/// accented Latin letters as plain ones, `ŋ` as `ng`; every other character
/// outside a-z and 0-9 a single space.
String foldHymnText(String input) {
  final out = StringBuffer();
  var pendingSpace = false;
  for (final rune in input.toLowerCase().runes) {
    if (_dropped.contains(rune) || (rune >= 0x300 && rune <= 0x36f)) {
      continue;
    }
    final String? piece;
    if ((rune >= 0x61 && rune <= 0x7a) || (rune >= 0x30 && rune <= 0x39)) {
      piece = String.fromCharCode(rune);
    } else {
      piece = _letterFolds[rune];
    }
    if (piece == null) {
      pendingSpace = out.isNotEmpty;
      continue;
    }
    if (pendingSpace) out.write(' ');
    pendingSpace = false;
    out.write(piece);
  }
  return out.toString();
}

/// Apostrophes and quotation marks: dropped, so a word keeps together.
const _dropped = {
  0x22, // "
  0x27, // '
  0x60, // `
  0xab, // left-pointing double angle quotation mark
  0xb4, // acute accent
  0xbb, // right-pointing double angle quotation mark
  0x2b9, // modifier letter prime
  0x2bb, // modifier letter turned comma
  0x2bc, // modifier letter apostrophe
  0x2bd, // modifier letter reversed comma
  0x2018, // left single quotation mark
  0x2019, // right single quotation mark
  0x201a, // single low-9 quotation mark
  0x201b, // single high-reversed-9 quotation mark
  0x201c, // left double quotation mark
  0x201d, // right double quotation mark
  0x201e, // double low-9 quotation mark
  0x201f, // double high-reversed-9 quotation mark
  0x2032, // prime
  0x2033, // double prime
};

const _foldGroups = <String, List<int>>{
  'a': [0xe0, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5, 0x101, 0x103, 0x105],
  'ae': [0xe6],
  'c': [0xe7, 0x107, 0x109, 0x10b, 0x10d],
  'd': [0xf0, 0x10f, 0x111],
  'e': [0xe8, 0xe9, 0xea, 0xeb, 0x113, 0x115, 0x117, 0x119, 0x11b],
  'g': [0x11d, 0x11f, 0x121, 0x123],
  'h': [0x125, 0x127],
  'i': [0xec, 0xed, 0xee, 0xef, 0x129, 0x12b, 0x12d, 0x12f, 0x131],
  'ij': [0x133],
  'j': [0x135],
  'k': [0x137, 0x138],
  'l': [0x13a, 0x13c, 0x13e, 0x140, 0x142],
  'n': [0xf1, 0x144, 0x146, 0x148, 0x149],
  'ng': [0x14b],
  'o': [0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf8, 0x14d, 0x14f, 0x151],
  'oe': [0x153],
  'r': [0x155, 0x157, 0x159],
  's': [0x15b, 0x15d, 0x15f, 0x161, 0x17f],
  'ss': [0xdf],
  't': [0x163, 0x165, 0x167],
  'th': [0xfe],
  'u': [0xf9, 0xfa, 0xfb, 0xfc, 0x169, 0x16b, 0x16d, 0x16f, 0x171, 0x173],
  'w': [0x175],
  'y': [0xfd, 0xff, 0x177],
  'z': [0x17a, 0x17c, 0x17e],
};

final Map<int, String> _letterFolds = {
  for (final group in _foldGroups.entries)
    for (final rune in group.value) rune: group.key,
};

Map<String, Object?> _object(Object? json, String what, Set<String> keys) {
  if (json is! Map) throw FormatException('$what is not an object');
  final actual = json.keys.toSet();
  if (actual.length != keys.length || !keys.every(actual.contains)) {
    throw FormatException('$what has unexpected fields');
  }
  return {for (final key in keys) key: json[key]};
}

String _line(Object? value, String what, int max) {
  if (value is! String ||
      value.trim() != value ||
      value.isEmpty ||
      value.length > max ||
      value.contains('\n') ||
      _forbidden.hasMatch(value)) {
    throw FormatException('invalid $what');
  }
  return value;
}

String? _optionalLine(Object? value, String what, int max) =>
    value == null ? null : _line(value, what, max);

String _block(Object? value, String what) {
  if (value is! String || value.isEmpty || _forbidden.hasMatch(value)) {
    throw FormatException('invalid $what');
  }
  final lines = value.split('\n');
  if (lines.length > HymnBookLimits.maxLinesPerBlock) {
    throw FormatException('$what has too many lines');
  }
  for (final line in lines) {
    if (line.isEmpty || line.trim() != line) {
      throw FormatException('$what has a blank or untrimmed line');
    }
    if (line.length > HymnBookLimits.maxLine) {
      throw FormatException('$what has a line that is too long');
    }
  }
  return value;
}

Hymn _item(Object? json) {
  final m = _object(json, 'an item', const {
    'id',
    'kind',
    'number',
    'section',
    'title',
    'original',
    'reference',
    'key',
    'verses',
    'choruses',
  });
  final kind = HymnKind.parse(m['kind']);
  if (kind == null) throw const FormatException('invalid item kind');
  final number = m['number'];
  if (number is! int || number < 1 || number > HymnBookLimits.maxNumber) {
    throw const FormatException('invalid item number');
  }
  final where = '${kind.wire} $number';
  if (m['id'] != '${kind.wire}-$number') {
    throw FormatException('the id of $where does not match it');
  }
  final key = m['key'];
  if (key != null && (key is! String || !_keyPattern.hasMatch(key))) {
    throw FormatException('invalid key of $where');
  }
  final verses = m['verses'];
  if (verses is! List ||
      verses.isEmpty ||
      verses.length > HymnBookLimits.maxVerses) {
    throw FormatException(
      '$where needs 1 to ${HymnBookLimits.maxVerses} verses',
    );
  }
  final rawChoruses = m['choruses'];
  if (rawChoruses is! List) throw FormatException('invalid choruses of $where');
  final choruses = <HymnChorus>[];
  for (final raw in rawChoruses) {
    final c = _object(raw, 'a chorus of $where', const {'from_verse', 'text'});
    final from = c['from_verse'];
    final previous = choruses.isEmpty ? 0 : choruses.last.fromVerse;
    if (from is! int || from <= previous || from > verses.length) {
      throw FormatException('invalid chorus position in $where');
    }
    choruses.add(
      HymnChorus(fromVerse: from, text: _block(c['text'], 'chorus of $where')),
    );
  }
  return Hymn(
    kind: kind,
    number: number,
    section: _line(m['section'], 'section of $where', HymnBookLimits.maxTitle),
    title: _line(m['title'], 'title of $where', HymnBookLimits.maxTitle),
    original: _optionalLine(
      m['original'],
      'original of $where',
      HymnBookLimits.maxOriginal,
    ),
    reference: _optionalLine(
      m['reference'],
      'reference of $where',
      HymnBookLimits.maxReference,
    ),
    key: key as String?,
    verses: List.unmodifiable([
      for (final (index, verse) in verses.indexed)
        _block(verse, 'verse ${index + 1} of $where'),
    ]),
    choruses: List.unmodifiable(choruses),
  );
}
