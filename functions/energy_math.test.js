// Run with: node --test   (from the functions/ folder)
// The key cases are mirrored in test/history_keys_test.dart -- keep them in sync.
const test = require('node:test');
const assert = require('node:assert');
const {
  DEFAULT_MAX_POWER_W, UNASSIGNED, RANGES,
  phDateParts, isoWeekKey, periodKeys, buildingOf, isRealDevice,
  computeDelta, planRollup, toUpdate,
} = require('./energy_math');

const MIN = 60 * 1000;
const HOUR = 60 * MIN;
const T0 = Date.UTC(2026, 9, 10, 2, 0); // 2026-10-10 10:00 PH
const close = (a, b, msg) => assert.ok(Math.abs(a - b) < 1e-9, `${msg ?? ''} expected ${b}, got ${a}`);

// ── Keys (Philippine time, ISO weeks) ─────────────────────────────────────

test('PH date: 23:59 PH stays on the day, 00:00 PH starts the next', () => {
  assert.deepStrictEqual(periodKeys(Date.UTC(2026, 9, 10, 15, 59)).daily, '2026-10-10');
  assert.deepStrictEqual(periodKeys(Date.UTC(2026, 9, 10, 15, 59)).hourly, '2026-10-10-23');
  assert.deepStrictEqual(periodKeys(Date.UTC(2026, 9, 10, 16, 0)).daily, '2026-10-11');
  assert.deepStrictEqual(periodKeys(Date.UTC(2026, 9, 10, 16, 0)).hourly, '2026-10-11-00');
});

test('PH date: 07:59 PH is 23:59 UTC the day before, and belongs to the PH day', () => {
  const k = periodKeys(Date.UTC(2026, 9, 10, 23, 59));
  assert.strictEqual(k.daily, '2026-10-11');
  assert.strictEqual(k.hourly, '2026-10-11-07');
});

test('PH new year: month, year and ISO week roll over together', () => {
  assert.deepStrictEqual(periodKeys(Date.UTC(2026, 11, 31, 16, 0)), {
    hourly: '2027-01-01-00', daily: '2027-01-01', weekly: '2026-W53', monthly: '2027-01', yearly: '2027',
  });
  assert.strictEqual(periodKeys(Date.UTC(2026, 11, 31, 15, 59)).yearly, '2026');
});

test('PH leap day', () => {
  assert.strictEqual(periodKeys(Date.UTC(2028, 1, 28, 16, 0)).daily, '2028-02-29');
  assert.strictEqual(periodKeys(Date.UTC(2028, 1, 29, 16, 0)).daily, '2028-03-01');
});

test('phDateParts', () => {
  assert.deepStrictEqual(phDateParts(Date.UTC(2026, 9, 10, 20, 30)), { year: 2026, month: 10, day: 11, hour: 4 });
});

test('ISO weeks at year boundaries', () => {
  assert.strictEqual(isoWeekKey(2026, 1, 1), '2026-W01'); // Thursday
  assert.strictEqual(isoWeekKey(2026, 12, 31), '2026-W53');
  assert.strictEqual(isoWeekKey(2027, 1, 1), '2026-W53');
  assert.strictEqual(isoWeekKey(2027, 1, 3), '2026-W53'); // Sunday
  assert.strictEqual(isoWeekKey(2027, 1, 4), '2027-W01'); // Monday
  assert.strictEqual(isoWeekKey(2024, 12, 30), '2025-W01');
  assert.strictEqual(isoWeekKey(2021, 1, 3), '2020-W53');
});

test('ISO weeks run Monday to Sunday', () => {
  assert.strictEqual(isoWeekKey(2026, 10, 5), '2026-W41'); // Monday
  assert.strictEqual(isoWeekKey(2026, 10, 11), '2026-W41'); // Sunday
  assert.strictEqual(isoWeekKey(2026, 10, 12), '2026-W42'); // Monday
});

// ── Registry helpers ──────────────────────────────────────────────────────

test('building comes from assignedTo, upper-cased; empty is UNASSIGNED', () => {
  assert.strictEqual(buildingOf('IC/1/Room 101'), 'IC');
  assert.strictEqual(buildingOf('test/1/test'), 'TEST');
  assert.strictEqual(buildingOf(''), UNASSIGNED);
  assert.strictEqual(buildingOf(undefined), UNASSIGNED);
});

