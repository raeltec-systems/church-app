import 'dart:async';
import 'dart:typed_data';

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/content_banners.dart';
import '../domain/content_sermons.dart';
import '../domain/public_content_cache.dart';
import 'banner_controllers.dart';
import 'content_controllers.dart';
import 'providers.dart';

/// Always reads and saves the canonical catalog. Screen filters are local.
///
/// Saving has two steps so a slow poster never holds back the list or the
/// shared cache queue: the teaching is saved at once with the posters already
/// on the phone, then missing offline-cleared posters are fetched outside the
/// queue, a few at a time, and saved with the same catalog unless a newer
/// catalog was saved meanwhile.
///
/// Only the current series keeps its poster on the phone (owner decision
/// 2026-10-27, to save members' data); other series show posters online only.
class PublicSermonsController extends PublicReadController<PublicSermons> {
  static const _posterFetches = 3;
  int _saves = 0;

  @override
  Future<AccessRead<PublicSermons>> fetch() =>
      ref.read(sermonsRepositoryProvider).fetchPublicSermons();
  @override
  bool get supportsOfflineSnapshot => true;
  @override
  Future<PublicContentSnapshot<PublicSermons>?> readOfflineSnapshot() =>
      ref.read(publicContentCacheProvider).readSermons();
  @override
  Future<DateTime?> saveOfflineSnapshot(PublicSermons value) async {
    final save = ++_saves;
    final offline = PublicSermons(
      sermons: value.sermons.where((s) => s.offlineAllowed).toList(),
      series: value.series.where((s) => s.offlineAllowed).toList(),
      truncated: value.truncated,
    );
    // The saved list leads with this series, so its poster is the one kept.
    final current = offline.currentSeries?.seriesId;
    PublicSermonSeries capped(PublicSermonSeries s) =>
        s.seriesId == current ? s : s.withPoster(null);
    final eligible = PublicSermons(
      sermons: [
        for (final s in offline.sermons)
          s.series == null ? s : s.withSeries(capped(s.series!)),
      ],
      series: offline.series.map(capped).toList(),
      truncated: offline.truncated,
    );
    final outcome = await ref
        .read(publicContentCacheProvider)
        .writeRead(
          PublicContentCacheKeys.sermons,
          eligible,
          loadSermonPoster: (_) async => null,
        );
    if (outcome is! PublicContentCacheSaved) return null;
    unawaited(_savePosters(save, eligible));
    return outcome.savedAt;
  }

  static String _posterKey(SermonPoster p) =>
      '${p.image.path}#${p.rightsRevision}';

  Future<void> _savePosters(int save, PublicSermons eligible) async {
    try {
      final cache = ref.read(publicContentCacheProvider);
      final saved = await cache.readSermons();
      if (!ref.mounted || save != _saves || saved == null) return;
      final present = {
        for (final s in [
          ...saved.value.series,
          for (final sermon in saved.value.sermons) ?sermon.series,
        ])
          if (s.poster case final p? when p.offlineBytes != null) _posterKey(p),
      };
      final wanted = <String, SermonPoster>{
        for (final s in [
          ...eligible.series,
          for (final sermon in eligible.sermons) ?sermon.series,
        ])
          if (s.poster case final p?
              when p.offlineAllowed && !present.contains(_posterKey(p)))
            _posterKey(p): p,
      };
      if (wanted.isEmpty) return;
      final assets = ref.read(bannerRepositoryProvider);
      final pending = wanted.entries.toList();
      final fetched = <String, Uint8List>{};
      var next = 0;
      Future<void> worker() async {
        while (next < pending.length) {
          final entry = pending[next++];
          try {
            final bytes = await assets.fetchPublicAsset(
              entry.value.image.path,
              entry.value.image.mediaType,
              maxBytes: 5 * 1024 * 1024,
            );
            if (bytes != null && bytes.isNotEmpty) fetched[entry.key] = bytes;
          } catch (_) {
            // A poster that cannot be fetched stays online only.
          }
        }
      }

      await Future.wait([
        for (var i = 0; i < _posterFetches && i < pending.length; i++) worker(),
      ]);
      // A newer catalog may have been saved while the posters downloaded.
      if (!ref.mounted || save != _saves || fetched.isEmpty) return;
      await cache.writeRead(
        PublicContentCacheKeys.sermons,
        eligible,
        loadSermonPoster: (p) async => fetched[_posterKey(p)],
      );
    } catch (_) {
      // Poster maintenance never replaces a successful server read.
    }
  }
}

final publicSermonsProvider =
    NotifierProvider<PublicSermonsController, PublicReadState<PublicSermons>>(
      PublicSermonsController.new,
    );

class PublicSermonController extends PublicReadController<PublicSermonRead> {
  PublicSermonController(this.sermonId);
  final String sermonId;
  @override
  Future<AccessRead<PublicSermonRead>> fetch() =>
      ref.read(sermonsRepositoryProvider).fetchPublicSermon(sermonId);
  @override
  bool get supportsOfflineSnapshot => true;
  @override
  Future<PublicContentSnapshot<PublicSermonRead>?> readOfflineSnapshot() async {
    final catalog = await ref.read(publicContentCacheProvider).readSermons();
    final sermon = catalog?.value.byId(sermonId);
    return sermon == null
        ? null
        : PublicContentSnapshot(
            value: PublicSermonRead(sermon),
            savedAt: catalog!.savedAt,
          );
  }

  @override
  Future<void> onFreshRead(PublicSermonRead value) async {
    // When the detail no longer matches the listed copy (withdrawn, revised,
    // or its video or series changed), refresh the canonical list so the
    // saved catalog follows. Never awaited: the teaching shows at once.
    final listed = ref.read(publicSermonsProvider).value?.byId(sermonId);
    final fresh = value.sermon;
    final changed = fresh == null
        ? listed != null
        : listed == null || !_sameListing(listed, fresh);
    if (changed) unawaited(ref.read(publicSermonsProvider.notifier).reload());
  }

