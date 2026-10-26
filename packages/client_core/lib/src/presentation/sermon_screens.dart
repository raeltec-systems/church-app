import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/providers.dart';
import '../application/sermon_controllers.dart';
import '../domain/content_sermons.dart';
import 'calendar_screens.dart'
    show publicReadProblem, publicSavedStatus, staleNotice;
import 'church_widgets.dart';

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

class SermonVideoUnavailable extends StatelessWidget {
  const SermonVideoUnavailable({super.key, this.offline = false});
  final bool offline;
  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 16 / 9,
    child: ColoredBox(
      color: ChurchColors.of(context).surface2,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            offline
                ? 'Video needs a connection. You can read the notes below.'
                : 'This video is unavailable. You can read the notes below.',
            key: const Key('sermon-video-unavailable'),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    ),
  );
}

class SermonsScreen extends ConsumerStatefulWidget {
  const SermonsScreen({super.key});
  @override
  ConsumerState<SermonsScreen> createState() => _SermonsScreenState();
}

class _SermonsScreenState extends ConsumerState<SermonsScreen> {
  final _search = TextEditingController();
  String _mode = 'Latest';
  String? _seriesId, _speaker;
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onResume: _reload,
  );
  @override
  void initState() {
    super.initState();
    _lifecycle;
    if (ref.read(publicSermonsProvider).result != null) {
      Future.microtask(_reload);
    }
  }

  void _reload() {
    if (mounted) ref.read(publicSermonsProvider.notifier).reload();
  }

  @override
  void dispose() {
    _search.dispose();
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(publicSermonsProvider);
    final catalog = state.value;
    final series = catalog?.series ?? [];
    final speakers =
        (catalog?.sermons.map((s) => s.speaker).toSet().toList() ?? [])..sort();
    final rows =
        catalog?.filter(
          query: _search.text,
          seriesId:
              _mode == 'Series' && series.any((s) => s.seriesId == _seriesId)
              ? _seriesId
              : null,
          speaker: _mode == 'Speaker' && speakers.contains(_speaker)
              ? _speaker
              : null,
        ) ??
        [];
    final c = ChurchColors.of(context);
    return MemberTabPage(
      title: 'Sermons',
      reloadKey: const Key('sermons-reload'),
      onReload: state.loading ? null : _reload,
      children: [
        ?publicSavedStatus(
          context,
          state,
          what: 'sermons',
          key: 'sermons-offline',
        ),
        if (!state.offlineSnapshot)
          ?staleNotice(state, what: 'sermons', key: 'sermons-stale'),
        if (catalog != null && series.isNotEmpty) ...[
          _SeriesHero(
            series: series.first,
            offline: state.offlineSnapshot,
            onTap: () => setState(() {
              _mode = 'Series';
              _seriesId = series.first.seriesId;
            }),
          ),
          const SizedBox(height: 18),
        ],
        TextField(
          key: const Key('sermons-search'),
          controller: _search,
          decoration: const InputDecoration(
            labelText: 'Search sermons',
            hintText: 'Title, series or speaker',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          children: [
            for (final mode in const ['Latest', 'Series', 'Speaker'])
              ChoiceChip(
                key: Key('sermons-filter-${mode.toLowerCase()}'),
                label: Text(mode),
                selected: _mode == mode,
                onSelected: (_) => setState(() => _mode = mode),
              ),
          ],
        ),
        if (_mode == 'Series')
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: DropdownButtonFormField<String>(
              key: ValueKey(
                'sermons-series-${series.map((s) => s.seriesId).join()}',
              ),
              isExpanded: true,
              initialValue: series.any((s) => s.seriesId == _seriesId)
                  ? _seriesId
                  : null,
              decoration: const InputDecoration(labelText: 'Series'),
              items: [
                const DropdownMenuItem(value: null, child: Text('All series')),
                for (final s in series)
                  DropdownMenuItem(value: s.seriesId, child: Text(s.title)),
              ],
              onChanged: (value) => setState(() => _seriesId = value),
            ),
          ),
        if (_mode == 'Speaker')
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: DropdownButtonFormField<String>(
              key: ValueKey('sermons-speaker-${speakers.join()}'),
              isExpanded: true,
              initialValue: speakers.contains(_speaker) ? _speaker : null,
              decoration: const InputDecoration(labelText: 'Speaker'),
              items: [
                const DropdownMenuItem(
                  value: null,
                  child: Text('All speakers'),
                ),
                for (final speaker in speakers)
                  DropdownMenuItem(value: speaker, child: Text(speaker)),
              ],
              onChanged: (value) => setState(() => _speaker = value),
            ),
          ),
        const SizedBox(height: 18),
        if (state.result == null)
          const Center(child: CircularProgressIndicator())
        else if (catalog == null)
          publicReadProblem(state.result!, what: 'sermons')
        else if (catalog.sermons.isEmpty)
          const ChurchCard(
            child: Text(
              'No sermons yet. When the church adds a sermon, it will appear here.',
              key: Key('sermons-empty'),
            ),
          )
        else if (rows.isEmpty)
          const Padding(
            padding: EdgeInsets.all(18),
            child: Text(
              'No sermons match this search.',
              key: Key('sermons-no-results'),
            ),
          )
        else
          ChurchCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final (i, sermon) in rows.indexed) ...[
                  if (i > 0) Divider(height: 1, color: c.line),
                  InkWell(
                    key: Key('sermon-row-${sermon.sermonId}'),
                    onTap: () =>
                        context.push(SermonPaths.detail(sermon.sermonId)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 16,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 104,
                            child: AspectRatio(
                              aspectRatio: 16 / 9,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  _Poster(
                                    series: sermon.series,
                                    offline: state.offlineSnapshot,
                                  ),
                                  const Center(
                                    child: Icon(
                                      Icons.play_circle_outline,
                                      color: Colors.white,
                                      size: 30,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  sermon.title,
                                  style: ChurchType.cardTitle.copyWith(
                                    color: c.ink,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  sermon.speaker,
                                  style: ChurchType.secondary.copyWith(
                                    color: c.muted,
                                  ),
                                ),
                                Text(
                                  '${_date(sermon.sermonDate)} · ${sermon.scriptureReference}',
                                  style: ChurchType.secondary.copyWith(
                                    color: c.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        if (catalog?.truncated == true)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('Showing the latest sermons in the church catalog.'),
          ),
      ],
    );
  }
}

class _SeriesHero extends StatelessWidget {
  const _SeriesHero({
    required this.series,
    required this.offline,
    required this.onTap,
  });
  final PublicSermonSeries series;
  final bool offline;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ChurchCard(
    padding: EdgeInsets.zero,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (series.poster != null)
          InkWell(
            onTap: () => showDialog<void>(
              context: context,
              builder: (_) => Dialog(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AspectRatio(
                      aspectRatio: 16 / 9,
                      child: _Poster(series: series, offline: offline),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
            ),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: _Poster(series: series, offline: offline),
            ),
          ),
        ColoredBox(
          color: const Color(0xFF14246B),
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Current series',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    series.title,
                    style: ChurchType.sectionTitle.copyWith(
                      color: Colors.white,
                    ),
                  ),
                  if (series.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        series.description,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _Poster extends ConsumerWidget {
  const _Poster({required this.series, required this.offline});
  final PublicSermonSeries? series;
  final bool offline;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final poster = series?.poster;
    final fallback = ColoredBox(
      color: ChurchColors.of(context).hero,
      child: const Center(
        child: Icon(Icons.mic_none, color: Colors.white70, size: 30),
      ),
    );
    if (poster == null) return fallback;
    final bytes = poster.offlineBytes;
    return Semantics(
      label: series!.altText,
      image: true,
      child: bytes != null
          ? Image.memory(
              bytes,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback,
            )
          : offline
          ? fallback
          : Image.network(
              ref
                  .read(bannerRepositoryProvider)
                  .publicFileUrl(poster.image.path)
                  .toString(),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}

class SermonDetailScreen extends ConsumerWidget {
  const SermonDetailScreen({super.key, required this.sermonId});
  final String sermonId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(publicSermonProvider(sermonId));
    final sermon = state.value?.sermon;
    final c = ChurchColors.of(context);
    final offline = state.offlineSnapshot || state.refreshFailed != null;
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
          IconButton(
            key: const Key('sermon-reload'),
            tooltip: 'Reload',
            onPressed: state.loading
                ? null
                : ref.read(publicSermonProvider(sermonId).notifier).reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: ChurchLayout.of(context).contentMaxWidth,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ?staleNotice(state, what: 'sermon', key: 'sermon-stale'),
                  if (state.result == null)
                    const Center(child: CircularProgressIndicator())
                  else if (state.value == null)
                    publicReadProblem(state.result!, what: 'sermon')
                  else if (sermon == null)
                    const RequestStateBanner(
                      key: Key('sermon-gone'),
                      tone: StatusTone.neutral,
                      title: 'Sermon unavailable',
                      message: 'This sermon is no longer available.',
                    )
                  else ...[
                    const SizedBox(height: 8),
                    if (sermon.youtubeVideoId != null && !offline)
                      ref.watch(sermonPlayerBuilderProvider)(
                        context,
                        sermon.youtubeVideoId!,
                      )
                    else
                      SermonVideoUnavailable(offline: offline),
                    const SizedBox(height: 20),
                    if (sermon.series != null)
                      Text(
                        sermon.series!.title,
                        style: ChurchType.secondary.copyWith(color: c.muted),
                      ),
                    Text(
                      sermon.title,
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(color: c.brand),
                    ),
                    const SizedBox(height: 8),
                    Text('${sermon.speaker} · ${_date(sermon.sermonDate)}'),
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Chip(label: Text(sermon.scriptureReference)),
                    ),
                    const SizedBox(height: 20),
                    const SectionHeader(title: 'Notes'),
                    const SizedBox(height: 12),
                    if (sermon.notes.isEmpty)
                      const Text('No notes for this sermon yet.')
                    else
                      SermonNotes(markdown: sermon.notes),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _date(DateTime date) {
  const months = [
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
  return '${date.day} ${months[date.month - 1]} ${date.year}';
}

/// A deliberately small renderer: no HTML, image, automatic URL or reference handlers.
class SermonNotes extends ConsumerWidget {
  const SermonNotes({super.key, required this.markdown});
  final String markdown;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    try {
      validateSermonNotes(markdown);
    } catch (_) {
      return const Text('These notes could not be displayed safely.');
    }
    final c = ChurchColors.of(context);
    final paragraphs = markdown.split(RegExp(r'\n\s*\n'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final paragraph in paragraphs) ...[
          for (final line in paragraph.split('\n'))
            Builder(
              builder: (context) {
                final heading = RegExp(r'^(#{1,6})\s+(.+)$').firstMatch(line);
                final list = RegExp(r'^\s*((?:[-*+]|[0-9]+[.)]))\s+(.+)$')
                    .firstMatch(line);
                final text = heading?[2] ?? list?[2] ?? line;
                final content = Text.rich(
                  TextSpan(children: _inline(context, ref, text)),
                  style: heading == null
                      ? ChurchType.body.copyWith(color: c.ink, height: 1.6)
                      : ChurchType.sectionTitle.copyWith(
                          color: c.ink,
                          fontSize: heading[1]!.length < 3 ? 22 : 18,
                        ),
                );
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: list == null
                      ? content
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 28,
                              child: Text(
                                RegExp(r'^[0-9]').hasMatch(list[1]!)
                                    ? list[1]!
                                    : '•',
                                style: ChurchType.body.copyWith(height: 1.6),
                              ),
                            ),
                            Expanded(child: content),
                          ],
                        ),
                );
              },
            ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  List<InlineSpan> _inline(BuildContext context, WidgetRef ref, String text) {
    final pattern = RegExp(
      r'\[([^\[\]\n]+)\]\(([^()\s]+)\)|\*\*(.+?)\*\*|__(.+?)__|\*([^*]+)\*|_([^_]+)_',
    );
    final spans = <InlineSpan>[];
    var offset = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > offset) {
        spans.add(TextSpan(text: text.substring(offset, match.start)));
      }
      if (match[1] != null) {
        final uri = safeSermonLink(match[2]!);
        if (uri != null) {
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Semantics(
                link: true,
                child: TextButton(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 44),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () async {
                    final ok = await ref
                        .read(sermonLinkLauncherProvider)
                        .open(uri);
                    if (!ok && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('This link could not be opened.'),
                        ),
                      );
                    }
                  },
                  child: Text(
                    match[1]!,
                    style: const TextStyle(
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
            ),
          );
        }
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
