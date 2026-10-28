import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/banner_controllers.dart' show staffRightsProvider;
import '../application/bible_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/content_banners.dart';
import '../domain/content_bible.dart';
import '../domain/content_events.dart' show ContentState;
import 'shell_routing.dart' show ClientPaths;

/// Public Bible reader for the mobile Bible & Hymns tab.
class BibleReaderScreen extends ConsumerWidget {
  const BibleReaderScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final state = ref.watch(bibleReaderProvider);
    final controller = ref.read(bibleReaderProvider.notifier);
    final translations =
        state.translations?.translations ?? const <BibleTranslation>[];
    final selected = state.selectedTranslation;
    final chapter = state.value;
    final availableBooks = selected == null
        ? const <BibleBook>[]
        : bibleBooks
              .where(
                (book) => selected.chapters.any((r) => r.bookId == book.id),
              )
              .toList();
    final bookId = state.reference?.bookId;
    final selectedBook = availableBooks
        .where((book) => book.id == bookId)
        .firstOrNull;
    final availableChapters =
        selected?.chapters.where((r) => r.bookId == bookId).toList() ??
        const <BibleChapterRef>[];

    return ColoredBox(
      color: c.bg,
      child: ListView(
        // Story 6.7: the tab's Bible / Hymn book segment above names the
        // view, so the reader starts with its own state and pickers.
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          if (state.offlineSnapshot)
            _ReaderNotice(
              icon: Icons.offline_pin_outlined,
              message:
                  'Offline copy saved ${_savedTime(state.savedAt)}. This is the last chapter saved on this device.',
            )
          else if (state.catalogError != null && state.translations == null)
            _ReaderNotice(
              icon: Icons.cloud_off_outlined,
              message: 'The online Bible catalog could not be reached. Saved chapters are checked separately.',
            ),
          if (state.offlineSnapshot || state.catalogError != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('bible-reconnect'),
                onPressed: state.loading ? null : controller.reload,
                icon: const Icon(Icons.refresh),
                label: const Text('Try online again'),
              ),
            ),
          if (chapter != null &&
              !state.offlineSnapshot &&
              state.chapterError is AccessReadFailed<PublicBibleChapter?>)
            const _ReaderNotice(
              icon: Icons.cloud_off_outlined,
              message: 'Could not refresh this chapter. The copy shown is not saved for offline reading.',
            ),
          const SizedBox(height: 12),
          if (translations.isNotEmpty)
            _ReaderPickers(
              translations: translations,
              selectedTranslation: state.translationId,
              books: availableBooks,
              selectedBook: selectedBook?.id,
              chapters: availableChapters,
              selectedChapter: state.reference?.chapter,
              enabled: !state.offlineSnapshot,
              onTranslation: controller.chooseTranslation,
              onBook: controller.chooseBook,
              onChapter: controller.chooseChapter,
            )
          else if (state.offlineSnapshot && chapter != null)
            _CachedReference(chapter: chapter)
          else if (state.loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: CircularProgressIndicator(),
              ),
            )
          else
            _EmptyReader(
              message: state.catalogError != null
                  ? 'The Bible could not be loaded right now.'
                  : 'No published Bible translations are available.',
              onRetry: controller.reload,
            ),
          if (chapter != null) ...[
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${bibleBook(chapter.reference.bookId)!.name} ${chapter.reference.chapter}',
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(color: c.ink, fontWeight: FontWeight.w700),
                  ),
                ),
                if (!state.offlineSnapshot && chapter.offlineAllowed)
                  TextButton.icon(
                    onPressed: state.saving ? null : controller.saveOffline,
                    icon: Icon(
                      state.savedOffline
                          ? Icons.check_circle_outline
                          : Icons.download_outlined,
                    ),
                    label: Text(state.savedOffline ? 'Saved' : 'Save offline'),
                  ),
              ],
            ),
            Text(
              '${chapter.translationName} (${chapter.translationCode})',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: c.muted),
            ),
            if (chapter.omittedVerses.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Some verse numbers are omitted in this translation.',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: c.muted),
                ),
              ),
            if (state.message != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(state.message!, style: TextStyle(color: c.muted)),
              ),
            const SizedBox(height: 16),
            for (final verse in chapter.verses)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _VerseText(verse: verse),
              ),
            const SizedBox(height: 12),
            if (!state.offlineSnapshot)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  OutlinedButton.icon(
                    key: const Key('bible-previous'),
                    onPressed: state.previous == null || state.loading
                        ? null
                        : () => controller.move(false),
                    icon: const Icon(Icons.chevron_left),
                    label: const Text('Previous'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('bible-next'),
                    onPressed: state.next == null || state.loading
                        ? null
                        : () => controller.move(true),
                    icon: const Icon(Icons.chevron_right),
                    label: const Text('Next'),
                    iconAlignment: IconAlignment.end,
                  ),
                ],
              ),
            if (state.offlineSnapshot)
              Text(
                'Connect to browse another chapter. The online catalog remains separate from this saved copy.',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: c.muted),
              ),
          ] else if (state.loading && translations.isNotEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: CircularProgressIndicator(),
              ),
            )
          else if (translations.isNotEmpty &&
              state.chapterError is AccessReadFailed<PublicBibleChapter?>)
            _EmptyReader(
              message: 'This chapter could not be loaded. Try again.',
              onRetry: controller.reload,
            )
          else if (translations.isNotEmpty)
            _EmptyReader(
              message:
                  'This chapter is not available in the selected translation.',
            ),
        ],
      ),
    );
  }
}

