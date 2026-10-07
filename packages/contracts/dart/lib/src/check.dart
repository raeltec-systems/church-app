// Wire contract v1 shape checks. Mirrors app.contract_check
// (supabase/migrations/20261003134340_cross_epic_contracts.sql) and the TypeScript mapping;
// all three pass the shared fixtures in packages/contracts/fixtures/v1. No business rules:
// registration membership, IANA zone existence and money scale are server-side checks.
// Behaves identically on the Dart VM and on the web (integers are checked by value).

const int contractVersion = 1;

/// Largest revision every client runtime represents exactly (2^53 - 1).
const int maxRevision = 9007199254740991;

enum ContractKind {
  memberRef('member_ref'),
  accountRef('account_ref'),
  actor('actor'),
  sourceRef('source_ref'),
  taskSource('task_source'),
  notificationKey('notification_key'),
  lifecycleEvent('lifecycle_event'),
  instant('instant'),
  zonedLocal('zoned_local'),
  money('money'),
  commandRequest('command_request'),
  commandResponse('command_response');

  const ContractKind(this.wireName);
  final String wireName;

  static ContractKind fromWireName(String name) =>
      values.firstWhere((k) => k.wireName == name,
          orElse: () => throw ArgumentError.value(name, 'kind', 'unknown contract kind'));
}

const List<String> lifecycleEventNames = [
  'access_hold_applied',
  'access_hold_released',
  'scope_revoked',
  'account_deactivated',
  'deletion_requested',
  'cell_transferred',
  'sessions_revoked',
  'membership_deactivated',
  'membership_restored',
  'member_deleted',
];

const List<String> errorCodeNames = [
  'validation_failed',
  'unauthenticated',
  'forbidden',
  'not_found',
  'conflict',
  'rate_limited',
  'unavailable',
];

/// Core field error codes of the shape checks (mirrors app.contract_field_error_codes).
///
/// Not exhaustive: in contract v1 a field error code is any lower_snake_case token
/// ([isFieldErrorCode]), and commands return their own specific codes (`last_admin`,
/// `reauthenticate`, `held`, ...). A client maps a code it does not know to a generic field
/// notice; it never rejects the envelope for it.
const List<String> fieldErrorCodeNames = [
  'required',
  'invalid',
  'unknown_field',
  'must_be_object',
  'unsupported',
  'must_be_null',
  'out_of_range',
  'unknown',
  'unregistered',
  'scale_exceeded',
  'gate_closed',
];

/// Same shape as app.contract_check: `valid` plus field path -> error code.
class CheckResult {
  const CheckResult(this.fieldErrors);
  final Map<String, String> fieldErrors;
  bool get valid => fieldErrors.isEmpty;
}

/// Thrown by typed decoders when a wire value breaks the contract.
class ContractViolation implements Exception {
  const ContractViolation(this.kind, this.fieldErrors);
  final ContractKind kind;
  final Map<String, String> fieldErrors;

  @override
  String toString() =>
      'ContractViolation(${kind.wireName} v$contractVersion: $fieldErrors)';
}

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
final _token = RegExp(r'^[a-z][a-z0-9_]{0,62}$');
final _command = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$');
final _instant = RegExp(
    r'^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]{1,6})?Z$');
final _local = RegExp(r'^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})$');
final _zone = RegExp(r'^(UTC|(Africa|America|Antarctica|Arctic|Asia|Atlantic|Australia|Europe'
    r'|Indian|Pacific)(/[A-Za-z][A-Za-z0-9_+-]*){1,2})$');
final _amount = RegExp(r'^(0|[1-9][0-9]{0,14})(\.[0-9]{1,6})?$');
final _currency = RegExp(r'^[A-Z]{3}$');

typedef _Rule = String? Function(Object? value);

_Rule _string(RegExp re, {int maxLength = 1 << 30}) => (v) {
      if (v == null) return 'required';
      return v is String && v.length <= maxLength && re.hasMatch(v) ? null : 'invalid';
    };

_Rule _nullable(_Rule rule) => (v) => v == null ? null : rule(v);

_Rule _oneOf(List<String> values) => (v) {
      if (v == null) return 'required';
      return v is String && values.contains(v) ? null : 'invalid';
    };

final _Rule _uuidError = _string(_uuid);
final _Rule _tokenError = _string(_token);
final _Rule _zoneError = _string(_zone, maxLength: 64);
final _Rule _currencyError = _string(_currency);
final _Rule _amountError = _string(_amount);

/// Integers are defined by value: `1`, `1.0` and `1e0` are the same integer on every
/// platform (the VM decodes `1.0`/`1e3` as doubles, the web as numbers).
bool integerIn(Object? v, num min, num max) {
  if (v is int) return v >= min && v <= max;
  if (v is double) return v.isFinite && v == v.truncateToDouble() && v >= min && v <= max;
  return false;
}

String? _revisionError(Object? v) {
  if (v == null) return 'required';
  return integerIn(v, 1, maxRevision) ? null : 'invalid';
}

bool _calendarOk(RegExpMatch m) {
  final p = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  final y = p[0], mo = p[1], d = p[2];
  final leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
  final dim = mo == 2 ? (leap ? 29 : 28) : (const [4, 6, 9, 11].contains(mo) ? 30 : 31);
  return y >= 1 && mo >= 1 && mo <= 12 && d >= 1 && d <= dim && p[3] <= 23 && p[4] <= 59 && p[5] <= 59;
}

