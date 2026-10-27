import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/providers.dart';
import '../application/sermon_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/church_time.dart';
import '../domain/content_sermons.dart';
import 'calendar_screens.dart'
    show publicReadProblem, publicSavedStatus, staleNotice;
import 'church_widgets.dart';

// Story 6.9 (mobile): the public Sermons tab and one sermon's detail, read by
// everyone, signed in or not, from the published projection only. The screen
// answers "Which sermon shall I watch or read?": the current series leads,
// then the sermons by date, series or speaker. A failed read never looks like
// an empty catalog, and an unavailable video never hides the notes.

abstract final class SermonPaths {
  static const list = '/sermons';
  static String detail(String id) => '$list/$id';
  static const staff = '/content/sermons';
  static const staffSeries = '/content/sermon-series';
}

/// Presentation seam: platform plugins are composed by the mobile entry point.
typedef SermonPlayerBuilder = Widget Function(
  BuildContext context,
  String videoId,
);
final sermonPlayerBuilderProvider = Provider<SermonPlayerBuilder>(
  (ref) =>
      (context, id) => const SermonVideoUnavailable(),
);

/// The player's place when a recorded video cannot play: the notes stay
/// readable below it.
class SermonVideoUnavailable extends StatelessWidget {
  const SermonVideoUnavailable({super.key, this.offline = false});
  final bool offline;
  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ColoredBox(
          color: c.surface2,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                offline
                    ? 'Video needs a connection. You can read the notes below.'
                    : 'This video is unavailable. You can read the notes below.',
                key: const Key('sermon-video-unavailable'),
                textAlign: TextAlign.center,
                style: ChurchType.body.copyWith(color: c.ink),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "Sun 27 Sep", with the year when it is not this church year.
String sermonDateText(DateTime date, {DateTime? now}) {
  final year = ChurchTime.wall(now ?? DateTime.now()).year;
  final text =
      '${_weekdays[date.weekday - 1]} ${date.day} ${_months[date.month - 1]}';
  return date.year == year ? text : '$text ${date.year}';
}

String _count(int n) => n == 1 ? '1 sermon' : '$n sermons';

/// The series the church is preaching now: the series of the newest sermon
/// that belongs to a published series. Null when no sermon is in one.
PublicSermonSeries? currentSermonSeries(PublicSermons catalog) {
  for (final sermon in catalog.sermons) {
    final id = sermon.series?.seriesId;
    if (id == null) continue;
    final series = catalog.series.where((s) => s.seriesId == id).firstOrNull;
    if (series != null) return series;
  }
  return null;
}

enum _Browse { latest, series, speaker }

class SermonsScreen extends ConsumerStatefulWidget {
  const SermonsScreen({super.key});
  @override
  ConsumerState<SermonsScreen> createState() => _SermonsScreenState();
}

class _SermonsScreenState extends ConsumerState<SermonsScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  var _browse = _Browse.latest;
  var _searching = false;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _reload);
    // Revisiting the tab asks the server again.
    if (ref.read(publicSermonsProvider).result != null) {
      Future.microtask(_reload);
    }
  }

  void _reload() {
    if (mounted && !ref.read(publicSermonsProvider).loading) {
      ref.read(publicSermonsProvider.notifier).reload();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final s = ref.watch(publicSermonsProvider);
    final children = <Widget>[];
    switch (s.result) {
      case null:
        children.add(
          const RequestStateBanner(
            key: Key('sermons-loading'),
            tone: StatusTone.info,
            busy: true,
            title: 'Loading sermons…',
            message: 'Asking the church server.',
          ),
        );
      case AccessReadOk(:final value):
        if (publicSavedStatus(
              context,
              s,
              what: 'sermon list',
              key: 'sermons-offline',
            )
            case final saved?) {
          children.addAll([saved, const SizedBox(height: 4)]);
        }
        // Offline, the saved-time notice above already says it is old.
        final stale = s.offlineSnapshot
            ? null
            : staleNotice(s, what: 'sermon list', key: 'sermons-stale');
        if (stale != null) children.addAll([stale, const SizedBox(height: 16)]);
        if (value.sermons.isEmpty) {
          children.add(
            ChurchCard(
              child: Text(
                'No sermons yet. When the church adds a sermon, it will '
                'appear here.',
                key: const Key('sermons-empty'),
                style: ChurchType.body.copyWith(color: c.muted),
              ),
            ),
          );
        } else {
          children.addAll(_catalog(context, value, s.offlineSnapshot));
        }
      case final AccessRead<PublicSermons> problem:
        children.add(publicReadProblem(problem, what: 'sermon list'));
    }
    return MemberTabPage(
      title: 'Sermons',
      reloadKey: const Key('sermons-reload'),
      onReload: s.loading ? null : _reload,
      children: children,
    );
  }

  List<Widget> _catalog(
    BuildContext context,
    PublicSermons catalog,
    bool offline,
  ) {
    final c = ChurchColors.of(context);
    final current = currentSermonSeries(catalog);
    final rows = catalog.filter(query: _search.text);
    final searching = _searching || _search.text.isNotEmpty;
    return [
      if (current != null) ...[
        _SeriesHero(
          series: current,
          sermons: catalog.filter(seriesId: current.seriesId).length,
          offline: offline,
          onBrowse: () => setState(() {
            _browse = _Browse.series;
            _search.clear();
            _searching = false;
          }),
        ),
        const SizedBox(height: 18),
      ],
      Row(
        children: [
          Expanded(
            child: RadioSegments<_Browse>(
              label: 'Browse sermons',
              options: const [
                SegmentOption(_Browse.latest, 'Latest'),
                SegmentOption(_Browse.series, 'Series'),
                SegmentOption(_Browse.speaker, 'Speaker'),
              ],
              selected: _browse,
              onChanged: (value) => setState(() => _browse = value),
            ),
          ),
          if (!searching) ...[
            const SizedBox(width: 6),
            FocusRing(
              radius: 22,
              child: IconButton(
                key: const Key('sermons-search-open'),
                tooltip: 'Search sermons',
                onPressed: () {
                  setState(() => _searching = true);
                  _searchFocus.requestFocus();
                },
                icon: const Icon(Icons.search),
              ),
            ),
          ],
        ],
      ),
      if (searching) ...[
        const SizedBox(height: 12),
        TextField(
          key: const Key('sermons-search'),
          controller: _search,
          focusNode: _searchFocus,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            labelText: 'Search sermons',
            hintText: 'Title, series or speaker',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: IconButton(
              key: const Key('sermons-search-close'),
              tooltip: 'Close search',
              onPressed: () => setState(() {
                _search.clear();
                _searching = false;
              }),
              icon: const Icon(Icons.close),
            ),
          ),
          onChanged: (_) => setState(() {}),
        ),
      ],
      const SizedBox(height: 18),
      if (rows.isEmpty)
        Text(
          'No sermons match "${_search.text.trim()}".',
          key: const Key('sermons-no-results'),
          style: ChurchType.body.copyWith(color: c.muted),
        )
      else
        ..._groups(context, rows, offline),
      if (catalog.truncated) ...[
        const SizedBox(height: 12),
        Text(
          'Only the latest sermons are listed here.',
          key: const Key('sermons-truncated'),
          style: ChurchType.secondary.copyWith(color: c.muted),
        ),
      ],
    ];
  }

  /// The rows as one list (Latest) or grouped under their series or speaker,
  /// each group in the order of its latest sermon.
  List<Widget> _groups(
    BuildContext context,
    List<PublicSermon> rows,
    bool offline,
  ) {
    Widget card(List<PublicSermon> list) {
      // One media slot down a card, and none when no row has a poster or a
      // video: an empty tile repeated down the list says nothing.
      final media = list.any(
        (s) => s.series?.poster != null || s.youtubeVideoId != null,
      );
      return _SermonRowsCard(
        media: media,
        rows: [
          for (final sermon in list)
            _SermonRow(
              sermon: sermon,
              media: media,
              offline: offline,
              onTap: () => context.push(SermonPaths.detail(sermon.sermonId)),
            ),
        ],
      );
    }

    if (_browse == _Browse.latest) return [card(rows)];
    final groups = <String, List<PublicSermon>>{};
    final titles = <String, String>{};
    for (final sermon in rows) {
      final (key, title) = switch (_browse) {
        _Browse.series => switch (sermon.series) {
          final series? => ('series-${series.seriesId}', series.title),
          null => ('series-none', 'Not in a series'),
        },
        _ => ('speaker-${sermon.speaker}', sermon.speaker),
      };
      groups.putIfAbsent(key, () => []).add(sermon);
      titles[key] = title;
    }
    final keys = _browse == _Browse.series
        // Series by their latest sermon; sermons outside a series come last.
        ? [
            ...groups.keys.where((k) => k != 'series-none'),
            if (groups.containsKey('series-none')) 'series-none',
          ]
        : (groups.keys.toList()..sort(
            (a, b) =>
                titles[a]!.toLowerCase().compareTo(titles[b]!.toLowerCase()),
          ));
    final c = ChurchColors.of(context);
    return [
      for (final (i, key) in keys.indexed) ...[
        if (i > 0) const SizedBox(height: 22),
        SectionHeader(
          key: Key('sermons-group-$key'),
          title: titles[key]!,
          action: Text(
            _count(groups[key]!.length),
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
        ),
        const SizedBox(height: 10),
        card(groups[key]!),
      ],
    ];
  }
}

