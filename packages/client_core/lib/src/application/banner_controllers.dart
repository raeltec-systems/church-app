import 'dart:convert';
import 'dart:typed_data';

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/commands.dart';
import '../domain/content_banners.dart';
import '../domain/content_events.dart' show ContentCommands;
import '../domain/public_content_cache.dart';
import 'access_controllers.dart' show noteProtectedDenial;
import 'content_controllers.dart'
    show ContentAction, PublicReadController, PublicReadState;
import 'providers.dart';

// Story 6.2: Home banners (everyone, signed in or not) and, on staff web, the
// editors' Banners and Rights screens with image upload. The public read holds
// only the published projection, in memory; the editors' reads, their
// commands, uploads and previews are protected state scoped to the account
// generation (AD-13). The server checks every read, command and upload.

/// `api.content_public_banners`: the theme first, then campaigns.
class PublicBannersController extends PublicReadController<PublicBanners> {
  @override
  Future<AccessRead<PublicBanners>> fetch() =>
      ref.read(bannerRepositoryProvider).fetchPublicBanners();

  @override
  bool get supportsOfflineSnapshot => true;

  @override
  Future<DateTime?> saveOfflineSnapshot(PublicBanners value) async {
    final eligible = PublicBanners(
      value.banners.where((banner) => banner.offlineAllowed).toList(),
      truncated: value.truncated,
    );
    final repository = ref.read(bannerRepositoryProvider);
    final outcome = await ref
        .read(publicContentCacheProvider)
        .writeRead(
          PublicContentCacheKeys.homeBanners,
          eligible,
          loadBannerImage: repository.fetchPublicImage,
        );
    return outcome is PublicContentCacheSaved ? outcome.savedAt : null;
  }

  @override
  Future<PublicContentSnapshot<PublicBanners>?> readOfflineSnapshot() =>
      ref.read(publicContentCacheProvider).readBanners();
}

final publicBannersProvider =
    NotifierProvider<PublicBannersController, PublicReadState<PublicBanners>>(
      PublicBannersController.new,
    );

/// What the Banners and Rights screens tell the editor after an action.
enum BannerNotice {
  created,
  saved,
  published,
  verified,
  withdrawn,
  archived,

  /// Changed in another tab or by someone else: reloaded.
  changedElsewhere,

  /// Nothing to publish or verify (no saved changes).
  nothingToPublish,

  /// Withdrawn already, or never published.
  notPublished,
  alreadyArchived,

  /// A field needs changing (a form's own refusal).
  invalid,

  /// Publishing was refused for the image, its rights or the linked event.
  blocked,
  notAllowed,
  signInAgain,
  notFound,
  notAvailable,
  refused,

  /// The outcome is unknown: check again with the same request.
  unconfirmed,
  notSent,
}

/// The editors' read of banners or rights records and its commands.
class StaffCatalogState<T> {
  const StaffCatalogState({
    this.loading = false,
    this.result,
    this.pending,
    this.unconfirmed,
    this.notice,
    this.noticeAction,
    this.fieldErrors = const {},
    this.syncing = false,
    this.sync,
  });

  final bool loading;
  final AccessRead<T>? result;
  final ContentAction? pending;
  final ContentAction? unconfirmed;
  final BannerNotice? notice;
  final ContentAction? noticeAction;
  final Map<String, String> fieldErrors;

  /// A public-file sync is under way.
  final bool syncing;

  /// The last sync's outcome (null before the first).
  final FileSyncOutcome? sync;

  bool get busy => pending != null;
  T? get value => switch (result) {
    AccessReadOk<T>(:final value) => value,
    _ => null,
  };

  StaffCatalogState<T> copyWith({
    bool? loading,
    AccessRead<T>? result,
    ContentAction? pending,
    bool clearPending = false,
    ContentAction? unconfirmed,
    bool clearUnconfirmed = false,
    BannerNotice? notice,
    ContentAction? noticeAction,
    bool clearNotice = false,
    Map<String, String>? fieldErrors,
    bool? syncing,
    FileSyncOutcome? sync,
  }) => StaffCatalogState<T>(
    loading: loading ?? this.loading,
    result: result ?? this.result,
    pending: clearPending ? null : (pending ?? this.pending),
    unconfirmed: clearUnconfirmed ? null : (unconfirmed ?? this.unconfirmed),
    notice: clearNotice ? null : (notice ?? this.notice),
    noticeAction: clearNotice ? null : (noticeAction ?? this.noticeAction),
    fieldErrors: fieldErrors ?? this.fieldErrors,
    syncing: syncing ?? this.syncing,
    sync: sync ?? this.sync,
  );
}

