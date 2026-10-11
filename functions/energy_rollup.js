// Once-a-minute energy rollup: the ONLY writer of energy history.
// Reads the registry, each real board's meter, meterState and the rate,
// lets energy_math.planRollup() work out the result, and writes it in one
// atomic multi-path update (totals and baselines together), so a failed run
// changes nothing and the next run counts the same energy.
'use strict';

const admin = require('firebase-admin');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { planRollup, toUpdate, isRealDevice } = require('./energy_math');

const LOCK_PATH = 'rollup/lock';
const TIMEOUT_SECONDS = 50;
// Longer than the function timeout: a run that is still alive always holds
// an unexpired lease, so an expired lease means the previous run has ended
// (Cloud Functions stops a run at its timeout).
const LEASE_MS = 120 * 1000;

/** Takes the lock unless another run holds an unexpired lease. */
async function acquireLock(db, runId, nowMs) {
  const res = await db.ref(LOCK_PATH).transaction((cur) => {
    if (cur && cur.owner !== runId && cur.until > nowMs) return undefined; // abort
    return { owner: runId, until: nowMs + LEASE_MS };
  });
  return res.committed && res.snapshot.val()?.owner === runId;
}

// RTDB calls a transaction handler first with the locally cached value, which
// is null when this client hasn't read the node yet. Answering null with a
// no-op (null) makes the server re-run the handler with the real value;
// returning undefined there would abort without ever asking the server.

/** True if [runId] still owns the lock (checked right before writing). */
async function stillOwner(db, runId) {
  const res = await db.ref(LOCK_PATH).transaction((cur) => {
    if (cur === null) return null;
    return cur.owner === runId ? cur : undefined;
  });
  return res.committed && res.snapshot.val()?.owner === runId;
}

/** Releases the lock only if [runId] owns it, never a newer run's lock. */
async function releaseLock(db, runId) {
  await db.ref(LOCK_PATH).transaction((cur) => {
    if (cur === null) return null;
    return cur.owner === runId ? null : undefined;
  });
}

async function readInputs(db) {
  const [registrySnap, stateSnap, rateSnap] = await Promise.all([
    db.ref('master_devices').get(),
    db.ref('meterState').get(),
    db.ref('settings/electricityRate').get(),
  ]);
  const registry = registrySnap.val() ?? {};
  const ids = Object.keys(registry).filter((id) => isRealDevice(registry[id]));
  // Firmware v2 reports the meter in device_live (Phase 5); boards still on
  // the old firmware report it in devices/{id}/kwh.
  const kwhSnaps = await Promise.all(ids.map(async (id) => {
    const live = (await db.ref(`device_live/${id}/telemetry/cumulativeKwh`).get()).val();
    if (live !== null && live !== undefined) return live;
    return (await db.ref(`devices/${id}/kwh`).get()).val();
  }));
  return {
    registry,
    kwhById: Object.fromEntries(ids.map((id, i) => [id, kwhSnaps[i]])),
    meterState: stateSnap.val() ?? {},
    rate: rateSnap.val(),
  };
}

/**
 * One rollup run. [nowMs], [runId] and [increment] are injectable for tests.
 * Returns { status, ... } where status is 'written', 'no-new-data',
 * 'skipped-locked', 'lost-lock' or 'invalid-rate'.
 */
async function runRollup(db, {
  nowMs = Date.now(),
  runId = `${nowMs}-${Math.random().toString(36).slice(2, 10)}`,
  increment = admin.database.ServerValue.increment,
} = {}) {
  if (!(await acquireLock(db, runId, nowMs))) {
    console.log('[rollupEnergy] another run holds the lock; skipping');
    return { status: 'skipped-locked' };
  }
  try {
    const plan = planRollup({ ...(await readInputs(db)), nowMs });
    if (!plan.ok) {
      console.error(`[rollupEnergy] not written: ${plan.reason} (settings/electricityRate)`);
      return { status: plan.reason };
    }

    const update = toUpdate(plan, increment);
    const paths = Object.keys(update).length;
    if (paths === 0) return { status: 'no-new-data' };

    if (!(await stillOwner(db, runId))) {
      console.warn('[rollupEnergy] lost the lock before writing; skipping');
      return { status: 'lost-lock' };
    }
    await db.ref().update(update);
    console.log(`[rollupEnergy] ${plan.keys.daily}: ${plan.devicesCounted} device(s) counted, ` +
      `${plan.anomalies} anomaly(ies), ${paths} path(s)`);
    return { status: 'written', devicesCounted: plan.devicesCounted, anomalies: plan.anomalies, paths };
  } finally {
    await releaseLock(db, runId);
  }
}

const rollupEnergy = onSchedule({
  schedule: 'every 1 minutes',
  timeZone: 'Asia/Manila',
  region: 'asia-southeast1',
  maxInstances: 1,
  concurrency: 1,
  timeoutSeconds: TIMEOUT_SECONDS,
  retryCount: 0, // a missed run is simply caught up by the next one
}, async () => {
  await runRollup(admin.database());
});

module.exports = {
  rollupEnergy,
  runRollup,
  acquireLock,
  stillOwner,
  releaseLock,
  LOCK_PATH,
  LEASE_MS,
};