class _ReaderPickers extends StatelessWidget {
  const _ReaderPickers({
    required this.translations,
    required this.selectedTranslation,
    required this.books,
    required this.selectedBook,
    required this.chapters,
    required this.selectedChapter,
    required this.enabled,
    required this.onTranslation,
    required this.onBook,
    required this.onChapter,
  });

  final List<BibleTranslation> translations;
  final String? selectedTranslation;
  final List<BibleBook> books;
  final String? selectedBook;
  final List<BibleChapterRef> chapters;
  final int? selectedChapter;
  final bool enabled;
  final ValueChanged<String> onTranslation;
  final ValueChanged<String> onBook;
  final ValueChanged<int> onChapter;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      DropdownButtonFormField<String>(
        key: const Key('bible-translation-picker'),
        isExpanded: true,
        initialValue: translations.any((t) => t.id == selectedTranslation)
            ? selectedTranslation
            : null,
        decoration: const InputDecoration(labelText: 'Translation'),
        items: [
          for (final t in translations)
            DropdownMenuItem(
              value: t.id,
              child: Text(
                '${t.name} (${t.code})',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: enabled
            ? (value) {
                if (value != null) onTranslation(value);
              }
            : null,
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            flex: 3,
            child: DropdownButtonFormField<String>(
              key: const Key('bible-book-picker'),
              initialValue: books.any((b) => b.id == selectedBook)
                  ? selectedBook
                  : null,
              decoration: const InputDecoration(labelText: 'Book'),
              items: [
                for (final b in books)
                  DropdownMenuItem(
                    value: b.id,
                    child: Text(b.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: enabled
                  ? (value) {
                      if (value != null) onBook(value);
                    }
                  : null,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: DropdownButtonFormField<int>(
              key: const Key('bible-chapter-picker'),
              initialValue: chapters.any((r) => r.chapter == selectedChapter)
                  ? selectedChapter
                  : null,
              decoration: const InputDecoration(labelText: 'Chapter'),
              items: [
                for (final r in chapters)
                  DropdownMenuItem(
                    value: r.chapter,
                    child: Text('${r.chapter}'),
                  ),
              ],
              onChanged: enabled
                  ? (value) {
                      if (value != null) onChapter(value);
                    }
                  : null,
            ),
          ),
        ],
      ),
    ],
  );
}

class _VerseText extends StatelessWidget {
  const _VerseText({required this.verse});
  final BibleVerse verse;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return Text.rich(
      TextSpan(
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.aboveBaseline,
            baseline: TextBaseline.alphabetic,
            child: Transform.translate(
              offset: const Offset(0, -3),
              child: Text(
                '${verse.number}',
                style: TextStyle(
                  color: c.accent,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          TextSpan(
            text: '  ${verse.text}',
            style: TextStyle(color: c.ink, fontSize: 18, height: 1.6),
          ),
        ],
      ),
    );
  }
}

class _ReaderNotice extends StatelessWidget {
  const _ReaderNotice({required this.icon, required this.message});
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.blueBg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, color: c.blueFg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: TextStyle(color: c.blueFg)),
          ),
        ],
      ),
    );
  }
}

