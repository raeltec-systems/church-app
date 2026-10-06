/// Story 2.3: the signed-in member's current roles and scopes, and the Admin
/// grant roster, as the server reports them. Navigation is built from these
/// reads, but they are presentation only: the server checks the current grant
/// rows on every protected call. Free of widgets and SDKs.
library;

/// Church-wide roles, held independently (wire names).
abstract final class ChurchRoles {
  static const admin = 'admin';
  static const pastor = 'pastor';
  static const media = 'media';
  static const leadPastor = 'lead_pastor';

  /// Display labels; an unknown wire role shows its wire name.
  static String label(String role) => switch (role) {
    admin => 'Admin',
    pastor => 'Pastor',
    media => 'Media',
    leadPastor => 'Lead pastor',
    _ => role,
  };
}

/// One scope grant: a kind registered by its owning module, and a target id.
class ScopeGrant {
  const ScopeGrant({required this.scopeKind, required this.scopeId});
  final String scopeKind;
  final String scopeId;

  @override
  bool operator ==(Object other) =>
      other is ScopeGrant &&
      other.scopeKind == scopeKind &&
      other.scopeId == scopeId;

  @override
  int get hashCode => Object.hash(scopeKind, scopeId);
}

/// One member's current grants (`app.identity_member_grants_json`).
class MemberGrants {
  const MemberGrants({
    required this.memberId,
    required this.revision,
    required this.roles,
    required this.scopes,
  });

  /// Maps the wire object; throws [FormatException] on any unexpected shape.
  factory MemberGrants.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('grants are not an object');
    final id = json['member_id'];
    final revision = json['revision'];
    final roles = json['roles'];
    final scopes = json['scopes'];
    if (id is! String ||
        revision is! int ||
        revision < 1 ||
        roles is! List ||
        scopes is! List ||
        roles.any((r) => r is! String)) {
      throw const FormatException('unexpected grants shape');
    }
    return MemberGrants(
      memberId: id,
      revision: revision,
      roles: List.unmodifiable(roles.cast<String>()),
      scopes: List.unmodifiable(
        scopes.map((s) {
          if (s is! Map ||
              s['scope_kind'] is! String ||
              s['scope_id'] is! String) {
            throw const FormatException('unexpected scope shape');
          }
          return ScopeGrant(
            scopeKind: s['scope_kind'] as String,
            scopeId: s['scope_id'] as String,
          );
        }),
      ),
    );
  }

  final String memberId;

  /// The member's grant-set revision (expected_revision of grant commands).
  final int revision;

  /// Roles in force now, in catalogue order.
  final List<String> roles;
  final List<ScopeGrant> scopes;

  bool hasRole(String role) => roles.contains(role);
  bool get isAdmin => hasRole(ChurchRoles.admin);
}

/// How an Admin roster row's account stands.
enum AccountStanding {
  /// An active account link with no review.
  appAccount,

  /// No account: a member record without a login.
  noLogin,

  /// The link is in review, suspended or held.
  accessReview,
}

class RosterMember {
  const RosterMember({
    required this.memberId,
    required this.displayName,
    required this.isSynthetic,
    required this.account,
    required this.grants,
  });

  factory RosterMember.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('roster row is not an object');
    }
    final id = json['member_id'];
    final name = json['display_name'];
    final synthetic = json['is_synthetic'];
    final account = switch (json['account']) {
      'app_account' => AccountStanding.appAccount,
      'no_login' => AccountStanding.noLogin,
      'access_review' => AccountStanding.accessReview,
      _ => null,
    };
    if (id is! String ||
        name is! String ||
        synthetic is! bool ||
        account == null) {
      throw const FormatException('unexpected roster row shape');
    }
    final grants = MemberGrants.fromJson(json['grants']);
    if (grants.memberId != id) {
      throw const FormatException('roster grants belong to another member');
    }
    return RosterMember(
      memberId: id,
      displayName: name,
      isSynthetic: synthetic,
      account: account,
      grants: grants,
    );
  }

  final String memberId;
  final String displayName;
  final bool isSynthetic;
  final AccountStanding account;
  final MemberGrants grants;

  RosterMember withGrants(MemberGrants g) => RosterMember(
    memberId: memberId,
    displayName: displayName,
    isSynthetic: isSynthetic,
    account: account,
    grants: g,
  );
}