test('only registered real boards count', () => {
  assert.ok(isRealDevice({ source: 'real_iot' }));
  assert.ok(!isRealDevice({ assignedTo: 'ADMIN/1/Room 101' })); // mock: no source
  assert.ok(!isRealDevice({ source: 'mock' }));
  assert.ok(!isRealDevice({ source: 'real_iot', status: 'retired' }));
  assert.ok(!isRealDevice(null));
});

// ── computeDelta ──────────────────────────────────────────────────────────

const state = (kwh, at = T0, extra = {}) => ({ lastAcceptedKwh: kwh, lastAcceptedAt: at, meterEpoch: 0, ...extra });

test('first reading sets the baseline and counts nothing', () => {
  const r = computeDelta({ kwh: 12.345, state: null, nowMs: T0 });
  assert.strictEqual(r.delta, 0);
  assert.deepStrictEqual(r.newState, state(12.345));
  assert.strictEqual(r.anomaly, null);
});

test('normal increase counts the difference and moves the baseline', () => {
  const r = computeDelta({ kwh: 12.347, state: state(12.345), nowMs: T0 + MIN });
  close(r.delta, 0.002);
  assert.deepStrictEqual(r.newState, state(12.347, T0 + MIN));
});

test('tiny increases are kept unrounded', () => {
  const r = computeDelta({ kwh: 12.345001, state: state(12.345), nowMs: T0 + MIN });
  close(r.delta, 0.000001);
});

test('same reading counts nothing and writes nothing', () => {
  assert.deepStrictEqual(computeDelta({ kwh: 12.345, state: state(12.345), nowMs: T0 + MIN }),
    { delta: 0, newState: null, anomaly: null });
});

test('missing reading counts nothing and writes nothing', () => {
  for (const kwh of [null, undefined]) {
    assert.deepStrictEqual(computeDelta({ kwh, state: state(5), nowMs: T0 + MIN }),
      { delta: 0, newState: null, anomaly: null });
  }
});

test('invalid readings are logged once and keep the baseline', () => {
  for (const kwh of [NaN, Infinity, -1, '12.4', {}]) {
    const r = computeDelta({ kwh, state: state(5), nowMs: T0 + MIN });
    assert.strictEqual(r.delta, 0);
    assert.strictEqual(r.anomaly, 'invalid');
    assert.strictEqual(r.newState.lastAcceptedKwh, 5);
    assert.strictEqual(r.newState.flag.frozen, false);
    // Seen again: no second anomaly, nothing written.
    const again = computeDelta({ kwh, state: r.newState, nowMs: T0 + 2 * MIN });
    assert.deepStrictEqual(again, { delta: 0, newState: null, anomaly: null });
  }
});

test('a valid reading after an invalid one counts normally and clears the flag', () => {
  const flagged = computeDelta({ kwh: NaN, state: state(5), nowMs: T0 + MIN }).newState;
  const r = computeDelta({ kwh: 5.01, state: flagged, nowMs: T0 + 2 * MIN });
  close(r.delta, 0.01);
  assert.strictEqual(r.newState.flag, undefined);
});

test('a drop (small or to zero) freezes the device and counts nothing', () => {
  for (const kwh of [12.3, 0]) {
    const r = computeDelta({ kwh, state: state(12.347), nowMs: T0 + MIN });
    assert.strictEqual(r.delta, 0);
    assert.strictEqual(r.anomaly, 'decrease');
    assert.strictEqual(r.newState.lastAcceptedKwh, 12.347);
    assert.strictEqual(r.newState.flag.frozen, true);
    // Still low next minute: frozen, no new anomaly, nothing written.
    assert.deepStrictEqual(computeDelta({ kwh, state: r.newState, nowMs: T0 + 2 * MIN }),
      { delta: 0, newState: null, anomaly: null });
  }
});

test('a frozen drop clears itself when the meter comes back to normal', () => {
  const frozen = computeDelta({ kwh: 12.3, state: state(12.347), nowMs: T0 + MIN }).newState;
  const r = computeDelta({ kwh: 12.35, state: frozen, nowMs: T0 + 2 * MIN });
  close(r.delta, 0.003);
  assert.strictEqual(r.newState.flag, undefined);
});

test('a confirmed reset ("accept" on a drop) counts the new reading and bumps meterEpoch', () => {
  const frozen = computeDelta({ kwh: 0, state: state(12.347), nowMs: T0 + MIN }).newState;
  const r = computeDelta({ kwh: 0.05, state: { ...frozen, resolve: 'accept' }, nowMs: T0 + 2 * MIN });
  close(r.delta, 0.05);
  assert.deepStrictEqual(r.newState, { lastAcceptedKwh: 0.05, lastAcceptedAt: T0 + 2 * MIN, meterEpoch: 1 });
});

