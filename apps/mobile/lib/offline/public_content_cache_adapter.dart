import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:church_client_core/church_client_core.dart'
    show
        PublicBanner,
        PublicBanners,
        PublicBibleChapter,
        PublicContentCache,
        PublicContentCacheKeys,
        PublicContentCacheRefusal,
        PublicContentCacheRefused,
        PublicContentCacheSaved,
        PublicContentSnapshot,
        PublicContentCacheUnavailable,
        PublicContentCacheWrite,
        PublicEvent,
        PublicEvents,
        PublicGivingLogo,
        PublicGivingMethod,
        PublicGivingMethods,
        PublicSermons,
        PublicSermonSeries,
        SermonPoster;
import 'package:path_provider/path_provider.dart';

Future<List<T>> _boundedMap<T, E>(
  List<E> values, {
  required int concurrency,
  required Future<T> Function(E value) convert,
}) async {
  if (values.isEmpty) return const [];
  final results = List<T?>.filled(values.length, null);
  var next = 0;

  Future<void> worker() async {
    while (true) {
      final index = next++;
      if (index >= values.length) return;
      results[index] = await convert(values[index]);
    }
  }

  final workerCount = values.length < concurrency ? values.length : concurrency;
  await Future.wait(List.generate(workerCount, (_) => worker()));
  return results.cast<T>();
}

