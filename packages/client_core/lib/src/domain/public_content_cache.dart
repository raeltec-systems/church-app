import 'dart:typed_data';

import 'content_banners.dart';
import 'content_events.dart';
import 'content_giving.dart';
import 'content_bible.dart';
import 'content_sermons.dart';

/// The only public list reads that may enter a mobile offline snapshot.
abstract final class PublicContentCacheKeys {
  static const calendar = 'content_public_events';
  static const homeBanners = 'content_public_banners';
  static const givingMethods = 'content_public_giving_methods';
  static const bibleChapter = 'content_public_bible_chapter';
  static const sermons = 'content_public_sermons';
}

/// A saved, anonymous public list projection and when the complete snapshot
/// was committed to local storage.
class PublicContentSnapshot<T> {
  const PublicContentSnapshot({required this.value, required this.savedAt});

  final T value;
  final DateTime savedAt;
}

enum PublicContentCacheRefusal {
  unsupportedRead,
  unexpectedProjection,
  offlineRightsNotCleared,
  imageLoaderRequired,
}

sealed class PublicContentCacheWrite {
  const PublicContentCacheWrite();
}

class PublicContentCacheSaved extends PublicContentCacheWrite {
  const PublicContentCacheSaved({
    required this.savedAt,
    required this.savedRows,
    this.omittedRows = 0,
  });

  final DateTime savedAt;
  final int savedRows;
  final int omittedRows;
}

class PublicContentCacheRefused extends PublicContentCacheWrite {
  const PublicContentCacheRefused(this.reason);

  final PublicContentCacheRefusal reason;
}

class PublicContentCacheUnavailable extends PublicContentCacheWrite {
  const PublicContentCacheUnavailable();
}

/// The persistence seam for the allowlisted public list reads. Detail, staff
/// and other public reads have no method that can cache them.
abstract interface class PublicContentCache {
  Future<PublicContentSnapshot<PublicSermons>?> readSermons();
  Future<PublicContentSnapshot<PublicEvents>?> readEvents();

  Future<PublicContentSnapshot<PublicBanners>?> readBanners();

  Future<PublicContentSnapshot<PublicGivingMethods>?> readGivingMethods();

  /// The most recently saved offline-cleared chapter. This independent lookup
  /// supports a cold launch before any network catalog call can succeed.
  Future<PublicContentSnapshot<PublicBibleChapter>?> readBibleChapter();

  /// Remove a method after a successful fresh detail read says it is hidden.
  Future<void> removeGivingMethod(String methodId);

  /// Reconcile a still-published method detail into an existing list row.
  /// This leaves the list's order, flags and snapshot time intact.
  Future<void> reconcileGivingMethod(
    PublicGivingMethod method, {
    required Future<Uint8List?> Function(PublicGivingLogo logo) loadGivingLogo,
  });

  /// The string key is checked at runtime so unsupported and protected
  /// projections can be refused explicitly instead of being persisted.
  Future<PublicContentCacheWrite> writeRead(
    String readKey,
    Object projection, {
    Future<Uint8List?> Function(PublicBanner banner)? loadBannerImage,
    Future<Uint8List?> Function(PublicGivingLogo logo)? loadGivingLogo,
    Future<Uint8List?> Function(SermonPoster poster)? loadSermonPoster,
  });
}

/// Shared by staff web and unconfigured builds; these surfaces persist no
/// public domain content.
class NoPublicContentCache implements PublicContentCache {
  const NoPublicContentCache();

  @override
  Future<PublicContentSnapshot<PublicSermons>?> readSermons() async => null;

  @override
  Future<PublicContentSnapshot<PublicEvents>?> readEvents() async => null;

  @override
  Future<PublicContentSnapshot<PublicBanners>?> readBanners() async => null;

  @override
  Future<PublicContentSnapshot<PublicGivingMethods>?>
  readGivingMethods() async => null;

  @override
  Future<PublicContentSnapshot<PublicBibleChapter>?> readBibleChapter() async =>
      null;

  @override
  Future<void> removeGivingMethod(String methodId) async {}

  @override
  Future<void> reconcileGivingMethod(
    PublicGivingMethod method, {
    required Future<Uint8List?> Function(PublicGivingLogo logo) loadGivingLogo,
  }) async {}

  @override
  Future<PublicContentCacheWrite> writeRead(
    String readKey,
    Object projection, {
    Future<Uint8List?> Function(PublicBanner banner)? loadBannerImage,
    Future<Uint8List?> Function(PublicGivingLogo logo)? loadGivingLogo,
    Future<Uint8List?> Function(SermonPoster poster)? loadSermonPoster,
  }) async => const PublicContentCacheUnavailable();
}
