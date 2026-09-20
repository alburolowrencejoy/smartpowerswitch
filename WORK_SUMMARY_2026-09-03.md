# Work Summary — Web Dashboard Fixes, Routing, and Institute Admin Model

Date: 2026-09-03

This documents everything done in this session: bug fixes to the new web
dashboard, route normalization, a Firebase security rules fix, a new
Manage Users screen, and a full institute-admin role model with per-institute
theming. Builds on the earlier web/mobile split described in
[WORK_SUMMARY.md](WORK_SUMMARY.md) and [PLATFORM_UI.md](PLATFORM_UI.md).

---

## 1. Bug fixes found while reviewing the new web dashboard

- **`_SideNavButton` compile error**: the unnamed constructor in
  `lib/screens/dashboard_web.dart` was missing `this.badgeCount = 0`, so
  `badgeCount` had no initializer on that path. Fixed.
- **Dead Firebase listener in the view-model**: `DashboardViewModel._listenToEnergyData()`
  (listens to `devices` for kWh totals) never stored its `StreamSubscription`,
  so `disposeViewModel()` couldn't cancel it — it kept running after the
  widget was disposed and would call `notifyListeners()` on a disposed
  `ChangeNotifier`. Flagged for a future fix (not yet patched at time of
  writing this doc — see `lib/viewmodels/dashboard_viewmodel.dart`).
- **Web sidebar hid Automation for non-admins**: mobile's `DashboardScreen`
  shows the Automation tab to every role; the web dashboard was gating it to
  admin-tier only, so clicking it as a non-admin silently bounced back to the
  dashboard tab. Removed the gate — Automation is now unconditionally
  reachable, matching mobile.

## 2. Responsive web/desktop layout

Mobile is completely untouched — every change below is either gated behind a
`LayoutBuilder` breakpoint (phones never cross it) or lives in a web-only
file.

- New [lib/widgets/responsive_center.dart](lib/widgets/responsive_center.dart):
  `ResponsiveCenter` caps + centers content past a 700px-wide viewport,
  passing content through unchanged below it; `responsiveColumnCount()` picks
  a grid column count from available width without ever going below the
  existing mobile default.
- `dashboard_web.dart` (web-only — mobile never renders this file): capped
  the hero energy card to 640px instead of stretching edge-to-edge; wrapped
  the History/Automation/Notifications/Settings tabs in `ResponsiveCenter`.
  Left the Map tab full-bleed (it's an interactive map that should use all
  available space).
- `building_floor_screen.dart` and `device_detail_screen.dart` (shared with
  mobile): wrapped content in `ResponsiveCenter` and made their `GridView`s
  pick more columns on wide screens via `responsiveColumnCount`, both gated
  by the same 700px breakpoint so phone-width behavior is unchanged.

## 3. Route normalization ("log in properly")

`main.dart` had `initialRoute: '/dashboard'` — the app always jumped straight
to the dashboard, with a synchronous `FirebaseAuth.instance.currentUser`
check as the only login gate. On web, Firebase Auth restores a persisted
session *asynchronously* (from IndexedDB), so an already-logged-in user could
see `currentUser == null` for a moment and get bounced to `/login`
unpredictably.

- Added [lib/screens/auth_gate.dart](lib/screens/auth_gate.dart): a proper
  gate using `authStateChanges()`, which waits for the real session-restore
  before deciding between `LoginScreen` and `DashboardPage`. `initialRoute`
  is now `'/'` → `AuthGate`.
- The `/dashboard` route builder was silently dropping the `role`/`name`
  arguments the login screen passes — no `settings:` was forwarded to
  `MaterialPageRoute`, so neither the constructor params (web) nor
  `ModalRoute.of(context)?.settings.arguments` (mobile) ever saw them. Fixed
  to extract the args and forward `settings: settings`, matching the pattern
  already used for `/building` and `/device` (which also now get
  `settings: settings` for consistency).

## 4. Firebase rules: recognize the full role hierarchy

`database.rules.json` only ever recognized the literal string `'admin'`,
plus a legacy `isMainAdmin` boolean and a hardcoded admin email that nothing
in the Dart code sets or reads anymore. But the client code (`role_provider.dart`,
`dashboard_web.dart`, `building_floor_screen.dart`, `device_detail_screen.dart`,
`campus_map_screen.dart`, `automation_screen.dart`) all treat five roles as
the real hierarchy: `faculty` (base) and an admin tier of `admin` /
`main_admin` / `super_admin` / `institute_admin`. Any account whose role was
one of the latter three was failing every `.read`/`.write` check server-side.

