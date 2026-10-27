/// Test doubles for the client ports, shared by the package and app tests.
/// Not for production composition roots.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import 'src/application/providers.dart';
import 'src/application/hymn_controllers.dart';
import 'src/domain/platform_status.dart';

import 'src/domain/access_grants.dart';
import 'src/domain/account_auth.dart';
import 'src/domain/assisted_recovery.dart';
import 'src/domain/cell_meetings.dart';
import 'src/domain/cell_programmes.dart';
import 'src/domain/cell_membership.dart';
import 'src/domain/commands.dart';
import 'src/domain/content_announcements.dart';
import 'src/domain/content_banners.dart';
import 'src/domain/content_events.dart';
import 'src/domain/content_sermons.dart';
import 'src/domain/content_bible.dart';
import 'src/domain/hymn_book.dart';
import 'src/domain/hymn_lists.dart';
import 'src/domain/public_content_cache.dart';
import 'src/domain/content_giving.dart';
import 'src/domain/credential_review.dart';
import 'src/domain/duties.dart';
import 'src/domain/followups.dart';
import 'src/domain/member_access.dart';
import 'src/domain/membership_application.dart';
import 'src/domain/member_deletion.dart';
import 'src/domain/membership_lifecycle.dart';
import 'src/domain/membership_review.dart';
import 'src/domain/password_recovery.dart';
import 'src/domain/recovery_email.dart';
import 'src/domain/fixture_counter.dart';
import 'src/domain/inbox.dart';
import 'src/domain/notification_settings.dart';
import 'src/domain/push_messaging.dart';
import 'src/domain/session.dart';

/// One command the fake gateway received; complete it to answer.
class SentCommand {
  SentCommand(this.function, this.request);
  final String function;
  final CommandRequest request;
  final Completer<CommandOutcome> _answer = Completer<CommandOutcome>();
  Future<CommandOutcome> get _future => _answer.future;

  /// The exact wire body that was sent.
  Map<String, Object?> get wire => request.toJson();

  void confirm(Object? data, int revision) => _answer.complete(
    CommandConfirmed(
      CommandSuccess(
        requestId: request.requestId,
        data: data,
        revision: revision,
      ),
    ),
  );

  void refuse(
    ErrorCode code, {
    Map<String, String> fieldErrors = const {},
    Optional<int> currentRevision = const Optional.absent(),
  }) => _answer.complete(
    CommandRefused(
      CommandError(
        requestId: request.requestId,
        code: code,
        message: code.wireName,
        fieldErrors: fieldErrors,
        currentRevision: currentRevision,
      ),
    ),
  );

  void unknown() => _answer.complete(const CommandUnknownOutcome('test'));
}

/// [CommandGateway] whose every call waits for the test to answer it.
class FakeCommandGateway implements CommandGateway {
  final List<SentCommand> sent = [];

  @override
  Future<CommandOutcome> send(String function, CommandRequest request) {
    final c = SentCommand(function, request);
    sent.add(c);
    return c._future;
  }
}

/// [SessionRepository] the test switches between accounts.
class FakeSession implements SessionRepository {
  FakeSession([this._current]);
  String? _current;
  final _changes = StreamController<String?>.broadcast();

  void switchTo(String? accountId) {
    _current = accountId;
    _changes.add(accountId);
  }

  @override
  String? get currentAccountId => _current;

  @override
  Stream<String?> get accountChanges => _changes.stream;
}

/// [FixtureCounterReader] answered by the test; null = unavailable.
class FakeFixtureReader implements FixtureCounterReader {
  FixtureCounter? next;
  int calls = 0;

  @override
  Future<FixtureCounter> read(String counterId) async {
    calls++;
    final n = next;
    if (n == null) throw const FixtureReadUnavailable('test: no read endpoint');
    return n;
  }
}

/// Deterministic request ids: `00000000-0000-4000-8000-00000000000N`.
class SequentialRequestIds implements RequestIds {
  int _n = 0;
  @override
  String next() {
    _n++;
    return '00000000-0000-4000-8000-${_n.toString().padLeft(12, '0')}';
  }
}

/// `data` of a synthetic fixture counter success envelope.
Map<String, Object?> fixtureCounterData({
  String id = '11111111-1111-4111-8111-111111111111',
  String intentKey = 'synthetic-demo',
  int value = 0,
}) => {
  'id': id,
  'intent_key': intentKey,
  'value': value,
  'is_synthetic': true,
  'updated_at': '2026-10-03T12:00:00Z',
};

/// A configured platform status that answers immediately.
class FakePlatformStatus implements PlatformStatusRepository {
  @override
  Future<PlatformStatus?> fetch() async => PlatformStatus(
    status: 'operational',
    message: 'SYNTHETIC tracer status',
    isSynthetic: true,
    updatedAt: DateTime.utc(2026, 10, 3, 9, 5),
  );
}

/// One sign-up or sign-in the fake gateway received; complete it to answer.
class SentAuth {
  SentAuth(this.createAccount, this.phoneE164);
  final bool createAccount;
  final String phoneE164;
  final Completer<AuthOutcome> _answer = Completer<AuthOutcome>();
}

/// [AccountAuthGateway] whose calls wait for the test. A success switches
/// [session] to the given account, as Supabase Auth would.
class FakeAccountAuth implements AccountAuthGateway {
  FakeAccountAuth(this.session);
  final FakeSession session;
  final List<SentAuth> sent = [];
  int signOuts = 0;

  SentAuth get last => sent.last;

  void succeed(String accountId) {
    last._answer.complete(AuthSucceeded(accountId));
    session.switchTo(accountId);
  }

  void fail(AuthFailure failure, {List<String> reasons = const []}) =>
      last._answer.complete(AuthFailed(failure, serverReasons: reasons));

  Future<AuthOutcome> _record(bool create, String phone) {
    final a = SentAuth(create, phone);
    sent.add(a);
    return a._answer.future;
  }

  @override
  Future<AuthOutcome> signUp({
    required String phoneE164,
    required String password,
  }) => _record(true, phoneE164);

  @override
  Future<AuthOutcome> signIn({
    required String phoneE164,
    required String password,
  }) => _record(false, phoneE164);

  @override
  Future<void> signOut() async {
    signOuts++;
    session.switchTo(null);
  }
}

/// [MemberAccessRepository] answered by the test; each call waits for
/// [answer] unless [next] is set.
class FakeMemberAccess implements MemberAccessRepository {
  MemberAccessResult? next;
  final List<Completer<MemberAccessResult>> pending = [];
  int calls = 0;

  void answer(MemberAccessResult result) =>
      pending.removeAt(0).complete(result);

  @override
  Future<MemberAccessResult> fetchMySummary() {
    calls++;
    final n = next;
    if (n != null) return Future.value(n);
    final c = Completer<MemberAccessResult>();
    pending.add(c);
    return c.future;
  }
}

/// A synthetic member summary.
MemberSummary syntheticMemberSummary({
  String name = 'SYNTHETIC Member One',
  String phone = '+12025550101',
}) => MemberSummary(
  memberId: '22222222-2222-4222-8222-222222222222',
  displayName: name,
  membershipState: 'approved',
  phoneUsername: phone,
  hasRecoveryEmail: false,
  isSynthetic: true,
);

/// [GrantsRepository] answered by the test. [myAccess] answers every
/// my-access read at once (default: not linked, so no grant-driven
/// destinations); roster reads wait for [answerRoster] unless [roster] is set.
class FakeGrants implements GrantsRepository {
  AccessRead<MemberGrants> myAccess = const AccessReadDenied(
    AccessDenial.notLinked,
  );
  AccessRead<GrantRoster>? roster;
  final List<Completer<AccessRead<GrantRoster>>> pendingRoster = [];
  final List<RosterCursor?> rosterCalls = [];
  int myAccessCalls = 0;

  void answerRoster(AccessRead<GrantRoster> r) =>
      pendingRoster.removeAt(0).complete(r);

  /// When set, every my-access read waits for it before answering.
  Completer<void>? myAccessGate;

  @override
  Future<AccessRead<MemberGrants>> fetchMyAccess() async {
    myAccessCalls++;
    final gate = myAccessGate;
    if (gate != null) await gate.future;
    return myAccess;
  }

  @override
  Future<AccessRead<GrantRoster>> fetchRoster({RosterCursor? after}) {
    rosterCalls.add(after);
    final r = roster;
    if (r != null) return Future.value(r);
    final c = Completer<AccessRead<GrantRoster>>();
    pendingRoster.add(c);
    return c.future;
  }
}

/// Synthetic grants of one member.
MemberGrants syntheticGrants({
  String memberId = '22222222-2222-4222-8222-222222222222',
  int revision = 1,
  List<String> roles = const [],
  List<ScopeGrant> scopes = const [],
  AdminGrantTenure? adminTenure,
}) => MemberGrants(
  memberId: memberId,
  revision: revision,
  roles: roles,
  scopes: scopes,
  adminTenure: adminTenure,
);

/// The wire form of [syntheticGrants] (a grant command's success `data`).
Map<String, Object?> grantsData({
  String memberId = '33333333-3333-4333-8333-333333333333',
  int revision = 2,
  List<String> roles = const [],
}) => {
  'member_id': memberId,
  'revision': revision,
  'roles': roles,
  'scopes': const <Object?>[],
};

/// A synthetic roster page with one member (no login state variations).
GrantRoster syntheticRoster({
  String memberId = '33333333-3333-4333-8333-333333333333',
  String name = 'SYNTHETIC Member Two',
  int revision = 1,
  List<String> roles = const [],
  bool leadPastorAvailable = true,
}) => GrantRoster(
  members: [
    RosterMember(
      memberId: memberId,
      displayName: name,
      isSynthetic: true,
      account: AccountStanding.appAccount,
      grants: syntheticGrants(
        memberId: memberId,
        revision: revision,
        roles: roles,
      ),
    ),
  ],
  roles: [
    const RoleOption('admin', available: true),
    const RoleOption('pastor', available: true),
    const RoleOption('media', available: true),
    RoleOption('lead_pastor', available: leadPastorAvailable),
  ],
  next: null,
);

/// [MembershipRepository] answered by the test (story 2.4). [mine] and
/// [options] answer every read at once; [calls] counts my-application reads.
class FakeMembership implements MembershipRepository {
  AccessRead<MyApplication> mine = const AccessReadOk(
    MyApplication(
      application: null,
      privacyNotice: PrivacyNotice(version: 'draft-2026-10-07', draft: true),
      accepting: true,
    ),
  );
  AccessRead<List<CellOption>> options = AccessReadOk(syntheticCellOptions);
  int calls = 0;

  @override
  Future<AccessRead<MyApplication>> fetchMyApplication() async {
    calls++;
    return mine;
  }

  @override
  Future<AccessRead<List<CellOption>>> fetchCellOptions() async => options;
}

/// The SYNTHETIC sign-up options of the local seed.
const syntheticCellOptions = <CellOption>[
  CellOption(
    cellId: '00000000-0000-4000-c000-00000000c241',
    label: 'SYNTHETIC Riverside',
    broadArea: 'SYNTHETIC North side',
    revision: 1,
  ),
  CellOption(
    cellId: '00000000-0000-4000-c000-00000000c242',
    label: 'SYNTHETIC Hilltop',
    broadArea: 'SYNTHETIC East side',
    revision: 1,
  ),
];

/// The wire form of a synthetic application (a command's success `data`).
Map<String, Object?> applicationData({
  String id = '44444444-4444-4444-8444-444444444444',
  int revision = 1,
  String churchStatus = 'awaiting_approval',
  String name = 'SYNTHETIC Applicant',
  Map<String, Object?> cellChoice = const {
    'choice': 'cell',
    'cell_id': '00000000-0000-4000-c000-00000000c241',
    'cell_revision': 1,
  },
}) => {
  'application_id': id,
  'revision': revision,
  'application_state': churchStatus == 'details_requested'
      ? 'needs_details'
      : 'submitted',
  'church_status': churchStatus,
  'full_name': name,
  'phone_username': '+12025550181',
  'cell_choice': cellChoice,
  'cell_status': cellChoice['choice'] == 'cell' ? 'requested' : 'follow_up',
  'privacy_notice_version': 'draft-2026-10-07',
  'is_synthetic': true,
  'submitted_at': '2026-10-07T04:30:00.000000Z',
  'updated_at': '2026-10-07T04:30:00.000000Z',
};

/// A my-application answer holding [applicationData].
AccessRead<MyApplication> myApplicationWith(Map<String, Object?> data) =>
    AccessReadOk(
      MyApplication(
        application: MembershipApplication.fromJson(data),
        privacyNotice: const PrivacyNotice(
          version: 'draft-2026-10-07',
          draft: true,
        ),
        accepting: true,
      ),
    );

/// [ReviewRepository] answered by the test (story 2.5). [queue] and
/// [search] answer every read at once; the call lists record what was asked.
class FakeReview implements ReviewRepository {
  AccessRead<ReviewQueue> queue = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  AccessRead<MemberSearchPage> search = const AccessReadOk(
    MemberSearchPage(members: [], next: null),
  );
  final List<QueueCursor?> queueCalls = [];
  final List<String?> searchCalls = [];

  @override
  Future<AccessRead<ReviewQueue>> fetchQueue({QueueCursor? after}) async {
    queueCalls.add(after);
    return queue;
  }

  @override
  Future<AccessRead<MemberSearchPage>> searchMembers(
    String? query, {
    MemberCursor? after,
  }) async {
    searchCalls.add(query);
    return search;
  }
}