  static bool _sameListing(PublicSermon a, PublicSermon b) =>
      a.publicationRevision == b.publicationRevision &&
      a.youtubeVideoId == b.youtubeVideoId &&
      a.rightsRevision == b.rightsRevision &&
      a.series?.seriesId == b.series?.seriesId &&
      a.series?.publicationRevision == b.series?.publicationRevision &&
      a.series?.poster?.rightsRevision == b.series?.poster?.rightsRevision;
}

final publicSermonProvider = NotifierProvider.autoDispose
    .family<PublicSermonController, PublicReadState<PublicSermonRead>, String>(
      PublicSermonController.new,
    );

class StaffSermonsController extends StaffCatalogController<StaffSermons> {
  @override
  Future<AccessRead<StaffSermons>> fetch() =>
      ref.read(sermonsRepositoryProvider).fetchStaffSermons();
  @override
  String get idKey => 'sermon_id';
  @override
  String get publishCommand => SermonCommands.publish;
  @override
  Set<String> get syncAfter => const {};
  @override
  BannerNotice success(String command) => _success(command);
  Future<void> create(SermonInput input) => send(
    SermonCommands.create,
    const Optional.of(null),
    input.toPayload(),
    input.title,
  );
  Future<void> save(StaffSermon item, SermonInput input) => send(
    SermonCommands.save,
    Optional.of(item.revision),
    input.toPayload(sermonId: item.id),
    input.title,
  );
  Future<void> lifecycle(String command, StaffSermon item) => send(
    command,
    Optional.of(item.revision),
    {'sermon_id': item.id},
    item.current.fields.title,
  );
}

final staffSermonsProvider =
    NotifierProvider<StaffSermonsController, StaffCatalogState<StaffSermons>>(
      StaffSermonsController.new,
    );

class StaffSermonSeriesController
    extends StaffCatalogController<StaffSermonSeriesCatalog> {
  @override
  Future<AccessRead<StaffSermonSeriesCatalog>> fetch() =>
      ref.read(sermonsRepositoryProvider).fetchStaffSeries();
  @override
  String get idKey => 'series_id';
  @override
  String get publishCommand => SermonCommands.publishSeries;
  @override
  Set<String> get syncAfter => const {
    SermonCommands.publishSeries,
    SermonCommands.withdrawSeries,
    SermonCommands.archiveSeries,
  };
  @override
  BannerNotice success(String command) => _success(command);
  Future<void> create(SermonSeriesInput input) => send(
    SermonCommands.createSeries,
    const Optional.of(null),
    input.toPayload(),
    input.title,
  );
  Future<void> save(StaffSermonSeries item, SermonSeriesInput input) => send(
    SermonCommands.saveSeries,
    Optional.of(item.revision),
    input.toPayload(seriesId: item.id),
    input.title,
  );
  Future<void> lifecycle(String command, StaffSermonSeries item) => send(
    command,
    Optional.of(item.revision),
    {'series_id': item.id},
    item.current.fields.title,
  );
}

final staffSermonSeriesProvider =
    NotifierProvider<
      StaffSermonSeriesController,
      StaffCatalogState<StaffSermonSeriesCatalog>
    >(StaffSermonSeriesController.new);

BannerNotice _success(String command) => switch (command) {
  SermonCommands.create || SermonCommands.createSeries => BannerNotice.created,
  SermonCommands.save || SermonCommands.saveSeries => BannerNotice.saved,
  SermonCommands.publish ||
  SermonCommands.publishSeries => BannerNotice.published,
  SermonCommands.withdraw ||
  SermonCommands.withdrawSeries => BannerNotice.withdrawn,
  _ => BannerNotice.archived,
};

class SermonPosterUploadController extends Notifier<BannerImageUpload> {
  SermonPosterUploadController(this.seriesId);
  final String seriesId;
  int _epoch = 0;
  @override
  BannerImageUpload build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    return const BannerImageUpload();
  }

  Future<void> pickAndUpload() async {
    if (state.busy) return;
    final epoch = _epoch;
    state = const BannerImageUpload(status: ImageUploadStatus.picking);
    final file = await ref.read(contentFilePickerProvider).pickImage();
    if (!ref.mounted || epoch != _epoch) return;
    if (file == null) {
      state = const BannerImageUpload();
      return;
    }
    if (file.unreadable) {
      state = const BannerImageUpload(
        status: ImageUploadStatus.refused,
        outcome: ImageUploadRefused(fieldErrors: {'file': 'too_large'}),
      );
      return;
    }
    state = BannerImageUpload(
      status: ImageUploadStatus.uploading,
      bytes: file.bytes,
    );
    final outcome = await ref
        .read(bannerRepositoryProvider)
        .uploadImage(seriesId, SermonCommands.posterPurpose, file);
    if (!ref.mounted || epoch != _epoch) return;
    state = switch (outcome) {
      ImageUploaded(:final image) => BannerImageUpload(
        status: ImageUploadStatus.uploaded,
        image: image,
        bytes: file.bytes,
        outcome: outcome,
      ),
      ImageUploadRefused() => BannerImageUpload(
        status: ImageUploadStatus.refused,
        outcome: outcome,
      ),
      _ => BannerImageUpload(
        status: ImageUploadStatus.failed,
        outcome: outcome,
      ),
    };
  }

  void clear() => state = const BannerImageUpload();
}

final sermonPosterUploadProvider = NotifierProvider.autoDispose
    .family<SermonPosterUploadController, BannerImageUpload, String>(
      SermonPosterUploadController.new,
    );
