import 'dart:math' as math;

import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/banner_controllers.dart';
import '../application/providers.dart' show bannerRepositoryProvider;
import '../domain/access_grants.dart';
import '../domain/content_banners.dart';
import 'calendar_screens.dart'
    show CalendarPaths, publicReadProblem, staleNotice;

// Story 6.2 (mobile, everyone): Home opens with the church's banners, the
// yearly theme first and then campaigns, in a 16:9 snap carousel (handoff:
// cards 310 px wide, radius 20). The theme card is the handoff's navy card;
// its uploaded image is the original a tap opens. A campaign card shows its
// image with a flat caption band. Images are read from the public bucket and
// held only in the image memory cache: nothing is stored (AD-13).

/// The routes of banners.
abstract final class BannerPaths {
  /// Mobile: one published banner's original image (under Home).
  static String banner(String bannerId) => '/home/banners/$bannerId';

  /// Staff web: the Banners editor.
  static const banners = '/content/banners';

  /// Staff web: the rights records.
  static const rights = '/content/rights';
}

/// The carousel's card width and gap (handoff).
const _cardWidth = 310.0;
const _cardGap = 12.0;

/// What a screen reader hears for a banner card.
String bannerCardLabel(PublicBanner b) => switch (b.kind) {
  BannerKind.theme => [
    'Theme for ${b.themeYear}.',
    '${b.title}.',
    if (b.subtitle case final s?) '$s.',
    'Opens the theme image.',
  ].join(' '),
  BannerKind.campaign => '${_sentence(b.altText)} ${_sentence(b.title)}',
};

String _sentence(String s) {
  final t = s.trim();
  return t.endsWith('.') || t.endsWith('!') || t.endsWith('?') ? t : '$t.';
}

/// Home's banner carousel: nothing while there are no banners (or this
/// build cannot read them), one grey card while loading, one line with
/// Retry when the read failed.
class HomeBannersCarousel extends ConsumerWidget {
  const HomeBannersCarousel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final s = ref.watch(publicBannersProvider);
    Widget gap(Widget child) =>
        Padding(padding: const EdgeInsets.only(bottom: 18), child: child);
    switch (s.result) {
      case null:
        return gap(
          LayoutBuilder(
            builder: (context, box) {
              final w = math.min(_cardWidth, box.maxWidth);
              return Align(
                alignment: AlignmentDirectional.centerStart,
                child: Container(
                  key: const Key('home-banners-loading'),
                  width: w,
                  height: w * 9 / 16,
                  decoration: BoxDecoration(
                    color: c.surface2,
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              );
            },
          ),
        );
      case AccessReadOk(:final value) when value.banners.isEmpty:
        return const SizedBox.shrink();
      case AccessReadOk(:final value):
        // The theme first, then campaigns, in the server's order.
        final banners = [
          ...value.banners.where((b) => b.kind == BannerKind.theme),
          ...value.banners.where((b) => b.kind == BannerKind.campaign),
        ];
        return gap(_Carousel(banners: banners));
      case AccessReadFailed():
        return gap(
          Row(
            key: const Key('home-banners-failed'),
            children: [
              Expanded(
                child: Text(
                  'Couldn\'t load church news.',
                  style: ChurchType.body.copyWith(color: c.ink),
                ),
              ),
              FocusRing(
                child: TextButton(
                  key: const Key('home-banners-retry'),
                  onPressed: s.loading
                      ? null
                      : ref.read(publicBannersProvider.notifier).reload,
                  child: const Text('Retry'),
                ),
              ),
            ],
          ),
        );
      case AccessReadDenied():
        return const SizedBox.shrink();
    }
  }
}

class _Carousel extends StatelessWidget {
  const _Carousel({required this.banners});
  final List<PublicBanner> banners;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final w = math.min(_cardWidth, box.maxWidth);
      return SizedBox(
        height: w * 9 / 16,
        child: ListView.separated(
          key: const Key('home-banners'),
          scrollDirection: Axis.horizontal,
          physics: _SnapPhysics(extent: w + _cardGap),
          itemCount: banners.length,
          separatorBuilder: (_, _) => const SizedBox(width: _cardGap),
          itemBuilder: (context, i) => SizedBox(
            width: w,
            child: _BannerCard(banner: banners[i]),
          ),
        ),
      );
    },
  );
}

