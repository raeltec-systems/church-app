import 'dart:convert';
import 'dart:math' as math;

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/commands.dart';
import '../domain/content_bible.dart';
import '../domain/content_events.dart' show ContentCommands;
import '../domain/content_banners.dart' show PickedFile;
import '../domain/public_content_cache.dart';
import 'providers.dart';

/// Public reader state. The saved chapter is loaded before the online catalog
/// request so a cold launch can render a rights-cleared copy without network.
class BibleReaderState {
  const BibleReaderState({
    this.loading = false,
    this.catalog,
    this.catalogError,
    this.chapter,
    this.chapterError,
    this.reference,
    this.translationId,
    this.asOf,
    this.savedAt,
    this.offlineSnapshot = false,
    this.saving = false,
    this.savedOffline = false,
    this.message,
  });

  final bool loading;
  final AccessRead<PublicBibleTranslations>? catalog;
  final AccessRead<PublicBibleTranslations>? catalogError;
  final AccessRead<PublicBibleChapter?>? chapter;
  final AccessRead<PublicBibleChapter?>? chapterError;
  final BibleChapterRef? reference;
  final String? translationId;
  final DateTime? asOf;
  final DateTime? savedAt;
  final bool offlineSnapshot;
  final bool saving;
  final bool savedOffline;
  final String? message;

  PublicBibleTranslations? get translations => switch (catalog) {
    AccessReadOk<PublicBibleTranslations>(:final value) => value,
    _ => null,
  };

  PublicBibleChapter? get value => switch (chapter) {
    AccessReadOk<PublicBibleChapter?>(:final value) => value,
    _ => null,
  };

  BibleTranslation? get selectedTranslation {
    for (final translation
        in translations?.translations ?? const <BibleTranslation>[]) {
      if (translation.id == translationId) return translation;
    }
    return null;
  }

  BibleChapterRef? get previous {
    final list = selectedTranslation?.chapters ?? const <BibleChapterRef>[];
    final current = reference;
    if (current == null) return null;
    final index = list.indexOf(current);
    return index > 0 ? list[index - 1] : null;
  }

  BibleChapterRef? get next {
    final list = selectedTranslation?.chapters ?? const <BibleChapterRef>[];
    final current = reference;
    if (current == null) return null;
    final index = list.indexOf(current);
    return index >= 0 && index + 1 < list.length ? list[index + 1] : null;
  }

  BibleReaderState copyWith({
    bool? loading,
    AccessRead<PublicBibleTranslations>? catalog,
    AccessRead<PublicBibleTranslations>? catalogError,
    bool clearCatalogError = false,
    AccessRead<PublicBibleChapter?>? chapter,
    AccessRead<PublicBibleChapter?>? chapterError,
    bool clearChapterError = false,
    bool clearChapter = false,
    BibleChapterRef? reference,
    bool clearReference = false,
    String? translationId,
    bool clearTranslationId = false,
    DateTime? asOf,
    bool clearAsOf = false,
    DateTime? savedAt,
    bool clearSavedAt = false,
    bool? offlineSnapshot,
    bool? saving,
    bool? savedOffline,
    String? message,
    bool clearMessage = false,
  }) => BibleReaderState(
    loading: loading ?? this.loading,
    catalog: catalog ?? this.catalog,
    catalogError: clearCatalogError
        ? null
        : (catalogError ?? this.catalogError),
    chapter: clearChapter ? null : (chapter ?? this.chapter),
    chapterError: clearChapterError
        ? null
        : (chapterError ?? this.chapterError),
    reference: clearReference ? null : (reference ?? this.reference),
    translationId: clearTranslationId
        ? null
        : (translationId ?? this.translationId),
    asOf: clearAsOf ? null : (asOf ?? this.asOf),
    savedAt: clearSavedAt ? null : (savedAt ?? this.savedAt),
    offlineSnapshot: offlineSnapshot ?? this.offlineSnapshot,
    saving: saving ?? this.saving,
    savedOffline: savedOffline ?? this.savedOffline,
    message: clearMessage ? null : (message ?? this.message),
  );
}

