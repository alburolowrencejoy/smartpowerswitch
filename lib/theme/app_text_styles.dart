import 'package:flutter/material.dart';
import 'app_fonts.dart';

/// The mobile redesign's type scale (handoff §3.4, cross-checked against
/// `smartswitch-mobile-preview.html`'s CSS for exact px/line-height/weight).
///
/// None of these constants bake in a text color -- the doc ties color to
/// *role* (ink/ink-mid/ink-muted/placeholder/disabled, see [AppColors]) far
/// more often than to a fixed size, and several sizes are reused with
/// different colors in different places (e.g. `bodySm` is `ink-mid` in some
/// rows and `ink-muted` in others). Callers should `.copyWith(color: ...)`.
///
/// Every style always carries `fontFamily: AppFonts.family` -- never a
/// string literal -- per CLAUDE.md.
class AppTextStyles {
  AppTextStyles._();

  static const _family = AppFonts.family;

  /// 36/40, weight 700. Hero number (e.g. the energy-today big figure).
  static const display = TextStyle(
    fontFamily: _family,
    fontSize: 36,
    height: 40 / 36,
    fontWeight: FontWeight.w700,
  );

  /// 22/28, weight 700. Generic large title, off the top bar (e.g. a big
  /// section title). See [topBarTitle] for the top-bar-specific promotion
  /// to 24/30.
  static const titleLg = TextStyle(
    fontFamily: _family,
    fontSize: 22,
    height: 28 / 22,
    fontWeight: FontWeight.w700,
  );

  /// Home-only dashboard title, 30/36, weight 700 (handoff §3.4 "Dashboard
  /// title" row / preview `.dev .topbar.big h1`).
  static const dashboardTitle = TextStyle(
    fontFamily: _family,
    fontSize: 30,
    height: 36 / 30,
    fontWeight: FontWeight.w700,
  );

  /// Date line under the Home dashboard title, 15/20 (handoff §3.4).
  static const dashboardDate = TextStyle(
    fontFamily: _family,
    fontSize: 15,
    height: 20 / 15,
    fontWeight: FontWeight.w400,
  );

  /// Top bar title on root tabs (Home/Devices/Analytics/Automation/More,
  /// non-Home): 24/30 weight 700 -- preview `.topbar h1` (final/`.dev`
  /// cascade, not the older draft `:root` value).
  static const topBarTitle = TextStyle(
    fontFamily: _family,
    fontSize: 24,
    height: 30 / 24,
    fontWeight: FontWeight.w700,
  );

  /// Top bar title on pushed/back screens (Device detail, Schedule editor,
  /// Notifications, Users, Settings, Building, ...): 19/24 weight 700 --
  /// preview `.topbar.small h1` (final `.dev` cascade overrides the weight
  /// to 700; an earlier draft rule in the same file has it at 600).
  static const topBarTitleSmall = TextStyle(
    fontFamily: _family,
    fontSize: 19,
    height: 24 / 19,
    fontWeight: FontWeight.w700,
  );

  /// Bottom-sheet / two-step-delete-dialog header title: 20/26 weight 700
  /// (preview `.sheet .s-head h3`, `.dl-card h3`). Not itself a row in the
  /// handoff §3.4 table, but needed verbatim by the shared bottom sheet
  /// scaffold and delete dialog built this phase.
  static const sheetTitle = TextStyle(
    fontFamily: _family,
    fontSize: 20,
    height: 26 / 20,
    fontWeight: FontWeight.w700,
  );

  /// 24/28, weight 700. KPI values / stat figures.
  static const stat = TextStyle(
    fontFamily: _family,
    fontSize: 24,
    height: 28 / 24,
    fontWeight: FontWeight.w700,
  );

  /// 18/24, weight 600. Section titles (e.g. "Manage IC", "Today", "Next
  /// up") -- preview `.sec-head h2`.
  static const title = TextStyle(
    fontFamily: _family,
    fontSize: 18,
    height: 24 / 18,
    fontWeight: FontWeight.w600,
  );

  /// 16/22, weight 600. List-row primary text -- preview `.row .r-title`,
  /// `.card-title`.
  static const subtitle = TextStyle(
    fontFamily: _family,
    fontSize: 16,
    height: 22 / 16,
    fontWeight: FontWeight.w600,
  );

  /// 15/22, weight 400. Message-style body text.
  static const body = TextStyle(
    fontFamily: _family,
    fontSize: 15,
    height: 22 / 15,
    fontWeight: FontWeight.w400,
  );

  /// 14/20, weight 400. Secondary/detail text -- preview `.row .r-sub`,
  /// `.n-msg`.
  static const bodySm = TextStyle(
    fontFamily: _family,
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w400,
  );

  /// 14/20, weight 600. Buttons, chips, section labels -- preview `.btn`,
  /// `.chip`, `.s-label`.
  static const label = TextStyle(
    fontFamily: _family,
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w600,
  );

  /// 13/18, weight 500. Captions -- KPI footers, units, notification times,
  /// forecast labels, reading labels.
  static const caption = TextStyle(
    fontFamily: _family,
    fontSize: 13,
    height: 18 / 13,
    fontWeight: FontWeight.w500,
  );

  /// 12/16, weight 500. The one caption exception the handoff calls out by
  /// name: floor labels ("floor = 12sp").
  static const captionSmall = TextStyle(
    fontFamily: _family,
    fontSize: 12,
    height: 16 / 12,
    fontWeight: FontWeight.w500,
  );

  /// Applies `FontFeature.tabularFigures()` per handoff §3.4 ("Numbers use
  /// tabular figures"). Apply to any style when the text it renders is a
  /// number (kWh figures, currency, percentages, clock times, etc.) --
  /// tabular figures are not baked into the base styles above because many
  /// of them (e.g. [title], [subtitle]) render non-numeric text too.
  static TextStyle tabularFigures(TextStyle style) => style.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// Convenience: [display] with tabular figures, for the hero kWh number.
  static final displayTabular = tabularFigures(display);

  /// Convenience: [stat] with tabular figures, for KPI values.
  static final statTabular = tabularFigures(stat);
}
