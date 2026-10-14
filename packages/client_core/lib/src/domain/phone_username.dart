/// Phone usernames (AD-20): an unverified sign-in identifier, normalized to
/// international E.164 form. Free of widgets and SDKs.
///
/// Any country code is accepted. The country picker only supplies the country
/// code for a number typed in national form; +260 is its initial value, not an
/// assumption about where a member lives. No rule here depends on a country's
/// operator prefixes. National-form rules: a number that already starts with
/// the picked country's calling code followed by a national number of that
/// country's length is taken as international (so the code is never added
/// twice); otherwise the country's trunk prefix is removed once (for example
/// the leading 0 of `07700 900123` in the UK) and the calling code is added.
/// E.164: 8 to 15 digits after the `+`.
library;

/// One entry of the country picker.
class DialingCountry {
  const DialingCountry(
    this.name,
    this.isoCode,
    this.dialCode, {
    this.trunkPrefix = '0',
    this.nationalLengths = const {},
  });

  final String name;

  /// ISO 3166-1 alpha-2 code.
  final String isoCode;

  /// Country calling code digits, without '+'.
  final String dialCode;

  /// The national trunk prefix dropped when a number is typed in national
  /// form; empty when the country has none (it is then part of the number).
  final String trunkPrefix;

  /// Lengths of the country's national significant numbers. Used only to
  /// recognise a number typed with the calling code but without `+`; empty
  /// when not curated (such input is then shown back before submit).
  final Set<int> nationalLengths;

  String get label => '$name (+$dialCode)';
}

/// The picker's initial country (design contract: +260 is only the initial
/// presentation).
const defaultDialingCountry = DialingCountry(
  'Zambia',
  'ZM',
  '260',
  nationalLengths: {9},
);

/// Countries offered by the picker. Any other country code can be typed in
/// international form (starting with + or 00) in the phone field.
const dialingCountries = <DialingCountry>[
  defaultDialingCountry,
  DialingCountry('Angola', 'AO', '244', trunkPrefix: '', nationalLengths: {9}),
  DialingCountry('Australia', 'AU', '61', nationalLengths: {9}),
  DialingCountry(
    'Botswana',
    'BW',
    '267',
    trunkPrefix: '',
    nationalLengths: {7, 8},
  ),
  DialingCountry('Canada', 'CA', '1', trunkPrefix: '1', nationalLengths: {10}),
  DialingCountry('Congo (DRC)', 'CD', '243', nationalLengths: {9}),
  DialingCountry('Germany', 'DE', '49'),
  DialingCountry('Ghana', 'GH', '233', nationalLengths: {9}),
  DialingCountry('India', 'IN', '91', nationalLengths: {10}),
  DialingCountry('Ireland', 'IE', '353'),
  DialingCountry('Kenya', 'KE', '254', nationalLengths: {9}),
  DialingCountry('Malawi', 'MW', '265', nationalLengths: {7, 9}),
  DialingCountry(
    'Mozambique',
    'MZ',
    '258',
    trunkPrefix: '',
    nationalLengths: {8, 9},
  ),
  DialingCountry('Namibia', 'NA', '264', nationalLengths: {8, 9}),
  DialingCountry('Nigeria', 'NG', '234', nationalLengths: {8, 10}),
  DialingCountry('South Africa', 'ZA', '27', nationalLengths: {9}),
  DialingCountry('Tanzania', 'TZ', '255', nationalLengths: {9}),
  DialingCountry('Uganda', 'UG', '256', nationalLengths: {9}),
  DialingCountry('United Arab Emirates', 'AE', '971', nationalLengths: {8, 9}),
  DialingCountry('United Kingdom', 'GB', '44', nationalLengths: {9, 10}),
  DialingCountry(
    'United States',
    'US',
    '1',
    trunkPrefix: '1',
    nationalLengths: {10},
  ),
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

  /// `+<country code><number>`, 8 to 15 digits (E.164).
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
    if (s.startsWith(country.dialCode) &&
        country.nationalLengths.contains(s.length - country.dialCode.length)) {
      // Already international without the '+': do not add the code twice.
      digits = s;
    } else {
      if (country.trunkPrefix.isNotEmpty && s.startsWith(country.trunkPrefix)) {
        s = s.substring(country.trunkPrefix.length);
      }
      digits = '${country.dialCode}$s';
    }
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
  if (digits.length < 8) {
    return const PhoneUsernameResult.problem(PhoneUsernameProblem.tooShort);
  }
  if (digits.length > 15) {
    return const PhoneUsernameResult.problem(PhoneUsernameProblem.tooLong);
  }
  return PhoneUsernameResult.ok('+$digits');
}
