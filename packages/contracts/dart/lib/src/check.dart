// Wire contract v1 shape checks. Mirrors app.contract_check
// (supabase/migrations/20261003190000_cross_epic_contracts.sql) and the TypeScript mapping;
// all three pass the shared fixtures in packages/contracts/fixtures/v1. No business rules:
// registration membership, IANA zone existence and money scale are server-side checks.

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
final _zone = RegExp(r'^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$');
final _amount = RegExp(r'^-?(0|[1-9][0-9]{0,14})(\.[0-9]{1,6})?$');
final _negativeZero = RegExp(r'^-0(\.0+)?$');
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

String? revisionError(Object? v) {
  if (v == null) return 'required';
  return v is int && v >= 1 && v <= maxRevision ? null : 'invalid';
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

String? _amountError(Object? v) {
  if (v == null) return 'required';
  return v is String && _amount.hasMatch(v) && !_negativeZero.hasMatch(v) ? null : 'invalid';
}

String? _fieldErrorsError(Object? v) {
  if (v == null) return 'required';
  return v is Map && v.values.every((x) => x is String) ? null : 'invalid';
}

Map<String, String> _object(Map<dynamic, dynamic> o, Map<String, _Rule> rules,
    {String root = r'$'}) {
  final errors = <String, String>{};
  rules.forEach((key, rule) {
    final e = rule(o[key]);
    if (e != null) errors[key] = e;
  });
  if (o.keys.any((k) => !rules.containsKey(k))) errors[root] = 'unknown_field';
  return errors;
}

final Map<ContractKind, Map<String, _Rule>> _rules = {
  ContractKind.memberRef: {'member_id': _uuidError},
  ContractKind.accountRef: {'auth_user_id': _uuidError},
  ContractKind.sourceRef: {
    'source_type': _tokenError,
    'source_id': _uuidError,
    'source_revision': revisionError,
  },
  ContractKind.taskSource: {
    'source_type': _tokenError,
    'source_id': _uuidError,
    'purpose': _tokenError,
  },
  ContractKind.notificationKey: {
    'source_type': _tokenError,
    'source_id': _uuidError,
    'source_revision': revisionError,
    'recipient_member_id': _uuidError,
    'reminder_kind': _tokenError,
    'scheduled_at': _instantError,
  },
  ContractKind.lifecycleEvent: {
    'event': _oneOf(lifecycleEventNames),
    'member_id': _uuidError,
    'occurred_at': _instantError,
    'identity_revision': revisionError,
  },
  ContractKind.zonedLocal: {'local': _localError, 'zone': _zoneError},
  ContractKind.money: {'amount': _amountError, 'currency': _currencyError},
};

String? _accept(Object? _) => null;

/// Checks a decoded JSON value (as produced by `jsonDecode`) against wire contract v1.
CheckResult check(ContractKind kind, Object? value) {
  if (kind == ContractKind.instant) {
    final e = _instantError(value);
    return CheckResult(e == null ? const {} : {r'$': e});
  }
  final root = kind == ContractKind.commandRequest ? 'envelope' : r'$';
  if (value is! Map) return CheckResult({root: 'must_be_object'});

  switch (kind) {
    case ContractKind.actor:
      final k = value['kind'];
      if (k == null) return const CheckResult({'kind': 'required'});
      if (k == 'member') {
        return CheckResult(_object(value,
            {'kind': _accept, 'member_id': _uuidError, 'auth_user_id': _uuidError}));
      }
      if (k == 'system') {
        return CheckResult(_object(value, {
          'kind': _accept,
          'system_principal_id': _uuidError,
          'job_id': _uuidError,
          'initiating_member_id': _nullable(_uuidError),
        }));
      }
      return const CheckResult({'kind': 'invalid'});
    case ContractKind.commandRequest:
      return CheckResult(_object(
        value,
        {
          'version': (v) => v == null ? 'required' : (v is int && v == 1 ? null : 'unsupported'),
          'command': _string(_command, maxLength: 127),
          'request_id': _uuidError,
          'expected_revision': _nullable(revisionError),
          'payload': (v) => v is Map ? null : 'must_be_object',
        },
        root: 'envelope',
      ));
    case ContractKind.commandResponse:
      if (value.containsKey('code')) {
        return CheckResult(_object(value, {
          'request_id': (v) =>
              value.containsKey('request_id') ? _nullable(_uuidError)(v) : 'required',
          'code': _oneOf(errorCodeNames),
          'message': (v) => v == null ? 'required' : (v is String ? null : 'invalid'),
          'field_errors': _fieldErrorsError,
          'current_revision': _nullable(revisionError),
        }));
      }
      return CheckResult(_object(value, {
        'request_id': _uuidError,
        'data': (v) => value.containsKey('data') ? null : 'required',
        'revision': revisionError,
      }));
    default:
      return CheckResult(_object(value, _rules[kind]!));
  }
}

/// Throws [ContractViolation] unless [value] satisfies [kind].
void require(ContractKind kind, Object? value) {
  final r = check(kind, value);
  if (!r.valid) throw ContractViolation(kind, r.fieldErrors);
}
