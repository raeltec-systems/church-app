import 'dart:typed_data';

import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/content_controllers.dart' show publicEventsProvider;
import '../application/providers.dart' show bannerRepositoryProvider;
import '../application/sermon_controllers.dart' show publicSermonsProvider;
import '../domain/access_grants.dart';
import '../domain/content_banners.dart' show PublicImage;
import '../domain/content_events.dart';
import '../domain/content_sermons.dart';
import 'calendar_screens.dart'
    show
        CalendarPaths,
        churchShortWhen,
        eventSpanText,
        publicReadProblem,
        publicSavedStatus;
import 'church_widgets.dart';
import 'sermon_screens.dart' show SermonPaths;

// Epic 6 entry 14 (Home, everyone): Coming up as poster cards. The next
// published events (at most three) and the series the church is preaching
// now each get a card: the 16:9 poster on top when there is one, which opens
// the original poster, then the title and when and where, which open the
// event (or the Sermons tab). An event without a poster keeps its date
// badge. The poster screens show the whole image, zoomable, with its text
// alternative. The series card shows only when its poster can be shown; the
// Sermons tab carries the series otherwise.

/// The poster routes under Home.
abstract final class HomePosterPaths {
  static String event(String eventId) => '/home/posters/events/$eventId';
  static String series(String seriesId) => '/home/posters/series/$seriesId';
}

String _sermonCount(int n) =>
    n == 1 ? 'Sermon series · 1 sermon' : 'Sermon series · $n sermons';

/// Story 6.1, finished by entry 14: Home's Coming up.
class ComingUpSection extends ConsumerWidget {
  const ComingUpSection({super.key});

  static const shown = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final s = ref.watch(publicEventsProvider);
    final sermons = ref.watch(publicSermonsProvider);
    Widget? seriesCard;
    if (sermons.result case AccessReadOk(:final value)) {
      final series = value.currentSeries;
      final poster = series?.poster;
      if (series != null &&
          poster != null &&
          (poster.offlineBytes != null || !sermons.offlineSnapshot)) {
        seriesCard = _SeriesPosterCard(
          series: series,
          sermons: value.sermons
              .where((x) => x.series?.seriesId == series.seriesId)
              .length,
        );
      }
    }
    final Widget body = switch (s.result) {
      null => Text(
        'Loading the calendar…',
        key: const Key('coming-up-loading'),
        style: ChurchType.secondary.copyWith(color: c.muted),
      ),
      AccessReadOk(:final value) when value.events.isEmpty => Text(
        'No upcoming events.',
        key: const Key('coming-up-empty'),
        style: ChurchType.body.copyWith(color: c.muted),
      ),
      AccessReadOk(:final value) => Column(
        key: const Key('coming-up-list'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, e) in value.events.take(shown).indexed) ...[
            if (i > 0) const SizedBox(height: 14),
            _EventPosterCard(event: e),
          ],
        ],
      ),
      AccessReadFailed(:final unreachable) => Text(
        unreachable
            ? 'No connection: we couldn\'t reach the church server, so no '
                  'events are shown. This is not an empty calendar.'
            : 'Couldn\'t load the calendar. Try again later.',
        key: const Key('coming-up-failed'),
        style: ChurchType.body.copyWith(color: c.ink),
      ),
      AccessReadDenied() => Text(
        'The calendar is not available from this app right now.',
        key: const Key('coming-up-unavailable'),
        style: ChurchType.body.copyWith(color: c.ink),
      ),
    };
    final savedStatus = publicSavedStatus(
      context,
      s,
      what: 'calendar',
      key: 'coming-up-stale',
    );
    return Column(
      key: const Key('coming-up'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: 'Coming up'),
        const SizedBox(height: 8),
        ?savedStatus,
        body,
        if (seriesCard != null) ...[const SizedBox(height: 14), seriesCard],
        const SizedBox(height: 4),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FocusRing(
            child: TextButton(
              key: const Key('coming-up-calendar'),
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: () => context.go(CalendarPaths.calendar),
              child: const Text('See the calendar'),
            ),
          ),
        ),
      ],
    );
  }
}

/// The card frame: surface, a 1 px line and the card radius; the poster is
/// clipped to the top corners.
class _CardFrame extends StatelessWidget {
  const _CardFrame({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final radius = BorderRadius.circular(ChurchGeometry.mobileCardRadius);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.line),
        borderRadius: radius,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}

/// The 16:9 poster area of a card: the image cropped to fill (the whole
/// poster is one tap away), a plain tile when it does not load.
class _PosterTile extends ConsumerWidget {
  const _PosterTile({
    required this.tapKey,
    required this.image,
    required this.altText,
    required this.title,
    required this.onTap,
    this.bytes,
  });