class BibleReaderController extends Notifier<BibleReaderState> {
  int _epoch = 0;

  @override
  BibleReaderState build() {
    ref.watch(accountGenerationProvider);
    ref.listen(publicContentReconnectsProvider, (previous, next) {
      if (next.hasValue) reload();
    });
    final epoch = ++_epoch;
    Future.microtask(() => _start(epoch));
    return const BibleReaderState(loading: true);
  }

  bool _current(int epoch) => ref.mounted && _epoch == epoch;

  Future<void> reload() async {
    final epoch = ++_epoch;
    await _start(epoch);
  }

  Future<void> _start(int epoch) async {
    if (!_current(epoch)) return;
    final requestedTranslationId = state.translationId;
    final requestedReference = state.reference;
    state = state.copyWith(loading: true, clearMessage: true);
    // Restore first: an online request that fails must never prevent a saved
    // offline chapter from appearing on a fresh launch.
    final snapshot = await ref
        .read(publicContentCacheProvider)
        .readBibleChapter();
    if (!_current(epoch)) return;
    if (snapshot != null) {
      state = state.copyWith(
        chapter: AccessReadOk(snapshot.value),
        reference: snapshot.value.reference,
        translationId: snapshot.value.translationId,
        asOf: snapshot.savedAt,
        savedAt: snapshot.savedAt,
        offlineSnapshot: true,
        savedOffline: true,
      );
    }
    final result = await ref
        .read(bibleRepositoryProvider)
        .fetchPublicTranslations();
    if (!_current(epoch)) return;
    if (result is! AccessReadOk<PublicBibleTranslations>) {
      state = state.copyWith(
        loading: false,
        catalogError: result,
        offlineSnapshot: snapshot != null,
      );
      return;
    }
    final usable = result.value.translations;
    state = state.copyWith(
      catalog: result,
      clearCatalogError: true,
      loading: false,
      offlineSnapshot: snapshot != null,
    );
    if (usable.isEmpty) {
      if (snapshot == null) {
        state = state.copyWith(
          clearChapter: true,
          clearReference: true,
          clearTranslationId: true,
        );
      }
      return;
    }
    final saved = snapshot?.value;
    final savedTranslationId = requestedTranslationId ?? saved?.translationId;
    final savedReference = requestedReference ?? saved?.reference;
    final matching = savedTranslationId == null || savedReference == null
        ? null
        : usable
              .where(
                (t) =>
                    t.id == savedTranslationId && t.hasChapter(savedReference),
              )
              .firstOrNull;
    if (matching != null) {
      await _loadChapter(matching, savedReference!, epoch);
    } else {
      final translation = usable.firstWhere((t) => t.firstChapter != null);
      final first = translation.firstChapter;
      if (first != null) await _loadChapter(translation, first, epoch);
    }
  }

  Future<void> chooseTranslation(String id) async {
    final translation = state.translations?.translations
        .where((t) => t.id == id)
        .firstOrNull;
    if (translation == null || translation.firstChapter == null) return;
    final currentReference = state.reference;
    final ref =
        currentReference != null && translation.hasChapter(currentReference)
        ? currentReference
        : translation.firstChapter!;
    final epoch = ++_epoch;
    await _loadChapter(translation, ref, epoch);
  }

  Future<void> chooseBook(String bookId) async {
    final translation = state.selectedTranslation;
    if (translation == null) return;
    final ref = translation.chapters
        .where((c) => c.bookId == bookId)
        .firstOrNull;
    if (ref != null) {
      final epoch = ++_epoch;
      await _loadChapter(translation, ref, epoch);
    }
  }

  Future<void> chooseChapter(int chapter) async {
    final translation = state.selectedTranslation;
    final book = state.reference?.bookId;
    if (translation == null || book == null) return;
    final ref = BibleChapterRef(bookId: book, chapter: chapter);
    if (!translation.hasChapter(ref)) return;
    final epoch = ++_epoch;
    await _loadChapter(translation, ref, epoch);
  }

