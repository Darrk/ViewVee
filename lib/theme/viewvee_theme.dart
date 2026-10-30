import 'package:flutter/material.dart';

export '../localization/viewvee_localizations.dart';

abstract final class ViewVeeColors {
  static const navy = Color(0xFF08162F);
  static const teal = Color(0xFF09BFAF);
  static const logoBlue = Color(0xFF168FE5);
  static const blue = Color(0xFF2E8DDF);
  static const violet = Color(0xFF6537E8);
  static const canvas = Color(0xFFF5F7FC);
  static const surface = Colors.white;
  static const outline = Color(0xFFDCE2EF);
  static const muted = Color(0xFF5C667A);
}

ThemeData buildViewVeeTheme() {
  const colors = ColorScheme.light(
    primary: ViewVeeColors.navy,
    onPrimary: Colors.white,
    primaryContainer: Color(0xFFE4F8F6),
    onPrimaryContainer: ViewVeeColors.navy,
    secondary: ViewVeeColors.teal,
    onSecondary: ViewVeeColors.navy,
    secondaryContainer: Color(0xFFDDF8F5),
    onSecondaryContainer: ViewVeeColors.navy,
    tertiary: ViewVeeColors.violet,
    onTertiary: Colors.white,
    tertiaryContainer: Color(0xFFEDE8FF),
    onTertiaryContainer: ViewVeeColors.navy,
    surface: ViewVeeColors.surface,
    onSurface: ViewVeeColors.navy,
    onSurfaceVariant: ViewVeeColors.muted,
    outline: ViewVeeColors.outline,
    error: Color(0xFFB3261E),
    onError: Colors.white,
  );

  final roundedShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(8),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    scaffoldBackgroundColor: ViewVeeColors.canvas,
    fontFamily: 'Avenir Next',
    appBarTheme: const AppBarTheme(
      backgroundColor: ViewVeeColors.surface,
      foregroundColor: ViewVeeColors.navy,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: ViewVeeColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: ViewVeeColors.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: ViewVeeColors.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: ViewVeeColors.blue, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: ViewVeeColors.navy,
        foregroundColor: Colors.white,
        shape: roundedShape,
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ViewVeeColors.navy,
        side: const BorderSide(color: ViewVeeColors.outline),
        shape: roundedShape,
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    cardTheme: CardThemeData(
      color: ViewVeeColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: roundedShape.copyWith(
        side: const BorderSide(color: ViewVeeColors.outline),
      ),
    ),
    dividerColor: ViewVeeColors.outline,
    sliderTheme: const SliderThemeData(
      activeTrackColor: ViewVeeColors.violet,
      thumbColor: ViewVeeColors.violet,
      overlayColor: Color(0x226537E8),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.white
            : ViewVeeColors.muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? ViewVeeColors.teal
            : ViewVeeColors.outline,
      ),
    ),
  );
}

ThemeData buildViewVeeDarkTheme() {
  const colors = ColorScheme.dark(
    primary: ViewVeeColors.teal,
    onPrimary: ViewVeeColors.navy,
    primaryContainer: Color(0xFF123C42),
    onPrimaryContainer: Color(0xFFD8FFFB),
    secondary: ViewVeeColors.blue,
    onSecondary: Colors.white,
    secondaryContainer: Color(0xFF173652),
    onSecondaryContainer: Color(0xFFD9EDFF),
    tertiary: Color(0xFF9B7BFF),
    onTertiary: Color(0xFF16064B),
    tertiaryContainer: Color(0xFF312264),
    onTertiaryContainer: Color(0xFFE9E1FF),
    surface: Color(0xFF121C2E),
    onSurface: Color(0xFFF3F6FC),
    onSurfaceVariant: Color(0xFFB6C0D2),
    outline: Color(0xFF35435D),
    error: Color(0xFFFFB4AB),
    onError: Color(0xFF690005),
  );
  final roundedShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(8),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: colors,
    scaffoldBackgroundColor: const Color(0xFF0A1322),
    fontFamily: 'Avenir Next',
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF0E1828),
      foregroundColor: Color(0xFFF3F6FC),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF172338),
      labelStyle: const TextStyle(color: Color(0xFFB6C0D2)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFF35435D)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFF35435D)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: ViewVeeColors.teal, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: ViewVeeColors.teal,
        foregroundColor: ViewVeeColors.navy,
        shape: roundedShape,
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.onSurface,
        side: const BorderSide(color: Color(0xFF35435D)),
        shape: roundedShape,
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    cardTheme: CardThemeData(
      color: colors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: roundedShape.copyWith(
        side: const BorderSide(color: Color(0xFF35435D)),
      ),
    ),
    dividerColor: const Color(0xFF35435D),
    sliderTheme: const SliderThemeData(
      activeTrackColor: Color(0xFF9B7BFF),
      thumbColor: Color(0xFF9B7BFF),
      overlayColor: Color(0x339B7BFF),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? ViewVeeColors.navy
            : colors.onSurfaceVariant,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? ViewVeeColors.teal
            : colors.outline,
      ),
    ),
  );
}
