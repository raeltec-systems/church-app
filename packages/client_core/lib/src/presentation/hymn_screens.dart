import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/hymn_controllers.dart';
import '../domain/hymn_book.dart';
import 'bible_screens.dart';
import 'shell_routing.dart' show ClientPaths;

/// Story 6.7 (mobile, everyone): the Bible & Hymns tab. A segment track
/// (design handoff screen 5) switches between the Bible reader (story 6.6)
/// and the church's hymn book, which is built into the app and so works
/// offline and without signing in. [initialView] (`?view=hymns`) opens the
/// hymn book; otherwise the tab remembers the last choice while the app runs.
class BibleAndHymnsScreen extends ConsumerStatefulWidget {
  const BibleAndHymnsScreen({super.key, this.initialView});

  final BibleHymnsView? initialView;

  @override
  ConsumerState<BibleAndHymnsScreen> createState() =>
      _BibleAndHymnsScreenState();
}

class _BibleAndHymnsScreenState extends ConsumerState<BibleAndHymnsScreen> {
  late BibleHymnsView _view =
      widget.initialView ?? ref.read(bibleHymnsViewProvider);

  @override
  void initState() {
    super.initState();
    final initial = widget.initialView;
    if (initial != null) {
      // Remember a deep link's choice once this frame is built.
      Future.microtask(() {
        if (mounted) ref.read(bibleHymnsViewProvider.notifier).show(initial);
      });
    }
  }

  @override
  void didUpdateWidget(covariant BibleAndHymnsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The tab's page is reused when a link (`?view=hymns`) returns to it.
    final view = widget.initialView;
    if (view != null && view != oldWidget.initialView) {
      _view = view;
      Future.microtask(() {
        if (mounted) ref.read(bibleHymnsViewProvider.notifier).show(view);
      });
    }
  }

  void _choose(BibleHymnsView view) {
    setState(() => _view = view);
    ref.read(bibleHymnsViewProvider.notifier).show(view);
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return ColoredBox(
      color: c.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: RadioSegments<BibleHymnsView>(
              key: const Key('bible-hymns-segment'),
              label: 'Bible or hymn book',
              options: const [
                SegmentOption(BibleHymnsView.bible, 'Bible'),
                SegmentOption(BibleHymnsView.hymns, 'Hymn book'),
              ],
              selected: _view,
              onChanged: _choose,
            ),
          ),
          Expanded(
            child: switch (_view) {
              BibleHymnsView.bible => const BibleReaderScreen(),
              BibleHymnsView.hymns => const HymnBookView(),
            },
          ),
        ],
      ),
    );
  }
}

/// The hymn book: search by number, title or first line on the device; with
/// no search, the whole book in its printed order under its section headers
/// (the hymns, then the choruses). Opening a row pushes the item. A book
/// that cannot be read says so with Try again; it never looks empty.
class HymnBookView extends ConsumerStatefulWidget {
  const HymnBookView({super.key});

  @override
  ConsumerState<HymnBookView> createState() => _HymnBookViewState();
}

