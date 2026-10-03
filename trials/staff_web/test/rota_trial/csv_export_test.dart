import 'package:flutter_test/flutter_test.dart';
import 'package:staff_web_trial/rota_trial/csv_export.dart';
import 'package:staff_web_trial/rota_trial/rota_fixture.dart';

void main() {
  group('neutraliseCsvCell', () {
    for (final trigger in [
      '=1+2',
      '+Plus',
      '-Minus',
      '@SUM(A1)',
      '\tTab',
      '\rCR',
    ]) {
      test(
        'prefixes ${trigger.codeUnitAt(0)}-led value with an apostrophe',
        () {
          expect(neutraliseCsvCell(trigger), "'$trigger");
        },
      );
    }

    test('prefixes a trigger hidden behind leading spaces', () {
      expect(neutraliseCsvCell('  =cmd'), "'  =cmd");
    });

    test('leaves plain text and empty values unchanged', () {
      expect(neutraliseCsvCell('Test Ruth D'), 'Test Ruth D');
      expect(neutraliseCsvCell('a=b'), 'a=b');
      expect(neutraliseCsvCell(''), '');
    });
  });

  test(
    'quoteCsvField doubles inner quotes and keeps commas/newlines inside',
    () {
      expect(quoteCsvField('a "b", c\nd'), '"a ""b"", c\nd"');
    },
  );

  group('buildRotaCsv', () {
    final fixture = RotaFixture.synthetic();
    final slots = [for (final row in fixture.slots) ...row];
    final csv = buildRotaCsv(slots, fixture.memberById);

    test('starts with a BOM, uses CRLF and the allowlisted header', () {
      expect(
        csv.startsWith('\uFEFF"Date","Position","Member","Status","Note"\r\n'),
        isTrue,
      );
      expect(csv.endsWith('\r\n'), isTrue);
    });

    test('has one row per slot', () {
      // Notes may contain quoted newlines, so count CRLF row terminators.
      expect('\r\n'.allMatches(csv).length, slots.length + 1);
    });

    test('never contains private fields', () {
      for (final m in fixture.members) {
        expect(csv, isNot(contains(m.privatePhone)));
      }
      expect(csv, isNot(contains('private care note')));
    });

    test('neutralises every formula-led synthetic name and note', () {
      expect(
        csv,
        contains('"\'=HYPERLINK(""https://example.invalid"",""Injected"")"'),
      );
      expect(csv, contains('"\'+Test Plus G"'));
      expect(csv, contains('"\'-Test Minus H"'));
      expect(csv, contains('"\'@Test At I"'));
      expect(csv, contains('"\'=1+2"'));
      expect(csv, contains('"\'\tTab-led note"'));
      // No field opens with a raw trigger.
      expect(
        RegExp(r'(^|,)"[=+\-@\t\r]', multiLine: true).hasMatch(csv),
        isFalse,
      );
    });

    test('unassigned slots export an empty member', () {
      final unfilled = slots.firstWhere((s) => s.status == SlotStatus.unfilled);
      final one = buildRotaCsv([unfilled], fixture.memberById);
      expect(one, contains(',"","Unfilled",'));
    });
  });
}
