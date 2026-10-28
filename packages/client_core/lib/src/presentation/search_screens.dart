import 'dart:async';

import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/hymn_controllers.dart' show hymnBookProvider;
import '../application/search_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/content_search.dart';
import '../domain/content_sermons.dart';
import '../domain/hymn_book.dart';
import 'announcement_screens.dart' show AnnouncementPaths, AnnouncementRow;
import 'calendar_screens.dart' show CalendarPaths, PublicEventRow;
import 'hymn_screens.dart' show HymnRow;
import 'sermon_screens.dart' show SermonPaths, sermonDateText;

// Epic 6 entry 14 (mobile, everyone): the top bar's search. It answers "where
// is the hymn, sermon, event or announcement I'm thinking of?". Hymns come
// from the hymn book on the phone as the user types, online or not; the
// published sermons, events and announcements come from one bounded server
// read a moment after typing stops. A failed server read says so beside the
// hymns and is never shown as "nothing found". Bible text is not searched.

abstract final class SearchPaths {
  static const search = '/search';
}

/// How long typing must pause before the server is asked.
const searchDebounce = Duration(milliseconds: 350);

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _text = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    super.dispose();
  }

  void _changed(String value) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(searchDebounce, () {
      if (mounted) ref.read(contentSearchProvider.notifier).search(value);
    });
  }

  void _submit(String value) {
    _debounce?.cancel();
    ref.read(contentSearchProvider.notifier).search(value);
  }

  void _clear() {
    _debounce?.cancel();
    _text.clear();
    setState(() {});
    ref.read(contentSearchProvider.notifier).search('');
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final typed = _text.text.trim();
    final asked = ref.watch(contentSearchProvider);
    // A server answer belongs to the query it was asked for. While the
    // debounce has not yet asked for what is typed now, the search is shown
    // as pending: an older answer (or its "nothing found") is never shown
    // under the new words.
    final s = asked.query == searchQueryOf(typed)
        ? asked
        : const ContentSearchState(loading: true);
    final book = ref.watch(hymnBookProvider);
    final children = <Widget>[];
    if (typed.isEmpty) {
      children.add(
        Text(
          'Find a hymn by its number, title or first line, or a sermon, '
          'event or announcement by its words. Hymns are found on this '
          'phone, even offline.',
          key: const Key('search-intro'),
          style: ChurchType.body.copyWith(color: c.muted),
        ),
      );
    } else {
      // Hymns: on the device, as the user types.
      final List<Hymn>? hymns = switch (book) {
        AsyncData(:final value) => value.search(typed),
        _ => null,
      };
      final serverDone = s.result is AccessReadOk<PublicSearchResults>;
      final server = switch (s.result) {
        AccessReadOk(:final value) => value,
        _ => null,
      };
      final nothing =
          hymns != null &&
          hymns.isEmpty &&
          serverDone &&
          (server?.isEmpty ?? false) &&
          !s.loading;
      if (nothing) {
        children.add(
          _Frame(
            key: const Key('search-nothing'),
            child: Text(
              'Nothing matches "$typed". Try fewer words or a hymn number.',
              style: ChurchType.body.copyWith(color: c.muted),
            ),
          ),
        );
      } else {
        children.addAll(_hymnSection(context, book, hymns, typed));
        children.addAll(_serverSections(context, s, typed));
      }
    }
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          key: const Key('search-field'),
          controller: _text,
          autofocus: true,
          textInputAction: TextInputAction.search,
          maxLength: ContentSearchLimits.maxLength,
          onChanged: _changed,
          onSubmitted: _submit,
          style: ChurchType.body.copyWith(color: c.ink),
          decoration: InputDecoration(
            hintText: 'Search hymns, sermons, events',
            counterText: '',
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
            suffixIcon: typed.isEmpty && _text.text.isEmpty
                ? null
                : FocusRing(
                    radius: 22,
                    child: IconButton(
                      key: const Key('search-clear'),
                      tooltip: 'Clear',
                      onPressed: _clear,
                      icon: const Icon(Icons.close),
                    ),
                  ),
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: layout.contentMaxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _hymnSection(
    BuildContext context,
    AsyncValue<HymnBook> book,
    List<Hymn>? hymns,
    String typed,
  ) {
    final c = ChurchColors.of(context);
    final Widget body;
    if (book is AsyncError) {
      body = _Frame(
        key: const Key('search-hymns-failed'),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'The hymn book could not be opened.',
                style: ChurchType.body.copyWith(color: c.ink),
              ),
            ),
            FocusRing(
              child: TextButton(
                key: const Key('search-hymns-retry'),
                onPressed: () => ref.invalidate(hymnBookProvider),
                child: const Text('Try again'),
              ),
            ),
          ],
        ),
      );
    } else if (hymns == null) {
      body = Text(
        'Opening the hymn book…',
        key: const Key('search-hymns-loading'),
        style: ChurchType.secondary.copyWith(color: c.muted),
      );
    } else if (hymns.isEmpty) {
      body = _Frame(
        key: const Key('search-hymns-none'),
        child: Text(
          'No hymns match "$typed".',
          style: ChurchType.body.copyWith(color: c.muted),
        ),
      );
    } else {
      final shown = hymns.take(ContentSearchLimits.hymnsShown).toList();
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DecoratedBox(
            key: const Key('search-hymns'),
            decoration: BoxDecoration(
              color: c.surface,
              border: Border.all(color: c.line),
              borderRadius: BorderRadius.circular(
                ChurchGeometry.mobileCardRadius,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, h) in shown.indexed)
                  HymnRow(
                    hymn: h,
                    first: i == 0,
                    last: i == shown.length - 1,
                    showKind: true,
                  ),
              ],
            ),
          ),
          if (hymns.length > shown.length) ...[
            const SizedBox(height: 8),
            Text(
              '${hymns.length - shown.length} more '
              '${hymns.length - shown.length == 1 ? 'hymn matches' : 'hymns match'}. '
              'Add a word to narrow the search.',
              key: const Key('search-hymns-more'),
              style: ChurchType.secondary.copyWith(color: c.muted),
            ),
          ],
        ],
      );
    }
    return [
      const SectionHeader(key: Key('search-hymns-header'), title: 'Hymns'),
      const SizedBox(height: 8),
      body,
      const SizedBox(height: ChurchGeometry.sectionGap),
    ];
  }

  List<Widget> _serverSections(
    BuildContext context,
    ContentSearchState s,
    String typed,
  ) {
    final c = ChurchColors.of(context);
    final notifier = ref.read(contentSearchProvider.notifier);
    if (searchQueryOf(typed) == null) {
      return [
        Text(
          'Type at least ${ContentSearchLimits.minLength} letters to search '
          'sermons, events and announcements.',
          key: const Key('search-too-short'),
          style: ChurchType.secondary.copyWith(color: c.muted),
        ),
      ];
    }
    switch (s.result) {
      case null:
        return [
          Row(
            key: const Key('search-server-loading'),
            children: [
              const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Searching sermons, events and announcements…',
                  style: ChurchType.secondary.copyWith(color: c.muted),
                ),
              ),
            ],
          ),
        ];
      case AccessReadFailed(:final unreachable):
        return [
          RequestStateBanner(
            key: const Key('search-server-failed'),
            tone: StatusTone.danger,
            icon: unreachable ? Icons.cloud_off_outlined : Icons.error_outline,
            title: unreachable ? 'No connection' : 'Couldn\'t search',
            message: unreachable
                ? 'Sermons, events and announcements could not be searched: '
                      'we couldn\'t reach the church server. This does not '
                      'mean there are none. Hymns above are from the hymn '
                      'book on this phone.'
                : 'Sermons, events and announcements could not be searched. '
                      'Try again later.',
            actions: [
              BannerAction(
                'Try again',
                notifier.retry,
                key: const Key('search-retry'),
              ),
            ],
          ),
        ];
      case AccessReadDenied():
        return [
          RequestStateBanner(
            key: const Key('search-server-unavailable'),
            tone: StatusTone.warning,
            icon: Icons.lock_outline,
            title: 'Not available yet',
            message:
                'Searching sermons, events and announcements is not '
                'available from this app right now.',
          ),
        ];
      case AccessReadOk(:final value):
        final out = <Widget>[];
        void section(String title, String key, List<Widget> rows) {
          if (rows.isEmpty) return;
          out.addAll([
            SectionHeader(key: Key('$key-header'), title: title),
            const SizedBox(height: 8),
            _RowsCard(key: Key(key), rows: rows),
            const SizedBox(height: ChurchGeometry.sectionGap),
          ]);
        }

        section('Sermons', 'search-sermons', [
          for (final sermon in value.sermons) _SermonResultRow(sermon: sermon),
        ]);
        section('Events', 'search-events', [
          for (final e in value.events)
            PublicEventRow(
              event: e,
              onTap: () => context.push(CalendarPaths.event(e.eventId)),
            ),
        ]);
        section('Announcements', 'search-announcements', [
          for (final a in value.announcements)
            AnnouncementRow(
              announcement: a,
              onTap: () =>
                  context.push(AnnouncementPaths.detail(a.announcementId)),
            ),
        ]);
        if (value.isEmpty) {
          out.add(
            Text(
              'No sermons, events or announcements match "$typed".',
              key: const Key('search-server-none'),
              style: ChurchType.secondary.copyWith(color: c.muted),
            ),
          );
        }
        if (value.truncated) {
          out.add(
            Text(
              'Showing the first ${ContentSearchLimits.perKind} of each. Add '
              'a word to narrow the search.',
              key: const Key('search-truncated'),
              style: ChurchType.secondary.copyWith(color: c.muted),
            ),
          );
        }
        if (s.loading) {
          out.insert(0, const LinearProgressIndicator(minHeight: 2));
        }
        return out;
    }
  }
}