/// One editors' list (banners or rights records) and its lifecycle commands
/// (1.4 envelope) with honest request states. Something shows as published
/// or verified only after the server confirmed it. A lifecycle change that
/// changes what is public is followed by a public-file sync.
abstract class StaffCatalogController<T>
    extends Notifier<StaffCatalogState<T>> {
  int _epoch = 0;

  Future<AccessRead<T>> fetch();

  /// The payload key of the item's id (`banner_id`, `rights_id`).
  String get idKey;

  /// The notice a confirmed [command] shows.
  BannerNotice success(String command);

  /// Commands after which public files change (publish, withdraw, ...).
  Set<String> get syncAfter;

  /// The publish (or verify) command, whose field refusals are [blocked].
  String get publishCommand;

  @override
  StaffCatalogState<T> build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    final epoch = _epoch;
    Future.microtask(() => _reload(epoch));
    return StaffCatalogState<T>(loading: true);
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;

  Future<void> reload() => _reload(_epoch);

  Future<void> _reload(int epoch) async {
    if (!_current(epoch)) return;
    state = state.copyWith(loading: true);
    final r = await fetch();
    if (!_current(epoch)) return;
    // A denial or failure drops the list from the screen; a command still in
    // flight stays pending so it cannot be sent twice.
    state = StaffCatalogState<T>(
      result: r,
      pending: state.pending,
      unconfirmed: state.unconfirmed,
      notice: state.notice,
      noticeAction: state.noticeAction,
      fieldErrors: state.fieldErrors,
      syncing: state.syncing,
      sync: state.sync,
    );
    if (r is AccessReadDenied<T>) noteProtectedDenial(ref);
  }

  /// Asks the server to place published files and remove withdrawn ones,
  /// then reloads the list.
  Future<void> sync() => _sync(_epoch);

  Future<void> _sync(int epoch) async {
    if (!_current(epoch) || state.syncing) return;
    state = state.copyWith(syncing: true);
    final outcome = await ref.read(bannerRepositoryProvider).syncFiles();
    if (!_current(epoch)) return;
    state = state.copyWith(syncing: false, sync: outcome);
    await _reload(epoch);
  }

  void dismissNotice() =>
      state = state.copyWith(clearNotice: true, fieldErrors: const {});

  void clearFieldErrors() {
    if (state.fieldErrors.isNotEmpty) {
      state = state.copyWith(fieldErrors: const {});
    }
  }

  /// Resends the unconfirmed command unchanged (same request_id and body).
  Future<void> checkAgain() async {
    final u = state.unconfirmed;
    if (u == null || state.busy) return;
    await _dispatch(u);
  }

  Future<void> send(
    String command,
    Optional<int> expected,
    Map<String, Object?> payload,
    String subject,
  ) async {
    if (state.busy) return;
    final u = state.unconfirmed?.request;
    final same =
        u != null &&
        u.command == command &&
        u.expectedRevision.value == expected.value &&
        jsonEncode(u.payload) == jsonEncode(payload);
    await _dispatch(
      ContentAction(
        request: CommandRequest(
          command: command,
          requestId: same ? u.requestId : ref.read(requestIdsProvider).next(),
          expectedRevision: expected,
          payload: payload,
        ),
        subject: subject,
      ),
    );
  }

  BannerNotice _refusal(String command, CommandError error) {
    final f = error.fieldErrors;
    return switch (error.code) {
      ErrorCode.validationFailed when f[idKey] == 'nothing_to_publish' =>
        BannerNotice.nothingToPublish,
      ErrorCode.validationFailed when f[idKey] == 'not_published' =>
        BannerNotice.notPublished,
      ErrorCode.validationFailed when f[idKey] == 'archived' =>
        BannerNotice.alreadyArchived,
      ErrorCode.validationFailed when command == publishCommand =>
        BannerNotice.blocked,
      ErrorCode.validationFailed => BannerNotice.invalid,
      ErrorCode.conflict => BannerNotice.changedElsewhere,
      ErrorCode.forbidden => BannerNotice.notAllowed,
      ErrorCode.unauthenticated => BannerNotice.signInAgain,
      ErrorCode.notFound => BannerNotice.notFound,
      ErrorCode.unavailable => BannerNotice.notAvailable,
      _ => BannerNotice.refused,
    };
  }

  Future<void> _dispatch(ContentAction action) async {
    final epoch = _epoch;
    state = state.copyWith(
      pending: action,
      clearNotice: true,
      fieldErrors: const {},
    );
    final outcome = await ref
        .read(commandGatewayProvider)
        .send(ContentCommands.function, action.request);
    if (!_current(epoch)) return;
    switch (outcome) {
      case CommandConfirmed():
        state = state.copyWith(
          clearPending: true,
          clearUnconfirmed: true,
          notice: success(action.command),
          noticeAction: action,
        );
        if (syncAfter.contains(action.command)) {
          await _sync(epoch);
        } else {
          await _reload(epoch);
        }
      case CommandRefused(:final error):
        final notice = _refusal(action.command, error);
        state = state.copyWith(
          clearPending: true,
          clearUnconfirmed: true,
          notice: notice,
          noticeAction: action,
          fieldErrors: error.fieldErrors,
        );
        if (notice == BannerNotice.notAllowed ||
            notice == BannerNotice.signInAgain) {
          noteProtectedDenial(ref);
        }
        if (notice != BannerNotice.invalid) await _reload(epoch);
      case CommandUnknownOutcome():
        state = state.copyWith(
          clearPending: true,
          unconfirmed: action,
          notice: BannerNotice.unconfirmed,
          noticeAction: action,
        );
      case CommandNotSent():
        state = state.copyWith(
          clearPending: true,
          notice: BannerNotice.notSent,
          noticeAction: action,
        );
    }
  }
}

