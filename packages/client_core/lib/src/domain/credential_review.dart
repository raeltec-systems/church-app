/// Story 2.8: reviewed sign-in detail changes (phone username, recovery
/// email), holds and the credential review, as the server reports them. The
/// member's own read is generic: it never says why access is in review.
/// Free of widgets and SDKs.
library;

import 'access_grants.dart';
import 'recovery_email.dart';

abstract final class CredentialCommands {
  static const function = 'identity_credential_command';

  /// The member's own request (fresh password sign-in).
  static const request = 'identity.request_credential_change';

  /// The member's own pending request, also while access is in review.
  static const withdraw = 'identity.withdraw_credential_change';
  static const approve = 'identity.approve_credential_change';
  static const reject = 'identity.reject_credential_change';
  static const placeHold = 'identity.place_hold';
  static const releaseHold = 'identity.release_hold';
  static const restore = 'identity.restore_credentials';
  static const accept = 'identity.accept_credentials';
}

enum CredentialChangeKind {
  phoneUsername('phone_username'),
  recoveryEmailReplace('recovery_email_replace'),
  recoveryEmailRemove('recovery_email_remove');

  const CredentialChangeKind(this.wire);
  final String wire;

  static CredentialChangeKind fromWire(Object? v) {
    for (final k in values) {
      if (k.wire == v) return k;
    }
    throw const FormatException('unknown change kind');
  }

  String get label => switch (this) {
    phoneUsername => 'New phone number username',
    recoveryEmailReplace => 'New recovery email',
    recoveryEmailRemove => 'Remove the recovery email',
  };
}

enum CredentialChangeState {
  pending,
  approved,
  rejected,
  withdrawn;

  static CredentialChangeState fromWire(Object? v) => switch (v) {
    'pending' => pending,
    'approved' => approved,
    'rejected' => rejected,
    'withdrawn' => withdrawn,
    _ => throw const FormatException('unknown change state'),
  };
}

/// Why an Admin placed a hold (codes; the member is never told).
enum HoldReason {
  ownershipDispute('ownership_dispute'),
  securityConcern('security_concern'),
  lostDevice('lost_device');

  const HoldReason(this.wire);
  final String wire;

  static HoldReason? fromWire(Object? v) {
    for (final r in values) {
      if (r.wire == v) return r;
    }
    return null;
  }

  String get label => switch (this) {
    ownershipDispute => 'Ownership dispute accepted for review',
    securityConcern => 'Security concern',
    lostDevice => 'Lost or compromised device (signs out every device)',
  };
}

/// One change request as its member sees it.
class CredentialChange {
  const CredentialChange({
    required this.changeId,
    required this.revision,
    required this.kind,
    required this.state,
    this.phoneUsername,
    this.email,
    this.verified,
    this.decisionReason,
  });

  factory CredentialChange.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('change is not an object');
    final id = json['change_id'];
    final revision = json['revision'];
    final phone = json['phone_username'];
    final email = json['email'];
    final verified = json['verified'];
    if (id is! String ||
        revision is! int ||
        revision < 1 ||
        (phone != null && phone is! String) ||
        (email != null && email is! String) ||
        (verified != null && verified is! bool)) {
      throw const FormatException('unexpected change shape');
    }
    return CredentialChange(
      changeId: id,
      revision: revision,
      kind: CredentialChangeKind.fromWire(json['change_kind']),
      state: CredentialChangeState.fromWire(json['state']),
      phoneUsername: phone as String?,
      email: email as String?,
      verified: verified as bool?,
      decisionReason: RecoveryEmailRejectReason.fromWire(
        json['decision_reason'],
      ),
    );
  }

  final String changeId;
  final int revision;
  final CredentialChangeKind kind;
  final CredentialChangeState state;

  /// The requested new username (phone change only).
  final String? phoneUsername;

  /// The requested new address (replacement only).
  final String? email;

  /// A replacement's new address is confirmed on the account.
  final bool? verified;
  final RecoveryEmailRejectReason? decisionReason;
}

/// The member's own sign-in details (`api.identity_my_credentials`), also
/// while access is in review.
class MyCredentials {
  const MyCredentials({
    required this.inReview,
    required this.phoneUsername,
    required this.recoveryEmail,
    required this.pendingChange,
    required this.lastChange,
    required this.pendingRecoveryEmail,
    required this.canRequest,
    required this.churchContact,
    required this.recentSignInMinutes,
  });

