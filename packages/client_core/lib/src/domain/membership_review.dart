/// Story 2.5: the Admin's membership review (open applications with
/// staff-only duplicate candidates, member records with or without a login)
/// as the server reports them. Nothing here decides anything: every command
/// and read is checked by the server against the live Admin grant. Free of
/// widgets and SDKs.
library;

import 'access_grants.dart';
import 'membership_application.dart';

/// How the Admin checked the person's identity (wire codes).
enum IdentityCheck {
  establishedRelationship('established_relationship'),
  inPerson('in_person');

  const IdentityCheck(this.wire);
  final String wire;

  String get label => switch (this) {
    establishedRelationship => 'Known to the church (established relationship)',
    inPerson => 'Checked in person',
  };
}

/// Optional rejection reason (codes only; the applicant sees church copy).
enum RejectReason {
  identityNotConfirmed('identity_not_confirmed'),
  notKnownToChurch('not_known_to_church'),
  contactChurchOffice('contact_church_office');

  const RejectReason(this.wire);
  final String wire;

  static RejectReason? fromWire(Object? v) {
    for (final r in values) {
      if (r.wire == v) return r;
    }
    return null;
  }

  String get label => switch (this) {
    identityNotConfirmed => 'Identity could not be confirmed',
    notKnownToChurch => 'Not known to the church',
    contactChurchOffice => 'Please contact the church office',
  };
}

/// What an Admin may ask the applicant for.
enum DetailRequest {
  fullName('full_name'),
  cellChoice('cell_choice'),
  visitChurchOffice('visit_church_office');

  const DetailRequest(this.wire);
  final String wire;

  static DetailRequest? fromWire(Object? v) {
    for (final r in values) {
      if (r.wire == v) return r;
    }
    return null;
  }

  String get label => switch (this) {
    fullName => 'Full name',
    cellChoice => 'Cell group answer',
    visitChurchOffice => 'Visit the church office',
  };
}

enum UnlinkReason {
  accountLost('account_lost'),
  ownershipDispute('ownership_dispute'),
  memberRequest('member_request'),
  phoneReclaim('phone_reclaim');

  const UnlinkReason(this.wire);
  final String wire;

  String get label => switch (this) {
    accountLost => 'Lost or changed phone/account',
    ownershipDispute => 'Ownership dispute',
    memberRequest => 'The member asked',
    phoneReclaim => 'Phone username reclaim',
  };
}

enum ReclaimReason {
  registeredBySomeoneElse('registered_by_someone_else'),
  numberReassigned('number_reassigned');

  const ReclaimReason(this.wire);
  final String wire;

  String get label => switch (this) {
    registeredBySomeoneElse => 'Someone else registered this number',
    numberReassigned => 'The number was reassigned',
  };
}

enum ConsentBasis {
  inPerson('in_person'),
  leaderAssisted('leader_assisted');

  const ConsentBasis(this.wire);
  final String wire;

  String get label => switch (this) {
    inPerson => 'Agreed in person',
    leaderAssisted => 'Agreed with their leader\'s help',
  };
}

/// Whose number a contact route is (it is never a login).
enum ContactOwner {
  member('member'),
  relative('relative'),
  household('household'),
  other('other');

  const ContactOwner(this.wire);
  final String wire;

  static ContactOwner? fromWire(Object? v) {
    for (final r in values) {
      if (r.wire == v) return r;
    }
    return null;
  }

  String get label => switch (this) {
    member => 'Their own number',
    relative => 'A relative\'s number',
    household => 'A household number',
    other => 'Someone else\'s number',
  };
}

AccountStanding _standing(Object? v) => switch (v) {
  'app_account' => AccountStanding.appAccount,
  'no_login' => AccountStanding.noLogin,
  'access_review' => AccountStanding.accessReview,
  _ => throw FormatException('unexpected account standing $v'),
};

/// A STAFF-ONLY duplicate hint: an approved member whose name, contact route
/// or live link resembles the application. Never shown to the applicant and
/// never acted on automatically.
class DuplicateCandidate {
  const DuplicateCandidate({
    required this.memberId,
    required this.displayName,
    required this.account,
    required this.linkEligible,
    required this.signals,
  });

