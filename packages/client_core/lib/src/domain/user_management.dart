import 'access_grants.dart';
import 'membership_review.dart';

/// Membership, login standing and role filters are independent server predicates.
class UserFilter {
  const UserFilter({
    this.query = '',
    this.membership = 'all',
    this.account = 'all',
    this.role,
  });
  final String query;
  final String membership;
  final String account;
  final String? role;
  static const memberships = [
    'all',
    'approved',
    'deactivated',
    'pending',
    'rejected',
  ];
  static const accounts = ['all', 'app_account', 'no_login', 'access_review'];
}

class ManagedMember {
  const ManagedMember({
    required this.record,
    required this.membership,
    required this.grants,
    required this.deletionPending,
    required this.commissionedAdmin,
  });
  factory ManagedMember.fromJson(Object? json) {
    if (json is! Map ||
        !UserFilter.memberships.skip(1).contains(json['membership_state']) ||
        json['deletion_pending'] is! bool ||
        json['commissioned_admin'] is! bool) {
      throw const FormatException('unexpected managed member');
    }
    final record = MemberRecord.fromJson(json);
    final grants = MemberGrants.fromJson(json['grants']);
    if (record.memberId != grants.memberId) {
      throw const FormatException('managed grants belong to another member');
    }
    return ManagedMember(
      record: record,
      membership: json['membership_state'] as String,
      grants: grants,
      deletionPending: json['deletion_pending'] as bool,
      commissionedAdmin: json['commissioned_admin'] as bool,
    );
  }
  final MemberRecord record;
  final String membership;
  final MemberGrants grants;
  final bool deletionPending;
  final bool commissionedAdmin;
  String get id => record.memberId;
  bool get editable =>
      !deletionPending && ['approved', 'deactivated'].contains(membership);
  String get membershipLabel => switch (membership) {
    'approved' => 'Approved',
    'deactivated' => 'Deactivated',
    'pending' => 'Pending',
    'rejected' => 'Not approved',
    _ => 'Unavailable',
  };
  String get accountLabel => switch (record.account) {
    AccountStanding.appAccount => 'App account',
    AccountStanding.noLogin => 'No login',
    AccountStanding.accessReview => 'Access review',
  };
}

class UserDirectoryPage {
  const UserDirectoryPage({
    required this.members,
    required this.roles,
    this.next,
  });
  factory UserDirectoryPage.fromJson(Object? json) {
    if (json is! Map ||
        json['members'] is! List ||
        (json['members'] as List).length > 25 ||
        json['roles'] is! List) {
      throw const FormatException('unexpected user directory');
    }
    final next = json['next'];
    MemberCursor? cursor;
    if (next != null) {
      if (next is! Map ||
          next['after_display_name'] is! String ||
          next['after_member_id'] is! String) {
        throw const FormatException('unexpected user cursor');
      }
      cursor = MemberCursor(
        next['after_display_name'] as String,
        next['after_member_id'] as String,
      );
    }
    return UserDirectoryPage(
      members: List.unmodifiable(
        (json['members'] as List).map(ManagedMember.fromJson),
      ),
      roles: List.unmodifiable(
        (json['roles'] as List).map((r) {
          if (r is! Map || r['role'] is! String || r['available'] is! bool) {
            throw const FormatException('unexpected management role');
          }
          return RoleOption(
            r['role'] as String,
            available: r['available'] as bool,
          );
        }),
      ),
      next: cursor,
    );
  }
  final List<ManagedMember> members;
  final List<RoleOption> roles;
  final MemberCursor? next;
}

class UserDetail {
  const UserDetail(this.member, {required this.ownRecord});
  factory UserDetail.fromJson(Object? json) {
    if (json is! Map || json['own_record'] is! bool) {
      throw const FormatException('unexpected user detail');
    }
    return UserDetail(
      ManagedMember.fromJson(json['member']),
      ownRecord: json['own_record'] as bool,
    );
  }
  final ManagedMember member;
  final bool ownRecord;
}

class UserActivityCursor {
  const UserActivityCursor(this.at, this.source, this.eventId);
  // Keep the exact server timestamp and string id; do not round microseconds.
  final String at;
  final String source;
  final String eventId;
}

class UserActivityEvent {
  const UserActivityEvent({
    required this.source,
    required this.eventId,
    required this.at,
    required this.action,
    required this.actor,
    this.role,
    this.changedFields = const [],
  });
  factory UserActivityEvent.fromJson(Object? json) {
    if (json is! Map ||
        json['source'] is! String ||
        json['event_id'] is! String ||
        json['at'] is! String ||
        DateTime.tryParse(json['at'] as String) == null ||
        json['action'] is! String ||
        json['actor_label'] is! String ||
        (json['role'] != null && json['role'] is! String) ||
        json['changed_fields'] is! List ||
        (json['changed_fields'] as List).any((x) => x is! String)) {
      throw const FormatException('unexpected administrative activity');
    }
    return UserActivityEvent(
      source: json['source'] as String,
      eventId: json['event_id'] as String,
      at: json['at'] as String,
      action: json['action'] as String,
      actor: json['actor_label'] as String,
      role: json['role'] as String?,
      changedFields: List.unmodifiable(
        (json['changed_fields'] as List).cast<String>(),
      ),
    );
  }
  final String source;
  final String eventId;
  final String at;
  final String action;
  final String actor;
  final String? role;
  final List<String> changedFields;
}

class UserActivityPage {
  const UserActivityPage({required this.events, this.next});
  factory UserActivityPage.fromJson(Object? json) {
    if (json is! Map ||
        json['events'] is! List ||
        (json['events'] as List).length > 50) {
      throw const FormatException('unexpected administrative activity page');
    }
    final next = json['next'];
    UserActivityCursor? cursor;
    if (next != null) {
      if (next is! Map ||
          next['after_at'] is! String ||
          next['after_source'] is! String ||
          next['after_event_id'] is! String) {
        throw const FormatException('unexpected activity cursor');
      }
      cursor = UserActivityCursor(
        next['after_at'] as String,
        next['after_source'] as String,
        next['after_event_id'] as String,
      );
    }
    return UserActivityPage(
      events: List.unmodifiable(
        (json['events'] as List).map(UserActivityEvent.fromJson),
      ),
      next: cursor,
    );
  }
  final List<UserActivityEvent> events;
  final UserActivityCursor? next;
}

abstract interface class UserManagementRepository {
  Future<AccessRead<UserDirectoryPage>> directory(
    UserFilter filter, {
    MemberCursor? after,
  });
  Future<AccessRead<UserDetail>> detail(String memberId);
  Future<AccessRead<UserActivityPage>> activity(
    String memberId, {
    UserActivityCursor? after,
  });
}

class UnconfiguredUserManagementRepository implements UserManagementRepository {
  const UnconfiguredUserManagementRepository();
  @override
  Future<AccessRead<UserDirectoryPage>> directory(
    UserFilter filter, {
    MemberCursor? after,
  }) async => const AccessReadDenied(AccessDenial.unavailable);
  @override
  Future<AccessRead<UserDetail>> detail(String memberId) async =>
      const AccessReadDenied(AccessDenial.unavailable);
  @override
  Future<AccessRead<UserActivityPage>> activity(
    String memberId, {
    UserActivityCursor? after,
  }) async => const AccessReadDenied(AccessDenial.unavailable);
}

abstract final class UserManagementCommands {
  static const function = 'identity_user_management_command';
  static const updateProfile = 'identity.update_member_profile';
}
