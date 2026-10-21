import 'package:flutter/material.dart';

import 'focus.dart';
import 'tokens.dart';

/// The handoff's surface card: white, 1 px line, radius 18, no shadow.
class ChurchCard extends StatelessWidget {
  const ChurchCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(ChurchGeometry.cardPadding),
    this.onTap,
    this.radius = ChurchGeometry.mobileCardRadius,
    this.semanticLabel,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final double radius;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final shape = RoundedRectangleBorder(
      side: BorderSide(color: c.line),
      borderRadius: BorderRadius.circular(radius),
    );
    final body = Padding(padding: padding, child: child);
    return Semantics(
      container: true,
      label: semanticLabel,
      child: Material(
        color: c.surface,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: onTap == null
            ? body
            : FocusRing(
                radius: radius,
                child: InkWell(onTap: onTap, child: body),
              ),
      ),
    );
  }
}

/// The handoff's navy hero card (My duties, My cell): radius 22, white text
/// and a thin decorative ring in one corner.
class HeroCard extends StatelessWidget {
  const HeroCard({
    super.key,
    required this.child,
    this.ringAtTop = false,
    this.padding = const EdgeInsets.all(18),
  });

  final Widget child;
  final bool ringAtTop;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(ChurchGeometry.heroRadius),
      child: ColoredBox(
        color: c.hero,
        child: Stack(
          children: [
            Positioned(
              right: -60,
              top: ringAtTop ? -60 : null,
              bottom: ringAtTop ? null : -60,
              child: ExcludeSemantics(
                child: Container(
                  width: 180,
                  height: 180,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                      width: 2,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: padding,
              child: DefaultTextStyle.merge(
                style: const TextStyle(color: Colors.white),
                child: IconTheme.merge(
                  data: const IconThemeData(color: Colors.white),
                  child: child,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Where a [DateBadge] sits: a plain surface, a navy hero, or highlighted.
enum DateBadgeTone { surface, hero, info }

/// The handoff's date badge: weekday, big day number, month.
class DateBadge extends StatelessWidget {
  const DateBadge({
    super.key,
    required this.weekday,
    required this.day,
    required this.month,
    this.tone = DateBadgeTone.surface,
  });

  /// Short upper-case labels, for example `SUN`, `4`, `OCT`.
  final String weekday;
  final String day;
  final String month;
  final DateBadgeTone tone;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final (bg, small, big) = switch (tone) {
      DateBadgeTone.surface => (c.surface2, c.muted, c.brand),
      DateBadgeTone.hero => (
        Colors.white.withValues(alpha: 0.12),
        Colors.white.withValues(alpha: 0.85),
        Colors.white,
      ),
      DateBadgeTone.info => (c.blueBg, c.blueFg, c.blueFg),
    };
    final smallStyle = TextStyle(
      fontFamily: ChurchFonts.body,
      fontSize: 11,
      fontWeight: FontWeight.w700,
      color: small,
      height: 1.1,
    );
    return Semantics(
      label: '$weekday $day $month',
      excludeSemantics: true,
      child: Container(
        width: 52,
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(weekday, style: smallStyle),
            Text(day, style: ChurchType.dateNumber.copyWith(color: big)),
            Text(month, style: smallStyle),
          ],
        ),
      ),
    );
  }
}

/// A section header: 19/600 Outfit title and an optional text action.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              title,
              style: ChurchType.sectionTitle.copyWith(color: c.ink),
            ),
          ),
        ),
        ?action,
      ],
    );
  }
}

/// An upper-case label inside a card ("PROGRAMME", "INSTRUCTIONS").
class CardLabel extends StatelessWidget {
  const CardLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(
      text.toUpperCase(),
      style: ChurchType.label.copyWith(color: ChurchColors.of(context).muted),
    ),
  );
}

/// One label and value of a [DetailTable].
typedef DetailRow = ({String label, String value});

/// The handoff's detail table: muted labels in a 104 px column, values in
/// ink, rows split by 1 px lines, inside a card.
class DetailTable extends StatelessWidget {
  const DetailTable({super.key, required this.rows, this.labelWidth = 104});

  final List<DetailRow> rows;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return ChurchCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                border: i == rows.length - 1
                    ? null
                    : Border(bottom: BorderSide(color: c.line)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: labelWidth,
                    child: Text(
                      rows[i].label,
                      style: ChurchType.secondary.copyWith(color: c.muted),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      rows[i].value,
                      style: ChurchType.body.copyWith(
                        fontWeight: FontWeight.w500,
                        color: c.ink,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A tappable menu row (Profile menu): label, optional meta, chevron;
/// min height 54.
class MenuRow extends StatelessWidget {
  const MenuRow({
    super.key,
    required this.label,
    required this.onTap,
    this.meta,
    this.danger = false,
    this.showDivider = true,
  });

  final String label;
  final String? meta;
  final VoidCallback onTap;
  final bool danger;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return FocusRing(
      radius: 4,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 54),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            border: showDivider
                ? Border(bottom: BorderSide(color: c.line))
                : null,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: ChurchType.body.copyWith(
                    fontWeight: FontWeight.w500,
                    color: danger ? c.redFg : c.ink,
                  ),
                ),
              ),
              if (meta case final m?)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    m,
                    style: ChurchType.secondary.copyWith(color: c.muted),
                  ),
                ),
              if (!danger) ...[
                const SizedBox(width: 6),
                ExcludeSemantics(
                  child: Icon(Icons.chevron_right, size: 20, color: c.muted),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The sticky footer of a detail screen (Accept / Can't make it): surface
/// background, 1 px top line, padded above the system inset.
class BottomActionBar extends StatelessWidget {
  const BottomActionBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: child,
        ),
      ),
    );
  }
}

/// The church emblem (it already carries the church's name): in a white
/// circle on light surfaces, or the white monochrome mark on navy.
class ChurchLogo extends StatelessWidget {
  const ChurchLogo({super.key, this.size = 44, this.onNavy = false});

  final double size;
  final bool onNavy;

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      onNavy ? 'assets/bic-logo-white.png' : 'assets/bic-logo.png',
      package: 'church_design_system',
      width: size,
      height: size,
      semanticLabel: onNavy ? null : 'Brethren in Christ Church Kafue',
      excludeFromSemantics: onNavy,
    );
    if (onNavy) return image;
    return ClipOval(
      child: ColoredBox(color: Colors.white, child: image),
    );
  }
}
