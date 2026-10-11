/**
 * Mock device cleanup (master plan Phase 4).
 *
 * Finds mock `DVC-*` devices wherever they are -- the registry
 * (`master_devices`) AND entries that exist only in `devices` (the old
 * script missed those) -- and removes them from `master_devices`,
 * `devices` and the old per-floor copies under `buildings/.../floorData`.
 *
 * Safe by default:
 * - DRY RUN unless `--apply` is passed (prints what it would do);
 * - never deletes a registered device just because its `source` isn't
 *   `real_iot`: anything that is neither `real_iot` nor a `DVC-*` ID is
 *   reported as UNKNOWN for a person to decide;
 * - all deletions happen in one atomic multi-path update.
 * Take a backup first: firebase database:get / -o backups/rtdb-full-<stamp>.json
 *
 * Usage (from functions/):
 *   node remove_mock_devices.js            # dry run
 *   node remove_mock_devices.js --apply    # delete the listed mocks
 */

const admin = require('firebase-admin');

const MOCK_ID = /^DVC-/i;

/** Pure: what to delete and what to report, from the three snapshots. */
function planCleanup({ master = {}, devices = {}, buildings = {} }) {
  const real = [];
  const mocks = new Set();
  const unknown = [];
  const orphans = [];

  for (const [id, entry] of Object.entries(master || {})) {
    if (MOCK_ID.test(id)) mocks.add(id);
    else if (entry && entry.source === 'real_iot') real.push(id);
    else unknown.push(id);
  }
  for (const id of Object.keys(devices || {})) {
    if (master && master[id]) continue;
    if (MOCK_ID.test(id)) mocks.add(id);
    else orphans.push(id);
  }

  const updates = {};
  for (const id of mocks) {
    if (master && master[id]) updates[`master_devices/${id}`] = null;
    if (devices && devices[id]) updates[`devices/${id}`] = null;
  }
  for (const [code, b] of Object.entries(buildings || {})) {
    const floors = (b && b.floorData) || {};
    for (const [floor, f] of Object.entries(floors)) {
      for (const id of Object.keys((f && f.devices) || {})) {
        if (mocks.has(id)) updates[`buildings/${code}/floorData/${floor}/devices/${id}`] = null;
      }
    }
  }
  return { real, mocks: [...mocks].sort(), unknown, orphans, updates };
}

async function main() {
  const apply = process.argv.includes('--apply');
  const serviceAccount = require('./serviceAccountKey.json');
  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount),
    databaseURL: 'https://smartpowerswitch-e90d0-default-rtdb.asia-southeast1.firebasedatabase.app',
  });
  const db = admin.database();

  const [master, devices, buildings] = await Promise.all(
    ['master_devices', 'devices', 'buildings'].map(async (p) => (await db.ref(p).get()).val()));
  const plan = planCleanup({ master, devices, buildings });

  console.log(`Real IoT (kept):            ${plan.real.join(', ') || '-'}`);
  console.log(`Mock DVC-* (to remove):     ${plan.mocks.length}`);
  console.log(`UNKNOWN registered (kept):  ${plan.unknown.join(', ') || '-'}  <- decide by hand`);
  console.log(`Orphans in devices (kept):  ${plan.orphans.join(', ') || '-'}  <- not registered, not DVC-*`);
  console.log(`Paths to delete:            ${Object.keys(plan.updates).length}`);

  if (!apply) {
    console.log('\nDry run: nothing deleted. Re-run with --apply to delete the mocks.');
    return;
  }
  if (Object.keys(plan.updates).length === 0) {
    console.log('Nothing to delete.');
    return;
  }
  await db.ref().update(plan.updates);
  console.log('Deleted.');
}

if (require.main === module) {
  main().then(() => process.exit(0), (err) => {
    console.error('Fatal:', err);
    process.exit(1);
  });
}

module.exports = { planCleanup };