  Future<void> move(bool forward) async {
    final translation = state.selectedTranslation;
    final reference = state.reference;
    if (translation == null || reference == null) return;
    final current = translation.chapters.indexOf(reference);
    final index = current + (forward ? 1 : -1);
    if (current < 0 || index < 0 || index >= translation.chapters.length) {
      return;
    }
    final epoch = ++_epoch;
    await _loadChapter(translation, translation.chapters[index], epoch);
  }

  Future<void> _loadChapter(
    BibleTranslation translation,
    BibleChapterRef reference,
    int epoch,
  ) async {
    if (!_current(epoch)) return;
    state = state.copyWith(
      loading: true,
      translationId: translation.id,
      reference: reference,
      offlineSnapshot: false,
      clearMessage: true,
      clearChapter:
          !(state.value?.offlineAllowed == true &&
              state.value?.translationId == translation.id &&
              state.value?.reference == reference),
      clearSavedAt:
          !(state.value?.offlineAllowed == true &&
              state.value?.translationId == translation.id &&
              state.value?.reference == reference),
      clearChapterError: true,
    );
    final result = await ref
        .read(bibleRepositoryProvider)
        .fetchPublicChapter(translation.id, reference);
    if (!_current(epoch)) return;
    final chapter = result is AccessReadOk<PublicBibleChapter?>
        ? result.value
        : null;
    if (chapter != null) {
      state = state.copyWith(
        loading: false,
        chapter: AccessReadOk(chapter),
        clearChapterError: true,
        asOf: DateTime.now(),
        offlineSnapshot: false,
        savedOffline: false,
        clearSavedAt: true,
      );
    } else if (result is AccessReadFailed<PublicBibleChapter?>) {
      final saved = await ref
          .read(publicContentCacheProvider)
          .readBibleChapter();
      if (!_current(epoch)) return;
      final savedChapter = saved?.value;
      final savedMatches =
          savedChapter != null &&
          savedChapter.translationId == translation.id &&
          savedChapter.reference == reference &&
          savedChapter.offlineAllowed;
      if (savedMatches) {
        state = state.copyWith(
          loading: false,
          chapter: AccessReadOk(savedChapter),
          savedAt: saved!.savedAt,
          asOf: saved.savedAt,
          offlineSnapshot: true,
          savedOffline: true,
          chapterError: result,
        );
      } else {
        state = state.copyWith(
          loading: false,
          offlineSnapshot: false,
          savedOffline: false,
          clearSavedAt: true,
          chapterError: result,
        );
      }
    } else {
      state = state.copyWith(
        loading: false,
        chapter: result is AccessReadOk<PublicBibleChapter?>
            ? AccessReadOk<PublicBibleChapter?>(null)
            : state.chapter,
        clearChapter: result is AccessReadOk<PublicBibleChapter?>,
        clearSavedAt: true,
        chapterError: result,
        savedOffline: false,
      );
    }
  }

  Future<void> saveOffline() async {
    final chapter = state.value;
    if (chapter == null ||
        !chapter.offlineAllowed ||
        state.offlineSnapshot ||
        state.saving) {
      return;
    }
    final epoch = _epoch;
    final generation = ref.read(accountGenerationProvider);
    state = state.copyWith(saving: true, clearMessage: true);
    final result = await ref
        .read(publicContentCacheProvider)
        .writeRead(PublicContentCacheKeys.bibleChapter, chapter);
    if (!ref.mounted || ref.read(accountGenerationProvider) != generation) {
      return;
    }
    if (!_current(epoch)) {
      state = state.copyWith(saving: false);
      return;
    }
    state = switch (result) {
      PublicContentCacheSaved(:final savedAt) => state.copyWith(
        saving: false,
        savedOffline: true,
        savedAt: savedAt,
        message: 'Saved for offline reading',
      ),
      PublicContentCacheRefused(:final reason) => state.copyWith(
        saving: false,
        message: reason == PublicContentCacheRefusal.offlineRightsNotCleared
            ? 'Offline rights are not cleared for this chapter'
            : 'This chapter could not be saved',
      ),
      _ => state.copyWith(
        saving: false,
        message: 'This chapter could not be saved',
      ),
    };
  }
}

