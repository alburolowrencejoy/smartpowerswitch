/**
 * Fixed History Writer Cloud Function
 * 
 * - Only writes history for real IoT devices (source === "real_iot")
 * - Removes mock DVC device data from totals
 * - Calculates per-building and per-room aggregations
 * - Uses transactions for concurrent write safety
 * 
 * Deploy with: firebase deploy --only functions:historyWriter
 */

const functions = require('firebase-functions');
const admin = require('firebase-admin');

admin.initializeApp();

function pad(n) {
  return String(n).padStart(2, '0');
}

function getDailyKey(date) {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

function getWeeklyKey(date) {
  const startOfYear = new Date(date.getFullYear(), 0, 1);
  const firstMonday = startOfYear.getDay();
  const dayOfYear = Math.floor((date - startOfYear) / (24 * 60 * 60 * 1000)) + 1;
  const weekNumber = Math.ceil((dayOfYear + firstMonday - 2) / 7);
  return `${date.getFullYear()}-W${pad(Math.max(1, weekNumber))}`;
}

function getMonthlyKey(date) {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}`;
}

function getYearlyKey(date) {
  return `${date.getFullYear()}`;
}

/**
 * Check if this device is a real IoT device (not mock)
 */
async function isRealIotDevice(deviceId) {
  try {
    const snap = await admin.database().ref(`master_devices/${deviceId}`).get();
    if (!snap.exists()) {
      return false;
    }
    const data = snap.val();
    return data.source === 'real_iot';
  } catch (error) {
    console.error(`[history_writer] Error checking device ${deviceId}:`, error.message);
    return false;
  }
}

/**
 * Get device details (building, room)
 */
async function getDeviceInfo(deviceId) {
  try {
    const snap = await admin.database().ref(`master_devices/${deviceId}`).get();
    if (!snap.exists()) {
      return { building: 'Unknown', room: 'Unknown' };
    }
    const data = snap.val();
    return {
      building: data.building || 'Unknown',
      room: data.room || 'Unknown',
      utility: data.utility || 'Unknown',
    };
  } catch (error) {
    console.error(`[history_writer] Error getting device info for ${deviceId}:`, error.message);
    return { building: 'Unknown', room: 'Unknown' };
  }
}

/**
 * Get current electricity rate
 */
async function getRate() {
  try {
    const snap = await admin.database().ref('settings/electricityRate').get();
    return (snap.val() ?? 11.5);
  } catch (error) {
    console.error('[history_writer] Error fetching rate:', error.message);
    return 11.5;
  }
}

/**
 * Write history for a single device across all time periods
 */
async function writeHistoryForDevice(deviceId, building, room, kwh) {
  if (!deviceId || !building || typeof kwh !== 'number' || kwh <= 0) {
    return;
  }

  try {
    const rate = await getRate();
    const cost = kwh * rate;
    const now = new Date();

    const periods = {
      'daily': getDailyKey(now),
      'weekly': getWeeklyKey(now),
      'monthly': getMonthlyKey(now),
      'yearly': getYearlyKey(now),
    };

    const db = admin.database();
    const promises = [];

    for (const [range, period] of Object.entries(periods)) {
      const basePath = `history/${range}/${period}`;

      // Write per-device entry with all metadata
      promises.push(
        db.ref(`${basePath}/devices/${deviceId}`).update({
          kwh: kwh,
          cost: cost,
          building: building,
          room: room,
          timestamp: Date.now(),
        }).catch(err => {
          console.error(`[history_writer] Error writing device entry ${basePath}/devices/${deviceId}:`, err.message);
        })
      );

      // Update period total_kwh with transaction
      promises.push(
        db.ref(`${basePath}/total_kwh`).transaction((current) => {
          const prev = (current ?? 0);
          const updated = parseFloat((prev + kwh).toFixed(6));
          return updated;
        }).catch(err => {
          console.error(`[history_writer] Error updating total_kwh at ${basePath}:`, err.message);
        })
      );

      // Update period total_cost with transaction
      promises.push(
        db.ref(`${basePath}/total_cost`).transaction((current) => {
          const prev = (current ?? 0);
          const updated = parseFloat((prev + cost).toFixed(6));
          return updated;
        }).catch(err => {
          console.error(`[history_writer] Error updating total_cost at ${basePath}:`, err.message);
        })
      );

      // Update per-building kwh
      promises.push(
        db.ref(`${basePath}/buildings/${building}/kwh`).transaction((current) => {
          const prev = (current ?? 0);
          const updated = parseFloat((prev + kwh).toFixed(6));
          return updated;
        }).catch(err => {
          console.error(`[history_writer] Error updating building kwh at ${basePath}:`, err.message);
        })
      );

      // Update per-building cost
      promises.push(
        db.ref(`${basePath}/buildings/${building}/cost`).transaction((current) => {
          const prev = (current ?? 0);
          const updated = parseFloat((prev + cost).toFixed(6));
          return updated;
        }).catch(err => {
          console.error(`[history_writer] Error updating building cost at ${basePath}:`, err.message);
        })
      );

      // Update per-room kwh (under building)
      promises.push(
        db.ref(`${basePath}/buildings/${building}/rooms/${room}/kwh`).transaction((current) => {
          const prev = (current ?? 0);
          const updated = parseFloat((prev + kwh).toFixed(6));
          return updated;
        }).catch(err => {
          console.error(`[history_writer] Error updating room kwh at ${basePath}:`, err.message);
        })
      );

      // Update per-room cost (under building)
      promises.push(
        db.ref(`${basePath}/buildings/${building}/rooms/${room}/cost`).transaction((current) => {
          const prev = (current ?? 0);
          const updated = parseFloat((prev + cost).toFixed(6));
          return updated;
        }).catch(err => {
          console.error(`[history_writer] Error updating room cost at ${basePath}:`, err.message);
        })
      );
    }

    await Promise.all(promises);
  } catch (error) {
    console.error(`[history_writer] Error writing history for ${deviceId}:`, error.message);
  }
}

/**
 * Cloud Function trigger: on write to /devices/{deviceId}
 * 
 * Only processes real IoT devices. Skips mock devices.
 */
exports.historyWriter = functions.database
  .ref('/devices/{deviceId}')
  .onWrite(async (change, context) => {
    const deviceId = context.params.deviceId;

    // Only process real IoT devices
    const isReal = await isRealIotDevice(deviceId);
    if (!isReal) {
      console.log(`[history_writer] Skipping mock device: ${deviceId}`);
      return;
    }

    console.log(`[history_writer] Processing real IoT device: ${deviceId}`);

    try {
      const after = change.after.val();
      if (!after) {
        return; // Device was deleted
      }

      // Extract kWh from the update
      const kwh = after.kwh ?? 0;
      if (typeof kwh !== 'number' || kwh <= 0) {
        console.log(`[history_writer] Invalid or zero kWh for ${deviceId}, skipping history`);
        return;
      }

      // Get device building and room info
      const info = await getDeviceInfo(deviceId);

      // Write history
      await writeHistoryForDevice(deviceId, info.building, info.room, kwh);

      console.log(
        `[history_writer] ✓ History written for ${deviceId}: ${kwh.toFixed(6)} kWh (${info.building}/${info.room})`
      );
    } catch (error) {
      console.error(`[history_writer] Fatal error processing ${deviceId}:`, error.message);
      throw error; // Retry the function
    }
  });

/**
 * Optional: Manual cleanup function (run once)
 * Usage: firebase functions:shell -> cleanupMockDeviceHistory()
 */
exports.cleanupMockDeviceHistory = functions.https.onCall(async (data, context) => {
  // Verify user is admin
  if (!context.auth || context.auth.token.admin !== true) {
    throw new functions.https.HttpsError(
      'permission-denied',
      'Only admins can run cleanup'
    );
  }

  console.log('[cleanup] Starting manual cleanup of mock devices...');
  // Implementation would be similar to cleanup_history.js
  // but triggered via HTTPS instead of CLI
  return { status: 'cleanup_not_implemented_in_cloud_function' };
});