class _HymnBookViewState extends ConsumerState<HymnBookView> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _setQuery(String value) => setState(() => _query = value);

  void _clear() {
    _search.clear();
    _setQuery('');
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final book = ref.watch(hymnBookProvider);
    final List<Widget> body;
    if (book.hasValue) {
      body = _bookSlivers(context, book.requireValue);
    } else if (book.hasError && !book.isLoading) {
      body = [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          sliver: SliverToBoxAdapter(child: _HymnBookError(ref: ref)),
        ),
      ];
    } else {
      body = const [
        SliverPadding(
          padding: EdgeInsets.all(28),
          sliver: SliverToBoxAdapter(
            child: Center(
              child: CircularProgressIndicator(key: Key('hymn-book-loading')),
            ),
          ),
        ),
      ];
    }
    return ColoredBox(
      color: c.bg,
      child: CustomScrollView(
        key: const Key('hymn-book'),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            sliver: SliverToBoxAdapter(
              child: TextField(
                key: const Key('hymn-search'),
                controller: _search,
                enabled: book.hasValue,
                onChanged: _setQuery,
                textInputAction: TextInputAction.search,
                style: ChurchType.body.copyWith(color: c.ink),
                decoration: InputDecoration(
                  hintText: 'Number, title or first line',
                  prefixIcon: Icon(Icons.search, color: c.muted),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          key: const Key('hymn-search-clear'),
                          tooltip: 'Clear the search',
                          onPressed: _clear,
                          icon: const Icon(Icons.close),
                        ),
                ),
              ),
            ),
          ),
          ...body,
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  List<Widget> _bookSlivers(BuildContext context, HymnBook book) {
    final c = ChurchColors.of(context);
    if (hymnQueryTokens(_query).isEmpty) {
      // The printed order, with a header wherever the section changes.
      final groups = <List<Hymn>>[];
      for (final item in book.items) {
        if (groups.isEmpty || groups.last.first.section != item.section) {
          groups.add([item]);
        } else {
          groups.last.add(item);
        }
      }
      return [
        for (final (index, group) in groups.indexed) ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            sliver: SliverToBoxAdapter(
              child: Semantics(
                header: true,
                child: Text(
                  group.first.section,
                  key: Key('hymn-section-$index'),
                  style: ChurchType.label.copyWith(color: c.muted),
                ),
              ),
            ),
          ),
          _HymnRows(items: group, showKind: false),
        ],
      ];
    }
    final results = book.search(_query);
    if (results.isEmpty) {
      return [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          sliver: SliverToBoxAdapter(
            child: DecoratedBox(
              key: const Key('hymn-search-empty-frame'),
              decoration: BoxDecoration(
                color: c.surface,
                border: Border.all(color: c.line),
                borderRadius: BorderRadius.circular(
                  ChurchGeometry.mobileCardRadius,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'No hymns match "${_query.trim()}".',
                  key: const Key('hymn-search-empty'),
                  textAlign: TextAlign.center,
                  style: ChurchType.body.copyWith(color: c.muted),
                ),
              ),
            ),
          ),
        ),
      ];
    }
    return [
      const SliverToBoxAdapter(child: SizedBox(height: 12)),
      _HymnRows(key: const Key('hymn-results'), items: results, showKind: true),
    ];
  }
}

/// One card of rows split by 1 px rules, built lazily.
class _HymnRows extends StatelessWidget {
  const _HymnRows({super.key, required this.items, required this.showKind});

  final List<Hymn> items;
  final bool showKind;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: DecoratedSliver(
        decoration: BoxDecoration(
          color: c.surface,
          border: Border.all(color: c.line),
          borderRadius: BorderRadius.circular(ChurchGeometry.mobileCardRadius),
        ),
        sliver: SliverList.builder(
          itemCount: items.length,
          itemBuilder: (context, index) => HymnRow(
            hymn: items[index],
            first: index == 0,
            last: index == items.length - 1,
            showKind: showKind,
          ),
        ),
      ),
    );
  }
}

/// One row of the hymn list: the number large in the brand colour, the title
/// and the first line under it, split from the next row by a 1 px rule. In
/// search results a chorus says so before its first line.
class HymnRow extends StatelessWidget {
  const HymnRow({
    super.key,
    required this.hymn,
    this.first = false,
    this.last = false,
    this.showKind = false,
  });

