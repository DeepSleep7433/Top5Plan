import 'package:flutter/material.dart';

class AppColors {
  static const blue = Color(0xFF3A6FE8);
  static const blueSoft = Color(0xFFE8EEFD);
  static const bg = Color(0xFFF3F4F6);
  static const surface = Color(0xFFFFFFFF);
  static const muted = Color(0xFF6B7280);
  static const line = Color(0xFFE5E7EB);
  static const success = Color(0xFF2F9E67);
  static const warning = Color(0xFFD98B2B);
  static const danger = Color(0xFFD14B4B);
  static const darkBg = Color(0xFF15171B);
  static const darkSurface = Color(0xFF1E2127);
  static const darkLine = Color(0xFF2C313A);
}

ThemeData buildAppTheme(Brightness brightness, {bool reduceMotion = false}) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.blue,
    brightness: brightness,
  ).copyWith(
    primary: dark ? const Color(0xFF7DA1FF) : AppColors.blue,
    surface: dark ? AppColors.darkSurface : AppColors.surface,
    surfaceContainerHighest: dark ? const Color(0xFF262A32) : const Color(0xFFF0F2F5),
    outline: dark ? AppColors.darkLine : AppColors.line,
    error: AppColors.danger,
    onPrimary: Colors.white,
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? AppColors.darkBg : AppColors.bg,
    fontFamily: 'Microsoft YaHei UI',
    fontFamilyFallback: const [
      'Microsoft YaHei',
      'PingFang SC',
      'Noto Sans CJK SC',
      'Noto Sans SC',
      'Segoe UI',
      'sans-serif',
    ],
    visualDensity: VisualDensity.compact,
    splashFactory: InkSparkle.splashFactory,
  );
  final text = base.textTheme.copyWith(
    headlineLarge: base.textTheme.headlineLarge?.copyWith(
      fontSize: 28,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.6,
    ),
    headlineMedium: base.textTheme.headlineMedium?.copyWith(
      fontSize: 22,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
    ),
    titleLarge: base.textTheme.titleLarge?.copyWith(
      fontSize: 18,
      fontWeight: FontWeight.w600,
    ),
    titleMedium: base.textTheme.titleMedium?.copyWith(
      fontSize: 15,
      fontWeight: FontWeight.w600,
    ),
    bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 14, height: 1.45),
    bodySmall: base.textTheme.bodySmall?.copyWith(fontSize: 12, height: 1.35),
    labelLarge: base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
  );
  return base.copyWith(
    textTheme: text,
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1),
    cardTheme: CardThemeData(
      elevation: 0,
      color: dark ? AppColors.darkSurface : AppColors.surface,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? const Color(0xFF20242B) : AppColors.surface,
      elevation: 12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: dark ? const Color(0xFF20242B) : AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF262A32) : const Color(0xFFF6F7F9),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(9),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(9),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(9),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      hintStyle: TextStyle(
        color: dark ? const Color(0xFF8A93A3) : const Color(0xFF9AA1AC),
        fontSize: 13,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      side: BorderSide(color: scheme.outlineVariant),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    pageTransitionsTheme: reduceMotion
        ? const PageTransitionsTheme(builders: {
            TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
            TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          })
        : const PageTransitionsTheme(builders: {
            TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
            TargetPlatform.android: ZoomPageTransitionsBuilder(),
          }),
  );
}
