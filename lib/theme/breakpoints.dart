/// Mobile-side responsive breakpoints (handoff §10.1 -- "Open items" item 1,
/// the compact-breakpoint recommendation, implemented now rather than left
/// open).
///
/// This only covers the phone-facing tiers. The phone-vs-desktop split
/// (`DashboardPage.desktopBreakpoint == 900`) already exists in
/// `lib/screens/shared/dashboard_page.dart` and is deliberately NOT
/// duplicated or changed here -- [web] below is just a same-value reference
/// so mobile-side code can reason about "would this width already be on the
/// desktop layout" without importing a shared/dashboard file. If the two
/// ever need to diverge, `DashboardPage.desktopBreakpoint` remains the one
/// that actually controls the phone/desktop switch.
///
/// Ranges (device width in logical pixels / dp):
/// - `< 360`      : compact -- scale down spacing/type/icons.
/// - `360 – 599`  : standard -- today's baseline mobile layout.
/// - `600 – 899`  : tablet -- cap content width (~600dp, centered).
/// - `>= 900`     : web/desktop layout (`DashboardPage.desktopBreakpoint`).
class Breakpoints {
  Breakpoints._();

  /// Below this width, use the compact layout. Moved from the old
  /// hardcoded 380 (see `dashboard_screen.dart`'s previous `isCompact`) down
  /// to 360, per the handoff's explicit recommendation -- so 360dp phones
  /// (Realme 8i and similar budget Android devices, the most common real
  /// width below iPhone-class sizes) get the regular/standard layout, and
  /// only genuinely narrow phones (<360, e.g. the 320dp small preset) go
  /// compact.
  static const double compact = 360;

  /// Start of the tablet tier -- cap content width and center it here.
  static const double tablet = 600;

  /// Same value as `DashboardPage.desktopBreakpoint`. Not the source of
  /// truth for the mobile/desktop layout switch (that constant is) --
  /// provided so mobile-only code can express "at/above the desktop
  /// breakpoint" in terms local to this file.
  static const double web = 900;

  /// Cap used when centering content in the tablet tier (handoff §10.1:
  /// "limit content width ~600 centered"). Pair with the existing
  /// `ResponsiveCenter` widget, e.g.
  /// `ResponsiveCenter(breakpoint: Breakpoints.tablet, maxWidth: Breakpoints.tabletContentMaxWidth, child: ...)`.
  static const double tabletContentMaxWidth = 600;

  static bool isCompact(double width) => width < compact;

  static bool isStandard(double width) => width >= compact && width < tablet;

  static bool isTablet(double width) => width >= tablet && width < web;

  static bool isWeb(double width) => width >= web;
}