/// The wire form of one Admin queue entry (story 2.5).
Map<String, Object?> reviewApplicationData({
  String id = '55555555-5555-4555-8555-555555555555',
  int revision = 1,
  String name = 'SYNTHETIC Ruth Mwale',
  int priorNotApproved = 0,
  bool ownAccount = false,
  List<Map<String, Object?>> candidates = const [],
}) => {
  ...applicationData(id: id, revision: revision, name: name),
  'cell_choice': const {
    'choice': 'not_sure',
    'cell_id': null,
    'cell_revision': null,
  },
  'cell_status': 'follow_up',
  'prior_not_approved': priorNotApproved,
  'own_account': ownAccount,
  'candidates': candidates,
};

/// A queue page with the given entries.
AccessRead<ReviewQueue> reviewQueueWith(List<Map<String, Object?>> entries) =>
    AccessReadOk(ReviewQueue.fromJson({'applications': entries, 'next': null}));

/// The wire form of an Admin member record (story 2.5).
Map<String, Object?> memberRecordData({
  String id = '66666666-6666-4666-8666-666666666666',
  String name = 'SYNTHETIC Ruth Mwale',
  int revision = 1,
  String account = 'no_login',
  bool linkEligible = true,
  List<Map<String, Object?>> routes = const [],
}) => {
  'member_id': id,
  'display_name': name,
  'membership_state': 'approved',
  'revision': revision,
  'is_synthetic': true,
  'account': account,
  'link_eligible': linkEligible,
  'origin': 'admin_record',
  'contact_routes': routes,
};

/// [CellsRepository] answered by the test (story 2.6). Each field answers
/// every read at once; the counters record how often each was asked.
class FakeCells implements CellsRepository {
  AccessRead<MyCell> mine = const AccessReadDenied(AccessDenial.notLinked);
  AccessRead<LeaderQueue> leader = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  AccessRead<CellAdminOverview> admin = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  AccessRead<CellMeetingsBoard> meetings = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  int mineCalls = 0;
  int leaderCalls = 0;
  int adminCalls = 0;
  int meetingsCalls = 0;

  /// Story 5.3: the programme read, whatever meeting is asked for.
  AccessRead<ProgrammeRead> programme = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  final programmeAsked = <String>[];

  /// Story 5.4: the member read of a published programme.
  AccessRead<MeetingProgrammeRead> meetingProgramme = const AccessReadDenied(
    AccessDenial.notGranted,
  );

  @override
  Future<AccessRead<CellMeetingsBoard>> fetchMeetings() async {
    meetingsCalls++;
    return meetings;
  }

  @override
  Future<AccessRead<ProgrammeRead>> fetchProgramme(String meetingId) async {
    programmeAsked.add(meetingId);
    return programme;
  }

  @override
  Future<AccessRead<MeetingProgrammeRead>> fetchMeetingProgramme(
    String meetingId,
  ) async => meetingProgramme;

  @override
  Future<AccessRead<MyCell>> fetchMyCell() async {
    mineCalls++;
    return mine;
  }

  @override
  Future<AccessRead<LeaderQueue>> fetchLeaderQueue() async {
    leaderCalls++;
    return leader;
  }

  @override
  Future<AccessRead<CellAdminOverview>> fetchAdminOverview() async {
    adminCalls++;
    return admin;
  }
}

/// [ContentRepository] answered by the test (story 6.1). Each field answers
/// every read at once; the lists record what was asked.
class FakeContent implements ContentRepository {
  AccessRead<PublicEvents> publicEvents = AccessReadOk(
    PublicEvents.fromJson(const {'events': <Object?>[], 'truncated': false}),
  );

  /// The detail answer by event id; an id not listed answers `{event: null}`.
  final Map<String, AccessRead<PublicEventRead>> publicEvent = {};
  AccessRead<StaffEvents> staffEvents = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  int publicEventsCalls = 0;
  int staffEventsCalls = 0;
  final publicEventAsked = <String>[];

  @override
  Future<AccessRead<PublicEvents>> fetchPublicEvents() async {
    publicEventsCalls++;
    return publicEvents;
  }

  @override
  Future<AccessRead<PublicEventRead>> fetchPublicEvent(String eventId) async {
    publicEventAsked.add(eventId);
    return publicEvent[eventId] ?? const AccessReadOk(PublicEventRead(null));
  }

  @override
  Future<AccessRead<StaffEvents>> fetchStaffEvents() async {
    staffEventsCalls++;
    return staffEvents;
  }

  /// Story 6.11: the member's own RSVP by event id; an id not listed answers
  /// "never answered".
  final Map<String, AccessRead<MyEventRsvp>> myRsvp = {};
  final myRsvpAsked = <String>[];

  /// Story 6.11: the names by event id; an id not listed is refused
  /// (`not_granted`), as for an editor who is not an organiser.
  final Map<String, AccessRead<StaffEventRsvpsRead>> staffRsvps = {};
  final staffRsvpsAsked = <String>[];

  @override
  Future<AccessRead<MyEventRsvp>> fetchMyEventRsvp(String eventId) async {
    myRsvpAsked.add(eventId);
    return myRsvp[eventId] ??
        AccessReadOk(
          MyEventRsvp.fromJson({
            'event_id': eventId,
            'rsvp_state': null,
            'updated_at': null,
          }),
        );
  }

  @override
  Future<AccessRead<StaffEventRsvpsRead>> fetchStaffEventRsvps(
    String eventId,
  ) async {
    staffRsvpsAsked.add(eventId);
    return staffRsvps[eventId] ??
        const AccessReadDenied(AccessDenial.notGranted);
  }
}

/// [BibleRepository] answered by tests (story 6.6).
class FakeBible implements BibleRepository {
  AccessRead<PublicBibleTranslations> translations = AccessReadOk(
    const PublicBibleTranslations([]),
  );
  AccessRead<StaffBibleTranslations> staff = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  final Map<(String, BibleChapterRef), AccessRead<PublicBibleChapter?>>
  chapters = {};
  final Map<String, AccessRead<BibleVerseManifest>> manifests = {};
  int translationCalls = 0;
  int staffCalls = 0;
  final chapterCalls = <(String, BibleChapterRef)>[];

  @override
  Future<AccessRead<PublicBibleTranslations>> fetchPublicTranslations() async {
    translationCalls++;
    return translations;
  }

  @override
  Future<AccessRead<PublicBibleChapter?>> fetchPublicChapter(
    String translationId,
    BibleChapterRef reference,
  ) async {
    final key = (translationId, reference);
    chapterCalls.add(key);
    return chapters[key] ?? const AccessReadOk(null);
  }

  @override
  Future<AccessRead<BibleVerseManifest>> fetchVerseManifest(
    String code,
  ) async =>
      manifests[code] ?? const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<StaffBibleTranslations>> fetchStaffTranslations() async {
    staffCalls++;
    return staff;
  }
}

Map<String, Object?> publicSermonSeriesData({
  String id = '91919191-9191-4191-8191-919191919191',
  String title = 'SYNTHETIC Living hope',
  bool poster = false,
  bool posterOffline = true,
  int rightsRevision = 1,
}) => {
  'series_id': id,
  'title': title,
  'description': 'SYNTHETIC Teaching for the church.',
  'alt_text': 'SYNTHETIC blue sky poster',
  'poster': poster
      ? {
          'path': '$id/1/poster.png',
          'media_type': 'image/png',
          'width': 960,
          'height': 540,
          'rights_revision': rightsRevision,
          'offline_allowed': posterOffline,
        }
      : null,
  'publication_revision': 1,
  'published_at': '2099-09-01T08:00:00Z',
  'offline_allowed': true,
};

Map<String, Object?> publicSermonData({
  String id = '92929292-9292-4292-8292-929292929292',
  String title = 'SYNTHETIC Hope for today',
  String speaker = 'SYNTHETIC Speaker One',
  Object? series,
  String? videoId = 'abcdefghijk',
  String notes = '# SYNTHETIC Notes\n\nKeep **hope**.\n\n- Read the scripture.',
  int revision = 1,
}) => {
  'sermon_id': id,
  'title': title,
  'speaker': speaker,
  'sermon_date': '2099-09-01',
  'scripture_reference': 'John 1:1',
  'notes': notes,
  'series': series,
  'youtube_video_id': videoId,
  'rights_revision': videoId == null ? null : 1,
  'publication_revision': revision,
  'published_at': '2099-09-01T08:00:00Z',
  'offline_allowed': true,
};

class FakeSermons implements SermonsRepository {
  AccessRead<PublicSermons> catalog = const AccessReadOk(
    PublicSermons(sermons: [], series: []),
  );
  AccessRead<StaffSermons> staff = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  AccessRead<StaffSermonSeriesCatalog> staffSeries = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  final details = <String, AccessRead<PublicSermonRead>>{};
  int catalogCalls = 0, staffCalls = 0, seriesCalls = 0;
  final detailCalls = <String>[];
  @override
  Future<AccessRead<PublicSermons>> fetchPublicSermons() async {
    catalogCalls++;
    return catalog;
  }

  @override
  Future<AccessRead<PublicSermonRead>> fetchPublicSermon(
    String sermonId,
  ) async {
    detailCalls.add(sermonId);
    return details[sermonId] ?? const AccessReadOk(PublicSermonRead(null));
  }

  @override
  Future<AccessRead<StaffSermons>> fetchStaffSermons() async {
    staffCalls++;
    return staff;
  }

  @override
  Future<AccessRead<StaffSermonSeriesCatalog>> fetchStaffSeries() async {
    seriesCalls++;
    return staffSeries;
  }
}

class FakeBibleTranslationPackageSource
    implements BibleTranslationPackageSource {
  String worldEnglishBibleVpl = '';

  @override
  Future<String> loadWorldEnglishBibleVpl() async => worldEnglishBibleVpl;
}

/// [HymnListsRepository] answered by the test (story 6.8): favourites, this
/// Sunday's public list and the editors' read. Each field answers every read
/// at once; the counters record how often each was asked.
class FakeHymnLists implements HymnListsRepository {
  AccessRead<MyHymnFavourites> favourites = const AccessReadOk(
    MyHymnFavourites.empty,
  );
  AccessRead<PublicSundayHymns> sunday = const AccessReadOk(
    PublicSundayHymns(
      sunday: '2099-01-04',
      edition: null,
      items: [],
      publicationRevision: null,
    ),
  );
  AccessRead<StaffSundayHymns> staff = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  int favouritesCalls = 0, sundayCalls = 0, staffCalls = 0;

  @override
  Future<AccessRead<MyHymnFavourites>> fetchMyFavourites() async {
    favouritesCalls++;
    return favourites;
  }

  @override
  Future<AccessRead<PublicSundayHymns>> fetchPublicSundayHymns() async {
    sundayCalls++;
    return sunday;
  }

  @override
  Future<AccessRead<StaffSundayHymns>> fetchStaffSundayHymns() async {
    staffCalls++;
    return staff;
  }
}

/// This Sunday's SYNTHETIC public list for [sunday] (`YYYY-MM-DD`) with
/// [items] of the test book.
PublicSundayHymns testSundayHymns(String sunday, List<String> items) =>
    PublicSundayHymns(
      sunday: sunday,
      edition: items.isEmpty ? null : 'test-1',
      items: items,
      publicationRevision: items.isEmpty ? null : 1,
    );

/// The built-in hymn book as tests read it (story 6.7): a small SYNTHETIC
/// book (placeholder words, never hymn text) unless a test sets [book] or
/// [error].
class FakeHymnBookSource implements HymnBookSource {
  HymnBook book = testHymnBook();

  /// When set, every load throws it (the "could not be opened" state).
  Object? error;
  int loads = 0;

  @override
  Future<HymnBook> load() async {
    loads++;
    final failure = error;
    if (failure != null) throw failure;
    return book;
  }
}

/// A SYNTHETIC test book: [hymns] hymns titled "SYNTHETIC hymn N" (1 and 2 in
/// "SYNTHETIC opening", the rest in "SYNTHETIC praise"), each with two placeholder
/// verses, hymn 1 with an English title, a key and a chorus; then [choruses]
/// single-stanza choruses titled "SYNTHETIC chorus N" in "SYNTHETIC choruses".
HymnBook testHymnBook({int hymns = 3, int choruses = 2}) => HymnBook(
  format: 1,
  edition: 'test-1',
  title: 'SYNTHETIC hymn book',
  language: 'toi',
  items: [
    for (var n = 1; n <= hymns; n++)
      Hymn(
        kind: HymnKind.hymn,
        number: n,
        section: n <= 2 ? 'SYNTHETIC opening' : 'SYNTHETIC praise',
        title: 'SYNTHETIC hymn $n',
        original: n == 1 ? 'SYNTHETIC ORIGINAL' : null,
        reference: n == 1 ? 'Z.H. 1' : null,
        key: n == 1 ? 'A flat' : null,
        verses: [
          'SYNTHETIC hymn $n verse one, line one,\nSYNTHETIC hymn $n verse one, line two.',
          'SYNTHETIC hymn $n verse two, line one,\nSYNTHETIC hymn $n verse two, line two.',
        ],
        choruses: [
          if (n == 1)
            const HymnChorus(
              fromVerse: 1,
              text: 'SYNTHETIC chorus line one,\nSYNTHETIC chorus line two.',
            ),
        ],
      ),
    for (var n = 1; n <= choruses; n++)
      Hymn(
        kind: HymnKind.chorus,
        number: n,
        section: 'SYNTHETIC choruses',
        title: 'SYNTHETIC chorus $n',
        original: null,
        reference: null,
        key: null,
        verses: [
          'SYNTHETIC chorus $n stanza, line one,\nSYNTHETIC chorus $n stanza.',
        ],
        choruses: const [],
      ),
  ],
);

