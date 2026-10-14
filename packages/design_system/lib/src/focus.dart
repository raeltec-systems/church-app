import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';

import 'tokens.dart';

/// Whether focus indicators should be visible, like CSS `:focus-visible`:
/// the focus highlight mode is traditional (no touch) *and* the most recent
/// input was a key press, not a pointer (mouse, touch or stylus) press. A
/// desktop mouse click therefore leaves no ring, and neither does a tap.
class FocusVisibility extends ChangeNotifier {
  FocusVisibility._();

  static final FocusVisibility instance = FocusVisibility._();

  bool _keyboard = true;
  bool _attached = false;

  bool get visible {
    _attach();
    return _keyboard &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
  }

  void _attach() {
    if (_attached) return;
    _attached = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    HardwareKeyboard.instance.addHandler(_onKey);
    FocusManager.instance.addHighlightModeListener((_) => notifyListeners());
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent && _keyboard) {
      _keyboard = false;
      notifyListeners();
    }
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent && !_keyboard) {
      _keyboard = true;
      notifyListeners();
    }
    return false;
  }

  /// Test hook: forget the last input (as at startup).
  @visibleForTesting
  void reset() {
    if (_attached) {
      // Test bindings may drop global handlers between tests: re-register.
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
      HardwareKeyboard.instance.removeHandler(_onKey);
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
      HardwareKeyboard.instance.addHandler(_onKey);
    }
    _attach();
    _keyboard = true;
    notifyListeners();
  }
}

/// True when focus indicators must be visible (see [FocusVisibility]).
bool get keyboardFocusVisible => FocusVisibility.instance.visible;

/// Rebuilds [builder] whenever [keyboardFocusVisible] may have changed.
class FocusHighlightBuilder extends StatefulWidget {
  const FocusHighlightBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, bool keyboardMode) builder;

  @override
  State<FocusHighlightBuilder> createState() => _FocusHighlightBuilderState();
}

class _FocusHighlightBuilderState extends State<FocusHighlightBuilder> {
  @override
  void initState() {
    super.initState();
    FocusVisibility.instance.addListener(_changed);
  }

  @override
  void dispose() {
    FocusVisibility.instance.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, keyboardFocusVisible);
}

/// Draws a [ChurchGeometry.focusRingWidth] ring *outside* [child] whenever
/// keyboard focus is on [child] or a descendant, so the ring contrasts with
/// the page rather than with the control's own fill (1.6 finding 4). Focus
/// from a pointer or touch shows no ring.
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

  /// Ring colour; defaults to the theme's focus token. Use
  /// [ChurchStaffChrome.onSidebar] (white) on navy surfaces.
  final Color? color;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final ring = color ?? ChurchColors.of(context).focus;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      child: FocusHighlightBuilder(
        builder: (context, keyboardMode) {
          final focused = keyboardMode && Focus.of(context).hasFocus;
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