final bibleReaderProvider =
    NotifierProvider<BibleReaderController, BibleReaderState>(
      BibleReaderController.new,
    );

class BibleStaffState {
  const BibleStaffState({
    this.loading = false,
    this.catalog,
    this.busy = false,
    this.progress = 0,
    this.total = 0,
    this.errors = const [],
    this.message,
    this.unconfirmed,
  });

  final bool loading;
  final AccessRead<StaffBibleTranslations>? catalog;
  final bool busy;
  final int progress;
  final int total;
  final List<BibleCsvError> errors;
  final String? message;
  final CommandRequest? unconfirmed;

  StaffBibleTranslations? get value => switch (catalog) {
    AccessReadOk<StaffBibleTranslations>(:final value) => value,
    _ => null,
  };
}

class BibleStaffController extends Notifier<BibleStaffState> {
  int _epoch = 0;

  @override
  BibleStaffState build() {
    ref.watch(accountGenerationProvider);
    final epoch = ++_epoch;
    Future.microtask(() => reload(epoch));
    return const BibleStaffState(loading: true);
  }

  bool _current(int epoch) => ref.mounted && _epoch == epoch;

  Future<void> reload([int? expectedEpoch]) async {
    final epoch = expectedEpoch ?? ++_epoch;
    if (!_current(epoch)) return;
    state = BibleStaffState(
      loading: true,
      busy: state.busy,
      unconfirmed: state.unconfirmed,
    );
    final result = await ref
        .read(bibleRepositoryProvider)
        .fetchStaffTranslations();
    if (!_current(epoch)) return;
    state = BibleStaffState(
      catalog: result,
      busy: state.busy,
      unconfirmed: state.unconfirmed,
      message: result is AccessReadDenied<StaffBibleTranslations>
          ? 'Bible editing is not available for this account'
          : null,
    );
  }

  Future<void> importCsv({
    required String? translationId,
    required String code,
    required String name,
    required String rightsId,
    required PickedFile file,
  }) async {
    if (state.busy) return;
    if (file.unreadable || file.bytes.length > bibleCsvMaxBytes) {
      state = const BibleStaffState(message: 'CSV file is too large to read');
      return;
    }
    if (!isBibleTranslationCode(code) || rightsId.trim().isEmpty) {
      state = BibleStaffState(
        message: 'Enter a valid translation code and a rights record',
      );
      return;
    }
    final manifestRead = await ref
        .read(bibleRepositoryProvider)
        .fetchVerseManifest(code);
    if (manifestRead is! AccessReadOk<BibleVerseManifest>) {
      state = BibleStaffState(
        catalog: state.catalog,
        message: 'The trusted verse manifest is unavailable',
      );
      return;
    }
    late final String csv;
    try {
      csv = utf8.decode(file.bytes, allowMalformed: false);
    } on FormatException {
      state = BibleStaffState(
        catalog: state.catalog,
        message: 'CSV must be valid UTF-8',
      );
      return;
    }
    final parsed = parseBibleCsv(csv, manifestRead.value);
    if (!parsed.valid) {
      state = BibleStaffState(
        catalog: state.catalog,
        errors: parsed.errors,
        message: parsed.errors.isEmpty
            ? 'CSV has no verse rows'
            : 'Fix the CSV errors before importing',
      );
      return;
    }
    await _importRows(
      translationId: translationId,
      code: code,
      name: name,
      rightsId: rightsId,
      manifest: manifestRead.value,
      rows: parsed.rows,
    );
  }

