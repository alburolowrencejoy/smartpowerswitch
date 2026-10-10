// Use the v1 compatibility API for Realtime Database and HTTPS onCall triggers
// while still using v2 scheduler for cron-style scheduling.
const functions = require('firebase-functions/v1');
const admin = require('firebase-admin');
const { onSchedule } = require('firebase-functions/v2/scheduler');

admin.initializeApp();

// ── Automation schedules ────────────────────────────────────────────
// The schedule rules live in schedule_logic.js (ported from the app's
// scheduler, so calendar date ranges, multiple windows and overnight
// windows all run on the server).
const { planRelayChanges } = require('./schedule_logic');

async function mirrorRelay(deviceId, building, floor, relay) {
  if (!building || !floor) return;

  await admin
    .database()
    .ref(`buildings/${building}/floorData/${floor}/devices/${deviceId}/relay`)
    .set(relay);
}

async function runAutomationSchedules() {
  const [timezoneSnap, automationSnap, deviceSnap] = await Promise.all([
    admin.database().ref('settings/timezone').get(),
    admin.database().ref('automations').get(),
    admin.database().ref('devices').get(),
  ]);

  const changes = planRelayChanges({
    automations: automationSnap.val(),
    devices: deviceSnap.val(),
    nowMs: Date.now(),
    timeZone: String(timezoneSnap.val() ?? 'Asia/Manila'),
  });

  for (const { deviceId, relay, building, floor } of changes) {
    await admin.database().ref(`devices/${deviceId}/relay`).set(relay);
    await mirrorRelay(deviceId, building, floor, relay);
    console.log(`[AutomationScheduler] ${deviceId} -> ${relay ? 'ON' : 'OFF'}`);
  }
}

// ── Shared authorization check for admin-only user-management actions ──
// - admin / main_admin / super_admin: unrestricted.
// - institute_admin: only for target users in their own institute.
async function assertCanManageUser(callerUid, targetUid) {
  const [callerSnap, targetSnap] = await Promise.all([
    admin.database().ref(`users/${callerUid}`).get(),
    admin.database().ref(`users/${targetUid}`).get(),
  ]);
  const caller = callerSnap.val() || {};
  const callerRole = caller.role;

  if (
    callerRole === 'admin' ||
    callerRole === 'main_admin' ||
    callerRole === 'super_admin' ||
    caller.isMainAdmin === true
  ) {
    return;
  }

  if (callerRole === 'institute_admin' && caller.institute) {
    const target = targetSnap.val() || {};
    if (target.institute === caller.institute) {
      return;
    }
  }

  throw new functions.https.HttpsError(
    'permission-denied', 'You do not have permission to manage this user.');
}

// ── Change password of a user (admin tiers only) ─────────────────
exports.changeUserPassword = functions.https.onCall(async (data, context) => {
  // 1. Must be authenticated
  if (!context.auth) {
    throw new functions.https.HttpsError(
      'unauthenticated', 'You must be logged in.');
  }

  // 2. Validate inputs
  const callerUid = context.auth.uid;
  const { uid, newPassword } = data;

  if (!uid || !newPassword) {
    throw new functions.https.HttpsError(
      'invalid-argument', 'uid and newPassword are required.');
  }

  if (newPassword.length < 6) {
    throw new functions.https.HttpsError(
      'invalid-argument', 'Password must be at least 6 characters.');
  }

  // 3. Must be an admin tier authorized to manage this target user
  await assertCanManageUser(callerUid, uid);

  // 4. Update password using Admin SDK
  await admin.auth().updateUser(uid, { password: newPassword });

  // 5. Clean up the passwordReset flag in DB if it exists
  await admin.database().ref(`users/${uid}/passwordReset`).remove();

  return { success: true, message: 'Password updated successfully.' };
});

// ── Davao Light watcher: verified rate advisories + newsroom posts ──
// (every 6 hours, and on demand from Settings > Fetch Latest Rate).
const davaoLight = require('./davao_light_watch');
exports.watchDavaoLight = davaoLight.watchDavaoLight;
exports.checkDavaoLightNow = davaoLight.checkDavaoLightNow;
exports.verifyAdvisoryText = davaoLight.verifyAdvisoryText;

// ── Energy history: once-a-minute rollup (the only history writer) ──
// Replaces onDeviceKwhChange, which added the meter's lifetime total on
// every reading. See energy_rollup.js / energy_math.js.
exports.rollupEnergy = require('./energy_rollup').rollupEnergy;

// ── Run automation scheduler every minute ─────────────────────────
exports.runAutomationScheduler = onSchedule('* * * * *', runAutomationSchedules);

// ── Delete user from Firebase Auth (admin tiers only) ──────────────
exports.deleteUser = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      'unauthenticated', 'You must be logged in.');
  }

  const callerUid = context.auth.uid;
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

  await assertCanManageUser(callerUid, uid);

  // Delete from Firebase Auth
  await admin.auth().deleteUser(uid);

  // Delete from Realtime Database
  await admin.database().ref(`users/${uid}`).remove();

  return { success: true, message: 'User deleted successfully.' };
});