test('"rebaseline" starts over from the current reading without counting', () => {
  const frozen = computeDelta({ kwh: 3, state: state(12.347), nowMs: T0 + MIN }).newState;
  const r = computeDelta({ kwh: 3.2, state: { ...frozen, resolve: 'rebaseline' }, nowMs: T0 + 2 * MIN });
  assert.strictEqual(r.delta, 0);
  assert.deepStrictEqual(r.newState, { lastAcceptedKwh: 3.2, lastAcceptedAt: T0 + 2 * MIN, meterEpoch: 1 });
});

test('a rise faster than 25 kW allows is a spike: frozen, and never auto-accepted', () => {
  const r = computeDelta({ kwh: 20, state: state(10), nowMs: T0 + MIN });
  assert.strictEqual(r.delta, 0);
  assert.strictEqual(r.anomaly, 'spike');
  assert.strictEqual(r.newState.flag.frozen, true);
  // Five hours later the 25 kW cap (125 kWh) would allow +10 kWh, but a
  // frozen spike stays frozen until an admin decides.
  assert.deepStrictEqual(computeDelta({ kwh: 20, state: r.newState, nowMs: T0 + 5 * HOUR }),
    { delta: 0, newState: null, anomaly: null });
  const accepted = computeDelta({ kwh: 20, state: { ...r.newState, resolve: 'accept' }, nowMs: T0 + 5 * HOUR });
  close(accepted.delta, 10);
});

test('the cap is measured from the last accepted change (offline catch-up is allowed)', () => {
  // Board offline 3 h with a load on: the meter kept counting.
  const r = computeDelta({ kwh: 13, state: state(10), nowMs: T0 + 3 * HOUR });
  close(r.delta, 3);
  assert.strictEqual(r.anomaly, null);
});

test('an unchanged reading keeps lastAcceptedAt, so a later catch-up still fits the cap', () => {
  // Many minutes of the same value (writes nothing, so lastAcceptedAt stays at T0) ...
  assert.strictEqual(computeDelta({ kwh: 10, state: state(10), nowMs: T0 + HOUR }).newState, null);
  // ... then +20 kWh after 1 h: allowed (cap 25 kWh), not a spike.
  close(computeDelta({ kwh: 30, state: state(10), nowMs: T0 + HOUR }).delta, 20);
});

test('a per-device maxPowerW tightens the cap', () => {
  const r = computeDelta({ kwh: 10.5, state: state(10), nowMs: T0 + MIN, maxPowerW: 1000 });
  assert.strictEqual(r.anomaly, 'spike');
  assert.strictEqual(DEFAULT_MAX_POWER_W, 25000);
});

// ── planRollup ────────────────────────────────────────────────────────────

const RATE = 13.24;
const NOW = T0 + MIN;
const registry = {
  'ESP32-A': { source: 'real_iot', assignedTo: 'IC/1/Room 101' },
  'ESP32-B': { source: 'real_iot', assignedTo: 'IC/2/Room 201' },
  'ESP32-C': { source: 'real_iot', assignedTo: '' },
  'ESP32-D': { source: 'real_iot', assignedTo: 'TEST/1/test' },
  'DVC-IC-001': { assignedTo: 'IC/1/Room 101' }, // mock: no source
};
const meterState = {
  'ESP32-A': state(1.0), 'ESP32-B': state(2.0), 'ESP32-C': state(3.0), 'ESP32-D': state(4.0),
  'DVC-IC-001': state(0),
};
const kwhById = { 'ESP32-A': 1.002, 'ESP32-B': 2.003, 'ESP32-C': 3.004, 'ESP32-D': 4.0, 'DVC-IC-001': 9 };
const plan = () => planRollup({ registry, kwhById, meterState, rate: RATE, nowMs: NOW });

test('unusable rate: plan writes nothing, so baselines stay and the next run catches up', () => {
  for (const rate of [null, undefined, 0, -1, 150, NaN, '13.24']) {
    const p = planRollup({ registry, kwhById, meterState, rate, nowMs: NOW });
    assert.strictEqual(p.ok, false);
    assert.strictEqual(p.reason, 'invalid-rate');
    assert.deepStrictEqual(p.increments, {});
    assert.deepStrictEqual(p.sets, {});
  }
});

