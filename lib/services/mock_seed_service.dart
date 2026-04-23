import 'package:flutter/foundation.dart';

import '../config/app_mode.dart';

class MockSeedService {
  static Future<void> seedIfNeeded({
    bool force = false,
    bool reseed = false,
  }) async {
    if (!force && !kSeedMockData) return;
    debugPrint('MockSeedService is disabled. No mock data will be written.');
  }

  static Future<void> clearRuntimeDemoData() async {
    debugPrint('MockSeedService clearRuntimeDemoData is disabled.');
  }
}
