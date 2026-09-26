# ESP32 on battery with deep sleep: plan

Goal: make each SmartSwitch board run as long as possible between battery
changes, without losing energy data or schedules.

Status: **plan, nothing built yet.** Current firmware:
`esp32/SmartPowerSwitch_ESP32.ino` (ESP32 Dev Module, SSR on GPIO 26,
PZEM-004T on UART2, Wi-Fi always on, relay polled every 1 s, telemetry every
3 s). All current and battery-life figures below are **estimates to confirm
by measurement** (section 7).

---

## 1. First, the honest trade-off

A board in deep sleep is **off the network**. While it sleeps it cannot hear
the app, so:

- **A relay command from the app waits until the next wake-up.** With a
  5-minute wake interval, pressing "Turn off" in the app can take up to
  5 minutes to happen. (A physical button on the board can still wake it
  instantly.)
- **Live readings are only as fresh as the last wake-up**, e.g. every 5 min.
- **Schedules still run on time**, because the board wakes exactly at the
  next schedule time (section 4).
- **No energy is lost while it sleeps.** The PZEM-004T keeps counting kWh on
  its own as long as the mains is present; the board reads the running
  total when it wakes.

If instant on/off from the app is a must, deep sleep is the wrong tool (see
option C below).

---

## 2. Three ways to power it

The board already sits on a mains line (the PZEM measures it and the relay
switches it), so mains power is physically right there.

| Option | How | Battery life | App control |
|---|---|---|---|
| **A. Mains + backup battery** (recommended if allowed) | Small isolated 230 V→5 V module (e.g. HLK-PM01 / HLK-5M05, fused) powers the board; an 18650 + charger/UPS module takes over during outages. | **Years**: the battery is only used during power cuts. | Instant, as today |
| **B. Battery + deep sleep** (this plan) | Board sleeps most of the time and wakes every few minutes. | **Months** with the right parts (section 5) | Delayed to next wake-up |
| **C. Battery + Wi-Fi light sleep** | Board stays connected but naps between Wi-Fi beacons. | Days to a few weeks | Near-instant (about a second) |

"As long as it can" is option A: a battery that is almost never used lasts
until it ages out. Option B is the right choice when the board must not draw
from the mains line (isolation rules, a location with no neutral, or a
portable unit). The rest of this plan is option B, and every part of it also
helps option A's backup time.

---

## 3. Where the battery goes (and the fixes)

Rough draw per part, and what to change:

| Part | Today | Problem | Fix |
|---|---|---|---|
| **ESP32 Dev Module board** | ~5–15 mA even in deep sleep | USB-serial chip, AMS1117 regulator and power LED never sleep | Use a low-power board (e.g. FireBeetle ESP32-E, LOLIN D32, or a bare ESP32 module) with a low-quiescent regulator (e.g. MCP1700 / HT7333, a few µA). Target: **10–25 µA asleep**. |
| **SSR relay input** | ~5–15 mA **all the time the load is on** | An SSR only stays on while its input is powered | Use a **latching (bistable) relay**: a 20–50 ms pulse flips it and it stays put with zero current. Size it for the load (AC units need a high inrush rating). |
| **Wi-Fi on each wake-up** | ~100–250 mA for 2–5 s | Scanning, DHCP and the HTTPS handshake | Cache Wi-Fi channel + BSSID in RTC memory, use a static IP, send one combined request, then switch Wi-Fi off. Target: **~1–2 s awake**. |
| **PZEM-004T interface side** | a few mA if always powered | Its TTL/optocoupler side is fed by the board | Switch its 5 V/3.3 V feed with a MOSFET; power it only while reading (~200 ms). Its kWh counter lives on the mains side and keeps counting. |
| **Battery voltage divider** | ~µA–mA continuously | A low-value divider leaks current | High-value divider (e.g. 2 × 1 MΩ + 100 nF), or switch it with the same MOSFET. |

---

## 4. What the firmware does on each wake-up

```
wake (timer, schedule time, or button)
 ├─ restore state from RTC memory (relay state, schedules, Wi-Fi cache,
 │  last kWh, unsent readings, failure count)
 ├─ power PZEM → read V, I, P, kWh, PF → power PZEM off
 ├─ read battery voltage
 ├─ if a schedule time is due → pulse the latching relay
 ├─ connect Wi-Fi (cached channel/BSSID, static IP)
 │    ├─ ONE PATCH: live readings (+ any readings buffered while offline),
 │    │  battery %, relay state, lastSeen, nextWakeAt
 │    └─ ONE GET: desired relay + schedules version (download schedules only
 │       when the version changed)
 ├─ apply relay command if it changed → pulse the relay
 ├─ Wi-Fi off
 ├─ next wake = min(regular interval, next schedule time, low-battery interval)
 └─ deep sleep (relay holds its state by itself)
```

Rules:

- **Adaptive interval:** e.g. 5 min normally; 15 min below 30 % battery;
  60 min below 15 %, with a "low battery" alert sent to the app.
- **Offline-safe:** if Wi-Fi fails, store the reading in RTC memory (keeps
  the last ~20) and back off (5, 10, 20 min) instead of retrying at full
  power.
- **Schedules run locally:** the board keeps the schedule list in RTC memory
  and sets its wake timer to the next on/off time, so schedules don't
  depend on Wi-Fi.
- **Manual button** on an RTC GPIO (EXT0 wake-up) toggles the relay
  instantly and reports it.
- **Brown-out safety:** below a cut-off voltage, set the relay to a safe
  state (decide: last state or OFF) and sleep until the battery is changed.

