import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

class RoleProvider extends ChangeNotifier {
  String _role = 'faculty';
  String _name = '';
  String _email = '';
  bool   _loaded = false;

  String get role    => _role;
  String get name    => _name;
  String get email   => _email;
  bool   get loaded  => _loaded;
  bool   get isAdmin => _role == 'admin';

  Future<void> load() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _email = user.email ?? '';

    final snap = await FirebaseDatabase.instance.ref('users/${user.uid}').get();
    if (snap.exists) {
      final data = Map<String, dynamic>.from(snap.value as Map);
      _role  = data['role'] as String? ?? 'faculty';
      _name  = data['name'] as String? ?? _email.split('@').first;
    }

    _loaded = true;
    notifyListeners();
  }

  void clear() {
    _role   = 'faculty';
    _name   = '';
    _email  = '';
    _loaded = false;
    notifyListeners();
  }
}
