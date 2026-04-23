import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config/app_mode.dart';

class MockLiveFeedService {
  static Timer? _timer;

  static Future<void> startIfNeeded() async {
    await start();
  }

  static Future<void> start({bool force = false}) async {
    if (!force && !kEnableMockLiveFeed) return;
    debugPrint('MockLiveFeedService is disabled.');
  }

  static Future<void> _tick() async {
    debugPrint('MockLiveFeedService tick skipped (disabled).');
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