class _CachedReference extends StatelessWidget {
  const _CachedReference({required this.chapter});
  final PublicBibleChapter chapter;

  @override
  Widget build(BuildContext context) => Text(
    '${chapter.translationName} · ${bibleBook(chapter.reference.bookId)!.name} ${chapter.reference.chapter}',
    style: Theme.of(context).textTheme.bodyMedium,
  );
}

class _EmptyReader extends StatelessWidget {
  const _EmptyReader({required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Column(
      children: [
        Text(message, textAlign: TextAlign.center),
        if (onRetry != null) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
        ],
      ],
    ),
  );
}

String _savedTime(DateTime? value) {
  if (value == null) return 'earlier';
  final d = value.toLocal();
  final mm = d.minute.toString().padLeft(2, '0');
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} at ${d.hour}:$mm';
}

/// Staff web: install a reviewed text package into a private draft, then
/// publish only after its rights are verified.
class StaffBibleScreen extends ConsumerStatefulWidget {
  const StaffBibleScreen({super.key});

  @override
  ConsumerState<StaffBibleScreen> createState() => _StaffBibleScreenState();
}

class _StaffBibleScreenState extends ConsumerState<StaffBibleScreen> {
  String? _rightsId;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(bibleStaffProvider);
    final controller = ref.read(bibleStaffProvider.notifier);
    final rightsState = ref.watch(staffRightsProvider);
    final translations =
        state.value?.translations ?? const <StaffBibleTranslation>[];
    final webRightsRecords =
        rightsState.value?.rights.where(_isWebRightsCandidate).toList() ??
        const <RightsRecord>[];
    final selectedRights =
        webRightsRecords
            .where((record) => record.rightsId == _rightsId)
            .firstOrNull ??
        webRightsRecords.firstOrNull;
    return Scaffold(
      backgroundColor: ChurchColors.of(context).bg,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1050),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                'Bible translations',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: ChurchColors.of(context).brand,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'The church app includes a curated World English Bible package. You do not need to download or format Bible files.',
              ),
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'World English Bible (WEB)',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Source: eBible.org · Public domain · The app checks every chapter and keeps this as a private draft until you publish it.',
                      ),
                      const SizedBox(height: 16),
                      if (rightsState.loading)
                        const LinearProgressIndicator()
                      else if (rightsState.result
                          case AccessReadFailed<StaffRights>())
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'The rights records could not be loaded. Try again before installing WEB.',
                            ),
                            TextButton.icon(
                              onPressed: ref
                                  .read(staffRightsProvider.notifier)
                                  .reload,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Reload rights'),
                            ),
                          ],
                        )
                      else if (rightsState.result
                          case AccessReadDenied<StaffRights>())
                        const Text(
                          'Verified rights records are not available for this account.',
                        )
                      else if (webRightsRecords.isEmpty) ...[
                        const Text(
                          'WEB is public domain, so no licence or permission is being requested. The app still needs one reusable eBible.org source record to check display and offline use. Create it once under Rights, then select it here for WEB installs.',
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          key: const Key('bible-open-rights'),
                          onPressed: () =>
                              context.go(ClientPaths.contentRights),
                          icon: const Icon(Icons.verified_outlined),
                          label: const Text('Create WEB source record'),
                        ),
                      ] else
                        DropdownButtonFormField<String>(
                          key: const Key('bible-web-rights'),
                          initialValue: selectedRights?.rightsId,
                          decoration: const InputDecoration(
                            labelText: 'WEB source rights record',
                          ),
                          items: [
                            for (final record in webRightsRecords)
                              DropdownMenuItem(
                                value: record.rightsId,
                                child: Text(
                                  record.current.fields.label,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: state.busy
                              ? null
                              : (value) => setState(() => _rightsId = value),
                        ),
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        key: const Key('bible-install-web'),
                        onPressed: state.busy || selectedRights == null
                            ? null
                            : () => controller.installWorldEnglishBible(
                                rightsId: selectedRights.rightsId,
                              ),
                        icon: const Icon(Icons.download_outlined),
                        label: const Text('Install WEB package'),
                      ),
                      if (state.busy) ...[
                        const SizedBox(height: 14),
                        LinearProgressIndicator(
                          value: state.total == 0
                              ? null
                              : state.progress / state.total,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Preparing ${state.progress} of ${state.total} verses',
                        ),
                      ],
                      if (state.message != null) ...[
                        const SizedBox(height: 12),
                        Text(state.message!),
                      ],
                      for (final error in state.errors.take(30))
                        Text(
                          error.toString(),
                          style: TextStyle(
                            color: ChurchColors.of(context).redFg,
                          ),
                        ),
                      if (state.errors.length > 30)
                        Text('${state.errors.length - 30} more CSV errors'),
                      if (state.unconfirmed != null)
                        TextButton(
                          onPressed: state.busy ? null : controller.checkAgain,
                          child: const Text('Check the same request again'),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              if (state.loading)
                const Center(child: CircularProgressIndicator())
              else if (state.catalog
                  case AccessReadDenied<StaffBibleTranslations>())
                const _StaffEmpty(
                  message: 'Bible editing is not available for this account.',
                )
              else if (state.catalog
                  case AccessReadFailed<StaffBibleTranslations>())
                Column(
                  children: [
                    const _StaffEmpty(
                      message:
                          'The Bible translation catalog could not be loaded.',
                    ),
                    TextButton.icon(
                      onPressed: controller.reload,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try again'),
                    ),
                  ],
                )
              else if (translations.isEmpty)
                const _StaffEmpty(
                  message: 'No Bible editions are installed yet. Add the curated WEB package to create a private draft.',
                )
              else ...[
                Text(
                  'Translations',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                for (final item in translations)
                  _StaffBibleCard(
                    translation: item,
                    busy: state.busy,
                    onPublish: () => controller.publish(item),
                    onWithdraw: () => controller.withdraw(item),
                    onArchive: () => controller.archive(item),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  bool _isWebRightsCandidate(RightsRecord record) {
    final fields = record.current.fields;
    if (record.state == ContentState.archived ||
        fields.basis != RightsBasis.publicDomain) {
      return false;
    }
    final evidence = fields.evidence.toLowerCase();
    final identity = '${fields.sourceKey} ${fields.label} ${fields.evidence}'
        .toLowerCase();
    return evidence.contains('ebible.org') &&
        RegExp(r'world\s+english\s+bible|(^|[^a-z0-9])web([^a-z0-9]|$)|engwebp')
            .hasMatch(identity);
  }
}

class _StaffBibleCard extends StatelessWidget {
  const _StaffBibleCard({
    required this.translation,
    required this.busy,
    required this.onPublish,
    required this.onWithdraw,
    required this.onArchive,
  });
  final StaffBibleTranslation translation;
  final bool busy;
  final VoidCallback onPublish;
  final VoidCallback onWithdraw;
  final VoidCallback onArchive;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${translation.name} (${translation.code})',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              'State: ${translation.state.name} · revision ${translation.revision} · last revision ${translation.lastRevisionNo}',
            ),
            if (translation.draftRevisionNo != null)
              Text(
                'Draft r${translation.draftRevisionNo} · ${translation.draftVerseCount} verses · ${translation.draftComplete ? 'complete' : 'incomplete'}',
              ),
            if (translation.displayRightsError != null)
              Text(
                'Display rights: ${translation.displayRightsError}',
                style: TextStyle(color: c.redFg),
              ),
            if (translation.offlineAllowed)
              const Text(
                'Offline storage is cleared for the published revision.',
              ),
            Wrap(
              spacing: 8,
              children: [
                if (translation.state != ContentState.archived &&
                    (translation.draftComplete ||
                        (translation.state == ContentState.withdrawn &&
                            translation.draftRevisionNo == null &&
                            translation.liveRevisionNo != null)))
                  FilledButton(
                    onPressed: busy ? null : onPublish,
                    child: const Text('Publish'),
                  ),
                if (translation.state == ContentState.published)
                  OutlinedButton(
                    onPressed: busy ? null : onWithdraw,
                    child: const Text('Withdraw'),
                  ),
                if (translation.state != ContentState.archived)
                  TextButton(
                    onPressed: busy ? null : onArchive,
                    child: const Text('Archive'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StaffEmpty extends StatelessWidget {
  const _StaffEmpty({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Text(message, textAlign: TextAlign.center),
  );
}
