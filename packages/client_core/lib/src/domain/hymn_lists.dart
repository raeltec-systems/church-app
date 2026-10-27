/// Story 6.8: members' favourite hymns and Hymns for this Sunday.
///
/// The hymn book is built into the apps (story 6.7); the server stores only
/// item ids of the book (`hymn-12`, `chorus-3`) with the book's edition,
/// never hymn text, and refuses numbers outside the edition. Favourites are
/// private to the member (`api.content_my_hymn_favourites`, live member
/// access); this Sunday's list is public (`api.content_public_sunday_hymns`);
/// Admin, Media and worship leaders read every Sunday's list
/// (`api.content_staff_sunday_hymns`) and change it through
/// `api.content_command`. Free of widgets and SDKs.
library;

import 'access_grants.dart';
import 'church_time.dart';
import 'wire_json.dart';

final _itemIdPattern = RegExp(r'^(hymn|chorus)-[1-9][0-9]{0,2}$');
final _editionPattern = RegExp(r'^[a-z0-9][a-z0-9.-]{0,63}$');
final _datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

String _itemId(Object? v) {
  if (v is! String || !_itemIdPattern.hasMatch(v)) {
    throw const FormatException('unexpected item');
  }
  return v;
}

String _edition(Object? v) {
  if (v is! String || !_editionPattern.hasMatch(v)) {
    throw const FormatException('unexpected edition');
  }
  return v;
}

String _date(Map json, String key) {
  final v = wireReq<String>(json, key);
  if (!_datePattern.hasMatch(v) || DateTime.tryParse(v) == null) {
    throw FormatException('unexpected $key');
  }
  return v;
}

List<String> _items(Map json, String key) =>
    List.unmodifiable(wireReq<List>(json, key).map(_itemId));

/// One saved hymn: the book's edition and the item's id.
class SavedHymn {
  const SavedHymn({
    required this.edition,
    required this.itemId,
    required this.savedAt,
  });

  factory SavedHymn.fromJson(Object? json) {
    final m = wireMap(json, 'favourite');
    return SavedHymn(
      edition: _edition(m['edition']),
      itemId: _itemId(m['item']),
      savedAt: wireInstant(m, 'saved_at'),
    );
  }

  final String edition;
  final String itemId;
  final DateTime savedAt;
}

/// `api.content_my_hymn_favourites`: the signed-in member's own saved hymns,
/// newest first. Nobody else's favourites can be read.
class MyHymnFavourites {
  const MyHymnFavourites({required this.favourites, required this.truncated});

  factory MyHymnFavourites.fromJson(Object? json) {
    final m = wireMap(json, 'favourites');
    return MyHymnFavourites(
      favourites: List.unmodifiable(
        wireReq<List>(m, 'favourites').map(SavedHymn.fromJson),
      ),
      truncated: wireReq<bool>(m, 'truncated'),
    );
  }

  static const empty = MyHymnFavourites(favourites: [], truncated: false);

  final List<SavedHymn> favourites;
  final bool truncated;

  /// The saved item ids (a later edition of the same book keeps its numbers).
  Set<String> get itemIds => {for (final f in favourites) f.itemId};

  bool contains(String itemId) => favourites.any((f) => f.itemId == itemId);

  /// The favourites with [itemId] saved ([saved]) or removed, newest first.
  MyHymnFavourites withItem(
    String itemId, {
    required bool saved,
    required String edition,
    required DateTime at,
  }) => MyHymnFavourites(
    favourites: List.unmodifiable([
      if (saved) SavedHymn(edition: edition, itemId: itemId, savedAt: at),
      for (final f in favourites)
        if (f.itemId != itemId) f,
    ]),
    truncated: truncated,
  );
}

/// `api.content_public_sunday_hymns`: this Sunday's list (church time), as
/// everyone reads it: the date, the edition and the item ids in order. No
/// items when nothing is set or the list was cleared.
class PublicSundayHymns {
  const PublicSundayHymns({
    required this.sunday,
    required this.edition,
    required this.items,
    required this.publicationRevision,
  });

  factory PublicSundayHymns.fromJson(Object? json) {
    // Keys a later entry adds are ignored, so an older app keeps reading.
    final m = wireMap(json, 'sunday hymns');
    final items = _items(m, 'items');
    final edition = m['edition'];
    final revision = m['publication_revision'];
    if (items.isEmpty != (edition == null) ||
        items.isEmpty != (revision == null)) {
      throw const FormatException('unexpected sunday hymns shape');
    }
    return PublicSundayHymns(
      sunday: _date(m, 'sunday'),
      edition: edition == null ? null : _edition(edition),
      items: items,
      publicationRevision: revision == null
          ? null
          : wireRevision(m, 'publication_revision'),
    );
  }

  /// `YYYY-MM-DD`, a church-time Sunday.
  final String sunday;
  final String? edition;
  final List<String> items;
  final int? publicationRevision;

