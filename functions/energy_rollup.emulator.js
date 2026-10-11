// Integration tests for the energy rollup against the Realtime Database
// EMULATOR (never the live project). Run from functions/ with:
//   npm run test:emulator
// (needs JAVA_HOME pointing at a JDK 17+; firebase-tools 13 is used because
// the installed CLI 15 requires Java 21 for the emulators)
// The file name deliberately doesn't end in .test.js, so plain `npm test`
// (no emulator running) doesn't pick it up.
const test = require('node:test');
const assert = require('node:assert');
const admin = require('firebase-admin');

if (!process.env.FIREBASE_DATABASE_EMULATOR_HOST) {
  throw new Error('FIREBASE_DATABASE_EMULATOR_HOST is not set: run via `npm run test:emulator`.');
}

const PROJECT = 'demo-smartswitch';
admin.initializeApp({
  projectId: PROJECT,
  databaseURL: `http://${process.env.FIREBASE_DATABASE_EMULATOR_HOST}?ns=${PROJECT}`,
});
const db = admin.database();

const { runRollup, acquireLock, stillOwner, releaseLock, LOCK_PATH } = require('./energy_rollup');
const { UNASSIGNED } = require('./energy_math');

const MIN = 60 * 1000;
const T0 = Date.UTC(2026, 9, 10, 2, 0); // 2026-10-10 10:00 PH
const RATE = 13.24;
const close = (a, b, msg) => assert.ok(Math.abs(a - b) < 1e-9, `${msg ?? ''} expected ${b}, got ${a}`);

async function seed({ rate = RATE } = {}) {
  await db.ref().set({
    settings: { electricityRate: rate },
    master_devices: {
      'ESP32-A': { source: 'real_iot', assignedTo: 'IC/1/Room 101' },
      'ESP32-B': { source: 'real_iot', assignedTo: 'IC/2/Room 201' },
      'ESP32-C': { source: 'real_iot', assignedTo: '' },
      'DVC-IC-001': { assignedTo: 'IC/1/Room 101' }, // mock
    },
    devices: {
      'ESP32-A': { kwh: 1.0 }, 'ESP32-B': { kwh: 2.0 }, 'ESP32-C': { kwh: 3.0 }, 'DVC-IC-001': { kwh: 0 },
    },
  });
}

const setKwh = (kwhs) => db.ref('devices').update(
  Object.fromEntries(Object.entries(kwhs).map(([id, kwh]) => [`${id}/kwh`, kwh])));
const get = async (path) => (await db.ref(path).get()).val();

test.after(async () => {
  await db.ref().set(null);
  await admin.app().delete();
});

test('first run only sets baselines; later runs count deltas; totals reconcile', async () => {
  await seed();
  assert.strictEqual((await runRollup(db, { nowMs: T0 })).status, 'written'); // baselines only
  assert.strictEqual(await get('energy_summaries'), null);
  assert.strictEqual((await get('meterState/ESP32-A')).lastAcceptedKwh, 1.0);
  assert.strictEqual(await get('meterState/DVC-IC-001'), null);

  await setKwh({ 'ESP32-A': 1.002, 'ESP32-B': 2.003, 'ESP32-C': 3.004, 'DVC-IC-001': 5 });
  const r = await runRollup(db, { nowMs: T0 + MIN });
  assert.strictEqual(r.status, 'written');
  assert.strictEqual(r.devicesCounted, 3);

  await setKwh({ 'ESP32-A': 1.010 });
  await runRollup(db, { nowMs: T0 + 2 * MIN });

  for (const [range, key] of [['daily', '2026-10-10'], ['hourly', '2026-10-10-10'],
    ['weekly', '2026-W41'], ['monthly', '2026-10'], ['yearly', '2026']]) {
    const s = await get(`energy_summaries/${range}/${key}`);
    close(s.devices['ESP32-A'].kwh, 0.010, `${range} A`); // 0.002 + 0.008 across two runs
    close(s.devices['ESP32-B'].kwh, 0.003, `${range} B`);
    close(s.devices['ESP32-C'].kwh, 0.004, `${range} C`);
    close(s.buildings.IC.kwh, 0.013, `${range} IC`);
    close(s.buildings[UNASSIGNED].kwh, 0.004, `${range} unassigned`);
    close(s.campus.kwh, 0.017, `${range} campus`);
    close(s.campus.kwh, s.buildings.IC.kwh + s.buildings[UNASSIGNED].kwh);
    close(s.campus.cost, 0.017 * RATE, `${range} cost`);
    assert.strictEqual(s.devices['ESP32-A'].building, 'IC');
    assert.ok(!JSON.stringify(s).includes('DVC-'), 'mock device leaked into history');
  }
  assert.strictEqual(await get(LOCK_PATH), null, 'lock must be released');
});

