/// Story 2.10: login hold, church deactivation and reviewed restoration of a
/// membership, as the server reports them. The member's own status says only
/// whether the membership is deactivated (never why, or by whom). Free of
/// widgets and SDKs.
library;

import 'access_grants.dart';

abstract final class LifecycleCommands {
  static const function = 'identity_lifecycle_command';
  static const deactivate = 'identity.deactivate_membership';
  static const restore = 'identity.restore_membership';
}

/// Why an Admin deactivated a church membership (codes only).
enum DeactivationReason {
  memberRequest('member_request'),
  movedAway('moved_away'),
  churchDecision('church_decision');

  const DeactivationReason(this.wire);
  final String wire;

  static DeactivationReason? fromWire(Object? v) {
    for (final r in values) {
      if (r.wire == v) return r;
    }
    return null;
  }

  String get label => switch (this) {
    memberRequest => 'The member asked to leave',
    movedAway => 'Moved away',
    churchDecision => 'Church decision',
  };
}

/// The signed-in account's own membership status
/// (`api.identity_my_membership_status`).
class MyMembershipStatus {
  const MyMembershipStatus({required this.deactivated, this.churchContact});

  factory MyMembershipStatus.fromJson(Object? json) {
    if (json is! Map ||
        json['deactivated'] is! bool ||
        (json['church_contact'] != null && json['church_contact'] is! String)) {
      throw const FormatException('unexpected membership status');
    }
    return MyMembershipStatus(
      deactivated: json['deactivated'] as bool,
      churchContact: json['church_contact'] as String?,
    );
  }

  final bool deactivated;

  /// The church's operational contact (Q1 setting), null while unset.
  final String? churchContact;
}

class DeactivatedMember {
  const DeactivatedMember({
    required this.memberId,
    required this.displayName,
    required this.revision,
    required this.account,
    required this.pendingObligations,
    required this.reason,
    required this.deactivatedAt,
    required this.ownMember,
    required this.isSynthetic,
  });

  factory DeactivatedMember.fromJson(Object? json) {
    if (json is! Map ||
        json['member_id'] is! String ||
        json['display_name'] is! String ||
        json['revision'] is! int ||
        json['account'] is! String ||
        json['pending_obligations'] is! int ||
        json['own_member'] is! bool ||
        json['is_synthetic'] is! bool) {
      throw const FormatException('unexpected deactivated member');
    }
    return DeactivatedMember(
      memberId: json['member_id'] as String,
      displayName: json['display_name'] as String,
      revision: json['revision'] as int,
      account: json['account'] as String,
      pendingObligations: json['pending_obligations'] as int,
      reason: DeactivationReason.fromWire(json['reason_code']),
      deactivatedAt: json['deactivated_at'] is String
          ? json['deactivated_at'] as String
          : null,
      ownMember: json['own_member'] as bool,
      isSynthetic: json['is_synthetic'] as bool,
    );
  }

  final String memberId;
  final String displayName;
  final int revision;

  /// `app_account`, `no_login` or `access_review`.
  final String account;
  final int pendingObligations;
  final DeactivationReason? reason;
  final String? deactivatedAt;
  final bool ownMember;
  final bool isSynthetic;
}

class LoginHoldItem {
  const LoginHoldItem({
    required this.holdId,
    required this.memberId,
    required this.displayName,
    required this.memberRevision,
    required this.ownMember,
    required this.isSynthetic,
  });

  factory LoginHoldItem.fromJson(Object? json) {
    if (json is! Map ||
        json['hold_id'] is! String ||
        json['member_id'] is! String ||
        json['display_name'] is! String ||
        json['member_revision'] is! int ||
        json['own_member'] is! bool ||
        json['is_synthetic'] is! bool) {
      throw const FormatException('unexpected login hold');
    }
    return LoginHoldItem(
      holdId: json['hold_id'] as String,
      memberId: json['member_id'] as String,
      displayName: json['display_name'] as String,
      memberRevision: json['member_revision'] as int,
      ownMember: json['own_member'] as bool,
      isSynthetic: json['is_synthetic'] as bool,
    );
  }

  final String holdId;
  final String memberId;
  final String displayName;
  final int memberRevision;
  final bool ownMember;
  final bool isSynthetic;
}

/// A pending handover an owning module recorded at deactivation. Resolved
/// in that owner's own workflow, never here.
class HandoverItem {
  const HandoverItem({
    required this.obligationId,
    required this.memberId,
    required this.displayName,
    required this.membershipState,
    required this.ownerModule,
    required this.obligationKind,
  });

  factory HandoverItem.fromJson(Object? json) {
    if (json is! Map ||
        json['obligation_id'] is! String ||
        json['member_id'] is! String ||
        json['display_name'] is! String ||
        json['membership_state'] is! String ||
        json['owner_module'] is! String ||
        json['obligation_kind'] is! String) {
      throw const FormatException('unexpected handover');
    }
    return HandoverItem(
      obligationId: json['obligation_id'] as String,
      memberId: json['member_id'] as String,
      displayName: json['display_name'] as String,
      membershipState: json['membership_state'] as String,
      ownerModule: json['owner_module'] as String,
      obligationKind: json['obligation_kind'] as String,
    );
  }

  final String obligationId;
  final String memberId;
  final String displayName;
  final String membershipState;
  final String ownerModule;
  final String obligationKind;
}

/// The Admin read `api.identity_admin_membership_lifecycle`.
class MembershipLifecycleOverview {
  const MembershipLifecycleOverview({
    required this.deactivated,
    required this.loginHolds,
    required this.handovers,
  });

  factory MembershipLifecycleOverview.fromJson(Object? json) {
    if (json is! Map ||
        json['deactivated'] is! List ||
        json['login_holds'] is! List ||
        json['handovers'] is! List) {
      throw const FormatException('unexpected membership lifecycle overview');
    }
    return MembershipLifecycleOverview(
      deactivated: List.unmodifiable(
        (json['deactivated'] as List).map(DeactivatedMember.fromJson),
      ),
      loginHolds: List.unmodifiable(
        (json['login_holds'] as List).map(LoginHoldItem.fromJson),
      ),
      handovers: List.unmodifiable(
        (json['handovers'] as List).map(HandoverItem.fromJson),
      ),
    );
  }

  final List<DeactivatedMember> deactivated;
  final List<LoginHoldItem> loginHolds;
  final List<HandoverItem> handovers;
}

/// Application port for the reads. Never throws; a fresh request every call.
abstract interface class MembershipLifecycleRepository {
  /// The signed-in account's own status (any trusted session).
  Future<AccessRead<MyMembershipStatus>> fetchMyStatus();

  /// Admin only.
  Future<AccessRead<MembershipLifecycleOverview>> fetchOverview();
}

class UnconfiguredMembershipLifecycleRepository
    implements MembershipLifecycleRepository {
  const UnconfiguredMembershipLifecycleRepository();

  @override
  Future<AccessRead<MyMembershipStatus>> fetchMyStatus() async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<MembershipLifecycleOverview>> fetchOverview() async =>
      const AccessReadDenied(AccessDenial.unavailable);
}
