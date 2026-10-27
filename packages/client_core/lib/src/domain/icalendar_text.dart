/// The iCalendar (RFC 5545) text rules the 4.5 duty export established,
/// shared since story 6.11 with the event export: UTC instants, calendar
/// dates, TEXT escaping and 75-octet line folding. The duty export's bytes
/// are unchanged. Free of widgets and SDKs.
library;

import 'dart:convert';

abstract final class ICalendarText {
  /// `20991130` (a calendar date: its own year, month and day).
  static String date(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year.toString().padLeft(4, '0')}${two(d.month)}${two(d.day)}';
  }

  /// `20990104T080000Z`.
  static String utc(DateTime at) {
    final u = at.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${u.year.toString().padLeft(4, '0')}${two(u.month)}${two(u.day)}'
        'T${two(u.hour)}${two(u.minute)}${two(u.second)}Z';
  }

  /// RFC 5545 TEXT escaping; control characters become spaces.
  static String text(String v) => v
      .replaceAll(r'\', r'\\')
      .replaceAll(';', r'\;')
      .replaceAll(',', r'\,')
      .replaceAll(RegExp(r'\r\n|\r|\n'), r'\n')
      .replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f\x7f]'), ' ');

  /// Folds a content line at 75 octets without splitting a UTF-8 character.
  static String fold(String line) {
    final out = StringBuffer();
    var octets = 0;
    var limit = 75;
    for (final rune in line.runes) {
      final ch = String.fromCharCode(rune);
      final n = utf8.encode(ch).length;
      if (octets + n > limit) {
        out.write('\r\n ');
        octets = 0;
        limit = 74; // the leading space of a continuation line counts
      }
      out.write(ch);
      octets += n;
    }
    return out.toString();
  }

  /// The document: every line folded, CRLF line ends, a final CRLF.
  static String document(List<String> lines) =>
      '${lines.map(fold).join('\r\n')}\r\n';
}