  factory DuplicateCandidate.fromJson(Object? json) {
    if (json is! Map ||
        json['member_id'] is! String ||
        json['display_name'] is! String ||
        json['link_eligible'] is! bool ||
        json['signals'] is! List ||
        (json['signals'] as List).any((s) => s is! String)) {
      throw const FormatException('unexpected duplicate candidate');
    }
    return DuplicateCandidate(
      memberId: json['member_id'] as String,
      displayName: json['display_name'] as String,
      account: _standing(json['account']),
      linkEligible: json['link_eligible'] as bool,
      signals: List.unmodifiable((json['signals'] as List).cast<String>()),
    );
  }

  final String memberId;
  final String displayName;
  final AccountStanding account;

  /// Approved, no live link and no open hold: the server may accept a link.
  final bool linkEligible;

  /// `same_name`, `similar_name`, `contact_route_phone`,
  /// `linked_phone_username`.
  final List<String> signals;

  static String signalLabel(String s) => switch (s) {
    'same_name' => 'Same name',
    'similar_name' => 'Similar name',
    'contact_route_phone' => 'Their contact number is this sign-in number',
    'linked_phone_username' => 'Already signs in with this number',
    _ => s,
  };
}

/// One open application in the Admin queue.
class ReviewApplication {
  const ReviewApplication({
    required this.application,
    required this.priorNotApproved,
    required this.ownAccount,
    required this.candidates,
  });

  factory ReviewApplication.fromJson(Object? json) {
    if (json is! Map ||
        json['prior_not_approved'] is! int ||
        json['own_account'] is! bool ||
        json['candidates'] is! List) {
      throw const FormatException('unexpected review application');
    }
    return ReviewApplication(
      application: MembershipApplication.fromJson(json),
      priorNotApproved: json['prior_not_approved'] as int,
      ownAccount: json['own_account'] as bool,
      candidates: List.unmodifiable(
        (json['candidates'] as List).map(DuplicateCandidate.fromJson),
      ),
    );
  }

  final MembershipApplication application;

  /// Earlier requests from the same account that were not approved.
  final int priorNotApproved;

  /// Sent from the reviewing Admin's own account: they may not decide it.
  final bool ownAccount;
  final List<DuplicateCandidate> candidates;

  String get id => application.applicationId;
}

class QueueCursor {
  const QueueCursor(this.afterSubmittedAt, this.afterApplicationId);
  final String afterSubmittedAt;
  final String afterApplicationId;
}

/// `api.identity_admin_application_queue`.
class ReviewQueue {
  const ReviewQueue({required this.applications, required this.next});

  factory ReviewQueue.fromJson(Object? json) {
    if (json is! Map || json['applications'] is! List) {
      throw const FormatException('unexpected review queue');
    }
    final next = json['next'];
    QueueCursor? cursor;
    if (next != null) {
      if (next is! Map ||
          next['after_submitted_at'] is! String ||
          next['after_application_id'] is! String) {
        throw const FormatException('unexpected queue cursor');
      }
      cursor = QueueCursor(
        next['after_submitted_at'] as String,
        next['after_application_id'] as String,
      );
    }
    return ReviewQueue(
      applications: List.unmodifiable(
        (json['applications'] as List).map(ReviewApplication.fromJson),
      ),
      next: cursor,
    );
  }

  final List<ReviewApplication> applications;
  final QueueCursor? next;
}

class ContactRoute {
  const ContactRoute({
    required this.routeId,
    required this.phone,
    required this.owner,
    this.holderLabel,
  });

  factory ContactRoute.fromJson(Object? json) {
    final owner = json is Map
        ? ContactOwner.fromWire(json['belongs_to'])
        : null;
    if (json is! Map ||
        json['route_id'] is! String ||
        json['phone'] is! String ||
        owner == null ||
        (json['holder_label'] != null && json['holder_label'] is! String)) {
      throw const FormatException('unexpected contact route');
    }
    return ContactRoute(
      routeId: json['route_id'] as String,
      phone: json['phone'] as String,
      owner: owner,
      holderLabel: json['holder_label'] as String?,
    );
  }