  /// Installs the bundled, source-checked WEB text without asking church
  /// staff to download or format a verse file.
  Future<void> installWorldEnglishBible({required String rightsId}) async {
    if (state.busy) return;
    if (rightsId.trim().isEmpty) {
      state = BibleStaffState(
        catalog: state.catalog,
        message: 'Choose a verified WEB rights record first',
      );
      return;
    }
    if (state.value == null) {
      state = BibleStaffState(
        catalog: state.catalog,
        message: 'Reload the translation list before installing WEB',
      );
      return;
    }
    final manifestRead = await ref
        .read(bibleRepositoryProvider)
        .fetchVerseManifest('WEB');
    if (manifestRead is! AccessReadOk<BibleVerseManifest>) {
      state = BibleStaffState(
        catalog: state.catalog,
        message: 'The trusted WEB verse manifest is unavailable',
      );
      return;
    }
    late final String source;
    try {
      source = await ref
          .read(bibleTranslationPackageSourceProvider)
          .loadWorldEnglishBibleVpl();
    } on Object {
      state = BibleStaffState(
        catalog: state.catalog,
        message: 'The bundled WEB package could not be read. Update the staff app and try again.',
      );
      return;
    }
    final parsed = parseBibleVpl(source, manifestRead.value);
    if (!parsed.valid) {
      state = BibleStaffState(
        catalog: state.catalog,
        errors: parsed.errors,
        message: 'The bundled WEB package did not match its trusted manifest',
      );
      return;
    }
    final existing = state.value!.translations
        .where((translation) => translation.code == 'WEB')
        .firstOrNull;
    await _importRows(
      translationId: existing?.id,
      code: 'WEB',
      name: 'World English Bible',
      rightsId: rightsId,
      manifest: manifestRead.value,
      rows: parsed.rows,
    );
  }

  Future<void> _importRows({
    required String? translationId,
    required String code,
    required String name,
    required String rightsId,
    required BibleVerseManifest manifest,
    required List<BibleCsvRow> rows,
  }) async {
    final epoch = ++_epoch;
    state = BibleStaffState(
      busy: true,
      catalog: state.catalog,
      total: rows.length,
      progress: 0,
    );
    var id = translationId;
    var expected = const Optional<int>.of(null);
    var revisionNo = 1;
    if (id == null) {
      final created = await _send(BibleCommands.create, expected, {
        'translation_code': code,
        'name': name.trim(),
        'rights_id': rightsId.trim(),
        'manifest_version': manifest.version,
      }, epoch);
      if (created == null) return;
      id = _dataString(created.data, 'translation_id');
      if (id == null) {
        state = BibleStaffState(
          message: 'The server did not return the new translation',
        );
        return;
      }
      expected = Optional<int>.of(created.revision);
    } else {
      final current = state.value?.translations
          .where((t) => t.id == id)
          .firstOrNull;
      if (current == null) {
        state = BibleStaffState(
          message: 'Reload the translation list and try again',
        );
        return;
      }
      final begun = await _send(
        BibleCommands.beginRevision,
        Optional<int>.of(current.revision),
        {
          'translation_id': id,
          'rights_id': rightsId.trim(),
          'manifest_version': manifest.version,
        },
        epoch,
      );
      if (begun == null) return;
      expected = Optional<int>.of(begun.revision);
      revisionNo =
          _dataInt(begun.data, 'draft_revision_no') ??
          current.lastRevisionNo + 1;
    }
    for (var start = 0; start < rows.length; start += bibleCsvBatchSize) {
      final end = math.min(start + bibleCsvBatchSize, rows.length);
      final batch = rows.sublist(start, end);
      final imported = await _send(BibleCommands.importVerses, expected, {
        'translation_id': id,
        'revision_no': revisionNo,
        'rows': batch.map((row) => row.toJson()).toList(),
      }, epoch);
      if (imported == null) return;
      expected = Optional<int>.of(imported.revision);
      state = BibleStaffState(
        busy: true,
        total: rows.length,
        progress: end,
        message: 'Installed $end of ${rows.length} verses',
      );
    }
    final finalized = await _send(BibleCommands.finalize, expected, {
      'translation_id': id,
      'revision_no': revisionNo,
    }, epoch);
    if (finalized == null) return;
    await reload(epoch);
    if (!_current(epoch)) return;
    state = BibleStaffState(
      catalog: state.catalog,
      progress: rows.length,
      total: rows.length,
      message: 'Complete draft revision $revisionNo is ready to review',
    );
  }

