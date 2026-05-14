# History Writer Fix - Deployment Guide

## Overview
This guide fixes the history writer to exclude mock DVC devices and recalculate totals correctly.

**Current Problem:**
- Yearly total: `38520.51 kWh` (WRONG — should be `~0.065 kWh`)
- Weekly W19 total: `0 kWh` (hardcoded zero)
- Building totals mixed real IoT + mock data

**Solution:**
- Only write history for **real IoT devices** (`source === "real_iot"`)
- Remove mock DVC data from all history periods
- Recalculate all totals using transactions for safety

---

## Step 1: Backup Your Data

**On your local machine, run:**

```bash
# If you have Firebase CLI installed
firebase database:get history/daily > backup_daily.json
firebase database:get history/weekly > backup_weekly.json
firebase database:get history/monthly > backup_monthly.json
firebase database:get history/yearly > backup_yearly.json
```

**Or manually export from Firebase Console:**
1. Go to Firebase Console → Realtime Database
2. Click the three-dot menu → Export JSON
3. Save as `backup_[timestamp].json`

---

## Step 2: Run Cleanup Script (LOCAL)

This removes old mock device data and recalculates totals.

### 2a. Get Service Account Key

1. Go to **Firebase Console** → **Project Settings** → **Service Accounts**
2. Click **"Generate new private key"**
3. Save to `functions/serviceAccountKey.json`

⚠️ **NEVER commit this file to git** — add to `.gitignore`

### 2b. Install Dependencies

```bash
cd functions
npm install firebase-admin
```

### 2c. Run Cleanup

```bash
node cleanup_history.js
```

**Expected output:**
```
========================================
  History Cleanup - Remove Mock Devices
========================================

[Cleanup] Identifying real IoT devices...
  ✓ Real IoT: ESP32-ROOM101-001
  ✗ Mock/Unassigned: DVC-ADMIN-036
  ✗ Mock/Unassigned: DVC-ADMIN-037
  ... (etc)

Found 1 real IoT devices.

[Cleanup] Processing daily history...
  ✓ 2026-05-07: 0.055000 kWh / 0.632500 ₱
  ✓ 2026-05-09: 0.000000 kWh / 0.000000 ₱
  ✓ 2026-05-10: 0.000051 kWh / 0.000587 ₱
  ... (etc)

[Cleanup] Processing weekly history...
  ✓ 2026-W18: 0.055051 kWh / 0.633087 ₱
  ... (etc)

[Cleanup] Processing monthly history...
  ✓ 2026-05: 0.065000 kWh / 0.747500 ₱
  ... (etc)

[Cleanup] Processing yearly history...
  ✓ 2026: 0.065000 kWh / 0.747500 ₱  ← FIXED (was 38520.51)

[Cleanup] ✓ History cleanup complete!
[Cleanup] Real IoT devices kept: ESP32-ROOM101-001
[Cleanup] Mock devices removed: 30+
```

✅ **If you see this, cleanup succeeded!**

---

## Step 3: Deploy New Cloud Function

If you have a **Blaze plan** (pay-as-you-go), deploy the fixed function:

### 3a. Update `functions/index.js`

Option A: **If you don't have an existing historyWriter**, just deploy the new one:
```bash
firebase deploy --only functions:historyWriter
```

Option B: **If you have an old historyWriter**, replace it:

1. Open `functions/index.js`
2. Remove the old `exports.historyWriter` block
3. Add this import at the top:
   ```javascript
   const historyWriterModule = require('./history_writer_fixed.js');
   exports.historyWriter = historyWriterModule.historyWriter;
   ```
4. Save and deploy:
   ```bash
   firebase deploy --only functions:historyWriter
   ```

### 3b. Verify Deployment

1. Go to **Firebase Console** → **Functions**
2. Look for `historyWriter` status: should be **GREEN** (Active)
3. Check **Logs** tab:
   ```
   [history_writer] Processing real IoT device: ESP32-ROOM101-001
   ```

---

## Step 4: Test New Telemetry

Push a test reading to verify the function processes it correctly:

### 4a. Trigger from ESP32

Just wait for the ESP32 to send its next telemetry reading (~3 seconds), or manually restart it.

### 4b. Manual Test (Firebase Console)

1. Go to **Realtime Database**
2. Click on `devices` → `ESP32-ROOM101-001`
3. Click the three-dot menu → **Edit**
4. Update the `kwh` value and `last_updated` timestamp:
   ```json
   {
     "kwh": 0.215,
     "power": 14.5,
     "voltage": 217.9,
     "current": 0.09,
     "last_updated": 1715782849000
   }
   ```
5. Click **Update**

### 4c. Verify in Firebase

Check that history was written correctly:

**Daily:**
```
history/daily/2026-05-15/
├── total_kwh: 0.215          ← Only ESP32 data
├── total_cost: 2.4725        ← Calculated from rate
├── devices/
│   └── ESP32-ROOM101-001/
│       ├── kwh: 0.215
│       ├── cost: 2.4725
│       └── building: "GYM"
└── buildings/
    └── GYM/
        ├── kwh: 0.215
        ├── cost: 2.4725
        └── rooms/
            └── Room101/
                ├── kwh: 0.215
                └── cost: 2.4725
```

