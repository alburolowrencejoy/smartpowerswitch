# PZEM Calibration Points - Smart Power Switch System

## Overview
This document lists ALL calibration points where PZEM readings are used, transmitted, stored, and displayed in the system.

---

## 1. ESP32 PZEM READINGS & PROCESSING

### File: `esp32/SmartPowerSwitch_ESP32.ino`

#### A. PZEM Reading Methods (Lines 160-190)
```cpp
const float voltage = pzem.voltage();        // V (Volts)
const float current = pzem.current();        // A (Amps)
const float power = pzem.power();            // W (Watts)
const float energyKwh = pzem.energy();       // kWh (Cumulative total)
const float frequency = pzem.frequency();    // Hz
const float powerFactor = pzem.pf();         // 0.0 to 1.0
```

#### B. PZEM Validity Checks (Lines 110-120)
```cpp
// Voltage range: 80.0V to 260.0V
// Current range: 0.0A to 100.0A  
// Power range: 0.0W to 25000.0W
// Energy range: 0.0kWh to 1000000.0kWh
// Frequency range: 45.0Hz to 65.0Hz
// Power Factor range: 0.0 to 1.0
```

#### C. Rounding/Precision (Lines 97-104)
```cpp
// Voltage: 1 decimal place      → roundTo(voltage, 1)
// Current: 2 decimal places     → roundTo(current, 2)
// Power: 1 decimal place        → roundTo(power, 1)
// Energy (kWh): 4 decimal places→ roundTo(energyKwh, 4)
// Frequency: 1 decimal place    → roundTo(frequency, 1)
// Power Factor: 2 decimal places→ roundTo(powerFactor, 2)
```

#### D. Voltage Warning Thresholds (Lines 107-115)
```cpp
// Under-voltage (Brownout): < 207V
// Over-voltage (Surge): > 253V
// Normal: 207V - 253V
```

#### E. PZEM Module Address (Line 60)
```cpp
uint8_t pzemAddress = 0xF8;  // Factory default address for v4.0
```

#### F. UART Configuration (Lines 56-59, 133-145)
```cpp
static const uint32_t PZEM_UART_BAUD = 9600;  // Baud rate
static const uint8_t PZEM_RX_PIN = 16;        // ESP32 RX2
static const uint8_t PZEM_TX_PIN = 17;        // ESP32 TX2
```

#### G. Telemetry Intervals (Lines 54-56)
```cpp
static const uint32_t RELAY_POLL_MS = 1000;       // Poll relay every 1s
static const uint32_t TELEMETRY_PUSH_MS = 3000;   // Push readings every 3s
static const uint32_t PZEM_PROBE_RETRY_MS = 15000;// Retry probe every 15s
```

---

## 2. FIREBASE TELEMETRY STRUCTURE

### File: `esp32/SmartPowerSwitch_ESP32.ino` (Lines 340-410)

### Data Pushed to Firebase:
```json
{
  "devices/<DEVICE_ID>": {
    "status": "online|offline",
    "voltage_warning": "under_voltage_brownout|over_voltage_surge|normal",
    "last_updated": <epoch_ms>,
    "last_seen": <epoch_ms>,
    "voltage": <float, 1 decimal>,
    "current": <float, 2 decimals>,
    "power": <float, 1 decimal>,
    "kwh": <float, 4 decimals>,
    "powerFactor": <float, 2 decimals>,
    "frequency": <float, 1 decimal>,
    "relay": <boolean>,
    "cost_total": <float, 4 decimals>
  }
}
```

#### Energy Delta Calculation (Lines 400-430)
```cpp
// Tracks lastReportedEnergyKwh across telemetry pushes
// Delta = Current energyKwh - lastReportedEnergyKwh
// If delta < 0: meter may have reset, use current reading
// Only write if delta >= 0.000001 (avoid noise)
```

---

## 3. HISTORY WRITER - CLOUD FUNCTION

### File: `functions/history_writer.js`

#### A. Electricity Rate (Line 35)
```javascript
async function getRate() {
  const snap = await admin.database().ref('settings/electricityRate').get();
  return (snap.val() ?? 11.5);  // Default: ₱11.5 / kWh
}
```

#### B. Cost Calculation (Lines 45-48)
```javascript
const rate = await getRate();
const cost = kwh * rate;  // Total cost = kWh × Rate
```

