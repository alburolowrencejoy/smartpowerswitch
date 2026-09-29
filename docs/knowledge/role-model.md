# Role model — plan vs. actual

Source docs: [`INSTITUTE_ROLE_MODEL.md`](../../INSTITUTE_ROLE_MODEL.md),
[`ROLE_HIERARCHY_PLAN.md`](../../ROLE_HIERARCHY_PLAN.md) (both dated
2026-08-12/14, written as a **plan before code changes**). This file is the
distilled, agent-facing view — cross-checked against the current
[`database.rules.json`](../../database.rules.json) and
[`docs/knowledge/work-history.md`](work-history.md) as of 2026-09-29. Where
the plan and the shipped code disagree, the code wins; the gap is called
out explicitly below so nobody re-implements the original 3-role plan
believing it's what's live.

## What the plan proposed (2026-08)

- Three roles: `main_admin` (global), `institute_admin` (scoped to one
  institute), `member` (read-only, own institute).
- Per-user fields: `users/{uid}/role`, `users/{uid}/institute`.
- Lookup nodes `/institutes/{code}/admins/{uid}`,
  `/institutes/{code}/members/{uid}` for fast rule checks (proposed,
  **not built** — see below).

## What actually shipped (read from `database.rules.json` + code)

- Five role strings are recognized everywhere: `faculty` (base/member
  tier), plus an admin tier of `admin`, `main_admin`, `super_admin`,
  `institute_admin` (legacy `admin` and a hardcoded `admin@dnsc.edu.ph`
  email check were kept additively, not replaced). A legacy
  `isMainAdmin: true` boolean on a user is also honored everywhere as an
  admin-tier escape hatch.
- Institute scoping is a single field, `users/{uid}/institute`, whose value
  is a **building code** (`IC`, `ILEGG`, `ITED`, `IAAS`, `ADMIN`) — DNSC's
  institutes map 1:1 to existing buildings, so no separate `/institutes/`
  collection was ever added. The planned `/institutes/{code}/admins`
  lookup node does not exist.
- `coAdmin: true` on a user distinguishes an admin an `institute_admin`
  added themselves from the "primary" admin the main admin assigned;
  co-admins can't touch the primary admin or self-demote.
- Per-institute UI theming exists (`lib/theme/institute_colors.dart`) and
  is layered on top of this same `institute` field — not part of access
  control, just a display concern.

## Known, currently-unfixed gap: rules are role-tier-scoped, not institute-scoped

This is the most important thing for `aaron` to know before touching
`database.rules.json` again: **every admin-tier role (`admin`,
`main_admin`, `super_admin`, `institute_admin`) currently has the exact
same server-side read/write reach — full campus-wide access to
`devices`, `buildings`, `automations`, `history`, etc.** The client UI
scopes an `institute_admin` to their own institute's screens, but nothing
in `database.rules.json` enforces that server-side; a direct API call from
an `institute_admin`'s account can read/write another institute's data.
This was flagged as a **Critical, unfixed** finding in the 2026-09-13
security audit (see `work-history.md` §Task 3) and is still open as of the
last rules read. Any rules change that touches `devices`, `buildings`, or
`automations` should treat closing this gap as the actual goal, not a
side effect.

## Other things any rule/role change should account for

- `users/$uid` self-write pins `role`, `isMainAdmin`, `institute`, and
  `coAdmin` unchanged on update (closed a self-escalation path where an
  `institute_admin` could reassign their own institute via a direct
  write) — don't loosen this without re-deriving why it's there.
- `master_devices/$id/writeKey` is defined in the schema but **not
  actually checked** by any rule — anonymous device writes are gated only
  on device-ID existence, not the key. Known High-severity gap, unfixed.
- The `@dnsc.edu.ph` email-domain restriction on signup is enforced only
  client-side (Flutter form validators); nothing stops a direct Identity
  Toolkit REST call from registering an arbitrary email and self-writing
  `role: "faculty"`, which the rules currently allow on first write.
  Critical, unfixed.
- Neither `deleteUser` nor `changeUserPassword` (Cloud Functions,
  `functions/index.js`) revokes the user's existing ID token, so a
  deleted/password-reset account's old token keeps working for up to ~1
  hour. High, unfixed.

## Where each role is read in the client

`role_provider.dart`, `dashboard_web.dart`, `building_floor_screen.dart`
(+`_web`), `device_detail_screen.dart` (+`_web`), `campus_map_screen.dart`,
`automation_screen.dart` (+`_web`) all branch on the five-role model above.
`manage_users_screen.dart` (now under `lib/screens/shared/`, plus a
`lib/screens/web/manage_users_screen_web.dart` counterpart) is the
UI for main-admin/institute-admin user management described in
`work-history.md`.