  factory MyCredentials.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('not an object');
    final access = json['access'];
    final phone = json['phone_username'];
    final email = json['recovery_email'];
    final canRequest = json['can_request'];
    final contact = json['church_contact'];
    final minutes = json['recent_sign_in_minutes'];
    if ((access != 'granted' && access != 'review_required') ||
        phone is! String ||
        (email != null && email is! String) ||
        canRequest is! bool ||
        (contact != null && contact is! String) ||
        minutes is! int) {
      throw const FormatException('unexpected credentials shape');
    }
    final pending = json['pending_change'];
    final last = json['last_change'];
    final proposal = json['pending_recovery_email'];
    return MyCredentials(
      inReview: access == 'review_required',
      phoneUsername: phone,
      recoveryEmail: email as String?,
      pendingChange: pending == null
          ? null
          : CredentialChange.fromJson(pending),
      lastChange: last == null ? null : CredentialChange.fromJson(last),
      pendingRecoveryEmail: proposal == null
          ? null
          : RecoveryEmailProposal.fromJson(proposal),
      canRequest: canRequest,
      churchContact: contact as String?,
      recentSignInMinutes: minutes,
    );
  }

  /// Access waits for a church check. Why is never said.
  final bool inReview;
  final String phoneUsername;
  final String? recoveryEmail;
  final CredentialChange? pendingChange;
  final CredentialChange? lastChange;

  /// A pending 2.7 recovery-email addition (the current request too).
  final RecoveryEmailProposal? pendingRecoveryEmail;
  final bool canRequest;

  /// The church's contact route, when the church has set one.
  final String? churchContact;
  final int recentSignInMinutes;
}

/// One requested change in the Admin queue.
class CredentialChangeItem {
  const CredentialChangeItem({
    required this.change,
    required this.memberId,
    required this.displayName,
    required this.memberRevision,
    required this.currentPhoneUsername,
    required this.hasRecoveryEmail,
    required this.accessReview,
    required this.phoneAvailable,
    required this.otherChanges,
    required this.ownAccount,
    required this.isSynthetic,
  });

  factory CredentialChangeItem.fromJson(Object? json) {
    if (json is! Map ||
        json['member_id'] is! String ||
        json['display_name'] is! String ||
        json['member_revision'] is! int ||
        json['current_phone_username'] is! String ||
        json['has_recovery_email'] is! bool ||
        json['access_review'] is! bool ||
        (json['phone_available'] != null && json['phone_available'] is! bool) ||
        json['other_changes'] is! bool ||
        json['own_account'] is! bool ||
        json['is_synthetic'] is! bool) {
      throw const FormatException('unexpected change item');
    }
    return CredentialChangeItem(
      change: CredentialChange.fromJson(json),
      memberId: json['member_id'] as String,
      displayName: json['display_name'] as String,
      memberRevision: json['member_revision'] as int,
      currentPhoneUsername: json['current_phone_username'] as String,
      hasRecoveryEmail: json['has_recovery_email'] as bool,
      accessReview: json['access_review'] as bool,
      phoneAvailable: json['phone_available'] as bool?,
      otherChanges: json['other_changes'] as bool,
      ownAccount: json['own_account'] as bool,
      isSynthetic: json['is_synthetic'] as bool,
    );
  }

  final CredentialChange change;
  final String memberId;
  final String displayName;
  final int memberRevision;
  final String currentPhoneUsername;
  final bool hasRecoveryEmail;
  final bool accessReview;

  /// Phone change only: no other account holds the new number.
  final bool? phoneAvailable;

  /// Something else changed on the account: reject, then review it.
  final bool otherChanges;
  final bool ownAccount;
  final bool isSynthetic;
}

/// An account waiting in access review with no pending request.
class AccessReviewItem {
  const AccessReviewItem({
    required this.memberId,
    required this.displayName,
    required this.memberRevision,
    required this.bindingReview,
    required this.phoneUsername,
    required this.recoveryEmail,
    required this.authPhoneUsername,
    required this.authEmail,
    required this.authEmailConfirmed,
    required this.extraFactors,
    required this.changeKinds,
    required this.ownAccount,
    required this.isSynthetic,
  });