  final Key tapKey;
  final PublicImage image;
  final String altText;
  final String title;
  final VoidCallback onTap;
  final Uint8List? bytes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final fallback = ColoredBox(color: c.surface2);
    final b = bytes;
    final Widget picture = b != null
        ? Image.memory(
            b,
            fit: BoxFit.cover,
            excludeFromSemantics: true,
            errorBuilder: (_, _, _) => fallback,
          )
        : Image.network(
            ref
                .read(bannerRepositoryProvider)
                .publicFileUrl(image.path)
                .toString(),
            fit: BoxFit.cover,
            excludeFromSemantics: true,
            errorBuilder: (_, _, _) => fallback,
          );
    return Semantics(
      button: true,
      image: true,
      label: 'Poster for $title: $altText. Open the full poster.',
      excludeSemantics: true,
      child: FocusRing(
        radius: 4,
        child: InkWell(
          key: tapKey,
          onTap: onTap,
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: ColoredBox(color: c.surface2, child: picture),
          ),
        ),
      ),
    );
  }
}

/// The title and its line under a poster (or beside a date badge).
class _CardText extends StatelessWidget {
  const _CardText({
    required this.tapKey,
    required this.label,
    required this.title,
    required this.line,
    required this.onTap,
    this.lineKey,
    this.leading,
  });

