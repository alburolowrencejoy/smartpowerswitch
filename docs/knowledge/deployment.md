# History writer fix & deployment — incident writeup

Source doc: [`DEPLOYMENT_GUIDE.md`](../../DEPLOYMENT_GUIDE.md). This
documents a specific past incident (mock device data polluting
history totals) and the fix/rollback procedure used — kept as a reference
for **the pattern to follow** if a similar history-aggregation bug shows
up again, not as a set of steps to blindly re-run today (the specific
cleanup has already happened).

## The bug

Mock/placeholder devices (IDs like `DVC-ADMIN-036`) were mixed into real
IoT device (`ESP32-ROOM101-001`) history totals, inflating a yearly total
from a real ~0.065 kWh to a nonsensical 38,520.51 kWh, and a weekly total
was hardcoded to 0.

## The fix pattern (reusable)

1. **Back up first** — `firebase database:get history/{daily,weekly,monthly,yearly}`
   to local JSON files (or export via Firebase Console), before touching
   anything.
2. **Identify real vs. mock devices** — the discriminator is
   `master_devices/{id}/source === "real_iot"`. Anything else (mock,
   unassigned, legacy DVC-prefixed test devices) is excluded from history.
3. **Cleanup script** (`functions/cleanup_history.js` — run locally with
   `firebase-admin` and a service account key, never committed) recomputes
   every history period's totals from only `source === "real_iot"`
   devices.
4. **Cloud Function fix** — `functions/history_writer_fixed.js` /
   the shared `writeHistoryForDevice` now imported in
   `functions/index.js` from `functions/history_writer.js` (the two were
   merged since this doc was written — check `functions/index.js`'s
   `require` line before assuming which file is live).
5. **Rollback options** if a deploy goes wrong: stop the function
   (`firebase functions:delete historyWriter --confirm`) and restore from
   the pre-cleanup backup, or deploy the fix under a new function name
   first (`historyWriter_v2`) and cut over once verified.

## Where credentials live (and don't commit)

`functions/serviceAccountKey.json` — required for `cleanup_history.js`
and similar admin-SDK local scripts. **Never commit this file.** It should
already be gitignored; if you ever see it tracked, flag it immediately
rather than just adding it to `.gitignore` after the fact (history would
still have the old commit).

## Live-code check (2026-09-29): the real_iot filter may not actually be wired up

Read `functions/index.js` and both history-writer files directly to verify
this before assuming the fix above is live:

- `functions/index.js`'s `onDeviceKwhChange` trigger imports
  `writeHistoryForDevice` from `./history_writer` (the **plain** file) —
  not from `history_writer_fixed.js`.
- `functions/history_writer.js`'s `writeHistoryForDevice` has **no
  `source === 'real_iot'` check at all** — it writes history for any
  `deviceId`/`building` passed to it. The only gating happens one level up
  in `onDeviceKwhChange`: the device must have a `building` field and
  `relay === true`.
- `functions/history_writer_fixed.js` — the file that actually contains
  the `data.source === 'real_iot'` filter described above — is not
  `require`d anywhere in `index.js`. It appears to be dead/orphaned code
  left over from this incident, not the deployed implementation.

**Net effect**: if a new mock/test device is ever created with a
`building` field and its relay toggled on, the same class of bug this doc
describes (mock device kWh polluting real history totals) can recur,
because the currently-deployed function has no device-source filter. This
is a live discrepancy between this doc's described fix and the actual
deployed code — flag it to `aaron` before assuming the 2026-05 cleanup is
still structurally protected against recurring.

## Adding a new real IoT device

Set `master_devices/{NEW_DEVICE_ID}/source = "real_iot"` — the history
writer picks it up automatically on its next telemetry push, no code
change needed. To temporarily exclude a device from history, delete it or
change `source` to anything else.

## See also

- [`pzem-calibration.md`](pzem-calibration.md) — the full telemetry →
  history data flow this bug lived in.
- [`backup.md`](backup.md) — generic whole-repo backup (unrelated to the
  per-path RTDB backup described here; don't confuse the two).