**Yearly:**
```
history/yearly/2026/
├── total_kwh: 0.280          ← CORRECT (0.065 from before + 0.215 new)
├── total_cost: 3.22          ← NOT 38520.51!
├── devices/...
└── buildings/...
```

✅ **If you see this structure, it's working!**

---

## Step 5: Verify No DVC Data

Make sure no mock devices are in history:

Go to Firebase Console → `history/daily/2026-05-15/devices/`:
- Should only see: `ESP32-ROOM101-001` ✓
- Should NOT see: `DVC-ADMIN-*`, `DVC-GYM-*`, etc. ✓

Go to Firebase Console → `history/daily/2026-05-15/buildings/GYM/`:
- Should only see: `0.215 kWh` (not `1000+ kWh`) ✓
- Should NOT see: old `totals` field ✓

---

## Rollback Plan (if needed)

If something goes wrong:

### Option 1: Stop the Function
```bash
firebase functions:delete historyWriter --confirm
```

Then restore from backup manually via Firebase Console.

### Option 2: Restore Backup
```bash
firebase database:set history/daily backup_daily.json
firebase database:set history/weekly backup_weekly.json
firebase database:set history/monthly backup_monthly.json
firebase database:set history/yearly backup_yearly.json
```

### Option 3: Keep Both Functions (Safe)
Deploy the new one with a different name first:
```bash
# Rename historyWriter_fixed to historyWriter_v2
exports.historyWriter_v2 = historyWriterModule.historyWriter;

firebase deploy --only functions:historyWriter_v2
```

Test it, then:
```bash
# Delete old one once v2 is stable
firebase functions:delete historyWriter --confirm

# Rename v2 back to historyWriter
exports.historyWriter = historyWriterModule.historyWriter;
firebase deploy --only functions:historyWriter
```

---

## What Changed

### BEFORE (BROKEN)
```json
{
  "history/yearly/2026": {
    "total_kwh": 38520.51,     ← WRONG!
    "devices": {
      "ESP32-ROOM101-001": { "kwh": 0.065 },
      "DVC-ADMIN-036": { "kwh": 1240.123 },  ← Mock data
      "DVC-ADMIN-037": { "kwh": 2341.456 },  ← Mock data
      ... 30+ more mock devices ...
    },
    "totals": {                 ← Old field (confusing)
      "DVC-ADMIN-036": {...},
      ...
    }
  }
}
```

### AFTER (FIXED)
```json
{
  "history/yearly/2026": {
    "total_kwh": 0.065,         ← CORRECT!
    "total_cost": 0.7475,
    "devices": {
      "ESP32-ROOM101-001": {
        "kwh": 0.065,
        "cost": 0.7475,
        "building": "GYM",
        "room": "Room101",
        "timestamp": 1715782849000
      }
    },
    "buildings": {
      "GYM": {
        "kwh": 0.065,
        "cost": 0.7475,
        "rooms": {
          "Room101": {
            "kwh": 0.065,
            "cost": 0.7475
          }
        }
      }
    }
  }
}
```

---

## Troubleshooting

### Q: Cleanup script won't run
**A:** Check that:
- `serviceAccountKey.json` exists in `functions/` folder
- Firebase Admin SDK is installed: `npm install firebase-admin`
- You're running from `functions/` directory

### Q: Function deployed but not writing history
**A:** Check:
- Function status is **GREEN** in Firebase Console → Functions
- Device exists with `source: "real_iot"` in `master_devices`
- Check function **Logs** tab for errors

### Q: Data looks wrong after cleanup
**A:** Restore from backup:
```bash
firebase database:set history/daily backup_daily.json
firebase database:set history/weekly backup_weekly.json
firebase database:set history/monthly backup_monthly.json
firebase database:set history/yearly backup_yearly.json
```

---

## FAQ

**Q: Do I need Blaze plan for this?**
- No, cleanup script runs locally
- Yes, to deploy the Cloud Function (but you can skip that if you don't have Blaze)
- Flutter app history writing works on Spark (free) plan

**Q: Will this affect currently running devices?**
- No, only future readings will use the new function
- Historical data is only cleaned once (Step 2)

**Q: What if I add a new real IoT device?**
- Update `master_devices/{NEW_DEVICE_ID}` with `"source": "real_iot"`
- Function will automatically start writing its history
- No code changes needed

**Q: Can I exclude a device temporarily?**
- Yes, delete it or change `source` to anything other than `"real_iot"`
- Function will skip it on next telemetry push

---

## Next Steps

After deployment:

1. **Monitor function logs** for 24 hours (Firebase Console → Functions → Logs)
2. **Spot-check** a few history entries to verify data looks right
3. **Check cost calculations** are correct (should match electricity rate × kWh)
4. **Consider enabling archived mock data** (optional — keep DVC devices in separate history path)

---

## Files Created

- **`cleanup_history.js`** — Removes old mock data (run once, locally)
- **`history_writer_fixed.js`** — New Cloud Function (deploy to Firebase)
- **`DEPLOYMENT_GUIDE.md`** — This file

---

## Support

If issues persist, check:
1. Device exists in `master_devices` with `source === "real_iot"`
2. Function logs in Firebase Console
3. Database structure matches expected format (no stray "totals" fields)
4. Electricity rate is set: `settings/electricityRate`