/// A bordered frame holding one sentence (an empty section keeps its frame).
class _Frame extends StatelessWidget {
  const _Frame({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(ChurchGeometry.mobileCardRadius),
      ),
      child: child,
    );
  }
}

/// Result rows split by 1 px lines inside one card.
class _RowsCard extends StatelessWidget {
  const _RowsCard({super.key, required this.rows});
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return ChurchCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, r) in rows.indexed) ...[
            if (i > 0) Divider(height: 1, color: c.line),
            r,
          ],
        ],
      ),
    );
  }
}

/// One sermon found: its title, the speaker, then date · scripture.
class _SermonResultRow extends StatelessWidget {
  const _SermonResultRow({required this.sermon});
  final PublicSermon sermon;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final when = sermonDateText(sermon.sermonDate);
    final series = sermon.series?.title;
    return Semantics(
      button: true,
      label:
          '${sermon.title}, ${sermon.speaker}, $when, '
          '${sermon.scriptureReference}${series == null ? '' : ', $series'}',
      excludeSemantics: true,
      child: FocusRing(
        radius: 4,
        child: InkWell(
          key: Key('search-sermon-${sermon.sermonId}'),
          onTap: () => context.push(SermonPaths.detail(sermon.sermonId)),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        sermon.title,
                        style: ChurchType.itemTitle.copyWith(color: c.ink),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        series == null
                            ? sermon.speaker
                            : '${sermon.speaker} · $series',
                        style: ChurchType.secondary.copyWith(color: c.muted),
                      ),
                      Text(
                        '$when · ${sermon.scriptureReference}',
                        style: ChurchType.secondary.copyWith(color: c.muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                ExcludeSemantics(
                  child: Icon(Icons.chevron_right, size: 20, color: c.muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