/// The wire form of one published event as everyone reads it (story 6.1);
/// by default the two-day SYNTHETIC Harvest Thanksgiving (Sat 10 Oct 2099
/// 09:00 to Sun 11 Oct 12:00 church time).
Map<String, Object?> publicEventData({
  String eventId = '71717171-7171-4171-8171-717171717171',
  String title = 'SYNTHETIC Harvest Thanksgiving',
  String description = 'SYNTHETIC two days of thanksgiving services.',
  String startsAt = '2099-10-10T07:00:00.000000Z',
  String endsAt = '2099-10-11T10:00:00.000000Z',
  String location = 'SYNTHETIC Main sanctuary',
  int publicationRevision = 1,
  String publishedAt = '2099-09-01T08:00:00.000000Z',
  bool offlineAllowed = true,
  Map<String, Object?>? poster,
  Map<String, Object?>? rsvp,
}) => {
  'event_id': eventId,
  'title': title,
  'description': description,
  'starts_at': startsAt,
  'ends_at': endsAt,
  'location': location,
  'publication_revision': publicationRevision,
  'published_at': publishedAt,
  'offline_allowed': offlineAllowed,
  'poster': ?poster,
  'rsvp': ?rsvp,
};

/// Story 6.11: the wire form of a public event's poster.
Map<String, Object?> publicEventPosterData({
  String eventId = '71717171-7171-4171-8171-717171717171',
  int width = 1920,
  int height = 1080,
  String altText = 'SYNTHETIC harvest baskets on the altar',
  bool offlineAllowed = false,
}) => {
  'path': 'event/$eventId/r1/poster.png',
  'media_type': 'image/png',
  'width': width,
  'height': height,
  'alt_text': altText,
  'offline_allowed': offlineAllowed,
};

/// Story 6.11: the wire form of a public event's RSVP counts.
Map<String, Object?> publicEventRsvpData({
  int? capacity = 2,
  int going = 0,
  bool open = true,
}) => {
  'capacity': capacity,
  'going': going,
  'spaces_left': capacity == null
      ? null
      : (capacity - going < 0 ? 0 : capacity - going),
  'full': capacity != null && going >= capacity,
  'open': open,
};

/// Story 6.11: the wire form of `api.content_my_event_rsvp`.
Map<String, Object?> myEventRsvpData({
  String eventId = '71717171-7171-4171-8171-717171717171',
  String? state,
  String updatedAt = '2099-09-02T08:00:00.000000Z',
}) => {
  'event_id': eventId,
  'rsvp_state': state,
  'updated_at': state == null ? null : updatedAt,
};

/// Story 6.11: the wire form of `api.content_staff_event_rsvps` naming
/// [names] (earliest first).
Map<String, Object?> staffEventRsvpsData(
  List<String> names, {
  String eventId = '71717171-7171-4171-8171-717171717171',
  int? capacity = 2,
}) => {
  'rsvps': {
    'event_id': eventId,
    'capacity': capacity,
    'going': names.length,
    'attendees': [
      for (final (i, n) in names.indexed)
        {'name': n, 'rsvp_at': '2099-09-0${(i % 8) + 1}T08:00:00.000000Z'},
    ],
    'truncated': false,
  },
};

/// The wire form of `api.content_public_events` holding [events].
Map<String, Object?> publicEventsData(
  List<Map<String, Object?>> events, {
  bool truncated = false,
}) => {'events': events, 'truncated': truncated};

/// The wire form of one event revision as editors read it.
Map<String, Object?> staffEventRevisionData({
  int revisionNo = 1,
  String title = 'SYNTHETIC Harvest Thanksgiving',
  String description = 'SYNTHETIC two days of thanksgiving services.',
  String startsAt = '2099-10-10T07:00:00.000000Z',
  String endsAt = '2099-10-11T10:00:00.000000Z',
  String location = 'SYNTHETIC Main sanctuary',
  String savedAt = '2099-09-01T07:00:00.000000Z',
  String savedBy = 'SYNTHETIC Media Phiri',
  Map<String, Object?>? poster,
  Map<String, Object?>? posterRights,
  String? posterAltText,
  bool? rsvpEnabled,
  int? rsvpCapacity,
}) => {
  'revision_no': revisionNo,
  'title': title,
  'description': description,
  'starts_at': startsAt,
  'ends_at': endsAt,
  'location': location,
  'saved_at': savedAt,
  'saved_by': savedBy,
  'poster': ?poster,
  'poster_rights': ?posterRights,
  'poster_alt_text': ?posterAltText,
  'rsvp_enabled': ?rsvpEnabled,
  'rsvp_capacity': ?rsvpCapacity,
};

/// The wire form of one event as editors read it ([live] and [draft] are
/// revision objects or null).
Map<String, Object?> staffEventData({
  String eventId = '71717171-7171-4171-8171-717171717171',
  int revision = 1,
  String state = 'draft',
  Map<String, Object?>? live,
  Map<String, Object?>? draft,
  String? publishedBy,
  String? publishedAt,
  String? withdrawnAt,
  String? archivedAt,
  String? publicPoster,
  int? rsvpGoing,
  List<Map<String, Object?>>? organisers,
  bool? seesNames,
}) => {
  'event_id': eventId,
  'revision': revision,
  'state': state,
  'created_at': '2099-09-01T07:00:00.000000Z',
  'created_by': 'SYNTHETIC Media Phiri',
  'updated_at': '2099-09-01T07:00:00.000000Z',
  'published_at': publishedAt,
  'published_by': publishedBy,
  'withdrawn_at': withdrawnAt,
  'archived_at': archivedAt,
  'live': live,
  'draft': draft,
  'public_poster': ?publicPoster,
  'rsvp_going': ?rsvpGoing,
  'organisers': ?organisers,
  'sees_names': ?seesNames,
};

/// Story 6.11: the wire form of an organiser (or an organiser option).
Map<String, Object?> eventOrganiserData(String memberId, String name) => {
  'member_id': memberId,
  'name': name,
};

/// The wire form of `api.content_staff_events`.
Map<String, Object?> staffEventsData(
  List<Map<String, Object?>> events, {
  String capacity = 'media',
  bool truncated = false,
  List<Map<String, Object?>>? organiserOptions,
}) => {
  'capacity': capacity,
  'events': events,
  'truncated': truncated,
  'organiser_options': ?organiserOptions,
};

/// [GivingRepository] answered by the test (story 6.3). Each field answers
/// every read at once; the counters and list record what was asked.
class FakeGiving implements GivingRepository {
  AccessRead<PublicGivingMethods> publicMethods = AccessReadOk(
    PublicGivingMethods.fromJson(publicGivingMethodsData([])),
  );

  /// The detail answer by method id; an id not listed answers
  /// `{sample: true, method: null}`.
  final Map<String, AccessRead<PublicGivingMethodRead>> publicMethod = {};
  AccessRead<StaffGivingMethods> staffMethods = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  int publicMethodsCalls = 0;
  int staffMethodsCalls = 0;
  final publicMethodAsked = <String>[];

  @override
  Future<AccessRead<PublicGivingMethods>> fetchPublicGivingMethods() async {
    publicMethodsCalls++;
    return publicMethods;
  }

  @override
  Future<AccessRead<PublicGivingMethodRead>> fetchPublicGivingMethod(
    String methodId,
  ) async {
    publicMethodAsked.add(methodId);
    return publicMethod[methodId] ??
        AccessReadOk(
          PublicGivingMethodRead.fromJson(const {
            'sample': true,
            'method': null,
          }),
        );
  }

  @override
  Future<AccessRead<StaffGivingMethods>> fetchStaffGivingMethods() async {
    staffMethodsCalls++;
    return staffMethods;
  }
}

/// The wire form of one published mobile money method as everyone reads it
/// (story 6.3); by default SAMPLE Airtel Money with a merchant ID and a
/// starting code. [details] replaces the destination rows.
Map<String, Object?> publicGivingMethodData({
  String methodId = '61616161-6161-4161-8161-616161616161',
  String methodType = 'mobile_money',
  String name = 'SAMPLE Airtel Money',
  String? purpose = 'Tithes & Offerings',
  String? currency = 'ZMW',
  List<Map<String, Object?>>? details,
  String? ussdCode = '*115#',
  List<String> steps = const [
    'Dial the starting code on your Airtel line.',
    'Choose Make payments, then Pay merchant.',
    'Enter the merchant ID shown above, then the amount.',
    'Check the beneficiary name, then enter your PIN to confirm.',
  ],
  String? note,
  String contact = 'SAMPLE church office, +260 97 000 0000',
  String verifiedOn = '2026-09-28',
  int publicationRevision = 1,
  String publishedAt = '2026-09-28T08:00:00.000000Z',
  bool unsafe = false,
  Map<String, Object?>? logo,
}) => {
  'method_id': methodId,
  'method_type': methodType,
  'name': name,
  'purpose': purpose,
  'currency': currency,
  'details':
      details ??
      [
        {
          'key': 'beneficiary',
          'value': 'SAMPLE Brethren in Christ Church Kafue',
        },
        {'key': 'merchant_id', 'value': '000000'},
      ],
  'ussd_code': ussdCode,
  'steps': steps,
  'note': note,
  'contact': contact,
  'verified_on': verifiedOn,
  'publication_revision': publicationRevision,
  'published_at': publishedAt,
  'unsafe': unsafe,
  'logo': logo,
};

/// The wire form of a published SAMPLE bank transfer method.
Map<String, Object?> publicBankMethodData({
  String methodId = '62626262-6262-4262-8262-626262626262',
  String name = 'SAMPLE Bank transfer',
  String? purpose = 'Building Project',
  String contact = 'SAMPLE church office, +260 97 000 0000',
}) => publicGivingMethodData(
  methodId: methodId,
  methodType: 'bank',
  name: name,
  purpose: purpose,
  ussdCode: null,
  contact: contact,
  details: const [
    {'key': 'bank_name', 'value': 'SAMPLE Bank Zambia'},
    {'key': 'beneficiary', 'value': 'SAMPLE Brethren in Christ Church Kafue'},
    {'key': 'account_number', 'value': '0000 0000 0000'},
    {'key': 'branch', 'value': 'Kafue'},
    {'key': 'reference', 'value': 'BUILDING + your name'},
  ],
  steps: const [
    'Open your banking app or visit a branch.',
    'Add the church as a new beneficiary using the details above.',
    'Use the reference shown so the treasurer can identify the purpose.',
  ],
);

/// The wire form of `api.content_public_giving_methods` holding [methods].
Map<String, Object?> publicGivingMethodsData(
  List<Map<String, Object?>> methods, {
  bool sample = true,
  bool truncated = false,
}) => {'sample': sample, 'methods': methods, 'truncated': truncated};

/// The wire form of a revision's verification (story 6.3).
Map<String, Object?> givingVerificationData({
  String verifiedBy = 'SYNTHETIC Admin Banda',
  bool verifiedByYou = false,
  String verifiedAt = '2026-09-28T09:00:00.000000Z',
  String testedOn = '2026-09-28',
  String testMethod =
      'SYNTHETIC the provider showed the beneficiary name for this ID.',
}) => {
  'verified_at': verifiedAt,
  'verified_by': verifiedBy,
  'verified_by_you': verifiedByYou,
  'tested_on': testedOn,
  'test_method': testMethod,
};

/// The wire form of one giving revision as Admins read it: every key of
/// its [methodType] (mobile money by default).
Map<String, Object?> staffGivingRevisionData({
  int revisionNo = 1,
  String methodType = 'mobile_money',
  String name = 'SAMPLE Airtel Money',
  String? purpose = 'Tithes & Offerings',
  String? currency = 'ZMW',
  List<String> steps = const [
    'Dial the starting code on your Airtel line.',
    'Enter the merchant ID shown above, then the amount.',
  ],
  String? note,
  String contact = 'SAMPLE church office, +260 97 000 0000',
  String beneficiary = 'SAMPLE Brethren in Christ Church Kafue',
  String identifierKind = 'merchant',
  String identifier = '000000',
  String? ussdCode = '*115#',
  String bankName = 'SAMPLE Bank Zambia',
  String accountNumber = '0000 0000 0000',
  String savedAt = '2026-09-27T07:00:00.000000Z',
  String savedBy = 'SYNTHETIC Admin Mwale',
  bool savedByYou = false,
  String? publishedAt,
  String? publishedBy,
  Map<String, Object?>? verification,
}) => {
  'revision_no': revisionNo,
  'name': name,
  'purpose': purpose,
  'currency': currency,
  'steps': steps,
  'note': note,
  'contact': contact,
  if (methodType == 'mobile_money') ...{
    'beneficiary': beneficiary,
    'identifier_kind': identifierKind,
    'identifier': identifier,
    'ussd_code': ussdCode,
  },
  if (methodType == 'bank') ...{
    'bank_name': bankName,
    'beneficiary': beneficiary,
    'account_number': accountNumber,
    'branch': null,
    'branch_code': null,
    'swift_code': null,
    'reference': null,
  },
  'saved_at': savedAt,
  'saved_by': savedBy,
  'saved_by_you': savedByYou,
  'published_at': publishedAt,
  'published_by': publishedBy,
  'verification': verification,
};

/// The wire form of one giving method as Admins read it ([live] and
/// [draft] are revision objects or null; [position] null when archived).
Map<String, Object?> staffGivingMethodData({
  String methodId = '61616161-6161-4161-8161-616161616161',
  String methodType = 'mobile_money',
  int? position = 1,
  int revision = 1,
  String state = 'draft',
  Map<String, Object?>? live,
  Map<String, Object?>? draft,
  String? publishedBy,
  String? publishedAt,
  String? withdrawnAt,
  String? archivedAt,
}) => {
  'method_id': methodId,
  'method_type': methodType,
  'position': position,
  'revision': revision,
  'state': state,
  'created_at': '2026-09-27T07:00:00.000000Z',
  'created_by': 'SYNTHETIC Admin Mwale',
  'updated_at': '2026-09-27T07:00:00.000000Z',
  'published_at': publishedAt,
  'published_by': publishedBy,
  'withdrawn_at': withdrawnAt,
  'archived_at': archivedAt,
  'live': live,
  'draft': draft,
};