test('no new data: nothing written, lock released', async () => {
  await seed();
  await runRollup(db, { nowMs: T0 });
  const before = await get('meterState');
  const r = await runRollup(db, { nowMs: T0 + MIN });
  assert.strictEqual(r.status, 'no-new-data');
  assert.deepStrictEqual(await get('meterState'), before);
  assert.strictEqual(await get('energy_summaries'), null);
  assert.strictEqual(await get(LOCK_PATH), null);
});

test('missing rate: nothing written; the next good run counts all of it', async () => {
  await seed();
  await runRollup(db, { nowMs: T0 });
  await db.ref('settings/electricityRate').remove();
  await setKwh({ 'ESP32-A': 1.5 });
  assert.strictEqual((await runRollup(db, { nowMs: T0 + MIN })).status, 'invalid-rate');
  assert.strictEqual(await get('energy_summaries'), null);
  assert.strictEqual((await get('meterState/ESP32-A')).lastAcceptedKwh, 1.0, 'baseline must not move');

  await db.ref('settings/electricityRate').set(RATE);
  await runRollup(db, { nowMs: T0 + 2 * MIN });
  close((await get('energy_summaries/daily/2026-10-10/campus/kwh')), 0.5);
});

test('energy after PH midnight goes to the new day', async () => {
  await seed();
  const beforeMidnight = Date.UTC(2026, 9, 10, 15, 58); // 23:58 PH
  await runRollup(db, { nowMs: beforeMidnight });
  await setKwh({ 'ESP32-A': 1.1 });
  await runRollup(db, { nowMs: beforeMidnight + MIN }); // 23:59 PH
  await setKwh({ 'ESP32-A': 1.3 });
  await runRollup(db, { nowMs: beforeMidnight + 3 * MIN }); // 00:01 PH, Oct 11
  close(await get('energy_summaries/daily/2026-10-10/campus/kwh'), 0.1);
  close(await get('energy_summaries/daily/2026-10-11/campus/kwh'), 0.2);
  close(await get('energy_summaries/monthly/2026-10/campus/kwh'), 0.3);
});

test('a drop is recorded once as an anomaly and nothing is counted', async () => {
  await seed();
  await runRollup(db, { nowMs: T0 });
  await setKwh({ 'ESP32-A': 0.2 });
  await runRollup(db, { nowMs: T0 + MIN });
  await runRollup(db, { nowMs: T0 + 2 * MIN });
  const anomalies = (await get('anomalies')) ?? {};
  assert.strictEqual(Object.keys(anomalies).length, 1);
  assert.strictEqual(Object.values(anomalies)[0].reason, 'decrease');
  assert.strictEqual((await get('meterState/ESP32-A')).flag.frozen, true);
  assert.strictEqual(await get('energy_summaries'), null);
});

test('a run is skipped while another run holds an unexpired lock', async () => {
  await seed();
  await runRollup(db, { nowMs: T0 });
  await db.ref(LOCK_PATH).set({ owner: 'other-run', until: T0 + 10 * MIN });
  await setKwh({ 'ESP32-A': 1.5 });
  assert.strictEqual((await runRollup(db, { nowMs: T0 + MIN })).status, 'skipped-locked');
  assert.strictEqual(await get('energy_summaries'), null);
  assert.deepStrictEqual(await get(LOCK_PATH), { owner: 'other-run', until: T0 + 10 * MIN },
    'must not release another run\'s lock');
  // Once that lease has expired, the next run proceeds and counts everything.
  const r = await runRollup(db, { nowMs: T0 + 11 * MIN });
  assert.strictEqual(r.status, 'written');
  close(await get('energy_summaries/daily/2026-10-10/campus/kwh'), 0.5);
});

