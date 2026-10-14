// Typed wire contract v1 values. Each `fromJson` validates with [check] first and throws
// [ContractViolation]; each `toJson` writes the wire form. Types only — no business rules.
import 'check.dart';

Map<String, Object?> _map(ContractKind kind, Object? json) {
  require(kind, json);
  return (json as Map).cast<String, Object?>();
}

/// A validated integral JSON number (the VM may decode `1e3` or `1.0` as a double).
int _int(Object? v) => (v as num).toInt();
int? _intOrNull(Object? v) => v == null ? null : _int(v);

/// An optional wire key: absent, or present with a value that may itself be null. Keeps an
/// omitted key distinct from an explicit null through decode -> encode.
class Optional<T> {
  const Optional.absent()
      : present = false,
        value = null;
  const Optional.of(this.value) : present = true;
  final bool present;
  final T? value;

  static Optional<T> fromKey<T>(Map<String, Object?> m, String key, T? Function(Object?) read) =>
      m.containsKey(key) ? Optional.of(read(m[key])) : Optional<T>.absent();
}

/// UTC instant kept in its exact wire form (microseconds survive on every platform).
class Instant {
  Instant.fromJson(Object? json) : wire = _instant(json);
  Instant.fromDateTime(DateTime at) : wire = _format(at.toUtc());

  final String wire;

  static String _instant(Object? json) {
    require(ContractKind.instant, json);
    return json as String;
  }

  static String _format(DateTime t) {
    if (t.year < 1 || t.year > 9999) {
      throw ArgumentError.value(t, 'at', 'year must be 0001..9999 for the wire contract');
    }
    String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    return '${p(t.year, 4)}-${p(t.month)}-${p(t.day)}T${p(t.hour)}:${p(t.minute)}:${p(t.second)}'
        '.${p(t.millisecond * 1000 + t.microsecond, 6)}Z';
  }

  /// Platform DateTime (web keeps millisecond precision only).
  DateTime toDateTime() => DateTime.parse(wire);

  String toJson() => wire;

  @override
  bool operator ==(Object other) => other is Instant && other.wire == wire;
  @override
  int get hashCode => wire.hashCode;
}

class MemberRef {
  const MemberRef(this.memberId);
  factory MemberRef.fromJson(Object? json) =>
      MemberRef(_map(ContractKind.memberRef, json)['member_id'] as String);
  final String memberId;
  Map<String, Object?> toJson() => {'member_id': memberId};
}

class AccountRef {
  const AccountRef(this.authUserId);
  factory AccountRef.fromJson(Object? json) =>
      AccountRef(_map(ContractKind.accountRef, json)['auth_user_id'] as String);
  final String authUserId;
  Map<String, Object?> toJson() => {'auth_user_id': authUserId};
}

/// Attribution of who acted. Resolved server-side; clients never send an actor.
sealed class Actor {
  const Actor();
  factory Actor.fromJson(Object? json) {
    final m = _map(ContractKind.actor, json);
    return m['kind'] == 'member'
        ? MemberActor(memberId: m['member_id'] as String, authUserId: m['auth_user_id'] as String)
        : SystemActor(
            systemPrincipalId: m['system_principal_id'] as String,
            jobId: m['job_id'] as String,
            initiatingMemberId:
                Optional.fromKey<String>(m, 'initiating_member_id', (v) => v as String?),
          );
  }
  Map<String, Object?> toJson();
}

class MemberActor extends Actor {
  const MemberActor({required this.memberId, required this.authUserId});
  final String memberId;
  final String authUserId;
  @override
  Map<String, Object?> toJson() =>
      {'kind': 'member', 'member_id': memberId, 'auth_user_id': authUserId};
}

class SystemActor extends Actor {
  const SystemActor({
    required this.systemPrincipalId,
    required this.jobId,
    this.initiatingMemberId = const Optional.absent(),
  });
  final String systemPrincipalId;
  final String jobId;

  /// The human who started the job, recorded separately from the system executor.
  final Optional<String> initiatingMemberId;
  @override
  Map<String, Object?> toJson() => {
        'kind': 'system',
        'system_principal_id': systemPrincipalId,
        'job_id': jobId,
        if (initiatingMemberId.present) 'initiating_member_id': initiatingMemberId.value,
      };
}

class SourceRef {
  const SourceRef({required this.sourceType, required this.sourceId, required this.sourceRevision});
  factory SourceRef.fromJson(Object? json) {
    final m = _map(ContractKind.sourceRef, json);
    return SourceRef(
      sourceType: m['source_type'] as String,
      sourceId: m['source_id'] as String,
      sourceRevision: _int(m['source_revision']),
    );
  }
  final String sourceType;
  final String sourceId;
  final int sourceRevision;
  Map<String, Object?> toJson() =>
      {'source_type': sourceType, 'source_id': sourceId, 'source_revision': sourceRevision};
}

