import 'dart:async';

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
class PublicSermonsController extends PublicReadController<PublicSermons> {
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
    final eligible = PublicSermons(
      sermons: value.sermons.where((s) => s.offlineAllowed).toList(),
      series: value.series.where((s) => s.offlineAllowed).toList(),
      truncated: value.truncated,
    );
    final outcome = await ref
        .read(publicContentCacheProvider)
        .writeRead(
          PublicContentCacheKeys.sermons,
          eligible,
          loadSermonPoster: (poster) => ref
              .read(bannerRepositoryProvider)
              .fetchPublicAsset(
                poster.image.path,
                poster.image.mediaType,
                maxBytes: 5 * 1024 * 1024,
              ),
        );
    return outcome is PublicContentCacheSaved ? outcome.savedAt : null;
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
    // A fresh detail also refreshes the canonical list (including withdrawals).
    // Poster downloads must never delay the readable teaching detail.
    unawaited(ref.read(publicSermonsProvider.notifier).reload());
  }
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
