# Realtime Database structure: current map and reorganization plan

Status: **plan only, nothing migrated yet** (agreed 2026-09-26: document first, no code changes; keep the current device IDs). Built from every read/write path in
`lib/`, `functions/`, `esp32/`, `tools/train_and_push.py` and
`database.rules.json` (live data was not inspected).

---

## 1. What is in the database today

| Node | What it holds | Written by | Read by |
|---|---|---|---|
| `users/{uid}` | name, email, role, institute, passwordReset | app (auth), functions | everything (role checks) |
| `settings/electricityRate` | current ₱/kWh | app Settings, `fetch_davao_light_rates.js` | app, ESP32, history writers |
| `settings/lastRateUpdate`, `settings/rateLastFetched` | timestamps | app, functions | Settings |
| `settings/timezone`, `settings/appMode`, `settings/updateNotifications/*` | misc app config | app | app, ESP32 (timezone) |
| `rate_changes/{timestamp}` | oldRate, newRate, source, updatedBy | app, functions | Settings, cost history (`RateTimeline`) |
| `buildings/{CODE}` | name, floors | app | app |
| `buildings/{CODE}/floorData/{floor}/rooms` | room list per floor | app | app |
| `buildings/{CODE}/floorData/{floor}/devices/{deviceId}` | **copy** of utility, status, relay, room | app, **ESP32** | building/floor screens, automations |
| `hotspots/{CODE}` | map zone x/y/w/h | app (campus map) | campus map |
| `hotspots/{CODE}/devices/{deviceId}` | device pin x/y on the map | app | campus map |
| `master_devices/{deviceId}` | device inventory + `assignedTo` | app | dashboards, room panels, settings |
| `devices/{deviceId}` | **live telemetry** (voltage, current, power, kwh, relay, status, last_seen) **plus** assignment (building, floor, room, utility, source) | **ESP32**, app | nearly every screen, both history writers |
| `readings/{CODE}/{room}/{deviceId}` | per-session readings list | app (device detail) | device detail |
| `history/{daily\|weekly\|monthly\|yearly\|hourly}/{key}` | total_kwh, total_cost, `buildings/{CODE}`, `devices/{id}` | **Cloud Function and app** (see 2.1) | dashboards, analytics |
| `history/raw/{day}_{deviceId}` | ESP32 day snapshots (kwh_total, cost_total, ts) | **ESP32** | prediction service, peak hour |
| `history/deleted/{range}/{key}` | "hide this period" markers | app | analytics |
| `history/predictions/daily`, `.../models/{lstm,xgboost}`, `.../model_url` | forecasts | `tools/train_and_push.py`, app | analytics forecast tab |
| `automations/{id}` | schedules (scope, target, times, enabled) | app | app, ESP32, scheduler function |
| `notifications/{id}` | alerts (push ids **and** `rate_change_{ts}` ids) | app, functions | app |
| `deletion_log/{id}` | audit of deletions | app | admin |
| `meta` | (rules only) | – | – |

---

## 2. Problems

### 2.1 Data correctness (fix these first)
1. **Two history writers.** `functions/index.js › onDeviceKwhChange` and the
   app's `GlobalReadingsListener → HistoryService` both add to the same
   `history/*` totals. Each open phone/browser running the listener is one
   more writer, so totals can be counted more than once.
