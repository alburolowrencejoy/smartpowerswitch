# Work Summary — Session Timeout, Hard Account Deletion, Auth Security Review

Date: 2026-09-13

This document summarizes three related changes to the auth/login system: a
20-minute inactivity auto-logout, wiring account deletion and password
changes to the (already-existing but unused) Cloud Functions that perform
them correctly, and a full security audit of the login/auth flow.

Related prior doc: [ROLE_HIERARCHY_PLAN.md](ROLE_HIERARCHY_PLAN.md) (the
`admin` / `main_admin` / `super_admin` / `institute_admin` / `faculty` role
model referenced throughout this work).

---

## 1. Problem

1. Sessions never expired from inactivity — a signed-in user stayed logged
   in indefinitely on both mobile and web.
2. "Deleting" a user in Manage Users only removed their Realtime Database
   profile (`users/$uid`). The Firebase Auth account itself was untouched,
   so the account could still sign back in, and its email stayed
   permanently registered and could never be reused for a new account.
3. No structured security review of the login/auth system had been done
   against modern attack classes (credential stuffing, DDoS/cost abuse,
   RTDB-rule bypass, session/token handling, standard pentest checks).

Investigation found that `functions/index.js` already contained two
correctly-implemented Cloud Functions — `deleteUser` and
`changeUserPassword` — using the Firebase Admin SDK properly. The Flutter
client never called either one:

- `manage_users_screen.dart`'s delete action did only
  `FirebaseDatabase.instance.ref('users/$uid').remove()`.
- Its password-change action wrote the **new password in plaintext** to
  `users/$uid/passwordReset`, picked up client-side on the user's next
  login and only then deleted.

So task 2 was largely a wiring fix, plus widening the two functions' role
check (previously `role === 'admin'` only) to match the app's actual role
hierarchy.

---

## 2. What was implemented

### Task 1 — 20-minute inactivity auto-logout

- **New file**: [lib/widgets/idle_timeout_wrapper.dart](lib/widgets/idle_timeout_wrapper.dart)
  — `IdleTimeoutWrapper`, a `StatefulWidget` that:
  - Tracks pointer activity (`Listener` — down/move/signal) and keyboard
    activity (`HardwareKeyboard` handler), resetting a 20-minute `Timer` on
    any event.
  - Only arms the timer while `FirebaseAuth.instance.authStateChanges()`
    reports a signed-in user.
  - Uses `WidgetsBindingObserver.didChangeAppLifecycleState` to check
    elapsed wall-clock time on `resumed`, since a backgrounded/suspended
    app (especially iOS) won't reliably keep a `Timer` firing.
  - On timeout: stops `AutomationSchedulerService`, calls
    `FirebaseAuth.instance.signOut()` (a real sign-out, matching the
    existing manual-logout pattern in `settings_screen.dart`), then
    navigates to `/login` via a root `GlobalKey<NavigatorState>`, clearing
    the nav stack and passing `{'forceLogoutReason': 'inactivity'}`.
- [lib/main.dart](lib/main.dart) — added a `navigatorKey` to `MaterialApp`
  and wrapped the whole app via `MaterialApp.builder`, so every
  authenticated route is covered by one timer instead of just the initial
  `AuthGate` instance.
- [lib/screens/shared/login_screen.dart](lib/screens/shared/login_screen.dart)
  — reads the force-logout reason from route arguments and shows an info
  card ("You were signed out after 20 minutes of inactivity.") above the
  login form.

### Task 2 — Hard account deletion + secure password changes

- [functions/index.js](functions/index.js) — added a shared
  `assertCanManageUser(callerUid, targetUid)` authorization check, used by
  both `deleteUser` and `changeUserPassword`:
  - `admin` / `main_admin` / `super_admin` / `isMainAdmin` — unrestricted.
  - `institute_admin` — only for target users in the caller's own
    institute (looked up from `users/$uid/institute` on both sides).
- [lib/screens/shared/manage_users_screen.dart](lib/screens/shared/manage_users_screen.dart):
  - `_deleteUser` now calls
    `FirebaseFunctions.instance.httpsCallable('deleteUser')` instead of
    removing the RTDB node directly.
  - `_changePassword` now calls
    `FirebaseFunctions.instance.httpsCallable('changeUserPassword')`
    instead of writing a plaintext `passwordReset` field. Passwords now
    apply immediately instead of on the user's next login.
  - Added `_friendlyFunctionsError` to map `FirebaseFunctionsException`
    codes to user-facing messages, matching the existing
    `_friendlyAuthError` pattern.
- [lib/screens/shared/login_screen.dart](lib/screens/shared/login_screen.dart)
  — removed the now-dead pending-`passwordReset` pickup block from
  `_handleLogin` (no longer needed; `changeUserPassword` cleans up its own
  flag server-side).
- [database.rules.json](database.rules.json) — closed a self-write
  escalation path found during the task-3 audit (see below): the
  `users/$uid` self-write rule now also pins `institute` and `coAdmin`
  unchanged on updates, so an `institute_admin` can no longer reassign
  their own institute via a direct database write to bypass
  `assertCanManageUser`'s scoping.
