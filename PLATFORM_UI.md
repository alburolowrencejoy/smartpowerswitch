# Platform-specific UI (one app, different design per platform)

This document explains how to keep a single Flutter app and backend while providing different UI/UX on web/desktop vs mobile.

## Goal
- One codebase and single backend (Firebase) shared by all platforms.
- Different visual/layout implementations for web/desktop and mobile while using the same data providers and routing names.

## Two recommended approaches

### Option A — Compile-time conditional imports (recommended)
- Create a wrapper export `dashboard_page.dart` that conditionally exports the mobile or web implementation:

```dart
// lib/screens/dashboard_page.dart
export 'dashboard_mobile.dart' if (dart.library.html) 'dashboard_web.dart';
```

- Implement `lib/screens/dashboard_mobile.dart` (thin file that reuses the existing `DashboardScreen`).
- Implement `lib/screens/dashboard_web.dart` (desktop/web layout which consumes the same providers/viewmodels).
- Use `DashboardPage` in your routes (e.g. `'/dashboard': (c) => const DashboardPage()`).

Pros: clean separation, web build contains only web UI; no runtime branching needed.

### Option B — Runtime switch (quick)
- Branch at runtime using `kIsWeb`, `defaultTargetPlatform`, or `LayoutBuilder`/`MediaQuery`:

```dart
Widget build(BuildContext context) {
  if (kIsWeb) return DashboardWeb();
  final width = MediaQuery.of(context).size.width;
  if (width > 900) return DashboardDesktop();
  return DashboardMobile();
}
```

Pros: simple to add and supports switching when the window resizes on desktop.

## Keep data and routing shared
- Move Firebase listeners and parsing logic into a service or view-model under `lib/services/` or `lib/viewmodels/`.
- Provide the same view-model to both web and mobile pages via `Provider` / `ChangeNotifierProvider` or by passing it through constructor args.

Example (route wiring):

```dart
Navigator.push(context, MaterialPageRoute(
  builder: (_) => ChangeNotifierProvider(
    create: (_) => DashboardViewModel(),
    child: const DashboardPage(),
  ),
));
```

Both `dashboard_mobile.dart` and `dashboard_web.dart` read from the same `DashboardViewModel` so they show identical data with different layouts.

## Files to add (example)
- `lib/screens/dashboard_page.dart` (wrapper export)
- `lib/screens/dashboard_mobile.dart` (uses existing `DashboardScreen`)
- `lib/screens/dashboard_web.dart` (new web/desktop layout)
- (Optional) `lib/viewmodels/dashboard_viewmodel.dart` — move non-UI logic here.

## Routing update
- Replace route target in `lib/main.dart` from `DashboardScreen` to `DashboardPage`:

```diff
- '/dashboard': (_) => const DashboardScreen(),
+ '/dashboard': (_) => const DashboardPage(),
```

## Build & hosting notes
- Web build:

```bash
flutter build web --release
```

- Deploy web app (example using Firebase Hosting — project already has `firebase.json` with `app` and `promo` targets):

```bash
firebase deploy --only hosting:app
```

- Mobile builds are distributed via Play Store / App Store as usual (`flutter build apk` / `flutter build appbundle` / `flutter build ios`).

## Tips & recommendations
- Prefer `conditional imports` if you want entirely different UI trees per platform.
- Prefer `runtime switch` when you want a single widget to adapt to window size or when you expect frequent runtime layout changes.
- Keep business logic (Firebase listeners, parsing, data transformations) outside UI code for easy reuse.
- Reuse small UI components (cards, charts) between web and mobile when possible.

## Next steps
- I can create the three example files and update the route (`dashboard_page.dart`, `dashboard_mobile.dart`, `dashboard_web.dart`) and optionally extract a `DashboardViewModel`. Reply `yes` to proceed.
