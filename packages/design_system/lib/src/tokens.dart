import 'package:flutter/material.dart';

/// Semantic colour tokens from design-contract.md "Tokens, type and geometry".
///
/// Mobile swaps the full set between [light] and [dark]; staff web uses
/// [light] only (with the navy sidebar). Screens read colours through
/// `ChurchColors.of(context)` and never hard-code hex values.
@immutable
class ChurchColors extends ThemeExtension<ChurchColors> {
  const ChurchColors({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.ink,
    required this.muted,
    required this.line,
    required this.primary,
    required this.onPrimary,
    required this.brand,
    required this.link,
    required this.accent,
    required this.focus,
    required this.hero,
    required this.amberBg,
    required this.amberFg,
    required this.greenBg,
    required this.greenFg,
    required this.redBg,
    required this.redFg,
    required this.blueBg,
    required this.blueFg,
    required this.grayBg,
    required this.sidebar,
    required this.onSidebar,
    required this.onSidebarMuted,
  });

  static const light = ChurchColors(
    brightness: Brightness.light,
    bg: Color(0xFFF4F6FA),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFEDF0F6),
    ink: Color(0xFF0E1530),
    muted: Color(0xFF586079),
    line: Color(0xFFDFE4EE),
    primary: Color(0xFF14246B),
    onPrimary: Color(0xFFFFFFFF),
    brand: Color(0xFF14246B),
    link: Color(0xFF14246B),
    accent: Color(0xFF0A7FE0),
    // Focus ring: the accent token (1.6 trial: >=3:1 change on bg/surface).
    focus: Color(0xFF0A7FE0),
    hero: Color(0xFF14246B),
    amberBg: Color(0xFFFFF1CF),
    amberFg: Color(0xFF6E4400),
    greenBg: Color(0xFFDFF3E8),
    greenFg: Color(0xFF0D6438),
    redBg: Color(0xFFFCE5E2),
    redFg: Color(0xFFA3241A),
    blueBg: Color(0xFFE3EEFC),
    blueFg: Color(0xFF0B4FA6),
    grayBg: Color(0xFFEDF0F6),
    sidebar: Color(0xFF14246B),
    onSidebar: Color(0xFFFFFFFF),
    onSidebarMuted: Color(0xFFDCE6FF),
  );

  static const dark = ChurchColors(
    brightness: Brightness.dark,
    bg: Color(0xFF0A0F1E),
    surface: Color(0xFF131A2E),
    surface2: Color(0xFF1B2440),
    ink: Color(0xFFEDF0F7),
    muted: Color(0xFF9AA3BC),
    line: Color(0xFF26304D),
    primary: Color(0xFF2A6FD0),
    onPrimary: Color(0xFFFFFFFF),
    brand: Color(0xFFDCE6FF),
    link: Color(0xFF8EC1FF),
    accent: Color(0xFF3D9BF5),
    focus: Color(0xFF8EC1FF),
    hero: Color(0xFF182A7A),
    amberBg: Color(0xFF3A2D10),
    amberFg: Color(0xFFF5C866),
    greenBg: Color(0xFF10301F),
    greenFg: Color(0xFF7FD9A6),
    redBg: Color(0xFF3A1614),
    redFg: Color(0xFFF4A29A),
    blueBg: Color(0xFF13284A),
    blueFg: Color(0xFF9CC7FF),
    grayBg: Color(0xFF1B2440),
    sidebar: Color(0xFF182A7A),
    onSidebar: Color(0xFFFFFFFF),
    onSidebarMuted: Color(0xFFDCE6FF),
  );

  final Brightness brightness;
  final Color bg;
  final Color surface;
  final Color surface2;
  final Color ink;
  final Color muted;
  final Color line;
  final Color primary;
  final Color onPrimary;
  final Color brand;
  final Color link;
  final Color accent;

  /// Keyboard focus ring colour on [bg]/[surface].
  final Color focus;
  final Color hero;
  final Color amberBg;
  final Color amberFg;
  final Color greenBg;
  final Color greenFg;
  final Color redBg;
  final Color redFg;
  final Color blueBg;
  final Color blueFg;

  /// Neutral chip background; its foreground is [muted].
  final Color grayBg;

  /// Staff navigation sidebar (light palette: `#14246B`).
  final Color sidebar;
  final Color onSidebar;
  final Color onSidebarMuted;

  /// The tokens of the nearest theme; falls back to [light].
  static ChurchColors of(BuildContext context) =>
      Theme.of(context).extension<ChurchColors>() ?? light;

  @override
  ChurchColors copyWith() => this;

  @override
  ChurchColors lerp(ChurchColors? other, double t) =>
      other == null || t < 0.5 ? this : other;
}

/// Geometry from the design contract, in logical pixels.
abstract final class ChurchGeometry {
  /// Minimum interactive target (both clients).
  static const double minTarget = 44;

  /// Button height used by the themes (the contract's 46–54 primary range).
  static const double buttonHeight = 48;

  /// Width of the keyboard focus ring drawn outside a control (1.6 trial).
  static const double focusRingWidth = 3;

  static const double mobileContentPadding = 16;
  static const double mobileFormPadding = 20;
  static const double sectionGap = 20;
  static const double cardPadding = 16;
  static const double mobileCardRadius = 16;
  static const double mobileInputRadius = 14;
  static const double staffInputRadius = 10;
  static const double staffButtonRadius = 12;
  static const double staffSidebarWidth = 232;
  static const double staffContentMaxWidth = 1280;
  static const double modalWidth = 460;
  static const double modalRadius = 18;

  /// Below this width the staff shell replaces the sidebar with a top bar.
  static const double staffCompactBreakpoint = 840;
}

/// Type scale (size / weight) from the design contract. Families (Outfit,
/// Figtree, JetBrains Mono) are not bundled yet: platform fonts are used.
abstract final class ChurchType {
  static const mobileScreenTitle = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w700,
  );
  static const sectionTitle = TextStyle(
    fontSize: 19,
    fontWeight: FontWeight.w600,
  );
  static const cardTitle = TextStyle(fontSize: 17, fontWeight: FontWeight.w600);
  static const body = TextStyle(fontSize: 16, fontWeight: FontWeight.w400);
  static const staffBody = TextStyle(fontSize: 15, fontWeight: FontWeight.w400);
  static const secondary = TextStyle(fontSize: 14, fontWeight: FontWeight.w400);
  static const chip = TextStyle(fontSize: 13, fontWeight: FontWeight.w600);
  static const staffPageTitle = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w700,
  );
  static const modalTitle = TextStyle(
    fontSize: 21,
    fontWeight: FontWeight.w700,
  );
}
