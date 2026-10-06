/// Phone usernames (AD-20): an unverified sign-in identifier, normalized to
/// international E.164 form. Free of widgets and SDKs.
///
/// Any country code is accepted. The country picker only supplies the country
/// code for a number typed in national form; +260 is its initial value, not an
/// assumption about where a member lives. No rule here depends on a country's
/// operator prefixes: the only national-form rule is removing the country's
/// trunk prefix (for example the leading 0 of `07700 900123` in the UK).
library;

/// One entry of the country picker.
class DialingCountry {
  const DialingCountry(
    this.name,
    this.isoCode,
    this.dialCode, {
    this.trunkPrefix = '0',
  });

  final String name;

  /// ISO 3166-1 alpha-2 code.
  final String isoCode;

  /// Country calling code digits, without '+'.
  final String dialCode;

  /// The national trunk prefix dropped when a number is typed in national
  /// form; empty when the country has none (it is then part of the number).
  final String trunkPrefix;

  String get label => '$name (+$dialCode)';
}

/// The picker's initial country (design contract: +260 is only the initial
/// presentation).
const defaultDialingCountry = DialingCountry('Zambia', 'ZM', '260');

/// Countries offered by the picker. Any other country code can be typed in
/// international form (starting with + or 00) in the phone field.
const dialingCountries = <DialingCountry>[
  defaultDialingCountry,
  DialingCountry('Angola', 'AO', '244', trunkPrefix: ''),
  DialingCountry('Australia', 'AU', '61'),
  DialingCountry('Botswana', 'BW', '267', trunkPrefix: ''),
  DialingCountry('Canada', 'CA', '1', trunkPrefix: '1'),
  DialingCountry('Congo (DRC)', 'CD', '243'),
  DialingCountry('Germany', 'DE', '49'),
  DialingCountry('Ghana', 'GH', '233'),
  DialingCountry('India', 'IN', '91'),
  DialingCountry('Ireland', 'IE', '353'),
  DialingCountry('Kenya', 'KE', '254'),
  DialingCountry('Malawi', 'MW', '265'),
  DialingCountry('Mozambique', 'MZ', '258', trunkPrefix: ''),
  DialingCountry('Namibia', 'NA', '264'),
  DialingCountry('Nigeria', 'NG', '234'),
  DialingCountry('South Africa', 'ZA', '27'),
  DialingCountry('Tanzania', 'TZ', '255'),
  DialingCountry('Uganda', 'UG', '256'),
  DialingCountry('United Arab Emirates', 'AE', '971'),
  DialingCountry('United Kingdom', 'GB', '44'),
  DialingCountry('United States', 'US', '1', trunkPrefix: '1'),
  DialingCountry('Zimbabwe', 'ZW', '263'),
];

/// Why a typed number cannot be used.
enum PhoneUsernameProblem {
  empty,
  invalidCharacters,
  tooShort,
  tooLong,
  invalidCountryCode,
}

/// Result of [normalizePhoneUsername]: exactly one of [value] or [problem].
class PhoneUsernameResult {
  const PhoneUsernameResult.ok(String this.value) : problem = null;
  const PhoneUsernameResult.problem(PhoneUsernameProblem this.problem)
    : value = null;

  /// `+<country code><number>`, 7 to 15 digits (E.164).
  final String? value;
  final PhoneUsernameProblem? problem;
}

final _separators = RegExp(r'[\s\-.()/ ]');
final _digits = RegExp(r'^[0-9]+$');

/// Normalizes [input] to E.164. A number starting with `+` or `00` is taken
/// as international and [country] is ignored; otherwise [country]'s calling
/// code is prefixed after removing its trunk prefix once.
PhoneUsernameResult normalizePhoneUsername(
  String input,
  DialingCountry country,
) {
  var s = input.trim().replaceAll(_separators, '');
  if (s.isEmpty) {
    return const PhoneUsernameResult.problem(PhoneUsernameProblem.empty);
  }
  String digits;
  if (s.startsWith('+')) {
    digits = s.substring(1);
  } else if (s.startsWith('00')) {
    digits = s.substring(2);
  } else {
    if (!_digits.hasMatch(s)) {
      return const PhoneUsernameResult.problem(
        PhoneUsernameProblem.invalidCharacters,
      );
    }
    if (country.trunkPrefix.isNotEmpty && s.startsWith(country.trunkPrefix)) {
      s = s.substring(country.trunkPrefix.length);
    }
    digits = '${country.dialCode}$s';
  }
  if (digits.isEmpty || !_digits.hasMatch(digits)) {
    return const PhoneUsernameResult.problem(
      PhoneUsernameProblem.invalidCharacters,
    );
  }
  if (digits.startsWith('0')) {
    return const PhoneUsernameResult.problem(
      PhoneUsernameProblem.invalidCountryCode,
    );
  }
  if (digits.length < 7) {
    return const PhoneUsernameResult.problem(PhoneUsernameProblem.tooShort);
  }
  if (digits.length > 15) {
    return const PhoneUsernameResult.problem(PhoneUsernameProblem.tooLong);
  }
  return PhoneUsernameResult.ok('+$digits');
}