/// The current series on navy: its poster when one is public, then its
/// title and how many sermons it holds; the text opens the Series view.
class _SeriesHero extends StatelessWidget {
  const _SeriesHero({
    required this.series,
    required this.sermons,
    required this.offline,
    required this.onBrowse,
  });
  final PublicSermonSeries series;
  final int sermons;
  final bool offline;
  final VoidCallback onBrowse;
  @override
  Widget build(BuildContext context) {
    final poster = series.poster;
    final showPoster =
        poster != null && (poster.offlineBytes != null || !offline);
    final quiet = Colors.white.withValues(alpha: 0.82);
    final line = [
      _count(sermons),
      if (series.description.isNotEmpty) series.description,
    ].join(' · ');
    return KeyedSubtree(
      key: Key('sermons-current-series-${series.seriesId}'),
      child: HeroCard(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showPoster)
              AspectRatio(
                aspectRatio: 16 / 9,
                child: _SeriesImage(series: series, offline: offline),
              ),
            Semantics(
              button: true,
              label: 'Current series, ${series.title}, $line. Browse it.',
              excludeSemantics: true,
              child: FocusRing(
                color: Colors.white,
                radius: 12,
                child: InkWell(
                  key: const Key('sermons-browse-series'),
                  onTap: onBrowse,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Current series',
                                style: ChurchType.secondary.copyWith(
                                  color: quiet,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                series.title,
                                style: ChurchType.sectionTitle.copyWith(
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                line,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: ChurchType.secondary.copyWith(
                                  color: quiet,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.chevron_right, color: Colors.white),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A series poster: the saved bytes offline, the public file online, and a
/// plain tile when neither is available.
class _SeriesImage extends ConsumerWidget {
  const _SeriesImage({required this.series, required this.offline});
  final PublicSermonSeries? series;
  final bool offline;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final poster = series?.poster;
    final fallback = ColoredBox(color: c.surface2);
    if (poster == null) return fallback;
    final bytes = poster.offlineBytes;
    final Widget image;
    if (bytes != null) {
      image = Image.memory(
        bytes,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      );
    } else if (offline) {
      return fallback;
    } else {
      image = Image.network(
        ref
            .read(bannerRepositoryProvider)
            .publicFileUrl(poster.image.path)
            .toString(),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      );
    }
    return Semantics(label: series!.altText, image: true, child: image);
  }
}

/// Rows split by 1 px lines inside one card.
class _SermonRowsCard extends StatelessWidget {
  const _SermonRowsCard({required this.rows, required this.media});
  final List<Widget> rows;
  final bool media;
  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return ChurchCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, r) in rows.indexed) ...[
            if (i > 0)
              Divider(height: 1, indent: media ? 140 : 14, color: c.line),
            r,
          ],
        ],
      ),
    );
  }
}

/// One sermon: a 16:9 thumbnail (its series poster, with a play mark when it
/// has a video), the title, speaker and date · scripture.
class _SermonRow extends StatelessWidget {
  const _SermonRow({
    required this.sermon,
    required this.media,
    required this.offline,
    required this.onTap,
  });
  final PublicSermon sermon;
  final bool media;
  final bool offline;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final when = sermonDateText(sermon.sermonDate);
    return Semantics(
      button: true,
      label:
          '${sermon.title}, ${sermon.speaker}, $when, '
          '${sermon.scriptureReference}',
      excludeSemantics: true,
      child: FocusRing(
        radius: 4,
        child: InkWell(
          key: Key('sermon-row-${sermon.sermonId}'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (media) ...[
                  SizedBox(
                    width: 112,
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _SeriesImage(
                              series: sermon.series,
                              offline: offline,
                            ),
                            if (sermon.youtubeVideoId != null)
                              Center(
                                child: Icon(
                                  Icons.play_circle_filled,
                                  size: 30,
                                  color: c.ink.withValues(alpha: 0.78),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                ],
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
                        sermon.speaker,
                        style: ChurchType.secondary.copyWith(color: c.muted),
                      ),
                      Text(
                        '$when · ${sermon.scriptureReference}',
                        key: Key('sermon-when-${sermon.sermonId}'),
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

/// Story 6.9, mobile: one published sermon. The player stands apart from the
/// teaching, so an unavailable or offline video never hides the scripture
/// and notes. A withdrawn sermon says so instead of showing an old copy.
class SermonDetailScreen extends ConsumerWidget {
  const SermonDetailScreen({super.key, required this.sermonId});
  final String sermonId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final s = ref.watch(publicSermonProvider(sermonId));
    final ctl = ref.read(publicSermonProvider(sermonId).notifier);
    final offline = s.offlineSnapshot || s.refreshFailed != null;
    final children = <Widget>[];
    switch (s.result) {
      case null:
        children.add(
          const RequestStateBanner(
            key: Key('sermon-loading'),
            tone: StatusTone.info,
            busy: true,
            title: 'Loading the sermon…',
            message: 'Asking the church server.',
          ),
        );
      case AccessReadOk(value: PublicSermonRead(:final sermon)):
        if (staleNotice(s, what: 'sermon', key: 'sermon-stale') case final n?) {
          children.addAll([n, const SizedBox(height: 16)]);
        }
        if (sermon == null) {
          children.add(
            RequestStateBanner(
              key: const Key('sermon-gone'),
              tone: StatusTone.neutral,
              title: 'Sermon unavailable',
              message: 'This sermon is no longer available.',
              actions: [
                BannerAction(
                  'Open sermons',
                  () => context.go(SermonPaths.list),
                  key: const Key('sermon-gone-list'),
                  primary: true,
                ),
              ],
            ),
          );
        } else {
          final video = sermon.youtubeVideoId;
          children.addAll([
            if (video != null && !offline)
              ref.watch(sermonPlayerBuilderProvider)(context, video)
            else
              _NoVideo(offline: offline),
            const SizedBox(height: 20),
            if (sermon.series case final series?)
              Text(
                series.title,
                key: const Key('sermon-series'),
                style: ChurchType.secondary.copyWith(color: c.muted),
              ),
            Semantics(
              header: true,
              child: Text(
                sermon.title,
                key: const Key('sermon-title'),
                style: ChurchType.mobileScreenTitle.copyWith(color: c.ink),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${sermon.speaker} · ${sermonDateText(sermon.sermonDate)}',
              style: ChurchType.body.copyWith(color: c.muted),
            ),
            const SizedBox(height: 14),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Container(
                key: const Key('sermon-scripture'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: c.surface2,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  sermon.scriptureReference,
                  style: ChurchType.chip.copyWith(color: c.ink),
                ),
              ),
            ),
            const SizedBox(height: ChurchGeometry.sectionGap),
            const SectionHeader(title: 'Notes'),
            const SizedBox(height: 10),
            if (sermon.notes.isEmpty)
              Text(
                'No notes for this sermon yet.',
                style: ChurchType.body.copyWith(color: c.muted),
              )
            else
              SermonNotes(markdown: sermon.notes),
          ]);
        }
      case final AccessRead<PublicSermonRead> problem:
        children.add(publicReadProblem(problem, what: 'sermon'));
    }
    final reload = s.loading ? null : ctl.reload;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sermon'),
        leading: BackButton(
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go(SermonPaths.list);
            }
          },
        ),
        actions: [
          FocusRing(
            radius: 22,
            child: IconButton(
              key: const Key('sermon-reload'),
              tooltip: 'Reload',
              onPressed: reload,
              icon: const Icon(Icons.refresh),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async => reload?.call(),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
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
      ),
    );
  }
}

/// No playable video in this answer: offline (saved teaching never carries
/// a video), or none published for this sermon.
class _NoVideo extends StatelessWidget {
  const _NoVideo({required this.offline});
  final bool offline;
  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            offline ? Icons.cloud_off_outlined : Icons.videocam_off_outlined,
            size: 20,
            color: c.muted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              offline
                  ? 'Video needs a connection. You can read the notes below.'
                  : 'No video is available for this sermon. You can read '
                        'the notes below.',
              key: const Key('sermon-video-unavailable'),
              style: ChurchType.body.copyWith(color: c.ink),
            ),
          ),
        ],
      ),
    );
  }
}

/// A deliberately small renderer for the server-checked notes: paragraphs,
/// # headings, emphasis, lists and approved links. It never renders HTML,
/// images, automatic URLs or reference links.
class SermonNotes extends ConsumerWidget {
  const SermonNotes({super.key, required this.markdown});
  final String markdown;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    try {
      validateSermonNotes(markdown);
    } on FormatException {
      return Text(
        'These notes could not be shown.',
        style: ChurchType.body.copyWith(color: c.muted),
      );
    }
    final paragraphs = markdown.split(RegExp(r'\n\s*\n'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final paragraph in paragraphs) ...[
          for (final line in paragraph.split('\n'))
            if (line.trim().isNotEmpty) _line(context, ref, line),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _line(BuildContext context, WidgetRef ref, String line) {
    final c = ChurchColors.of(context);
    final heading = RegExp(r'^\s*(#{1,6})\s+(.+)$').firstMatch(line);
    final list = RegExp(r'^\s*((?:[-*+])|[0-9]+[.)])\s+(.+)$').firstMatch(line);
    final text = heading?[2] ?? list?[2] ?? line.trim();
    final style = heading == null
        ? ChurchType.body.copyWith(color: c.ink, height: 1.6)
        : ChurchType.sectionTitle.copyWith(
            color: c.ink,
            fontSize: heading[1]!.length < 3 ? 20 : 17,
          );
    final content = Text.rich(
      TextSpan(children: _inline(context, ref, text)),
      style: style,
    );
    final Widget body = heading != null
        ? Semantics(header: true, child: content)
        : list == null
        ? content
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 28,
                child: Text(
                  RegExp(r'^[0-9]').hasMatch(list[1]!) ? list[1]! : '•',
                  style: ChurchType.body.copyWith(color: c.ink, height: 1.6),
                ),
              ),
              Expanded(child: content),
            ],
          );
    return Padding(padding: const EdgeInsets.only(bottom: 4), child: body);
  }