/// The wire form of `api.content_staff_giving_methods`.
Map<String, Object?> staffGivingMethodsData(
  List<Map<String, Object?>> methods, {
  bool truncated = false,
}) => {'capacity': 'admin', 'methods': methods, 'truncated': truncated};

/// [AnnouncementsRepository] answered by the test (story 6.13). Each field
/// answers every read at once; the lists record what was asked.
class FakeAnnouncements implements AnnouncementsRepository {
  AccessRead<PublicAnnouncements> publicAnnouncements = AccessReadOk(
    PublicAnnouncements.fromJson(publicAnnouncementsData(const [])),
  );

  /// The detail answer by id; an id not listed answers `{announcement: null}`.
  final Map<String, AccessRead<PublicAnnouncementRead>> publicAnnouncement = {};
  AccessRead<StaffAnnouncements> staffAnnouncements = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  int publicAnnouncementsCalls = 0;
  int staffAnnouncementsCalls = 0;
  final publicAnnouncementAsked = <String>[];

  @override
  Future<AccessRead<PublicAnnouncements>> fetchPublicAnnouncements() async {
    publicAnnouncementsCalls++;
    return publicAnnouncements;
  }

  @override
  Future<AccessRead<PublicAnnouncementRead>> fetchPublicAnnouncement(
    String announcementId,
  ) async {
    publicAnnouncementAsked.add(announcementId);
    return publicAnnouncement[announcementId] ??
        const AccessReadOk(PublicAnnouncementRead(null));
  }

  @override
  Future<AccessRead<StaffAnnouncements>> fetchStaffAnnouncements() async {
    staffAnnouncementsCalls++;
    return staffAnnouncements;
  }
}

/// The wire form of one published announcement as everyone reads it (story
/// 6.13); by default the pinned SYNTHETIC harvest offering notice.
Map<String, Object?> publicAnnouncementData({
  String announcementId = '73737373-7373-4373-8373-737373737373',
  String title = 'SYNTHETIC Harvest offering on Sunday',
  String body = 'SYNTHETIC Bring your harvest offering to the 09:00 service.',
  bool pinned = true,
  int publicationRevision = 1,
  String publishedAt = '2099-09-01T08:00:00.000000Z',
}) => {
  'announcement_id': announcementId,
  'title': title,
  'body': body,
  'pinned': pinned,
  'publication_revision': publicationRevision,
  'published_at': publishedAt,
};

/// The wire form of `api.content_public_announcements` holding [items].
Map<String, Object?> publicAnnouncementsData(
  List<Map<String, Object?>> items, {
  bool truncated = false,
}) => {'announcements': items, 'truncated': truncated};

/// The wire form of one announcement revision as editors read it.
Map<String, Object?> staffAnnouncementRevisionData({
  int revisionNo = 1,
  String title = 'SYNTHETIC Harvest offering on Sunday',
  String body = 'SYNTHETIC Bring your harvest offering to the 09:00 service.',
  bool pinned = true,
  String savedAt = '2099-09-01T07:00:00.000000Z',
  String savedBy = 'SYNTHETIC Media Phiri',
  String? notifiedAt,
  String? notifiedBy,
  int? notifiedCount,
}) => {
  'revision_no': revisionNo,
  'title': title,
  'body': body,
  'pinned': pinned,
  'saved_at': savedAt,
  'saved_by': savedBy,
  'notified_at': notifiedAt,
  'notified_by': notifiedBy,
  'notified_count': notifiedCount,
};

/// The wire form of one announcement as editors read it ([live] and [draft]
/// are revision objects or null).
Map<String, Object?> staffAnnouncementData({
  String announcementId = '73737373-7373-4373-8373-737373737373',
  int revision = 1,
  String state = 'draft',
  Map<String, Object?>? live,
  Map<String, Object?>? draft,
  String? publishedBy,
  String? publishedAt,
  String? withdrawnAt,
  String? archivedAt,
}) => {
  'announcement_id': announcementId,
  'revision': revision,
  'state': state,
  'created_at': '2099-09-01T07:00:00.000000Z',
  'created_by': 'SYNTHETIC Media Phiri',
  'updated_at': '2099-09-01T07:00:00.000000Z',
  'published_at': publishedAt,
  'published_by': publishedBy,
  'withdrawn_at': withdrawnAt,
  'archived_at': archivedAt,
  'live': live,
  'draft': draft,
};

/// The wire form of `api.content_staff_announcements`.
Map<String, Object?> staffAnnouncementsData(
  List<Map<String, Object?>> items, {
  String capacity = 'media',
  int audienceMembers = 12,
  int audienceLimit = 1000,
  int perMinute = 20,
  String noticeTitle = 'Church announcement',
  String noticeBody =
      'The church has posted an announcement. Open the app to read it.',
  bool truncated = false,
}) => {
  'capacity': capacity,
  'audience': {
    'members': audienceMembers,
    'limit': audienceLimit,
    'per_minute': perMinute,
  },
  'notice': {'title': noticeTitle, 'body': noticeBody},
  'announcements': items,
  'truncated': truncated,
};

/// [BannerRepository] answered by the test (story 6.2). Each field answers
/// every call at once; the lists record what was asked.
class FakeBanners implements BannerRepository {
  AccessRead<PublicBanners> publicBanners = AccessReadOk(
    PublicBanners.fromJson(const {'banners': <Object?>[], 'truncated': false}),
  );
  AccessRead<StaffBanners> staffBanners = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  AccessRead<StaffRights> staffRights = const AccessReadDenied(
    AccessDenial.notGranted,
  );

  /// The answer to every upload (default: uploaded as a 1920 x 1080 PNG).
  ImageUploadOutcome upload = const ImageUploaded(
    UploadedImage(
      assetId: '61616161-6161-4161-8161-616161616161',
      mediaType: 'image/png',
      byteSize: 204800,
      width: 1920,
      height: 1080,
    ),
  );
  Uint8List? publicImageBytes;
  FileSyncOutcome sync = const FileSyncDone(
    placed: 0,
    removed: 0,
    waiting: 0,
    removalsPending: 0,
  );

  /// Preview bytes by asset id (none: null).
  final Map<String, Uint8List> previews = {};
  int publicCalls = 0;
  int staffCalls = 0;
  int rightsCalls = 0;
  int syncCalls = 0;
  final uploads = <(String, String, PickedFile)>[];

  @override
  Future<AccessRead<PublicBanners>> fetchPublicBanners() async {
    publicCalls++;
    return publicBanners;
  }

  @override
  Future<AccessRead<StaffBanners>> fetchStaffBanners() async {
    staffCalls++;
    return staffBanners;
  }

  @override
  Future<AccessRead<StaffRights>> fetchStaffRights() async {
    rightsCalls++;
    return staffRights;
  }

  @override
  Uri publicFileUrl(String path) => Uri.parse(
    'https://test.invalid/storage/v1/object/public/$contentPublicBucket/$path',
  );

  @override
  Future<Uint8List?> fetchPublicImage(PublicBanner banner) async =>
      publicImageBytes;

  /// Paths passed to [fetchPublicAsset], in call order.
  final fetchedAssets = <String>[];

  @override
  Future<Uint8List?> fetchPublicAsset(
    String path,
    String mediaType, {
    int maxBytes = 2 * 1024 * 1024,
  }) async {
    fetchedAssets.add(path);
    return publicImageBytes;
  }

  @override
  Future<ImageUploadOutcome> uploadImage(
    String itemId,
    String purpose,
    PickedFile file,
  ) async {
    uploads.add((itemId, purpose, file));
    return upload;
  }

  @override
  Future<FileSyncOutcome> syncFiles() async {
    syncCalls++;
    return sync;
  }

  @override
  Future<Uint8List?> previewImage(String assetId) async => previews[assetId];
}

/// The two allowlisted public snapshots for controller and widget tests.
class FakePublicContentCache implements PublicContentCache {
  bool available = false;
  DateTime savedAt = DateTime.utc(2099, 9, 1, 8);
  PublicContentSnapshot<PublicEvents>? events;
  PublicContentSnapshot<PublicBanners>? banners;
  PublicContentSnapshot<PublicGivingMethods>? givingMethods;
  PublicContentSnapshot<PublicBibleChapter>? bibleChapter;
  PublicContentSnapshot<PublicSermons>? sermons;
  final reads = <String>[];
  final writes = <(String, Object)>[];
  final imageFetches = <String>[];
  final removedGivingMethods = <String>[];
  final reconciledGivingMethods = <PublicGivingMethod>[];

  @override
  Future<PublicContentSnapshot<PublicSermons>?> readSermons() async {
    reads.add(PublicContentCacheKeys.sermons);
    return sermons;
  }

  @override
  Future<PublicContentSnapshot<PublicEvents>?> readEvents() async {
    reads.add(PublicContentCacheKeys.calendar);
    return events;
  }

  @override
  Future<PublicContentSnapshot<PublicBanners>?> readBanners() async {
    reads.add(PublicContentCacheKeys.homeBanners);
    return banners;
  }

  @override
  Future<PublicContentSnapshot<PublicGivingMethods>?>
  readGivingMethods() async {
    reads.add(PublicContentCacheKeys.givingMethods);
    return givingMethods;
  }

  @override
  Future<PublicContentSnapshot<PublicBibleChapter>?> readBibleChapter() async {
    reads.add(PublicContentCacheKeys.bibleChapter);
    return bibleChapter;
  }

  @override
  Future<void> removeGivingMethod(String methodId) async {
    removedGivingMethods.add(methodId);
    final snapshot = givingMethods;
    if (snapshot == null) return;
    givingMethods = PublicContentSnapshot(
      savedAt: snapshot.savedAt,
      value: PublicGivingMethods(
        sample: snapshot.value.sample,
        methods: snapshot.value.methods
            .where((method) => method.methodId != methodId)
            .toList(growable: false),
        truncated: snapshot.value.truncated,
      ),
    );
  }

  @override
  Future<void> reconcileGivingMethod(
    PublicGivingMethod method, {
    required Future<Uint8List?> Function(PublicGivingLogo logo) loadGivingLogo,
  }) async {
    reconciledGivingMethods.add(method);
    final snapshot = givingMethods;
    if (snapshot == null) return;
    final index = snapshot.value.methods.indexWhere(
      (cached) => cached.methodId == method.methodId,
    );
    if (index < 0) return;
    final cached = snapshot.value.methods[index];
    final oldLogo = cached.logo;
    final newLogo = method.logo;
    final oldOfflineBytes = oldLogo?.offlineBytes;
    final sameOfflineLogo =
        oldLogo != null &&
        oldOfflineBytes != null &&
        newLogo != null &&
        newLogo.offlineAllowed &&
        cached.publicationRevision == method.publicationRevision &&
        oldLogo.path == newLogo.path &&
        oldLogo.mediaType == newLogo.mediaType &&
        oldLogo.width == newLogo.width &&
        oldLogo.height == newLogo.height &&
        oldLogo.rightsRevision == newLogo.rightsRevision;
    PublicGivingMethod updated;
    if (sameOfflineLogo) {
      updated = method.withLogo(newLogo.withOfflineBytes(oldOfflineBytes));
    } else if (newLogo?.offlineAllowed == true) {
      imageFetches.add(method.methodId);
      Uint8List? bytes;
      try {
        bytes = await loadGivingLogo(newLogo!);
      } catch (_) {
        bytes = null;
      }
      updated = method.withLogo(
        bytes == null || bytes.isEmpty || bytes.length > 2 * 1024 * 1024
            ? null
            : newLogo!.withOfflineBytes(bytes),
      );
    } else {
      updated = method.withLogo(null);
    }
    final methods = [...snapshot.value.methods];
    methods[index] = updated;
    givingMethods = PublicContentSnapshot(
      savedAt: snapshot.savedAt,
      value: PublicGivingMethods(
        sample: snapshot.value.sample,
        methods: methods,
        truncated: snapshot.value.truncated,
      ),
    );
  }

