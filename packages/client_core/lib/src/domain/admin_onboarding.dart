/// First-Admin commissioning client contract. This port does not grant access:
/// only the server can validate an invitation and complete commissioning.
library;

/// Never include the invitation in diagnostics, URLs or persisted state.
final class AdminInvitation {
  const AdminInvitation(this.value);
  final String value;
  @override
  String toString() => 'AdminInvitation([redacted])';
}

enum AdminEnrollmentMode { newAccount, existingAccount }

enum AdminOnboardingOutcome {
  ready,
  pending,
  completed,
  activationPending,
  refused,
  rateLimited,
  unavailable,

  /// A mutation may have committed. Check status; do not repeat provisioning.
  uncertain,
  passwordRejected,
}

final class AdminOnboardingReply {
  const AdminOnboardingReply(
    this.outcome, {
    this.mode,
    this.privacyVersion,
    this.privacyText,
    this.expiresAt,
    this.requestId,
  });

  factory AdminOnboardingReply.fromJson(Object? json) {
    if (json is! Map<String, Object?> || json['outcome'] is! String) {
      throw const FormatException('Invalid commissioning response');
    }
    final outcome = switch (json['outcome']) {
      'ready' => AdminOnboardingOutcome.ready,
      'pending' => AdminOnboardingOutcome.pending,
      'completed' => AdminOnboardingOutcome.completed,
      'activation_pending' => AdminOnboardingOutcome.activationPending,
      'refused' => AdminOnboardingOutcome.refused,
      'rate_limited' => AdminOnboardingOutcome.rateLimited,
      'unavailable' => AdminOnboardingOutcome.unavailable,
      'uncertain' => AdminOnboardingOutcome.uncertain,
      'password_rejected' => AdminOnboardingOutcome.passwordRejected,
      _ => throw const FormatException('Unknown commissioning outcome'),
    };
    if (outcome == AdminOnboardingOutcome.completed ||
        outcome == AdminOnboardingOutcome.activationPending) {
      // Provisioning is not a session, and must never silently sign someone in.
      if (json['sign_in_required'] != true) {
        throw const FormatException('Missing fresh sign-in requirement');
      }
    }
    if (outcome == AdminOnboardingOutcome.pending) {
      final requestId = json['request_id'];
      if (requestId is! String ||
          !RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
          ).hasMatch(requestId)) {
        throw const FormatException('Missing pending operation correlation');
      }
      return AdminOnboardingReply(outcome, requestId: requestId);
    }
    if (outcome != AdminOnboardingOutcome.ready) {
      return AdminOnboardingReply(outcome);
    }
    final mode = switch (json['mode']) {
      'new_account' => AdminEnrollmentMode.newAccount,
      'existing_account' => AdminEnrollmentMode.existingAccount,
      _ => throw const FormatException('Unknown enrollment mode'),
    };
    final version = json['privacy_notice_version'];
    final text = json['privacy_notice_text'];
    final expiry = json['expires_at'];
    final at = expiry is String ? DateTime.tryParse(expiry) : null;
    if (version is! String ||
        version.isEmpty ||
        version.length > 100 ||
        text is! String ||
        text.trim().isEmpty ||
        text.length > 20000 ||
        at == null ||
        !at.isUtc) {
      throw const FormatException('Incomplete invitation response');
    }
    return AdminOnboardingReply(
      outcome,
      mode: mode,
      privacyVersion: version,
      privacyText: text,
      expiresAt: at,
    );
  }

  final AdminOnboardingOutcome outcome;
  final AdminEnrollmentMode? mode;
  final String? privacyVersion;
  final String? privacyText;
  final DateTime? expiresAt;
  final String? requestId;
}

abstract interface class AdminOnboardingRepository {
  Future<AdminOnboardingReply> inspect({
    required AdminInvitation invitation,
    required String phoneUsername,
  });
  Future<AdminOnboardingReply> complete({
    required AdminInvitation invitation,
    required String phoneUsername,
    required String fullName,
    required String password,
    required String privacyVersion,
    required String requestId,
  });
  Future<AdminOnboardingReply> status({
    required AdminInvitation invitation,
    required String phoneUsername,
    required String requestId,
  });
}

final class UnconfiguredAdminOnboardingRepository
    implements AdminOnboardingRepository {
  const UnconfiguredAdminOnboardingRepository();
  static const _unavailable = AdminOnboardingReply(
    AdminOnboardingOutcome.unavailable,
  );
  @override
  Future<AdminOnboardingReply> inspect({
    required AdminInvitation invitation,
    required String phoneUsername,
  }) async => _unavailable;
  @override
  Future<AdminOnboardingReply> complete({
    required AdminInvitation invitation,
    required String phoneUsername,
    required String fullName,
    required String password,
    required String privacyVersion,
    required String requestId,
  }) async => _unavailable;
  @override
  Future<AdminOnboardingReply> status({
    required AdminInvitation invitation,
    required String phoneUsername,
    required String requestId,
  }) async => _unavailable;
}
