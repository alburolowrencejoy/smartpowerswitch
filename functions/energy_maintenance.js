// Phase 6: retention and monitoring for the energy history.
//
// - pruneHistory (monthly): deletes hourly summaries and anomaly records
//   older than one year. Daily / weekly / monthly / yearly summaries are kept
//   forever (forecasts and year-over-year comparison need them).
// - checkEnergyHealth (hourly): raises a `system_alert` notification, once per
//   problem, when the energy rollup has stopped, a board's history is frozen
//   by an anomaly, a registered board has gone offline, or today's totals
//   don't add up.
// The planning logic is pure (tested in energy_maintenance.test.js); the
// scheduled functions only read, call it, and write.
'use strict';

const admin = require('firebase-admin');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { periodKeys, isRealDevice } = require('./energy_math');

const DAY_MS = 24 * 3600 * 1000;
const RETENTION_MS = 365 * DAY_MS;
const ROLLUP_STALE_MS = 2 * 3600 * 1000;
const OFFLINE_AFTER_MS = DAY_MS;
const MAX_PATHS_PER_UPDATE = 500;

// ── Retention ─────────────────────────────────────────────────────────────

/** Oldest keys to keep: hourly keys sort as "YYYY-MM-DD-HH", anomaly keys as "<ms>_<id>". */
function retentionCutoffs(nowMs) {
  const cutoffMs = nowMs - RETENTION_MS;
  return {
    hourlyKey: `${periodKeys(cutoffMs).daily}-00`,
    anomalyKey: `${cutoffMs}`,
  };
}

/** Paths to delete: hourly keys before the cutoff hour, anomalies before the cutoff time. */
function planRetention({ hourlyKeys = [], anomalyKeys = [], nowMs }) {
  const { hourlyKey, anomalyKey } = retentionCutoffs(nowMs);
  return [
    ...hourlyKeys.filter((k) => k < hourlyKey).map((k) => `energy_summaries/hourly/${k}`),
    ...anomalyKeys
      .filter((k) => Number(String(k).split('_')[0]) < Number(anomalyKey))
      .map((k) => `anomalies/${k}`),
  ];
}

async function runRetention(db, nowMs = Date.now()) {
  const { hourlyKey, anomalyKey } = retentionCutoffs(nowMs);
  // Only the keys older than the cutoffs are downloaded.
  const [hourlySnap, anomalySnap] = await Promise.all([
    db.ref('energy_summaries/hourly').orderByKey().endBefore(hourlyKey).get(),
    db.ref('anomalies').orderByKey().endBefore(anomalyKey).get(),
  ]);
  const paths = planRetention({
    hourlyKeys: Object.keys(hourlySnap.val() ?? {}),
    anomalyKeys: Object.keys(anomalySnap.val() ?? {}),
    nowMs,
  });
  for (let i = 0; i < paths.length; i += MAX_PATHS_PER_UPDATE) {
    const chunk = paths.slice(i, i + MAX_PATHS_PER_UPDATE);
    await db.ref().update(Object.fromEntries(chunk.map((p) => [p, null])));
  }
  console.log(`[pruneHistory] deleted ${paths.length} path(s) older than one year`);
  return paths.length;
}

// ── Monitoring ────────────────────────────────────────────────────────────

/**
 * When a board last checked in: the newest of its device_live (firmware
 * 2.0+) and devices timestamps. Both firmware versions backdate last_seen
 * while the meter isn't answering but still stamp last_updated, so a board
 * with a broken meter isn't reported offline.
 */
function lastSeenOf(live, legacy) {
  const times = [
    live?.connectivity?.lastSeenAt, live?.connectivity?.lastUpdatedAt,
    legacy?.last_seen, legacy?.last_updated,
  ].filter((t) => typeof t === 'number' && t > 0);
  return times.length ? Math.max(...times) : null;
}

/**
 * Alerts to raise now. Each has a stable `key`; keys already in [alerted]
 * are skipped, so a problem is reported once, not every hour.
 */
