// Energy accounting for the once-a-minute rollup: pure functions, no Firebase.
// The scheduled job reads the registry, the meters, meterState and the rate,
// calls planRollup(), and writes the result in one multi-path update.
// Run the tests with: node --test   (from the functions/ folder)
'use strict';

const DAY_MS = 24 * 3600 * 1000;
const HOUR_MS = 3600 * 1000;

// Asia/Manila is UTC+8 all year (no daylight saving).
const PH_OFFSET_MS = 8 * HOUR_MS;

// PZEM-004T 100 A variant. 25 kW is also the firmware's upper limit for a
// valid power reading. A device can override it with master_devices/{id}/maxPowerW.
const DEFAULT_MAX_POWER_W = 25000;

// Rounding slack added to the plausibility cap, in kWh.
const CAP_SLACK_KWH = 0.01;

const UNASSIGNED = 'UNASSIGNED';
const RANGES = ['hourly', 'daily', 'weekly', 'monthly', 'yearly'];
const SUMMARY_ROOT = 'energy_summaries';

function pad(n) {
  return String(n).padStart(2, '0');
}

/** Calendar fields of [ms] (epoch milliseconds) as seen in the Philippines. */
function phDateParts(ms) {
  const d = new Date(ms + PH_OFFSET_MS);
  return {
    year: d.getUTCFullYear(),
    month: d.getUTCMonth() + 1,
    day: d.getUTCDate(),
    hour: d.getUTCHours(),
  };
}

/** ISO 8601 week key (Monday start, ISO week-year), e.g. "2026-W53". */
function isoWeekKey(year, month, day) {
  const date = Date.UTC(year, month - 1, day);
  const weekday = (new Date(date).getUTCDay() + 6) % 7; // Monday = 0
  // The ISO week belongs to the year that contains its Thursday.
  const thursday = new Date(date + (3 - weekday) * DAY_MS);
  const isoYear = thursday.getUTCFullYear();
  const ordinal = Math.floor((thursday - Date.UTC(isoYear, 0, 1)) / DAY_MS) + 1;
  return `${isoYear}-W${pad(Math.floor((ordinal - 1) / 7) + 1)}`;
}

/** Every history key that the instant [ms] falls into, in Philippine time. */
function periodKeys(ms) {
  const p = phDateParts(ms);
  const daily = `${p.year}-${pad(p.month)}-${pad(p.day)}`;
  return {
    hourly: `${daily}-${pad(p.hour)}`,
    daily,
    weekly: isoWeekKey(p.year, p.month, p.day),
    monthly: `${p.year}-${pad(p.month)}`,
    yearly: `${p.year}`,
  };
}

/** Building code from a registry assignment like "IC/1/Room 101". */
function buildingOf(assignedTo) {
  const code = String(assignedTo ?? '').split('/')[0].trim().toUpperCase();
  return code || UNASSIGNED;
}

/** Only registered real boards are accounted; mocks have no `real_iot` source. */
function isRealDevice(entry) {
  return !!entry && entry.source === 'real_iot' && entry.status !== 'retired';
}

function maxPowerWOf(entry) {
  const w = Number(entry?.maxPowerW);
  return Number.isFinite(w) && w > 0 ? w : DEFAULT_MAX_POWER_W;
}

function isValidRate(rate) {
  return typeof rate === 'number' && Number.isFinite(rate) && rate > 0 && rate < 100;
}

function hasBaseline(state) {
  return typeof state?.lastAcceptedKwh === 'number';
}

function baseline(kwh, nowMs, meterEpoch) {
  return { lastAcceptedKwh: kwh, lastAcceptedAt: nowMs, meterEpoch };
}

/**
 * Energy a device used since its last accepted meter reading.
 *
 * [kwh] is the board's cumulative meter value. [state] is
 * meterState/{id}: { lastAcceptedKwh, lastAcceptedAt, meterEpoch,
 * flag?: { reason, observedKwh, at, frozen }, resolve?: 'accept'|'rebaseline' }.
 *
 * Returns { delta, newState, anomaly }:
 * - delta: kWh to add to history (0 when nothing is counted);
 * - newState: the meterState to write, or null to leave it as it is
 *   (nothing is written when there's no new data);
 * - anomaly: a reason string the first time a problem is seen, else null.
 *
 * Rules (Phase 0 audit, gates G1/G2):
 * - first reading only sets the baseline; the lifetime total is never counted;
 * - a missing reading counts nothing and changes nothing;
 * - an invalid reading (not a finite number, or negative) is logged once and
 *   the baseline is kept;
 * - a drop, or a rise faster than maxPowerW allows since the last accepted
 *   change, is logged once and the device is frozen (nothing counted) until
 *   an admin sets `resolve`: 'accept' counts it ('accept' on a drop means a
 *   confirmed meter reset, so the new reading itself is counted), 'rebaseline'
 *   starts over from the current reading. A frozen drop clears itself if the
 *   meter comes back to a normal reading; a frozen spike never does, because
 *   the cap grows with time and would eventually let it through.
 */
