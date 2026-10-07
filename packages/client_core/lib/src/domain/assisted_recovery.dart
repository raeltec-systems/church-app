/// Story 2.9: staff-assisted recovery with a single-use setup grant. The
/// member's device creates the grant secret and sends only its digest; staff
/// see a non-secret request code, never the secret, a digest or a password.
/// Free of widgets and SDKs.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'access_grants.dart';
import 'membership_review.dart' show IdentityCheck;

abstract final class RecoveryCaseCommands {
  static const function = 'identity_recovery_command';
  static const open = 'identity.open_recovery_case';
  static const issue = 'identity.issue_recovery_grant';
  static const cancel = 'identity.cancel_recovery_case';
  static const reconcile = 'identity.reconcile_recovery_operation';
}

// ---------------------------------------------------------------------------
// Member device
// ---------------------------------------------------------------------------

/// The grant secret this device holds in memory only. Its [digest] is what
/// the server stores; the secret itself leaves the device once, with the
/// chosen password, to the recovery service.
class GrantSecret {
  GrantSecret._(this.value)
    : digest = sha256.convert(utf8.encode(value)).toString();

  /// 32 random bytes from a secure source, `arg_` + base64url without padding.
  factory GrantSecret.generate([Random? random]) {
    final r = random ?? Random.secure();
    final bytes = List<int>.generate(32, (_) => r.nextInt(256));
    return GrantSecret._('arg_${base64Url.encode(bytes).replaceAll('=', '')}');
  }

  /// For tests: a known secret.
  factory GrantSecret.fromValue(String value) {
    if (!RegExp(r'^arg_[A-Za-z0-9_-]{43}$').hasMatch(value)) {
      throw const FormatException('not a grant secret');
    }
    return GrantSecret._(value);
  }

  final String value;
  final String digest;

  @override
  String toString() => 'GrantSecret(…)';
}

/// The answer to a recovery request. Neutral: it never says whether the
/// number has an account.
sealed class RecoveryRequestOutcome {
  const RecoveryRequestOutcome();
}

class RecoveryRequestReceived extends RecoveryRequestOutcome {
  const RecoveryRequestReceived(this.requestCode, this.expiresAt);

  /// Shown to the church office; not a secret.
  final String requestCode;
  final DateTime? expiresAt;
}

class RecoveryRequestNotReceived extends RecoveryRequestOutcome {
  const RecoveryRequestNotReceived(this.reason);
  final RecoveryFailure reason;
}

enum RecoveryFailure {
  rateLimited,
  refused,
  unavailable,
  unreachable,
  notConfigured,
}

enum RecoveryGrantState { waiting, ready, closed }

/// The state of this device's request: waiting for the office, ready to set
/// a password, or closed (expired, used or replaced).
sealed class RecoveryStatusOutcome {
  const RecoveryStatusOutcome();
}

class RecoveryStatus extends RecoveryStatusOutcome {
  const RecoveryStatus(this.state, this.expiresAt);
  final RecoveryGrantState state;
  final DateTime? expiresAt;
}

class RecoveryStatusFailed extends RecoveryStatusOutcome {
  const RecoveryStatusFailed(this.reason);
  final RecoveryFailure reason;
}

enum RedeemOutcome {
  /// The password is set; every older session ended. Sign in again.
  succeeded,

  /// The setup can't be used (used, replaced, expired, or the details
  /// changed). Ask the church office for a new one.
  rejected,

  /// Auth did not accept this password; ask for a new setup.
  passwordRejected,

  /// The change could not be confirmed. The account stays protected until
  /// the church office checks it.
  uncertain,
  unavailable,
  unreachable,
  invalid,
  notConfigured,
}

/// The recovery service a member device uses without a session. Never
/// throws.
abstract interface class AssistedRecoveryGateway {
  Future<RecoveryRequestOutcome> request(String phoneUsername, String digest);

  Future<RecoveryStatusOutcome> status(String digest);

  /// Sends the secret and the chosen password once.
  Future<RedeemOutcome> redeem(
    String phoneUsername,
    GrantSecret secret,
    String password,
  );
}

class UnconfiguredAssistedRecoveryGateway implements AssistedRecoveryGateway {
  const UnconfiguredAssistedRecoveryGateway();

  @override
  Future<RecoveryRequestOutcome> request(String phone, String digest) async =>
      const RecoveryRequestNotReceived(RecoveryFailure.notConfigured);

  @override
  Future<RecoveryStatusOutcome> status(String digest) async =>
      const RecoveryStatusFailed(RecoveryFailure.notConfigured);

  @override
  Future<RedeemOutcome> redeem(
    String phone,
    GrantSecret secret,
    String password,
  ) async => RedeemOutcome.notConfigured;
}

/// The password rules checked before the setup is used: 8 to 72 bytes
/// (Auth's bcrypt limit), so an obviously unusable password never consumes
/// the single-use grant.
String? setupPasswordProblem(String password, String confirmation) {
  final bytes = utf8.encode(password).length;
  if (bytes < 8) return 'Use at least 8 characters.';
  if (bytes > 72) return 'Use at most 72 characters.';
  if (password != confirmation) return 'The two passwords are different.';
  return null;
}

// ---------------------------------------------------------------------------
// Staff (Admin)
// ---------------------------------------------------------------------------

/// What the reviewer saw (codes only).
enum RecoveryEvidence {
  photoId('photo_id'),
  knownInPerson('known_in_person'),
  churchRecords('church_records'),
  leaderConfirmation('leader_confirmation');

  const RecoveryEvidence(this.wire);
  final String wire;

