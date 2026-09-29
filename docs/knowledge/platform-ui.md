# Platform-specific UI — mobile vs. web/desktop split

Source doc: [`PLATFORM_UI.md`](../../PLATFORM_UI.md) (the original design
proposal). This file describes what's **actually built**, read from the
current `lib/` tree, since the code has moved past the proposal in a few
ways (directory layout, exact breakpoint).

## One codebase, width-based layout switch — not platform-based

`lib/screens/shared/dashboard_page.dart` is the switch. It does **not**
branch on `kIsWeb`/`defaultTargetPlatform` — it branches on available
width via `LayoutBuilder`, so a resized browser window, a native
Windows/macOS/Linux build, and a tablet in landscape all get the desktop
layout once there's room, while a phone (on any platform) always gets the
mobile layout:

```dart
static const double desktopBreakpoint = 900; // lib/screens/shared/dashboard_page.dart

if (constraints.maxWidth >= desktopBreakpoint) {
  return DesktopDashboardScreen(role: role, name: name); // lib/screens/web/dashboard_web.dart
}
return const DashboardScreen(); // lib/screens/mobile/dashboard_screen.dart
```

Both sides read from the same Firebase data/roles/routes; only the layout
differs. `DashboardPage` also gates on `HistoryClock.instance.ensureReady()`
before picking a layout, so history period keys (day/week/month) are
resolved before either screen starts listening.

## Actual directory layout (as of 2026-09-29)

The original `PLATFORM_UI.md` proposal assumed flat files
(`dashboard_mobile.dart`, `dashboard_web.dart` side by side in
`lib/screens/`). The codebase instead organizes by platform into three
subdirectories — this is the layout `don`, `rhose`, and `joren` should
assume:

- `lib/screens/mobile/` — phone-facing screens (`don`'s domain):
  `dashboard_screen.dart`, `automation_screen.dart`,
  `building_floor_screen.dart`, `device_detail_screen.dart`,
  `history_screen.dart`, `more_screen.dart`, `notifications_screen.dart`,
  `room_devices_panel.dart`, `room_devices_screen.dart`,
  `settings_screen.dart`.
- `lib/screens/web/` — desktop/web screens (`rhose`'s domain):
  `dashboard_web.dart`, `automation_screen_web.dart`,
  `building_floor_screen_web.dart`, `campus_map_screen_web.dart`,
  `device_detail_screen_web.dart`, `history_screen_web.dart`,
  `history_trend_panel.dart`, `manage_users_screen_web.dart`,
  `notifications_screen_web.dart`, `settings_screen_web.dart`,
  `web_forecast_cards.dart`, `web_overview_tab.dart`, `web_theme.dart`,
  `web_trend_chart.dart`, `web_widgets.dart`, plus an `analytics/`
  subfolder (`analytics_data.dart`, `analytics_filter.dart`,
  `analytics_filter_bar.dart`, `analytics_focus.dart`, `analytics_ui.dart`,
  `breakdown_panel.dart`, `utility_donut.dart`, `year_comparison.dart`).
- `lib/screens/shared/` — platform-agnostic or switch files:
  `auth_gate.dart`, `campus_map_screen.dart`, `dashboard_page.dart`,
  `login_screen.dart`, `manage_users_screen.dart`, `splash_screen.dart`.

Web-only shared widgets live at the top level of `lib/widgets/`, not in
`lib/screens/web/`: `range_calendar.dart`, `responsive_center.dart`,
`trend_chart_painters.dart`.

## Shared data layer

Firebase listeners and derived state live in `lib/services/` and
`lib/viewmodels/` (e.g. `lib/viewmodels/dashboard_viewmodel.dart`), not in
the screen widgets, so mobile and web consume the same data shape — see
`work-history.md` for how this evolved (the mobile dashboard still has
some in-file listeners not yet routed through the shared view-model; that
gap is documented there, not fixed).

## Build & deploy

- Web build: `flutter build web --release` (PowerShell, not Git Bash — see
  root `CLAUDE.md`).
- Hosting: Firebase Hosting, two targets defined in `firebase.json` — `app`
  (`build/web`) and `promo` (a static `promo/` folder, the marketing page).
  Deploy with `firebase deploy --only hosting:app` (or `hosting:promo`).
- Known issue: the web build has a slow (~20s+) first paint on a
  release build, gated behind external CDN fetches (CanvasKit, Firebase JS
  SDK, fonts) — see [`web-white-screen.md`](web-white-screen.md), not yet
  fixed.
