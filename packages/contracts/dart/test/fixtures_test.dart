// Runs every shared v1 fixture through the Dart mapping used by both Flutter clients, on the
// VM (`dart test`) and in a browser (`dart test -p chrome`). Fixtures are embedded verbatim in
// fixtures.g.dart (checked against the files by fixtures_files_test.dart).
import 'dart:convert';

import 'package:church_contracts/church_contracts.dart';
import 'package:test/test.dart';

import 'fixtures.g.dart';

/// Exact deep equality for decoded JSON: same keys (omitted stays omitted, null stays null).
bool jsonEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && jsonEquals(a[k], b[k]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b; // 1000 == 1000.0 is true: integers are compared by value
}

void main() {
  final names = embeddedFixtures.keys.toList()..sort();

  test('fixture set is present', () => expect(names.length, greaterThanOrEqualTo(12)));

  for (final name in names) {
    final fixture = jsonDecode(embeddedFixtures[name]!) as Map<String, Object?>;
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
          expect(jsonEquals(encoded, value), isTrue,
              reason: 'decode -> encode must return the identical wire value, got $encoded');
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

  test('the lifecycle event list equals the valid lifecycle fixtures', () {
    final fixture = jsonDecode(embeddedFixtures['lifecycle_event.json']!) as Map<String, Object?>;
    final events = [
      for (final c in (fixture['valid'] as List).cast<Map<String, Object?>>())
        (c['value'] as Map)['event'] as String,
    ]..sort();
    expect([...lifecycleEventNames]..sort(), events);
  });

  test('unknown kind is a programming error', () {
    expect(() => ContractKind.fromWireName('nope'), throwsArgumentError);
  });

  test('money converts to exact minor units without floating point', () {
    final m = Money.fromJson({'amount': '999999999999999.99', 'currency': 'XTS'});
    expect(m.toMinorUnits(2), BigInt.parse('99999999999999999'));
    expect(Money.fromJson({'amount': '0.3', 'currency': 'XTS'}).toMinorUnits(2), BigInt.from(30));
    expect(() => Money.fromJson({'amount': '1.005', 'currency': 'XTS'}).toMinorUnits(2),
        throwsArgumentError);
  });

  test('instants keep microseconds; DateTime formatting is canonical and range-checked', () {
    expect(Instant.fromJson('2026-10-03T12:34:56.123456Z').wire, '2026-10-03T12:34:56.123456Z');
    expect(Instant.fromDateTime(DateTime.utc(2026, 10, 3, 12, 34, 56, 789)).wire,
        '2026-10-03T12:34:56.789000Z');
    expect(() => Instant.fromDateTime(DateTime.utc(10000)), throwsArgumentError);
    expect(() => Instant.fromDateTime(DateTime.utc(0)), throwsArgumentError);
    expect(check(ContractKind.instant, Instant.fromDateTime(DateTime.utc(9999, 12, 31)).wire).valid,
        isTrue);
  });

  test('omitted and explicit-null optional keys stay distinct', () {
    const create = CommandRequest(
      command: 'fixture_counter.create',
      requestId: '00000000-0000-4000-8000-000000000001',
      payload: {'intent_key': 'synthetic'},
    );
    expect(create.toJson().containsKey('expected_revision'), isFalse);
    const explicitNull = CommandRequest(
      command: 'fixture_counter.create',
      requestId: '00000000-0000-4000-8000-000000000001',
      expectedRevision: Optional.of(null),
    );
    expect(explicitNull.toJson().containsKey('expected_revision'), isTrue);
    expect(explicitNull.toJson()['expected_revision'], isNull);
    expect(check(ContractKind.commandRequest, explicitNull.toJson()).valid, isTrue);
  });

  test('integers are checked by value on every platform', () {
    expect(integerIn(jsonDecode('1e3'), 1, maxRevision), isTrue);
    expect(integerIn(jsonDecode('1.0'), 1, maxRevision), isTrue);
    expect(integerIn(jsonDecode('1.5'), 1, maxRevision), isFalse);
    expect(integerIn(jsonDecode('1e300'), 1, maxRevision), isFalse);
    expect(integerIn(jsonDecode('9007199254740992'), 1, maxRevision), isFalse);
  });

  test('field error codes are an open lower_snake_case vocabulary', () {
    for (final code in fieldErrorCodeNames) {
      expect(isFieldErrorCode(code), isTrue, reason: code);
    }
    for (final code in ['last_admin', 'reauthenticate', 'password_reset_required', 'held']) {
      expect(isFieldErrorCode(code), isTrue, reason: code);
    }
    for (final code in ['', 'Held', 'too-big', '9lives', 'a' * 64]) {
      expect(isFieldErrorCode(code), isFalse, reason: code);
    }
  });

  test('an identity refusal with a command-specific code decodes as its top-level error', () {
    final r = CommandResponse.fromJson({
      'request_id': '00000000-0000-4000-8000-000000000001',
      'code': 'forbidden',
      'message': 'You are not allowed to do this.',
      'field_errors': {'member_id': 'last_admin'},
    });
    expect(r, isA<CommandError>());
    final e = r as CommandError;
    expect(e.code, ErrorCode.forbidden);
    expect(e.message, 'You are not allowed to do this.');
    expect(e.fieldErrors, {'member_id': 'last_admin'});
  });
}
