/// Story 6.13: church announcements through Content's publication lifecycle.
/// The public projection (`api.content_public_announcements`,
/// `api.content_public_announcement`) is read by everyone, signed in or not,
/// and carries only the current published revision of each announcement,
/// pinned ones first; editors (Media, Pastor, Admin) read every announcement
/// with its live and draft revisions and who notified members
/// (`api.content_staff_announcements`) and change them through
/// `api.content_command`. A notice to members' phones is optional on publish
/// and always carries generic text, never the announcement's. Free of widgets
/// and SDKs.
library;

import 'access_grants.dart';
import 'content_events.dart' show ContentState;
import 'wire_json.dart';

/// A required, non-blank string at [key].
String _text(Map json, String key) {
  final v = wireReq<String>(json, key);
  if (v.trim().isEmpty) throw FormatException('unexpected $key');
  return v;
}

/// One published announcement as everyone reads it: only the current
/// published revision, never a draft, who edited it or who was notified.
class PublicAnnouncement {
  const PublicAnnouncement({
    required this.announcementId,
    required this.title,
    required this.body,
    required this.pinned,
    required this.publicationRevision,
    required this.publishedAt,
  });

  /// Maps the wire object; throws [FormatException] on any other shape.
  factory PublicAnnouncement.fromJson(Object? json) {
    // Keys a later entry adds are ignored, so an older app keeps reading.
    final m = wireMap(json, 'announcement');
    return PublicAnnouncement(
      announcementId: _text(m, 'announcement_id'),
      title: _text(m, 'title'),
      body: _text(m, 'body'),
      pinned: wireReq<bool>(m, 'pinned'),
      publicationRevision: wireRevision(m, 'publication_revision'),
      publishedAt: wireInstant(m, 'published_at'),
    );
  }

  final String announcementId;
  final String title;
  final String body;
  final bool pinned;

  /// The published revision shown (a later publication raises it).
  final int publicationRevision;

  /// When it was last published.
  final DateTime publishedAt;
}

/// `api.content_public_announcements`: the published announcements, pinned
/// first, then the most recently published.
class PublicAnnouncements {
  const PublicAnnouncements({
    required this.announcements,
    required this.truncated,
  });

  factory PublicAnnouncements.fromJson(Object? json) {
    final m = wireMap(json, 'public announcements');
    return PublicAnnouncements(
      announcements: List.unmodifiable(
        wireReq<List>(m, 'announcements').map(PublicAnnouncement.fromJson),
      ),
      truncated: wireReq<bool>(m, 'truncated'),
    );
  }

  final List<PublicAnnouncement> announcements;

  /// More announcements exist than the read returns.
  final bool truncated;

  List<PublicAnnouncement> get pinned => [
    for (final a in announcements)
      if (a.pinned) a,
  ];

  List<PublicAnnouncement> get others => [
    for (final a in announcements)
      if (!a.pinned) a,
  ];
}

/// `api.content_public_announcement`: one announcement, or null when it is
/// not published (never published, withdrawn, archived or unknown).
class PublicAnnouncementRead {
  const PublicAnnouncementRead(this.announcement);

  factory PublicAnnouncementRead.fromJson(Object? json) {
    final m = wireMap(json, 'public announcement');
    if (!m.containsKey('announcement')) {
      throw const FormatException('unexpected public announcement shape');
    }
    final a = m['announcement'];
    return PublicAnnouncementRead(
      a == null ? null : PublicAnnouncement.fromJson(a),
    );
  }

  final PublicAnnouncement? announcement;
}

/// One revision of an announcement as an editor reads it, with who saved it
/// and, once published with a notice, who notified members and how many.
class StaffAnnouncementRevision {
  const StaffAnnouncementRevision({
    required this.revisionNo,
    required this.title,
    required this.body,
    required this.pinned,
    required this.savedAt,
    required this.savedBy,
    this.notifiedAt,
    this.notifiedBy,
    this.notifiedCount,
  });