test('firmware v2 boards are read from device_live; old boards from devices', async () => {
  await seed();
  // ESP32-A runs firmware v2: its devices/{id}/kwh goes stale, device_live is current.
  await db.ref('device_live/ESP32-A/telemetry/cumulativeKwh').set(1.0);
  await runRollup(db, { nowMs: T0 });
  await db.ref('device_live/ESP32-A/telemetry/cumulativeKwh').set(1.25);
  await setKwh({ 'ESP32-A': 99, 'ESP32-B': 2.3 }); // A's old field is ignored
  await runRollup(db, { nowMs: T0 + MIN });
  const day = await get('energy_summaries/daily/2026-10-10');
  close(day.devices['ESP32-A'].kwh, 0.25, 'A from device_live');
  close(day.devices['ESP32-B'].kwh, 0.3, 'B from devices');
});

test('lock helpers: only the owner keeps or releases the lock', async () => {
  await db.ref().set(null);
  assert.ok(await acquireLock(db, 'run-1', T0));
  assert.ok(!(await acquireLock(db, 'run-2', T0 + MIN)), 'second run must not take a live lease');
  assert.ok(await stillOwner(db, 'run-1'));
  // run-1 stalls past its lease; run-2 takes over.
  assert.ok(await acquireLock(db, 'run-2', T0 + 3 * MIN));
  assert.ok(!(await stillOwner(db, 'run-1')), 'stale run must see it lost the lock');
  await releaseLock(db, 'run-1');
  assert.strictEqual((await get(LOCK_PATH)).owner, 'run-2', 'stale run must not release the new lock');
  await releaseLock(db, 'run-2');
  assert.strictEqual(await get(LOCK_PATH), null);
});

test('two runs started together: exactly one counts the energy', async () => {
  await seed();
  await runRollup(db, { nowMs: T0 });
  await setKwh({ 'ESP32-A': 1.4 });
  const results = await Promise.all([
    runRollup(db, { nowMs: T0 + MIN, runId: 'x' }),
    runRollup(db, { nowMs: T0 + MIN, runId: 'y' }),
  ]);
  const statuses = results.map((r) => r.status).sort();
  assert.ok(statuses.includes('written'), `one run should write: ${statuses}`);
  close(await get('energy_summaries/daily/2026-10-10/campus/kwh'), 0.4, 'counted exactly once');
});

// ── Phase 6: retention and health check ──────────────────────────────────
const { runRetention, runHealthCheck } = require('./energy_maintenance');
const NOW6 = Date.UTC(2027, 9, 11, 2, 30); // 2027-10-11 10:30 PH

test('retention deletes hourly and anomalies older than a year, keeps the rest', async () => {
  await db.ref().set({
    energy_summaries: {
      hourly: { '2026-10-10-23': { campus: { kwh: 1 } }, '2027-10-11-09': { campus: { kwh: 1 } } },
      daily: { '2025-01-01': { campus: { kwh: 1 } } }, // daily is kept forever
    },
    anomalies: {
      [`${NOW6 - 400 * 24 * 3600 * 1000}_ESP32-A`]: { reason: 'spike' },
      [`${NOW6 - 5 * 24 * 3600 * 1000}_ESP32-A`]: { reason: 'spike' },
    },
  });
  assert.strictEqual(await runRetention(db, NOW6), 2);
  assert.deepStrictEqual(Object.keys(await get('energy_summaries/hourly')), ['2027-10-11-09']);
  assert.ok(await get('energy_summaries/daily/2025-01-01'));
  assert.strictEqual(Object.keys(await get('anomalies')).length, 1);
});

test('health check notifies once per problem and records the check', async () => {
  await db.ref().set({
    master_devices: { 'ESP32-A': { source: 'real_iot', assignedTo: 'IC/1/R1' } },
    meterState: { 'ESP32-A': { flag: { reason: 'drop', at: 5, frozen: true } } },
    rollup: { heartbeat: NOW6 - 10 * 60 * 1000 },
  });
  const first = await runHealthCheck(db, NOW6);
  assert.deepStrictEqual(first.map((a) => a.subtype), ['device_frozen']);
  const notes = Object.values(await get('notifications'));
  assert.strictEqual(notes.length, 1);
  assert.strictEqual(notes[0].type, 'system_alert');
  assert.strictEqual(notes[0].deviceId, 'ESP32-A');
  assert.strictEqual((await get('system_health/lastCheck')).alerts, 1);
  // Next hour, same problem: no second notification.
  assert.deepStrictEqual(await runHealthCheck(db, NOW6 + 3600 * 1000), []);
  assert.strictEqual(Object.keys(await get('notifications')).length, 1);
});
