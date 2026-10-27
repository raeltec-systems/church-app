import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/hymn_book.dart';

/// Story 6.7: reads the hymn book bundled in this package. Both apps carry
/// the asset, so the book works in every build, signed in or not, with or
/// without a connection. An asset read is not persistence (AD-13): nothing
/// is written. Books larger than 64 KiB are parsed in a background isolate
/// so a several-hundred-hymn book does not stall the first frame.
class BundledHymnBookSource implements HymnBookSource {
  const BundledHymnBookSource({this.bundle});

  /// The asset's key as the apps see a package asset.
  static const assetKey =
      'packages/church_client_core/assets/hymn_book/hymn_book.json';
  static const _isolateThreshold = 64 * 1024;

  final AssetBundle? bundle;

  @override
  Future<HymnBook> load() async {
    final text = await (bundle ?? rootBundle).loadString(
      assetKey,
      cache: false,
    );
    return text.length > _isolateThreshold
        ? compute(parseHymnBookJson, text)
        : parseHymnBookJson(text);
  }
}

/// Where the hymn book comes from; tests replace it.
final hymnBookSourceProvider = Provider<HymnBookSource>(
  (ref) => const BundledHymnBookSource(),
);

/// The hymn book, read once per app run. A failure stays on screen (no
/// automatic retry) until the reader presses Try again, which invalidates
/// this provider.
final hymnBookProvider = FutureProvider<HymnBook>(
  (ref) => ref.watch(hymnBookSourceProvider).load(),
  retry: (retryCount, error) => null,
);

/// The two views of the Bible & Hymns tab.
enum BibleHymnsView { bible, hymns }

/// The tab's chosen view, remembered while the app runs.
class BibleHymnsViewController extends Notifier<BibleHymnsView> {
  @override
  BibleHymnsView build() => BibleHymnsView.bible;

  void show(BibleHymnsView view) => state = view;
}

final bibleHymnsViewProvider =
    NotifierProvider<BibleHymnsViewController, BibleHymnsView>(
      BibleHymnsViewController.new,
    );