  final Hymn hymn;
  final bool first;
  final bool last;
  final bool showKind;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    const radius = Radius.circular(ChurchGeometry.mobileCardRadius);
    final chorus = hymn.kind == HymnKind.chorus;
    final subline = showKind && chorus
        ? 'Chorus · ${hymn.firstLine}'
        : hymn.firstLine;
    void open() => context.push(ClientPaths.hymn(hymn.id));
    return Semantics(
      button: true,
      label:
          '${chorus ? 'Chorus' : 'Hymn'} ${hymn.number}, ${hymn.title}. '
          '${hymn.firstLine}',
      excludeSemantics: true,
      onTap: open,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: Key('hymn-row-${hymn.id}'),
          borderRadius: BorderRadius.vertical(
            top: first ? radius : Radius.zero,
            bottom: last ? radius : Radius.zero,
          ),
          onTap: open,
          child: Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: first
                ? null
                : BoxDecoration(
                    border: Border(top: BorderSide(color: c.line)),
                  ),
            child: Row(
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 40),
                  child: Text(
                    '${hymn.number}',
                    textAlign: TextAlign.center,
                    softWrap: false,
                    style: ChurchType.dateNumber.copyWith(color: c.brand),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        hymn.title,
                        style: ChurchType.itemTitle.copyWith(color: c.ink),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ChurchType.secondary.copyWith(color: c.muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HymnBookError extends StatelessWidget {
  const _HymnBookError({required this.ref});

  final WidgetRef ref;

  @override
  Widget build(BuildContext context) => RequestStateBanner(
    key: const Key('hymn-book-error'),
    tone: StatusTone.warning,
    icon: Icons.error_outline,
    title: 'The hymn book could not be opened',
    message: 'Try again. If it keeps happening, update the app.',
    actions: [
      BannerAction(
        'Try again',
        () => ref.invalidate(hymnBookProvider),
        key: const Key('hymn-book-retry'),
        primary: true,
      ),
    ],
  );
}

/// Hymn text: 19/1.55 (design contract, Reading).
TextStyle hymnTextStyle(ChurchColors c) =>
    ChurchType.body.copyWith(color: c.ink, fontSize: 19, height: 1.55);

/// Story 6.7 (mobile, everyone): one hymn or chorus by its id (`hymn-12`,
/// `chorus-3`), pushed over the tabs with its back bar ("Hymn 12"): the
/// Tonga title, the English title and the key in muted lines, the verses in
/// 19/1.55 text (numbered when there is more than one) and the italic chorus
/// after each verse. [id] is null when the link is not an item id.
class HymnDetailScreen extends ConsumerWidget {
  const HymnDetailScreen({super.key, required this.id});

  final String? id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final book = ref.watch(hymnBookProvider);
    final id = this.id;
    final hymn = id == null ? null : book.value?.byId(id);
    final Widget body;
    if (book.hasValue) {
      body = hymn == null
          ? RequestStateBanner(
              key: const Key('hymn-missing'),
              tone: StatusTone.neutral,
              title: 'Not in the hymn book',
              message: 'This hymn is not in the hymn book.',
              actions: [
                BannerAction(
                  'Open the hymn book',
                  () => context.go(ClientPaths.hymnBook),
                  key: const Key('hymn-missing-book'),
                  primary: true,
                ),
              ],
            )
          : _HymnText(hymn: hymn);
    } else if (book.hasError && !book.isLoading) {
      body = _HymnBookError(ref: ref);
    } else {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: CircularProgressIndicator(key: Key('hymn-book-loading')),
        ),
      );
    }
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        title: Text(_barTitle(id, hymn), key: const Key('hymn-bar-title')),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: layout.contentMaxWidth),
              child: body,
            ),
          ),
        ),
      ),
    );
  }

  static String _barTitle(String? id, Hymn? hymn) {
    if (hymn != null) {
      return '${hymn.kind == HymnKind.chorus ? 'Chorus' : 'Hymn'} '
          '${hymn.number}';
    }
    final match = RegExp(r'^(hymn|chorus)-(\d+)$').firstMatch(id ?? '');
    if (match == null) return 'Hymn';
    return '${match.group(1) == 'chorus' ? 'Chorus' : 'Hymn'} '
        '${match.group(2)}';
  }
}

class _HymnText extends StatelessWidget {
  const _HymnText({required this.hymn});

  final Hymn hymn;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final text = hymnTextStyle(c);
    final numbered = hymn.verses.length > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            hymn.title,
            key: const Key('hymn-title'),
            style: ChurchType.mobileScreenTitle.copyWith(color: c.brand),
          ),
        ),
        if (hymn.original case final original?) ...[
          const SizedBox(height: 4),
          Text(
            original,
            key: const Key('hymn-original'),
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
        ],
        if (hymn.key case final key?) ...[
          const SizedBox(height: 2),
          Text(
            'Key of $key',
            key: const Key('hymn-key'),
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
        ],
        for (final (index, verse) in hymn.verses.indexed) ...[
          const SizedBox(height: 20),
          Row(
            key: Key('hymn-verse-${index + 1}'),
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              if (numbered) ...[
                SizedBox(
                  width: 22,
                  child: Semantics(
                    label: 'Verse ${index + 1}',
                    excludeSemantics: true,
                    child: Text(
                      '${index + 1}',
                      style: ChurchType.body.copyWith(
                        color: c.accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(child: Text(verse, style: text)),
            ],
          ),
          if (hymn.chorusAfterVerse(index + 1) case final chorus?)
            Padding(
              padding: EdgeInsets.only(left: numbered ? 48 : 14, top: 14),
              child: Column(
                key: Key('hymn-chorus-${index + 1}'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Chorus',
                    style: ChurchType.chip.copyWith(color: c.muted),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    chorus,
                    style: text.copyWith(fontStyle: FontStyle.italic),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}
