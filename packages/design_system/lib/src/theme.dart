import 'package:flutter/material.dart';

import 'tokens.dart';

/// Mobile theme: full light/dark token swap.
ThemeData churchMobileTheme(Brightness brightness) => _theme(
  brightness == Brightness.dark ? ChurchColors.dark : ChurchColors.light,
  layout: ChurchLayout.mobile,
  // Screen title 28/700 in brand.
  title: ChurchType.mobileScreenTitle,
  headerBackground: null,
  titleSpacing: ChurchGeometry.mobileContentPadding,
  inputRadius: ChurchGeometry.mobileInputRadius,
  // Mobile buttons are fully rounded (radius half the height).
  buttonShape: const StadiumBorder(),
);

/// Staff web theme: light palette only, navy sidebar.
ThemeData churchStaffTheme() => _theme(
  ChurchColors.light,
  layout: ChurchLayout.staff,
  // Page title 24/700 #14246B on a white header, padding 18/32.
  title: ChurchType.staffPageTitle,
  headerBackground: ChurchColors.light.surface,
  titleSpacing: 32,
  inputRadius: ChurchGeometry.staffInputRadius,
  buttonShape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(ChurchGeometry.staffButtonRadius),
  ),
);

ThemeData _theme(
  ChurchColors c, {
  required ChurchLayout layout,
  required TextStyle title,
  required Color? headerBackground,
  required double titleSpacing,
  required double inputRadius,
  required OutlinedBorder buttonShape,
}) {
  final scheme = ColorScheme(
    brightness: c.brightness,
    primary: c.primary,
    onPrimary: c.onPrimary,
    secondary: c.accent,
    onSecondary: c.onPrimary,
    error: c.redFg,
    onError: c.brightness == Brightness.light ? Colors.white : c.bg,
    surface: c.surface,
    onSurface: c.ink,
    onSurfaceVariant: c.muted,
    outline: c.muted,
    outlineVariant: c.line,
    surfaceContainerHighest: c.surface2,
  );
  // Standard density everywhere: the desktop default (compact) shrinks
  // buttons to 32 px, below the 44 px target (1.6 finding 9).
  final buttonStyle = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(
      Size(ChurchGeometry.minTarget, ChurchGeometry.buttonHeight),
    ),
    visualDensity: VisualDensity.standard,
    shape: WidgetStatePropertyAll(buttonShape),
  );
  OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(inputRadius),
    borderSide: BorderSide(color: color, width: width),
  );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bg,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    extensions: [c, layout],
    textTheme: Typography.material2021(platform: TargetPlatform.android)
        .englishLike
        .apply(bodyColor: c.ink, displayColor: c.ink)
        .copyWith(
          bodyLarge: layout.body.copyWith(color: c.ink),
          bodyMedium: layout.body.copyWith(color: c.ink),
        ),
    // Keyboard highlight for list/menu items: near-solid accent, >=3:1
    // against the unfocused item (1.6 finding 4).
    focusColor: c.focus.withValues(alpha: 0.85),
    appBarTheme: AppBarTheme(
      backgroundColor: headerBackground ?? c.bg,
      foregroundColor: c.brand,
      titleTextStyle: title.copyWith(color: c.brand),
      titleSpacing: titleSpacing,
      centerTitle: false,
      shape: headerBackground == null
          ? null
          : Border(bottom: BorderSide(color: c.line)),
      elevation: 0,
      scrolledUnderElevation: 0,
      // Room for a 48 px action plus its outside focus ring.
      toolbarHeight: 64,
    ),
    cardTheme: CardThemeData(
      color: c.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: c.line),
        borderRadius: BorderRadius.circular(ChurchGeometry.mobileCardRadius),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(style: buttonStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(style: buttonStyle),
    textButtonTheme: TextButtonThemeData(style: buttonStyle),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(
          Size.square(ChurchGeometry.minTarget),
        ),
        foregroundColor: WidgetStatePropertyAll(c.brand),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface,
      border: border(c.muted, 1),
      enabledBorder: border(c.muted, 1),
      disabledBorder: border(c.line, 1),
      // One px wider than the ring: a 4 px focused border (1.6 finding 4).
      focusedBorder: border(c.focus, ChurchGeometry.focusRingWidth + 1),
      errorBorder: border(c.redFg, 2),
      focusedErrorBorder: border(c.redFg, ChurchGeometry.focusRingWidth + 1),
      labelStyle: TextStyle(color: c.muted),
      floatingLabelStyle: TextStyle(color: c.ink),
      errorStyle: TextStyle(color: c.redFg, fontSize: 14),
      errorMaxLines: 4,
      helperMaxLines: 4,
    ),
    dividerTheme: DividerThemeData(color: c.line),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.primary),
  );
}
