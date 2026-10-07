/// Story 2.7: the member's optional recovery email on the same account, and
/// the Admin's approval of it into the credential binding, as the server
/// reports them. Free of widgets and SDKs.
library;

import 'access_grants.dart';
import 'account_auth.dart';

abstract final class RecoveryEmailCommands {
  static const function = 'identity_recovery_email_command';
  static const propose = 'identity.propose_recovery_email';
  static const approve = 'identity.approve_recovery_email';
  static const reject = 'identity.reject_recovery_email';

  /// The member's own pending proposal, also while access waits in review.
  static const withdraw = 'identity.withdraw_recovery_email';
}

enum ProposalState {
  pending,
  approved,
  rejected,
  superseded,
  withdrawn;

  static ProposalState fromWire(Object? v) => switch (v) {
    'pending' => pending,
    'approved' => approved,
    'rejected' => rejected,
    'superseded' => superseded,
    'withdrawn' => withdrawn,
    _ => throw const FormatException('unknown proposal state'),
  };
}

/// Why an Admin did not approve an email (codes only).
enum RecoveryEmailRejectReason {
  identityNotConfirmed('identity_not_confirmed'),
  contactChurchOffice('contact_church_office');

  const RecoveryEmailRejectReason(this.wire);
  final String wire;

  static RecoveryEmailRejectReason? fromWire(Object? v) {
    for (final r in values) {
      if (r.wire == v) return r;
    }
    return null;
  }

  String get label => switch (this) {
    identityNotConfirmed => 'Identity could not be confirmed',
    contactChurchOffice => 'Please contact the church office',
  };
}

/// One proposal as its member sees it.
class RecoveryEmailProposal {
  const RecoveryEmailProposal({
    required this.proposalId,
    required this.revision,
    required this.email,
    required this.state,
    required this.verified,
    this.decisionReason,
  });

  factory RecoveryEmailProposal.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('proposal is not an object');
    final id = json['proposal_id'];
    final revision = json['revision'];
    final email = json['email'];
    final verified = json['verified'];
    if (id is! String ||
        revision is! int ||
        revision < 1 ||
        email is! String ||
        verified is! bool) {
      throw const FormatException('unexpected proposal shape');
    }
    return RecoveryEmailProposal(
      proposalId: id,
      revision: revision,
      email: email,
      state: ProposalState.fromWire(json['state']),
      verified: verified,
      decisionReason: RecoveryEmailRejectReason.fromWire(
        json['decision_reason'],
      ),
    );
  }

  final String proposalId;
  final int revision;
  final String email;
  final ProposalState state;

  /// The account holds this email, confirmed through its link.
  final bool verified;
  final RecoveryEmailRejectReason? decisionReason;
}

/// The member's own recovery-email state (`api.identity_my_recovery_email`).
class MyRecoveryEmail {
  const MyRecoveryEmail({
    required this.inReview,
    required this.approvedEmail,
    required this.proposal,
    required this.canPropose,
    required this.recentSignInMinutes,
  });

  factory MyRecoveryEmail.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('not an object');
    final access = json['access'];
    final approved = json['approved_email'];
    final canPropose = json['can_propose'];
    final minutes = json['recent_sign_in_minutes'];
    if ((access != 'granted' && access != 'review_required') ||
        (approved != null && approved is! String) ||
        canPropose is! bool ||
        minutes is! int) {
      throw const FormatException('unexpected recovery email shape');
    }
    final p = json['proposal'];
    return MyRecoveryEmail(
      inReview: access == 'review_required',
      approvedEmail: approved as String?,
      proposal: p == null ? null : RecoveryEmailProposal.fromJson(p),
      canPropose: canPropose,
      recentSignInMinutes: minutes,
    );
  }

  /// The account's access waits for a church check (for example a verified
  /// email waiting for approval).
  final bool inReview;
  final String? approvedEmail;
  final RecoveryEmailProposal? proposal;
  final bool canPropose;
  final int recentSignInMinutes;
}

/// One pending proposal in the Admin queue.
class RecoveryEmailReviewItem {
  const RecoveryEmailReviewItem({
    required this.proposal,
    required this.memberId,
    required this.displayName,
    required this.phoneUsername,
    required this.accessReview,
    required this.otherChanges,
    required this.ownAccount,
    required this.isSynthetic,
  });

  factory RecoveryEmailReviewItem.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('item is not an object');
    final memberId = json['member_id'];
    final name = json['display_name'];
    final phone = json['phone_username'];
    final review = json['access_review'];
    final other = json['other_changes'];
    final own = json['own_account'];
    final synthetic = json['is_synthetic'];
    if (memberId is! String ||
        name is! String ||
        phone is! String ||
        review is! bool ||
        other is! bool ||
        own is! bool ||
        synthetic is! bool) {
      throw const FormatException('unexpected review item shape');
    }
    return RecoveryEmailReviewItem(
      proposal: RecoveryEmailProposal.fromJson(json),
      memberId: memberId,
      displayName: name,
      phoneUsername: phone,
      accessReview: review,
      otherChanges: other,
      ownAccount: own,
      isSynthetic: synthetic,
    );
  }

  final RecoveryEmailProposal proposal;
  final String memberId;
  final String displayName;
  final String phoneUsername;
  final bool accessReview;

  /// Something besides this email changed on the account: the case belongs
  /// to the credential review, not to this approval.
  final bool otherChanges;
  final bool ownAccount;
  final bool isSynthetic;
}

class RecoveryEmailQueue {
  const RecoveryEmailQueue(this.items);

  factory RecoveryEmailQueue.fromJson(Object? json) {
    if (json is! Map || json['proposals'] is! List) {
      throw const FormatException('unexpected queue shape');
    }
    return RecoveryEmailQueue(
      List.unmodifiable(
        (json['proposals'] as List).map(RecoveryEmailReviewItem.fromJson),
      ),
    );
  }

  final List<RecoveryEmailReviewItem> items;
}

/// Asking Auth to send the confirmation link to the new address.
enum EmailVerificationRequest {
  sent,
  addressUnavailable,
  rateLimited,
  unreachable,
  failed,
}

/// Application port: the reads, a password re-check on the same account and
/// the native same-account email change. Never throws.
abstract interface class RecoveryEmailRepository {
  Future<AccessRead<MyRecoveryEmail>> fetchMine();

  /// Admin only.
  Future<AccessRead<RecoveryEmailQueue>> fetchQueue();

  /// Signs in again with the signed-in account's own phone username and
  /// [password] (a recent password sign-in is required to add an email).
  Future<AuthOutcome> confirmPassword(String password);

  /// Native `updateUser(email)` on the SAME account; Auth emails a
  /// confirmation link that returns to the email-confirmed link.
  Future<EmailVerificationRequest> requestVerification(String email);
}

class UnconfiguredRecoveryEmailRepository implements RecoveryEmailRepository {
  const UnconfiguredRecoveryEmailRepository();

  @override
  Future<AccessRead<MyRecoveryEmail>> fetchMine() async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<RecoveryEmailQueue>> fetchQueue() async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AuthOutcome> confirmPassword(String password) async =>
      const AuthFailed(AuthFailure.unavailable);

  @override
  Future<EmailVerificationRequest> requestVerification(String email) async =>
      EmailVerificationRequest.failed;
}