class TaskSource {
  const TaskSource({required this.sourceType, required this.sourceId, required this.purpose});
  factory TaskSource.fromJson(Object? json) {
    final m = _map(ContractKind.taskSource, json);
    return TaskSource(
      sourceType: m['source_type'] as String,
      sourceId: m['source_id'] as String,
      purpose: m['purpose'] as String,
    );
  }
  final String sourceType;
  final String sourceId;
  final String purpose;
  Map<String, Object?> toJson() =>
      {'source_type': sourceType, 'source_id': sourceId, 'purpose': purpose};
}

class NotificationKey {
  const NotificationKey({
    required this.source,
    required this.recipientMemberId,
    required this.reminderKind,
    required this.scheduledAt,
  });
  factory NotificationKey.fromJson(Object? json) {
    final m = _map(ContractKind.notificationKey, json);
    return NotificationKey(
      source: SourceRef(
        sourceType: m['source_type'] as String,
        sourceId: m['source_id'] as String,
        sourceRevision: _int(m['source_revision']),
      ),
      recipientMemberId: m['recipient_member_id'] as String,
      reminderKind: m['reminder_kind'] as String,
      scheduledAt: Instant.fromJson(m['scheduled_at']),
    );
  }
  final SourceRef source;
  final String recipientMemberId;
  final String reminderKind;
  final Instant scheduledAt;
  Map<String, Object?> toJson() => {
        ...source.toJson(),
        'recipient_member_id': recipientMemberId,
        'reminder_kind': reminderKind,
        'scheduled_at': scheduledAt.toJson(),
      };
}

enum LifecycleEventName {
  accessHoldApplied('access_hold_applied'),
  accessHoldReleased('access_hold_released'),
  scopeRevoked('scope_revoked'),
  accountDeactivated('account_deactivated'),
  deletionRequested('deletion_requested'),
  cellTransferred('cell_transferred'),
  sessionsRevoked('sessions_revoked'),
  membershipDeactivated('membership_deactivated'),
  membershipRestored('membership_restored'),
  memberDeleted('member_deleted');

  const LifecycleEventName(this.wireName);
  final String wireName;
  static LifecycleEventName fromWire(String w) => values.firstWhere((e) => e.wireName == w);
}

class LifecycleEvent {
  const LifecycleEvent({
    required this.event,
    required this.memberId,
    required this.occurredAt,
    required this.identityRevision,
  });
  factory LifecycleEvent.fromJson(Object? json) {
    final m = _map(ContractKind.lifecycleEvent, json);
    return LifecycleEvent(
      event: LifecycleEventName.fromWire(m['event'] as String),
      memberId: m['member_id'] as String,
      occurredAt: Instant.fromJson(m['occurred_at']),
      identityRevision: _int(m['identity_revision']),
    );
  }
  final LifecycleEventName event;
  final String memberId;
  final Instant occurredAt;
  final int identityRevision;
  Map<String, Object?> toJson() => {
        'event': event.wireName,
        'member_id': memberId,
        'occurred_at': occurredAt.toJson(),
        'identity_revision': identityRevision,
      };
}

/// Church-local wall time with its explicit IANA zone (never inferred from the device).
class ZonedLocal {
  const ZonedLocal({required this.local, required this.zone});
  factory ZonedLocal.fromJson(Object? json) {
    final m = _map(ContractKind.zonedLocal, json);
    return ZonedLocal(local: m['local'] as String, zone: m['zone'] as String);
  }
  final String local;
  final String zone;
  Map<String, Object?> toJson() => {'local': local, 'zone': zone};
}

/// Exact unsigned decimal amount as a string plus currency. Never a double.
class Money {
  const Money._(this.amount, this.currency);
  factory Money.fromJson(Object? json) {
    final m = _map(ContractKind.money, json);
    return Money._(m['amount'] as String, m['currency'] as String);
  }
  final String amount;
  final String currency;

  /// Digits after the decimal point; the server enforces the approved scale.
  int get fractionDigits => amount.contains('.') ? amount.split('.')[1].length : 0;

  /// Exact value in units of 10^-[scale]; throws if the amount has more digits than [scale].
  BigInt toMinorUnits(int scale) {
    if (fractionDigits > scale) {
      throw ArgumentError.value(amount, 'amount', 'more fraction digits than scale $scale');
    }
    final parts = amount.split('.');
    return BigInt.parse(parts[0] + (parts.length > 1 ? parts[1] : '').padRight(scale, '0'));
  }

  Map<String, Object?> toJson() => {'amount': amount, 'currency': currency};
}