_Rule _dateTime(RegExp re) => (v) {
      if (v == null) return 'required';
      if (v is! String) return 'invalid';
      final m = re.firstMatch(v);
      return m != null && _calendarOk(m) ? null : 'invalid';
    };

final _Rule _instantError = _dateTime(_instant);
final _Rule _localError = _dateTime(_local);

/// Whether [code] is a well-formed v1 field error code: `^[a-z][a-z0-9_]{0,62}$`.
bool isFieldErrorCode(String code) => _token.hasMatch(code);

String? _fieldErrorsError(Object? v) {
  if (v == null) return 'required';
  return v is Map && v.values.every((x) => x is String && isFieldErrorCode(x))
      ? null
      : 'invalid';
}

/// Rule errors per key plus `{"<key>": "unknown_field"}` for every key outside the rules.
Map<String, String> _object(Map<dynamic, dynamic> o, Map<String, _Rule> rules) {
  final errors = <String, String>{};
  rules.forEach((key, rule) {
    final e = rule(o[key]);
    if (e != null) errors[key] = e;
  });
  for (final k in o.keys) {
    if (!rules.containsKey(k)) errors['$k'] = 'unknown_field';
  }
  return errors;
}

String? _accept(Object? _) => null;

final Map<ContractKind, Map<String, _Rule>> _rules = {
  ContractKind.memberRef: {'member_id': _uuidError},
  ContractKind.accountRef: {'auth_user_id': _uuidError},
  ContractKind.sourceRef: {
    'source_type': _tokenError,
    'source_id': _uuidError,
    'source_revision': _revisionError,
  },
  ContractKind.taskSource: {
    'source_type': _tokenError,
    'source_id': _uuidError,
    'purpose': _tokenError,
  },
  ContractKind.notificationKey: {
    'source_type': _tokenError,
    'source_id': _uuidError,
    'source_revision': _revisionError,
    'recipient_member_id': _uuidError,
    'reminder_kind': _tokenError,
    'scheduled_at': _instantError,
  },
  ContractKind.lifecycleEvent: {
    'event': _oneOf(lifecycleEventNames),
    'member_id': _uuidError,
    'occurred_at': _instantError,
    'identity_revision': _revisionError,
  },
  ContractKind.zonedLocal: {'local': _localError, 'zone': _zoneError},
  ContractKind.money: {'amount': _amountError, 'currency': _currencyError},
};

final Map<String, _Rule> _memberActor = {
  'kind': _accept,
  'member_id': _uuidError,
  'auth_user_id': _uuidError,
};
final Map<String, _Rule> _systemActor = {
  'kind': _accept,
  'system_principal_id': _uuidError,
  'job_id': _uuidError,
  'initiating_member_id': _nullable(_uuidError),
};
final Map<String, _Rule> _commandRequest = {
  'version': (v) => v == null ? 'required' : (integerIn(v, 1, 1) ? null : 'unsupported'),
  'command': _string(_command, maxLength: 127),
  'request_id': _uuidError,
  'expected_revision': _nullable(_revisionError),
  'payload': (v) => v is Map ? null : 'must_be_object',
};

/// The key rules for an object value of [kind]; null when the shape cannot be determined.
Map<String, _Rule>? _keyRules(ContractKind kind, Map<dynamic, dynamic> o) {
  switch (kind) {
    case ContractKind.actor:
      final k = o['kind'];
      return k == 'member' ? _memberActor : (k == 'system' ? _systemActor : null);
    case ContractKind.commandRequest:
      return _commandRequest;
    case ContractKind.commandResponse:
      if (o.containsKey('code')) {
        return {
          'request_id': (v) =>
              o.containsKey('request_id') ? _nullable(_uuidError)(v) : 'required',
          'code': _oneOf(errorCodeNames),
          'message': (v) => v == null ? 'required' : (v is String ? null : 'invalid'),
          'field_errors': _fieldErrorsError,
          'current_revision': _nullable(_revisionError),
        };
      }
      return {
        'request_id': _uuidError,
        'data': (v) => o.containsKey('data') ? null : 'required',
        'revision': _revisionError,
      };
    default:
      return _rules[kind];
  }
}

/// Checks a decoded JSON value (as produced by `jsonDecode`) against wire contract v1.
CheckResult check(ContractKind kind, Object? value) {
  if (kind == ContractKind.instant) {
    final e = _instantError(value);
    return CheckResult(e == null ? const {} : {r'$': e});
  }
  if (value is! Map) {
    return CheckResult({kind == ContractKind.commandRequest ? 'envelope' : r'$': 'must_be_object'});
  }
  if (kind == ContractKind.actor) {
    if (value['kind'] == null) return const CheckResult({'kind': 'required'});
    if (_keyRules(kind, value) == null) return const CheckResult({'kind': 'invalid'});
  }
  return CheckResult(_object(value, _keyRules(kind, value)!));
}

/// Throws [ContractViolation] unless [value] satisfies [kind].
void require(ContractKind kind, Object? value) {
  final r = check(kind, value);
  if (!r.valid) throw ContractViolation(kind, r.fieldErrors);
}