  static RecoveryEvidence? fromWire(Object? v) {
    for (final e in values) {
      if (e.wire == v) return e;
    }
    return null;
  }

  String get label => switch (this) {
    photoId => 'Photo ID seen',
    knownInPerson => 'Known to me in person',
    churchRecords => 'Matches church records',
    leaderConfirmation => 'Confirmed by their cell leader',
  };
}

enum RecoveryCancelReason {
  identityNotConfirmed('identity_not_confirmed'),
  memberWithdrew('member_withdrew'),
  openedInError('opened_in_error');

  const RecoveryCancelReason(this.wire);
  final String wire;

  String get label => switch (this) {
    identityNotConfirmed => 'Identity not confirmed',
    memberWithdrew => 'The member no longer needs it',
    openedInError => 'Opened in error',
  };
}

/// A request code as staff type it: upper case, no spaces or dashes.
String normalizeRequestCode(String input) =>
    input.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');

bool looksLikeRequestCode(String input) =>
    RegExp(r'^[A-HJ-NP-Z2-9]{8}$').hasMatch(normalizeRequestCode(input));

class RecoveryCaseItem {
  const RecoveryCaseItem({
    required this.caseId,
    required this.revision,
    required this.memberId,
    required this.displayName,
    required this.caseState,
    required this.identityCheck,
    required this.evidence,
    required this.openedAt,
    required this.held,
    required this.ownMember,
    required this.isSynthetic,
    this.outcome,
    this.cancelReason,
    this.linkProblem,
    this.grantState,
    this.grantExpiresAt,
    this.operationState,
  });

  factory RecoveryCaseItem.fromJson(Object? json) {
    if (json is! Map ||
        json['case_id'] is! String ||
        json['revision'] is! int ||
        json['member_id'] is! String ||
        json['display_name'] is! String ||
        json['case_state'] is! String ||
        json['identity_check'] is! String ||
        json['evidence'] is! List ||
        json['opened_at'] is! String ||
        json['held'] is! bool ||
        json['is_synthetic'] is! bool) {
      throw const FormatException('unexpected recovery case');
    }
    final grant = json['grant'];
    final op = json['operation'];
    if ((grant != null && grant is! Map) || (op != null && op is! Map)) {
      throw const FormatException('unexpected recovery case');
    }
    return RecoveryCaseItem(
      caseId: json['case_id'] as String,
      revision: json['revision'] as int,
      memberId: json['member_id'] as String,
      displayName: json['display_name'] as String,
      caseState: json['case_state'] as String,
      identityCheck: json['identity_check'] == 'in_person'
          ? IdentityCheck.inPerson
          : IdentityCheck.establishedRelationship,
      evidence: List.unmodifiable(
        (json['evidence'] as List)
            .map(RecoveryEvidence.fromWire)
            .whereType<RecoveryEvidence>(),
      ),
      openedAt: DateTime.parse(json['opened_at'] as String),
      held: json['held'] as bool,
      ownMember: json['own_member'] == true,
      isSynthetic: json['is_synthetic'] as bool,
      outcome: json['outcome'] as String?,
      cancelReason: json['cancel_reason'] as String?,
      linkProblem: json['link_problem'] as String?,
      grantState: grant is Map ? grant['state'] as String? : null,
      grantExpiresAt: grant is Map && grant['expires_at'] is String
          ? DateTime.parse(grant['expires_at'] as String)
          : null,
      operationState: op is Map ? op['state'] as String? : null,
    );
  }

  final String caseId;
  final int revision;
  final String memberId;
  final String displayName;

  /// `open`, `completed` or `cancelled`.
  final String caseState;
  final IdentityCheck identityCheck;
  final List<RecoveryEvidence> evidence;
  final DateTime openedAt;

  /// The member has an open hold (shown in Access reviews).
  final bool held;
  final bool ownMember;
  final bool isSynthetic;
  final String? outcome;
  final String? cancelReason;

  /// Why a grant cannot be issued now (null: it can).
  final String? linkProblem;

  /// `issued`, `expired`, `consumed`, `superseded`, `burned`, `cancelled`.
  final String? grantState;
  final DateTime? grantExpiresAt;

  /// `pending`, `dispatched`, `succeeded`, `failed`, `uncertain`, `stuck`,
  /// `obsolete`, `reconciled`.
  final String? operationState;

  bool get isOpen => caseState == 'open';

  /// The last reset could not be confirmed: reconcile before anything else.
  bool get needsReconciliation =>
      operationState == 'uncertain' || operationState == 'stuck';

  bool get inFlight =>
      operationState == 'pending' || operationState == 'dispatched';
}

class RecoveryCases {
  const RecoveryCases({required this.cases, required this.accepting});

  factory RecoveryCases.fromJson(Object? json) {
    if (json is! Map || json['cases'] is! List || json['accepting'] is! bool) {
      throw const FormatException('unexpected recovery cases');
    }
    return RecoveryCases(
      cases: List.unmodifiable(
        (json['cases'] as List).map(RecoveryCaseItem.fromJson),
      ),
      accepting: json['accepting'] as bool,
    );
  }

  final List<RecoveryCaseItem> cases;

  /// Assisted recovery is open in this environment (policy gates).
  final bool accepting;
}

/// Application port for the Admin read. Never throws.
abstract interface class RecoveryCasesRepository {
  Future<AccessRead<RecoveryCases>> fetchCases();
}

class UnconfiguredRecoveryCasesRepository implements RecoveryCasesRepository {
  const UnconfiguredRecoveryCasesRepository();

  @override
  Future<AccessRead<RecoveryCases>> fetchCases() async =>
      const AccessReadDenied(AccessDenial.unavailable);
}
