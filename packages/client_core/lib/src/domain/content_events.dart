/// Story 6.1: church events through Content's publication lifecycle. The
/// public projection (`api.content_public_events`, `api.content_public_event`)
/// is read by everyone, signed in or not, and carries only the current
/// published revision of each event; editors (Media, Pastor, Admin) read every
/// event with its live and draft revisions (`api.content_staff_events`) and
/// change them through `api.content_command`. Story 6.11 adds the poster, the
/// RSVP counts (never names), a member's own RSVP
/// (`api.content_my_event_rsvp`), the organisers and the names of the members
/// going, which only an event's organisers and Admins read
/// (`api.content_staff_event_rsvps`). Free of widgets and SDKs.
library;

import 'access_grants.dart';
import 'church_time.dart';
import 'content_banners.dart' show BannerRights, PublicImage, StaffImage;
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

/// Story 6.11: a published event's poster as everyone reads it, once it is
/// placed in the public bucket: the file, its text alternative and whether
/// its rights clear offline use.
class PublicEventPoster {
  const PublicEventPoster({
    required this.image,
    required this.altText,
    required this.offlineAllowed,
  });

  factory PublicEventPoster.fromJson(Object? json) {
    final m = wireMap(json, 'poster');
    return PublicEventPoster(
      image: PublicImage.fromJson(m),
      altText: _text(m, 'alt_text'),
      offlineAllowed: wireReq<bool>(m, 'offline_allowed'),
    );
  }

  final PublicImage image;
  final String altText;
  final bool offlineAllowed;
}

/// Story 6.11: an event's RSVP as everyone reads it: counts only, never who.
class PublicEventRsvp {
  const PublicEventRsvp({
    required this.capacity,
    required this.going,
    required this.spacesLeft,
    required this.full,
    required this.open,
  });

  factory PublicEventRsvp.fromJson(Object? json) {
    final m = wireMap(json, 'rsvp');
    final capacity = wireOpt<int>(m, 'capacity');
    final going = wireReq<int>(m, 'going');
    final left = wireOpt<int>(m, 'spaces_left');
    final full = wireReq<bool>(m, 'full');
    if ((capacity != null && capacity < 1) ||
        going < 0 ||
        (capacity == null) != (left == null) ||
        (left != null && left < 0) ||
        (capacity == null && full)) {
      throw const FormatException('unexpected rsvp');
    }
    return PublicEventRsvp(
      capacity: capacity,
      going: going,
      spacesLeft: left,
      full: full,
      open: wireReq<bool>(m, 'open'),
    );
  }

  /// The number of places; null means no limit.
  final int? capacity;

  /// How many members are going now.
  final int going;

  /// Places still free (null without a limit).
  final int? spacesLeft;

  /// Every place is taken.
  final bool full;

  /// The event has not started: members may still answer.
  final bool open;

