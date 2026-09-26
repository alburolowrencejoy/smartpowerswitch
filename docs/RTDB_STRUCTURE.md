# Realtime Database: a scalable structure and the plan to get there

Status: **plan only, nothing migrated yet.** Agreed 2026-09-26: document
first, no code changes yet; keep the current device IDs.

Built from every read/write path in `lib/`, `functions/`, `esp32/`,
`tools/train_and_push.py` and `database.rules.json`. Live data was not
inspected, so sizes below are estimates from the code, not measurements.

The goal is not only to tidy what exists today, but to shape the database
so it keeps working, and stays affordable, as SmartSwitch grows: more
devices, more buildings, years of history, possibly more campuses.

---

## 1. Growth we are designing for

These are planning targets, not predictions. Confirm or change them; every
choice below is sized against them.

| | Today (approx.) | Design target |
|---|---|---|
| Campuses | 1 (DNSC) | 10 |
| Buildings per campus | 5 | 30 |
| Devices (ESP32 + PZEM) | tens | 5,000 total |
| People with the app open at once | a few | 500 |
| History kept | since 2026 | 10 years |

---

## 2. Why the current structure won't scale

### 2.1 Load that grows with devices × people (the big one)
The numbers below use the firmware's current timings
(`RELAY_POLL_MS = 1000`, `TELEMETRY_PUSH_MS = 3000`,
`AUTOMATION_POLL_MS = 15000`).

- **Every board polls its relay once a second** (a REST GET) and **downloads
  the whole `automations` list every 15 s**. At 1,000 devices that is about
  **1,000 reads/s** just for relay polling, before anyone opens the app.
- **Every board writes telemetry every 3 s**: 1,000 devices ≈ **330
  writes/s**; 5,000 devices ≈ 1,670 writes/s. Firebase documents a limit of
  roughly 1,000 writes/second for a single Realtime Database instance (check
  the current value in the Firebase "Limits" docs).
- **Screens listen to the whole `devices` node**, so every open screen
  receives every board's telemetry. Rough cost at 1,000 devices, ~300 bytes
  per update and 100 open screens: 330 × 300 B × 100 ≈ **10 MB/s**, about
  **26 TB of download a month**. Download is what Firebase bills for.
- **Every reading runs ~25 transactions on the same total nodes**
  (`history/*/{key}/total_kwh`, `buildings/{CODE}/kwh`, ...). Many devices
  incrementing one counter at once retry against each other (a hot spot).

### 2.2 Data that grows forever
- `history/daily/{day}/devices/{id}`: one entry per device per day
  (5,000 devices ≈ 1.8 million entries a year), and analytics downloads
  whole day nodes to filter them on the phone.
- `history/hourly` and `history/raw` have no cleanup at all.
- The web analytics screen downloads **all of `history`**
  (`ref('history').get()`), including every raw snapshot, on each load.

### 2.3 Data correctness
1. **Two history writers.** `functions/index.js › onDeviceKwhChange` and the
   app's `GlobalReadingsListener → HistoryService` both add to the same
   totals, and every open app instance is one more writer.
