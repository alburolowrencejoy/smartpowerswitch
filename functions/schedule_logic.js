// Automation schedules: when should a schedule switch its devices ON or OFF?
// Pure functions, no Firebase. A port of the app's scheduler
// (lib/services/automation_scheduler_service.dart `_AutomationRecord` and
// lib/services/schedule_windows.dart), which is the reference: the server
// must run every schedule the app can create, so the app-side scheduler can
// be retired. Run the tests with: node --test   (from the functions/ folder)
'use strict';

const DAY_MINUTES = 24 * 60;
const DAY_MS = 24 * 3600 * 1000;
const DAY_LABELS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

function parseBoolean(value) {
  if (typeof value === 'boolean') return value;
  return String(value).toLowerCase().trim() === 'true';
}

function normalizeText(value) {
  return String(value ?? '').trim();
}

/** "HH:mm" -> minutes after midnight, or null. */
function parseHm(value) {
  const parts = String(value ?? '').trim().split(':');
  if (parts.length !== 2) return null;
  const h = Number(parts[0]);
  const m = Number(parts[1]);
  if (!Number.isInteger(h) || !Number.isInteger(m)) return null;
  if (h < 0 || h > 23 || m < 0 || m > 59) return null;
  return h * 60 + m;
}

/** "YYYY-MM-DD" -> UTC midnight of that calendar day (ms), or null. */
function parseIsoDay(value) {
  const m = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(String(value ?? '').trim());
  if (!m) return null;
  const ms = Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  return Number.isNaN(ms) ? null : ms;
}

/**
 * A time window: ON at [on], stays ON through [until], OFF one minute after
 * [until]. An [until] earlier than [on] runs overnight into the next day.
 */
function makeWindow(on, until) {
  const overnight = until < on;
  return {
    on,
    until,
    overnight,
    offMinute: (until + 1) % DAY_MINUTES,
    // Days after the start day that the OFF happens.
    offDayOffset: (until + 1 >= DAY_MINUTES || overnight) ? 1 : 0,
  };
}

/** `windows` from a schedule: a list, or an index-keyed map; bad entries skipped. */
function parseWindows(raw) {
  let items = [];
  if (Array.isArray(raw)) {
    items = raw;
  } else if (raw && typeof raw === 'object') {
    items = Object.keys(raw).sort().map((k) => raw[k]);
  }
  const out = [];
  for (const item of items) {
    if (!item || typeof item !== 'object') continue;
    const on = parseHm(item.on);
    const until = parseHm(item.until);
    if (on !== null && until !== null) out.push(makeWindow(on, until));
  }
  return out;
}

/** Normalizes an `automations/{id}` record the same way the app does. */
function parseSchedule(id, data) {
  const rawDays = data.days;
  let days = [];
  if (Array.isArray(rawDays)) {
    days = rawDays.map((d) => String(d));
  } else if (rawDays && typeof rawDays === 'object') {
    days = Object.values(rawDays).map((d) => String(d));
  }

  const legacyAction = String(data.action ?? '').toLowerCase();
  const legacyTime = String(data.time ?? '');
  let onTime = String(data.onTime ?? '');
  let offTime = String(data.offTime ?? '');
  if (!onTime && legacyAction === 'on' && legacyTime) onTime = legacyTime;
  if (!offTime && legacyAction === 'off' && legacyTime) offTime = legacyTime;
  if (!onTime) onTime = '08:00';
  if (!offTime) offTime = '18:00';

  return {
    id,
    scope: String(data.scope ?? 'global'),
    target: String(data.target ?? 'all'),
    utility: String(data.utility ?? 'All'),
    onTime,
    offTime,
    days,
    enabled: parseBoolean(data.enabled ?? true),
    scheduleMode: String(data.scheduleMode ?? '') === 'calendar' ? 'calendar' : 'weekly',
    startDay: parseIsoDay(data.startDate),
    endDay: parseIsoDay(data.endDate),
    windows: parseWindows(data.windows),
  };
}

/**
 * The schedule's wall clock in [timeZone]:
 * { day (UTC-midnight ms of the local calendar date), minute (of the day) }.
 * Falls back to Asia/Manila if the time zone is invalid.
 */
function clockAt(ms, timeZone = 'Asia/Manila') {
  let parts;
  try {
    parts = new Intl.DateTimeFormat('en-US', {
      timeZone, year: 'numeric', month: 'numeric', day: 'numeric',
      hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
    }).formatToParts(new Date(ms));
  } catch (_) {
    return clockAt(ms, 'Asia/Manila');
  }
  const v = Object.fromEntries(parts.map((p) => [p.type, p.value]));
  return {
    day: Date.UTC(Number(v.year), Number(v.month) - 1, Number(v.day)),
    minute: Number(v.hour) * 60 + Number(v.minute),
  };
}