/// Snaps a horizontal list to whole cards of [extent].
class _SnapPhysics extends ScrollPhysics {
  const _SnapPhysics({required this.extent, super.parent});
  final double extent;

  @override
  _SnapPhysics applyTo(ScrollPhysics? ancestor) =>
      _SnapPhysics(extent: extent, parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if ((velocity <= 0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final t = toleranceFor(position);
    var page = position.pixels / extent;
    if (velocity < -t.velocity) {
      page -= 0.5;
    } else if (velocity > t.velocity) {
      page += 0.5;
    }
    final target = (page.roundToDouble() * extent).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() < t.distance) return null;
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      target,
      velocity,
      tolerance: t,
    );
  }
}

class _BannerCard extends ConsumerWidget {
  const _BannerCard({required this.banner});
  final PublicBanner banner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = banner;
    void open() => context.push(BannerPaths.banner(b.bannerId));
    final card = switch (b.kind) {
      BannerKind.theme => _ThemeCard(banner: b),
      BannerKind.campaign => _CampaignCard(
        banner: b,
        url: ref.read(bannerRepositoryProvider).publicFileUrl(b.image.path),
      ),
    };
    return Semantics(
      key: Key('home-banner-${b.bannerId}'),
      button: true,
      label: bannerCardLabel(b),
      excludeSemantics: true,
      onTap: open,
      child: FocusRing(
        radius: 20,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            fit: StackFit.expand,
            children: [
              card,
              Positioned.fill(
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    key: Key('home-banner-open-${b.bannerId}'),
                    onTap: open,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The handoff's theme card: navy, the eyebrow, the theme and its
/// reference; decorative rings and the white emblem top right.
class _ThemeCard extends StatelessWidget {
  const _ThemeCard({required this.banner});
  final PublicBanner banner;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final b = banner;
    return ColoredBox(
      color: c.hero,
      child: Stack(
        children: [
          const Positioned(
            right: -46,
            top: -46,
            child: CustomPaint(size: Size(180, 180), painter: _RingsPainter()),
          ),
          const Positioned(
            right: 14,
            top: 14,
            child: ChurchLogo(size: 52, onNavy: true),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'THEME FOR ${b.themeYear}',
                  key: Key('home-banner-eyebrow-${b.bannerId}'),
                  style: const TextStyle(
                    fontFamily: ChurchFonts.mono,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.32,
                    color: Color(0xCCFFFFFF),
                  ),
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(right: 40),
                  child: Text(
                    b.title,
                    key: Key('home-banner-title-${b.bannerId}'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: ChurchFonts.heading,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      height: 1.15,
                      color: Colors.white,
                    ),
                  ),
                ),
                if (b.subtitle case final s?) ...[
                  const SizedBox(height: 4),
                  Text(
                    s,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: ChurchFonts.body,
                      fontSize: 13,
                      color: Color(0xD9FFFFFF),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Concentric rings, white at low opacity (decoration only).
class _RingsPainter extends CustomPainter {
  const _RingsPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(0x24FFFFFF);
    final centre = size.center(Offset.zero);
    for (final r in const [44.0, 66.0, 88.0]) {
      canvas.drawCircle(centre, r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// A campaign card: the image (cover) with a flat dark caption band.
class _CampaignCard extends StatelessWidget {
  const _CampaignCard({required this.banner, required this.url});
  final PublicBanner banner;
  final Uri url;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final b = banner;
    return ColoredBox(
      color: c.surface2,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.network(
            url.toString(),
            key: Key('home-banner-image-${b.bannerId}'),
            fit: BoxFit.cover,
            excludeFromSemantics: true,
            errorBuilder: (context, _, _) => Padding(
              key: Key('home-banner-unavailable-${b.bannerId}'),
              padding: const EdgeInsets.all(14),
              child: Align(
                alignment: AlignmentDirectional.topStart,
                child: Text(
                  'Image unavailable',
                  style: ChurchType.secondary.copyWith(color: c.muted),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ColoredBox(
              color: const Color(0xC70E1530),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      b.title,
                      key: Key('home-banner-title-${b.bannerId}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: ChurchFonts.heading,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    if (b.subtitle case final s?)
                      Text(
                        s,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: ChurchFonts.body,
                          fontSize: 13,
                          color: Color(0xE6FFFFFF),
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
}

/// `/home/banners/<id>` (mobile, everyone): the banner's original image,
/// zoomable, with its title and line, and the linked event when it has one.
class BannerScreen extends ConsumerWidget {
  const BannerScreen({super.key, required this.bannerId});

  final String bannerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final s = ref.watch(publicBannersProvider);
    final ctl = ref.read(publicBannersProvider.notifier);
    final children = <Widget>[];
    var title = 'Banner';
    switch (s.result) {
      case null:
        children.add(
          const RequestStateBanner(
            key: Key('banner-loading'),
            tone: StatusTone.info,
            busy: true,
            title: 'Loading…',
            message: 'Asking the church server.',
          ),
        );
      case AccessReadOk(:final value):
        if (staleNotice(s, what: 'banner', key: 'banner-stale') case final n?) {
          children.addAll([n, const SizedBox(height: 16)]);
        }
        final b = value.byId(bannerId);
        if (b == null) {
          children.add(
            RequestStateBanner(
              key: const Key('banner-gone'),
              tone: StatusTone.neutral,
              title: 'No longer shown',
              message: 'This banner is no longer shown.',
              actions: [
                BannerAction(
                  'Back to Home',
                  () => context.go('/home'),
                  key: const Key('banner-gone-home'),
                  primary: true,
                ),
              ],
            ),
          );
        } else {
          if (b.kind == BannerKind.theme) title = 'Theme for ${b.themeYear}';
          final url = ref
              .read(bannerRepositoryProvider)
              .publicFileUrl(b.image.path);
          children.addAll([
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: ColoredBox(
                color: c.surface2,
                child: AspectRatio(
                  aspectRatio: b.image.width / b.image.height,
                  child: InteractiveViewer(
                    key: const Key('banner-viewer'),
                    maxScale: 4,
                    child: Image.network(
                      url.toString(),
                      key: const Key('banner-image'),
                      fit: BoxFit.contain,
                      semanticLabel: b.altText,
                      errorBuilder: (context, _, _) => Center(
                        key: const Key('banner-image-unavailable'),
                        child: Text(
                          'Image unavailable',
                          style: ChurchType.secondary.copyWith(color: c.muted),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Semantics(
              header: true,
              child: Text(
                b.title,
                key: const Key('banner-title'),
                style: ChurchType.mobileScreenTitle.copyWith(color: c.ink),
              ),
            ),
            if (b.subtitle case final line?) ...[
              const SizedBox(height: 6),
              Text(
                line,
                key: const Key('banner-subtitle'),
                style: ChurchType.body.copyWith(color: c.muted),
              ),
            ],
            if (b.eventId case final eventId?) ...[
              const SizedBox(height: ChurchGeometry.sectionGap),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FocusRing(
                  child: FilledButton(
                    key: const Key('banner-see-event'),
                    onPressed: () => context.push(CalendarPaths.event(eventId)),
                    child: const Text('See event'),
                  ),
                ),
              ),
            ],
          ]);
        }
      case final AccessRead<PublicBanners> problem:
        children.add(publicReadProblem(problem, what: 'banner'));
    }
    final reload = s.loading ? null : ctl.reload;
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          FocusRing(
            radius: 22,
            child: IconButton(
              key: const Key('banner-reload'),
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
}
