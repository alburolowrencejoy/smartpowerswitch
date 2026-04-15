import 'package:flutter/foundation.dart';

// Toggle mock behavior from build args:
// flutter run --dart-define=USE_MOCK_DATA=true
const bool _mockFromEnv =
    bool.fromEnvironment('USE_MOCK_DATA', defaultValue: true);

// Mock mode is allowed only in debug/profile builds by default.
const bool kUseMockData = !kReleaseMode && _mockFromEnv;

// Seed mock data on app startup when mock mode is enabled.
// Disable with: --dart-define=SEED_MOCK_DATA=false
const bool _seedFromEnv =
    bool.fromEnvironment('SEED_MOCK_DATA', defaultValue: true);
const bool kSeedMockData = kUseMockData && _seedFromEnv;

// Force reseeding even if the same seed version was already applied.
// Enable with: --dart-define=FORCE_RESEED_MOCK=true
const bool kForceReseedMock =
    bool.fromEnvironment('FORCE_RESEED_MOCK', defaultValue: false);

// Live mock generator (updates existing devices in realtime).
// Enable with: --dart-define=ENABLE_MOCK_LIVE_FEED=true
const bool _liveFeedFromEnv =
    bool.fromEnvironment('ENABLE_MOCK_LIVE_FEED', defaultValue: true);
const bool kEnableMockLiveFeed = kUseMockData && _liveFeedFromEnv;

// Update interval for mock live feed, in seconds.
// Example: --dart-define=MOCK_LIVE_FEED_INTERVAL_SEC=2
const int kMockLiveFeedIntervalSec =
    int.fromEnvironment('MOCK_LIVE_FEED_INTERVAL_SEC', defaultValue: 3);
