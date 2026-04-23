import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

class RuntimeModeService {
  static final ValueNotifier<String> mode = ValueNotifier<String>('normal');

  static String _normalize(String? raw) {
    final v = (raw ?? '').toLowerCase().trim();
    if (v == 'production') return 'normal';
    return 'normal';
  }

  static Future<void> initialize() async {
    final ref = FirebaseDatabase.instance.ref('settings/appMode');
    try {
      final current = _normalize((await ref.get()).value?.toString());
      if (current != 'normal') {
        await ref.set('normal');
      }
      mode.value = 'normal';
    } catch (e) {
      debugPrint('RuntimeModeService initialize failed: $e');
      mode.value = 'normal';
    }
  }

  static Future<void> setMode(String nextMode,
      {String? requestedByUid, String? requestedByEmail}) async {
    await FirebaseDatabase.instance.ref('settings/appMode').set('normal');
    mode.value = 'normal';
  }
}