#### C. History Periods Written (Lines 50-54)
```javascript
// For each reading, writes to:
// - history/daily/<YYYY-MM-DD>/
// - history/weekly/<YYYY-Wxx>/
// - history/monthly/<YYYY-MM>/
// - history/yearly/<YYYY>/
```

#### D. History Structure (Lines 61-78)
```javascript
// Per period writes:
{
  "total_kwh": <cumulative>,
  "total_cost": <cumulative>,
  "devices/<deviceId>": {
    "kwh": <delta>,
    "cost": <delta>,
    "building": "<building>"
  },
  "buildings/<building>/kwh": <cumulative>,
  "buildings/<building>/cost": <cumulative>,
  "buildings/<building>/rooms/<room>/kwh": <cumulative>,
  "buildings/<building>/rooms/<room>/cost": <cumulative>
}
```

#### E. Rounding Precision (Throughout)
```javascript
// All totals rounded to 4 decimal places
.toFixed(4)
```

---

## 4. FIREBASE REALTIME DATABASE STORAGE

### Current Database Paths:

#### Live Device Data:
```
/devices/{DEVICE_ID}/
├── status: "online" | "offline"
├── voltage: number (1 decimal)
├── current: number (2 decimals)
├── power: number (1 decimal)
├── kwh: number (4 decimals)
├── powerFactor: number (2 decimals)
├── frequency: number (1 decimal)
├── voltage_warning: string
├── relay: boolean
├── last_updated: timestamp (ms)
└── last_seen: timestamp (ms)
```

#### Settings:
```
/settings/electricityRate: number  # Default: 11.5 (₱/kWh)
```

#### History (Raw Summary):
```
/history/raw/{YYYY-MM-DD}_{DEVICE_ID}.json
├── deviceId: string
├── kwh_total: number (4 decimals)
├── cost_total: number (4 decimals)
└── ts: timestamp (ms)
```

#### History (Organized by Period):
```
/history/{daily|weekly|monthly|yearly}/{period}/
├── total_kwh: number (4 decimals)
├── total_cost: number (4 decimals)
├── devices/{deviceId}/
│   ├── kwh: number
│   ├── cost: number
│   └── building: string
└── buildings/{building}/
    ├── kwh: number
    ├── cost: number
    └── rooms/{room}/
        ├── kwh: number
        └── cost: number
```

---

## 5. FLUTTER APP - READINGS DISPLAY

### File: `lib/screens/device_detail_screen.dart`

#### A. Real-Time Listening (Lines 45-130)
```dart
// Subscribes to: /devices/{deviceId}
// Updates at: last_seen timestamp change (new reading detected)
```

#### B. Energy Accumulation (Lines 75-120)
```dart
// Formula: kWh = (Power_Watts / 1000) × Hours_Elapsed
final kwhThisInterval = (power / 1000.0) * intervalHours;
_lastValidEnergy += kwhThisInterval;  // Running total accumulation
```

#### C. Interval Calculation (Line 80)
```dart
// elapsedMs = last_seen_current - last_seen_previous
// intervalHours = elapsedMs / 3600000
```

#### D. PZEM Readings Display (Lines 591-608)
```dart
// Grid displays (with formatting):
_safeFormatPzem(_deviceData['voltage'], 1)      // 1 decimal
_safeFormatPzem(_deviceData['current'], 2)      // 2 decimals
_safeFormatPzem(_deviceData['power'], 1)        // 1 decimal
_safeFormatPzem(_deviceData['powerFactor'], 2)  // 2 decimals
_safeFormatPzem(_deviceData['frequency'], 1)    // 1 decimal
_safeFormatPzem(_deviceData['kwh'], 4)          // 4 decimals
```

#### E. Cost Calculation (Line 231)
```dart
final cost = energy * _ratePhp;  // Loaded from settings/electricityRate
```

#### F. Safety Checks (Lines 177-190)
```dart
// Online check: last_seen < 2 minutes = online
// PZEM check: voltage > 0.0
// NaN/Infinity handling: Returns "--" for invalid values
```

---

## 6. DATA FLOW SUMMARY

