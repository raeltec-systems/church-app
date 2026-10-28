import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/content_search.dart';

// Epic 6 entry 14: the top-bar search's server half. Hymns are searched on
// the device (hymnBookProvider); this asks `api.content_public_search` for the
// published sermons, events and announcements. Answers are held in memory
// only, for the open search screen, and an answer to an older query never
// replaces a newer one.

/// The search read (everyone, signed in or not).
final contentSearchRepositoryProvider = Provider<ContentSearchRepository>(
  (ref) => const UnconfiguredContentSearchRepository(),
);

class ContentSearchState {
  const ContentSearchState({this.query, this.loading = false, this.result});

  /// The query asked (null: nothing long enough to ask the server).
  final String? query;
  final bool loading;

  /// The server's answer for [query] (null while it is asked).
  final AccessRead<PublicSearchResults>? result;
}

class ContentSearchController extends Notifier<ContentSearchState> {
  int _asked = 0;

  @override
  ContentSearchState build() => const ContentSearchState();

  /// Asks the server for [text] (folded by [searchQueryOf]); a query too
  /// short to send clears the answer. The same query is asked once, unless
  /// [again] (Try again).
  Future<void> search(String text, {bool again = false}) async {
    final query = searchQueryOf(text);
    if (query == null) {
      _asked++;
      state = const ContentSearchState();
      return;
    }
    if (!again &&
        query == state.query &&
        (state.loading || state.result != null)) {
      return;
    }
    final asked = ++_asked;
    state = ContentSearchState(query: query, loading: true);
    final r = await ref.read(contentSearchRepositoryProvider).search(query);
    if (!ref.mounted || asked != _asked) return;
    state = ContentSearchState(query: query, result: r);
  }

  /// Asks the current query again.
  Future<void> retry() async {
    final q = state.query;
    if (q != null) await search(q, again: true);
  }
}

final contentSearchProvider =
    NotifierProvider.autoDispose<ContentSearchController, ContentSearchState>(
      ContentSearchController.new,
    );
