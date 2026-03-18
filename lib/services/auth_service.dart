import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_core/firebase_core.dart';

class AuthService {
  static final _auth = FirebaseAuth.instance;
  static final _db   = FirebaseDatabase.instance;

  // ── Current user ─────────────────────────────────────────────
  static User? get currentUser => _auth.currentUser;

  // ── Get role of current user ──────────────────────────────────
  static Future<String> getCurrentRole() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return 'faculty';
    final snap = await _db.ref('users/$uid/role').get();
    return snap.value as String? ?? 'faculty';
  }

  // ── Login ─────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> login(String email, String password) async {
    final cred = await _auth.signInWithEmailAndPassword(
      email: email, password: password,
    );
    final uid  = cred.user!.uid;
    final snap = await _db.ref('users/$uid').get();

    if (!snap.exists) {
      // First login — create user entry with faculty role by default
      await _db.ref('users/$uid').set({
        'email': email,
        'role':  'faculty',
        'name':  email.split('@').first,
      });
      return {'role': 'faculty', 'uid': uid};
    }

    final data = Map<String, dynamic>.from(snap.value as Map);
    return {'role': data['role'] ?? 'faculty', 'uid': uid};
  }

  // ── Logout ────────────────────────────────────────────────────
  static Future<void> logout() async {
    await _auth.signOut();
  }

  // ── Admin creates a new user account ─────────────────────────
  // Uses a secondary FirebaseApp so it doesn't log out the admin
  static Future<void> createUser({
    required String email,
    required String password,
    required String name,
    required String role,
  }) async {
    // Create via REST — avoids signing out current admin
    final currentUser = _auth.currentUser;
    if (currentUser == null) throw Exception('Not logged in');

    // Create auth account
    final cred = await FirebaseAuth.instanceFor(
      app: _auth.app,
    ).createUserWithEmailAndPassword(email: email, password: password);

    final newUid = cred.user!.uid;

    // Store in database
    await _db.ref('users/$newUid').set({
      'email': email,
      'name':  name,
      'role':  role,
    });

    // Sign back in as admin (createUserWithEmailAndPassword signs in as new user)
    await _auth.signInWithEmailAndPassword(
      email:    currentUser.email!,
      password: password, // Admin must re-enter their password — see AddUserScreen
    );
  }

  // ── Simpler: admin creates user and stays logged in ──────────
  // Best practice: use Firebase Admin SDK on backend.
  // For now we create the user record directly and send password reset email.
  static Future<void> createUserSafe({
    required String email,
    required String name,
    required String role,
    required String adminEmail,
    required String adminPassword,
  }) async {
    // Step 1: create the Firebase Auth account
    final secondaryApp = await Firebase.initializeApp(
      name: 'secondary',
      options: Firebase.app().options,
    );
    final secondaryAuth = FirebaseAuth.instanceFor(app: secondaryApp);
    final tempPassword  = 'Temp@${DateTime.now().millisecondsSinceEpoch}';

    final cred = await secondaryAuth.createUserWithEmailAndPassword(
      email: email, password: tempPassword,
    );
    final newUid = cred.user!.uid;
    await secondaryApp.delete();

    // Step 2: store in Realtime Database
    await _db.ref('users/$newUid').set({
      'email': email,
      'name':  name,
      'role':  role,
    });

    // Step 3: send password reset so user sets their own password
    await _auth.sendPasswordResetEmail(email: email);
  }

  // ── Update user role ──────────────────────────────────────────
  static Future<void> updateRole(String uid, String role) async {
    await _db.ref('users/$uid/role').set(role);
  }

  // ── Delete user from database (Auth deletion needs Admin SDK) ─
  static Future<void> removeUser(String uid) async {
    await _db.ref('users/$uid').remove();
  }

  // ── Password reset ────────────────────────────────────────────
  static Future<void> sendPasswordReset(String email) async {
    await _auth.sendPasswordResetEmail(email: email);
  }

  // ── Friendly error messages ───────────────────────────────────
  static String friendlyError(String code) {
    switch (code) {
      case 'user-not-found':        return 'No account found with this email.';
      case 'wrong-password':        return 'Incorrect password. Please try again.';
      case 'invalid-email':         return 'Please enter a valid email address.';
      case 'too-many-requests':     return 'Too many attempts. Please wait and try again.';
      case 'email-already-in-use':  return 'An account with this email already exists.';
      case 'weak-password':         return 'Password must be at least 6 characters.';
      default:                      return 'Something went wrong. Please try again.';
    }
  }
}