/// A role in the server catalogue; [available] is false while its church
/// setting is unset here (for example the lead-pastor designation).
class RoleOption {
  const RoleOption(this.role, {required this.available});
  final String role;
  final bool available;
}

/// Cursor to the next roster page.
class RosterCursor {
  const RosterCursor(this.afterDisplayName, this.afterMemberId);
  final String afterDisplayName;
  final String afterMemberId;
}

/// One page of `api.identity_admin_member_grants`.
class GrantRoster {
  const GrantRoster({
    required this.members,
    required this.roles,
    required this.next,
  });

  factory GrantRoster.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('roster is not an object');
    final members = json['members'];
    final roles = json['roles'];
    final next = json['next'];
    if (members is! List || roles is! List) {
      throw const FormatException('unexpected roster shape');
    }
    RosterCursor? cursor;
    if (next != null) {
      if (next is! Map ||
          next['after_display_name'] is! String ||
          next['after_member_id'] is! String) {
        throw const FormatException('unexpected roster cursor');
      }
      cursor = RosterCursor(
        next['after_display_name'] as String,
        next['after_member_id'] as String,
      );
    }
    return GrantRoster(
      members: List.unmodifiable(members.map(RosterMember.fromJson)),
      roles: List.unmodifiable(
        roles.map((r) {
          if (r is! Map || r['role'] is! String || r['available'] is! bool) {
            throw const FormatException('unexpected role option');
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

  final List<RosterMember> members;
  final List<RoleOption> roles;
  final RosterCursor? next;
}

/// Why the server denied an access read to the caller.
enum AccessDenial {
  signedOut,

  /// Not a live password session: sign in again.
  untrustedSession,
  notLinked,

  /// Access review required (credential change, hold, dormancy, link review).
  reviewRequired,

  /// The caller has access, but not the role or scope this read needs.
  notGranted,
  unavailable,
}

sealed class AccessRead<T> {
  const AccessRead();
}

final class AccessReadOk<T> extends AccessRead<T> {
  const AccessReadOk(this.value);
  final T value;
}

final class AccessReadDenied<T> extends AccessRead<T> {
  const AccessReadDenied(this.denial);
  final AccessDenial denial;
}

/// No server decision (unreachable, bad payload).
final class AccessReadFailed<T> extends AccessRead<T> {
  const AccessReadFailed({required this.unreachable, this.cause});
  final bool unreachable;
  final Object? cause;
}

/// Application port for the grant reads. Never throws; a fresh request every
/// call.
abstract interface class GrantsRepository {
  /// The caller's own roles and scopes (`api.identity_my_access`).
  Future<AccessRead<MemberGrants>> fetchMyAccess();

  /// Admin only: one roster page (`api.identity_admin_member_grants`).
  Future<AccessRead<GrantRoster>> fetchRoster({RosterCursor? after});
}

class UnconfiguredGrantsRepository implements GrantsRepository {
  const UnconfiguredGrantsRepository();

  @override
  Future<AccessRead<MemberGrants>> fetchMyAccess() async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<GrantRoster>> fetchRoster({RosterCursor? after}) async =>
      const AccessReadDenied(AccessDenial.unavailable);
}

/// The grant command function and command names (1.4 envelope).
abstract final class GrantCommands {
  static const function = 'identity_grant_command';
  static const grantRole = 'identity.grant_role';
  static const revokeRole = 'identity.revoke_role';
  static const grantScope = 'identity.grant_scope';
  static const revokeScope = 'identity.revoke_scope';
}