- **Deployed to production** (`smartpowerswitch-e90d0`): `firebase deploy
  --only functions,database` — `deleteUser`, `changeUserPassword`,
  `onDeviceKwhChange`, `runAutomationScheduler`, and the rules update all
  went live.

### Task 3 — Security audit of the auth/login system (report-only)

A full read-only audit was run against `login_screen.dart`,
`auth_gate.dart`, `role_provider.dart`, `manage_users_screen.dart`,
`auth_service.dart`, `functions/index.js`, `database.rules.json`,
`firebase.json`, and dependency versions. One finding (institute
self-escalation) was patched immediately since it undermined task 2's own
access control (see above); everything else below is unfixed and left for
prioritization.

**Critical (unfixed)**
- The `@dnsc.edu.ph` email-domain restriction is enforced **only** in
  Flutter form validators. Nothing checks it server-side, so a direct call
  to the Identity Toolkit REST API (using the public client API key
  shipped in `lib/firebase_options.dart`) can register any email address,
  then self-write `role: "faculty"` to `users/$uid` — which the DB rules
  currently allow on first write — granting an outside actor read access
  to devices/history/automations campus-wide.
- `devices`, `buildings`, and `automations` write rules in
  `database.rules.json` are not institute-scoped: any `institute_admin`
  can currently control every building's relays and automations, not just
  their own.

**High (unfixed)**
- `master_devices/$id/writeKey` is defined but never actually checked —
  the anonymous device-write rule only checks that the device ID exists,
  so anyone who knows/guesses a device ID can spam relay toggles and kWh
  writes with no rate limiting.
- The Manage Users screen's broad `users` listener likely fails outright
  for real admins under RTDB's "rules are not filters" behavior — there is
  no `.read` rule on the `users` node itself, only on `users/$uid`.
- Neither `deleteUser` nor `changeUserPassword` calls
  `admin.auth().revokeRefreshTokens(uid)` — a deleted or password-reset
  user's already-issued ID token keeps working until it naturally expires
  (up to ~1 hour).

**Medium / Low (unfixed)**
- Login error messages (`_friendlyError`) distinguish "no account found"
  from "wrong password," enabling account enumeration.
- No Firebase App Check / CAPTCHA anywhere in the project.
- "Remember me" still stores the plaintext password in `SharedPreferences`
  for up to 3 days (`login_screen.dart`).
- No Cloud Function has `maxInstances`/`timeoutSeconds`/`memory` set —
  no cost or concurrency guardrails against abuse.
- An uncommitted (properly gitignored) `serviceAccountKey.json` sits on
  the local dev machine for `functions/cleanup_history.js` — not a repo
  leak, but worth rotating/removing when no longer needed.
- Client and Cloud Functions dependencies (`firebase_auth`,
  `firebase-admin`, `firebase-functions`, etc.) are a few minor versions
  behind current.
- Login fields don't set `autofillHints`, discouraging the OS/browser's
  own encrypted password manager in favor of the app's own (less secure)
  "remember me."
- No XSS-relevant rendering surface found — no action needed.

---

## 3. Files modified / created

**New**
- [lib/widgets/idle_timeout_wrapper.dart](lib/widgets/idle_timeout_wrapper.dart)

**Modified**
- [lib/main.dart](lib/main.dart) — `navigatorKey` + `IdleTimeoutWrapper` via `MaterialApp.builder`
- [lib/screens/shared/login_screen.dart](lib/screens/shared/login_screen.dart) — force-logout info card; removed dead `passwordReset` pickup
- [lib/screens/shared/manage_users_screen.dart](lib/screens/shared/manage_users_screen.dart) — `_deleteUser`/`_changePassword` call Cloud Functions
- [functions/index.js](functions/index.js) — `assertCanManageUser` shared authorization helper
- [database.rules.json](database.rules.json) — pinned `institute`/`coAdmin` on `users/$uid` self-write

---

## 4. How to verify locally

```powershell
flutter analyze
```

- **Idle timeout**: temporarily shorten `IdleTimeoutWrapper.timeout` (e.g.
  to 20 seconds), sign in, leave the app untouched, and confirm silent
  logout + the login-screen info card. Also test backgrounding the app
  past the limit and resuming.
- **Hard delete**: in Manage Users, delete a disposable test account, then
  confirm in the Firebase Console (Authentication tab) that the Auth user
  is actually gone, and that the same email can immediately register a new
  account.
- **Password change**: change a user's password via Manage Users and
  confirm it applies immediately (no "on next login" delay).
- **Role scoping**: confirm an `institute_admin` can act on their own
  institute's members but gets `permission-denied` outside it.

---

## 5. What needs a decision before further work

The Critical and High findings from the task-3 audit were intentionally
left unfixed (report-only, per request) except for the one that undermined
this session's own work. Recommend prioritizing, in order:

1. Server-side `@dnsc.edu.ph` enforcement (Auth blocking function) and
   institute-scoped `devices`/`buildings`/`automations` rules — both
   Critical, both isolated changes.
2. `revokeRefreshTokens` in `deleteUser`/`changeUserPassword`, and an
   actual `writeKey` check on anonymous device writes — both High, both
   small.
3. App Check, dropping plaintext password storage from "remember me," and
   Cloud Function `maxInstances` — Medium, larger effort/product-visible
   tradeoffs (App Check in particular needs Firebase Console setup).
