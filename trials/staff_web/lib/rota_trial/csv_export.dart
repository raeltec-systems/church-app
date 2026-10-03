// Disposable Flutter Web trial (Q10): safe CSV core. Do not build on this.
import 'rota_fixture.dart';

/// The only columns an export may contain. Private fields (phone numbers,
/// care notes) are not listed, so they cannot be exported.
const List<String> kCsvColumns = [
  'Date',
  'Position',
  'Member',
  'Status',
  'Note',
];

/// Characters that make a spreadsheet treat a cell as a formula (OWASP CSV
/// injection guidance), checked at the start of the cell.
const String _formulaTriggers = '=+-@\t\r';

/// Prefixes a formula-looking value with `'` so spreadsheets show it as text.
///
/// A value is treated as formula-looking when its first character, or its
/// first character after leading spaces, is a trigger.
String neutraliseCsvCell(String value) {
  if (value.isEmpty) return value;
  final firstNonSpace = value.trimLeft();
  final starts =
      _formulaTriggers.contains(value[0]) ||
      (firstNonSpace.isNotEmpty && _formulaTriggers.contains(firstNonSpace[0]));
  return starts ? "'$value" : value;
}

/// RFC 4180 quoting: every field is quoted, and inner quotes are doubled.
String quoteCsvField(String value) => '"${value.replaceAll('"', '""')}"';

/// Builds the CSV for [slots] using only [kCsvColumns]. The result starts with
/// a UTF-8 byte-order mark (so spreadsheets detect UTF-8) and uses CRLF line
/// endings.
String buildRotaCsv(
  Iterable<RotaSlot> slots,
  Member? Function(String?) memberOf,
) {
  final buffer = StringBuffer('\uFEFF');
  void writeRow(List<String> cells) {
    buffer
      ..write(cells.map((c) => quoteCsvField(neutraliseCsvCell(c))).join(','))
      ..write('\r\n');
  }

  writeRow(kCsvColumns);
  for (final slot in slots) {
    writeRow([
      slot.date.iso,
      slot.position,
      memberOf(slot.memberId)?.displayName ?? '',
      slot.status.label,
      slot.note,
    ]);
  }
  return buffer.toString();
}