  /// "8 of 20 places left", "Full", or "12 going" when there is no limit.
  String get placesText => switch (capacity) {
    null => going == 1 ? '1 going' : '$going going',
    final c when full => 'Full ($c places)',
    final c => '$spacesLeft of $c places left',
  };
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
    this.poster,
    this.rsvp,
  });

  /// Maps the wire object; throws [FormatException] on any other shape.
  factory PublicEvent.fromJson(Object? json) {
    // An absent poster or RSVP reads as none: a server before story 6.11
    // sends neither, and the offline snapshot keeps neither (6.4 shape).
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
      poster: m['poster'] == null
          ? null
          : PublicEventPoster.fromJson(m['poster']),
      rsvp: m['rsvp'] == null ? null : PublicEventRsvp.fromJson(m['rsvp']),
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

  /// Story 6.11: the poster, once placed in the public bucket (null: none).
  final PublicEventPoster? poster;

  /// Story 6.11: the RSVP counts when the event takes RSVPs (null: it does
  /// not, or this copy came from the offline snapshot).
  final PublicEventRsvp? rsvp;

  /// Starts and ends on different church days.
  bool get multiDay => !churchSameDay(startsAt, endsAt);

  /// Has it ended at [now]?
  bool endedAt(DateTime now) => !endsAt.isAfter(now);

  /// Has it started at [now]?
  bool startedAt(DateTime now) => !startsAt.isAfter(now);
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
    this.poster,
    this.posterRights,
    this.posterAltText,
    this.rsvpEnabled = false,
    this.rsvpCapacity,
  });

  factory StaffEventRevision.fromJson(Object? json) {
    final m = wireMap(json, 'event revision');
    final starts = wireInstant(m, 'starts_at');
    final ends = wireInstant(m, 'ends_at');
    if (!ends.isAfter(starts)) {
      throw const FormatException('event ends before it starts');
    }
    // Story 6.11 keys: absent from a server before it (no poster, no RSVP).
    final enabled = wireOpt<bool>(m, 'rsvp_enabled') ?? false;
    final capacity = wireOpt<int>(m, 'rsvp_capacity');
    if (capacity != null && (capacity < 1 || !enabled)) {
      throw const FormatException('unexpected rsvp_capacity');
    }
    final alt = wireOpt<String>(m, 'poster_alt_text');
    if (alt != null && alt.trim().isEmpty) {
      throw const FormatException('unexpected poster_alt_text');
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
      poster: m['poster'] == null ? null : StaffImage.fromJson(m['poster']),
      posterRights: m['poster_rights'] == null
          ? null
          : BannerRights.fromJson(m['poster_rights']),
      posterAltText: alt,
      rsvpEnabled: enabled,
      rsvpCapacity: capacity,
    );
  }

  final int revisionNo;
  final EventFields fields;
  final DateTime savedAt;

  /// The editor's display name (`Former member` once erased).
  final String savedBy;

  /// Story 6.11: the revision's poster upload (null: none).
  final StaffImage? poster;

  /// The rights record the poster cites, with the server's display check.
  final BannerRights? posterRights;

  /// The poster's text alternative.
  final String? posterAltText;

  /// Whether members may RSVP to this revision.
  final bool rsvpEnabled;

  /// The number of places (null: no limit).
  final int? rsvpCapacity;
}

/// Story 6.11: where a published event's poster stands in the public bucket.
enum EventPosterState {
  /// In the public bucket: phones show it.
  shown,

  /// It should be public: the next file sync places it.
  waiting,

  /// Its upload or rights record no longer allows it.
  blocked,

  /// The event is over: the next file sync removes it.
  ended;

  static EventPosterState? parse(Object? v) => switch (v) {
    null => null,
    'shown' => shown,
    'waiting' => waiting,
    'blocked' => blocked,
    'ended' => ended,
    _ => throw const FormatException('unexpected public_poster'),
  };
}

/// Story 6.11: a member named as one of an event's organisers (or who may be).
class EventOrganiser {
  const EventOrganiser({required this.memberId, required this.name});

  factory EventOrganiser.fromJson(Object? json) {
    final m = wireMap(json, 'organiser');
    return EventOrganiser(
      memberId: _text(m, 'member_id'),
      name: _text(m, 'name'),
    );
  }

  final String memberId;
  final String name;
}

List<EventOrganiser> _organisers(Map m, String key) => List.unmodifiable(
  (wireOpt<List>(m, key) ?? const []).map(EventOrganiser.fromJson),
);

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
    this.publicPoster,
    this.rsvpGoing = 0,
    this.organisers = const [],
    this.seesNames = false,
  });

  factory StaffEvent.fromJson(Object? json) {
    final m = wireMap(json, 'staff event');
    final going = wireOpt<int>(m, 'rsvp_going') ?? 0;
    if (going < 0) throw const FormatException('unexpected rsvp_going');
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
      publicPoster: EventPosterState.parse(m['public_poster']),
      rsvpGoing: going,
      organisers: _organisers(m, 'organisers'),
      seesNames: wireOpt<bool>(m, 'sees_names') ?? false,
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

  /// Story 6.11: the published poster's place in the public bucket (null:
  /// not published, or no poster).
  final EventPosterState? publicPoster;

  /// How many members are going now (counts only, for every editor).
  final int rsvpGoing;

  /// The event's organisers: they and Admins read who is going.
  final List<EventOrganiser> organisers;

  /// Whether the reader sees the names of the members going (an Admin or
  /// one of the organisers) and may change the organisers.
  final bool seesNames;

  /// Published with saved changes not yet published.
  bool get hasChanges => state == ContentState.published && draft != null;

  /// What an edit starts from: the draft, otherwise the live revision.
  EventFields get current => (draft ?? live)!.fields;

  /// The revision an edit starts from (draft, otherwise live).
  StaffEventRevision get currentRevision => (draft ?? live)!;

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
    this.organiserOptions = const [],
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
      organiserOptions: _organisers(m, 'organiser_options'),
    );
  }

  /// The role the caller edits with (`admin`, `pastor` or `media`).
  final String capacity;
  final List<StaffEvent> events;
  final bool truncated;

  /// Story 6.11: everyone who may be named an organiser (they edit events).
  final List<EventOrganiser> organiserOptions;
}