  @override
  Future<PublicContentCacheWrite> writeRead(
    String readKey,
    Object projection, {
    Future<Uint8List?> Function(PublicBanner banner)? loadBannerImage,
    Future<Uint8List?> Function(PublicGivingLogo logo)? loadGivingLogo,
    Future<Uint8List?> Function(SermonPoster poster)? loadSermonPoster,
  }) async {
    writes.add((readKey, projection));
    if (!available) return const PublicContentCacheUnavailable();
    if (readKey == PublicContentCacheKeys.sermons &&
        projection is PublicSermons) {
      final source = PublicSermons.fromJson(projection.toCacheJson());
      if (source.sermons.any((s) => !s.offlineAllowed) ||
          source.series.any((s) => !s.offlineAllowed)) {
        return const PublicContentCacheRefused(
          PublicContentCacheRefusal.offlineRightsNotCleared,
        );
      }
      final cached = <String, PublicSermonSeries>{};
      for (final series in [
        ...source.series,
        ...source.sermons.map((s) => s.series).whereType<PublicSermonSeries>(),
      ]) {
        if (!series.offlineAllowed) continue;
        if (cached.containsKey(series.seriesId)) continue;
        final poster = series.poster;
        final bytes =
            poster != null && poster.offlineAllowed && loadSermonPoster != null
            ? await loadSermonPoster(poster)
            : null;
        cached[series.seriesId] = series.withPoster(
          bytes == null ? null : poster!.withBytes(bytes),
        );
      }
      sermons = PublicContentSnapshot(
        value: PublicSermons(
          sermons: source.sermons
              .map(
                (s) => s.withSeries(
                  s.series == null ? null : cached[s.series!.seriesId],
                ),
              )
              .toList(),
          series: source.series.map((s) => cached[s.seriesId]!).toList(),
          truncated: source.truncated,
        ),
        savedAt: savedAt,
      );
      return PublicContentCacheSaved(
        savedAt: savedAt,
        savedRows: source.sermons.length,
      );
    }
    if (readKey == PublicContentCacheKeys.calendar &&
        projection is PublicEvents) {
      if (projection.events.any((event) => !event.offlineAllowed)) {
        return const PublicContentCacheRefused(
          PublicContentCacheRefusal.unexpectedProjection,
        );
      }
      events = PublicContentSnapshot(value: projection, savedAt: savedAt);
      return PublicContentCacheSaved(
        savedAt: savedAt,
        savedRows: projection.events.length,
      );
    }
    if (readKey == PublicContentCacheKeys.homeBanners &&
        projection is PublicBanners) {
      if (projection.banners.any((banner) => !banner.offlineAllowed)) {
        return const PublicContentCacheRefused(
          PublicContentCacheRefusal.offlineRightsNotCleared,
        );
      }
      if (projection.banners.isNotEmpty && loadBannerImage == null) {
        return const PublicContentCacheRefused(
          PublicContentCacheRefusal.imageLoaderRequired,
        );
      }
      final cached = <PublicBanner>[];
      for (final banner in projection.banners) {
        imageFetches.add(banner.bannerId);
        final bytes = await loadBannerImage!(banner);
        if (bytes != null) cached.add(banner.withOfflineImageBytes(bytes));
      }
      banners = PublicContentSnapshot(
        value: PublicBanners(cached, truncated: projection.truncated),
        savedAt: savedAt,
      );
      return PublicContentCacheSaved(
        savedAt: savedAt,
        savedRows: cached.length,
        omittedRows: projection.banners.length - cached.length,
      );
    }
    if (readKey == PublicContentCacheKeys.givingMethods &&
        projection is PublicGivingMethods) {
      final cached = <PublicGivingMethod>[];
      for (final method in projection.methods) {
        final logo = method.logo;
        if (logo == null || !logo.offlineAllowed || loadGivingLogo == null) {
          cached.add(method.withLogo(null));
          continue;
        }
        imageFetches.add(method.methodId);
        final bytes = await loadGivingLogo(logo);
        cached.add(
          method.withLogo(bytes == null ? null : logo.withOfflineBytes(bytes)),
        );
      }
      givingMethods = PublicContentSnapshot(
        value: PublicGivingMethods(
          sample: projection.sample,
          methods: cached,
          truncated: projection.truncated,
        ),
        savedAt: savedAt,
      );
      return PublicContentCacheSaved(
        savedAt: savedAt,
        savedRows: projection.methods.length,
      );
    }
    if (readKey == PublicContentCacheKeys.bibleChapter &&
        projection is PublicBibleChapter) {
      if (!projection.offlineAllowed) {
        return const PublicContentCacheRefused(
          PublicContentCacheRefusal.offlineRightsNotCleared,
        );
      }
      bibleChapter = PublicContentSnapshot(value: projection, savedAt: savedAt);
      return PublicContentCacheSaved(savedAt: savedAt, savedRows: 1);
    }
    return const PublicContentCacheRefused(
      PublicContentCacheRefusal.unsupportedRead,
    );
  }
}

/// [ContentFilePicker] answered by the test: [next] is the next pick (null:
/// the editor cancelled).
class FakeFilePicker implements ContentFilePicker {
  PickedFile? next;
  int picks = 0;
  int csvPicks = 0;

  @override
  bool get supported => true;

  @override
  Future<PickedFile?> pickImage() async {
    picks++;
    return next;
  }

  @override
  Future<PickedFile?> pickCsv() async {
    csvPicks++;
    return next;
  }
}

/// A 1 x 1 transparent PNG (enough for Image.memory in widget tests).
final Uint8List tinyPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// The wire form of one published banner (story 6.2); by default the
/// SYNTHETIC theme for 2026.
Map<String, Object?> publicBannerData({
  String bannerId = '81818181-8181-4181-8181-818181818181',
  String kind = 'theme',
  int? themeYear = 2026,
  String title = 'SYNTHETIC God\'s faithfulness in Self Sustenance',
  String? subtitle = 'Deuteronomy 7:9',
  String altText = 'SYNTHETIC theme artwork: an open field at sunrise',
  String? eventId,
  String path = 'banner/81818181-8181-4181-8181-818181818181/r1/image.png',
  int publicationRevision = 1,
  int rightsRevision = 1,
  String publishedAt = '2099-09-01T08:00:00.000000Z',
  bool offlineAllowed = true,
}) => {
  'banner_id': bannerId,
  'banner_kind': kind,
  'theme_year': kind == 'theme' ? themeYear : null,
  'title': title,
  'subtitle': subtitle,
  'alt_text': altText,
  'event_id': eventId,
  'image': {
    'path': path,
    'media_type': 'image/png',
    'width': 1920,
    'height': 1080,
  },
  'publication_revision': publicationRevision,
  'rights_revision': rightsRevision,
  'published_at': publishedAt,
  'offline_allowed': offlineAllowed,
};

/// The wire form of `api.content_public_banners` holding [banners].
Map<String, Object?> publicBannersData(
  List<Map<String, Object?>> banners, {
  bool truncated = false,
}) => {'banners': banners, 'truncated': truncated};

/// The wire form of one banner revision as editors read it.
Map<String, Object?> staffBannerRevisionData({
  int revisionNo = 1,
  String kind = 'campaign',
  int? themeYear,
  String title = 'SYNTHETIC Harvest appeal',
  String? subtitle = 'Bring a gift on Sunday',
  String altText = 'SYNTHETIC baskets of maize and pumpkins',
  String? eventId,
  String? eventTitle,
  String? imageAssetId,
  Map<String, Object?>? rights,
  String savedAt = '2099-09-01T07:00:00.000000Z',
  String savedBy = 'SYNTHETIC Media Phiri',
}) => {
  'revision_no': revisionNo,
  'banner_kind': kind,
  'theme_year': themeYear,
  'title': title,
  'subtitle': subtitle,
  'alt_text': altText,
  'event_id': eventId,
  'event_title': eventTitle,
  'image': imageAssetId == null
      ? null
      : {
          'asset_id': imageAssetId,
          'media_type': 'image/png',
          'byte_size': 204800,
          'width': 1920,
          'height': 1080,
        },
  'rights': rights,
  'saved_at': savedAt,
  'saved_by': savedBy,
};

/// The `rights` object of a banner revision.
Map<String, Object?> bannerRightsData({
  String rightsId = '91919191-9191-4191-8191-919191919191',
  String label = 'SYNTHETIC images made for the church',
  String state = 'published',
  int? liveRevisionNo = 1,
  String? display,
}) => {
  'rights_id': rightsId,
  'label': label,
  'state': state,
  'live_revision_no': liveRevisionNo,
  'display': display,
};

/// The wire form of one banner as editors read it.
Map<String, Object?> staffBannerData({
  String bannerId = '82828282-8282-4282-8282-828282828282',
  int revision = 1,
  String state = 'draft',
  String? publicImage,
  Map<String, Object?>? live,
  Map<String, Object?>? draft,
  String? publishedBy,
  String? publishedAt,
}) => {
  'banner_id': bannerId,
  'revision': revision,
  'state': state,
  'created_at': '2099-09-01T07:00:00.000000Z',
  'created_by': 'SYNTHETIC Media Phiri',
  'updated_at': '2099-09-01T07:00:00.000000Z',
  'published_at': publishedAt,
  'published_by': publishedBy,
  'withdrawn_at': null,
  'archived_at': null,
  'public_image': publicImage,
  'live': live,
  'draft': draft,
};

/// The wire form of `api.content_staff_banners`.
Map<String, Object?> staffBannersData(
  List<Map<String, Object?>> banners, {
  String capacity = 'media',
  int removalsPending = 0,
  bool truncated = false,
}) => {
  'capacity': capacity,
  'banners': banners,
  'removals_pending': removalsPending,
  'truncated': truncated,
};

/// The wire form of one rights record revision.
Map<String, Object?> rightsRevisionData({
  int revisionNo = 1,
  String label = 'SYNTHETIC images made for the church',
  String sourceKey = 'synthetic',
  String holder = 'SYNTHETIC BICC Kafue media team',
  String basis = 'church_owned',
  bool clearsDisplay = true,
  bool clearsOffline = false,
  bool clearsAudio = false,
  String evidence = 'SYNTHETIC made by the media team for staging',
  String savedAt = '2099-09-01T07:00:00.000000Z',
  String savedBy = 'SYNTHETIC Media Phiri',
}) => {
  'revision_no': revisionNo,
  'label': label,
  'source_key': sourceKey,
  'holder': holder,
  'basis': basis,
  'clears_display': clearsDisplay,
  'clears_offline': clearsOffline,
  'clears_audio': clearsAudio,
  'evidence': evidence,
  'saved_at': savedAt,
  'saved_by': savedBy,
};

/// The wire form of one rights record as editors read it.
Map<String, Object?> rightsRecordData({
  String rightsId = '91919191-9191-4191-8191-919191919191',
  int revision = 1,
  String state = 'draft',
  List<String> q5Uses = const ['display', 'offline', 'audio'],
  Map<String, Object?>? live,
  Map<String, Object?>? draft,
  String? verifiedBy,
  String? verifiedAt,
}) => {
  'rights_id': rightsId,
  'revision': revision,
  'state': state,
  'created_at': '2099-09-01T07:00:00.000000Z',
  'created_by': 'SYNTHETIC Media Phiri',
  'updated_at': '2099-09-01T07:00:00.000000Z',
  'verified_at': verifiedAt,
  'verified_by': verifiedBy,
  'withdrawn_at': null,
  'archived_at': null,
  'q5_uses': q5Uses,
  'live': live,
  'draft': draft,
};

/// The wire form of `api.content_staff_rights`.
Map<String, Object?> staffRightsData(
  List<Map<String, Object?>> rights, {
  String capacity = 'media',
  bool truncated = false,
}) => {'capacity': capacity, 'rights': rights, 'truncated': truncated};

/// [FollowUpsRepository] answered by the test (story 4.6). Each field
/// answers every read at once; the counters record how often each was asked.
class FakeFollowUps implements FollowUpsRepository {
  AccessRead<MyFollowUps> mine = const AccessReadDenied(AccessDenial.notLinked);
  AccessRead<FollowUpDetail> task = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  AccessRead<FollowUpSupervision> supervision = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  AccessRead<FollowUpAdminRouting> routing = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  final List<String> taskReads = [];
  int mineCalls = 0;
  int supervisionCalls = 0;
  int routingCalls = 0;

  @override
  Future<AccessRead<MyFollowUps>> fetchMyTasks() async {
    mineCalls++;
    return mine;
  }

  @override
  Future<AccessRead<FollowUpDetail>> fetchTask(String taskId) async {
    taskReads.add(taskId);
    return task;
  }

  @override
  Future<AccessRead<FollowUpSupervision>> fetchSupervision() async {
    supervisionCalls++;
    return supervision;
  }

  @override
  Future<AccessRead<FollowUpAdminRouting>> fetchAdminRouting() async {
    routingCalls++;
    return routing;
  }
}

/// The wire form of a follow-up person (story 4.6).
Map<String, Object?> followUpPersonData({
  String memberId = '22222222-2222-4222-8222-222222222222',
  String? displayName = 'SYNTHETIC Member M',
  String account = 'app_account',
}) => {'member_id': memberId, 'display_name': displayName, 'account': account};

/// The wire form of a follow-up task as its owner or a scope holder sees it
/// (story 4.6); [routing] drops the private fields (Admin).
Map<String, Object?> followUpTaskData({
  String taskId = '46464646-4646-4646-8646-464646464646',
  int revision = 1,
  String state = 'open',
  String dueAt = '2099-01-04T08:00:00.000000Z',
  String? reviewAt,
  bool overdue = false,
  bool duePassed = false,
  String? finishedAt,
  String nextAction = 'SYNTHETIC: phone and check in',
  String? context = 'SYNTHETIC check-in source',
  String? latestOutcome,
  String? closeCode,
  String? closeReason,
  String capacity = 'owner',
  bool? canUpdate,
  bool canReassign = false,
  Map<String, Object?>? owner,
  Map<String, Object?>? supervisor,
  bool routing = false,
  Map<String, Object?>? reminders,
}) {
  final active =
      state == 'open' || state == 'in_progress' || state == 'waiting';
  final meta = <String, Object?>{
    'task_id': taskId,
    'revision': revision,
    'source_type': 'fixture_followup',
    'purpose': 'synthetic_check_in',
    'purpose_label': 'SYNTHETIC check-in',
    'owner': owner ?? followUpPersonData(),
    'supervisor':
        supervisor ??
        followUpPersonData(
          memberId: '33333333-3333-4333-8333-333333333333',
          displayName: 'SYNTHETIC Leader',
        ),
    'scope': {
      'scope_kind': 'department_leader',
      'scope_id': '44444444-4444-4444-8444-444444444444',
    },
    'state': state,
    'due_at': dueAt,
    'review_at': reviewAt,
    'overdue': overdue,
    'due_passed': duePassed,
    'finished_at':
        finishedAt ?? (active ? null : '2026-10-14T09:00:00.000000Z'),
    'created_at': '2026-10-14T08:00:00.000000Z',
    'updated_at': '2026-10-14T08:00:00.000000Z',
  };
  if (routing) return meta;
  return {
    ...meta,
    'source_id': '45454545-4545-4545-8545-454545454545',
    'context': context == null ? null : {'label': context},
    'next_action': nextAction,
    'latest_outcome': latestOutcome,
    'outcomes': ['contacted', 'no_longer_needed', 'unreachable'],
    'close_code': closeCode ?? (state == 'closed' ? 'manual' : null),
    'close_reason': closeReason,
    'capacity': capacity,
    'can_update': canUpdate ?? (active && capacity != 'admin'),
    'can_reassign': canReassign,
    'reminders': ?reminders,
  };
}