function computeDelta({ kwh, state, nowMs, maxPowerW = DEFAULT_MAX_POWER_W }) {
  const none = { delta: 0, newState: null, anomaly: null };
  const epoch = Number.isInteger(state?.meterEpoch) ? state.meterEpoch : 0;
  const flag = state?.flag ?? null;

  if (kwh === null || kwh === undefined) return none;

  if (typeof kwh !== 'number' || !Number.isFinite(kwh) || kwh < 0) {
    if (flag?.reason === 'invalid' || flag?.frozen) return none;
    const observedKwh = typeof kwh === 'number' && Number.isFinite(kwh) ? kwh : null;
    return {
      delta: 0,
      newState: { ...cleanState(state), flag: { reason: 'invalid', observedKwh, at: nowMs, frozen: false } },
      anomaly: 'invalid',
    };
  }

  if (!hasBaseline(state)) {
    return { delta: 0, newState: baseline(kwh, nowMs, epoch), anomaly: null };
  }

  const last = state.lastAcceptedKwh;

  if (state.resolve === 'rebaseline') {
    return { delta: 0, newState: baseline(kwh, nowMs, epoch + 1), anomaly: null };
  }
  if (state.resolve === 'accept') {
    const reset = kwh < last;
    return {
      delta: reset ? kwh : kwh - last,
      newState: baseline(kwh, nowMs, reset ? epoch + 1 : epoch),
      anomaly: null,
    };
  }

  if (flag?.frozen && flag.reason === 'spike') return none;

  const freeze = (reason) => ({
    delta: 0,
    newState: flag?.frozen && flag.reason === reason
      ? null
      : { ...cleanState(state), flag: { reason, observedKwh: kwh, at: nowMs, frozen: true } },
    anomaly: flag?.frozen && flag.reason === reason ? null : reason,
  });

  const diff = kwh - last;
  if (diff < 0) return freeze('decrease');

  const elapsedHours = Math.max(0, nowMs - (state.lastAcceptedAt ?? nowMs)) / HOUR_MS;
  const capKwh = (maxPowerW / 1000) * elapsedHours + CAP_SLACK_KWH;
  if (diff > capKwh) return freeze('spike');

  if (diff === 0) {
    // Same reading: nothing to count. Keep lastAcceptedAt so the cap keeps
    // measuring from the last real change (a board that was offline for
    // hours may legitimately catch up in one reading).
    return flag ? { delta: 0, newState: cleanState(state), anomaly: null } : none;
  }

  return { delta: diff, newState: baseline(kwh, nowMs, epoch), anomaly: null };
}

/** meterState without the flag/resolve fields. */
function cleanState(state) {
  if (!hasBaseline(state)) return {};
  return baseline(state.lastAcceptedKwh, state.lastAcceptedAt, Number.isInteger(state.meterEpoch) ? state.meterEpoch : 0);
}

/**
 * Plans one rollup run. Inputs are plain snapshots:
 * - registry: master_devices ({ id: { source, assignedTo, maxPowerW, ... } })
 * - kwhById: { id: devices/{id}/kwh } for the registered devices
 * - meterState: meterState ({ id: state })
 * - rate: settings/electricityRate (₱ per kWh)
 * - nowMs: the run's time (epoch ms)
 *
 * Returns { ok, reason?, keys, increments, sets, devicesCounted, anomalies }.
 * `increments` maps each path to the amount to add, already summed per path:
 * a multi-path update can hold a path only once, so per-device increments to
 * the same building/campus total must be added together first.
 * Writes nothing when the rate is unusable: the next run counts the same
 * energy, because baselines don't move.
 */
function planRollup({ registry, kwhById, meterState, rate, nowMs }) {
  const keys = periodKeys(nowMs);
  const empty = { keys, increments: {}, sets: {}, devicesCounted: 0, anomalies: 0 };
  if (!isValidRate(rate)) return { ok: false, reason: 'invalid-rate', ...empty };

  const increments = {};
  const sets = {};
  const add = (path, amount) => {
    increments[path] = (increments[path] ?? 0) + amount;
  };
  let devicesCounted = 0;
  let anomalies = 0;

  for (const id of Object.keys(registry ?? {}).sort()) {
    const entry = registry[id];
    if (!isRealDevice(entry)) continue;

    const state = meterState?.[id] ?? null;
    const res = computeDelta({ kwh: kwhById?.[id], state, nowMs, maxPowerW: maxPowerWOf(entry) });

    if (res.anomaly) {
      anomalies++;
      sets[`anomalies/${nowMs}_${id}`] = {
        deviceId: id,
        reason: res.anomaly,
        previousKwh: hasBaseline(state) ? state.lastAcceptedKwh : null,
        observedKwh: typeof kwhById?.[id] === 'number' && Number.isFinite(kwhById[id]) ? kwhById[id] : null,
        detectedAt: nowMs,
      };
    }
    if (res.newState) sets[`meterState/${id}`] = res.newState;
    if (!(res.delta > 0)) continue;

    devicesCounted++;
    const building = buildingOf(entry.assignedTo);
    const cost = res.delta * rate;
    for (const range of RANGES) {
      const base = `${SUMMARY_ROOT}/${range}/${keys[range]}`;
      add(`${base}/campus/kwh`, res.delta);
      add(`${base}/campus/cost`, cost);
      add(`${base}/buildings/${building}/kwh`, res.delta);
      add(`${base}/buildings/${building}/cost`, cost);
      add(`${base}/devices/${id}/kwh`, res.delta);
      add(`${base}/devices/${id}/cost`, cost);
      sets[`${base}/devices/${id}/building`] = building;
    }
  }

  return { ok: true, keys, increments, sets, devicesCounted, anomalies };
}

/** Turns a plan into an RTDB update object; [increment] is ServerValue.increment. */
function toUpdate(plan, increment) {
  const update = { ...plan.sets };
  for (const [path, amount] of Object.entries(plan.increments)) {
    update[path] = increment(amount);
  }
  return update;
}

module.exports = {
  DEFAULT_MAX_POWER_W,
  UNASSIGNED,
  RANGES,
  SUMMARY_ROOT,
  phDateParts,
  isoWeekKey,
  periodKeys,
  buildingOf,
  isRealDevice,
  isValidRate,
  computeDelta,
  planRollup,
  toUpdate,
};