  factory StaffAnnouncementRevision.fromJson(Object? json) {
    final m = wireMap(json, 'announcement revision');
    final notifiedAt = wireOptInstant(m, 'notified_at');
    final notifiedBy = wireOpt<String>(m, 'notified_by');
    final notifiedCount = wireOpt<int>(m, 'notified_count');
    // A notice is recorded whole (when, who, how many) or not at all.
    if ((notifiedAt == null) != (notifiedBy == null) ||
        (notifiedAt == null) != (notifiedCount == null) ||
        (notifiedCount != null && notifiedCount < 0)) {
      throw const FormatException('unexpected notice record');
    }
    return StaffAnnouncementRevision(
      revisionNo: wireRevision(m, 'revision_no'),
      title: _text(m, 'title'),
      body: _text(m, 'body'),
      pinned: wireReq<bool>(m, 'pinned'),
      savedAt: wireInstant(m, 'saved_at'),
      savedBy: _text(m, 'saved_by'),
      notifiedAt: notifiedAt,
      notifiedBy: notifiedBy,
      notifiedCount: notifiedCount,
    );
  }

  final int revisionNo;
  final String title;
  final String body;
  final bool pinned;
  final DateTime savedAt;

  /// The editor's display name (`Former member` once erased).
  final String savedBy;

  /// When members were notified of this revision (null: never).
  final DateTime? notifiedAt;
  final String? notifiedBy;

  /// How many members a notice was queued for.
  final int? notifiedCount;

  bool get notified => notifiedAt != null;
}

/// One announcement as an editor reads it: the live revision (what everyone
/// sees, or saw before a withdrawal) and the open draft.
class StaffAnnouncement {
  const StaffAnnouncement({
    required this.announcementId,
    required this.revision,
    required this.state,
    required this.createdAt,
    required this.createdBy,
    required this.updatedAt,
    required this.live,
    required this.draft,
    this.publishedAt,
    this.publishedBy,
    this.withdrawnAt,
    this.archivedAt,
  });

  factory StaffAnnouncement.fromJson(Object? json) {
    final m = wireMap(json, 'staff announcement');
    final state = ContentState.parse(m['state']);
    final live = m['live'] == null
        ? null
        : StaffAnnouncementRevision.fromJson(m['live']);
    final draft = m['draft'] == null
        ? null
        : StaffAnnouncementRevision.fromJson(m['draft']);
    // A never-published announcement has its draft and no live revision; a
    // published or withdrawn one has a live revision.
    if ((state == ContentState.draft && (live != null || draft == null)) ||
        ((state == ContentState.published || state == ContentState.withdrawn) &&
            live == null) ||
        (live == null && draft == null)) {
      throw const FormatException('unexpected staff announcement revisions');
    }
    return StaffAnnouncement(
      announcementId: _text(m, 'announcement_id'),
      revision: wireRevision(m),
      state: state,
      createdAt: wireInstant(m, 'created_at'),
      createdBy: _text(m, 'created_by'),
      updatedAt: wireInstant(m, 'updated_at'),
      publishedAt: wireOptInstant(m, 'published_at'),
      publishedBy: wireOpt<String>(m, 'published_by'),
      withdrawnAt: wireOptInstant(m, 'withdrawn_at'),
      archivedAt: wireOptInstant(m, 'archived_at'),
      live: live,
      draft: draft,
    );
  }

  final String announcementId;

  /// The expected revision of the next command on this announcement.
  final int revision;
  final ContentState state;
  final DateTime createdAt;
  final String createdBy;
  final DateTime updatedAt;
  final DateTime? publishedAt;
  final String? publishedBy;
  final DateTime? withdrawnAt;
  final DateTime? archivedAt;
  final StaffAnnouncementRevision? live;
  final StaffAnnouncementRevision? draft;

  /// Published with saved changes not yet published.
  bool get hasChanges => state == ContentState.published && draft != null;

  /// What an edit starts from: the draft, otherwise the live revision.
  StaffAnnouncementRevision get current => (draft ?? live)!;

  /// Published and pinned: shown first to everyone.
  bool get pinnedLive => state == ContentState.published && live!.pinned;

  /// May it be published now (a draft, or a withdrawn announcement)?
  bool get canPublish =>
      state != ContentState.archived &&
      (draft != null || state == ContentState.withdrawn);

  bool get canWithdraw => state == ContentState.published;
  bool get canArchive => state != ContentState.archived;
  bool get canEdit => state != ContentState.archived;

  /// The revision a publish would make live: the open draft, otherwise a
  /// withdrawn announcement's live revision. Null when nothing can be
  /// published.
  StaffAnnouncementRevision? get publishTarget => !canPublish
      ? null
      : draft ?? (state == ContentState.withdrawn ? live : null);