/// Staff web: every banner and its commands.
class StaffBannersController extends StaffCatalogController<StaffBanners> {
  @override
  Future<AccessRead<StaffBanners>> fetch() =>
      ref.read(bannerRepositoryProvider).fetchStaffBanners();

  @override
  String get idKey => 'banner_id';

  @override
  String get publishCommand => BannerCommands.publishBanner;

  @override
  Set<String> get syncAfter => const {
    BannerCommands.publishBanner,
    BannerCommands.withdrawBanner,
    BannerCommands.archiveBanner,
  };

  @override
  BannerNotice success(String command) => switch (command) {
    BannerCommands.createBanner => BannerNotice.created,
    BannerCommands.saveBanner => BannerNotice.saved,
    BannerCommands.publishBanner => BannerNotice.published,
    BannerCommands.withdrawBanner => BannerNotice.withdrawn,
    _ => BannerNotice.archived,
  };

  Future<void> create(BannerInput input) => send(
    BannerCommands.createBanner,
    const Optional.of(null),
    input.toCreatePayload(),
    input.title.trim(),
  );

  Future<void> save(StaffBanner banner, BannerInput input) => send(
    BannerCommands.saveBanner,
    Optional.of(banner.revision),
    input.toSavePayload(banner.bannerId),
    input.title.trim(),
  );

  Future<void> publish(StaffBanner b) =>
      _lifecycle(BannerCommands.publishBanner, b);

  Future<void> withdraw(StaffBanner b) =>
      _lifecycle(BannerCommands.withdrawBanner, b);

  Future<void> archive(StaffBanner b) =>
      _lifecycle(BannerCommands.archiveBanner, b);

  Future<void> _lifecycle(String command, StaffBanner b) => send(
    command,
    Optional.of(b.revision),
    {'banner_id': b.bannerId},
    b.current.fields.title,
  );
}

final staffBannersProvider =
    NotifierProvider<StaffBannersController, StaffCatalogState<StaffBanners>>(
      StaffBannersController.new,
    );

