/**
 * Cleanup script to remove mock DVC devices from history
 * and recalculate totals using only real IoT devices.
 * 
 * Usage:
 *   1. npm install firebase-admin
 *   2. Download service account key to serviceAccountKey.json
 *   3. node cleanup_history.js
 */

const admin = require('firebase-admin');
const serviceAccount = require('./serviceAccountKey.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  databaseURL: 'https://smartpowerswitch-e90d0-default-rtdb.asia-southeast1.firebasedatabase.app',
});

const db = admin.database();

async function getRealIotDevices() {
  console.log('[Cleanup] Identifying real IoT devices...');
  const snap = await db.ref('master_devices').get();
  if (!snap.exists()) {
    console.log('  ✗ No devices found');
    return [];
  }

  const devices = snap.val();
  const realIot = [];
  const mock = [];

  for (const [id, data] of Object.entries(devices)) {
    const source = data.source || '';
    if (source === 'real_iot') {
      realIot.push(id);
      console.log(`  ✓ Real IoT: ${id}`);
    } else {
      mock.push(id);
      console.log(`  ✗ Mock/Unassigned: ${id}`);
    }
  }

  console.log(`\nFound ${realIot.length} real IoT devices.\n`);
  return { realIot, mock };
}

async function cleanupHistoryPeriod(range, period, realIotDevices) {
  const path = `history/${range}/${period}`;
  const snap = await db.ref(path).get();

  if (!snap.exists()) {
    return null;
  }

  const data = snap.val();
  let recalculatedKwh = 0;
  let recalculatedCost = 0;
  const cleanedDevices = {};

  // Rebuild devices object with only real IoT devices
  if (data.devices) {
    for (const [deviceId, deviceData] of Object.entries(data.devices)) {
      if (realIotDevices.includes(deviceId)) {
        cleanedDevices[deviceId] = deviceData;
        recalculatedKwh += (deviceData.kwh || 0);
        recalculatedCost += (deviceData.cost || 0);
      }
    }
  }

  // Round to 6 decimals to avoid floating point errors
  recalculatedKwh = parseFloat(recalculatedKwh.toFixed(6));
  recalculatedCost = parseFloat(recalculatedCost.toFixed(6));

  // Prepare clean update object
  const updates = {
    'total_kwh': recalculatedKwh,
    'total_cost': recalculatedCost,
    'devices': cleanedDevices,
  };

  // Remove "totals" field if it exists (was mixing real + mock deltas)
  // and remove old building data to be recalculated

  // Perform atomic write
  await db.ref(path).set(updates, (err) => {
    if (err) {
      console.error(`  Error writing ${path}:`, err);
    }
  });

  return { kwh: recalculatedKwh, cost: recalculatedCost };
}

async function rebuildBuildingTotals(range, period, realIotDevices) {
  const path = `history/${range}/${period}`;
  const snap = await db.ref(path).get();

  if (!snap.exists()) {
    return;
  }

  const data = snap.val();
  const buildingTotals = {};

  // Sum buildings from cleaned devices
  if (data.devices) {
    for (const [deviceId, deviceData] of Object.entries(data.devices)) {
      if (realIotDevices.includes(deviceId)) {
        const building = deviceData.building || 'Unknown';
        if (!buildingTotals[building]) {
          buildingTotals[building] = { kwh: 0, cost: 0 };
        }
        buildingTotals[building].kwh += (deviceData.kwh || 0);
        buildingTotals[building].cost += (deviceData.cost || 0);
      }
    }
  }

  // Round to 6 decimals
  for (const building of Object.keys(buildingTotals)) {
    buildingTotals[building].kwh = parseFloat(buildingTotals[building].kwh.toFixed(6));
    buildingTotals[building].cost = parseFloat(buildingTotals[building].cost.toFixed(6));
  }

  // Write clean building totals
  await db.ref(`${path}/buildings`).set(buildingTotals);
}

async function cleanupRange(range, realIotDevices) {
  console.log(`[Cleanup] Processing ${range} history...`);

  const snap = await db.ref(`history/${range}`).get();
  if (!snap.exists()) {
    console.log(`  ✗ No ${range} data found`);
    return;
  }

  const periods = snap.val();
  let periodCount = 0;

  for (const [period, periodData] of Object.entries(periods)) {
    // Skip metadata keys (avoid treating them as date entries)
    if (period === 'deleted') {
      continue;
    }

    // Skip non-object values
    if (typeof periodData !== 'object' || periodData === null) {
      continue;
    }

    // Skip if it looks like it doesn't have device/building structure
    if (!periodData.devices && !periodData.buildings && !periodData.total_kwh) {
      continue;
    }

    try {
      const result = await cleanupHistoryPeriod(range, period, realIotDevices);
      if (result) {
        await rebuildBuildingTotals(range, period, realIotDevices);
        console.log(
          `  ✓ ${period}: ${result.kwh.toFixed(6)} kWh / ${result.cost.toFixed(6)} ₱`
        );
        periodCount++;
      }
    } catch (err) {
      console.error(`  Error cleaning ${range}/${period}:`, err.message);
    }
  }

  console.log(`  Cleaned ${periodCount} periods\n`);
}

async function cleanup() {
  console.log('\n========================================');
  console.log('  History Cleanup - Remove Mock Devices');
  console.log('========================================\n');

  try {
    const { realIot, mock } = await getRealIotDevices();

    if (realIot.length === 0) {
      console.log('[Cleanup] No real IoT devices found. Skipping cleanup.');
      process.exit(0);
    }

    // Clean each history range
    await cleanupRange('daily', realIot);
    await cleanupRange('weekly', realIot);
    await cleanupRange('monthly', realIot);
    await cleanupRange('yearly', realIot);

    console.log('[Cleanup] ✓ History cleanup complete!');
    console.log(`[Cleanup] Real IoT devices kept: ${realIot.join(', ')}`);
    console.log(`[Cleanup] Mock devices removed: ${mock.length}`);
  } catch (error) {
    console.error('[Cleanup] Fatal error:', error);
    process.exit(1);
  }

  // Exit gracefully
  setTimeout(() => {
    process.exit(0);
  }, 2000);
}

cleanup();
