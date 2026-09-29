# lib/CLAUDE.md

Scoped notes for working inside `lib/`. See the root
[`CLAUDE.md`](../CLAUDE.md) first (Windows test-runner gotcha, UI
conventions — both still apply here) and
[`docs/knowledge/platform-ui.md`](../docs/knowledge/platform-ui.md) for the
full write-up this file summarizes.

## Mobile vs. web split

`lib/screens/` has three subdirectories, not a flat file list:

- `lib/screens/mobile/` — phone screens (`don`'s domain).
- `lib/screens/web/` — desktop/web screens, including a `web/analytics/`
  subfolder (`rhose`'s domain).
- `lib/screens/shared/` — platform-agnostic screens and the layout switch
  itself: `auth_gate.dart`, `campus_map_screen.dart`, `dashboard_page.dart`,
  `login_screen.dart`, `manage_users_screen.dart`, `splash_screen.dart`.

A `*_web.dart` file (or a file under `lib/screens/web/`) is `rhose`'s; its
non-`_web` counterpart under `lib/screens/mobile/` is `don`'s. Don't assume
they share a `State` object or need to change together — per both agents'
own rules, each platform's screen is independent, and a shared bug fix
that touches both should be called out explicitly, not silently bundled
into a one-platform change.

## `dashboard_page.dart` — the width switch

`lib/screens/shared/dashboard_page.dart` picks mobile vs. desktop by
**window width**, not platform: `LayoutBuilder` checks
`constraints.maxWidth >= desktopBreakpoint` (`900`), returning
`DesktopDashboardScreen` (`lib/screens/web/dashboard_web.dart`) above it or
`DashboardScreen` (`lib/screens/mobile/dashboard_screen.dart`) below it. A
resized browser window or a native desktop build can cross this breakpoint
at runtime — don't assume `kIsWeb` tells you which layout is showing.

## Shared data layer

Firebase RTDB listeners and derived state belong in `lib/services/` or
`lib/viewmodels/`, not duplicated inline in a screen — see
`lib/viewmodels/dashboard_viewmodel.dart` as the existing pattern. Known
gap (see `docs/knowledge/work-history.md`): mobile's `dashboard_screen.dart`
still has some listeners that were never migrated to the shared
view-model — don't treat that as the model to copy for new screens.

## UI conventions (enforced by `test/ui_conventions_test.dart`)

Repeated here because it's easy to miss when only skimming `lib/`:
- Never use a raw `TextField`/`TextFormField`. Use `AppTextField`/
  `AppTextFormField` (`lib/widgets/app_text_field.dart`).
- Always `fontFamily: AppFonts.family` (`lib/theme/app_fonts.dart`), never
  a string literal; no `google_fonts`.

## Role/institute checks

If a screen branches on `role` or `institute`, read
[`docs/knowledge/role-model.md`](../docs/knowledge/role-model.md) first —
it documents the actual 5-role model as implemented (not the older 3-role
planning doc) and the current server-side enforcement gaps, which matter
for deciding whether a client-side check alone is sufficient for what
you're building.
