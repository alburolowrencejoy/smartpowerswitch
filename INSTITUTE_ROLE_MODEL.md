# Institute Role Model

Date: 2026-08-14

This document captures the interim role plan for the app before code changes are applied.

## Roles
- `main_admin` or super admin
- `institute_admin`
- `member`

## Access model
- Super admin:
  - can access all screens
  - can create and edit across all institutes
  - can register or authenticate devices
  - can assign institute admins and members
- Institute admin:
  - no global super-admin access
  - can manage only their institute
  - can add members
  - can create rooms and floors for their institute
  - can add devices already registered/authenticated by super admin
- Member:
  - can only see their own institute
  - read-only access for their institute data unless explicitly allowed later

## Institute scoping
- Each user should have an `institute` field.
- Each institute should have exclusive members.
- Users can only see data for their own institute unless they are `main_admin`.

## Example mapping
- Institute `IC`:
  - members: `mem1`, `mem2`, `mem3`
- Institute `IAAS`:
  - members: `mem2`, `mem3`, `mem4`

## Planned data fields
- `users/{uid}/role`
- `users/{uid}/institute`
- optional lookup nodes for faster rule checks:
  - `institutes/{code}/admins/{uid}`
  - `institutes/{code}/members/{uid}`

## Next implementation steps
1. Update auth and role storage to support the new roles.
2. Update Firebase rules for institute-based access.
3. Update UI checks so each screen hides or shows actions based on role and institute.
4. Add a super-admin flow for device registration/authentication.
5. Add institute admin management and member assignment.

## Notes
- Current app code still uses `admin` and `faculty` in many places.
- This document is the working target for the migration.
