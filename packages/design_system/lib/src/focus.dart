import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'tokens.dart';

/// Draws a [ChurchGeometry.focusRingWidth] ring *outside* [child] whenever
/// focus is on [child] or a descendant, so the ring contrasts with the page
/// rather than with the control's own fill (1.6 finding 4).
///
/// The ring is per control: wrap each focusable control separately, never a
/// whole group (1.6 finding 2).
class FocusRing extends StatelessWidget {
  const FocusRing({
    super.key,
    required this.child,
    this.color,
    this.radius = 14,
  });

  final Widget child;

  /// Ring colour; defaults to the theme's focus token. Use the sidebar's
  /// on-colour (white) on navy surfaces.
  final Color? color;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final ring = color ?? ChurchColors.of(context).focus;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return Container(
            padding: const EdgeInsets.all(ChurchGeometry.focusRingWidth + 1),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(
                color: focused ? ring : Colors.transparent,
                width: ChurchGeometry.focusRingWidth,
              ),
            ),
            child: child,
          );
        },
      ),
    );
  }
}

/// Scrolls [child] into view whenever keyboard focus lands on it or a
/// descendant. `requestFocus()` alone does not scroll (1.6 finding 8).
class RevealOnFocus extends StatelessWidget {
  const RevealOnFocus({super.key, required this.child, this.alignment = 0.5});

  final Widget child;
  final double alignment;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onFocusChange: (focused) {
        if (!focused) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) {
            Scrollable.ensureVisible(context, alignment: alignment);
          }
        });
      },
      child: child,
    );
  }
}

/// Announces [message] to screen readers.
///
/// `Semantics(liveRegion: true)` produced no announcement in Chromium, and
/// the engine moves its announcement element into any still-open modal
/// dialog (1.6 finding 7). Callers that close a dialog first pass a [delay]
/// covering its exit transition. Always show the same text persistently too.
void announce(
  BuildContext context,
  String message, {
  Duration delay = Duration.zero,
}) {
  final view = View.of(context);
  final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
  void send() => SemanticsService.sendAnnouncement(view, message, direction);
  if (delay == Duration.zero) {
    send();
  } else {
    Future<void>.delayed(delay, () {
      if (context.mounted) send();
    });
  }
}

/// Time for a dialog's exit transition before announcing.
const Duration kAnnouncementAfterDialog = Duration(milliseconds: 400);