  final Key tapKey;
  final String label;
  final String title;
  final String line;
  final Key? lineKey;
  final Widget? leading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: FocusRing(
        radius: 4,
        child: InkWell(
          key: tapKey,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (leading case final l?) ...[l, const SizedBox(width: 14)],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: ChurchType.itemTitle.copyWith(color: c.ink),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        line,
                        key: lineKey,
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

/// An event's card: its poster (when public) opens the original poster; the
/// text opens the event.
class _EventPosterCard extends StatelessWidget {
  const _EventPosterCard({required this.event});
  final PublicEvent event;

  @override
  Widget build(BuildContext context) {
    final e = event;
    final poster = e.poster;
    final when = eventSpanText(e.startsAt, e.endsAt);
    return _CardFrame(
      key: Key('coming-up-card-${e.eventId}'),
      children: [
        if (poster != null)
          _PosterTile(
            tapKey: Key('coming-up-poster-${e.eventId}'),
            image: poster.image,
            altText: poster.altText,
            title: e.title,
            onTap: () => context.push(HomePosterPaths.event(e.eventId)),
          ),
        _CardText(
          tapKey: Key('event-row-${e.eventId}'),
          lineKey: Key('event-when-${e.eventId}'),
          label:
              '${e.title}, ${churchShortWhen(e.startsAt)}, $when, '
              '${e.location}',
          title: e.title,
          line: '$when · ${e.location}',
          leading: poster == null ? ChurchDateBadge(at: e.startsAt) : null,
          onTap: () => context.push(CalendarPaths.event(e.eventId)),
        ),
      ],
    );
  }
}

/// The series the church is preaching now: its poster opens the original;
/// the text opens the Sermons tab.
class _SeriesPosterCard extends StatelessWidget {
  const _SeriesPosterCard({required this.series, required this.sermons});
  final PublicSermonSeries series;
  final int sermons;

  @override
  Widget build(BuildContext context) {
    final poster = series.poster!;
    final line = _sermonCount(sermons);
    return _CardFrame(
      key: Key('coming-up-series-${series.seriesId}'),
      children: [
        _PosterTile(
          tapKey: Key('coming-up-series-poster-${series.seriesId}'),
          image: poster.image,
          altText: series.altText,
          title: series.title,
          bytes: poster.offlineBytes,
          onTap: () => context.push(HomePosterPaths.series(series.seriesId)),
        ),
        _CardText(
          tapKey: Key('coming-up-series-open-${series.seriesId}'),
          label: '${series.title}, $line. Open Sermons.',
          title: series.title,
          line: line,
          onTap: () => context.go(SermonPaths.list),
        ),
      ],
    );
  }
}

/// `/home/posters/events/<id>` and `/home/posters/series/<id>` (mobile,
/// everyone): the original poster, whole and zoomable, with its text
/// alternative, the title and a way on to the event or the sermons.
class HomePosterScreen extends ConsumerWidget {
  const HomePosterScreen.event({super.key, required this.id}) : series = false;
  const HomePosterScreen.series({super.key, required this.id}) : series = true;

  final String id;
  final bool series;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layout = ChurchLayout.of(context);
    final children = <Widget>[];
    VoidCallback? reload;
    if (series) {
      final s = ref.watch(publicSermonsProvider);
      final ctl = ref.read(publicSermonsProvider.notifier);
      reload = s.loading ? null : ctl.reload;
      switch (s.result) {
        case null:
          children.add(_loading);
        case AccessReadOk(:final value):
          final found = value.series.where((x) => x.seriesId == id).firstOrNull;
          final poster = found?.poster;
          if (found == null ||
              poster == null ||
              (s.offlineSnapshot && poster.offlineBytes == null)) {
            children.add(_gone(context));
          } else {
            final count = value.sermons
                .where((x) => x.series?.seriesId == id)
                .length;
            children.addAll(
              _poster(
                context,
                ref,
                image: poster.image,
                bytes: poster.offlineBytes,
                altText: found.altText,
                title: found.title,
                line: [
                  _sermonCount(count),
                  if (found.description.isNotEmpty) found.description,
                ].join(' · '),
                next: FocusRing(
                  child: FilledButton(
                    key: const Key('poster-see-sermons'),
                    onPressed: () => context.go(SermonPaths.list),
                    child: const Text('See the sermons'),
                  ),
                ),
              ),
            );
          }
        case final AccessRead<PublicSermons> problem:
          children.add(publicReadProblem(problem, what: 'poster'));
      }
    } else {
      final s = ref.watch(publicEventsProvider);
      final ctl = ref.read(publicEventsProvider.notifier);
      reload = s.loading ? null : ctl.reload;
      switch (s.result) {
        case null:
          children.add(_loading);
        case AccessReadOk(:final value):
          final e = value.events.where((x) => x.eventId == id).firstOrNull;
          final poster = e?.poster;
          if (e == null || poster == null) {
            children.add(_gone(context));
          } else {
            children.addAll(
              _poster(
                context,
                ref,
                image: poster.image,
                altText: poster.altText,
                title: e.title,
                line: '${eventSpanText(e.startsAt, e.endsAt)} · ${e.location}',
                next: FocusRing(
                  child: FilledButton(
                    key: const Key('poster-see-event'),
                    onPressed: () => context.push(CalendarPaths.event(id)),
                    child: const Text('See event'),
                  ),
                ),
              ),
            );
          }
        case final AccessRead<PublicEvents> problem:
          children.add(publicReadProblem(problem, what: 'poster'));
      }
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Poster'),
        actions: [
          FocusRing(
            radius: 22,
            child: IconButton(
              key: const Key('poster-reload'),
              tooltip: 'Reload',
              onPressed: reload,
              icon: const Icon(Icons.refresh),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
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

  static const Widget _loading = RequestStateBanner(
    key: Key('poster-loading'),
    tone: StatusTone.info,
    busy: true,
    title: 'Loading…',
    message: 'Asking the church server.',
  );

  Widget _gone(BuildContext context) => RequestStateBanner(
    key: const Key('poster-gone'),
    tone: StatusTone.neutral,
    title: 'No longer shown',
    message: 'This poster is no longer shown.',
    actions: [
      BannerAction(
        'Back to Home',
        () => context.go('/home'),
        key: const Key('poster-gone-home'),
        primary: true,
      ),
    ],
  );

  List<Widget> _poster(
    BuildContext context,
    WidgetRef ref, {
    required PublicImage image,
    required String altText,
    required String title,
    required String line,
    required Widget next,
    Uint8List? bytes,
  }) {
    final c = ChurchColors.of(context);
    Widget unavailable(BuildContext context, Object error, StackTrace? st) =>
        Center(
          key: const Key('poster-unavailable'),
          child: Text(
            'Poster unavailable',
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
        );
    final picture = bytes != null
        ? Image.memory(
            bytes,
            key: const Key('poster-image'),
            fit: BoxFit.contain,
            semanticLabel: altText,
            errorBuilder: unavailable,
          )
        : Image.network(
            ref
                .read(bannerRepositoryProvider)
                .publicFileUrl(image.path)
                .toString(),
            key: const Key('poster-image'),
            fit: BoxFit.contain,
            semanticLabel: altText,
            errorBuilder: unavailable,
          );
    return [
      ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: ColoredBox(
          color: c.surface2,
          child: AspectRatio(
            aspectRatio: image.width / image.height,
            child: InteractiveViewer(
              key: const Key('poster-viewer'),
              maxScale: 4,
              child: picture,
            ),
          ),
        ),
      ),
      const SizedBox(height: 16),
      Semantics(
        header: true,
        child: Text(
          title,
          key: const Key('poster-title'),
          style: ChurchType.mobileScreenTitle.copyWith(color: c.ink),
        ),
      ),
      const SizedBox(height: 6),
      Text(
        line,
        key: const Key('poster-line'),
        style: ChurchType.body.copyWith(color: c.muted),
      ),
      const SizedBox(height: ChurchGeometry.sectionGap),
      Align(alignment: AlignmentDirectional.centerStart, child: next),
    ];
  }
}
