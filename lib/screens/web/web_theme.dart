import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../theme/app_colors.dart';

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

/// The web shell's theme: DM Sans for body/UI text (very legible at small
/// sizes) while every `fontFamily: 'Outfit'` heading and number keeps
/// Outfit, the app's display face. Applied only inside
/// `DesktopDashboardScreen`, so the mobile UI is untouched.
ThemeData webTheme(ThemeData base) {
  final text = GoogleFonts.dmSansTextTheme(base.textTheme).apply(
    bodyColor: WebColors.ink,
    displayColor: WebColors.ink,
  );
  return base.copyWith(
    textTheme: text,
    primaryTextTheme: GoogleFonts.dmSansTextTheme(base.primaryTextTheme),
    tooltipTheme: TooltipThemeData(
      textStyle: GoogleFonts.dmSans(
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
        textStyle: GoogleFonts.dmSans(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        textStyle: GoogleFonts.dmSans(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      labelStyle: GoogleFonts.dmSans(fontSize: 14, color: WebColors.mid),
      hintStyle: GoogleFonts.dmSans(fontSize: 14, color: WebColors.muted),
      helperStyle: GoogleFonts.dmSans(fontSize: 12.5, color: WebColors.muted),
    ),
  );
}
