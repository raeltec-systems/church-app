/// Epic 6 entry 14 (K5): the top-bar search. Hymns are found on the device
/// in the built-in hymn book (entry 7), online or not; the published sermons,
/// events and announcements come from one bounded anonymous server read
/// (`api.content_public_search`) that answers with each kind's own public
/// projection, at most [ContentSearchLimits.perKind] of each. Bible text is
/// not searched. Free of widgets and SDKs.
library;

import 'access_grants.dart';
import 'content_announcements.dart';
import 'content_events.dart';
import 'content_sermons.dart';
import 'wire_json.dart';

abstract final class ContentSearchLimits {
  /// The shortest query the server answers (after trimming).
  static const minLength = 2;

  /// The longest query the server answers.
  static const maxLength = 100;

  /// The most items of one kind in an answer.
  static const perKind = 10;

  /// The hymns listed before "more in the hymn book".
  static const hymnsShown = 10;
}

/// The query as the server reads it: trimmed, runs of white space folded to
/// one space. Null when it is too short to send.
String? searchQueryOf(String text) {
  final q = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (q.length < ContentSearchLimits.minLength) return null;
  return q.length > ContentSearchLimits.maxLength
      ? q.substring(0, ContentSearchLimits.maxLength).trimRight()
      : q;
}

/// `api.content_public_search`: the published sermons, events and
/// announcements that match, each kind in the server's rank order.
class PublicSearchResults {
  const PublicSearchResults({
    required this.query,
    required this.sermons,
    required this.events,
    required this.announcements,
    required this.truncated,
  });

  factory PublicSearchResults.fromJson(Object? json) {
    final m = wireMap(json, 'search results');
    final query = wireReq<String>(m, 'query');
    List<T> list<T>(String key, T Function(Object?) parse) {
      final items = wireReq<List>(m, key);
      if (items.length > ContentSearchLimits.perKind) {
        throw FormatException('unexpected $key length');
      }
      return List.unmodifiable(items.map(parse));
    }

    return PublicSearchResults(
      query: query,
      sermons: list('sermons', PublicSermon.fromJson),
      events: list('events', PublicEvent.fromJson),
      announcements: list('announcements', PublicAnnouncement.fromJson),
      truncated: wireReq<bool>(m, 'truncated'),
    );
  }

  /// The query the server searched for (trimmed and folded).
  final String query;
  final List<PublicSermon> sermons;
  final List<PublicEvent> events;
  final List<PublicAnnouncement> announcements;

  /// A kind had more matches than the answer lists.
  final bool truncated;

  bool get isEmpty =>
      sermons.isEmpty && events.isEmpty && announcements.isEmpty;
}

/// Application port for the search read. Never throws.
abstract interface class ContentSearchRepository {
  /// Everyone (signed in or not). [query] is a [searchQueryOf] result.
  Future<AccessRead<PublicSearchResults>> search(String query);
}

class UnconfiguredContentSearchRepository implements ContentSearchRepository {
  const UnconfiguredContentSearchRepository();

  @override
  Future<AccessRead<PublicSearchResults>> search(String query) async =>
      const AccessReadDenied(AccessDenial.unavailable);
}