/// [DutiesRepository] answered by the test (story 4.1). Each field answers
/// every read at once; the counters record how often each was asked.
class FakeDuties implements DutiesRepository {
  AccessRead<MyDuties> mine = const AccessReadDenied(AccessDenial.notLinked);
  AccessRead<DutyLeaderBoard> board = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  AccessRead<DutyAdminOverview> admin = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  AccessRead<DutyRota> rota = const AccessReadDenied(AccessDenial.notGranted);

  /// Story 4.4: the candidates read (every query gets this answer).
  AccessRead<DutyCandidates> candidates = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  final List<CandidateQuery> candidateQueries = [];
  int mineCalls = 0;
  int boardCalls = 0;
  int adminCalls = 0;
  int rotaCalls = 0;

  @override
  Future<AccessRead<MyDuties>> fetchMyDuties() async {
    mineCalls++;
    return mine;
  }

  @override
  Future<AccessRead<DutyLeaderBoard>> fetchLeaderBoard() async {
    boardCalls++;
    return board;
  }

  @override
  Future<AccessRead<DutyAdminOverview>> fetchAdminOverview() async {
    adminCalls++;
    return admin;
  }

  @override
  Future<AccessRead<DutyRota>> fetchRota() async {
    rotaCalls++;
    return rota;
  }

  @override
  Future<AccessRead<DutyCandidates>> fetchCandidates(
    CandidateQuery query,
  ) async {
    candidateQueries.add(query);
    return candidates;
  }
}

/// [DutyCoverageRepository] answered by the test (story 4.9).
class FakeDutyCoverage implements DutyCoverageRepository {
  AccessRead<DutyCoverage> coverage = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  final List<CoverageQuery> queries = [];

  @override
  Future<AccessRead<DutyCoverage>> fetchCoverage(CoverageQuery query) async {
    queries.add(query);
    return coverage;
  }
}

/// [DutyOutcomesRepository] answered by the test (story 4.10).
class FakeDutyOutcomes implements DutyOutcomesRepository {
  AccessRead<DutyOutcomes> outcomes = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  AccessRead<MemberHistory> history = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  final List<OutcomesQuery> queries = [];
  final List<HistoryQuery> historyQueries = [];

  @override
  Future<AccessRead<DutyOutcomes>> fetchOutcomes(OutcomesQuery query) async {
    queries.add(query);
    return outcomes;
  }

  @override
  Future<AccessRead<MemberHistory>> fetchHistory(HistoryQuery query) async {
    historyQueries.add(query);
    return history;
  }
}

/// [DutySpecialRepository] answered by the test (special assignments).
class FakeDutySpecial implements DutySpecialRepository {
  AccessRead<SpecialAssignments> special = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  int reads = 0;

  @override
  Future<AccessRead<SpecialAssignments>> fetchSpecialAssignments() async {
    reads++;
    return special;
  }
}

/// The wire form of one special assignment as the Pastors read it. [dueOn]
/// (YYYY-MM-DD) makes it a due date (its start is then the due moment,
/// 18:00 church time); [assignment] null leaves it unheld (with [vacancy]);
/// otherwise its keys override [specialHolderData].
Map<String, Object?> specialAssignmentData({
  String occurrenceId = '61616161-6161-4161-8161-616161616161',
  int revision = 1,
  String slotId = '62626262-6262-4262-8262-626262626262',
  String dutyName = 'SYNTHETIC Lead the prayer meeting',
  String startsAt = '2099-01-04T08:00:00.000000Z',
  String? endsAt = '2099-01-04T10:00:00.000000Z',
  String? dueOn,
  String? location = 'SYNTHETIC Chapel',
  String? instructions,
  bool started = false,
  Map<String, Object?>? assignment = const {},
  Map<String, Object?>? vacancy,
}) => {
  'occurrence_id': occurrenceId,
  'revision': revision,
  'slot_id': slotId,
  'duty_name': dutyName,
  'timing': dueOn == null ? 'time' : 'due',
  'starts_at': dueOn == null ? startsAt : '${dueOn}T16:00:00.000000Z',
  'ends_at': dueOn == null ? endsAt : null,
  'due_on': dueOn,
  'location': location,
  'instructions': instructions,
  'given_by': 'SYNTHETIC Pastor Banda',
  'given_at': '2098-12-01T08:00:00.000000Z',
  'started': started,
  'assignment': assignment == null
      ? null
      : specialHolderData(extra: assignment),
  'vacancy': vacancy,
};

/// The wire form of a special assignment's holder ([extra] overrides keys).
Map<String, Object?> specialHolderData({
  Map<String, Object?> extra = const {},
}) => {
  'assignment_id': '63636363-6363-4363-8363-636363636363',
  'revision': 1,
  'member_id': '64646464-6464-4464-8464-646464646464',
  'display_name': 'SYNTHETIC Ruth Mwale',
  'account': 'app_account',
  'own': false,
  'erased': false,
  'response': 'pending',
  'response_provenance': null,
  'confirmed_channel': null,
  'responded_at': null,
  'prior_accepted_at': null,
  'note': null,
  'response_deadline': '2099-01-02T16:00:00.000000Z',
  'deadline_source': 'default',
  'short_notice': false,
  'needs_contact': null,
  'override': null,
  'outcome': null,
  'allowed': <String>[],
  ...extra,
};

/// [ContactLauncher] that records what the screen asked for (story 4.9).
class FakeContactLauncher implements ContactLauncher {
  FakeContactLauncher([this.result = ContactLaunch.opened]);
  ContactLaunch result;
  final List<String> calls = [];
  final List<String> messages = [];

  @override
  Future<ContactLaunch> call(String phone) async {
    calls.add(phone);
    return result;
  }

  @override
  Future<ContactLaunch> message(String phone) async {
    messages.add(phone);
    return result;
  }
}

/// The wire form of one of the member's duties (stories 4.1, 4.2; 4.5 adds
/// the slot id, the owner kind, the earlier acceptance and the leader
/// names; 4.8 keys go in [extra]). Story 4.11: a `cell` owner kind is a cell
/// programme part (its cell, no department).
Map<String, Object?> myDutyData({
  String assignmentId = '42424242-4242-4242-8242-424242424242',
  int revision = 1,
  String response = 'pending',
  String startsAt = '2099-01-04T08:00:00.000000Z',
  String? endsAt = '2099-01-04T10:00:00.000000Z',
  String responseDeadline = '2099-01-01T08:00:00.000000Z',
  String? respondedAt,
  String? note,
  String dutyName = 'Sunday preaching',
  int slotRevision = 1,
  List<String>? changes,
  String? previousResponse,
  List<String> previousAssignmentIds = const [],
  String? notesUpdatedAt,
  String? reportingAt,
  String? location = 'SYNTHETIC Main hall',
  String? positionName,
  String? priorAcceptedAt,
  List<Map<String, Object?>> leaders = const [],
  String slotId = '45454545-4545-4545-8545-454545454545',
  String ownerKind = 'department',
  // Story 4.8: deadline_source, short_notice, reminders (absent = a server
  // before 4.8).
  Map<String, Object?> extra = const {},
}) => {
  'assignment_id': assignmentId,
  'revision': revision,
  'occurrence_id': '43434343-4343-4343-8343-434343434343',
  'slot_id': slotId,
  'owner_kind': ownerKind,
  // Special assignments: a `special` owner kind has no department either.
  'department_id': ownerKind == 'cell' || ownerKind == 'special'
      ? null
      : '44444444-4444-4444-8444-444444444444',
  'department_name': ownerKind == 'cell' || ownerKind == 'special'
      ? null
      : 'SYNTHETIC Preaching Rota',
  if (ownerKind == 'cell') 'cell_id': '47474747-4747-4747-8747-474747474747',
  'duty_name': dutyName,
  'position_name': positionName,
  'starts_at': startsAt,
  'ends_at': endsAt,
  'reporting_at': reportingAt,
  'location': location,
  'instructions': 'Arrive early.',
  'prior_accepted_at': priorAcceptedAt,
  'leaders': leaders,
  'response': response,
  'response_deadline': responseDeadline,
  'responded_at': respondedAt,
  'note': note,
  'slot_revision': slotRevision,
  'changes': changes,
  'previous_response': previousResponse,
  'previous_assignment_ids': previousAssignmentIds,
  'notes_updated_at': notesUpdatedAt,
  ...extra,
};

/// The wire form of a synthetic cell as the Admin sees it (story 2.6).
Map<String, Object?> adminCellData({
  String id = '77777777-7777-4777-8777-777777777777',
  String name = 'SYNTHETIC Cell X',
  int revision = 1,
  bool listed = true,
  int? signupRevision = 1,
  List<Map<String, Object?>> leaders = const [],
  List<Map<String, Object?>> assistants = const [],
}) => {
  'cell_id': id,
  'name': name,
  'broad_area': 'SYNTHETIC North',
  'signup_label': '$name label',
  'listed': listed,
  'signup_revision': signupRevision,
  'cell_state': 'active',
  'is_synthetic': true,
  'revision': revision,
  'leaders': leaders,
  'assistants': assistants,
  'member_count': 0,
};

/// The wire form of an open request in the Admin overview (story 2.6).
Map<String, Object?> adminCellRequestData({
  String id = '88888888-8888-4888-8888-888888888888',
  String memberId = '66666666-6666-4666-8666-666666666666',
  String choice = 'cell',
  String? requestedCellId = '77777777-7777-4777-8777-777777777777',
  String state = 'pending',
  int memberRevision = 2,
  bool ownRecord = false,
}) => {
  'request_id': id,
  'member_id': memberId,
  'display_name': 'SYNTHETIC Ruth Mwale',
  'kind': 'join',
  'origin': 'application',
  'choice': choice,
  'state': state,
  'requested_cell_id': requestedCellId,
  'requested_cell_name': requestedCellId == null ? null : 'SYNTHETIC Cell X',
  'current_cell_id': null,
  'current_cell_name': null,
  'reason': null,
  'follow_up': requestedCellId == null || state == 'referred',
  'member_revision': memberRevision,
  'own_record': ownRecord,
  'created_at': '2026-10-07T12:00:00.000000Z',
};

/// The wire form of an approved member row in the Admin overview.
Map<String, Object?> cellMemberRowData({
  String id = '99999999-9999-4999-8999-999999999999',
  String name = 'SYNTHETIC Leader Lydia',
  int grantsRevision = 3,
  int cellRevision = 1,
  String? cellId,
}) => {
  'member_id': id,
  'display_name': name,
  'account': 'app_account',
  'grants_revision': grantsRevision,
  'cell_revision': cellRevision,
  'cell_id': cellId,
  'open_request_id': null,
};

/// The wire form of the member's own cell (story 2.6).
Map<String, Object?> myCellData({
  int revision = 1,
  Map<String, Object?>? primary,
  Map<String, Object?>? openRequest,
  Map<String, Object?>? lastDecision,
}) => {
  'member_id': '22222222-2222-4222-8222-222222222222',
  'revision': revision,
  'primary': primary,
  'open_request': openRequest,
  'last_decision': lastDecision,
};

/// [PasswordRecoveryGateway] answered by the test (story 2.7). Records every
/// call; the recovery session it pretends to hold is only "open" between a
/// ready [openLink] and [setNewPassword] or [discard].
class FakePasswordRecovery implements PasswordRecoveryGateway {
  ResetRequestOutcome resetAnswer = ResetRequestOutcome.sent;
  RecoveryLinkOutcome linkAnswer = RecoveryLinkOutcome.ready;
  SetPasswordOutcome setAnswer = const PasswordSet();
  final List<String> resetEmails = [];
  final List<String> openedCodes = [];
  final List<String> passwordsSet = [];
  int discards = 0;
  bool sessionOpen = false;

  @override
  Future<ResetRequestOutcome> requestReset(String email) async {
    resetEmails.add(email);
    return resetAnswer;
  }

  @override
  Future<RecoveryLinkOutcome> openLink(String code) async {
    openedCodes.add(code);
    sessionOpen = linkAnswer == RecoveryLinkOutcome.ready;
    return linkAnswer;
  }

  @override
  Future<SetPasswordOutcome> setNewPassword(String password) async {
    passwordsSet.add(password);
    if (setAnswer is PasswordSet) sessionOpen = false;
    return setAnswer;
  }

  @override
  Future<void> discard() async {
    discards++;
    sessionOpen = false;
  }
}

/// [RecoveryEmailRepository] answered by the test (story 2.7).
class FakeRecoveryEmail implements RecoveryEmailRepository {
  AccessRead<MyRecoveryEmail> mine = AccessReadOk(
    MyRecoveryEmail.fromJson(myRecoveryEmailData()),
  );
  AccessRead<RecoveryEmailQueue> queue = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  AuthOutcome passwordAnswer = const AuthSucceeded(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  );
  EmailVerificationRequest verificationAnswer = EmailVerificationRequest.sent;
  int mineCalls = 0;
  int queueCalls = 0;
  final List<String> passwordsChecked = [];
  final List<String> verificationsRequested = [];

  @override
  Future<AccessRead<MyRecoveryEmail>> fetchMine() async {
    mineCalls++;
    return mine;
  }

  @override
  Future<AccessRead<RecoveryEmailQueue>> fetchQueue() async {
    queueCalls++;
    return queue;
  }

  @override
  Future<AuthOutcome> confirmPassword(String password) async {
    passwordsChecked.add(password);
    return passwordAnswer;
  }

  @override
  Future<EmailVerificationRequest> requestVerification(String email) async {
    verificationsRequested.add(email);
    return verificationAnswer;
  }
}