  /// The item ids to mark when the device's church date is in [sunday]'s
  /// week (the list names that Sunday), else none.
  Set<String> idsFor(DateTime now) =>
      SundayHymnsWindow.thisSunday(now) == sunday ? {...items} : const {};
}

/// The church-time week of a Sunday list (Africa/Lusaka).
abstract final class SundayHymnsWindow {
  /// This Sunday as `YYYY-MM-DD`: today on a Sunday, else the coming Sunday
  /// (the server answers the same date).
  static String thisSunday(DateTime now) {
    final w = ChurchTime.wall(now);
    final day = DateTime.utc(w.year, w.month, w.day);
    return ChurchTime.ymd(day.add(Duration(days: (7 - day.weekday) % 7)));
  }

  /// Home shows Hymns for this Sunday from Saturday 00:00 to Sunday 23:59
  /// church time.
  static bool onHome(DateTime now) {
    final weekday = ChurchTime.wall(now).weekday;
    return weekday == DateTime.saturday || weekday == DateTime.sunday;
  }

  /// The Sunday [weeks] after this Sunday.
  static String sundayAfter(String sunday, int weeks) {
    final d = DateTime.parse('${sunday}T00:00:00Z');
    return ChurchTime.ymd(d.add(Duration(days: 7 * weeks)));
  }
}

/// One edition of the built-in book the server accepts.
class HymnEdition {
  const HymnEdition({
    required this.edition,
    required this.hymns,
    required this.choruses,
  });

  factory HymnEdition.fromJson(Object? json) {
    final m = wireMap(json, 'edition');
    return HymnEdition(
      edition: _edition(m['edition']),
      hymns: wireReq<int>(m, 'hymns'),
      choruses: wireReq<int>(m, 'choruses'),
    );
  }

  final String edition;
  final int hymns;
  final int choruses;
}

/// The capacity in which the reader sets the Sunday list.
enum SundayHymnsCapacity {
  admin('admin', 'Admin'),
  media('media', 'Media'),
  worshipLeader('worship_leader', 'Worship leader');

  const SundayHymnsCapacity(this.wire, this.label);
  final String wire;
  final String label;

  static SundayHymnsCapacity parse(Object? v) => values.firstWhere(
    (c) => c.wire == v,
    orElse: () => throw const FormatException('unexpected capacity'),
  );
}

/// One Sunday's current list as its editors read it.
class StaffSundayList {
  const StaffSundayList({
    required this.sunday,
    required this.revisionNo,
    required this.edition,
    required this.items,
    required this.savedAt,
    required this.savedBy,
    required this.savedCapacity,
  });

  factory StaffSundayList.fromJson(Object? json) {
    final m = wireMap(json, 'sunday list');
    final items = _items(m, 'items');
    final edition = m['edition'];
    if (items.isEmpty != (edition == null)) {
      throw const FormatException('unexpected sunday list shape');
    }
    return StaffSundayList(
      sunday: _date(m, 'sunday'),
      revisionNo: wireRevision(m, 'revision_no'),
      edition: edition == null ? null : _edition(edition),
      items: items,
      savedAt: wireInstant(m, 'saved_at'),
      savedBy: wireReq<String>(m, 'saved_by'),
      savedCapacity: SundayHymnsCapacity.parse(m['saved_capacity']),
    );
  }

  final String sunday;
  final int revisionNo;
  final String? edition;
  final List<String> items;
  final DateTime savedAt;

  /// The saver's name, or `Former member`.
  final String savedBy;
  final SundayHymnsCapacity savedCapacity;

  bool get cleared => items.isEmpty;
}

/// A member who holds the worship-leader scope.
class WorshipLeader {
  const WorshipLeader({
    required this.memberId,
    required this.displayName,
    required this.grantsRevision,
  });

  factory WorshipLeader.fromJson(Object? json) {
    final m = wireMap(json, 'worship leader');
    return WorshipLeader(
      memberId: wireReq<String>(m, 'member_id'),
      displayName: wireReq<String>(m, 'display_name'),
      grantsRevision: wireRevision(m, 'grants_revision'),
    );
  }

  final String memberId;
  final String displayName;

  /// The member's grant-set revision (expected revision of the grant
  /// command).
  final int grantsRevision;
}

/// An approved member an Admin may make a worship leader.
class WorshipLeaderCandidate {
  const WorshipLeaderCandidate({
    required this.memberId,
    required this.displayName,
    required this.account,
    required this.grantsRevision,
  });

  factory WorshipLeaderCandidate.fromJson(Object? json) {
    final m = wireMap(json, 'member');
    return WorshipLeaderCandidate(
      memberId: wireReq<String>(m, 'member_id'),
      displayName: wireReq<String>(m, 'display_name'),
      account: wireAccount(m['account']),
      grantsRevision: wireRevision(m, 'grants_revision'),
    );
  }

