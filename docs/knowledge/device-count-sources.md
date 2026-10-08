# Device counts: which list is the real one? (decision needed)

Status: **open, needs a decision** · Found 2026-10-08 by the every-screen
browser test (`e2e/test_screens.py`).

## The problem

The same building shows a different number of devices depending on the
screen. For IC on 2026-10-08:

| Screen | IC shows | Reads from |
|---|---|---|
| Web Dashboard: Device Status, Map ("Devices assigned") | 45 devices, 15 rooms | `devices` |
| Web Dashboard: Building Load, Web Devices building card | 0 devices | `master_devices` (`assignedTo`) |
| Phone Home: Room load | 3 devices per room | `devices` |
| Phone Devices: room list | 1 device per room, only rooms 101/103/104 | `master_devices` |
| Phone Devices: header | "Devices 18" | mixed |
| Settings: Device Inventory | 11 registered, 3 assigned, 8 unassigned (campus) | `master_devices` |

Campus-wide the gap is bigger: the dashboard says "of 123 reporting" while
Settings says 11 registered devices.

## Why: two lists that disagree

The database keeps devices in two places:

- **`master_devices/{id}`**: the device registry. A device gets here when
  an admin registers its ID in Settings, and `assignedTo` (for example
  `IC/1/Room 101`) says which room it is in. `source: "real_iot"` marks a
  real ESP32 board.
- **`devices/{id}`**: live readings (`kwh`, `last_seen`, `relay`) plus a
  copy of `building` / `floor` / `room`. The ESP32 writes its readings
  here.

A real, registered device should be in both. On 2026-10-07 they held:

- `master_devices`: **11** entries (2 assigned to ADMIN Room 101, 1 to
  TEST, 8 unassigned).
- `devices`: **123** entries. **112** of them are `DVC-*` IDs (for example
  `DVC-IC-009`) spread across ADMIN, IC, ILEGG and ITED, 3 per room. These
  are **not** in `master_devices`.

[`deployment.md`](deployment.md) already records that `DVC-*` devices are
mock/test data ("legacy DVC-prefixed test devices"), and that the history
writer counts only `master_devices` entries with `source === "real_iot"`.
That is why History and Analytics show almost no IC energy while the
dashboard shows 45 IC devices: the 45 are mock devices that history
already ignores.

### Why the cleanup script didn't remove them

`functions/remove_mock_devices.js` starts from `master_devices` and
deletes every entry there that isn't `real_iot`, along with its
`devices` and `readings` data. The 112 `DVC-*` devices exist **only in
`devices`**, so the script never sees them.

The script also has the opposite risk: it would delete any registered
device whose `source` isn't exactly `real_iot`, possibly including the 8
unassigned devices. Check their `source` before running it.

## Options

### A. `master_devices` is the source of truth (recommended)

Count, list and group devices only from `master_devices` (registered,
with `assignedTo` for the room). Use `devices` only for each registered
device's live readings.

- Matches what history already does, so every screen agrees with History
  and Analytics.
- Mock devices disappear from every count automatically, even before
  they're deleted.
- **What people will see:** IC, ILEGG and ITED show **0 devices** until
  real boards are registered and assigned to their rooms. ADMIN shows 2,
  TEST 1. That is the true state of the campus today, but it makes the
  institute dashboards look empty for a demo.
- Work: change the screens that count from `devices` (web Dashboard
  Device Status and Consumption by Room, both campus maps, phone Home Room
  load, History screens) to start from `master_devices`.

### B. `devices` is the source of truth

Count everything in `devices`, including unregistered entries.

- Institute dashboards stay full (45 IC devices).
- But the counts include 112 mock devices that produce no real history,
  so dashboards and History disagree permanently, and nothing stops a
  device from appearing without being registered.
- Work: change the screens that count from `master_devices` (Building
  Load, the Devices screens, Settings inventory) to read `devices`.

### C. Keep the mock data for demos, but label it

Option A, plus a "Show demo devices" switch, or a "Demo data" tag on
`DVC-*` devices.

- Lets the panel or defense demo show full dashboards without the counts
  pretending to be real.
- Most work of the three.

## Recommendation

**Option A**, then remove the 112 `DVC-*` entries from `devices` (and
`readings`) once you no longer need them for demos. If a demo needs full
dashboards first, do **C**.

## Decisions needed from the team

1. A, B or C?
2. Should the 112 `DVC-*` mock devices be deleted, and when (before or
   after the defense/demo)?
3. Are the 8 unassigned registered devices real boards waiting for a
   room, or leftovers? (Decides whether `remove_mock_devices.js` is safe
   to run as it is.)

Deleting data is a production write: back up first (see
[`deployment.md`](deployment.md), step 1).
