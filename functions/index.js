const functions = require('firebase-functions');
const admin = require('firebase-admin');
const { onSchedule } = require('firebase-functions/v2/scheduler');

admin.initializeApp();

function parseBoolean(value) {
  if (typeof value === 'boolean') return value;
  return String(value).toLowerCase().trim() === 'true';
}

function normalizeText(value) {
  return String(value ?? '').trim();
}

function canonicalUtility(value) {
  const normalized = String(value ?? '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '');

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

function dayLabelFromWeekday(weekday) {
  switch (weekday) {
    case 1: return 'Mon';
    case 2: return 'Tue';
    case 3: return 'Wed';
    case 4: return 'Thu';
    case 5: return 'Fri';
    case 6: return 'Sat';
    case 7: return 'Sun';
    default: return 'Mon';
  }
}

function previousDayLabel(day) {
  switch (day) {
    case 'Mon': return 'Sun';
    case 'Tue': return 'Mon';
    case 'Wed': return 'Tue';
    case 'Thu': return 'Wed';
    case 'Fri': return 'Thu';
    case 'Sat': return 'Fri';
    case 'Sun': return 'Sat';
    default: return 'Sun';
  }
}

function getClockParts(timeZone) {
  try {
    const formatter = new Intl.DateTimeFormat('en-US', {
      timeZone,
      weekday: 'short',
      hour: '2-digit',
      minute: '2-digit',
      hour12: false,
    });

    const parts = formatter.formatToParts(new Date());
    const values = {};
    for (const part of parts) {
      values[part.type] = part.value;
    }

    return {
      day: values.weekday,
      hour: Number(values.hour),
      minute: Number(values.minute),
    };
  } catch (error) {
    console.log(`[AutomationScheduler] invalid timezone "${timeZone}", falling back to UTC: ${error.message}`);
    const fallback = new Intl.DateTimeFormat('en-US', {
      timeZone: 'UTC',
      weekday: 'short',
      hour: '2-digit',
      minute: '2-digit',
      hour12: false,
    });

    const parts = fallback.formatToParts(new Date());
    const values = {};
    for (const part of parts) {
      values[part.type] = part.value;
    }

    return {
      day: values.weekday,
      hour: Number(values.hour),
      minute: Number(values.minute),
    };
  }
}

function parseMinutes(value) {
  const parts = String(value ?? '').split(':');
  if (parts.length !== 2) return null;

  const hour = Number(parts[0]);
  const minute = Number(parts[1]);
  if (!Number.isInteger(hour) || !Number.isInteger(minute)) return null;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;

  return hour * 60 + minute;
}

function parseAutomationSchedule(id, data) {
  const rawDays = data.days;
  let days = [];
  if (Array.isArray(rawDays)) {
    days = rawDays.map((day) => String(day));
  } else if (rawDays && typeof rawDays === 'object') {
    days = Object.values(rawDays).map((day) => String(day));
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
  };
}

function isBuildingMatch(expected, actual) {
  return normalizeText(expected).toUpperCase() === normalizeText(actual).toUpperCase();
}

function isUtilityMatch(expected, actual) {
  const normalizedExpected = canonicalUtility(expected);
  if (normalizedExpected === 'all') return true;
  return normalizedExpected === canonicalUtility(actual);
}

function matchesScheduleWindow(schedule, day, currentMinutes) {
  const onMinutes = parseMinutes(schedule.onTime);
  const offMinutes = parseMinutes(schedule.offTime);
  if (onMinutes == null || offMinutes == null) return null;

  const activeDay = schedule.days.includes(day);
  const previousDay = schedule.days.includes(previousDayLabel(day));

  if (activeDay && currentMinutes === onMinutes) {
    return 'on';
  }

  if (currentMinutes !== offMinutes) {
    return null;
  }

  if (onMinutes > offMinutes) {
    return previousDay ? 'off' : null;
  }

  return activeDay ? 'off' : null;
}

async function mirrorRelay(deviceId, building, floor, relay) {
  if (!building || !floor) return;

  await admin
    .database()
    .ref(`buildings/${building}/floorData/${floor}/devices/${deviceId}/relay`)
    .set(relay);
}

async function runAutomationSchedules() {
  const timezoneSnap = await admin.database().ref('settings/timezone').get();
  const timezone = String(timezoneSnap.val() ?? 'Asia/Manila');
  const clock = getClockParts(timezone);
  const currentMinutes = clock.hour * 60 + clock.minute;
  const day = clock.day || 'Mon';

  const [automationSnap, deviceSnap] = await Promise.all([
    admin.database().ref('automations').get(),
    admin.database().ref('devices').get(),
  ]);

  const automationRaw = automationSnap.val();
  const deviceRaw = deviceSnap.val();

  if (!automationRaw || typeof automationRaw !== 'object') return;
  if (!deviceRaw || typeof deviceRaw !== 'object') return;

  const automations = Object.entries(automationRaw)
    .filter(([, value]) => value && typeof value === 'object')
    .map(([id, value]) => parseAutomationSchedule(id, value));

  const devices = Object.entries(deviceRaw)
    .filter(([, value]) => value && typeof value === 'object')
    .map(([deviceId, value]) => [deviceId, value]);

  for (const schedule of automations) {
    if (!schedule.enabled) continue;

    const action = matchesScheduleWindow(schedule, day, currentMinutes);
    if (!action) continue;

    const desiredRelay = action === 'on';
    for (const [deviceId, device] of devices) {
      const scope = schedule.scope;
      const target = schedule.target;
      const utility = schedule.utility;

      let matches = false;
      if (scope === 'global') {
        matches = isUtilityMatch(utility, device.utility);
      } else if (scope === 'building') {
        matches = isBuildingMatch(target, device.building) && isUtilityMatch(utility, device.utility);
      } else if (scope === 'utility') {
        matches = isUtilityMatch(target, device.utility);
      } else if (scope === 'device') {
        matches = normalizeText(deviceId) === normalizeText(target);
      }

      if (!matches) continue;

      const currentRelay = parseBoolean(device.relay);
      if (currentRelay === desiredRelay) continue;

      await admin.database().ref(`devices/${deviceId}/relay`).set(desiredRelay);
      await mirrorRelay(deviceId, normalizeText(device.building), normalizeText(device.floor), desiredRelay);
      console.log(`[AutomationScheduler] ${deviceId} -> ${desiredRelay ? 'ON' : 'OFF'}`);
    }
  }
}

// ── Change password of any user (admin only) ─────────────────
exports.changeUserPassword = functions.https.onCall(async (data, context) => {
  // 1. Must be authenticated
  if (!context.auth) {
    throw new functions.https.HttpsError(
      'unauthenticated', 'You must be logged in.');
  }

  // 2. Must be admin role
  const callerUid = context.auth.uid;
  const callerSnap = await admin.database().ref(`users/${callerUid}/role`).get();
  const callerRole = callerSnap.val();

  if (callerRole !== 'admin') {
    throw new functions.https.HttpsError(
      'permission-denied', 'Only admins can change passwords.');
  }

  // 3. Validate inputs
  const { uid, newPassword } = data;

  if (!uid || !newPassword) {
    throw new functions.https.HttpsError(
      'invalid-argument', 'uid and newPassword are required.');
  }

  if (newPassword.length < 6) {
    throw new functions.https.HttpsError(
      'invalid-argument', 'Password must be at least 6 characters.');
  }

  // 4. Update password using Admin SDK
  await admin.auth().updateUser(uid, { password: newPassword });

  // 5. Clean up the passwordReset flag in DB if it exists
  await admin.database().ref(`users/${uid}/passwordReset`).remove();

  return { success: true, message: 'Password updated successfully.' };
});

// ── Auto-write PZEM history when device kwh changes ─────────────
const { writeHistoryForDevice } = require('./history_writer');

exports.onDeviceKwhChange = functions.database
  .ref('devices/{deviceId}/kwh')
  .onWrite(async (change, context) => {
    const deviceId = context.params.deviceId;
    const newKwh = change.after.val();

    // Only process if new kwh value exists and is valid
    if (typeof newKwh !== 'number' || newKwh < 0) {
      return;
    }

    try {
      // Get device building info
      const deviceSnap = await admin.database().ref(`devices/${deviceId}`).get();
      const device = deviceSnap.val();

      if (!device || !device.building) {
        return;
      }

      const building = String(device.building).trim();
      const kwh = parseFloat(newKwh);

      // Write the kwh delta to history
      // Only record incremental changes (new kwh value) to history
      await writeHistoryForDevice(deviceId, building, kwh);
    } catch (error) {
      console.error(`[onDeviceKwhChange] Error processing ${deviceId}: ${error.message}`);
    }
  });

// ── Run automation scheduler every minute ─────────────────────────
exports.runAutomationScheduler = onSchedule('* * * * *', runAutomationSchedules);

// ── Delete user from Firebase Auth (admin only) ──────────────
exports.deleteUser = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      'unauthenticated', 'You must be logged in.');
  }

  const callerUid = context.auth.uid;
  const callerSnap = await admin.database().ref(`users/${callerUid}/role`).get();
  const callerRole = callerSnap.val();

  if (callerRole !== 'admin') {
    throw new functions.https.HttpsError(
      'permission-denied', 'Only admins can delete users.');
  }

  const { uid } = data;

  if (!uid) {
    throw new functions.https.HttpsError(
      'invalid-argument', 'uid is required.');
  }

  // Prevent deleting own account
  if (uid === callerUid) {
    throw new functions.https.HttpsError(
      'invalid-argument', 'You cannot delete your own account.');
  }

  // Delete from Firebase Auth
  await admin.auth().deleteUser(uid);

  // Delete from Realtime Database
  await admin.database().ref(`users/${uid}`).remove();

  return { success: true, message: 'User deleted successfully.' };
});


exports.runAutomationSchedules = onSchedule('every 1 minute', async () => {
  await runAutomationSchedules();
});