/**
 * Complete Mock Device Removal Script
 * 
 * Removes ALL traces of mock DVC devices from:
 * - /devices/ (live telemetry)
 * - /readings/ (historical readings)
 * - /master_devices/ (device registry)
 * 
 * Usage:
 *   npm install firebase-admin
 *   node remove_mock_devices.js
 */

const admin = require('firebase-admin');
const serviceAccount = require('./serviceAccountKey.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  databaseURL: 'https://smartpowerswitch-e90d0-default-rtdb.asia-southeast1.firebasedatabase.app',
});

const db = admin.database();

async function removeMockDevices() {
  console.log('\n========================================');
  console.log('  Remove All Mock Devices');
  console.log('========================================\n');

  try {
    // Get all devices first to identify mocks
    const snap = await db.ref('master_devices').get();
    if (!snap.exists()) {
      console.log('[Remove] No devices found');
      process.exit(0);
    }

    const devices = snap.val();
    const mockDevices = [];
    const realDevices = [];

    for (const [id, data] of Object.entries(devices)) {
      const source = data.source || '';
      if (source === 'real_iot') {
        realDevices.push(id);
        console.log(`  ✓ Keeping real IoT: ${id}`);
      } else {
        mockDevices.push(id);
        console.log(`  ✗ Will remove mock: ${id}`);
      }
    }

    console.log(`\nFound ${realDevices.length} real IoT device(s)`);
    console.log(`Found ${mockDevices.length} mock device(s) to remove\n`);

    if (mockDevices.length === 0) {
      console.log('[Remove] No mock devices to remove');
      process.exit(0);
    }

    // Remove from /devices/
    console.log('[Remove] Cleaning /devices/...');
    for (const deviceId of mockDevices) {
      try {
        await db.ref(`devices/${deviceId}`).remove();
        console.log(`  ✓ Removed /devices/${deviceId}`);
      } catch (err) {
        console.error(`  ✗ Error removing /devices/${deviceId}:`, err.message);
      }
    }

    // Remove from /readings/
    console.log('\n[Remove] Cleaning /readings/...');
    for (const deviceId of mockDevices) {
      try {
        await db.ref(`readings/${deviceId}`).remove();
        console.log(`  ✓ Removed /readings/${deviceId}`);
      } catch (err) {
        console.error(`  ✗ Error removing /readings/${deviceId}:`, err.message);
      }
    }

    // Remove from /master_devices/
    console.log('\n[Remove] Cleaning /master_devices/...');
    for (const deviceId of mockDevices) {
      try {
        await db.ref(`master_devices/${deviceId}`).remove();
        console.log(`  ✓ Removed /master_devices/${deviceId}`);
      } catch (err) {
        console.error(`  ✗ Error removing /master_devices/${deviceId}:`, err.message);
      }
    }

    console.log('\n========================================');
    console.log('[Remove] ✓ Mock device removal complete!');
    console.log(`[Remove] Kept: ${realDevices.join(', ')}`);
    console.log(`[Remove] Removed: ${mockDevices.length} mock devices`);
    console.log('========================================\n');
  } catch (error) {
    console.error('[Remove] Fatal error:', error);
    process.exit(1);
  }

  // Exit gracefully
  setTimeout(() => {
    process.exit(0);
  }, 2000);
}

removeMockDevices();
