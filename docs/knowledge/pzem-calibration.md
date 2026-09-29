# PZEM readings — data flow and calibration points

Source doc: [`PZEM_CALIBRATION_POINTS.md`](../../PZEM_CALIBRATION_POINTS.md)
(full detail, including exact line numbers in the ESP32 firmware). This is
the condensed, agent-facing summary — read the source doc before actually
changing a calibration value, since line numbers drift.

## Data flow

```
PZEM-004T v4.0 (RS485 @ 9600 baud, RX2=GPIO16, TX2=GPIO17)
  -> ESP32 firmware (esp32/SmartPowerSwitch_ESP32.ino)
     reads every 3s, validates range, rounds, checks voltage warnings
  -> Firebase RTDB: /devices/{DEVICE_ID} (HTTPS + JSON, every 3s)
  -> fan-out:
     - functions/history_writer.js (Cloud Function): writes
       history/{daily,weekly,monthly,yearly}, cost = kWh x
       settings/electricityRate
     - Flutter (lib/screens/mobile/device_detail_screen.dart /
       lib/screens/web/device_detail_screen_web.dart): live display +
       client-side energy accumulation between readings
```

## Validity ranges & precision (ESP32 firmware)

| Field | Valid range | Precision | Voltage warning |
|---|---|---|---|
| Voltage | 80.0–260.0 V | 1 decimal | under <207V, over >253V |
| Current | 0.0–100.0 A | 2 decimals | — |
| Power | 0.0–25000.0 W | 1 decimal | — |
| Energy (kWh) | 0.0–1,000,000.0 kWh | 4 decimals | — |
| Frequency | 45.0–65.0 Hz | 1 decimal | — |
| Power factor | 0.0–1.0 | 2 decimals | — |

PZEM module address `0xF8` (factory default), baud 9600 fixed for
PZEM-004T. Telemetry push every 3s, relay poll every 1s, PZEM probe retry
every 15s if not ready.

## Energy delta & cost

- ESP32 tracks `lastReportedEnergyKwh` and only reports a delta if it's
  `>= 0.000001` (avoids noise); a negative delta means the PZEM's
  cumulative counter reset, in which case the current reading is used
  as-is.
- Cost = `kWh x rate`, computed independently in three places that must
  stay consistent: ESP32 firmware, `functions/history_writer.js` (reads
  `settings/electricityRate`, default ₱11.5/kWh if unset), and the Flutter
  device-detail screens (`_ratePhp`, loaded from the same settings path).
- History rounding: all totals in `history_writer.js` are rounded to 4
  decimals throughout.

## Online status

A device is treated as offline in the UI if `last_seen` is more than 2
minutes old (`device_detail_screen.dart`).

## Where to actually calibrate something

- Hardware/wiring/address/baud: `esp32/SmartPowerSwitch_ESP32.ino`
  (firmware — outside this repo's Flutter/Firebase agents' normal scope;
  flag to the user if a calibration request needs a firmware change).
- Validation ranges, rounding, voltage-warning thresholds, telemetry
  timing: same firmware file.
- Electricity rate: `settings/electricityRate` in Firebase — editable from
  the Settings screen in the app, consumed by `history_writer.js` and the
  device-detail screens. See also
  [`davao-light-rate-function.md`](davao-light-rate-function.md) for the
  automated-rate-fetch Cloud Function that can update this value.
- History rounding precision: `functions/history_writer.js`.

## Cross-check before touching `history_writer.js` or the RTDB history shape

See [`docs/knowledge/deployment.md`](deployment.md) for the "mock device
data polluted history totals" incident and its cleanup/rollback procedure
— any change to how history is aggregated should re-read that first so the
same class of bug (mixing mock `DVC-*` devices into real IoT totals)
doesn't reappear.