  final String memberId;
  final String displayName;
  final AccountStanding account;
  final int grantsRevision;
}

/// `api.content_staff_sunday_hymns`: the Sunday lists for Admin, Media and
/// worship leaders; an Admin also gets the worship leaders and the members to
/// choose from (null for everyone else).
class StaffSundayHymns {
  const StaffSundayHymns({
    required this.capacity,
    required this.listId,
    required this.revision,
    required this.thisSunday,
    required this.editions,
    required this.sundays,
    required this.worshipLeaders,
    required this.members,
    required this.membersTruncated,
  });

  factory StaffSundayHymns.fromJson(Object? json) {
    final m = wireMap(json, 'staff sunday hymns');
    final leaders = m['worship_leaders'];
    final members = m['members'];
    if ((leaders == null) != (members == null)) {
      throw const FormatException('unexpected staff sunday hymns shape');
    }
    return StaffSundayHymns(
      capacity: SundayHymnsCapacity.parse(m['capacity']),
      listId: wireReq<String>(m, 'list_id'),
      revision: wireRevision(m),
      thisSunday: _date(m, 'this_sunday'),
      editions: List.unmodifiable(
        wireReq<List>(m, 'editions').map(HymnEdition.fromJson),
      ),
      sundays: List.unmodifiable(
        wireReq<List>(m, 'sundays').map(StaffSundayList.fromJson),
      ),
      worshipLeaders: leaders == null
          ? null
          : List.unmodifiable(
              wireReq<List>(m, 'worship_leaders').map(WorshipLeader.fromJson),
            ),
      members: members == null
          ? null
          : List.unmodifiable(
              wireReq<List>(m, 'members').map(WorshipLeaderCandidate.fromJson),
            ),
      membersTruncated: wireOpt<bool>(m, 'members_truncated') ?? false,
    );
  }

  final SundayHymnsCapacity capacity;

  /// The church's one Sunday-list record (the worship-leader scope's target).
  final String listId;

  /// The record's revision: the expected revision of every list command.
  final int revision;
  final String thisSunday;
  final List<HymnEdition> editions;

  /// Every Sunday from 8 weeks back to 52 ahead that has a list, by date.
  final List<StaffSundayList> sundays;
  final List<WorshipLeader>? worshipLeaders;
  final List<WorshipLeaderCandidate>? members;
  final bool membersTruncated;

  /// The reader manages worship leaders (Admin).
  bool get managesWorshipLeaders => worshipLeaders != null;

  StaffSundayList? listFor(String sunday) {
    for (final s in sundays) {
      if (s.sunday == sunday) return s;
    }
    return null;
  }

  HymnEdition? editionNamed(String edition) {
    for (final e in editions) {
      if (e.edition == edition) return e;
    }
    return null;
  }
}

/// The Content command function and the story 6.8 commands (1.4 envelope).
abstract final class HymnListCommands {
  static const function = 'content_command';
  static const saveFavourite = 'content.save_hymn_favourite';
  static const removeFavourite = 'content.remove_hymn_favourite';
  static const setSunday = 'content.set_sunday_hymns';
  static const clearSunday = 'content.clear_sunday_hymns';

  /// The Content scope kind an Admin grants (2.3 grant command).
  static const worshipLeaderScope = 'worship_leader';

  /// At most this many items in one Sunday's list (the server's limit).
  static const maxSundayItems = 12;
}

/// Does [grants] set Hymns for this Sunday (Admin, Media or a worship
/// leader)? Navigation only: the server checks every read and command.
bool setsSundayHymns(MemberGrants? grants) =>
    grants != null &&
    (grants.isAdmin ||
        grants.hasRole(ChurchRoles.media) ||
        grants.scopes.any(
          (s) => s.scopeKind == HymnListCommands.worshipLeaderScope,
        ));

/// Application port for the story 6.8 reads. Never throws.
abstract interface class HymnListsRepository {
  /// The signed-in member's own saved hymns.
  Future<AccessRead<MyHymnFavourites>> fetchMyFavourites();

  /// Everyone (signed in or not): this Sunday's list.
  Future<AccessRead<PublicSundayHymns>> fetchPublicSundayHymns();

  /// Admin, Media and worship leaders: every Sunday's list.
  Future<AccessRead<StaffSundayHymns>> fetchStaffSundayHymns();
}

class UnconfiguredHymnListsRepository implements HymnListsRepository {
  const UnconfiguredHymnListsRepository();

  @override
  Future<AccessRead<MyHymnFavourites>> fetchMyFavourites() async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<PublicSundayHymns>> fetchPublicSundayHymns() async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<StaffSundayHymns>> fetchStaffSundayHymns() async =>
      const AccessReadDenied(AccessDenial.unavailable);
}