/// The wire form of the member's own recovery-email state (story 2.7).
Map<String, Object?> myRecoveryEmailData({
  String access = 'granted',
  String? approvedEmail,
  Map<String, Object?>? proposal,
  bool canPropose = true,
}) => {
  'access': access,
  'approved_email': approvedEmail,
  'proposal': proposal,
  'can_propose': canPropose,
  'recent_sign_in_minutes': 10,
};

/// The wire form of one recovery-email proposal (story 2.7).
Map<String, Object?> recoveryProposalData({
  String id = '77777777-7777-4777-8777-777777777777',
  int revision = 1,
  String email = 'synthetic-member@example.test',
  String state = 'pending',
  bool verified = false,
  String? decisionReason,
}) => {
  'proposal_id': id,
  'revision': revision,
  'email': email,
  'state': state,
  'verified': verified,
  'proposed_at': '2026-10-07T10:00:00Z',
  'decision_reason': ?decisionReason,
};

/// The wire form of one Admin queue item (story 2.7).
Map<String, Object?> recoveryReviewItemData({
  String id = '77777777-7777-4777-8777-777777777777',
  int revision = 1,
  String name = 'SYNTHETIC Ruth Mwale',
  bool verified = true,
  bool otherChanges = false,
  bool ownAccount = false,
}) => {
  ...recoveryProposalData(id: id, revision: revision, verified: verified),
  'member_id': '66666666-6666-4666-8666-666666666666',
  'display_name': name,
  'phone_username': '+447700900281',
  'access_review': verified,
  'other_changes': otherChanges,
  'own_account': ownAccount,
  'is_synthetic': true,
};

/// [CredentialReviewRepository] answered by the test (story 2.8).
class FakeCredentialReview implements CredentialReviewRepository {
  AccessRead<MyCredentials> mine = AccessReadOk(
    MyCredentials.fromJson(myCredentialsData()),
  );
  AccessRead<CredentialQueue> queue = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  int mineCalls = 0;
  int queueCalls = 0;

  @override
  Future<AccessRead<MyCredentials>> fetchMine() async {
    mineCalls++;
    return mine;
  }

  @override
  Future<AccessRead<CredentialQueue>> fetchQueue() async {
    queueCalls++;
    return queue;
  }
}

/// The wire form of the member's own sign-in details (story 2.8).
Map<String, Object?> myCredentialsData({
  String access = 'granted',
  String phone = '+447700900331',
  String? email,
  Map<String, Object?>? pendingChange,
  Map<String, Object?>? lastChange,
  Map<String, Object?>? pendingRecoveryEmail,
  bool canRequest = true,
  String? churchContact,
}) => access == 'review_required'
    // In review the server sends only access, the church contact and the
    // member's own pending request id/revision/kind/state.
    ? {
        'access': access,
        'church_contact': churchContact,
        'pending_change': pendingChange == null
            ? null
            : {
                for (final k in [
                  'change_id',
                  'revision',
                  'change_kind',
                  'state',
                ])
                  k: pendingChange[k],
              },
        'pending_recovery_email': pendingRecoveryEmail == null
            ? null
            : {
                for (final k in ['proposal_id', 'revision', 'state'])
                  k: pendingRecoveryEmail[k],
              },
      }
    : {
        'access': access,
        'phone_username': phone,
        'recovery_email': email,
        'pending_change': pendingChange,
        'last_change': lastChange,
        'pending_recovery_email': pendingRecoveryEmail,
        'can_request': canRequest,
        'church_contact': churchContact,
        'recent_sign_in_minutes': 10,
      };

/// The wire form of one credential change (story 2.8).
Map<String, Object?> credentialChangeData({
  String id = '88888888-8888-4888-8888-888888888888',
  int revision = 1,
  String kind = 'phone_username',
  String state = 'pending',
  String? phone = '+447700900340',
  String? email,
  bool? verified,
  String? decisionReason,
}) => {
  'change_id': id,
  'revision': revision,
  'change_kind': kind,
  'phone_username': ?phone,
  'email': ?email,
  'state': state,
  'verified': ?verified,
  'requested_at': '2026-10-07T10:00:00Z',
  'decision_reason': ?decisionReason,
};

/// The wire form of the Admin credential queue (story 2.8).
Map<String, Object?> credentialQueueData({
  List<Map<String, Object?>> changes = const [],
  List<Map<String, Object?>> reviews = const [],
  List<Map<String, Object?>> holds = const [],
}) => {'changes': changes, 'reviews': reviews, 'holds': holds};

Map<String, Object?> credentialChangeItemData({
  Map<String, Object?>? change,
  String name = 'SYNTHETIC Grace Phiri',
  bool phoneAvailable = true,
  bool otherChanges = false,
  bool ownAccount = false,
}) {
  final c = change ?? credentialChangeData();
  return {
    ...c,
    'member_id': '99999999-9999-4999-8999-999999999999',
    'display_name': name,
    'member_revision': 3,
    'current_phone_username': '+447700900331',
    'has_recovery_email': false,
    'access_review': false,
    if (c['change_kind'] == 'phone_username') 'phone_available': phoneAvailable,
    'other_changes': otherChanges,
    'own_account': ownAccount,
    'is_synthetic': true,
  };
}

Map<String, Object?> accessReviewItemData({
  String memberId = 'abababab-abab-4bab-8bab-abababababab',
  String name = 'SYNTHETIC John Banda',
  bool extraFactors = false,
  List<String> changeKinds = const ['email'],
}) => {
  'member_id': memberId,
  'display_name': name,
  'member_revision': 4,
  'link_state': 'review_required',
  'binding_review': true,
  'phone_username': '+447700900336',
  'recovery_email': null,
  'auth_phone_username': '+447700900336',
  'auth_email': 'synthetic-thief@example.test',
  'auth_email_confirmed': true,
  'extra_factors': extraFactors,
  'change_kinds': changeKinds,
  'own_account': false,
  'is_synthetic': true,
};

Map<String, Object?> holdItemData({
  String holdId = 'cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd',
  String name = 'SYNTHETIC Mary Tembo',
  String reason = 'ownership_dispute',
  bool ownMember = false,
}) => {
  'hold_id': holdId,
  'member_id': 'efefefef-efef-4fef-8fef-efefefefefef',
  'display_name': name,
  'member_revision': 2,
  'hold_kind': reason == 'ownership_dispute' ? 'access_review' : 'security',
  'reason_code': reason,
  'placed_at': '2026-10-07T10:00:00Z',
  'own_member': ownMember,
  'is_synthetic': true,
};

/// [AssistedRecoveryGateway] answered by the test (story 2.9). Records what
/// the device sent so a test can check that only a digest left before the
/// password step.
class FakeAssistedRecovery implements AssistedRecoveryGateway {
  RecoveryRequestOutcome requestAnswer = RecoveryRequestReceived(
    'ABCD2345',
    DateTime.utc(2026, 10, 7, 12, 30),
  );
  RecoveryStatusOutcome statusAnswer = const RecoveryStatus(
    RecoveryGrantState.ready,
    null,
  );
  RedeemOutcome redeemAnswer = RedeemOutcome.succeeded;
  final List<(String, String)> requests = [];
  final List<String> statusDigests = [];
  final List<(String, GrantSecret, String)> redeems = [];

  @override
  Future<RecoveryRequestOutcome> request(String phone, String digest) async {
    requests.add((phone, digest));
    return requestAnswer;
  }

  @override
  Future<RecoveryStatusOutcome> status(String digest) async {
    statusDigests.add(digest);
    return statusAnswer;
  }

  @override
  Future<RedeemOutcome> redeem(
    String phone,
    GrantSecret secret,
    String password,
  ) async {
    redeems.add((phone, secret, password));
    return redeemAnswer;
  }
}

/// [RecoveryCasesRepository] answered by the test (story 2.9).
class FakeRecoveryCases implements RecoveryCasesRepository {
  AccessRead<RecoveryCases> cases = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  int calls = 0;

  @override
  Future<AccessRead<RecoveryCases>> fetchCases() async {
    calls++;
    return cases;
  }
}

/// The wire form of one recovery case as the Admin read sends it (2.9).
Map<String, Object?> recoveryCaseData({
  String caseId = '29292929-2929-4929-8929-292929292929',
  String name = 'SYNTHETIC Ruth Mwale',
  String state = 'open',
  String? grantState,
  String? operationState,
  String? linkProblem,
  bool held = false,
  bool ownMember = false,
}) => {
  'case_id': caseId,
  'revision': 2,
  'member_id': '39393939-3939-4939-8939-393939393939',
  'display_name': name,
  'member_revision': 4,
  'case_state': state,
  'identity_check': 'in_person',
  'evidence': ['known_in_person', 'photo_id'],
  'opened_at': '2026-10-07T10:00:00Z',
  'opened_by_me': true,
  'closed_at': null,
  'outcome': state == 'completed' ? 'reset_completed' : null,
  'cancel_reason': null,
  'account': 'app_account',
  'link_problem': linkProblem,
  'held': held,
  'grant': grantState == null
      ? null
      : {
          'grant_id': '49494949-4949-4949-8949-494949494949',
          'state': grantState,
          'issued_at': '2026-10-07T10:05:00Z',
          'expires_at': '2026-10-07T10:20:00Z',
          'end_reason': null,
        },
  'operation': operationState == null
      ? null
      : {
          'operation_id': '59595959-5959-4959-8959-595959595959',
          'state': operationState,
          'begun_at': '2026-10-07T10:06:00Z',
          'completed_at': null,
        },
  'is_synthetic': true,
  'own_member': ownMember,
};

/// [MembershipLifecycleRepository] answered by the test (story 2.10).
class FakeMembershipLifecycle implements MembershipLifecycleRepository {
  AccessRead<MyMembershipStatus> status = const AccessReadOk(
    MyMembershipStatus(deactivated: false),
  );
  AccessRead<MembershipLifecycleOverview> overview = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  int statusCalls = 0;
  int overviewCalls = 0;

  @override
  Future<AccessRead<MyMembershipStatus>> fetchMyStatus() async {
    statusCalls++;
    return status;
  }

  @override
  Future<AccessRead<MembershipLifecycleOverview>> fetchOverview() async {
    overviewCalls++;
    return overview;
  }
}

/// The wire form of the Admin lifecycle overview (story 2.10).
Map<String, Object?> membershipLifecycleData({
  List<Map<String, Object?>> deactivated = const [],
  List<Map<String, Object?>> loginHolds = const [],
  List<Map<String, Object?>> handovers = const [],
}) => {
  'deactivated': deactivated,
  'login_holds': loginHolds,
  'handovers': handovers,
};

Map<String, Object?> deactivatedMemberData({
  String id = '81818181-8181-4181-8181-818181818181',
  String name = 'SYNTHETIC Esther Banda',
  int revision = 4,
  String account = 'access_review',
  int pendingObligations = 1,
  String reason = 'member_request',
  bool ownMember = false,
}) => {
  'member_id': id,
  'display_name': name,
  'membership_state': 'deactivated',
  'revision': revision,
  'account': account,
  'is_synthetic': true,
  'pending_obligations': pendingObligations,
  'deactivated_at': '2026-10-07T10:00:00Z',
  'reason_code': reason,
  'own_member': ownMember,
};

Map<String, Object?> loginHoldData({
  String holdId = '82828282-8282-4282-8282-828282828282',
  String memberId = '83838383-8383-4383-8383-838383838383',
  String name = 'SYNTHETIC Moses Phiri',
  int revision = 3,
  bool ownMember = false,
}) => {
  'hold_id': holdId,
  'member_id': memberId,
  'display_name': name,
  'member_revision': revision,
  'placed_at': '2026-10-07T09:00:00Z',
  'own_member': ownMember,
  'is_synthetic': true,
};

Map<String, Object?> handoverData({
  String id = '84848484-8484-4484-8484-848484848484',
  String memberId = '81818181-8181-4181-8181-818181818181',
  String name = 'SYNTHETIC Esther Banda',
  String state = 'deactivated',
  String kind = 'fixture_door_duty',
  String module = 'fixture',
}) => {
  'obligation_id': id,
  'member_id': memberId,
  'display_name': name,
  'membership_state': state,
  'owner_module': module,
  'obligation_kind': kind,
  'recorded_at': '2026-10-07T10:00:00Z',
};

/// [MemberDeletionRepository] answered by the test (story 2.11).
class FakeMemberDeletion implements MemberDeletionRepository {
  AccessRead<MemberDeletionOverview> overview = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  int overviewCalls = 0;

  @override
  Future<AccessRead<MemberDeletionOverview>> fetchOverview() async {
    overviewCalls++;
    return overview;
  }
}

/// The wire form of the Admin deletion read (story 2.11).
Map<String, Object?> memberDeletionOverviewData({
  List<Map<String, Object?>> deletions = const [],
  List<Map<String, Object?>> deactivated = const [],
  bool accepting = true,
}) => {
  'deletions': deletions,
  'deactivated': deactivated,
  'accepting': accepting,
};

const _deletionSteps = [
  'journal_access_revoked',
  'journal_manifest_member',
  'journal_manifest_account',
  'auth_account',
  'erase_identity',
  'erase_owners',
  'anonymise',
  'verify',
  'journal_completed_member',
  'journal_completed_account',
  'complete',
];