/// The only file-backed public content cache. It stores exactly the Calendar,
/// Home, giving and one offline-cleared Bible chapter, plus allowed image bytes.
class PublicContentCacheAdapter implements PublicContentCache {
  PublicContentCacheAdapter({
    Future<Directory> Function()? supportDirectory,
    DateTime Function()? clock,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _clock = clock ?? DateTime.now;

  static const _manifestVersion = 1;
  static const _maxImageBytes = 5 * 1024 * 1024;
  static const _maxGivingLogoBytes = 2 * 1024 * 1024;
  static const _givingLogoConcurrency = 4;
  static const _allowedReads = {
    PublicContentCacheKeys.calendar,
    PublicContentCacheKeys.homeBanners,
    PublicContentCacheKeys.givingMethods,
    PublicContentCacheKeys.bibleChapter,
    PublicContentCacheKeys.sermons,
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
  Future<PublicContentSnapshot<PublicSermons>?> readSermons() async {
    try {
      final directory = await _directory();
      final manifest = await _readManifest(directory);
      final entry =
          (manifest?['reads'] as Map?)?[PublicContentCacheKeys.sermons];
      if (!_hasKeys(entry, const {'saved_at', 'projection', 'image_files'}) ||
          entry['image_files'] is! Map) {
        return null;
      }
      final source = PublicSermons.fromJson(entry['projection']);
      if (source.sermons.any(
            (s) =>
                !s.offlineAllowed ||
                s.youtubeVideoId != null ||
                s.rightsRevision != null,
          ) ||
          source.series.any((s) => !s.offlineAllowed)) {
        return null;
      }
      final allSeries = <String, PublicSermonSeries>{
        for (final s in source.series) s.seriesId: s,
        for (final s in source.sermons)
          if (s.series != null) s.series!.seriesId: s.series!,
      };
      final files = entry['image_files'] as Map;
      if (files.keys.any((key) => !allSeries.containsKey(key))) return null;
      final loaded = <String, PublicSermonSeries>{};
      for (final series in allSeries.values) {
        if (!series.offlineAllowed) return null;
        final poster = series.poster;
        if (poster == null) {
          loaded[series.seriesId] = series;
          continue;
        }
        if (!poster.offlineAllowed) return null;
        final name = files[series.seriesId];
        if (name != _sermonPosterFileName(series, poster)) {
          loaded[series.seriesId] = series.withPoster(null);
          continue;
        }
        final file = File('${directory.path}${Platform.pathSeparator}$name');
        final bytes = await file.exists() ? await file.readAsBytes() : null;
        loaded[series.seriesId] = series.withPoster(
          bytes == null || bytes.isEmpty || bytes.length > _maxImageBytes
              ? null
              : poster.withBytes(bytes),
        );
      }
      return PublicContentSnapshot(
        value: PublicSermons(
          sermons: source.sermons
              .map(
                (s) => s.withSeries(
                  s.series == null ? null : loaded[s.series!.seriesId],
                ),
              )
              .toList(),
          series: source.series.map((s) => loaded[s.seriesId]!).toList(),
          truncated: source.truncated,
        ),
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
  Future<PublicContentSnapshot<PublicGivingMethods>?>
  readGivingMethods() async {
    try {
      final directory = await _directory();
      final manifest = await _readManifest(directory);
      final entry =
          (manifest?['reads'] as Map?)?[PublicContentCacheKeys.givingMethods];
      if (!_hasKeys(entry, const {'saved_at', 'projection', 'image_files'})) {
        return null;
      }
      final projection = entry['projection'];
      final imageFiles = entry['image_files'];
      if (!_hasKeys(projection, const {'methods', 'truncated', 'sample'}) ||
          projection['methods'] is! List ||
          projection['truncated'] is! bool ||
          projection['sample'] is! bool ||
          imageFiles is! Map) {
        return null;
      }
      for (final raw in projection['methods'] as List) {
        if (!_hasKeys(raw, _givingMethodKeys) ||
            raw['details'] is! List ||
            raw['steps'] is! List) {
          return null;
        }
      }
      final source = PublicGivingMethods.fromJson(projection);
      final ids = source.methods.map((method) => method.methodId).toSet();
      if (imageFiles.keys.any((key) => !ids.contains(key))) return null;
      final methods = <PublicGivingMethod>[];
      for (final method in source.methods) {
        final logo = method.logo;
        final name = imageFiles[method.methodId];
        if (logo == null ||
            !logo.offlineAllowed ||
            name is! String ||
            name != _givingLogoFileName(method, logo)) {
          methods.add(method);
          continue;
        }
        final file = File('${directory.path}${Platform.pathSeparator}$name');
        if (!await file.exists()) {
          methods.add(method);
          continue;
        }
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty ||
            bytes.length > _maxGivingLogoBytes ||
            !_givingLogoMediaTypeMatchesExtension(logo, name)) {
          methods.add(method);
          continue;
        }
        methods.add(method.withLogo(logo.withOfflineBytes(bytes)));
      }
      return PublicContentSnapshot<PublicGivingMethods>(
        value: PublicGivingMethods(
          sample: source.sample,
          methods: List.unmodifiable(methods),
          truncated: source.truncated,
        ),
        savedAt: _savedAt(entry['saved_at']),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<PublicContentSnapshot<PublicBibleChapter>?> readBibleChapter() async {
    try {
      final directory = await _directory();
      final manifest = await _readManifest(directory);
      final entry =
          (manifest?['reads'] as Map?)?[PublicContentCacheKeys.bibleChapter];
      if (!_hasKeys(entry, const {'saved_at', 'projection'})) return null;
      final projection = entry['projection'];
      if (!_hasKeys(projection, _bibleChapterKeys) ||
          projection['offline_allowed'] != true) {
        return null;
      }
      final chapter = PublicBibleChapter.fromCacheJson(projection);
      return PublicContentSnapshot<PublicBibleChapter>(
        value: chapter,
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
    Future<Uint8List?> Function(PublicGivingLogo logo)? loadGivingLogo,
    Future<Uint8List?> Function(SermonPoster poster)? loadSermonPoster,
  }) {
    final completer = Completer<PublicContentCacheWrite>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        completer.complete(
          await _writeRead(
            readKey,
            projection,
            loadBannerImage,
            loadGivingLogo,
            loadSermonPoster,
          ),
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
    Future<Uint8List?> Function(PublicGivingLogo logo)? loadGivingLogo,
    Future<Uint8List?> Function(SermonPoster poster)? loadSermonPoster,
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
      } else if (readKey == PublicContentCacheKeys.homeBanners) {
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
      } else if (readKey == PublicContentCacheKeys.sermons) {
        if (projection is! PublicSermons) {
          return const PublicContentCacheRefused(
            PublicContentCacheRefusal.unexpectedProjection,
          );
        }
        // Strict round trip refuses extra/private fields and unsafe notes before writes.
        final source = PublicSermons.fromJson(projection.toCacheJson());
        if (source.sermons.any((s) => !s.offlineAllowed) ||
            source.series.any((s) => !s.offlineAllowed)) {
          return const PublicContentCacheRefused(
            PublicContentCacheRefusal.offlineRightsNotCleared,
          );
        }
        final directory = await _directory();
        final allSeries = <String, PublicSermonSeries>{
          for (final s in source.series) s.seriesId: s,
          for (final s in source.sermons)
            if (s.series != null) s.series!.seriesId: s.series!,
        };
        final cached = <String, PublicSermonSeries>{};
        final files = <String, String>{};
        for (final series in allSeries.values) {
          if (!series.offlineAllowed) {
            continue;
          }
          final poster = series.poster;
          if (poster == null ||
              !poster.offlineAllowed ||
              loadSermonPoster == null) {
            cached[series.seriesId] = series.withPoster(null);
            continue;
          }
          final name = _sermonPosterFileName(series, poster);
          final current = File(
            '${directory.path}${Platform.pathSeparator}$name',
          );
          Uint8List? bytes = await current.exists()
              ? await current.readAsBytes()
              : null;
          if (bytes == null || bytes.isEmpty || bytes.length > _maxImageBytes) {
            try {
              bytes = await loadSermonPoster(poster);
            } catch (_) {
              bytes = null;
            }
          }
          if (bytes == null || bytes.isEmpty || bytes.length > _maxImageBytes) {
            cached[series.seriesId] = series.withPoster(null);
            omittedRows++;
            continue;
          }
          if (!await current.exists() ||
              await current.length() == 0 ||
              await current.length() > _maxImageBytes) {
            await _writeImage(current, bytes);
          }
          cached[series.seriesId] = series;
          files[series.seriesId] = name;
          imageFiles.add(name);
        }
        final value = PublicSermons(
          sermons: source.sermons
              .map(
                (s) => s.withSeries(
                  s.series == null ? null : cached[s.series!.seriesId],
                ),
              )
              .toList(),
          series: source.series.map((s) => cached[s.seriesId]!).toList(),
          truncated: source.truncated,
        );
        entry = {
          'saved_at': _clock().toUtc().toIso8601String(),
          'projection': value.toCacheJson(),
          'image_files': files,
        };
        savedRows = source.sermons.length;
      } else if (readKey == PublicContentCacheKeys.bibleChapter) {
        if (projection is! PublicBibleChapter) {
          return const PublicContentCacheRefused(
            PublicContentCacheRefusal.unexpectedProjection,
          );
        }
        if (!projection.offlineAllowed) {
          return const PublicContentCacheRefused(
            PublicContentCacheRefusal.offlineRightsNotCleared,
          );
        }
        final cacheJson = projection.toCacheJson();
        // Re-parse through the same strict allowlist before any local write.
        PublicBibleChapter.fromCacheJson(cacheJson);
        final savedAt = _clock().toUtc();
        entry = {
          'saved_at': savedAt.toIso8601String(),
          'projection': cacheJson,
        };
        savedRows = 1;
      } else {
        if (projection is! PublicGivingMethods) {
          return const PublicContentCacheRefused(
            PublicContentCacheRefusal.unexpectedProjection,
          );
        }
        final directory = await _directory();
        final methods = <Map<String, Object?>>[];
        final files = <String, String>{};
        final cachedRows = await _boundedMap(
          projection.methods,
          concurrency: _givingLogoConcurrency,
          convert: (method) async {
            final serialized = method.toCacheJson();
            final logo = method.logo;
            if (logo == null ||
                !logo.offlineAllowed ||
                loadGivingLogo == null) {
              serialized['logo'] = null;
              return (
                serialized: serialized,
                fileName: null,
                omitted: logo != null,
              );
            }
            Uint8List? bytes;
            final name = _givingLogoFileName(method, logo);
            final current = File(
              '${directory.path}${Platform.pathSeparator}$name',
            );
            if (await current.exists()) {
              final existing = await current.readAsBytes();
              if (existing.isNotEmpty &&
                  existing.length <= _maxGivingLogoBytes) {
                bytes = existing;
              }
            }
            if (bytes == null) {
              try {
                bytes = await loadGivingLogo(logo);
              } catch (_) {
                bytes = null;
              }
            }
            if (bytes == null ||
                bytes.isEmpty ||
                bytes.length > _maxGivingLogoBytes ||
                !_givingLogoMediaTypeMatchesExtension(logo, name)) {
              serialized['logo'] = null;
              return (serialized: serialized, fileName: null, omitted: true);
            }
            if (!await current.exists()) {
              await _writeImage(current, bytes);
            } else if (await current.length() == 0) {
              await current.delete();
              await _writeImage(current, bytes);
            }
            return (serialized: serialized, fileName: name, omitted: false);
          },
        );
        for (var i = 0; i < cachedRows.length; i++) {
          final row = cachedRows[i];
          methods.add(row.serialized);
          if (row.fileName case final name?) {
            final methodId = projection.methods[i].methodId;
            files[methodId] = name;
            imageFiles.add(name);
          }
          if (row.omitted) omittedRows++;
        }
        final savedAt = _clock().toUtc();
        entry = {
          'saved_at': savedAt.toIso8601String(),
          'projection': {
            'sample': projection.sample,
            'methods': methods,
            'truncated': projection.truncated,
          },
          'image_files': files,
        };
        savedRows = projection.methods.length;
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
      if (readKey == PublicContentCacheKeys.sermons) {
        try {
          await for (final entity in directory.list()) {
            if (entity is File &&
                entity.uri.pathSegments.last.startsWith(
                  'sermon-poster-offline-',
                ) &&
                !imageFiles.contains(entity.uri.pathSegments.last)) {
              await entity.delete();
            }
          }
        } catch (_) {
          /* Manifest committed; leftover files are not readable. */
        }
      }
      if (readKey == PublicContentCacheKeys.homeBanners) {
        try {
          await _removeUnusedBannerImages(directory, imageFiles);
        } catch (_) {
          // The manifest already committed; a leftover file is not readable.
        }
      }
      if (readKey == PublicContentCacheKeys.givingMethods) {
        try {
          await _removeUnusedGivingLogos(directory, imageFiles);
        } catch (_) {
          // A leftover logo is unreadable once the manifest no longer points at it.
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

  static String _sermonPosterFileName(
    PublicSermonSeries series,
    SermonPoster poster,
  ) {
    if (!RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(series.seriesId)) {
      throw const FormatException('invalid series id');
    }
    final extension = switch (poster.image.mediaType) {
      'image/png' => 'png',
      'image/jpeg' => 'jpg',
      'image/webp' => 'webp',
      _ => throw const FormatException('invalid poster media type'),
    };
    return 'sermon-poster-offline-${series.seriesId}-p${series.publicationRevision}-r${poster.rightsRevision}.$extension';
  }

  @override
  Future<void> removeGivingMethod(String methodId) {
    final completer = Completer<void>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        await _removeGivingMethod(methodId);
      } catch (_) {
        // A stale offline method can never override the successful detail read.
      } finally {
        completer.complete();
      }
    });
    return completer.future;
  }

  @override
  Future<void> reconcileGivingMethod(
    PublicGivingMethod method, {
    required Future<Uint8List?> Function(PublicGivingLogo logo) loadGivingLogo,
  }) {
    final completer = Completer<void>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        await _reconcileGivingMethod(method, loadGivingLogo);
      } catch (_) {
        // Cache maintenance cannot replace a successful fresh detail read.
      } finally {
        completer.complete();
      }
    });
    return completer.future;
  }

  Future<void> _reconcileGivingMethod(
    PublicGivingMethod method,
    Future<Uint8List?> Function(PublicGivingLogo logo) loadGivingLogo,
  ) async {
    final directory = await _directory();
    final manifest = await _readManifest(directory);
    if (manifest == null) return;
    final reads = Map<String, Object?>.from(manifest['reads'] as Map);
    final entry = reads[PublicContentCacheKeys.givingMethods];
    if (entry is! Map) return;
    final projection = entry['projection'];
    final imageFiles = entry['image_files'];
    if (!_hasKeys(projection, const {'sample', 'methods', 'truncated'}) ||
        projection['methods'] is! List ||
        imageFiles is! Map) {
      return;
    }

    final methods = List<Object?>.from(projection['methods'] as List);
    final index = methods.indexWhere(
      (raw) => raw is Map && raw['method_id'] == method.methodId,
    );
    if (index < 0) return;

    final cached = methods[index];
    final cachedRow = cached is Map ? cached : null;
    final cachedLogo = cachedRow?['logo'];
    final logo = method.logo;
    final files = Map<String, Object?>.from(imageFiles);
    final expectedFileName = logo != null && logo.offlineAllowed
        ? _givingLogoFileName(method, logo)
        : null;
    final sameCachedLogo =
        cachedRow?['publication_revision'] == method.publicationRevision &&
        cachedLogo is Map &&
        cachedLogo['offline_allowed'] == true &&
        logo != null &&
        logo.offlineAllowed &&
        cachedLogo['path'] == logo.path &&
        cachedLogo['media_type'] == logo.mediaType &&
        cachedLogo['width'] == logo.width &&
        cachedLogo['height'] == logo.height &&
        cachedLogo['rights_revision'] == logo.rightsRevision;
    final fileName = expectedFileName;
    final file = fileName == null
        ? null
        : File('${directory.path}${Platform.pathSeparator}$fileName');
    final canReuseCachedFile =
        sameCachedLogo && files[method.methodId] == fileName;
    Uint8List? bytes;
    if (canReuseCachedFile && file != null && await file.exists()) {
      final existing = await file.readAsBytes();
      if (existing.isNotEmpty &&
          existing.length <= _maxGivingLogoBytes &&
          _givingLogoMediaTypeMatchesExtension(logo, fileName!)) {
        bytes = existing;
      }
    }
    if (logo?.offlineAllowed == true && bytes == null) {
      bytes = logo!.offlineBytes;
      if (bytes == null) {
        try {
          bytes = await loadGivingLogo(logo);
        } catch (_) {
          bytes = null;
        }
      }
      if (bytes == null ||
          bytes.isEmpty ||
          bytes.length > _maxGivingLogoBytes ||
          !_givingLogoMediaTypeMatchesExtension(logo, fileName!)) {
        bytes = null;
      }
      if (bytes != null && file != null) {
        // A new publication or rights revision must never inherit a file
        // that was saved for different logo metadata under the same name.
        if (await file.exists()) await file.delete();
        await _writeImage(file, bytes);
      }
    }

    final keepLogo = logo?.offlineAllowed == true && bytes != null;
    final updated = keepLogo
        ? method.withLogo(logo!.withOfflineBytes(bytes))
        : method.withLogo(null);
    methods[index] = updated.toCacheJson();
    if (keepLogo) {
      files[method.methodId] = fileName!;
    } else {
      files.remove(method.methodId);
    }
    reads[PublicContentCacheKeys.givingMethods] = {
      'saved_at': entry['saved_at'],
      'projection': {
        'sample': projection['sample'],
        'methods': methods,
        'truncated': projection['truncated'],
      },
      'image_files': files,
    };
    await _commitManifest(
      directory,
      jsonEncode({'version': _manifestVersion, 'reads': reads}),
    );
    await _removeUnusedGivingLogos(
      directory,
      files.values.whereType<String>().toSet(),
    );
  }

  Future<void> _removeGivingMethod(String methodId) async {
    final directory = await _directory();
    final manifest = await _readManifest(directory);
    if (manifest == null) return;
    final reads = Map<String, Object?>.from(manifest['reads'] as Map);
    final entry = reads[PublicContentCacheKeys.givingMethods];
    if (entry is! Map) return;
    final projection = entry['projection'];
    final imageFiles = entry['image_files'];
    if (!_hasKeys(projection, const {'sample', 'methods', 'truncated'}) ||
        projection['methods'] is! List ||
        imageFiles is! Map) {
      return;
    }
    final methods = (projection['methods'] as List)
        .where((raw) => raw is Map && raw['method_id'] != methodId)
        .toList(growable: false);
    final files = Map<String, Object?>.from(imageFiles)..remove(methodId);
    reads[PublicContentCacheKeys.givingMethods] = {
      'saved_at': entry['saved_at'],
      'projection': {
        'sample': projection['sample'],
        'methods': methods,
        'truncated': projection['truncated'],
      },
      'image_files': files,
    };
    await _commitManifest(
      directory,
      jsonEncode({'version': _manifestVersion, 'reads': reads}),
    );
    await _removeUnusedGivingLogos(
      directory,
      files.values.whereType<String>().toSet(),
    );
  }

  Future<void> _writeImage(File target, Uint8List bytes) async {
    final temp = File('${target.path}.tmp-${_clock().microsecondsSinceEpoch}');
    await temp.writeAsBytes(bytes, flush: true);
    if (!await target.exists()) await temp.rename(target.path);
    if (await temp.exists()) await temp.delete();
  }

  Future<void> _commitManifest(Directory directory, String json) async {
    final file = await _manifest(directory);
    final suffix = _clock().microsecondsSinceEpoch;
    final temp = File('${file.path}.tmp-$suffix');
    final backup = File('${file.path}.backup-$suffix');
    await temp.writeAsString(json, flush: true);
    final hadPrevious = await file.exists();
    try {
      if (hadPrevious) {
        await file.copy(backup.path);
        await file.delete();
      }
      await temp.rename(file.path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      // Restore the previous manifest if the replacement fails after removal.
      if (await backup.exists()) {
        try {
          if (await file.exists()) await file.delete();
          await backup.rename(file.path);
        } catch (_) {
          // The original failure remains the useful error for the caller.
        }
      }
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {
        // A leftover temporary manifest is ignored by the cache reader.
      }
      rethrow;
    }
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
    if (readKey == PublicContentCacheKeys.givingMethods) {
      await _removeUnusedGivingLogos(directory, const {});
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

  Future<void> _removeUnusedGivingLogos(
    Directory directory,
    Set<String> active,
  ) async {
    await for (final entity in directory.list()) {
      if (entity is File &&
          entity.uri.pathSegments.last.startsWith('giving-logo-offline-') &&
          !active.contains(entity.uri.pathSegments.last)) {
        try {
          await entity.delete();
        } catch (_) {
          // The manifest no longer references this logo.
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

  static const _givingMethodKeys = {
    'method_id',
    'method_type',
    'name',
    'purpose',
    'currency',
    'details',
    'ussd_code',
    'steps',
    'note',
    'contact',
    'verified_on',
    'publication_revision',
    'published_at',
    'unsafe',
    'logo',
  };

  static const _bibleChapterKeys = {
    'translation_id',
    'translation_code',
    'translation_name',
    'book_id',
    'chapter',
    'verse_count',
    'omitted_verses',
    'verses',
    'publication_revision',
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

  static String _givingLogoFileName(
    PublicGivingMethod method,
    PublicGivingLogo logo,
  ) {
    final id = method.methodId;
    if (!RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(id)) {
      throw const FormatException('invalid giving method id');
    }
    final extension = switch (logo.mediaType) {
      'image/png' => 'png',
      'image/jpeg' => 'jpg',
      'image/webp' => 'webp',
      _ => throw const FormatException('invalid giving logo media type'),
    };
    return 'giving-logo-offline-$id-p${method.publicationRevision}'
        '-r${logo.rightsRevision}.$extension';
  }

  static bool _givingLogoMediaTypeMatchesExtension(
    PublicGivingLogo logo,
    String name,
  ) => name.endsWith(switch (logo.mediaType) {
    'image/png' => '.png',
    'image/jpeg' => '.jpg',
    'image/webp' => '.webp',
    _ => '.invalid',
  });

  static bool _mediaTypeMatchesExtension(PublicBanner banner, String name) =>
      name.endsWith(switch (banner.image.mediaType) {
        'image/png' => '.png',
        'image/jpeg' => '.jpg',
        'image/webp' => '.webp',
        _ => '.invalid',
      });
}
