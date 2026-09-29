# Work history — condensed timeline

Source docs (full detail, read before relying on a specific line/file
reference): [`WORK_SUMMARY.md`](../../WORK_SUMMARY.md) (2026-08-12),
[`WORK_SUMMARY_2026-09-03.md`](../../WORK_SUMMARY_2026-09-03.md),
[`WORK_SUMMARY_2026-09-09.md`](../../WORK_SUMMARY_2026-09-09.md),
[`WORK_SUMMARY_2026-09-13.md`](../../WORK_SUMMARY_2026-09-13.md). This file
is a chronological "how did we get here" index — for the current state of
a system (roles, platform split), prefer [`role-model.md`](role-model.md)
/ [`platform-ui.md`](platform-ui.md), which are kept current; treat this
file as history, not a live spec.

## 2026-08-12 — Web dashboard parity (`WORK_SUMMARY.md`)

Brought the web/desktop dashboard to parity with mobile: introduced
`DashboardViewModel` as the shared RTDB-listener/derived-state layer,
added the conditional `DashboardPage` mobile/web split, built the web
side nav (`IndexedStack`-based, so tab state persists), matched mobile's
gradient energy card and building-card styling. Flagged but not fixed at
the time: mobile's `DashboardScreen` still had its own in-file listeners
instead of using the shared view-model.

## 2026-09-03 — Web fixes, routing, institute-admin model
(`WORK_SUMMARY_2026-09-03.md`)

- Fixed a `_SideNavButton` compile error and a dead (never-cancelled)
  Firebase listener in `DashboardViewModel`; un-gated Automation for
  non-admins on web to match mobile.
- Added `ResponsiveCenter` (`lib/widgets/responsive_center.dart`) and
  `responsiveColumnCount()` — the shared 700px-breakpoint responsive
  helpers used across web and the shared building-floor/device-detail
  screens. Mobile behavior is untouched below that breakpoint.
- Replaced the synchronous `FirebaseAuth.instance.currentUser` login gate
  (which raced Firebase Auth's async web session restore) with
  `lib/screens/shared/auth_gate.dart`, using `authStateChanges()`.
- Extended `database.rules.json` to recognize the full 5-role hierarchy
  (previously only literal `'admin'` was recognized server-side) — see
  [`role-model.md`](role-model.md) for the current state of this, since
  it's evolved further since.
- Introduced the `users/{uid}/institute` field and built
  `manage_users_screen.dart` (main-admin sees all institutes; institute
  admin sees only their own, can manage co-admins). Added per-institute
  color theming (`lib/theme/institute_colors.dart`). Ported the same
  institute-admin model to mobile (`dashboard_screen.dart`) for parity.
- **Explicitly flagged as an unresolved gap at the time**: rules were not
  yet institute-scoped, only role-tier-scoped — still true today, see
  [`role-model.md`](role-model.md).

## 2026-09-09 — Skeleton loading (retrospective spec) (`WORK_SUMMARY_2026-09-09.md`)

Written by `joren` *after* the feature shipped (backfilling a requirements
pass that didn't happen before `don`/`rhose` built it) — a good example of
why joren's "spec before build" pass matters. Documents:

- The bug: every RTDB-reading screen treated a transient
  `snapshot.value == null` as real data loss, flashing fields to
  blank/zero on rebuilds/reconnects, not just genuine data loss.
- The fix: `ScreenSkeleton` (`lib/widgets/screen_skeleton.dart`,
  `Skeletonizer`-based shimmer) + `lib/utils/placeholder_data.dart`
  placeholder builders, combined with a per-screen
  `Rx.combineLatestList` pattern across 9 logical screens (18 files
  counting mobile/web pairs) that only resets fields to empty while still
  in first-load state; once loaded, a later null/error snapshot is
  ignored and the last-known-good value is kept.
- **Known, still-relevant gap (Finding 1)**: 7 of 9 screens
  (dashboard, settings, manage-users, campus map, building floor, device
  detail, history) swallow a sustained load error and never flip their
  loading flag — the skeleton spins forever with no error/retry UI. Only
  automation and notifications got a graceful error floor. If you touch
  any of those 7 screens' RTDB-loading logic, this is the first thing to
  check/fix alongside whatever else you're doing.
- **Known platform difference (Finding 2, not a bug)**: web's
  `IndexedStack`-hosted tabs (History/Automation/Notifications/Settings/
  Manage Users) never recreate their `State`, so their skeleton only shows
  once per browser session; mobile's `Navigator.push`-reached versions of
  the same screens re-show the skeleton on every re-visit. Expected given
  each platform's navigation model, but looks like an inconsistency in a
  side-by-side demo — worth knowing before someone "fixes" it as a bug.

## 2026-09-13 — Session timeout, hard delete, security audit
(`WORK_SUMMARY_2026-09-13.md`)

- Added a 20-minute inactivity auto-logout
  (`lib/widgets/idle_timeout_wrapper.dart`), armed only while signed in,
  using both a `Timer` and wall-clock checks on app resume (since a
  backgrounded app's `Timer` isn't reliable, especially iOS).
- Wired `manage_users_screen.dart`'s delete/password-change actions to two
  **pre-existing but previously unused** Cloud Functions (`deleteUser`,
  `changeUserPassword` in `functions/index.js`) instead of a
  database-only "delete" (which left the Firebase Auth account alive and
  the email permanently unregisterable) and a plaintext
  `passwordReset` field. Added a shared `assertCanManageUser` authorization
  helper server-side, matching the role/institute scoping rules.
- Ran a full security audit of the login/auth flow; one finding (an
  `institute_admin` self-escalation path via direct `users/$uid` writes)
  was patched immediately since it undermined this session's own fix.
  **Everything else in the audit is unfixed** — see
  [`role-model.md`](role-model.md)'s "Known, currently-unfixed gap"
  sections, which fold in the Critical/High findings from this audit
  (server-side email-domain enforcement, institute-scoped rules,
  `writeKey` not actually checked, no `revokeRefreshTokens` call, account
  enumeration via login error messages, no App Check, plaintext
  "remember me" password storage, Cloud Functions with no
  `maxInstances`/cost guardrails).

## What this means for new work

Before starting a task that touches roles, auth, or `database.rules.json`,
read [`role-model.md`](role-model.md)'s gap list — several of the
"unfixed" items above are still open today and should factor into scope
discussions (e.g. don't build a new admin feature on top of the
non-institute-scoped rules without at least flagging that it inherits the
same gap).