```
┌─────────────────────────────────────────────────────────────┐
│ PZEM-004T v4.0 Module                                       │
│ (Voltage, Current, Power, Energy, Frequency, Power Factor) │
└────────────┬────────────────────────────────────────────────┘
             │ RS485 @ 9600 baud
             │ (RX2=GPIO16, TX2=GPIO17)
             ↓
┌─────────────────────────────────────────────────────────────┐
│ ESP32 Firmware - SmartPowerSwitch_ESP32.ino                 │
│ ├─ Read PZEM every 3 seconds                               │
│ ├─ Validate readings (voltage 80-260V, current 0-100A...)  │
│ ├─ Round to precision (V:1, A:2, W:1, kWh:4, Hz:1, PF:2)  │
│ ├─ Check voltage warnings (207V-253V normal)               │
│ └─ Push to Firebase every 3 seconds                        │
└────────────┬────────────────────────────────────────────────┘
             │ HTTPS + JSON
             │ Path: /devices/{DEVICE_ID}
             ↓
┌─────────────────────────────────────────────────────────────┐
│ Firebase Realtime Database                                  │
│ ├─ Stores live telemetry                                   │
│ ├─ Tracks last_seen timestamp                              │
│ └─ Stores electricity rate (default: ₱11.5/kWh)            │
└────────┬──────────────────────────┬──────────────────────────┘
         │                          │
         │ Cloud Function           │ Flutter App
         │ history_writer.js        │ device_detail_screen.dart
         │                          │
         ↓                          ↓
┌──────────────────────┐    ┌────────────────────────┐
│ History Writer       │    │ Real-Time Display      │
│ ├─ Calc cost:        │    │ ├─ Display PZEM data   │
│ │  cost = kWh × rate │    │ ├─ Accumulate energy   │
│ ├─ Write daily       │    │ ├─ Calc interval kWh   │
│ ├─ Write weekly      │    │ ├─ Show voltage warn   │
│ ├─ Write monthly     │    │ ├─ Display cost        │
│ ├─ Write yearly      │    │ └─ Online status       │
│ └─ Persist per room  │    └────────────────────────┘
└──────────────────────┘

```

---

## 7. KEY CALIBRATION ADJUSTMENT POINTS

### To Calibrate PZEM Readings, You Can Modify:

#### 1. **ESP32 Hardware Configuration**
   - **File**: `esp32/SmartPowerSwitch_ESP32.ino` Lines 50-62
   - **Options**: 
     - PZEM module address (0xF8 factory default)
     - UART pins (RX2=GPIO16, TX2=GPIO17)
     - Baud rate (9600 fixed for PZEM-004T)

#### 2. **PZEM Reading Validation Ranges**
   - **File**: `esp32/SmartPowerSwitch_ESP32.ino` Lines 110-120
   - **Options**:
     - Voltage: min 80.0V → max 260.0V
     - Current: min 0.0A → max 100.0A
     - Power: min 0.0W → max 25000.0W
     - Energy: min 0.0kWh → max 1000000.0kWh
     - Frequency: min 45.0Hz → max 65.0Hz
     - Power Factor: min 0.0 → max 1.0

#### 3. **Precision/Rounding**
   - **File**: `esp32/SmartPowerSwitch_ESP32.ino` Lines 97-104 & 361-375
   - **Current Settings**:
     - Voltage: 1 decimal (e.g., 220.5V)
     - Current: 2 decimals (e.g., 5.32A)
     - Power: 1 decimal (e.g., 1170.0W)
     - Energy: 4 decimals (e.g., 12.3456kWh)
     - Frequency: 1 decimal (e.g., 50.0Hz)
     - Power Factor: 2 decimals (e.g., 0.98)

#### 4. **Voltage Warning Thresholds**
   - **File**: `esp32/SmartPowerSwitch_ESP32.ino` Lines 107-115
   - **Current Settings**:
     - Under-voltage warning: < 207V
     - Over-voltage warning: > 253V

#### 5. **Electricity Rate (Cost Calculation)**
   - **File**: Firebase `settings/electricityRate`
   - **Location**: Settings Screen in Flutter App
   - **Current Default**: ₱11.5 per kWh
   - **Used by**:
     - Cloud function `history_writer.js` (Line 35)
     - Flutter app `device_detail_screen.dart` (Line 231)

#### 6. **Telemetry Timing**
   - **File**: `esp32/SmartPowerSwitch_ESP32.ino` Lines 54-56
   - **Current Settings**:
     - PZEM readings pushed to Firebase: every 3 seconds
     - Relay polling: every 1 second
     - PZEM probe retry: every 15 seconds if not ready