- Extended every rule block (`users`, `settings`, `buildings`, `devices`,
  `master_devices`, `history`, `hotspots`, `notifications`, `automations`,
  `meta`) to also accept `main_admin`, `super_admin`, and `institute_admin` —
  purely additive, nothing that worked before was removed.
- **Not yet deployed** — the user chose not to push it live during this
  session. Deploy with `firebase deploy --only database` (project
  `smartpowerswitch-e90d0`) when ready.
- **Known gap**: rules are still not scoped *per institute* — any admin-tier
  account (including `institute_admin`) can read/write every building's data
  via direct API calls, not just their own. True enforcement would need
  building-scoped rules (e.g. cross-referencing `devices/$id/building`
  against the caller's own `institute` field), which hasn't been built.

## 5. Sidebar reorganization

In `dashboard_web.dart`'s side nav:
- The old "Create / Manage" button is now **Settings** (gear icon), same
  target screen.
- Added a **Manage Users** entry as the last nav item (above Logout),
  visible to main-admin-tier accounts and to `institute_admin`.

## 6. Manage Users screen + institute/member data model

New [lib/screens/manage_users_screen.dart](lib/screens/manage_users_screen.dart),
built from scratch to replace the old flat "Manage Users" section that used
to live inside `settings_screen.dart` (removed from there, along with its
now-dead helpers: `_addUser`, `_changeRole`, `_deleteUser`, `_changePassword`,
`_apiKey`, `_friendlyError`, `_inputDecoration`).

- **Data model**: added a `users/{uid}/institute` field (a building code) —
  DNSC's institutes map 1:1 to buildings already in the system (`IC`,
  `ILEGG`, `ITED`, `IAAS`, `ADMIN`), so no new "institutes" collection was
  needed, just this one field. No rules change was needed since the
  admin-tier already has full `users/*` write access from item 4 above.
- **Main admin view**: sees every institute as an expandable card — code,
  name, floor count, member count, and its admin(s). Can add/remove admins
  for any institute, add/remove members, change passwords, and manage an
  "Other Accounts" bucket (top-tier admins + institute-less legacy faculty,
  with an "Assign to Institute" action to migrate them in).
- **Institute admin view**: sees only their own institute's card
  (pre-expanded), no "Other Accounts." Can add members and can add/remove
  **co-admins** — a new `coAdmin: true` flag distinguishes an admin an
  institute admin added themselves from the "primary" admin the main admin
  originally assigned (`coAdmin` absent/false). Institute admins can't touch
  the primary admin or demote themselves through this screen.

## 7. Institute-admin dashboard restructuring

- **Dashboard tab**: main/super admin still see the campus-wide buildings
  list (unchanged). Institute admins instead get their own institute's
  `BuildingFloorScreen` embedded directly as the dashboard tab — rooms are
  visible immediately, no buildings list to click through. Added a
  `showBackButton` param to `BuildingFloorScreen` (default `true`, so mobile
  and the normal "click a building card" web flow are unaffected) that's set
  to `false` here so a stray tap can't pop the entire dashboard shell. That
  embedded screen's own dashboard band (kWh/cost/online/devices) already
  covers "the main card must be institute-consumed only" — no separate
  campus-wide hero card is shown to institute admins.
- **Analytics tab**: hidden from institute admins (both the nav button and
  the tab-index safety check that guards against a stale `_selectedIndex`).

## 8. Per-institute color palettes