/// Staff web: every rights record and its commands. Verifying is the
/// record's publish step: the revision comes into force with the verifier
/// and the date.
class StaffRightsController extends StaffCatalogController<StaffRights> {
  @override
  Future<AccessRead<StaffRights>> fetch() =>
      ref.read(bannerRepositoryProvider).fetchStaffRights();

  @override
  String get idKey => 'rights_id';

  @override
  String get publishCommand => BannerCommands.verifyRights;

  @override
  Set<String> get syncAfter => const {
    BannerCommands.verifyRights,
    BannerCommands.withdrawRights,
    BannerCommands.archiveRights,
  };

  @override
  BannerNotice success(String command) => switch (command) {
    BannerCommands.createRights => BannerNotice.created,
    BannerCommands.saveRights => BannerNotice.saved,
    BannerCommands.verifyRights => BannerNotice.verified,
    BannerCommands.withdrawRights => BannerNotice.withdrawn,
    _ => BannerNotice.archived,
  };

  Future<void> create(RightsInput input) => send(
    BannerCommands.createRights,
    const Optional.of(null),
    input.toPayload(),
    input.label.trim(),
  );

  Future<void> save(RightsRecord record, RightsInput input) => send(
    BannerCommands.saveRights,
    Optional.of(record.revision),
    input.toPayload(rightsId: record.rightsId),
    input.label.trim(),
  );

  Future<void> verify(RightsRecord r) =>
      _lifecycle(BannerCommands.verifyRights, r);

  Future<void> withdraw(RightsRecord r) =>
      _lifecycle(BannerCommands.withdrawRights, r);

  Future<void> archive(RightsRecord r) =>
      _lifecycle(BannerCommands.archiveRights, r);

  Future<void> _lifecycle(String command, RightsRecord r) => send(
    command,
    Optional.of(r.revision),
    {'rights_id': r.rightsId},
    r.current.fields.label,
  );
}

final staffRightsProvider =
    NotifierProvider<StaffRightsController, StaffCatalogState<StaffRights>>(
      StaffRightsController.new,
    );

/// Where an image upload for one banner stands.
enum ImageUploadStatus { idle, picking, uploading, uploaded, refused, failed }

class BannerImageUpload {
  const BannerImageUpload({
    this.status = ImageUploadStatus.idle,
    this.image,
    this.bytes,
    this.outcome,
  });

  final ImageUploadStatus status;

  /// The uploaded image (status uploaded): save the draft to use it.
  final UploadedImage? image;

  /// The picked bytes, for the preview (in memory only).
  final Uint8List? bytes;

  /// The last answer (refusals and failures included).
  final ImageUploadOutcome? outcome;

  bool get busy =>
      status == ImageUploadStatus.picking ||
      status == ImageUploadStatus.uploading;
}

/// One banner's image upload: pick a file, send it to the server, keep the
/// answer. The server measures the bytes; nothing is attached until the
/// editor saves the draft with the uploaded image.
class BannerImageUploadController extends Notifier<BannerImageUpload> {
  BannerImageUploadController(this.bannerId);

  final String bannerId;

  @override
  BannerImageUpload build() {
    ref.watch(accountGenerationProvider);
    return const BannerImageUpload();
  }

  Future<void> pickAndUpload() async {
    if (state.busy) return;
    state = const BannerImageUpload(status: ImageUploadStatus.picking);
    final file = await ref.read(contentFilePickerProvider).pickImage();
    if (!ref.mounted) return;
    if (file == null) {
      state = const BannerImageUpload();
      return;
    }
    // Larger than the route reads at all: refused here, nothing sent.
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
        .uploadImage(bannerId, ContentPurposes.bannerImage, file);
    if (!ref.mounted) return;
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

final bannerImageUploadProvider = NotifierProvider.autoDispose
    .family<BannerImageUploadController, BannerImageUpload, String>(
      BannerImageUploadController.new,
    );

/// An uploaded (private) image's bytes for an editor's preview, through the
/// access-checked route; null when it cannot be read. In memory only.
final bannerPreviewProvider = FutureProvider.autoDispose
    .family<Uint8List?, String>((ref, assetId) {
      ref.watch(accountGenerationProvider);
      return ref.read(bannerRepositoryProvider).previewImage(assetId);
    });
