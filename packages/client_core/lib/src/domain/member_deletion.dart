/// Story 2.11: full member deletion. A member asks in the app; an Admin asks
/// for a member who cannot use the app. Access ends at once; a server-side
/// worker then deletes the account and erases the data step by step. The
/// Admin sees each deletion's steps; nobody sees a password, a reason or any
/// care or finance content. Free of widgets and SDKs.
library;

import 'access_grants.dart';

abstract final class DeletionCommands {
  static const function = 'identity_deletion_command';
  static const requestMine = 'identity.request_my_deletion';
  static const requestMember = 'identity.request_member_deletion';

  /// The exact confirmation the in-app request carries.
  static const confirmation = 'delete_my_account';
}

/// One step of a deletion, as the server reports it.
class DeletionStep {
  const DeletionStep({
    required this.step,
    required this.state,
    required this.attempts,
    this.outcome,
  });

  factory DeletionStep.fromJson(Object? json) {
    if (json is! Map ||
        json['step'] is! String ||
        json['state'] is! String ||
        json['attempts'] is! int ||
        (json['outcome'] != null && json['outcome'] is! String)) {
      throw const FormatException('unexpected deletion step');
    }
    return DeletionStep(
      step: json['step'] as String,
      state: json['state'] as String,
      attempts: json['attempts'] as int,
      outcome: json['outcome'] as String?,
    );
  }

  /// `journal_access_revoked`, `auth_account`, `erase_identity`, ...
  final String step;

  /// `pending`, `waiting`, `failed` or `done`.
  final String state;
  final int attempts;
  final String? outcome;

  bool get done => state == 'done';

  /// Plain words for the step (never an internal id).
  String get label => switch (step) {
    'journal_access_revoked' =>
      'Access closed (recorded in the recovery journal)',
    'journal_manifest_member' ||
    'journal_manifest_account' => 'Deletion recorded in the recovery journal',
    'auth_account' => 'App account deleted',
    'erase_identity' => 'Membership details erased',
    'erase_owners' => 'Cell and other sections erased',
    'anonymise' => 'Kept records made anonymous',
    'verify' => 'Every store checked',
    'journal_completed_member' || 'journal_completed_account' =>
      'Completion recorded in the recovery journal',
    'complete' => 'Deletion complete',
    _ => step.replaceAll('_', ' '),
  };
}

/// A deletion in the Admin read (`api.identity_admin_deletions`).
class MemberDeletion {
  const MemberDeletion({
    required this.deletionId,
    required this.memberId,
    required this.displayName,
    required this.origin,
    required this.completed,
    required this.hadAccount,
    required this.pendingObligations,
    required this.steps,
    required this.isSynthetic,
    this.waitingReason,
  });

  factory MemberDeletion.fromJson(Object? json) {
    if (json is! Map ||
        json['deletion_id'] is! String ||
        json['member_id'] is! String ||
        json['display_name'] is! String ||
        json['origin'] is! String ||
        json['deletion_state'] is! String ||
        json['had_account'] is! bool ||
        json['pending_obligations'] is! int ||
        json['is_synthetic'] is! bool ||
        json['steps'] is! List ||
        json['next'] is! Map) {
      throw const FormatException('unexpected deletion');
    }
    final next = json['next'] as Map;
    return MemberDeletion(
      deletionId: json['deletion_id'] as String,
      memberId: json['member_id'] as String,
      displayName: json['display_name'] as String,
      origin: json['origin'] as String,
      completed: json['deletion_state'] == 'completed',
      hadAccount: json['had_account'] as bool,
      pendingObligations: json['pending_obligations'] as int,
      isSynthetic: json['is_synthetic'] as bool,
      steps: List.unmodifiable(
        (json['steps'] as List).map(DeletionStep.fromJson),
      ),
      waitingReason: next['action'] == 'wait' && next['reason'] is String
          ? next['reason'] as String
          : null,
    );
  }

  final String deletionId;
  final String memberId;

  /// The member's name until it is erased; `Deleted member` afterwards.
  final String displayName;

  /// `member_request`, `staff_request` or `journal_replay`.
  final String origin;
  final bool completed;
  final bool hadAccount;
  final int pendingObligations;
  final List<DeletionStep> steps;
  final bool isSynthetic;

  /// Why the next step waits: `handover_pending`, `policy_gate_closed`,
  /// `restore_held`; null when it does not wait.
  final String? waitingReason;

  int get doneSteps => steps.where((s) => s.done).length;
}

/// A deactivated member an Admin may delete on the staff route.
class DeletionCandidate {
  const DeletionCandidate({
    required this.memberId,
    required this.displayName,
    required this.revision,
    required this.account,
    required this.ownMember,
    required this.isSynthetic,
  });

  factory DeletionCandidate.fromJson(Object? json) {
    if (json is! Map ||
        json['member_id'] is! String ||
        json['display_name'] is! String ||
        json['revision'] is! int ||
        json['account'] is! String ||
        json['own_member'] is! bool ||
        json['is_synthetic'] is! bool) {
      throw const FormatException('unexpected deletion candidate');
    }
    return DeletionCandidate(
      memberId: json['member_id'] as String,
      displayName: json['display_name'] as String,
      revision: json['revision'] as int,
      account: switch (json['account']) {
        'app_account' => AccountStanding.appAccount,
        'no_login' => AccountStanding.noLogin,
        'access_review' => AccountStanding.accessReview,
        _ => throw const FormatException('unexpected account standing'),
      },
      ownMember: json['own_member'] as bool,
      isSynthetic: json['is_synthetic'] as bool,
    );
  }

  final String memberId;
  final String displayName;
  final int revision;
  final AccountStanding account;
  final bool ownMember;
  final bool isSynthetic;
}

/// The Admin read `api.identity_admin_deletions`.
class MemberDeletionOverview {
  const MemberDeletionOverview({
    required this.deletions,
    required this.deactivated,
    required this.accepting,
  });

  factory MemberDeletionOverview.fromJson(Object? json) {
    if (json is! Map ||
        json['deletions'] is! List ||
        json['deactivated'] is! List ||
        json['accepting'] is! bool) {
      throw const FormatException('unexpected deletion overview');
    }
    return MemberDeletionOverview(
      deletions: List.unmodifiable(
        (json['deletions'] as List).map(MemberDeletion.fromJson),
      ),
      deactivated: List.unmodifiable(
        (json['deactivated'] as List).map(DeletionCandidate.fromJson),
      ),
      accepting: json['accepting'] as bool,
    );
  }

  final List<MemberDeletion> deletions;
  final List<DeletionCandidate> deactivated;

  /// Whether erasure may run in this environment (Q4 retention gate; a
  /// labelled fixture in local/staging). Requests are recorded either way.
  final bool accepting;
}

/// Application port for the Admin read. Never throws; a fresh request every
/// call.
abstract interface class MemberDeletionRepository {
  Future<AccessRead<MemberDeletionOverview>> fetchOverview();
}

class UnconfiguredMemberDeletionRepository implements MemberDeletionRepository {
  const UnconfiguredMemberDeletionRepository();

  @override
  Future<AccessRead<MemberDeletionOverview>> fetchOverview() async =>
      const AccessReadDenied(AccessDenial.unavailable);
}
