---
name: firebase-rules-check
description: Review checklist for changes to smartpowerswitch's database.rules.json (Firebase Realtime Database security rules). Use before approving or merging any diff that touches database.rules.json, to check it against the role model, look for over-broad access or missing validation, and flag unbounded listener risk.
---

# Reviewing a database.rules.json change

This is a checklist, not a rewrite guide — it's for `aaron` (or whoever
proposed the rules change) to run through, and for the manager to use when
reviewing the diff before it ships. Ground every judgment in the actual
file, [`database.rules.json`](../../../database.rules.json), and in
[`docs/knowledge/role-model.md`](../../../docs/knowledge/role-model.md)
(the current, code-verified role model and its known gaps) — not in the
older planning docs (`INSTITUTE_ROLE_MODEL.md`,
`ROLE_HIERARCHY_PLAN.md`), which describe a 3-role model the code moved
past.

## 1. Cross-check against the role model

- The live rule pattern checks `role` against five literal strings
  (`admin`, `main_admin`, `super_admin`, `institute_admin`, `faculty`),
  plus a legacy `isMainAdmin === true` boolean and a hardcoded
  `admin@dnsc.edu.ph` email escape hatch. A new rule block should match
  this exact pattern for consistency unless there's a specific reason to
  diverge — check it against a node that already has the pattern right
  (e.g. `history` or `automations`) rather than writing it from scratch.
- **The known, unfixed gap**: every admin-tier role currently has
  identical server-side reach — campus-wide, not scoped to the caller's
  own `institute`. If this change is meant to *close* that gap for the
  node it touches, verify it actually cross-references
  `newData`/`data`'s `building`/institute field against
  `root.child('users').child(auth.uid).child('institute').val()` — a rule
  that still only checks role tier, without an institute comparison,
  has **not** closed the gap, no matter how it reads.
- If this change *doesn't* address that gap, that's fine (not every rules
  PR has to), but say so explicitly in the review rather than silently
  extending a pattern that has the gap baked in.
- Check `users/$uid`'s self-write pinning (`role`, `isMainAdmin`,
  `institute`, `coAdmin` must stay unchanged on a self-update) isn't
  weakened by the change — this closes a real, previously-exploited
  self-escalation path.

## 2. Look for over-broad `.read`/`.write`

- Any `".read": true` or `".write": true` (or an auth check that's just
  `auth != null` with no role check) on a node that isn't genuinely public
  should be treated as a red flag — ask "what's the narrowest role/path
  combination that actually needs this," per `aaron`'s own standing rule
  of never widening rules "temporarily."
- Check `master_devices/$id/writeKey` — historically defined but **never
  actually enforced** (the anonymous device-write rule only checks
  device-ID existence, not the key). If this diff touches device-write
  rules, verify whether it finally wires the key check in, or if it's
  unrelated, don't let the diff quietly make this worse (e.g. by removing
  the field's `.write` restriction).
- A rule granting write access on `auth == null` (anonymous) should be as
  narrow as possible and paired with field-level `.validate` — check the
  existing `devices/$deviceId` block's anonymous-write case as the
  precedent (it already restricts which fields can change and requires
  `master_devices` registration).

## 3. Missing `.validate`

- RTDB rules default-allow any data shape once `.read`/`.write` pass —
  look for nodes that accept writes but have no `.validate` on the fields
  that matter (type, range, required presence). PZEM numeric fields in
  particular have known valid ranges (see
  [`docs/knowledge/pzem-calibration.md`](../../../docs/knowledge/pzem-calibration.md))
  — a device-write rule with no bound on `voltage`/`current`/`power` lets
  a compromised or spoofed device write garbage that then corrupts
  history totals (see
  [`docs/knowledge/deployment.md`](../../../docs/knowledge/deployment.md)
  for what that class of bug looked like in practice).
- For a node with a fixed set of expected children (e.g. a settings node),
  consider whether `.validate` should also reject unexpected extra
  children, not just check the known ones.

## 4. Unbounded listeners / cost risk

- A `.read` grant on a wide node (e.g. all of `users`, all of `history`)
  is exactly what lets a client attach a full-tree listener — check
  whether the intended client usage is actually a bounded query
  (`.indexOn` + `limitToLast`/`orderByChild`, etc.) and whether the rule
  as written would still allow an unbounded pull instead. `notifications`
  and `rate_changes` already have `.indexOn: ["timestamp"]` for this
  reason — a new time-ordered, potentially-growing node should get the
  same treatment.
- Flag (don't silently allow) any client-side pattern this rules change
  would newly permit that reads/listens to an unbounded or deeply nested
  path — full-tree listeners and unpaginated history reads are a real
  billing risk on RTDB, even if the rule is otherwise "correct."

## 5. Testing the change

**No Firebase Emulator Suite is currently configured in this repo** —
[`firebase.json`](../../../firebase.json) has no `emulators` key. Before
relying on emulator testing for a rules change:
1. Confirm this is still true (`firebase.json` may have changed since this
   was written).
2. If not configured, say so explicitly rather than assuming it's safe to
   test against, and propose adding an `emulators` block (`firebase init
   emulators`, selecting Database) rather than testing the new rule
   against production data.
3. If/when configured: `firebase emulators:start --only database`, then
   exercise the rule from each role in the model (including denied cases —
   an `institute_admin` acting outside their institute should get
   `permission-denied`, not silently succeed) before deploying.
- Rules are **not deployed automatically** — deployment is
  `firebase deploy --only database` against project `smartpowerswitch-e90d0`.
  Per `aaron`'s standing rule, this requires the user's explicit go-ahead;
  don't deploy as part of "finishing" a rules review.

## 6. Sign-off

This checklist is a review aid, not an approval — per `joren`'s and
`aaron`'s standing practice, close out a rules review by stating plainly
what's still open (e.g. "institute-scoping gap not addressed by this
diff," "no emulator test run, only read the rule text") rather than
rounding a partial review up to "looks good."