2. **The Cloud Function adds the meter's running total, not the change.**
   `writeHistoryForDevice(deviceId, building, kwh)` is called with
   `devices/{id}/kwh`, which the ESP32 reports as the PZEM *cumulative*
   energy. Every update adds the whole meter value again, which inflates
   history. (The app's listener correctly uses a delta.)
3. **Relay state lives in two places**: `devices/{id}/relay` and
   `buildings/.../floorData/.../devices/{id}/relay`. They can disagree.

### 2.2 Layout
4. **One device, five places**: `master_devices`, `devices`,
   `buildings/.../floorData/.../devices`, `hotspots/.../devices`,
   `readings/{CODE}/{room}/{id}`. Assigning or deleting a device means
   updating all of them (and each screen does it slightly differently).
5. **`readings` is keyed by location** (`{CODE}/{room}/{id}`). Moving a
   device to another room orphans its old readings.
6. **`history` mixes four different things**: period totals, raw ESP32
   snapshots, deletion markers and ML forecasts. The web analytics screen
   does `ref('history').get()`, so it downloads all of it, including every
   raw snapshot, on each load. That cost grows forever.
7. **`settings` is a grab bag** of rate, fetch timestamps, timezone, app
   mode and release-notification state.
8. **Map positions live apart from what they position** (`hotspots`).

### 2.3 IDs and value formats
9. **Device IDs encode a location** (`ESP32-ROOM101-001`), but devices get
   reassigned; the ID then lies. IDs should be the hardware identity only.
10. **`floor` is sometimes a string (`'1'`) and sometimes a number (`1`).**
11. **Notification IDs mix** Firebase push IDs and `rate_change_{ts}`.
12. **`history/raw` keys** are `{day}_{deviceId}`, so one device's data
    can't be queried without scanning every key.

---

## 3. Proposed structure

```
users/{uid}                         unchanged
settings/
  rate/        { current, updatedAt, fetchedAt }
  app/         { mode, timezone }
  releases/    { lastSignatureNotified }
rateHistory/{timestampMs}           renamed from rate_changes (same fields)

buildings/{CODE}/                   CODE = upper-case institute code
  name, floors
  map/         { x, y, w, h }       from hotspots/{CODE}
  floors/{n}/rooms/{roomId}: { name }   from floorData/{n}/rooms

devices/{deviceId}/                 the ONE device record
  (live telemetry fields stay flat, so ESP32 firmware keeps working)
  relay, status, voltage, current, power, kwh, last_seen, last_updated, ...
  building, floor (number), room, utility, source      assignment
  map/         { x, y }             from hotspots/{CODE}/devices/{id}
  registeredAt                      from master_devices

index/devicesByBuilding/{CODE}/{deviceId}: true
                                    replaces floorData/*/devices and master_devices.assignedTo

history/{daily|weekly|monthly|yearly|hourly}/{key}/
  total_kwh, total_cost, buildings/{CODE}/{kwh,cost}, devices/{id}/{kwh,cost}
                                    period totals only; ONE writer (Cloud Function, using deltas)
historyHidden/{range}/{key}: true   from history/deleted
rawReadings/{deviceId}/{YYYY-MM-DD} from history/raw/{day}_{id}
readings/{deviceId}/{pushId}        re-keyed by device, not location
forecasts/
  daily, models/{lstm,xgboost}, modelUrl   from history/predictions

automations/{id}                    unchanged
notifications/{pushId}              always push IDs; type in the body
logs/deletions/{id}                 from deletion_log
```

**ID and value rules:** building codes upper case (`IC`, `ILEGG`, `ITED`,
`IAAS`, `ADMIN`); device IDs stay as they are today (e.g. `ESP32-ROOM101-001`)
and are treated as plain names -- a device's location lives only in its
`building`/`floor`/`room` fields, never inferred from the ID; `floor` is always a number; date keys
`YYYY-MM-DD`, month `YYYY-MM`, week `YYYY-Www`, year `YYYY`, hour
`YYYY-MM-DD-HH`; every timestamp is epoch milliseconds.

---

## 4. How to get there safely

Each phase is its own commit + deploy, with a backup first
(`scripts/backup.ps1`). Old paths are kept (read-only) until the new ones are
confirmed, so any phase can be rolled back.

| Phase | Change | Touches firmware? | Risk |
|---|---|---|---|
| 0 | **Backup** the whole database | no | none |
| 1 | **Fix history correctness**: Cloud Function uses the kWh *delta* (keeps the last meter value per device); app stops writing history (read-only). | no | low; fixes inflated totals going forward |
| 2 | Split `history`: move `raw`, `deleted`, `predictions` to `rawReadings`, `historyHidden`, `forecasts`; update app, rules and `train_and_push.py`. Stop downloading all of `history`. | no | low |
| 3 | Tidy `settings` → `settings/rate`, `settings/app`; `rate_changes` → `rateHistory`; `deletion_log` → `logs/deletions`. | yes, ESP32 reads `settings/electricityRate` and `settings/timezone` (dual-write the old paths until firmware is updated) | low |
| 4 | One device record: fold `master_devices`, `hotspots/*/devices` and the `floorData/*/devices` copy into `devices/{id}` + `index/devicesByBuilding`; fold `hotspots/{CODE}` into `buildings/{CODE}/map`; `floor` → number. | yes, ESP32 patches `floorData/.../devices` | medium, most screens change |
| 5 | Re-key `readings` by device ID (IDs themselves unchanged). | no | low |

Past history totals that were inflated by problem 2.1.2 **cannot be repaired
automatically**; they can only be recomputed from `history/raw` where it
exists. Whether to do that is a separate decision.