/// The most organisers an event can have.
const maxEventOrganisers = 10;

/// The most places an event's RSVP can have.
const maxEventPlaces = 10000;

/// What an editor typed: the whole event (a save sends every field; an
/// RSVP that is off and a poster that is absent are sent as absent keys,
/// which the server reads as off and none).
class EventInput {
  const EventInput({
    required this.title,
    required this.description,
    required this.startsAt,
    required this.endsAt,
    required this.location,
    this.rsvpEnabled = false,
    this.rsvpCapacity,
    this.posterAssetId,
    this.posterRightsId,
    this.posterAltText,
  });

  final String title;
  final String description;
  final DateTime startsAt;
  final DateTime endsAt;
  final String location;

  /// Story 6.11: members may RSVP, within [rsvpCapacity] places (null: no
  /// limit).
  final bool rsvpEnabled;
  final int? rsvpCapacity;

  /// Story 6.11 (saves only): the poster upload, its rights record and its
  /// text alternative, all three or none.
  final String? posterAssetId;
  final String? posterRightsId;
  final String? posterAltText;

  /// The command payload; [eventId] for a save of an existing event (only a
  /// save carries the poster: an upload needs the event to exist).
  Map<String, Object?> toPayload({String? eventId}) {
    String utc(DateTime t) => t.toUtc().toIso8601String();
    final alt = posterAltText?.trim();
    return {
      'event_id': ?eventId,
      'title': title.trim(),
      'description': description.trim(),
      'starts_at': utc(startsAt),
      'ends_at': utc(endsAt),
      'location': location.trim(),
      if (rsvpEnabled) ...{
        'rsvp_enabled': true,
        'rsvp_capacity': ?rsvpCapacity,
      },
      if (eventId != null && posterAssetId != null) ...{
        'poster_asset_id': posterAssetId,
        'poster_rights_id': ?posterRightsId,
        if (alt != null && alt.isNotEmpty) 'poster_alt_text': alt,
      },
    };
  }
}

/// Story 6.11: a member's answer to an event.
enum RsvpState {
  going('going'),
  cancelled('cancelled'),

  /// The member's church membership ended before the event.
  released('released');

  const RsvpState(this.wire);
  final String wire;

  static RsvpState? parse(Object? v) => switch (v) {
    null => null,
    'going' => going,
    'cancelled' => cancelled,
    'released' => released,
    _ => throw const FormatException('unexpected rsvp_state'),
  };
}

/// Story 6.11, `api.content_my_event_rsvp`: the caller's own RSVP to an
/// event (approved members with live access only).
class MyEventRsvp {
  const MyEventRsvp({
    required this.eventId,
    required this.state,
    required this.updatedAt,
  });

  factory MyEventRsvp.fromJson(Object? json) {
    final m = wireMap(json, 'my rsvp');
    final state = RsvpState.parse(m['rsvp_state']);
    final updated = wireOptInstant(m, 'updated_at');
    if ((state == null) != (updated == null)) {
      throw const FormatException('unexpected my rsvp');
    }
    return MyEventRsvp(
      eventId: _text(m, 'event_id'),
      state: state,
      updatedAt: updated,
    );
  }

  final String eventId;

  /// Null when the member never answered.
  final RsvpState? state;
  final DateTime? updatedAt;

  bool get going => state == RsvpState.going;
}

/// Story 6.11: one member going, as an organiser or an Admin reads it.
class EventAttendee {
  const EventAttendee({required this.name, required this.rsvpAt});

