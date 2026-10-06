import 'package:church_client_core/church_client_core.dart';
import 'package:flutter_test/flutter_test.dart';

// Only reserved fictional numbers: NANP +1 202 555 0100-0199 and the Ofcom
// drama range +44 7700 900000-900999. No real or guessed national ranges.
const _uk = DialingCountry('United Kingdom', 'GB', '44');
const _us = DialingCountry('United States', 'US', '1', trunkPrefix: '1');

String? ok(String input, DialingCountry c) =>
    normalizePhoneUsername(input, c).value;
PhoneUsernameProblem? problem(String input, DialingCountry c) =>
    normalizePhoneUsername(input, c).problem;

void main() {
  test('the picker starts at +260 (presentation only)', () {
    expect(defaultDialingCountry.dialCode, '260');
    expect(dialingCountries.first, same(defaultDialingCountry));
    expect(
      dialingCountries.map((c) => c.isoCode).toSet(),
      hasLength(dialingCountries.length),
    );
  });

  test('international input ignores the picker, for any country code', () {
    expect(ok('+1 202 555 0101', defaultDialingCountry), '+12025550101');
    expect(ok('+44 7700 900123', defaultDialingCountry), '+447700900123');
    expect(ok('0044 7700 900123', defaultDialingCountry), '+447700900123');
    expect(ok('+1 (202) 555-0101', _uk), '+12025550101');
  });

  test(
    'national input uses the picked country and drops its trunk prefix once',
    () {
      expect(ok('07700 900123', _uk), '+447700900123');
      expect(ok('7700 900123', _uk), '+447700900123');
      expect(ok('202-555-0101', _us), '+12025550101');
      expect(ok('1 202 555 0101', _us), '+12025550101');
    },
  );

  test('no operator-prefix rules: the same rule for every country', () {
    // Only the trunk prefix is removed; the remaining digits are kept as typed.
    const other = DialingCountry('Example', 'XX', '44');
    expect(ok('07700 900999', other), ok('07700 900999', _uk));
  });

  test('problems', () {
    expect(problem('   ', _uk), PhoneUsernameProblem.empty);
    expect(
      problem('07700 9OO123', _uk),
      PhoneUsernameProblem.invalidCharacters,
    );
    expect(problem('+44 77OO', _uk), PhoneUsernameProblem.invalidCharacters);
    expect(
      problem('+0 7700 900123', _uk),
      PhoneUsernameProblem.invalidCountryCode,
    );
    expect(problem('+1 202', _uk), PhoneUsernameProblem.tooShort);
    expect(
      problem('+1 202 555 0101 0101 01', _uk),
      PhoneUsernameProblem.tooLong,
    );
  });

  DialingCountry picker(String iso) =>
      dialingCountries.firstWhere((c) => c.isoCode == iso);

  test('E.164 length: 7 digits rejected, 8 and 15 accepted, 16 rejected', () {
    expect(problem('+1234567', _uk), PhoneUsernameProblem.tooShort);
    expect(ok('+12345678', _uk), '+12345678');
    expect(ok('+123456789012345', _uk), '+123456789012345');
    expect(problem('+1234567890123456', _uk), PhoneUsernameProblem.tooLong);
  });

  test(
    'a number already starting with the picked calling code is not doubled',
    () {
      // Repro: `260…` with the +260 picker used to become +260260….
      expect(ok('260 100 000 001', defaultDialingCountry), '+260100000001');
      expect(ok('44 7700 900123', picker('GB')), '+447700900123');
      expect(ok('12025550101', picker('US')), '+12025550101');
      // The national form still works for the same countries.
      expect(ok('07700 900123', picker('GB')), '+447700900123');
      expect(ok('202 555 0101', picker('US')), '+12025550101');
      // Only a full national length after the code counts as international.
      expect(ok('44 1234', picker('GB')), '+44441234');
    },
  );

  test('another country\'s number without + keeps the picked code (shown before submit)', () {
    // Repro: `12025550101` with the +260 picker. It cannot be told apart from
    // a national number, so the sign-in screen shows the result first.
    expect(ok('12025550101', defaultDialingCountry), '+26012025550101');
  });
}