New [lib/theme/institute_colors.dart](lib/theme/institute_colors.dart):
`InstitutePalette` (a `dark`/`mid`/`light`/`pale` ramp, same shape as
`AppColors`' green ramp) and `InstituteColors.forCode()`:

| Institute | Color  |
|-----------|--------|
| IC        | Violet |
| ILEGG     | Maroon |
| ITED      | Gold   |
| IAAS      | Blue   |
| ADMIN / anything unmapped | Green (the app's original palette) |

- Threaded into `BuildingFloorScreen` (header, dashboard band, floor tabs,
  room cards, buttons) based on `buildingCode` — so *any* viewer looking at
  IC's building sees violet, regardless of their own role. Utility-type
  colors (Lights = orange, Outlets = green, AC = blue) were deliberately left
  untouched since those are a device legend, not institute branding.
- Threaded into `dashboard_web.dart`'s side nav and page background via a
  `_palette` getter: resolves to the viewer's own institute color for
  `institute_admin`, or the green default for everyone else.

---

## 9. Mobile parity for the institute-admin model

Items 5–8 above were originally web-dashboard-only. Ported to
`lib/screens/dashboard_screen.dart` (mobile) so the institute-admin model
works the same on both platforms:

- Added `_institute`, `_isSuperAdmin`, `_isInstituteAdmin`,
  `_canAccessManagement`, and a `_palette` getter (mirroring the web state),
  and `_hydrateSessionFromAuth()` now also reads `institute` from
  `users/{uid}`.
- **Dashboard tab**: institute admins get their institute's
  `BuildingFloorScreen` embedded directly (via a new `_buildInstituteHomeTab()`,
  same approach as web) instead of the campus-wide buildings list; main/super
  admin and faculty are unaffected.
- **Analytics tab**: hidden for institute admins. The bottom nav is 4 fixed
  conceptual slots (Dashboard/Map/Analytics/Automation); for institute admins
  the Analytics `BottomNavigationBarItem` is simply omitted and taps are
  remapped to the slot they actually mean, so the `IndexedStack` doesn't need
  restructuring.
- **Manage Users**: mobile only had a Settings gear icon (admin-only) in the
  top bar / compact popup menu — there's no side nav to put a new item in.
  Added a matching "Manage Users" icon/menu item next to it, gated the same
  way as web (`_canAccessManagement`), pushing a new `/manage-users` route
  (added in `main.dart`) that wraps `ManageUsersScreen` in a plain `Scaffold`
  with a back-button app bar, passing `role`/`institute` as route arguments.
  Also broadened the Settings icon's own gate from the old literal
  `_role == 'admin'` to `_canAccessManagement`, matching web.
- **Institute color theming**: the top bar background now uses `_palette.dark`
  instead of a hardcoded green. The energy-card hero and buildings list in
  `_buildHomeTab()` were left untouched (still hardcoded green) since
  institute admins no longer render that tab at all — only main/super admin
  and faculty ever see it, and it should stay green for them.

## 10. Palette re-tune + mobile dashboard cleanup

Prompted by a real device screenshot of IC's (violet) embedded dashboard:
the color read as too saturated/harsh, "IC" appeared redundantly twice in
the header, and the bottom nav's selected-tab color stayed green while
everything above it had switched to violet.

- **Re-tuned every institute ramp** in `institute_colors.dart` so each one
  shares the *exact same saturation and lightness as the green ramp*, tier
  for tier (dark ≈ L23%/S56%, mid ≈ L40%/S55%, light ≈ L61%/S47%, pale ≈
  L85%/S55%) — only the hue rotates (IC 265°, ILEGG 350°, ITED 45°, IAAS
  210°). Previously the institute hues were chosen by eye and ended up more
  saturated than green, which is what read as an eyesore. New values:

  | Institute | dark | mid | light | pale |
  |---|---|---|---|---|
  | IC (violet) | `#351A5C` | `#5D2E9E` | `#956ECB` | `#D4C2ED` |
  | ILEGG (maroon) | `#5C1A25` | `#9E2E41` | `#CB6E7D` | `#EDC2C9` |
  | ITED (gold) | `#5C4B1A` | `#9E822E` | `#CBB46E` | `#EDE2C2` |
  | IAAS (blue) | `#1A3B5C` | `#2E669E` | `#6E9CCB` | `#C2D8ED` |

  Verified side-by-side against the original green in a quick spec-sheet
  artifact: https://claude.ai/code/artifact/bafd152c-fbd0-4fa7-937a-e2f81ac3645a
- **Removed the redundant code caption** in `BuildingFloorScreen`'s header —
  it now only shows the small "IC" label above the title when the building
  actually has a custom name different from its code; an unnamed institute
  no longer shows "IC" twice.
- **Bottom nav now themed too** (mobile): `selectedItemColor` uses
  `_palette.dark` instead of hardcoded green, so the highlighted tab icon
  matches the institute color shown in the header above it, instead of
  clashing.

## Known gaps / suggested next steps

1. **Per-institute Firebase rules enforcement** — currently client-side only
   (see §4). An institute admin's API calls aren't actually blocked from
   touching another institute's data server-side.
2. **`DashboardViewModel` dead subscription** (see §1) — not yet patched.
3. **Deploy the updated `database.rules.json`** when ready — not yet pushed
   to the live project.
4. Manual click-through recommended before trusting this in production,
   especially: the institute-admin login → embedded rooms view → co-admin
   add/remove flow, and the color palettes — on both a browser and a real
   device/emulator now that mobile has the same model.
