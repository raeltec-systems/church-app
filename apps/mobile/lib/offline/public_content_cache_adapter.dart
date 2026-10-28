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

  // Review F3: every withdrawal removal advances the generation when it is
  // requested (before it is queued) and leaves a tombstone. A list save
  // whose fetch began at an earlier generation leaves those rows out, so an
  // old in-flight read queued after the removal cannot bring them back.
  // Tombstones live for the process: after a restart no older read exists.
  int _readGeneration = 0;
  final _tombstones = <({String readKey, String id, int generation})>[];

  @override
  int get readGeneration => _readGeneration;

  void _tombstone(String readKey, String id) {
    _readGeneration++;
    _tombstones.add((readKey: readKey, id: id, generation: _readGeneration));
  }

  /// Ids of [readKey] removed after a fetch that began at [readGeneration].
  /// A save that carries no generation is not filtered (every list
  /// controller passes one).
  Set<String> _removedSince(String readKey, int? readGeneration) => {
    if (readGeneration != null)
      for (final t in _tombstones)
        if (t.readKey == readKey && t.generation > readGeneration) t.id,
  };

  Future<Directory> _directory() async {
    final support = await _supportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}bic-kafue'
      '${Platform.pathSeparator}public-content-v1',
    );
    await directory.create(recursive: true);
    await (_recovered ??= _recoverManifest(directory));
    return directory;
  }

  Future<void>? _recovered;

  /// Startup recovery for a manifest replacement interrupted by a process
  /// stop (see [_commitManifest]). With no live manifest, the newest fully
  /// written replacement is promoted, else the newest backup is restored;
  /// a leftover that does not parse is never promoted. Leftovers are then
  /// removed. Runs once per adapter, before any read or write.
  Future<void> _recoverManifest(Directory directory) async {
    try {
      final live = await _manifest(directory);
      final name = live.uri.pathSegments.last;
      final temps = <File>[];
      final backups = <File>[];
      await for (final entity in directory.list()) {
        if (entity is! File) continue;
        final n = entity.uri.pathSegments.last;
        if (n.startsWith('$name.tmp-')) temps.add(entity);
        if (n.startsWith('$name.backup-')) backups.add(entity);
      }
      int stamp(File f) =>
          int.tryParse(f.uri.pathSegments.last.split('-').last) ?? 0;
      temps.sort((a, b) => stamp(b).compareTo(stamp(a)));
      backups.sort((a, b) => stamp(b).compareTo(stamp(a)));
      if (!await live.exists()) {
        for (final candidate in [...temps, ...backups]) {
          if (await _validManifestFile(candidate)) {
            await candidate.rename(live.path);
            break;
          }
        }
      }
      for (final leftover in [...temps, ...backups]) {
        try {
          if (await leftover.exists()) await leftover.delete();
        } catch (_) {
          // A leftover is never read as the manifest.
        }
      }
    } catch (_) {
      // Recovery is best effort; an unreadable cache reads as empty.
    }
  }

  Future<bool> _validManifestFile(File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      return _hasKeys(decoded, const {'version', 'reads'}) &&
          decoded['version'] == _manifestVersion &&
          decoded['reads'] is Map &&
          (decoded['reads'] as Map).keys.every(_allowedReads.contains);
    } catch (_) {
      return false;
    }
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
                s.facebookVideoUrl != null ||
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
    int? readGeneration,
  }) {
    final completer = Completer<PublicContentCacheWrite>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        if (readKey == PublicContentCacheKeys.givingMethods) _givingWrites++;
        completer.complete(
          await _writeRead(
            readKey,
            _withoutRemoved(readKey, projection, readGeneration),
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

  /// Runs inside the queue, so it sees every removal requested before this
  /// save ran, including those requested after the save was queued.
  Object _withoutRemoved(
    String readKey,
    Object projection,
    int? readGeneration,
  ) {
    final removed = _removedSince(readKey, readGeneration);
    if (removed.isEmpty) return projection;
    if (readKey == PublicContentCacheKeys.sermons &&
        projection is PublicSermons) {
      return removed.fold<PublicSermons>(
        projection,
        (p, id) => p.withoutSermon(id),
      );
    }
    if (readKey == PublicContentCacheKeys.calendar &&
        projection is PublicEvents) {
      return removed.fold<PublicEvents>(
        projection,
        (p, id) => p.withoutEvent(id),
      );
    }
    if (readKey == PublicContentCacheKeys.givingMethods &&
        projection is PublicGivingMethods) {
      return PublicGivingMethods(
        sample: projection.sample,
        methods: List.unmodifiable(
          projection.methods.where((m) => !removed.contains(m.methodId)),
        ),
        truncated: projection.truncated,
      );
    }
    return projection;
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
        // Withdrawn, superseded or revoked banners leave the saved read now,
        // before any download; unchanged permitted ones stay for reuse.
        await _pruneBannersBeforeRefresh(directory, projection);
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
          // Review C2: a rejected saved file (empty or oversized) is
          // replaced, never kept under its name, as for sermon posters.
          await _replaceRejectedImage(current, bytes, _maxImageBytes);
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
          // A damaged saved poster is replaced, never kept under its name.
          if (await current.exists() &&
              (await current.length() == 0 ||
                  await current.length() > _maxImageBytes)) {
            await current.delete();
          }
          if (!await current.exists()) await _writeImage(current, bytes);
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
            await _replaceRejectedImage(current, bytes, _maxGivingLogoBytes);
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
      // One policy for every read type: an unreadable manifest already reads
      // as no saved content, so a successful write replaces it with just
      // this read, and every image no longer referenced is removed.
      final corrupt =
          manifest == null && await (await _manifest(directory)).exists();
      final reads = Map<String, Object?>.from(
        (manifest?['reads'] as Map?) ?? const {},
      )..[readKey] = entry;
      final next = jsonEncode({'version': _manifestVersion, 'reads': reads});
      await _commitManifest(directory, next);
      if (corrupt) {
        try {
          await _removeUnreferencedImages(directory, imageFiles);
        } catch (_) {
          // Unreferenced files are never read.
        }
      }
      if (readKey == PublicContentCacheKeys.sermons) {
        try {
          await _removeUnusedSermonPosters(directory, imageFiles);
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
    _tombstone(PublicContentCacheKeys.givingMethods, methodId);
    final completer = Completer<void>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        _givingWrites++;
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
  Future<void> removeSermon(String sermonId) {
    _tombstone(PublicContentCacheKeys.sermons, sermonId);
    final completer = Completer<void>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        await _removeSermon(sermonId);
      } catch (_) {
        // The detail read already says the sermon is gone; a failed cleanup
        // leaves the previous manifest, never a partial one.
      } finally {
        completer.complete();
      }
    });
    return completer.future;
  }

  @override
  Future<void> removeEvent(String eventId) {
    _tombstone(PublicContentCacheKeys.calendar, eventId);
    final completer = Completer<void>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        await _removeEvent(eventId);
      } catch (_) {
        // The detail read already says the event is gone; a failed cleanup
        // leaves the previous manifest, never a partial one.
      } finally {
        completer.complete();
      }
    });
    return completer.future;
  }

  Future<void> _removeEvent(String eventId) async {
    final directory = await _directory();
    final manifest = await _readManifest(directory);
    if (manifest == null) return;
    final reads = Map<String, Object?>.from(manifest['reads'] as Map);
    final entry = reads[PublicContentCacheKeys.calendar];
    if (entry is! Map) return;
    final projection = entry['projection'];
    if (projection is! Map || projection['events'] is! List) return;
    final events = projection['events'] as List;
    final kept = events
        .where((raw) => raw is Map && raw['event_id'] != eventId)
        .toList(growable: false);
    if (kept.length == events.length) return;
    reads[PublicContentCacheKeys.calendar] = {
      'saved_at': entry['saved_at'],
      'projection': {'events': kept, 'truncated': projection['truncated']},
    };
    await _commitManifest(
      directory,
      jsonEncode({'version': _manifestVersion, 'reads': reads}),
    );
  }

  Future<void> _removeSermon(String sermonId) async {
    final directory = await _directory();
    final manifest = await _readManifest(directory);
    if (manifest == null) return;
    final reads = Map<String, Object?>.from(manifest['reads'] as Map);
    final entry = reads[PublicContentCacheKeys.sermons];
    if (entry is! Map || entry['image_files'] is! Map) return;
    final source = PublicSermons.fromJson(entry['projection']);
    if (source.byId(sermonId) == null) return;
    final remaining = source.withoutSermon(sermonId);
    // A series only the removed sermon carried leaves the saved rows, so its
    // poster file entry goes too (the reader refuses unknown file keys).
    final seriesIds = {
      for (final s in remaining.series) s.seriesId,
      for (final s in remaining.sermons)
        if (s.series != null) s.series!.seriesId,
    };
    final files = <String, Object?>{
      for (final file in (entry['image_files'] as Map).entries)
        if (seriesIds.contains(file.key)) file.key as String: file.value,
    };
    reads[PublicContentCacheKeys.sermons] = {
      'saved_at': entry['saved_at'],
      'projection': remaining.toCacheJson(),
      'image_files': files,
    };
    await _commitManifest(
      directory,
      jsonEncode({'version': _manifestVersion, 'reads': reads}),
    );
    await _removeUnusedSermonPosters(
      directory,
      files.values.whereType<String>().toSet(),
    );
  }

  Future<void> _removeUnusedSermonPosters(
    Directory directory,
    Set<String> active,
  ) async {
    await for (final entity in directory.list()) {
      if (entity is File &&
          entity.uri.pathSegments.last.startsWith('sermon-poster-offline-') &&
          !active.contains(entity.uri.pathSegments.last)) {
        try {
          await entity.delete();
        } catch (_) {
          // The manifest no longer references this poster.
        }
      }
    }
  }

  @override
  Future<void> reconcileGivingMethod(PublicGivingMethod method) {
    final completer = Completer<void>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        _givingWrites++;
        await _reconcileGivingMethod(method);
      } catch (_) {
        // Cache maintenance cannot replace a successful fresh detail read.
      } finally {
        completer.complete();
      }
    });
    return completer.future;
  }

  // Review C1: counts every queued change to the saved giving read. A logo
  // downloaded in the background is attached only if nothing changed the
  // giving read since its detail was reconciled, so it can never undo a
  // later revocation, removal or list save.
  int _givingWrites = 0;

  static bool _sameGivingLogo(Object? cachedLogo, PublicGivingLogo logo) =>
      cachedLogo is Map &&
      cachedLogo['offline_allowed'] == true &&
      logo.offlineAllowed &&
      cachedLogo['path'] == logo.path &&
      cachedLogo['media_type'] == logo.mediaType &&
      cachedLogo['width'] == logo.width &&
      cachedLogo['height'] == logo.height &&
      cachedLogo['rights_revision'] == logo.rightsRevision;

  /// The safety half of a fresh detail: the row takes the fresh text, keeps
  /// its logo only when it is the same revision with a valid saved file, and
  /// otherwise loses it now. Nothing is downloaded here.
  Future<void> _reconcileGivingMethod(PublicGivingMethod method) async {
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
    final logo = method.logo;
    final files = Map<String, Object?>.from(imageFiles);
    final fileName = logo != null && logo.offlineAllowed
        ? _givingLogoFileName(method, logo)
        : null;
    final sameCachedLogo =
        logo != null &&
        cachedRow?['publication_revision'] == method.publicationRevision &&
        _sameGivingLogo(cachedRow?['logo'], logo);
    Uint8List? bytes;
    if (sameCachedLogo &&
        fileName != null &&
        files[method.methodId] == fileName) {
      final file = File('${directory.path}${Platform.pathSeparator}$fileName');
      if (await file.exists()) {
        final existing = await file.readAsBytes();
        if (existing.isNotEmpty &&
            existing.length <= _maxGivingLogoBytes &&
            _givingLogoMediaTypeMatchesExtension(logo, fileName)) {
          bytes = existing;
        }
      }
    }

    final updated = bytes != null
        ? method.withLogo(logo!.withOfflineBytes(bytes))
        : method.withLogo(null);
    methods[index] = updated.toCacheJson();
    if (bytes != null) {
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

  @override
  Future<void> saveGivingLogo(
    PublicGivingMethod method, {
    required Future<Uint8List?> Function(PublicGivingLogo logo) loadGivingLogo,
  }) async {
    try {
      final logo = method.logo;
      if (logo == null || !logo.offlineAllowed) return;
      final fileName = _givingLogoFileName(method, logo);
      // Taken now, after the reconcile this follows: any later change to
      // the giving read cancels the attach.
      final writes = _givingWrites;
      final saved = (await readGivingMethods())?.value.methods
          .where((m) => m.methodId == method.methodId)
          .firstOrNull;
      if (saved == null ||
          saved.publicationRevision != method.publicationRevision ||
          saved.logo?.offlineBytes != null) {
        return;
      }
      // Downloaded outside the write queue, so other saves never wait.
      Uint8List? bytes = logo.offlineBytes;
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
          !_givingLogoMediaTypeMatchesExtension(logo, fileName)) {
        return;
      }
      final attach = bytes;
      final completer = Completer<void>();
      _writeQueue = _writeQueue.then((_) async {
        try {
          if (writes != _givingWrites) return;
          _givingWrites++;
          await _attachGivingLogo(method, logo, fileName, attach);
        } catch (_) {
          // The row stays without an offline logo.
        } finally {
          completer.complete();
        }
      });
      await completer.future;
    } catch (_) {
      // An optional logo never fails the fresh detail.
    }
  }

  Future<void> _attachGivingLogo(
    PublicGivingMethod method,
    PublicGivingLogo logo,
    String fileName,
    Uint8List bytes,
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
    final row = Map<String, Object?>.from(methods[index] as Map);
    if (row['publication_revision'] != method.publicationRevision ||
        row['logo'] != null) {
      return;
    }
    final file = File('${directory.path}${Platform.pathSeparator}$fileName');
    // A file saved under this name for other logo metadata is never kept.
    if (await file.exists()) await file.delete();
    await _writeImage(file, bytes);
    row['logo'] = method.withLogo(logo).toCacheJson()['logo'];
    methods[index] = row;
    final files = Map<String, Object?>.from(imageFiles)
      ..[method.methodId] = fileName;
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

  /// Writes [bytes] to [target] unless it already holds an accepted file
  /// (non-empty and at most [maxBytes]); a rejected file is deleted first.
  Future<void> _replaceRejectedImage(
    File target,
    Uint8List bytes,
    int maxBytes,
  ) async {
    if (await target.exists()) {
      final length = await target.length();
      if (length > 0 && length <= maxBytes) return;
      await target.delete();
    }
    await _writeImage(target, bytes);
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
    if (!Platform.isWindows) {
      // rename(2) replaces the target atomically on Android and iOS.
      try {
        await temp.rename(file.path);
        return;
      } catch (_) {
        if (await temp.exists()) await temp.delete();
        rethrow;
      }
    }
    // Windows cannot rename over an existing file: copy a backup, delete,
    // rename. A stop between the delete and the rename is repaired at the
    // next start by [_recoverManifest].
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
      await _removeUnreferencedImages(directory, const {});
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

  /// Keeps only saved banners the fresh projection still lists at the same
  /// publication and rights revision (the file name encodes both), commits
  /// that subset, and deletes every other banner file except the ones the
  /// fresh projection names. The final commit then removes whatever the new
  /// projection excludes.
  Future<void> _pruneBannersBeforeRefresh(
    Directory directory,
    PublicBanners fresh,
  ) async {
    final wanted = {
      for (final banner in fresh.banners)
        banner.bannerId: _imageFileName(banner),
    };
    final file = await _manifest(directory);
    if (!await file.exists()) {
      await _removeUnusedBannerImages(directory, wanted.values.toSet());
      return;
    }
    final manifest = await _readManifest(directory);
    if (manifest == null) {
      await _removeReadBeforeRefresh(
        directory,
        PublicContentCacheKeys.homeBanners,
      );
      return;
    }
    final reads = Map<String, Object?>.from(manifest['reads'] as Map);
    final entry = reads[PublicContentCacheKeys.homeBanners];
    final projection = entry is Map ? entry['projection'] : null;
    final imageFiles = entry is Map ? entry['image_files'] : null;
    if (entry is! Map ||
        projection is! Map ||
        projection['banners'] is! List ||
        imageFiles is! Map) {
      if (entry != null) {
        await _removeReadBeforeRefresh(
          directory,
          PublicContentCacheKeys.homeBanners,
        );
      } else {
        await _removeUnusedBannerImages(directory, wanted.values.toSet());
      }
      return;
    }
    final keptFiles = <String, String>{
      for (final saved in imageFiles.entries)
        if (saved.key is String &&
            saved.value is String &&
            wanted[saved.key] == saved.value)
          saved.key as String: saved.value as String,
    };
    final banners = projection['banners'] as List;
    final keptBanners = banners
        .where((raw) => raw is Map && keptFiles.containsKey(raw['banner_id']))
        .toList(growable: false);
    if (keptBanners.length != banners.length ||
        keptFiles.length != imageFiles.length) {
      reads[PublicContentCacheKeys.homeBanners] = {
        'saved_at': entry['saved_at'],
        'projection': {
          'banners': keptBanners,
          'truncated': projection['truncated'],
        },
        'image_files': keptFiles,
      };
      await _commitManifest(
        directory,
        jsonEncode({'version': _manifestVersion, 'reads': reads}),
      );
    }
    await _removeUnusedBannerImages(directory, wanted.values.toSet());
  }

  /// Every saved image kind, for a manifest that no longer references any
  /// image outside [keep].
  Future<void> _removeUnreferencedImages(
    Directory directory,
    Set<String> keep,
  ) async {
    await _removeUnusedBannerImages(directory, keep);
    await _removeUnusedGivingLogos(directory, keep);
    await _removeUnusedSermonPosters(directory, keep);
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
