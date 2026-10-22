import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:church_client_core/church_client_core.dart'
    show
        PublicBanner,
        PublicBanners,
        PublicContentCache,
        PublicContentCacheKeys,
        PublicContentCacheRefusal,
        PublicContentCacheRefused,
        PublicContentCacheSaved,
        PublicContentSnapshot,
        PublicContentCacheUnavailable,
        PublicContentCacheWrite,
        PublicEvent,
        PublicEvents;
import 'package:path_provider/path_provider.dart';

/// The only file-backed public content cache. It stores exactly the Calendar
/// and Home list projections, plus eligible banner image bytes.
class PublicContentCacheAdapter implements PublicContentCache {
  PublicContentCacheAdapter({
    Future<Directory> Function()? supportDirectory,
    DateTime Function()? clock,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _clock = clock ?? DateTime.now;

  static const _manifestVersion = 1;
  static const _maxImageBytes = 5 * 1024 * 1024;
  static const _allowedReads = {
    PublicContentCacheKeys.calendar,
    PublicContentCacheKeys.homeBanners,
  };

  final Future<Directory> Function() _supportDirectory;
  final DateTime Function() _clock;
  Future<void> _writeQueue = Future<void>.value();

  Future<Directory> _directory() async {
    final support = await _supportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}bic-kafue'
      '${Platform.pathSeparator}public-content-v1',
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<File> _manifest(Directory directory) async =>
      File('${directory.path}${Platform.pathSeparator}manifest.json');

  Future<Map<String, Object?>?> _readManifest(Directory directory) async {
    try {
      final file = await _manifest(directory);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (!_hasKeys(decoded, const {'version', 'reads'}) ||
          decoded['version'] != _manifestVersion ||
          decoded['reads'] is! Map) {
        return null;
      }
      final reads = Map<String, Object?>.from(decoded['reads'] as Map);
      if (reads.keys.any((key) => !_allowedReads.contains(key))) return null;
      return {'version': _manifestVersion, 'reads': reads};
    } catch (_) {
      return null;
    }
  }

  @override
  Future<PublicContentSnapshot<PublicEvents>?> readEvents() async {
    try {
      final directory = await _directory();
      final manifest = await _readManifest(directory);
      final entry =
          (manifest?['reads'] as Map?)?[PublicContentCacheKeys.calendar];
      if (!_hasKeys(entry, const {'saved_at', 'projection'})) return null;
      final projection = entry['projection'];
      if (!_hasKeys(projection, const {'events', 'truncated'}) ||
          projection['events'] is! List ||
          projection['truncated'] is! bool) {
        return null;
      }
      for (final raw in projection['events'] as List) {
        if (!_hasKeys(raw, _eventKeys) || raw['offline_allowed'] != true) {
          return null;
        }
      }
      final events = PublicEvents.fromJson(projection);
      return PublicContentSnapshot<PublicEvents>(
        value: events,
        savedAt: _savedAt(entry['saved_at']),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<PublicContentSnapshot<PublicBanners>?> readBanners() async {
    try {
      final directory = await _directory();
      final manifest = await _readManifest(directory);
      final entry =
          (manifest?['reads'] as Map?)?[PublicContentCacheKeys.homeBanners];
      if (!_hasKeys(entry, const {'saved_at', 'projection', 'image_files'})) {
        return null;
      }
      final projection = entry['projection'];
      final imageFiles = entry['image_files'];
      if (!_hasKeys(projection, const {'banners', 'truncated'}) ||
          projection['banners'] is! List ||
          projection['truncated'] is! bool ||
          imageFiles is! Map) {
        return null;
      }
      for (final raw in projection['banners'] as List) {
        if (!_hasKeys(raw, _bannerKeys) ||
            raw['offline_allowed'] != true ||
            !_hasKeys(raw['image'], const {
              'path',
              'media_type',
              'width',
              'height',
            })) {
          return null;
        }
      }
      final source = PublicBanners.fromJson(projection).banners;
      if (source.any((banner) => !banner.offlineAllowed)) return null;
      final ids = source.map((banner) => banner.bannerId).toSet();
      if (imageFiles.keys.any((key) => !ids.contains(key))) {
        return null;
      }
      final cached = <PublicBanner>[];
      for (final banner in source) {
        if (banner.offlineAllowed != true) return null;
        final name = imageFiles[banner.bannerId];
        if (name is! String || name != _imageFileName(banner)) continue;
        final file = File('${directory.path}${Platform.pathSeparator}$name');
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty || bytes.length > _maxImageBytes) continue;
        cached.add(banner.withOfflineImageBytes(bytes));
      }
      return PublicContentSnapshot<PublicBanners>(
        value: PublicBanners(
          List.unmodifiable(cached),
          truncated: projection['truncated'] as bool,
        ),
        savedAt: _savedAt(entry['saved_at']),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<PublicContentCacheWrite> writeRead(
    String readKey,
    Object projection, {
    Future<Uint8List?> Function(PublicBanner banner)? loadBannerImage,
  }) {
    final completer = Completer<PublicContentCacheWrite>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        completer.complete(
          await _writeRead(readKey, projection, loadBannerImage),
        );
      } catch (_) {
        completer.complete(const PublicContentCacheUnavailable());
      }
    });
    return completer.future;
  }

  Future<PublicContentCacheWrite> _writeRead(
    String readKey,
    Object projection,
    Future<Uint8List?> Function(PublicBanner banner)? loadBannerImage,
  ) async {
    if (!_allowedReads.contains(readKey)) {
      return const PublicContentCacheRefused(
        PublicContentCacheRefusal.unsupportedRead,
      );
    }
    final Map<String, Object?> entry;
    final Set<String> imageFiles = {};
    var savedRows = 0;
    var omittedRows = 0;
    try {
      if (readKey == PublicContentCacheKeys.calendar) {
        if (projection is! PublicEvents) {
          return const PublicContentCacheRefused(
            PublicContentCacheRefusal.unexpectedProjection,
          );
        }
        if (projection.events.any((event) => !event.offlineAllowed)) {
          return const PublicContentCacheRefused(
            PublicContentCacheRefusal.unexpectedProjection,
          );
        }
        final directory = await _directory();
        await _removeReadBeforeRefresh(directory, readKey);
        final savedAt = _clock().toUtc();
        final value = <String, Object?>{
          'saved_at': savedAt.toIso8601String(),
          'projection': _eventsToJson(projection),
        };
        entry = value;
        savedRows = projection.events.length;
      } else {
        if (projection is! PublicBanners) {
          return const PublicContentCacheRefused(
            PublicContentCacheRefusal.unexpectedProjection,
          );
        }
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
        final directory = await _directory();
        await _removeReadBeforeRefresh(directory, readKey);
        final eligible = <PublicBanner>[];
        final files = <String, String>{};
        for (final banner in projection.banners) {
          Uint8List? bytes;
          final name = _imageFileName(banner);
          final current = File(
            '${directory.path}${Platform.pathSeparator}$name',
          );
          if (await current.exists()) {
            final existing = await current.readAsBytes();
            if (existing.isNotEmpty && existing.length <= _maxImageBytes) {
              bytes = existing;
            }
          }
          if (bytes == null) {
            try {
              bytes = await loadBannerImage!(banner);
            } catch (_) {
              bytes = null;
            }
          }
          if (bytes == null ||
              bytes.isEmpty ||
              bytes.length > _maxImageBytes ||
              !_mediaTypeMatchesExtension(banner, name)) {
            omittedRows++;
            continue;
          }
          if (!await current.exists()) {
            await _writeImage(current, bytes);
          } else if (await current.length() == 0) {
            await current.delete();
            await _writeImage(current, bytes);
          }
          eligible.add(banner);
          files[banner.bannerId] = name;
          imageFiles.add(name);
        }
        final savedAt = _clock().toUtc();
        entry = {
          'saved_at': savedAt.toIso8601String(),
          'projection': _bannersToJson(
            PublicBanners(eligible, truncated: projection.truncated),
          ),
          'image_files': files,
        };
        savedRows = eligible.length;
      }

      final directory = await _directory();
      final manifest = await _readManifest(directory);
      if (await (await _manifest(directory)).exists() && manifest == null) {
        return const PublicContentCacheUnavailable();
      }
      final reads = Map<String, Object?>.from(
        (manifest?['reads'] as Map?) ?? const {},
      )..[readKey] = entry;
      final next = jsonEncode({'version': _manifestVersion, 'reads': reads});
      await _commitManifest(directory, next);
      if (readKey == PublicContentCacheKeys.homeBanners) {
        try {
          await _removeUnusedBannerImages(directory, imageFiles);
        } catch (_) {
          // The manifest already committed; a leftover file is not readable.
        }
      }
      return PublicContentCacheSaved(
        savedAt: _savedAt(entry['saved_at']),
        savedRows: savedRows,
        omittedRows: omittedRows,
      );
    } catch (_) {
      return const PublicContentCacheUnavailable();
    }
  }

  Future<void> _writeImage(File target, Uint8List bytes) async {
    final temp = File('${target.path}.tmp-${_clock().microsecondsSinceEpoch}');
    await temp.writeAsBytes(bytes, flush: true);
    if (!await target.exists()) await temp.rename(target.path);
    if (await temp.exists()) await temp.delete();
  }

  Future<void> _commitManifest(Directory directory, String json) async {
    final file = await _manifest(directory);
    final temp = File('${file.path}.tmp-${_clock().microsecondsSinceEpoch}');
    await temp.writeAsString(json, flush: true);
    // Removing first keeps an old snapshot from surviving a failed write on
    // platforms where rename does not replace an existing destination.
    if (await file.exists()) await file.delete();
    await temp.rename(file.path);
  }

  Future<void> _removeReadBeforeRefresh(
    Directory directory,
    String readKey,
  ) async {
    final file = await _manifest(directory);
    if (!await file.exists()) return;
    final manifest = await _readManifest(directory);
    if (manifest == null) {
      await file.delete();
      await _removeUnusedBannerImages(directory, const {});
      return;
    }
    final reads = Map<String, Object?>.from(manifest['reads'] as Map);
    if (reads.remove(readKey) == null) return;
    if (reads.isEmpty) {
      await file.delete();
    } else {
      await _commitManifest(
        directory,
        jsonEncode({'version': _manifestVersion, 'reads': reads}),
      );
    }
    if (readKey == PublicContentCacheKeys.homeBanners) {
      await _removeUnusedBannerImages(directory, const {});
    }
  }

  Future<void> _removeUnusedBannerImages(
    Directory directory,
    Set<String> active,
  ) async {
    await for (final entity in directory.list()) {
      if (entity is File &&
          entity.uri.pathSegments.last.startsWith('banner-offline-') &&
          !active.contains(entity.uri.pathSegments.last)) {
        try {
          await entity.delete();
        } catch (_) {
          // A stale file is harmless once the manifest no longer references it.
        }
      }
    }
  }

  static DateTime _savedAt(Object? value) {
    if (value is! String) throw const FormatException('invalid saved_at');
    final parsed = DateTime.tryParse(value);
    if (parsed == null) throw const FormatException('invalid saved_at');
    return parsed.toUtc();
  }

  static bool _hasKeys(Object? value, Set<String> expected) =>
      value is Map &&
      value.keys.every((key) => key is String) &&
      value.keys.toSet().containsAll(expected) &&
      expected.containsAll(value.keys.cast<String>());

  static const _eventKeys = {
    'event_id',
    'title',
    'description',
    'starts_at',
    'ends_at',
    'location',
    'publication_revision',
    'published_at',
    'offline_allowed',
  };

  static const _bannerKeys = {
    'banner_id',
    'banner_kind',
    'theme_year',
    'title',
    'subtitle',
    'alt_text',
    'event_id',
    'image',
    'publication_revision',
    'rights_revision',
    'published_at',
    'offline_allowed',
  };

  static Map<String, Object?> _eventsToJson(PublicEvents events) => {
    'events': [for (final event in events.events) _eventToJson(event)],
    'truncated': events.truncated,
  };

  static Map<String, Object?> _eventToJson(PublicEvent event) => {
    'event_id': event.eventId,
    'title': event.title,
    'description': event.description,
    'starts_at': event.startsAt.toUtc().toIso8601String(),
    'ends_at': event.endsAt.toUtc().toIso8601String(),
    'location': event.location,
    'publication_revision': event.publicationRevision,
    'published_at': event.publishedAt.toUtc().toIso8601String(),
    'offline_allowed': event.offlineAllowed,
  };

  static Map<String, Object?> _bannersToJson(PublicBanners banners) => {
    'banners': [for (final banner in banners.banners) _bannerToJson(banner)],
    'truncated': banners.truncated,
  };

  static Map<String, Object?> _bannerToJson(PublicBanner banner) => {
    'banner_id': banner.bannerId,
    'banner_kind': banner.kind.wire,
    'theme_year': banner.themeYear,
    'title': banner.title,
    'subtitle': banner.subtitle,
    'alt_text': banner.altText,
    'event_id': banner.eventId,
    'image': {
      'path': banner.image.path,
      'media_type': banner.image.mediaType,
      'width': banner.image.width,
      'height': banner.image.height,
    },
    'publication_revision': banner.publicationRevision,
    'rights_revision': banner.rightsRevision,
    'published_at': banner.publishedAt.toUtc().toIso8601String(),
    'offline_allowed': banner.offlineAllowed,
  };

  static String _imageFileName(PublicBanner banner) {
    final id = banner.bannerId;
    if (!RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(id)) {
      throw const FormatException('invalid banner id');
    }
    final extension = switch (banner.image.mediaType) {
      'image/png' => 'png',
      'image/jpeg' => 'jpg',
      'image/webp' => 'webp',
      _ => throw const FormatException('invalid banner media type'),
    };
    return 'banner-offline-$id-p${banner.publicationRevision}'
        '-r${banner.rightsRevision}.$extension';
  }

  static bool _mediaTypeMatchesExtension(PublicBanner banner, String name) =>
      name.endsWith(switch (banner.image.mediaType) {
        'image/png' => '.png',
        'image/jpeg' => '.jpg',
        'image/webp' => '.webp',
        _ => '.invalid',
      });
}