  List<InlineSpan> _inline(BuildContext context, WidgetRef ref, String text) {
    final pattern = RegExp(
      r'\[([^\[\]\n]+)\]\(([^()\s]+)\)|\*\*(.+?)\*\*|(?<![A-Za-z0-9])__(.+?)__(?![A-Za-z0-9])|\*([^*\n]+)\*|(?<![A-Za-z0-9])_([^_\n]+)_(?![A-Za-z0-9])',
    );
    final spans = <InlineSpan>[];
    var offset = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > offset) {
        spans.add(TextSpan(text: text.substring(offset, match.start)));
      }
      if (match[1] != null) {
        final uri = safeSermonLink(match[2]!);
        spans.add(
          uri == null
              ? TextSpan(text: match[1])
              : WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: _NoteLink(label: match[1]!, uri: uri),
                ),
        );
      } else {
        final bold = match[3] ?? match[4];
        spans.add(
          TextSpan(
            text: bold ?? match[5] ?? match[6],
            style: TextStyle(
              fontWeight: bold == null ? null : FontWeight.w700,
              fontStyle: bold == null ? FontStyle.italic : null,
            ),
          ),
        );
      }
      offset = match.end;
    }
    if (offset < text.length) spans.add(TextSpan(text: text.substring(offset)));
    return spans;
  }
}

/// An approved link in the notes: opened outside the app, after the host
/// check, with a plain message when the phone cannot open it.
class _NoteLink extends ConsumerWidget {
  const _NoteLink({required this.label, required this.uri});
  final String label;
  final Uri uri;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    return Semantics(
      link: true,
      child: FocusRing(
        radius: 4,
        child: TextButton(
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: const Size(0, ChurchGeometry.minTarget),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: c.link,
          ),
          onPressed: () async {
            final ok = await ref.read(sermonLinkLauncherProvider).open(uri);
            if (!ok && context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('This link could not be opened.')),
              );
            }
          },
          child: Text(
            label,
            style: ChurchType.body.copyWith(
              color: c.link,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
      ),
    );
  }
}