---

## 5. Battery life estimates

Assumptions: one 18650 Li-ion, 3,000 mAh, ~2,400 mAh usable (about 80 %
after regulator losses and ageing margin); load on 10 h/day; each wake-up
~2 s at ~120 mA average. **Estimates only: measure to confirm.**

| Setup | Per day (approx.) | Life on one 18650 |
|---|---|---|
| Today (Dev Module, Wi-Fi always on, SSR) | ~2,500–3,500 mAh | **under 1 day** |
| Dev Module + deep sleep every 5 min + SSR | ~250–450 mAh | about **1 week** |
| Low-power board + deep sleep 5 min + **latching relay** | ~20 mAh | about **3–4 months** |
| Same, wake every 15 min | ~7–8 mAh | about **9–10 months** |
| Same, 15 min, **two 18650s** in parallel | ~7–8 mAh | about **1.5 years** (self-discharge starts to matter) |
| Option A: mains + backup battery | ~0 (outages only) | **years** (battery ageing is the limit) |

### With the 32650 cell on hand

The cell is labelled "24000 mAh", which a 32650 cannot hold: real 32650
cells are about 5,000–7,000 mAh. Plan with ~6,000 mAh (~4,800 mAh usable)
until its real capacity is measured with a capacity tester.

| Setup | Life on the 32650 (~6,000 mAh real) |
|---|---|
| Today (Dev Module, Wi-Fi always on, SSR) | about 1–2 days |
| Dev Module + deep sleep every 5 min + SSR | about 2 weeks |
| Low-power board + deep sleep 5 min + latching relay | about **8 months** |
| Same, wake every 15 min | about **1.5 years** |

The cell is **LiFePO4** (3.2 V nominal). Consequences for the build:

- **Charger:** a 3.6 V LiFePO4 charger (e.g. TP5000 in LiFePO4 mode, or
  CN3058) plus a 1S LiFePO4 protection board (cut-off ~2.5 V). **Never a
  TP4056**: it charges to 4.2 V and overcharges LiFePO4.
- **No regulator needed:** the cell sits at ~3.2–3.35 V for most of its
  charge, inside the ESP32's 3.0–3.6 V range, so it can feed the board's
  3.3 V pin directly (not 5V/VIN), which removes regulator losses. Use a
  charger that terminates at 3.6 V (not 3.65 V); the cell settles to
  ~3.35 V within minutes of charging.
- **Battery %:** the voltage curve is nearly flat, so voltage only works as
  a threshold (~3.1 V low, ~3.0 V critical → long sleep). Estimate % by
  counting charge used (awake time × current) in RTC memory.
- **Everything runs at ~3.2 V:** choose a latching relay with a **3 V coil**
  rated for the load; test the PZEM interface side at 3.3 V (add a small
  boost converter, powered only while reading, if it needs 5 V).
- Low self-discharge and long cycle life suit a board that sleeps for
  months.

The lesson: **board choice and the latching relay matter more than the wake
interval.** With a Dev Module and an SSR, no firmware trick gets past a
week or two.

---

## 6. Changes needed in the app and database

These fit phase 3 of `docs/RTDB_STRUCTURE.md`, with one difference: a
sleeping board can't keep a streaming connection, so battery boards **read
their command once per wake-up** instead of streaming it.

- **"Online" means "checked in on time":** a board is online if `lastSeen`
  is within about 2.5 × its wake interval (today the app uses a fixed
  2 minutes, which would show every sleeping board as offline).
- **Show the delay honestly:** "Sleeping · next check-in in 3 min", and a
  relay command shows as **Pending** until the board confirms it.
- **New fields per device:** `battery` (%), `batteryVoltage`,
  `wakeIntervalSec`, `nextWakeAt`, `powerSource` (`battery` / `mains`).
- **Low-battery notifications** and a "battery" column in device lists.
- **History:** unchanged. Readings arrive every few minutes instead of every
  3 s; the kWh deltas add up to the same totals.

---

## 7. How to build it (steps)

1. **Decide the power option** (A, B or C) and the maximum command delay
   you can accept (section 8).
2. **Measure first:** a USB power meter or multimeter (µA range) on today's
   board; record awake current, sleep current and SSR current. This gives
   the real numbers for section 5.
3. **Parts:** low-power ESP32 board, low-quiescent regulator, latching
   relay (+ driver), MOSFET switch for the PZEM feed, 32650 LiFePO4 holder + 3.6 V LiFePO4 charger (e.g. TP5000) + 1S
   LiFePO4 protection board, high-value divider.
4. **Firmware v2 on one test board:** deep-sleep loop (section 4), RTC
   memory state, fast Wi-Fi reconnect, one PATCH + one GET per wake-up,
   latching-relay pulses, local schedules, battery reading, button wake-up.
5. **Measure again**, adjust the interval, confirm the battery estimate.
6. **App changes** (section 6) before rolling out to more boards.
7. **Pilot** 2–3 boards for two weeks; compare kWh totals with a board on
   today's firmware on the same kind of load.
8. **Roll out**, ideally with over-the-air updates so future firmware
   doesn't mean opening every box.

---

## 8. Decisions needed

1. Is mains power (option A) allowed at the install points? It gives the
   longest life by far.
2. What is the longest acceptable delay between pressing a switch in the
   app and it happening? (This sets the wake interval.)
3. If the battery dies, should the load stay in its last state or turn off?
4. What loads do the boards switch (lights, outlets, air-con)? This decides
   the latching relay rating.
5. Battery: one or two 18650s per board, and who changes them?
