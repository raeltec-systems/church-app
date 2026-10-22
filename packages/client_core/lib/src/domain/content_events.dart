/// Story 6.1: church events through Content's publication lifecycle. The
/// public projection (`api.content_public_events`, `api.content_public_event`)
/// is read by everyone, signed in or not, and carries only the current
/// published revision of each event; editors (Media, Pastor, Admin) read every
/// event with its live and draft revisions (`api.content_staff_events`) and
/// change them through `api.content_command`. Free of widgets and SDKs.
library;

import 'access_grants.dart';
import 'church_time.dart';
import 'wire_json.dart';

/// Do two instants fall on the same church (Africa/Lusaka) day?
bool churchSameDay(DateTime a, DateTime b) {
  final x = ChurchTime.wall(a), y = ChurchTime.wall(b);
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

/// A required, non-blank string at [key].
String _text(Map json, String key) {
  final v = wireReq<String>(json, key);
  if (v.trim().isEmpty) throw FormatException('unexpected $key');
  return v;
}

/// One published event as everyone reads it: only the current published
/// revision, never a draft or who edited it.
class PublicEvent {
  const PublicEvent({
    required this.eventId,
    required this.title,
    required this.description,
    required this.startsAt,
    required this.endsAt,
    required this.location,
    required this.publicationRevision,
    required this.publishedAt,
    required this.offlineAllowed,
  });

  /// Maps the wire object; throws [FormatException] on any other shape.
  factory PublicEvent.fromJson(Object? json) {
    // Keys a later entry adds (a poster, RSVP) are ignored, so an older app
    // keeps reading the calendar.
    final m = wireMap(json, 'event');
    final starts = wireInstant(m, 'starts_at');
    final ends = wireInstant(m, 'ends_at');
    if (!ends.isAfter(starts)) {
      throw const FormatException('event ends before it starts');
    }
    return PublicEvent(
      eventId: _text(m, 'event_id'),
      title: _text(m, 'title'),
      description: _text(m, 'description'),
      startsAt: starts,
      endsAt: ends,
      location: _text(m, 'location'),
      publicationRevision: wireRevision(m, 'publication_revision'),
      publishedAt: wireInstant(m, 'published_at'),
      offlineAllowed: wireReq<bool>(m, 'offline_allowed'),
    );
  }

  final String eventId;
  final String title;
  final String description;
  final DateTime startsAt;
  final DateTime endsAt;
  final String location;

  /// The published revision shown (a later publication raises it).
  final int publicationRevision;
  final DateTime publishedAt;

  /// Whether the church has cleared this published event for local storage.
  /// The anonymous server projection is the authority; a client never infers
  /// this from the event's fields or publication state.
  final bool offlineAllowed;

  /// Starts and ends on different church days.
  bool get multiDay => !churchSameDay(startsAt, endsAt);

  /// Has it ended at [now]?
  bool endedAt(DateTime now) => !endsAt.isAfter(now);
}

/// `api.content_public_events`: upcoming and ongoing published events,
/// soonest first.
class PublicEvents {
  const PublicEvents({required this.events, required this.truncated});

  factory PublicEvents.fromJson(Object? json) {
    final m = wireMap(json, 'public events');
    final events = wireReq<List>(m, 'events');
    return PublicEvents(
      events: List.unmodifiable(events.map(PublicEvent.fromJson)),
      truncated: wireReq<bool>(m, 'truncated'),
    );
  }

  final List<PublicEvent> events;

  /// More events exist than the read returns (the soonest are listed).
  final bool truncated;
}

/// `api.content_public_event`: one event, or null when it is not on the
/// public calendar (never published, withdrawn, archived or unknown).
class PublicEventRead {
  const PublicEventRead(this.event);

  factory PublicEventRead.fromJson(Object? json) {
    final m = wireMap(json, 'public event');
    if (!m.containsKey('event')) {
      throw const FormatException('unexpected public event shape');
    }
    final e = m['event'];
    return PublicEventRead(e == null ? null : PublicEvent.fromJson(e));
  }

  final PublicEvent? event;
}

/// Where a content item stands in the publication lifecycle.
enum ContentState {
  /// Never published: private to editors.
  draft('draft'),

  /// Its live revision is public.
  published('published'),

  /// Taken off the public calendar; can be published again.
  withdrawn('withdrawn'),

  /// Retired: no further change.
  archived('archived');

  const ContentState(this.wire);
  final String wire;

  static ContentState parse(Object? v) => switch (v) {
    'draft' => draft,
    'published' => published,
    'withdrawn' => withdrawn,
    'archived' => archived,
    _ => throw const FormatException('unexpected state'),
  };
}

/// The five fields of an event.
class EventFields {
  const EventFields({
    required this.title,
    required this.description,
    required this.startsAt,
    required this.endsAt,
    required this.location,
  });

  final String title;
  final String description;
  final DateTime startsAt;
  final DateTime endsAt;
  final String location;

  bool get multiDay => !churchSameDay(startsAt, endsAt);
}

/// One revision of an event as an editor reads it, with who saved it.
class StaffEventRevision {
  const StaffEventRevision({
    required this.revisionNo,
    required this.fields,
    required this.savedAt,
    required this.savedBy,
  });

  factory StaffEventRevision.fromJson(Object? json) {
    final m = wireMap(json, 'event revision');
    final starts = wireInstant(m, 'starts_at');
    final ends = wireInstant(m, 'ends_at');
    if (!ends.isAfter(starts)) {
      throw const FormatException('event ends before it starts');
    }
    return StaffEventRevision(
      revisionNo: wireRevision(m, 'revision_no'),
      fields: EventFields(
        title: _text(m, 'title'),
        description: _text(m, 'description'),
        startsAt: starts,
        endsAt: ends,
        location: _text(m, 'location'),
      ),
      savedAt: wireInstant(m, 'saved_at'),
      savedBy: _text(m, 'saved_by'),
    );
  }

  final int revisionNo;
  final EventFields fields;
  final DateTime savedAt;

  /// The editor's display name (`Former member` once erased).
  final String savedBy;
}

/// One event as an editor reads it: the live revision (what the public
/// calendar shows, or showed before a withdrawal) and the open draft.
class StaffEvent {
  const StaffEvent({
    required this.eventId,
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

  factory StaffEvent.fromJson(Object? json) {
    final m = wireMap(json, 'staff event');
    final state = ContentState.parse(m['state']);
    final live = m['live'] == null
        ? null
        : StaffEventRevision.fromJson(m['live']);
    final draft = m['draft'] == null
        ? null
        : StaffEventRevision.fromJson(m['draft']);
    // A never-published event has its draft and no live revision; a published
    // or withdrawn one has a live revision.
    if ((state == ContentState.draft && (live != null || draft == null)) ||
        ((state == ContentState.published || state == ContentState.withdrawn) &&
            live == null) ||
        (live == null && draft == null)) {
      throw const FormatException('unexpected staff event revisions');
    }
    return StaffEvent(
      eventId: _text(m, 'event_id'),
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

  final String eventId;

  /// The expected revision of the next command on this event.
  final int revision;
  final ContentState state;
  final DateTime createdAt;
  final String createdBy;
  final DateTime updatedAt;
  final DateTime? publishedAt;
  final String? publishedBy;
  final DateTime? withdrawnAt;
  final DateTime? archivedAt;
  final StaffEventRevision? live;
  final StaffEventRevision? draft;

  /// Published with saved changes not yet published.
  bool get hasChanges => state == ContentState.published && draft != null;

  /// What an edit starts from: the draft, otherwise the live revision.
  EventFields get current => (draft ?? live)!.fields;

  /// May it be published now (a draft, or a withdrawn event)?
  bool get canPublish =>
      state != ContentState.archived &&
      (draft != null || state == ContentState.withdrawn);

  bool get canWithdraw => state == ContentState.published;
  bool get canArchive => state != ContentState.archived;
  bool get canEdit => state != ContentState.archived;

  /// The live revision has ended at [now].
  bool endedAt(DateTime now) =>
      live != null && !live!.fields.endsAt.isAfter(now);
}

/// `api.content_staff_events`: every event, for the editors.
class StaffEvents {
  const StaffEvents({
    required this.capacity,
    required this.events,
    required this.truncated,
  });

  factory StaffEvents.fromJson(Object? json) {
    final m = wireMap(json, 'staff events');
    final capacity = wireReq<String>(m, 'capacity');
    if (!const [
      ChurchRoles.admin,
      ChurchRoles.pastor,
      ChurchRoles.media,
    ].contains(capacity)) {
      throw const FormatException('unexpected capacity');
    }
    return StaffEvents(
      capacity: capacity,
      events: List.unmodifiable(
        wireReq<List>(m, 'events').map(StaffEvent.fromJson),
      ),
      truncated: wireReq<bool>(m, 'truncated'),
    );
  }

  /// The role the caller edits with (`admin`, `pastor` or `media`).
  final String capacity;
  final List<StaffEvent> events;
  final bool truncated;
}

/// What an editor typed: the whole event (a save sends every field).
class EventInput {
  const EventInput({
    required this.title,
    required this.description,
    required this.startsAt,
    required this.endsAt,
    required this.location,
  });

  final String title;
  final String description;
  final DateTime startsAt;
  final DateTime endsAt;
  final String location;

  /// The command payload; [eventId] for a save of an existing event.
  Map<String, Object?> toPayload({String? eventId}) {
    String utc(DateTime t) => t.toUtc().toIso8601String();
    return {
      'event_id': ?eventId,
      'title': title.trim(),
      'description': description.trim(),
      'starts_at': utc(startsAt),
      'ends_at': utc(endsAt),
      'location': location.trim(),
    };
  }
}

/// The Content command function and the event commands (1.4 envelope).
abstract final class ContentCommands {
  static const function = 'content_command';
  static const createEvent = 'content.create_event';
  static const saveEvent = 'content.save_event';
  static const publishEvent = 'content.publish_event';
  static const withdrawEvent = 'content.withdraw_event';
  static const archiveEvent = 'content.archive_event';
}

/// Application port for the Content reads. Never throws.
abstract interface class ContentRepository {
  /// Everyone (signed in or not): the published, not yet ended events.
  Future<AccessRead<PublicEvents>> fetchPublicEvents();

  /// Everyone: one published event, or null when it is not public.
  Future<AccessRead<PublicEventRead>> fetchPublicEvent(String eventId);

  /// Media, Pastor and Admin: every event with its revisions.
  Future<AccessRead<StaffEvents>> fetchStaffEvents();
}

class UnconfiguredContentRepository implements ContentRepository {
  const UnconfiguredContentRepository();

  @override
  Future<AccessRead<PublicEvents>> fetchPublicEvents() async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<PublicEventRead>> fetchPublicEvent(String eventId) async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<StaffEvents>> fetchStaffEvents() async =>
      const AccessReadDenied(AccessDenial.unavailable);
}

/// Does [grants] edit church content (Media, Pastor or Admin)? Navigation
/// only; the server checks every read and command.
bool editsContent(MemberGrants? grants) =>
    grants != null &&
    (grants.isAdmin ||
        grants.hasRole(ChurchRoles.pastor) ||
        grants.hasRole(ChurchRoles.media));