enum ErrorCode {
  validationFailed('validation_failed'),
  unauthenticated('unauthenticated'),
  forbidden('forbidden'),
  notFound('not_found'),
  conflict('conflict'),
  rateLimited('rate_limited'),
  unavailable('unavailable');

  const ErrorCode(this.wireName);
  final String wireName;
  static ErrorCode fromWire(String w) => values.firstWhere((e) => e.wireName == w);
}

class CommandRequest {
  const CommandRequest({
    required this.command,
    required this.requestId,
    this.expectedRevision = const Optional.absent(),
    this.payload = const {},
  });
  factory CommandRequest.fromJson(Object? json) {
    final m = _map(ContractKind.commandRequest, json);
    return CommandRequest(
      command: m['command'] as String,
      requestId: m['request_id'] as String,
      expectedRevision: Optional.fromKey<int>(m, 'expected_revision', _intOrNull),
      payload: (m['payload'] as Map).cast<String, Object?>(),
    );
  }
  final String command;

  /// Caller-generated UUID; reuse it when retrying an unknown outcome.
  final String requestId;

  /// Absent or null for create; required for an existing aggregate.
  final Optional<int> expectedRevision;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => {
        'version': contractVersion,
        'command': command,
        'request_id': requestId,
        if (expectedRevision.present) 'expected_revision': expectedRevision.value,
        'payload': payload,
      };
}

sealed class CommandResponse {
  const CommandResponse();
  factory CommandResponse.fromJson(Object? json) {
    final m = _map(ContractKind.commandResponse, json);
    if (m.containsKey('code')) {
      return CommandError(
        requestId: m['request_id'] as String?,
        code: ErrorCode.fromWire(m['code'] as String),
        message: m['message'] as String,
        fieldErrors: (m['field_errors'] as Map).cast<String, String>(),
        currentRevision: Optional.fromKey<int>(m, 'current_revision', _intOrNull),
      );
    }
    return CommandSuccess(
      requestId: m['request_id'] as String,
      data: m['data'],
      revision: _int(m['revision']),
    );
  }
  Map<String, Object?> toJson();
}

class CommandSuccess extends CommandResponse {
  const CommandSuccess({required this.requestId, required this.data, required this.revision});
  final String requestId;
  final Object? data;
  final int revision;
  @override
  Map<String, Object?> toJson() => {'request_id': requestId, 'data': data, 'revision': revision};
}

class CommandError extends CommandResponse {
  const CommandError({
    required this.requestId,
    required this.code,
    required this.message,
    required this.fieldErrors,
    this.currentRevision = const Optional.absent(),
  });
  final String? requestId;
  final ErrorCode code;
  final String message;

  /// Field path -> field error code. Codes are an open v1 vocabulary: besides the core codes
  /// ([fieldErrorCodeNames]) a command may return its own (`last_admin`, `held`, ...). Read the
  /// codes you know; treat any other as a generic notice for that field under [code].
  final Map<String, String> fieldErrors;

  /// Present only where the caller may read it (conflicts).
  final Optional<int> currentRevision;
  @override
  Map<String, Object?> toJson() => {
        'request_id': requestId,
        'code': code.wireName,
        'message': message,
        'field_errors': fieldErrors,
        if (currentRevision.present) 'current_revision': currentRevision.value,
      };
}

/// Typed decode by kind, used by the shared fixture tests.
Object decode(ContractKind kind, Object? json) => switch (kind) {
      ContractKind.memberRef => MemberRef.fromJson(json),
      ContractKind.accountRef => AccountRef.fromJson(json),
      ContractKind.actor => Actor.fromJson(json),
      ContractKind.sourceRef => SourceRef.fromJson(json),
      ContractKind.taskSource => TaskSource.fromJson(json),
      ContractKind.notificationKey => NotificationKey.fromJson(json),
      ContractKind.lifecycleEvent => LifecycleEvent.fromJson(json),
      ContractKind.instant => Instant.fromJson(json),
      ContractKind.zonedLocal => ZonedLocal.fromJson(json),
      ContractKind.money => Money.fromJson(json),
      ContractKind.commandRequest => CommandRequest.fromJson(json),
      ContractKind.commandResponse => CommandResponse.fromJson(json),
    };

/// Wire form of a value produced by [decode].
Object? encode(Object value) => switch (value) {
      Instant v => v.toJson(),
      MemberRef v => v.toJson(),
      AccountRef v => v.toJson(),
      Actor v => v.toJson(),
      SourceRef v => v.toJson(),
      TaskSource v => v.toJson(),
      NotificationKey v => v.toJson(),
      LifecycleEvent v => v.toJson(),
      ZonedLocal v => v.toJson(),
      Money v => v.toJson(),
      CommandRequest v => v.toJson(),
      CommandResponse v => v.toJson(),
      _ => throw ArgumentError.value(value, 'value', 'not a contract value'),
    };