  Future<void> publish(StaffBibleTranslation translation) =>
      _lifecycle(BibleCommands.publish, translation);

  Future<void> withdraw(StaffBibleTranslation translation) =>
      _lifecycle(BibleCommands.withdraw, translation);

  Future<void> archive(StaffBibleTranslation translation) =>
      _lifecycle(BibleCommands.archive, translation);

  Future<void> _lifecycle(
    String command,
    StaffBibleTranslation translation,
  ) async {
    if (state.busy) return;
    final epoch = ++_epoch;
    state = BibleStaffState(busy: true, catalog: state.catalog);
    final result = await _send(
      command,
      Optional<int>.of(translation.revision),
      {'translation_id': translation.id},
      epoch,
    );
    if (result == null) return;
    await reload(epoch);
    if (!_current(epoch)) return;
    state = BibleStaffState(
      catalog: state.catalog,
      message: 'Bible translation updated',
    );
  }

  Future<void> checkAgain() async {
    final request = state.unconfirmed;
    if (request == null || state.busy) return;
    final epoch = ++_epoch;
    state = BibleStaffState(
      busy: true,
      unconfirmed: request,
      catalog: state.catalog,
    );
    final result = await _dispatch(request, epoch);
    if (result != null && _current(epoch)) {
      await reload(epoch);
      if (!_current(epoch)) return;
      state = BibleStaffState(
        catalog: state.catalog,
        message:
            'The request was confirmed. Reload the list before continuing.',
      );
    }
  }

  Future<CommandSuccess?> _send(
    String command,
    Optional<int> expected,
    Map<String, Object?> payload,
    int epoch,
  ) async {
    final request = CommandRequest(
      command: command,
      requestId: ref.read(requestIdsProvider).next(),
      expectedRevision: expected,
      payload: payload,
    );
    return _dispatch(request, epoch);
  }

  Future<CommandSuccess?> _dispatch(CommandRequest request, int epoch) async {
    final result = await ref
        .read(commandGatewayProvider)
        .send(ContentCommands.function, request);
    if (!_current(epoch)) return null;
    switch (result) {
      case CommandConfirmed(:final success):
        state = BibleStaffState(busy: state.busy, catalog: state.catalog);
        return success;
      case CommandUnknownOutcome():
        state = BibleStaffState(
          catalog: state.catalog,
          unconfirmed: request,
          message: 'The result is not confirmed. Check the same request before continuing.',
        );
        return null;
      case CommandRefused(:final error):
        final message = error.code == ErrorCode.conflict
            ? 'The translation changed elsewhere. Reload and review it.'
            : 'The server refused this action (${error.code.wireName})';
        state = BibleStaffState(catalog: state.catalog, message: message);
        await reload(epoch);
        if (!_current(epoch)) return null;
        state = BibleStaffState(catalog: state.catalog, message: message);
        return null;
      case CommandNotSent(:final reason):
        state = BibleStaffState(
          catalog: state.catalog,
          message: 'The request was not sent: $reason',
        );
        return null;
    }
  }

  static String? _dataString(Object? data, String key) {
    if (data is! Map) return null;
    final value = data[key];
    return value is String ? value : null;
  }

  static int? _dataInt(Object? data, String key) {
    if (data is! Map) return null;
    final value = data[key];
    return value is int ? value : null;
  }
}

final bibleStaffProvider =
    NotifierProvider<BibleStaffController, BibleStaffState>(
      BibleStaffController.new,
    );
