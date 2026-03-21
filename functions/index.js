const functions = require('firebase-functions');
const admin = require('firebase-admin');

admin.initializeApp();

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