  final String routeId;
  final String phone;
  final ContactOwner owner;
  final String? holderLabel;
}

/// An approved member record as the Admin sees it.
class MemberRecord {
  const MemberRecord({
    required this.memberId,
    required this.displayName,
    required this.revision,
    required this.isSynthetic,
    required this.account,
    required this.linkEligible,
    required this.origin,
    required this.contactRoutes,
  });

  factory MemberRecord.fromJson(Object? json) {
    if (json is! Map ||
        json['member_id'] is! String ||
        json['display_name'] is! String ||
        json['revision'] is! int ||
        json['is_synthetic'] is! bool ||
        json['link_eligible'] is! bool ||
        json['origin'] is! String ||
        json['contact_routes'] is! List) {
      throw const FormatException('unexpected member record');
    }
    return MemberRecord(
      memberId: json['member_id'] as String,
      displayName: json['display_name'] as String,
      revision: json['revision'] as int,
      isSynthetic: json['is_synthetic'] as bool,
      account: _standing(json['account']),
      linkEligible: json['link_eligible'] as bool,
      origin: json['origin'] as String,
      contactRoutes: List.unmodifiable(
        (json['contact_routes'] as List).map(ContactRoute.fromJson),
      ),
    );
  }

  final String memberId;
  final String displayName;

  /// The member's revision (expected_revision of identity.unlink_account).
  final int revision;
  final bool isSynthetic;
  final AccountStanding account;
  final bool linkEligible;

  /// `application`, `admin_record` or `other`.
  final String origin;
  final List<ContactRoute> contactRoutes;
}

class MemberCursor {
  const MemberCursor(this.afterDisplayName, this.afterMemberId);
  final String afterDisplayName;
  final String afterMemberId;
}

/// `api.identity_admin_member_search`.
class MemberSearchPage {
  const MemberSearchPage({required this.members, required this.next});

  factory MemberSearchPage.fromJson(Object? json) {
    if (json is! Map || json['members'] is! List) {
      throw const FormatException('unexpected member page');
    }
    final next = json['next'];
    MemberCursor? cursor;
    if (next != null) {
      if (next is! Map ||
          next['after_display_name'] is! String ||
          next['after_member_id'] is! String) {
        throw const FormatException('unexpected member cursor');
      }
      cursor = MemberCursor(
        next['after_display_name'] as String,
        next['after_member_id'] as String,
      );
    }
    return MemberSearchPage(
      members: List.unmodifiable(
        (json['members'] as List).map(MemberRecord.fromJson),
      ),
      next: cursor,
    );
  }

  final List<MemberRecord> members;
  final MemberCursor? next;
}

/// Application port for the Admin review reads. Never throws; a fresh
/// request every call.
abstract interface class ReviewRepository {
  Future<AccessRead<ReviewQueue>> fetchQueue({QueueCursor? after});
  Future<AccessRead<MemberSearchPage>> searchMembers(
    String? query, {
    MemberCursor? after,
  });
}

class UnconfiguredReviewRepository implements ReviewRepository {
  const UnconfiguredReviewRepository();

  @override
  Future<AccessRead<ReviewQueue>> fetchQueue({QueueCursor? after}) async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<MemberSearchPage>> searchMembers(
    String? query, {
    MemberCursor? after,
  }) async => const AccessReadDenied(AccessDenial.unavailable);
}

/// The review command function and command names (1.4 envelope).
abstract final class ReviewCommands {
  static const function = 'identity_review_command';
  static const approve = 'identity.approve_application';
  static const link = 'identity.link_application';
  static const askDetails = 'identity.request_application_details';
  static const reject = 'identity.reject_application';
  static const createMember = 'identity.create_member';
  static const unlink = 'identity.unlink_account';
  static const reclaim = 'identity.reclaim_phone_username';
}
