// History Writer: Automatically writes PZEM readings to organized history database
// Format: history/{range}/{period}/ with total_kwh, total_cost, devices/, buildings/
// Compatible with _exportOrganizedXlsx() in history_screen.dart

const admin = require('firebase-admin');

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

async function getRate() {
  const snap = await admin.database().ref('settings/electricityRate').get();
  return (snap.val() ?? 11.5);
}

async function writeHistoryForDevice(deviceId, building, kwh) {
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
    const updates = {};

    for (const [range, period] of Object.entries(periods)) {
      const basePath = `history/${range}/${period}`;

      // Write per-device entry (export-compatible format)
      updates[`${basePath}/devices/${deviceId}`] = {
        kwh: kwh,
        cost: cost,
        building: building,
      };
    }

    // Batch update all period totals using transactions
    const promises = [];

    for (const [range, period] of Object.entries(periods)) {
      const basePath = `history/${range}/${period}`;

      // Update period total_kwh (used by export)
      promises.push(
        db.ref(`${basePath}/total_kwh`).transaction((current) => {
          const prev = (current ?? 0);
          const updated = parseFloat((prev + kwh).toFixed(4));
          return updated;
        })
      );

      // Update period total_cost (used by export)
      promises.push(
        db.ref(`${basePath}/total_cost`).transaction((current) => {
          const prev = (current ?? 0);
          const updated = parseFloat((prev + cost).toFixed(4));
          return updated;
        })
      );

      // Update per-building kwh
      promises.push(
        db.ref(`${basePath}/buildings/${building}/kwh`).transaction((current) => {
          const prev = (current ?? 0);
          const updated = parseFloat((prev + kwh).toFixed(4));
          return updated;
        })
      );

      // Update per-building cost
      promises.push(
        db.ref(`${basePath}/buildings/${building}/cost`).transaction((current) => {
          const prev = (current ?? 0);
          const updated = parseFloat((prev + cost).toFixed(4));
          return updated;
        })
      );
    }

    // Apply all batch updates
    await db.ref().update(updates);
    await Promise.all(promises);

    console.log(
      `[HistoryWriter] Recorded ${deviceId}: ${kwh.toFixed(2)} kWh (₱${cost.toFixed(2)}) in ${building}`
    );
  } catch (error) {
    console.error(
      `[HistoryWriter] Failed to write history for ${deviceId}: ${error.message}`
    );
  }
}

module.exports = {
  writeHistoryForDevice,
};