  factory EventAttendee.fromJson(Object? json) {
    final m = wireMap(json, 'attendee');
    return EventAttendee(
      name: _text(m, 'name'),
      rsvpAt: wireInstant(m, 'rsvp_at'),
    );
  }

  /// The member's display name (`Former member` once erased).
  final String name;

  /// When they said they are going.
  final DateTime rsvpAt;
}

/// Story 6.11: who is going to one event (organisers and Admins only).
class EventRsvpNames {
  const EventRsvpNames({
    required this.eventId,
    required this.capacity,
    required this.going,
    required this.attendees,
    required this.truncated,
  });

  factory EventRsvpNames.fromJson(Object? json) {
    final m = wireMap(json, 'rsvps');
    final capacity = wireOpt<int>(m, 'capacity');
    final going = wireReq<int>(m, 'going');
    final attendees = List<EventAttendee>.unmodifiable(
      wireReq<List>(m, 'attendees').map(EventAttendee.fromJson),
    );
    if ((capacity != null && capacity < 1) ||
        going < 0 ||
        attendees.length > going) {
      throw const FormatException('unexpected rsvps');
    }
    return EventRsvpNames(
      eventId: _text(m, 'event_id'),
      capacity: capacity,
      going: going,
      attendees: attendees,
      truncated: wireReq<bool>(m, 'truncated'),
    );
  }

  final String eventId;
  final int? capacity;
  final int going;

  /// Earliest first.
  final List<EventAttendee> attendees;

  /// More are going than the list names.
  final bool truncated;
}

/// Story 6.11, `api.content_staff_event_rsvps`: the names, or null when the
/// event is unknown.
class StaffEventRsvpsRead {
  const StaffEventRsvpsRead(this.rsvps);

  factory StaffEventRsvpsRead.fromJson(Object? json) {
    final m = wireMap(json, 'staff rsvps');
    if (!m.containsKey('rsvps')) {
      throw const FormatException('unexpected staff rsvps shape');
    }
    final r = m['rsvps'];
    return StaffEventRsvpsRead(r == null ? null : EventRsvpNames.fromJson(r));
  }

  final EventRsvpNames? rsvps;
}

/// The Content command function and the event commands (1.4 envelope).
abstract final class ContentCommands {
  static const function = 'content_command';
  static const createEvent = 'content.create_event';
  static const saveEvent = 'content.save_event';
  static const publishEvent = 'content.publish_event';
  static const withdrawEvent = 'content.withdraw_event';
  static const archiveEvent = 'content.archive_event';

  /// Story 6.11 (an Admin or one of the event's organisers).
  static const setEventOrganisers = 'content.set_event_organisers';

  /// Story 6.11, member commands (approved members with live access).
  static const rsvpEvent = 'content.rsvp_event';
  static const cancelRsvp = 'content.cancel_rsvp';
}

/// Application port for the Content reads. Never throws.
abstract interface class ContentRepository {
  /// Everyone (signed in or not): the published, not yet ended events.
  Future<AccessRead<PublicEvents>> fetchPublicEvents();

  /// Everyone: one published event, or null when it is not public.
  Future<AccessRead<PublicEventRead>> fetchPublicEvent(String eventId);

  /// Media, Pastor and Admin: every event with its revisions.
  Future<AccessRead<StaffEvents>> fetchStaffEvents();

  /// Story 6.11, approved members: their own RSVP to an event.
  Future<AccessRead<MyEventRsvp>> fetchMyEventRsvp(String eventId);

  /// Story 6.11, an Admin or one of the event's organisers: who is going.
  Future<AccessRead<StaffEventRsvpsRead>> fetchStaffEventRsvps(String eventId);
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

  @override
  Future<AccessRead<MyEventRsvp>> fetchMyEventRsvp(String eventId) async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<StaffEventRsvpsRead>> fetchStaffEventRsvps(
    String eventId,
  ) async => const AccessReadDenied(AccessDenial.unavailable);
}

/// Does [grants] edit church content (Media, Pastor or Admin)? Navigation
/// only; the server checks every read and command.
bool editsContent(MemberGrants? grants) =>
    grants != null &&
    (grants.isAdmin ||
        grants.hasRole(ChurchRoles.pastor) ||
        grants.hasRole(ChurchRoles.media));