  factory AccessReviewItem.fromJson(Object? json) {
    if (json is! Map ||
        json['member_id'] is! String ||
        json['display_name'] is! String ||
        json['member_revision'] is! int ||
        json['binding_review'] is! bool ||
        json['phone_username'] is! String ||
        (json['recovery_email'] != null && json['recovery_email'] is! String) ||
        (json['auth_phone_username'] != null &&
            json['auth_phone_username'] is! String) ||
        (json['auth_email'] != null && json['auth_email'] is! String) ||
        json['auth_email_confirmed'] is! bool ||
        json['extra_factors'] is! bool ||
        json['change_kinds'] is! List ||
        (json['change_kinds'] as List).any((k) => k is! String) ||
        json['own_account'] is! bool ||
        json['is_synthetic'] is! bool) {
      throw const FormatException('unexpected review item');
    }
    return AccessReviewItem(
      memberId: json['member_id'] as String,
      displayName: json['display_name'] as String,
      memberRevision: json['member_revision'] as int,
      bindingReview: json['binding_review'] as bool,
      phoneUsername: json['phone_username'] as String,
      recoveryEmail: json['recovery_email'] as String?,
      authPhoneUsername: json['auth_phone_username'] as String?,
      authEmail: json['auth_email'] as String?,
      authEmailConfirmed: json['auth_email_confirmed'] as bool,
      extraFactors: json['extra_factors'] as bool,
      changeKinds: List.unmodifiable(
        (json['change_kinds'] as List).cast<String>(),
      ),
      ownAccount: json['own_account'] as bool,
      isSynthetic: json['is_synthetic'] as bool,
    );
  }

  final String memberId;
  final String displayName;
  final int memberRevision;

  /// A detected direct sign-in change waits for review.
  final bool bindingReview;

  /// The approved binding.
  final String phoneUsername;
  final String? recoveryEmail;

  /// What the sign-in service holds now.
  final String? authPhoneUsername;
  final String? authEmail;
  final bool authEmailConfirmed;

  /// An extra sign-in factor or provider exists: only restore applies.
  final bool extraFactors;

  /// Recorded change kinds (codes), never values.
  final List<String> changeKinds;
  final bool ownAccount;
  final bool isSynthetic;
}

class HoldItem {
  const HoldItem({
    required this.holdId,
    required this.memberId,
    required this.displayName,
    required this.memberRevision,
    required this.holdKind,
    required this.reason,
    required this.ownMember,
    required this.isSynthetic,
  });

  factory HoldItem.fromJson(Object? json) {
    if (json is! Map ||
        json['hold_id'] is! String ||
        json['member_id'] is! String ||
        json['display_name'] is! String ||
        json['member_revision'] is! int ||
        json['hold_kind'] is! String ||
        json['own_member'] is! bool ||
        json['is_synthetic'] is! bool) {
      throw const FormatException('unexpected hold item');
    }
    return HoldItem(
      holdId: json['hold_id'] as String,
      memberId: json['member_id'] as String,
      displayName: json['display_name'] as String,
      memberRevision: json['member_revision'] as int,
      holdKind: json['hold_kind'] as String,
      reason: HoldReason.fromWire(json['reason_code']),
      ownMember: json['own_member'] as bool,
      isSynthetic: json['is_synthetic'] as bool,
    );
  }

  final String holdId;
  final String memberId;
  final String displayName;
  final int memberRevision;
  final String holdKind;

  /// Null for a hold an operator placed before story 2.8.
  final HoldReason? reason;
  final bool ownMember;
  final bool isSynthetic;
}

class CredentialQueue {
  const CredentialQueue({
    required this.changes,
    required this.reviews,
    required this.holds,
  });

  factory CredentialQueue.fromJson(Object? json) {
    if (json is! Map ||
        json['changes'] is! List ||
        json['reviews'] is! List ||
        json['holds'] is! List) {
      throw const FormatException('unexpected credential queue');
    }
    return CredentialQueue(
      changes: List.unmodifiable(
        (json['changes'] as List).map(CredentialChangeItem.fromJson),
      ),
      reviews: List.unmodifiable(
        (json['reviews'] as List).map(AccessReviewItem.fromJson),
      ),
      holds: List.unmodifiable((json['holds'] as List).map(HoldItem.fromJson)),
    );
  }

  final List<CredentialChangeItem> changes;
  final List<AccessReviewItem> reviews;
  final List<HoldItem> holds;
}

/// Application port for the reads. The password re-check and the native
/// email change are the 2.7 [RecoveryEmailRepository]'s. Never throws.
abstract interface class CredentialReviewRepository {
  Future<AccessRead<MyCredentials>> fetchMine();

  /// Admin only.
  Future<AccessRead<CredentialQueue>> fetchQueue();
}

class UnconfiguredCredentialReviewRepository
    implements CredentialReviewRepository {
  const UnconfiguredCredentialReviewRepository();

  @override
  Future<AccessRead<MyCredentials>> fetchMine() async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<CredentialQueue>> fetchQueue() async =>
      const AccessReadDenied(AccessDenial.unavailable);
}