  /// Members were already notified of the revision a publish would make
  /// live: the server refuses a second notice for it.
  bool get notifyDone => publishTarget?.notified ?? false;
}

/// `api.content_staff_announcements`: every announcement, for the editors,
/// how many members a notice would reach now and the generic text phones
/// show for it.
class StaffAnnouncements {
  const StaffAnnouncements({
    required this.capacity,
    required this.audienceMembers,
    required this.audienceLimit,
    required this.audiencePerMinute,
    required this.noticeTitle,
    required this.noticeBody,
    required this.announcements,
    required this.truncated,
  });

  factory StaffAnnouncements.fromJson(Object? json) {
    final m = wireMap(json, 'staff announcements');
    final capacity = wireReq<String>(m, 'capacity');
    if (!const [
      ChurchRoles.admin,
      ChurchRoles.pastor,
      ChurchRoles.media,
    ].contains(capacity)) {
      throw const FormatException('unexpected capacity');
    }
    final audience = wireMap(m['audience'], 'audience');
    final members = wireReq<int>(audience, 'members');
    final limit = wireReq<int>(audience, 'limit');
    final perMinute = wireReq<int>(audience, 'per_minute');
    if (members < 0 || limit < 1 || perMinute < 1) {
      throw const FormatException('unexpected audience');
    }
    final notice = wireMap(m['notice'], 'notice');
    return StaffAnnouncements(
      capacity: capacity,
      audienceMembers: members,
      audienceLimit: limit,
      audiencePerMinute: perMinute,
      noticeTitle: _text(notice, 'title'),
      noticeBody: _text(notice, 'body'),
      announcements: List.unmodifiable(
        wireReq<List>(m, 'announcements').map(StaffAnnouncement.fromJson),
      ),
      truncated: wireReq<bool>(m, 'truncated'),
    );
  }

  /// The role the caller edits with (`admin`, `pastor` or `media`).
  final String capacity;

  /// Members a notice would reach now (approved, reachable by the app).
  final int audienceMembers;

  /// The most members one notice may be queued for.
  final int audienceLimit;

  /// How many of a notice's members fall due per minute (a large notice is
  /// spread so other reminders are not held back).
  final int audiencePerMinute;

  /// What phones show for a notice: the server's registered generic text,
  /// never the announcement's own title or body.
  final String noticeTitle;
  final String noticeBody;
  final List<StaffAnnouncement> announcements;
  final bool truncated;

  /// More members than one notice may reach: publish without a notice.
  bool get audienceTooLarge => audienceMembers > audienceLimit;
}

/// What an editor typed: the whole announcement (a save sends every field).
class AnnouncementInput {
  const AnnouncementInput({
    required this.title,
    required this.body,
    required this.pinned,
  });

  final String title;
  final String body;
  final bool pinned;

  /// The command payload; [announcementId] for a save of an existing one.
  Map<String, Object?> toPayload({String? announcementId}) => {
    'announcement_id': ?announcementId,
    'title': title.trim(),
    'body': body.trim(),
    'pinned': pinned,
  };
}

/// The Content command function and the announcement commands (1.4
/// envelope).
abstract final class AnnouncementCommands {
  static const function = 'content_command';
  static const create = 'content.create_announcement';
  static const save = 'content.save_announcement';
  static const publish = 'content.publish_announcement';
  static const withdraw = 'content.withdraw_announcement';
  static const archive = 'content.archive_announcement';
}

/// Application port for the announcement reads. Never throws.
abstract interface class AnnouncementsRepository {
  /// Everyone (signed in or not): the published announcements.
  Future<AccessRead<PublicAnnouncements>> fetchPublicAnnouncements();

  /// Everyone: one published announcement, or null when it is not public.
  Future<AccessRead<PublicAnnouncementRead>> fetchPublicAnnouncement(
    String announcementId,
  );

  /// Media, Pastor and Admin: every announcement with its revisions.
  Future<AccessRead<StaffAnnouncements>> fetchStaffAnnouncements();
}

class UnconfiguredAnnouncementsRepository implements AnnouncementsRepository {
  const UnconfiguredAnnouncementsRepository();

  @override
  Future<AccessRead<PublicAnnouncements>> fetchPublicAnnouncements() async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<PublicAnnouncementRead>> fetchPublicAnnouncement(
    String announcementId,
  ) async => const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<StaffAnnouncements>> fetchStaffAnnouncements() async =>
      const AccessReadDenied(AccessDenial.unavailable);
}