#### 7. **History Rounding**
   - **File**: `functions/history_writer.js` (throughout)
   - **Current Setting**: All history values rounded to 4 decimals

#### 8. **Online Status Threshold**
   - **File**: `lib/screens/device_detail_screen.dart` Lines 162-166
   - **Current Setting**: Device offline if no reading for > 2 minutes

---

## 8. CURRENT DEFAULTS SUMMARY TABLE

| Component | Parameter | Value | Location |
|-----------|-----------|-------|----------|
| **PZEM Module** | Address | 0xF8 (factory default) | ESP32 line 60 |
| **PZEM Module** | Baud Rate | 9600 | ESP32 line 57 |
| **PZEM Module** | RX Pin | GPIO 16 (Serial2) | ESP32 line 55 |
| **PZEM Module** | TX Pin | GPIO 17 (Serial2) | ESP32 line 56 |
| **Voltage Reading** | Min valid | 80.0V | ESP32 line 112 |
| **Voltage Reading** | Max valid | 260.0V | ESP32 line 112 |
| **Voltage Reading** | Precision | 1 decimal | ESP32 line 97 |
| **Voltage Reading** | Under warning | < 207V | ESP32 line 109 |
| **Voltage Reading** | Over warning | > 253V | ESP32 line 109 |
| **Current Reading** | Min valid | 0.0A | ESP32 line 113 |
| **Current Reading** | Max valid | 100.0A | ESP32 line 113 |
| **Current Reading** | Precision | 2 decimals | ESP32 line 98 |
| **Power Reading** | Min valid | 0.0W | ESP32 line 114 |
| **Power Reading** | Max valid | 25000.0W | ESP32 line 114 |
| **Power Reading** | Precision | 1 decimal | ESP32 line 99 |
| **Energy Reading** | Min valid | 0.0kWh | ESP32 line 115 |
| **Energy Reading** | Max valid | 1000000.0kWh | ESP32 line 115 |
| **Energy Reading** | Precision | 4 decimals | ESP32 line 100 |
| **Frequency Reading** | Min valid | 45.0Hz | ESP32 line 116 |
| **Frequency Reading** | Max valid | 65.0Hz | ESP32 line 116 |
| **Frequency Reading** | Precision | 1 decimal | ESP32 line 101 |
| **Power Factor Reading** | Min valid | 0.0 | ESP32 line 117 |
| **Power Factor Reading** | Max valid | 1.0 | ESP32 line 117 |
| **Power Factor Reading** | Precision | 2 decimals | ESP32 line 102 |
| **Telemetry Push** | Interval | 3000ms | ESP32 line 56 |
| **Relay Poll** | Interval | 1000ms | ESP32 line 54 |
| **PZEM Probe** | Retry interval | 15000ms | ESP32 line 58 |
| **Electricity Rate** | Default | ₱11.5 / kWh | functions/history_writer.js line 35 |
| **Online Status** | Timeout | 2 minutes | device_detail_screen.dart line 164 |
| **History Rounding** | Decimals | 4 places | history_writer.js throughout |

---

## 9. SUGGESTED CALIBRATION WORKFLOW

1. **Measure Reference Values**
   - Use a calibrated multimeter to measure actual V, A, P at the device
   - Note the readings shown in the Flutter app

2. **Calculate Error**
   - Error % = (Displayed - Actual) / Actual × 100

3. **Adjust Calibration**
   - If error is systematic across all readings, the PZEM module itself may need calibration
   - Most PZEM-004T modules can be calibrated using their built-in calibration mode (consult datasheet)
   - Alternatively, apply software correction factors in the ESP32 code

4. **Test and Verify**
   - Push telemetry again to Firebase
   - Verify corrected readings in Flutter app
   - Check cost calculations in history

---

## 10. NOTES

- **Energy (kWh)**: The PZEM module reports cumulative energy since last reset
- **Energy Delta**: ESP32 tracks `lastReportedEnergyKwh` to calculate incremental consumption
- **Cost**: Calculated as `kWh × Electricity Rate` at multiple points:
  - ESP32 firmware (line 407)
  - Cloud function (history_writer.js)
  - Flutter app (device_detail_screen.dart)
- **Precision Loss**: Rounding at multiple stages can introduce small cumulative errors
- **Voltage Warnings**: These are logged but don't affect readings; they're for alerting on grid issues

