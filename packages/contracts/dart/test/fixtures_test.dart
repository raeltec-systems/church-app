// Runs every shared v1 fixture through the Dart mapping used by both Flutter clients.
import 'dart:convert';
import 'dart:io';

import 'package:church_contracts/church_contracts.dart';
import 'package:test/test.dart';

const _deep = DeepCollectionEquality();

/// Top-level null entries carry no information on the wire (optional or nullable keys).
Object? _dropTopLevelNulls(Object? v) =>
    v is Map ? {for (final e in v.entries) if (e.value != null) e.key: e.value} : v;

void main() {
  final files = Directory('../fixtures/v1')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('fixture set is present', () => expect(files.length, greaterThanOrEqualTo(12)));

  for (final file in files) {
    final fixture = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final kind = ContractKind.fromWireName(fixture['kind'] as String);

    group(kind.wireName, () {
      test('declares contract version $contractVersion',
          () => expect(fixture['contract_version'], contractVersion));
      for (final c in (fixture['valid'] as List).cast<Map<String, Object?>>()) {
        test('valid: ${c['name']}', () {
          final value = c['value'];
          final result = check(kind, value);
          expect(result.fieldErrors, isEmpty);
          expect(result.valid, isTrue);
          final encoded = encode(decode(kind, value));
          expect(check(kind, encoded).valid, isTrue, reason: 'encoded form stays valid');
          expect(_deep.equals(_dropTopLevelNulls(encoded), _dropTopLevelNulls(value)), isTrue,
              reason: 'decode -> encode keeps the wire value: $encoded');
        });
      }
      for (final c in (fixture['invalid'] as List).cast<Map<String, Object?>>()) {
        test('invalid: ${c['name']}', () {
          final result = check(kind, c['value']);
          expect(result.valid, isFalse);
          expect(result.fieldErrors, equals(c['field_errors']));
          expect(() => decode(kind, c['value']), throwsA(isA<ContractViolation>()));
        });
      }
    });
  }

  test('unknown kind is a programming error', () {
    expect(() => ContractKind.fromWireName('nope'), throwsArgumentError);
  });

  test('money converts to exact minor units without floating point', () {
    final m = Money.fromJson({'amount': '-999999999999999.99', 'currency': 'XTS'});
    expect(m.toMinorUnits(2), BigInt.parse('-99999999999999999'));
    expect(Money.fromJson({'amount': '0.3', 'currency': 'XTS'}).toMinorUnits(2), BigInt.from(30));
    expect(() => Money.fromJson({'amount': '1.005', 'currency': 'XTS'}).toMinorUnits(2),
        throwsArgumentError);
  });

  test('instants keep microseconds and format from DateTime in canonical UTC form', () {
    expect(Instant.fromJson('2026-10-03T12:34:56.123456Z').wire, '2026-10-03T12:34:56.123456Z');
    expect(Instant.fromDateTime(DateTime.utc(2026, 10, 3, 12, 34, 56, 789, 1)).wire,
        '2026-10-03T12:34:56.789001Z');
  });

  test('a create command encodes a null expected_revision and version 1', () {
    const request = CommandRequest(
      command: 'fixture_counter.create',
      requestId: '00000000-0000-4000-8000-000000000001',
      payload: {'intent_key': 'synthetic'},
    );
    expect(check(ContractKind.commandRequest, request.toJson()).valid, isTrue);
    expect(request.toJson()['version'], 1);
    expect(request.toJson().containsKey('expected_revision'), isTrue);
  });
}

/// Minimal deep equality for decoded JSON (avoids a package:collection dependency).
class DeepCollectionEquality {
  const DeepCollectionEquality();
  bool equals(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return a.length == b.length &&
          a.keys.every((k) => b.containsKey(k) && equals(a[k], b[k]));
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!equals(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }
}
