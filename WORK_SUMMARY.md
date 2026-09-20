# Work Summary — Web Dashboard Parity

Date: 2026-08-12

This document summarizes work completed to make the web dashboard match the mobile dashboard UI and behavior, what was changed, how to verify, and recommended next steps.

**Goal**
- Bring the web/desktop dashboard UI and behavior in parity with the mobile dashboard while keeping a shared data layer.

**High-level approach**
- Add a shared `DashboardViewModel` to centralize Realtime DB listeners and derived fields.
- Use a conditional `DashboardPage` split (mobile vs web) and reuse mobile screens where appropriate.
- Keep the side navigation persistent on web using `IndexedStack` and internal state instead of route pushes.

**What I implemented**
- Shared ViewModel
  - `lib/viewmodels/dashboard_viewmodel.dart`: central `ChangeNotifier` that listens to Firebase RTDB and exposes `buildings`, `totalKwh`, `monthlyKwh`, `monthlyCostPhp`, `buildingDeviceCounts`, `buildingEnergy`, `historyData`, `unreadNotificationCount`, and device counts.

- Web dashboard and routing
  - `lib/screens/dashboard_page.dart`: conditional export wrapper (platform-aware) to load web vs mobile dashboard.
  - `lib/screens/dashboard_web.dart`: full web dashboard UI and side navigation, using `DashboardViewModel`.
    - Implemented persistent left side nav (`_SideNavButton`) with badges.
    - Replaced placeholder Analytics/Map tabs with real screens (`HistoryScreen`, `CampusMapScreen`, `AutomationScreen`, `NotificationsScreen`, `SettingsScreen`).
    - Used `IndexedStack` (keeps nav visible when switching sections).

- UI parity & components
  - Replaced two summary cards with a single mobile-style gradient energy card (large kWh + mini-stats). See: [lib/screens/dashboard_web.dart](lib/screens/dashboard_web.dart)
  - Added campus buildings list using viewmodel data and implemented `_WebBuildingCard` (matching mobile card layout and behavior).
  - Added energy level helpers: `_energyLevelForValue` and `_energyColorForLevel` (uses `AppColors` semantic palette).
  - Building rows are now tappable and navigate to `/building` with arguments (code, name, floors, role).

- Styling and color scheme
  - Aligned web colors with mobile palette defined in `lib/theme/app_colors.dart` (used `AppColors.greenDark`, `greenMid`, `greenPale`, `cardBg`, `textMuted`, `textDark`, `warning`, `error`).
  - Adjusted paddings, font sizes, and column widths to avoid overlaps on desktop layout.

- Code cleanup
  - Removed unused import from `lib/main.dart` and removed an unused helper `_statCard` from `lib/screens/dashboard_screen.dart`.

**Files modified / created**
- ViewModel
  - [lib/viewmodels/dashboard_viewmodel.dart](lib/viewmodels/dashboard_viewmodel.dart)

- Web UI
  - [lib/screens/dashboard_web.dart](lib/screens/dashboard_web.dart)
  - (conditional wrapper) [lib/screens/dashboard_page.dart](lib/screens/dashboard_page.dart)

- Mobile (minor cleanup)
  - [lib/screens/dashboard_screen.dart](lib/screens/dashboard_screen.dart)

- Theme
  - [lib/theme/app_colors.dart](lib/theme/app_colors.dart) — used existing color palette across web UI.

**How to verify locally**
1. Run analyzer:

```bash
flutter analyze
```

2. Run the app on Chrome (web):

```bash
flutter run -d chrome
```

3. On the web dashboard:
- Confirm the large gradient energy card appears and shows live kWh and month cost.
- Confirm the campus buildings list shows building cards that match the mobile styling.
- Click a building card — it should navigate to the building page (`/building`).
- Switch tabs on the left nav (Map, Analytics, Automation, Notifications, Settings) — side nav should remain visible.

**Known gaps / next recommended improvements**
- Mobile `DashboardScreen` still uses in-file listeners; consider refactoring it to use `DashboardViewModel` so mobile + web share a single data source.
- Use the actual logged-in user role (instead of the default `'faculty'`) when navigating to building pages. `DashboardViewModel` can be extended to expose role or `main.dart` can pass it into `DashboardPage`.
- Make the web layout responsive: collapse the side nav on narrow widths or stack the energy card above buildings.
- Add hover elevation on building rows and side nav buttons for better web affordance.

**If you want next**
- I can refactor `DashboardScreen` to use the `DashboardViewModel` (larger change).
- I can make the web dashboard responsive with a collapsible side nav.
- I can wire role propagation from auth into the web dashboard (so navigation uses real role).

---
If you want this written as a changelog entry or committed as part of a branch, tell me and I will create a commit message and prepare the changes for commit.