Map<String, Object?> memberDeletionData({
  String id = '85858585-8585-4585-8585-858585858585',
  String memberId = '86868686-8686-4686-8686-868686868686',
  String name = 'SYNTHETIC Grace Mwale',
  String origin = 'member_request',
  int done = 4,
  bool hadAccount = true,
  int pendingObligations = 0,
  Map<String, Object?>? next,
  int authAttempts = 1,
}) {
  final names = [
    for (final s in _deletionSteps)
      if (hadAccount || !s.endsWith('_account')) s,
  ];
  final steps = [
    for (final (i, s) in names.indexed)
      {
        'step': s,
        'state': i < done ? 'done' : 'pending',
        'attempts': s == 'auth_account' ? authAttempts : (i < done ? 1 : 0),
        'outcome': i < done ? 'done' : null,
      },
  ];
  final completed = steps.every((s) => s['state'] == 'done');
  return {
    'deletion_id': id,
    'member_id': memberId,
    'display_name': completed ? 'Deleted member' : name,
    'origin': origin,
    'deletion_state': completed ? 'completed' : 'requested',
    'had_account': hadAccount,
    'requested_at': '2026-10-07T11:00:00Z',
    'completed_at': completed ? '2026-10-07T11:05:00Z' : null,
    'revision': 1,
    'is_synthetic': true,
    'pending_obligations': pendingObligations,
    'steps': steps,
    'next':
        next ??
        (completed
            ? {'action': 'done'}
            : {
                'step': steps[done]['step'],
                'action': 'advance',
                'attempts': 0,
              }),
  };
}

Map<String, Object?> deletionCandidateData({
  String id = '87878787-8787-4787-8787-878787878787',
  String name = 'SYNTHETIC Daniel Zulu',
  int revision = 5,
  String account = 'access_review',
  bool ownMember = false,
}) => {
  'member_id': id,
  'display_name': name,
  'revision': revision,
  'account': account,
  'own_member': ownMember,
  'is_synthetic': true,
};

/// [InboxRepository] answered by the test (story 3.1).
class FakeInbox implements InboxRepository {
  AccessRead<Inbox> inbox = const AccessReadOk(Inbox(items: []));

  /// The answer for an older page, by its cursor's item id.
  final olderPages = <String, AccessRead<Inbox>>{};
  final afters = <InboxCursor?>[];
  int calls = 0;

  /// Story 3.7: when set, an older-page read waits for it (a request in
  /// flight).
  Completer<void>? holdOlder;

  @override
  Future<AccessRead<Inbox>> fetchMyInbox({InboxCursor? after}) async {
    calls++;
    afters.add(after);
    if (after == null) return inbox;
    final hold = holdOlder;
    if (hold != null) await hold.future;
    return olderPages[after.afterItemId] ??
        const AccessReadFailed(unreachable: false);
  }

  /// Story 3.2: the answer for opening an item, by its id (default: not
  /// found).
  final opened = <String, AccessRead<OpenedInboxItem>>{};
  final openedIds = <String>[];

  @override
  Future<AccessRead<OpenedInboxItem>> openItem(String itemId) async {
    openedIds.add(itemId);
    return opened[itemId] ?? const AccessReadOk(OpenedInboxItem.notFound());
  }
}

/// [NotificationSettingsRepository] answered by the test (story 3.7).
class FakeNotificationSettings implements NotificationSettingsRepository {
  AccessRead<NotificationSettings> settings = const AccessReadOk(
    NotificationSettings(categories: []),
  );
  int calls = 0;

  @override
  Future<AccessRead<NotificationSettings>> fetchMySettings() async {
    calls++;
    return settings;
  }
}

/// [InboxSignals] the test fires (story 3.7).
class FakeInboxSignals implements InboxSignals {
  final _controllers = <StreamController<void>>[];

  /// The account ids subscribed so far, and how many are listening now.
  final subscribed = <String>[];
  int get listening => _controllers.where((c) => c.hasListener).length;

  /// Sends one generic signal to every open subscription.
  void signal() {
    for (final c in _controllers) {
      if (c.hasListener) c.add(null);
    }
  }

  @override
  Stream<void> changes(String accountId) {
    subscribed.add(accountId);
    late final StreamController<void> c;
    c = StreamController<void>(onCancel: () => _controllers.remove(c));
    _controllers.add(c);
    return c.stream;
  }
}

/// The wire form of one push category (story 3.5).
Map<String, Object?> pushCategoryData({
  String sourceType = 'fixture_reminder',
  String kind = 'fixture_due',
  String title = 'SYNTHETIC test reminder',
  bool pushEnabled = true,
  int? revision,
}) => {
  'source_type': sourceType,
  'reminder_kind': kind,
  'title': title,
  'push_enabled': pushEnabled,
  'revision': revision,
};

/// Story 3.6: a device push SDK the test drives (permission answers, tokens,
/// token refreshes and notification taps).
class FakePushMessaging implements PushMessaging {
  FakePushMessaging({
    this.supported = true,
    this.devicePlatform = PushPlatform.android,
    this.current = PushPermission.notDetermined,
    this.answer = PushPermission.granted,
    this.deviceToken,
    this.launchedBy,
  });

  final bool supported;
  final PushPlatform devicePlatform;

  /// The permission now, and the person's answer when asked.
  PushPermission current;
  PushPermission answer;

  /// The device token (null = none available).
  String? deviceToken;

  /// The item id of the notification that launched the app.
  String? launchedBy;

  int requests = 0;
  int deletes = 0;

  /// The SDK's token deletion throws (sign-out must still proceed).
  bool failDelete = false;
  final _refreshes = StreamController<String>.broadcast();
  final _taps = StreamController<String>.broadcast();

  void refreshToken(String token) {
    deviceToken = token;
    _refreshes.add(token);
  }

  void tap(String itemId) => _taps.add(itemId);

  @override
  bool get isSupported => supported;

  @override
  PushPlatform? get platform => supported ? devicePlatform : null;

  @override
  Future<PushPermission> permission() async => current;

  @override
  Future<PushPermission> requestPermission() async {
    requests++;
    current = answer;
    return answer;
  }

  @override
  Future<String?> token() async => deviceToken;

  @override
  Stream<String> get tokenRefreshes => _refreshes.stream;

  @override
  Stream<String> get taps => _taps.stream;

  @override
  Future<String?> initialTap() async {
    final id = launchedBy;
    launchedBy = null;
    return id;
  }

  @override
  Future<void> deleteToken() async {
    deletes++;
    if (failDelete) throw StateError('SYNTHETIC push SDK failure');
    deviceToken = null;
  }
}

/// The wire form of one inbox item (story 3.1).
Map<String, Object?> inboxItemData({
  String id = '31313131-3131-4131-8131-313131313131',
  String kind = 'fixture_due',
  String dueAt = '2026-10-08T07:00:00.000000Z',
  String deliveredAt = '2026-10-08T07:00:05.000000Z',
  String? title = 'SYNTHETIC test reminder',
  String? body = 'A test reminder is waiting for you.',
  bool? opened,
  String? snoozedUntil,
}) => {
  'item_id': id,
  'reminder_kind': kind,
  'due_at': dueAt,
  'delivered_at': deliveredAt,
  'title': ?title,
  'body': ?body,
  'opened': ?opened,
  'snoozed_until': ?snoozedUntil,
};

/// The wire form of an opened inbox item (story 3.2; snooze from 3.7).
Map<String, Object?> openedItemData({
  String id = '31313131-3131-4131-8131-313131313131',
  String state = 'current',
  String? target = '/fixture/reminders/41414141-4141-4141-8141-414141414141',
  List<String>? snoozeChoices,
  String? snoozedUntil,
}) => {
  ...inboxItemData(id: id),
  'state': state,
  'target': target,
  'snooze_choices': ?snoozeChoices,
  'snoozed_until': ?snoozedUntil,
};

/// The fakes and provider overrides an app or screen test runs against.
class ClientTestHarness {
  ClientTestHarness({String? account = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'})
    : session = FakeSession(account);

  final gateway = FakeCommandGateway();
  final FakeSession session;
  final reader = FakeFixtureReader();
  late final auth = FakeAccountAuth(session);
  final memberAccess = FakeMemberAccess();
  final grants = FakeGrants();
  final membership = FakeMembership();
  final review = FakeReview();
  final cells = FakeCells();
  final content = FakeContent();
  final bible = FakeBible();
  final sermons = FakeSermons();
  final biblePackageSource = FakeBibleTranslationPackageSource();
  final hymnBook = FakeHymnBookSource();
  final hymnLists = FakeHymnLists();
  final giving = FakeGiving();
  GivingDiallerLauncher? givingDiallerLauncher;
  final announcements = FakeAnnouncements();
  final banners = FakeBanners();
  final publicContentCache = FakePublicContentCache();
  final filePicker = FakeFilePicker();
  final duties = FakeDuties();
  final coverage = FakeDutyCoverage();
  final outcomes = FakeDutyOutcomes();
  final special = FakeDutySpecial();
  final contact = FakeContactLauncher();
  final followUps = FakeFollowUps();
  final recovery = FakePasswordRecovery();
  final recoveryEmail = FakeRecoveryEmail();
  final credentials = FakeCredentialReview();
  final assisted = FakeAssistedRecovery();
  final recoveryCases = FakeRecoveryCases();
  final lifecycle = FakeMembershipLifecycle();
  final deletions = FakeMemberDeletion();
  final inbox = FakeInbox();
  final notificationSettings = FakeNotificationSettings();
  final signals = FakeInboxSignals();

  /// Story 3.6: the device push SDK (default: none, as every build today).
  PushMessaging push = const NoPushMessaging();

  /// Replaces [gateway] in [overrides] when set, so a screen test can run
  /// the real adapter (for example SupabaseCommandGateway over a mock HTTP
  /// client answering with a recorded server envelope).
  CommandGateway? commandGateway;

  /// [configured] false leaves the unconfigured defaults for the gateway and
  /// the platform status (as a build without `--dart-define`s).
  List<Override> overrides({bool configured = true}) => [
    sessionRepositoryProvider.overrideWithValue(session),
    fixtureCounterReaderProvider.overrideWithValue(reader),
    requestIdsProvider.overrideWithValue(SequentialRequestIds()),
    pushMessagingProvider.overrideWithValue(push),
    hymnBookSourceProvider.overrideWithValue(hymnBook),
    if (configured) ...[
      accountAuthGatewayProvider.overrideWithValue(auth),
      memberAccessRepositoryProvider.overrideWithValue(memberAccess),
      grantsRepositoryProvider.overrideWithValue(grants),
      membershipRepositoryProvider.overrideWithValue(membership),
      reviewRepositoryProvider.overrideWithValue(review),
      cellsRepositoryProvider.overrideWithValue(cells),
      contentRepositoryProvider.overrideWithValue(content),
      bibleRepositoryProvider.overrideWithValue(bible),
      sermonsRepositoryProvider.overrideWithValue(sermons),
      bibleTranslationPackageSourceProvider.overrideWithValue(
        biblePackageSource,
      ),
      givingRepositoryProvider.overrideWithValue(giving),
      givingDiallerLauncherProvider.overrideWithValue(
        givingDiallerLauncher ?? const UnavailableGivingDiallerLauncher(),
      ),
      announcementsRepositoryProvider.overrideWithValue(announcements),
      hymnListsRepositoryProvider.overrideWithValue(hymnLists),
      bannerRepositoryProvider.overrideWithValue(banners),
      publicContentCacheProvider.overrideWithValue(publicContentCache),
      contentFilePickerProvider.overrideWithValue(filePicker),
      dutiesRepositoryProvider.overrideWithValue(duties),
      dutyCoverageRepositoryProvider.overrideWithValue(coverage),
      dutyOutcomesRepositoryProvider.overrideWithValue(outcomes),
      dutySpecialRepositoryProvider.overrideWithValue(special),
      contactLauncherProvider.overrideWithValue(contact),
      followUpsRepositoryProvider.overrideWithValue(followUps),
      passwordRecoveryGatewayProvider.overrideWithValue(recovery),
      recoveryEmailRepositoryProvider.overrideWithValue(recoveryEmail),
      credentialReviewRepositoryProvider.overrideWithValue(credentials),
      assistedRecoveryGatewayProvider.overrideWithValue(assisted),
      recoveryCasesRepositoryProvider.overrideWithValue(recoveryCases),
      membershipLifecycleRepositoryProvider.overrideWithValue(lifecycle),
      memberDeletionRepositoryProvider.overrideWithValue(deletions),
      inboxRepositoryProvider.overrideWithValue(inbox),
      notificationSettingsRepositoryProvider.overrideWithValue(
        notificationSettings,
      ),
      inboxSignalsProvider.overrideWithValue(signals),
      commandGatewayProvider.overrideWithValue(commandGateway ?? gateway),
      platformStatusRepositoryProvider.overrideWithValue(FakePlatformStatus()),
    ],
  ];
}

final _directive = RegExp(
  r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);
final _sdkPackage = RegExp(
  r'^package:(supabase|supabase_flutter|gotrue|postgrest|realtime_client|storage_client|functions_client|http)/',
);

/// Import/export targets in [source] (the file at the package-relative
/// [path], e.g. `lib/src/presentation/x.dart`) that only a composition root
/// or an adapter may reach: the Supabase/http SDKs, the adapters (by package
/// URI or by a relative path that resolves into them), `supabase_adapters.dart`
/// and `composition.dart`. Relative paths are resolved against [path].
List<String> boundaryViolations(String path, String source) {
  const ownPackage = 'package:church_client_core/';
  bool restricted(String libPath) =>
      libPath.startsWith('lib/src/adapters/') ||
      libPath == 'lib/supabase_adapters.dart' ||
      libPath == 'lib/composition.dart';
  final found = <String>[];
  for (final m in _directive.allMatches(source)) {
    final uri = m.group(1)!;
    if (uri.startsWith('dart:')) continue;
    if (_sdkPackage.hasMatch(uri)) {
      found.add(uri);
    } else if (uri.startsWith(ownPackage)) {
      if (restricted('lib/${uri.substring(ownPackage.length)}')) found.add(uri);
    } else if (!uri.startsWith('package:')) {
      final parts = path.split('/')..removeLast();
      for (final seg in uri.split('/')) {
        if (seg == '..') {
          if (parts.isNotEmpty) parts.removeLast();
        } else if (seg != '.') {
          parts.add(seg);
        }
      }
      if (restricted(parts.join('/'))) found.add(uri);
    }
  }
  return found;
}