2. **The Cloud Function adds the meter's running total, not the change.** It
   passes `devices/{id}/kwh` (the PZEM's cumulative energy) straight into
   the history totals on every update, which inflates them.
3. **Relay state is stored twice** (`devices/{id}/relay` and
   `buildings/.../floorData/.../devices/{id}/relay`) and can disagree.

### 2.4 Layout, identity and security
4. **One device, five places**: `master_devices`, `devices`,
   `buildings/.../floorData/.../devices`, `hotspots/.../devices`,
   `readings/{CODE}/{room}/{id}`. Every assign or delete has to touch all of
   them, and screens do it slightly differently.
5. **`readings` is keyed by location**, so moving a device orphans its data.
6. **No campus level anywhere**: a second campus would mix with the first.
7. **Boards have no identity of their own.** The firmware calls the REST API
   without a per-device credential, so rules can't limit a board to its own
   record.
8. **Rules look up the role from `users/{uid}` in every check** (long,
   copy-pasted expressions). That is slow to evaluate and easy to get wrong
   as roles grow; Firebase Auth custom claims do this better.
9. `floor` is sometimes a string, sometimes a number; notification IDs mix
   push IDs and `rate_change_{ts}`; `settings` is a grab bag.

---

## 3. Principles for a scalable Realtime Database

1. **Separate data by how often it changes.** Fast-changing telemetry,
   rarely-changing configuration and commands each get their own node, so a
   screen that needs a device's name doesn't also stream its voltage.
2. **Listen to the smallest node that answers the question.** Dashboards read
   small summary nodes kept up to date by the server; only a device's own
   detail screen listens to that device's live data.
3. **One writer per piece of data.** Boards write only their own live
   record; the app writes only configuration and commands; history and
   summaries are written only by Cloud Functions.
4. **No shared counters on the hot path.** Each device adds to its own
   counters; a scheduled function rolls them up into building and campus
   totals (every few minutes), instead of thousands of transactions fighting
   over one number.
5. **Partition by campus from day one**, even with one campus, so a second
   campus is new data, not a migration. If one database ever gets too busy,
   a campus can move to its own database instance with the same layout.
6. **Everything that grows is split by time and has a retention rule**:
   raw data kept for weeks, hourly for a year, daily and monthly forever;
   older detail is archived out of the Realtime Database.
7. **Keys are stable IDs, never locations.** Location is a field. (Current
   device IDs stay; they are treated as plain names.)
8. **Queries use keys or indexed fields** (`.indexOn`), never "download the
   parent and filter on the phone".
9. **Security by identity**: role and campus in Auth custom claims; each
   board signs in as itself and can write only its own record.
10. **Versioned schema and repeatable migrations**: `meta/schemaVersion`,
    migration scripts that are idempotent and have a dry-run mode, a backup
    before each one, and emulator tests for rules.

---

## 4. Target structure

`{campus}` is a short campus ID (e.g. `dnsc`); `{CODE}` an upper-case
building code; `{deviceId}` today's device ID.

```
meta/                    { schemaVersion }
users/{uid}              profile only (role + campus live in Auth custom claims)

campuses/{campus}/       { name, timezone }
settings/{campus}/
  rate/                  { current, updatedAt, fetchedAt }
  app/                   { mode }
rateHistory/{campus}/{timestampMs}       (was rate_changes)

buildings/{campus}/{CODE}/
  name, floors, map/{x,y,w,h}             (map was hotspots/{CODE})
  floors/{n}/rooms/{roomId}/{name}        (was floorData/{n}/rooms)

# One device, split by how often each part changes
devices/{campus}/{deviceId}/              CONFIG: changes rarely (app writes)
  name, utility, building, floor (number), room, map/{x,y}, registeredAt
live/{campus}/{deviceId}/                 TELEMETRY: the board writes only here
  voltage, current, power, kwhMeter, relay (actual), online, lastSeen
commands/{campus}/{deviceId}/             COMMANDS: the app writes, the board listens
  relay (desired), requestedBy, requestedAt
schedules/{campus}/{scheduleId}           (was automations)
schedulesByDevice/{campus}/{deviceId}/{scheduleId}: true
                                          a board downloads only its own schedules

# Indexes (small, written by functions, replace the old copies)
index/{campus}/devicesByBuilding/{CODE}/{deviceId}: true
index/{campus}/devicesByRoom/{CODE}/{n}/{roomId}/{deviceId}: true

# What dashboards listen to (small, updated by a function every ~1 min)
summaries/{campus}/campus                 { kwhToday, costMonth, online, total, ... }
summaries/{campus}/buildings/{CODE}       same, per building

# Usage: per-device counters + server rollups, all time-partitioned
usage/{campus}/device/{deviceId}/{YYYY-MM-DD}   { kwh, cost }   one writer: function
usage/{campus}/building/{CODE}/{YYYY-MM-DD}     { kwh, cost }   rollup
usage/{campus}/campus/{YYYY-MM-DD}              { kwh, cost }   rollup
usage/{campus}/…/month/{YYYY-MM}                monthly rollups (same shape)
usage/{campus}/hourly/{deviceId}/{YYYY-MM-DD}/{HH}              kept 1 year
rawReadings/{campus}/{deviceId}/{YYYY-MM-DD}                    kept 60 days
usageHidden/{campus}/{range}/{key}: true  (was history/deleted)
forecasts/{campus}/{daily, models/{lstm,xgboost}, modelUrl}

notifications/{campus}/{pushId}           type + fields in the body
logs/{campus}/deletions/{pushId}          (was deletion_log)
```

**Why per-device usage keyed by device, then date:** a device's history is
one small query (`usage/.../device/{id}` between two dates); a building's
trend reads the building rollup, never thousands of device rows; the day
node never grows with the number of devices.

**Value rules:** `floor` is a number; dates `YYYY-MM-DD`, months `YYYY-MM`,
hours `HH`; timestamps are epoch milliseconds; money in ₱ with the rate
stored alongside the cost it was computed at.

---

## 5. Data lifecycle (so storage stays bounded)

| Data | Kept in the Realtime Database | After that |
|---|---|---|
| `live`, `commands` | latest value only | overwritten |
| `rawReadings` | 60 days | deleted by a scheduled function |
| hourly usage | 1 year | rolled into daily, then deleted |
| daily usage per device | 2 years | archived (below), rollups remain |
| daily/monthly rollups (building, campus) | forever | small: ~365 keys/year each |
| notifications, logs | 1 year | archived |

**Archive:** a scheduled function exports expiring data to Cloud Storage (or
BigQuery if long-range analytics needs it) before deleting it. Analytics
ranges longer than what is kept in the database read from the archive.

---

## 6. Load with the target design (5,000 devices, 500 open screens)

| | Current design | Target design |
|---|---|---|
| Relay | 5,000 GETs/s (1 s polling) | 0 polling: each board keeps one streaming connection to its `commands` node |
| Telemetry writes | ~1,670/s (every 3 s) | ~170/s: every 30 s, or sooner on a real change (relay flip, > 5 % power change) |
| Schedules | every board downloads all schedules every 15 s | each board streams only its own |
| What a dashboard receives | every board's telemetry | a few summary nodes, ~once a minute |
| History writes | ~25 contended transactions per reading | one plain write per device counter + a rollup every few minutes |

If the target write rate is still too high for one database instance, the
campus partition allows one database per campus without changing the layout.

---

## 7. Roadmap

Each phase ships on its own, starts with a backup (`scripts/backup.ps1`) and
keeps old paths readable until the new ones are verified, so any phase can
be rolled back.

| Phase | What | Firmware update? | Pays off |
|---|---|---|---|
| **0. Measure** | Daily automated backups; run the Firebase database profiler for a day; record current sizes, bandwidth and write rates; confirm the growth targets in section 1. | no | baseline to size everything else |
| **1. Correct the numbers** | History written only by a Cloud Function, from the meter's *change* (keeps the last meter value per device); app stops writing history. | no | totals become trustworthy |
| **2. Stop the big downloads** | Summary nodes for dashboards; screens stop listening to all of `devices`; analytics stops downloading all of `history`; move raw/deleted/predictions out of `history`. | no | biggest bandwidth and cost cut |
| **3. Device protocol** | `commands` + streaming instead of 1 s polling; telemetry every 30 s or on change; per-device schedule index; OTA firmware update path. | **yes** | removes most device traffic |
| **4. One device record + campus partition** | `devices` / `live` / `commands` split under `{campus}`; fold in `master_devices`, `hotspots`, the `floorData` copies; indexes; `floor` → number. | yes (paths) | one source of truth; ready for campus 2 |
| **5. Security by identity** | Role and campus as Auth custom claims; each board signs in with its own credential and may write only `live/{campus}/{its id}`; rules rewritten short and tested in the emulator. | yes (auth) | safe to add campuses and devices |
| **6. Lifecycle** | Per-device usage + rollups; retention jobs; archive to Cloud Storage/BigQuery. | no | storage stays bounded for years |
| **7. Only if needed** | Separate database instance per campus. | no | headroom beyond one instance |

Past totals inflated by problem 2.3.2 can't be repaired automatically; they
can only be recomputed from `history/raw` where it exists. That is a
separate decision.

---

## 8. Decisions needed before building

1. Are the growth targets in section 1 right (especially campuses and
   device count)?
2. Is a second campus realistic? (If never, the `{campus}` level can be
   dropped, but it costs little to keep.)
3. How fresh must "live" be on dashboards: ~1 minute summaries, with
   second-by-second data only on a device's own screen?
4. Archive destination: Cloud Storage (cheap, simple) or BigQuery (queryable
   long-range analytics, costs more)?
5. Can every board be reached for a firmware update (OTA or by hand)?
   Phases 3–5 depend on it.