function planHealthAlerts({
  nowMs, heartbeatAt, registry = {}, devices = {}, deviceLive = {},
  meterState = {}, today = null, alerted = {},
}) {
  const alerts = [];
  const day = periodKeys(nowMs).daily;
  const add = (key, subtype, message, deviceId) => {
    if (!alerted[key]) alerts.push({ key, subtype, message, ...(deviceId ? { deviceId } : {}) });
  };

  if (typeof heartbeatAt !== 'number' || nowMs - heartbeatAt > ROLLUP_STALE_MS) {
    add(`rollup_stalled:${day}`, 'rollup_stalled',
      'Energy history is not being recorded: the once-a-minute history job has not run for over 2 hours.');
  }

  for (const [id, entry] of Object.entries(registry ?? {})) {
    if (!isRealDevice(entry)) continue;
    const flag = meterState?.[id]?.flag;
    if (flag?.frozen) {
      add(`frozen:${id}:${flag.at}`, 'device_frozen',
        `${id}: energy counting is paused (meter ${flag.reason === 'spike' ? 'jumped' : 'dropped'} unexpectedly). ` +
        'An admin needs to review it (accept or start over).', id);
    }
    const seen = lastSeenOf(deviceLive?.[id], devices?.[id]);
    if (seen && seen > 0 && nowMs - seen > OFFLINE_AFTER_MS && nowMs - seen < 7 * DAY_MS) {
      add(`offline:${id}:${seen}`, 'device_offline',
        `${id} has not reported for over a day.`, id);
    }
  }

  if (today && typeof today === 'object') {
    const campus = Number(today.campus?.kwh ?? 0);
    const sumOf = (node) => Object.values(node ?? {})
      .reduce((a, v) => a + (typeof v?.kwh === 'number' ? v.kwh : 0), 0);
    const devicesSum = sumOf(today.devices);
    const buildingsSum = sumOf(today.buildings);
    const off = (a, b) => Math.abs(a - b) > Math.max(1e-6, 1e-6 * Math.abs(a));
    if (off(campus, devicesSum) || off(campus, buildingsSum)) {
      add(`mismatch:${day}`, 'summary_mismatch',
        `Today's energy totals don't add up (campus ${campus.toFixed(4)} kWh, ` +
        `devices ${devicesSum.toFixed(4)}, buildings ${buildingsSum.toFixed(4)}).`);
    }
  }
  return alerts;
}

async function runHealthCheck(db, nowMs = Date.now()) {
  const day = periodKeys(nowMs).daily;
  const read = async (p) => (await db.ref(p).get()).val();
  const [heartbeatAt, registry, devices, deviceLive, meterState, today, alerted] = await Promise.all([
    read('rollup/heartbeat'), read('master_devices'), read('devices'), read('device_live'),
    read('meterState'), read(`energy_summaries/daily/${day}`), read('system_health/alerted'),
  ]);
  const alerts = planHealthAlerts({
    nowMs, heartbeatAt, registry, devices, deviceLive, meterState, today, alerted: alerted ?? {},
  });
  const update = { 'system_health/lastCheck': { at: nowMs, alerts: alerts.length } };
  for (const a of alerts) {
    const id = db.ref('notifications').push().key;
    update[`notifications/${id}`] = {
      type: 'system_alert',
      subtype: a.subtype,
      message: a.message,
      ...(a.deviceId ? { deviceId: a.deviceId } : {}),
      timestamp: admin.database.ServerValue.TIMESTAMP,
    };
    update[`system_health/alerted/${a.key.replace(/[.#$[\]/]/g, '_')}`] = nowMs;
  }
  await db.ref().update(update);
  if (alerts.length) console.warn(`[checkEnergyHealth] ${alerts.map((a) => a.key).join(', ')}`);
  return alerts;
}

const pruneHistory = onSchedule({
  schedule: '0 3 1 * *', // 03:00 PH on the 1st of every month
  timeZone: 'Asia/Manila',
  region: 'asia-southeast1',
  timeoutSeconds: 300,
}, async () => {
  await runRetention(admin.database());
});

const checkEnergyHealth = onSchedule({
  schedule: '30 * * * *', // every hour at :30 PH
  timeZone: 'Asia/Manila',
  region: 'asia-southeast1',
  timeoutSeconds: 120,
}, async () => {
  await runHealthCheck(admin.database());
});

module.exports = {
  pruneHistory,
  checkEnergyHealth,
  retentionCutoffs,
  planRetention,
  planHealthAlerts,
  runRetention,
  runHealthCheck,
};
