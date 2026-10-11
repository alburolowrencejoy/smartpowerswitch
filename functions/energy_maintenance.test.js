// Run with: node --test   (from the functions/ folder)
const test = require('node:test');
const assert = require('node:assert');
const { retentionCutoffs, planRetention, planHealthAlerts } = require('./energy_maintenance');

const HOUR = 3600 * 1000;
const DAY = 24 * HOUR;
const NOW = Date.UTC(2027, 9, 11, 2, 30); // 2027-10-11 10:30 PH

test('retention cutoff is one year back, in PH dates', () => {
  const c = retentionCutoffs(NOW);
  assert.strictEqual(c.hourlyKey, '2026-10-11-00');
  assert.strictEqual(c.anomalyKey, String(NOW - 365 * DAY));
});

test('hourly older than a year is deleted; the last year is kept', () => {
  const paths = planRetention({
    nowMs: NOW,
    hourlyKeys: ['2026-10-10-23', '2026-10-11-00', '2027-10-11-09'],
  });
  assert.deepStrictEqual(paths, ['energy_summaries/hourly/2026-10-10-23']);
});

test('anomalies older than a year are deleted', () => {
  const old = `${NOW - 366 * DAY}_ESP32-A`;
  const recent = `${NOW - 10 * DAY}_ESP32-A`;
  assert.deepStrictEqual(planRetention({ nowMs: NOW, anomalyKeys: [old, recent] }), [`anomalies/${old}`]);
});

test('nothing old: nothing deleted', () => {
  assert.deepStrictEqual(planRetention({ nowMs: NOW }), []);
});

const registry = {
  'ESP32-A': { source: 'real_iot', assignedTo: 'IC/1/R1' },
  'ESP32-B': { source: 'real_iot', assignedTo: '' },
  'DVC-1': { assignedTo: 'IC/1/R1' }, // mock: ignored
};
const healthy = {
  nowMs: NOW,
  heartbeatAt: NOW - 30 * 60 * 1000,
  registry,
  devices: { 'ESP32-A': { last_seen: NOW - 60 * 1000 } },
  deviceLive: { 'ESP32-B': { connectivity: { lastSeenAt: NOW - 120 * 1000 } } },
  today: {
    campus: { kwh: 0.3 },
    buildings: { IC: { kwh: 0.2 }, UNASSIGNED: { kwh: 0.1 } },
    devices: { 'ESP32-A': { kwh: 0.2 }, 'ESP32-B': { kwh: 0.1 } },
  },
};

test('a healthy system raises nothing', () => {
  assert.deepStrictEqual(planHealthAlerts(healthy), []);
});

test('rollup stalled (no heartbeat for 2 h, or none at all)', () => {
  const a = planHealthAlerts({ ...healthy, heartbeatAt: NOW - 3 * HOUR });
  assert.deepStrictEqual(a.map((x) => x.subtype), ['rollup_stalled']);
  assert.strictEqual(planHealthAlerts({ ...healthy, heartbeatAt: null })[0].subtype, 'rollup_stalled');
});

test('frozen device, once per freeze', () => {
  const meterState = { 'ESP32-A': { flag: { reason: 'spike', at: 123, frozen: true } } };
  const a = planHealthAlerts({ ...healthy, meterState });
  assert.deepStrictEqual(a.map((x) => [x.subtype, x.deviceId, x.key]), [['device_frozen', 'ESP32-A', 'frozen:ESP32-A:123']]);
  assert.deepStrictEqual(planHealthAlerts({ ...healthy, meterState, alerted: { 'frozen:ESP32-A:123': 1 } }), []);
});

test('offline over a day (old firmware and v2), not for never-seen boards', () => {
  const a = planHealthAlerts({
    ...healthy,
    devices: { 'ESP32-A': { last_seen: NOW - 2 * DAY } },
    deviceLive: { 'ESP32-B': { connectivity: { lastSeenAt: NOW - 3 * DAY } } },
  });
  assert.deepStrictEqual(a.map((x) => x.deviceId).sort(), ['ESP32-A', 'ESP32-B']);
  assert.deepStrictEqual(planHealthAlerts({ ...healthy, devices: {}, deviceLive: {} }), []);
});

test('totals that do not add up', () => {
  const today = { ...healthy.today, campus: { kwh: 0.5 } };
  const a = planHealthAlerts({ ...healthy, today });
  assert.deepStrictEqual(a.map((x) => x.subtype), ['summary_mismatch']);
});