const dayLabel = (dayMs) => DAY_LABELS[new Date(dayMs).getUTCDay()];

/** Whether the schedule is active on calendar day [dayMs] (UTC midnight). */
function runsOn(schedule, dayMs) {
  if (schedule.scheduleMode === 'calendar') {
    if (schedule.startDay === null || schedule.endDay === null) return false;
    return dayMs >= schedule.startDay && dayMs <= schedule.endDay;
  }
  return schedule.days.includes(dayLabel(dayMs));
}

/**
 * 'on', 'off' or null for [schedule] at [clock] ({day, minute}).
 * Windows: ON at a window's start on an active day; OFF one minute after its
 * end, on the day the window started (so an overnight window's OFF fires the
 * next morning). ON wins when an OFF and an ON meet (back-to-back windows).
 * Without windows: the single onTime/offTime pair, overnight when on > off.
 */
function actionFor(schedule, clock) {
  const { day, minute } = clock;

  if (schedule.windows.length > 0) {
    let action = null;
    for (const w of schedule.windows) {
      if (w.on === minute && runsOn(schedule, day)) return 'on';
      if (w.offMinute === minute && runsOn(schedule, day - w.offDayOffset * DAY_MS)) {
        action = 'off';
      }
    }
    return action;
  }

  const onMinutes = parseHm(schedule.onTime);
  const offMinutes = parseHm(schedule.offTime);
  if (onMinutes === null || offMinutes === null) return null;

  if (minute === onMinutes && runsOn(schedule, day)) return 'on';
  if (minute !== offMinutes) return null;
  const overnight = onMinutes > offMinutes;
  return runsOn(schedule, overnight ? day - DAY_MS : day) ? 'off' : null;
}

function canonicalUtility(value) {
  const normalized = String(value ?? '').toLowerCase().replace(/[^a-z0-9]+/g, '');
  switch (normalized) {
    case 'light':
    case 'lights':
      return 'lights';
    case 'outlet':
    case 'outlets':
      return 'outlets';
    case 'ac':
    case 'aircon':
    case 'airconditioner':
    case 'airconditioners':
    case 'airconditioning':
      return 'ac';
    case 'all':
    case '':
      return 'all';
    default:
      return normalized;
  }
}

function utilityMatches(expected, actual) {
  const e = canonicalUtility(expected);
  return e === 'all' || e === canonicalUtility(actual);
}

/** Whether [schedule] targets the device [deviceId] with live record [device]. */
function targetsDevice(schedule, deviceId, device) {
  switch (schedule.scope) {
    case 'global':
      return utilityMatches(schedule.utility, device.utility);
    case 'building':
      return normalizeText(schedule.target).toUpperCase() ===
          normalizeText(device.building).toUpperCase() &&
        utilityMatches(schedule.utility, device.utility);
    case 'utility':
      return utilityMatches(schedule.target, device.utility);
    case 'device':
      return normalizeText(deviceId) === normalizeText(schedule.target);
    default:
      return false;
  }
}

/**
 * Relay changes for one scheduler run: [{ deviceId, relay, building, floor }]
 * for every device a due schedule targets whose relay isn't already there.
 * Later schedules win when two are due for the same device at once.
 */
function planRelayChanges({ automations, devices, nowMs, timeZone }) {
  const clock = clockAt(nowMs, timeZone);
  const desired = new Map();
  for (const [id, data] of Object.entries(automations ?? {})) {
    if (!data || typeof data !== 'object') continue;
    const schedule = parseSchedule(id, data);
    if (!schedule.enabled) continue;
    const action = actionFor(schedule, clock);
    if (!action) continue;
    for (const [deviceId, device] of Object.entries(devices ?? {})) {
      if (!device || typeof device !== 'object') continue;
      if (targetsDevice(schedule, deviceId, device)) desired.set(deviceId, action === 'on');
    }
  }
  const changes = [];
  for (const [deviceId, relay] of desired) {
    const device = devices[deviceId];
    if (parseBoolean(device.relay) === relay) continue;
    changes.push({
      deviceId,
      relay,
      building: normalizeText(device.building),
      floor: normalizeText(device.floor),
    });
  }
  return changes;
}

module.exports = {
  parseHm,
  parseWindows,
  parseSchedule,
  clockAt,
  runsOn,
  actionFor,
  targetsDevice,
  canonicalUtility,
  planRelayChanges,
};