test('campus = sum of buildings = sum of devices, in every range, each path once', () => {
  const p = plan();
  assert.strictEqual(p.ok, true);
  assert.strictEqual(p.devicesCounted, 3);
  for (const range of RANGES) {
    const base = `energy_summaries/${range}/${p.keys[range]}`;
    const inc = (path) => p.increments[`${base}/${path}`] ?? 0;
    close(inc('campus/kwh'), 0.009, `${range} campus kwh`);
    close(inc('buildings/IC/kwh'), 0.005, `${range} IC`);
    close(inc(`buildings/${UNASSIGNED}/kwh`), 0.004, `${range} unassigned`);
    close(inc('devices/ESP32-A/kwh'), 0.002);
    close(inc('devices/ESP32-B/kwh'), 0.003);
    close(inc('devices/ESP32-C/kwh'), 0.004);
    close(inc('campus/cost'), 0.009 * RATE, `${range} campus cost`);
    close(inc('buildings/IC/cost') + inc(`buildings/${UNASSIGNED}/cost`), inc('campus/cost'));
    assert.strictEqual(p.sets[`${base}/devices/ESP32-A/building`], 'IC');
    assert.strictEqual(p.sets[`${base}/devices/ESP32-C/building`], UNASSIGNED);
  }
});

test('mock devices are never counted, even with a rising meter', () => {
  const all = JSON.stringify(plan());
  assert.ok(!all.includes('DVC-'), 'a DVC- path or value leaked into the plan');
});

test('a device with no new energy adds no paths', () => {
  const p = plan();
  assert.ok(!Object.keys(p.increments).some((k) => k.includes('ESP32-D')));
  assert.ok(!Object.keys(p.sets).some((k) => k.includes('ESP32-D')));
  assert.ok(!Object.keys(p.increments).some((k) => k.includes('/buildings/TEST/')));
});

test('baselines move in the same plan as the totals', () => {
  const p = plan();
  assert.strictEqual(p.sets['meterState/ESP32-A'].lastAcceptedKwh, 1.002);
  assert.strictEqual(p.sets['meterState/ESP32-A'].lastAcceptedAt, NOW);
});

test('no path appears twice or inside another path (valid multi-path update)', () => {
  const p = plan();
  const paths = [...Object.keys(p.increments), ...Object.keys(p.sets)];
  assert.strictEqual(new Set(paths).size, paths.length, 'duplicate path');
  const sorted = [...paths].sort();
  for (let i = 1; i < sorted.length; i++) {
    assert.ok(!sorted[i].startsWith(`${sorted[i - 1]}/`), `${sorted[i - 1]} contains ${sorted[i]}`);
  }
});

test('nothing new anywhere: the plan writes nothing', () => {
  const p = planRollup({
    registry, meterState, rate: RATE, nowMs: NOW,
    kwhById: { 'ESP32-A': 1.0, 'ESP32-B': 2.0, 'ESP32-C': 3.0, 'ESP32-D': 4.0 },
  });
  assert.deepStrictEqual(p.increments, {});
  assert.deepStrictEqual(p.sets, {});
});

test('anomalies are recorded with the device, reason and both readings', () => {
  const p = planRollup({
    registry: { 'ESP32-A': registry['ESP32-A'] }, meterState, rate: RATE, nowMs: NOW,
    kwhById: { 'ESP32-A': 0.5 },
  });
  assert.strictEqual(p.anomalies, 1);
  assert.deepStrictEqual(p.sets[`anomalies/${NOW}_ESP32-A`], {
    deviceId: 'ESP32-A', reason: 'decrease', previousKwh: 1.0, observedKwh: 0.5, detectedAt: NOW,
  });
  assert.deepStrictEqual(p.increments, {});
});

test('a new device gets a baseline and contributes nothing on its first run', () => {
  const p = planRollup({
    registry: { 'ESP32-NEW': { source: 'real_iot', assignedTo: 'ITED/1/Lab' } },
    meterState: {}, rate: RATE, nowMs: NOW, kwhById: { 'ESP32-NEW': 57.3 },
  });
  assert.deepStrictEqual(p.increments, {});
  assert.deepStrictEqual(p.sets, { 'meterState/ESP32-NEW': { lastAcceptedKwh: 57.3, lastAcceptedAt: NOW, meterEpoch: 0 } });
});

test('toUpdate wraps increments and keeps sets', () => {
  const p = plan();
  const u = toUpdate(p, (n) => ({ inc: n }));
  const someInc = Object.keys(p.increments)[0];
  assert.deepStrictEqual(u[someInc], { inc: p.increments[someInc] });
  assert.deepStrictEqual(u['meterState/ESP32-A'], p.sets['meterState/ESP32-A']);
  assert.strictEqual(Object.keys(u).length, Object.keys(p.increments).length + Object.keys(p.sets).length);
});
