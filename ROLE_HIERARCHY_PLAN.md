# Role Hierarchy Migration Plan

Date: 2026-08-12

This document captures the planned changes to move from the current flat role model (admin / faculty/member) to the new hierarchical model:

- `main_admin` — global super-admin
- `institute_admin` — admin scoped to an institute (e.g. `IC`, `ILEGG`, `IAAS`, `ITED`, `ADMIN`)
- `member` — ordinary user scoped to an institute

This is a planning document only.

---

## 1. Data model
- Add per-user fields under `users/{uid}`:
  - `role`: one of `main_admin` | `institute_admin` | `member`
  - `institute`: optional institute code string (present for institute-scoped accounts)
- Add lookup nodes to speed rule checks:
  - `/institutes/{code}/admins/{uid}: true`
  - `/institutes/{code}/members/{uid}: true` (optional / derived)
- Keep existing fields untouched during migration until verified.

## 2. Migration strategy (safe + auditable)
1. Prepare a migration script (Node.js or Cloud Function run once):
   - Map existing `users/{uid}` values to new fields according to mapping rules.
   - Populate `/institutes/{code}/admins` for institute admins.
   - Write an audit record for each changed user under `/migration_audit/{timestamp}/{uid}` recording before/after values.
2. Dry-run: run on a small sample and produce an audit report.
3. Staging run: run on a staging DB snapshot and verify app flows.
4. Production run: after exporting a full DB backup, execute migration and mark completion with a `migration_done_at` timestamp.

## 3. Security rules & backend
- Update Firebase rules to enforce the new hierarchy:
  - `main_admin` → full read/write to all buildings and admin nodes.
  - `institute_admin` → read/write only to their institute nodes.
  - `member` → read-only to their institute and own user profile.
- Add rule helper functions: `isMainAdmin(uid)`, `isInstituteAdmin(uid, code)`.
- Update Cloud Functions to use server-side checks and not trust client-provided role/institute values.

## 4. App (viewmodel + UI) changes
- Expose current user context in the app (viewmodel):
  - `currentRole`, `currentInstitute`, helper getters like `isMainAdmin` and `isInstituteAdminFor(code)`.
- UI behavior:
  - `main_admin`: view/create/edit all buildings + admin management UI.
  - `institute_admin`: view only buildings for `currentInstitute`; institute-scoped admin actions.
  - `member`: view-only for their `currentInstitute`.
- Add an admin-management screen for `main_admin` to assign/unassign institute admins.

## 5. Tests and verification
- Migration unit tests (script-level) using sample users.
- Security rules tests using Firebase emulator covering all role scenarios.
- Manual flows (staging): login, building list, create building, assign admin.

## 6. Rollout plan
- Staging verification → feature-flagged client release (reads new fields only) → enable new rule enforcement after monitoring.
- Keep DB backups and audit logs for rollback if needed.

## 7. Risks & mitigations
- Mis-mapped roles: mitigate with dry-run and audit logs.
- Broken client assumptions: mitigate with feature flags and staged rollout.
- Security gaps: mitigate with thorough emulator rule tests and Cloud Function checks.

## 8. Deliverables (pick order)
- Migration script (Node.js) + dry-run report.
- Firebase security rules patch + emulator tests.
- `DashboardViewModel` changes to surface role/institute.
- Admin UI to manage institute admins.

---

If you want, I can prepare the migration script or the security rules next. Otherwise tell me which deliverable to start with and I will prepare a scoped plan and estimate for that task.
