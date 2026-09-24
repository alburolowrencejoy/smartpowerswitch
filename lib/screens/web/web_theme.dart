import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_fonts.dart';

/// Web-only text colors. The app-wide [AppColors.textMuted] (#7AAA8A) is
/// only ~2.6:1 on white, too faint for the desktop dashboard's small
/// captions, so the web screens use these instead. Mobile keeps AppColors.
class WebColors {
  WebColors._();

  /// Titles, values and table text (same as AppColors.textDark).
  static const ink = AppColors.textDark;

  /// Secondary text (same as AppColors.textMid, ~6:1 on white).
  static const mid = AppColors.textMid;

  /// Captions, hints, axis labels, table headers. ~5.9:1 on white and
  /// ~4.7:1 on the pale green wash, so it stays readable at 12px.
  static const muted = Color(0xFF4F6A58);
}

/// The web shell's theme: the app font ([AppFonts.family]) everywhere, with
/// darker web text colors and web-sized button, tooltip and input text.
/// Applied only inside `DesktopDashboardScreen`, so the mobile UI is untouched.
ThemeData webTheme(ThemeData base) {
  final text = base.textTheme.apply(
    fontFamily: AppFonts.family,
    bodyColor: WebColors.ink,
    displayColor: WebColors.ink,
  );
  return base.copyWith(
    textTheme: text,
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: AppFonts.family),
    tooltipTheme: TooltipThemeData(
      textStyle: const TextStyle(
        fontFamily: AppFonts.family,
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
      decoration: BoxDecoration(
        color: WebColors.ink,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      waitDuration: const Duration(milliseconds: 250),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        textStyle: const TextStyle(
            fontFamily: AppFonts.family,
            fontSize: 14,
            fontWeight: FontWeight.w600),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        textStyle: const TextStyle(
            fontFamily: AppFonts.family,
            fontSize: 14,
            fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      labelStyle: const TextStyle(
          fontFamily: AppFonts.family, fontSize: 14, color: WebColors.mid),
      hintStyle: const TextStyle(
          fontFamily: AppFonts.family, fontSize: 14, color: WebColors.muted),
      helperStyle: const TextStyle(
          fontFamily: AppFonts.family, fontSize: 12.5, color: WebColors.muted),
    ),
  );
}
