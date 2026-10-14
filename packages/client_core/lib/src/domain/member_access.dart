/// The signed-in member's own summary, read through the server's live-access
/// predicate (`api.identity_my_member_summary`). Free of widgets and SDKs.
library;

class MemberSummary {
  const MemberSummary({
    required this.memberId,
    required this.displayName,
    required this.membershipState,
    required this.phoneUsername,
    required this.hasRecoveryEmail,
    required this.isSynthetic,
  });

  /// Maps the wire object; throws [FormatException] on any unexpected shape so
  /// a bad payload is reported as a failure, never shown as data.
  factory MemberSummary.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('member summary is not an object');
    }
    final id = json['member_id'];
    final name = json['display_name'];
    final state = json['membership_state'];
    final phone = json['phone_username'];
    final email = json['has_recovery_email'];
    final synthetic = json['is_synthetic'];
    if (id is! String ||
        name is! String ||
        state is! String ||
        phone is! String ||
        email is! bool ||
        synthetic is! bool) {
      throw const FormatException('unexpected member summary shape');
    }
    return MemberSummary(
      memberId: id,
      displayName: name,
      membershipState: state,
      phoneUsername: phone,
      hasRecoveryEmail: email,
      isSynthetic: synthetic,
    );
  }

  final String memberId;
  final String displayName;
  final String membershipState;
  final String phoneUsername;
  final bool hasRecoveryEmail;
  final bool isSynthetic;
}

/// Why the server denied the caller's own member data.
enum MemberAccessDenial {
  /// No session on this device.
  signedOut,

  /// The session is not a live password session (signed out elsewhere,
  /// revoked, or not a password sign-in): sign in again.
  untrustedSession,

  /// The account has no approved member link.
  notLinked,

  /// Access review required (credential change, hold, dormancy, link review).
  reviewRequired,

  /// Member data is not being served in this environment yet.
  unavailable,
}

sealed class MemberAccessResult {
  const MemberAccessResult();
}

class MemberAccessGranted extends MemberAccessResult {
  const MemberAccessGranted(this.summary);
  final MemberSummary summary;
}

class MemberAccessDenied extends MemberAccessResult {
  const MemberAccessDenied(this.denial);
  final MemberAccessDenial denial;
}

/// The read failed without a server decision (unreachable, bad payload).
class MemberAccessFailed extends MemberAccessResult {
  const MemberAccessFailed({required this.unreachable, this.cause});
  final bool unreachable;
  final Object? cause;
}

/// Application port for the member summary read.
abstract interface class MemberAccessRepository {
  /// Sends a fresh request every call; never throws.
  Future<MemberAccessResult> fetchMySummary();
}

/// No backend configured.
class UnconfiguredMemberAccessRepository implements MemberAccessRepository {
  const UnconfiguredMemberAccessRepository();

  @override
  Future<MemberAccessResult> fetchMySummary() async =>
      const MemberAccessDenied(MemberAccessDenial.unavailable);
}
