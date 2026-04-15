import 'dart:async';
import 'dart:math';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../config/app_mode.dart';
import 'mock_live_feed_service.dart';
import 'mock_seed_service.dart';

class RuntimeModeService {
  static final ValueNotifier<String> mode = ValueNotifier<String>('normal');

  static StreamSubscription<DatabaseEvent>? _modeSub;
  static bool _applying = false;
  static Timer? _leaderTimer;
  static bool _isLeader = false;

  static const int _leaseMs = 30000;
  static const int _heartbeatEveryMs = 10000;
  static final String _clientId =
      '${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(1 << 20)}';

  static DatabaseReference get _leaderRef =>
      FirebaseDatabase.instance.ref('meta/demoFeedLeader');

  static String _normalize(String? raw) {
    final v = (raw ?? '').toLowerCase().trim();
    if (v == 'demo') return 'demo';
    if (v == 'production') return 'normal';
    return 'normal';
  }

  static Future<void> initialize() async {
    final ref = FirebaseDatabase.instance.ref('settings/appMode');

    try {
      final initialSnap = await ref.get();
      final remoteMode = _normalize(initialSnap.value?.toString());
      final initial = initialSnap.value == null
          ? (kUseMockData ? 'demo' : 'normal')
          : remoteMode;

      if (initialSnap.value == null) {
        await ref.set(initial);
      }

      await _applyMode(initial);

      _modeSub?.cancel();
      _modeSub = ref.onValue.listen((event) async {
        final next = _normalize(event.snapshot.value?.toString());
        if (next == mode.value) return;
        await _applyMode(next);
      });
    } catch (e) {
      debugPrint('RuntimeModeService initialize failed: $e');
      const fallback = kUseMockData ? 'demo' : 'normal';
      await _applyMode(fallback);
    }
  }

  static Future<void> setMode(String nextMode,
      {String? requestedByUid, String? requestedByEmail}) async {
    // Caller (Settings admin UI) performs role validation. This avoids
    // false negatives when user records are keyed differently in RTDB.
    final normalized = _normalize(nextMode);
    await FirebaseDatabase.instance.ref('settings/appMode').set(normalized);
  }

  static Future<void> _leaderTick() async {
    if (mode.value != 'demo') {
      _isLeader = false;
      MockLiveFeedService.stop();
      return;
    }

    if (_isLeader) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final result = await _leaderRef.runTransaction((current) {
        if (current is! Map) {
          return Transaction.abort();
        }
        final map = Map<String, dynamic>.from(current);
        if ((map['clientId'] ?? '').toString() != _clientId) {
          return Transaction.abort();
        }
        return Transaction.success({
          'clientId': _clientId,
          'heartbeatAt': now,
          'expiresAt': now + _leaseMs,
        });
      });

      final holder = result.snapshot.value is Map
          ? (Map<String, dynamic>.from(result.snapshot.value as Map)['clientId']
                  ?.toString() ??
              '')
          : '';
      _isLeader = result.committed && holder == _clientId;
      if (!_isLeader) {
        MockLiveFeedService.stop();
      }
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final claim = await _leaderRef.runTransaction((current) {
      if (current is Map) {
        final map = Map<String, dynamic>.from(current);
        final owner = (map['clientId'] ?? '').toString();
        final expiresAt = (map['expiresAt'] as num?)?.toInt() ?? 0;
        final activeOtherOwner =
            owner.isNotEmpty && owner != _clientId && expiresAt > now;
        if (activeOtherOwner) {
          return Transaction.abort();
        }
      }

      return Transaction.success({
        'clientId': _clientId,
        'heartbeatAt': now,
        'expiresAt': now + _leaseMs,
      });
    });

    final claimedBy = claim.snapshot.value is Map
        ? (Map<String, dynamic>.from(claim.snapshot.value as Map)['clientId']
                ?.toString() ??
            '')
        : '';
    _isLeader = claim.committed && claimedBy == _clientId;
    if (_isLeader) {
      await MockLiveFeedService.start(force: true);
    } else {
      MockLiveFeedService.stop();
    }
  }

  static Future<void> _releaseLeadershipIfOwned() async {
    if (!_isLeader) return;
    await _leaderRef.runTransaction((current) {
      if (current is! Map) return Transaction.abort();
      final map = Map<String, dynamic>.from(current);
      if ((map['clientId'] ?? '').toString() != _clientId) {
        return Transaction.abort();
      }
      return Transaction.success(null);
    });
    _isLeader = false;
  }

  static void _startLeaderLoop() {
    _leaderTimer?.cancel();
    _leaderTick();
    _leaderTimer = Timer.periodic(
      const Duration(milliseconds: _heartbeatEveryMs),
      (_) => _leaderTick(),
    );
  }

  static Future<void> _stopLeaderLoop() async {
    _leaderTimer?.cancel();
    _leaderTimer = null;
    await _releaseLeadershipIfOwned();
  }

  static Future<void> _applyMode(String nextMode) async {
    if (_applying) return;
    _applying = true;
    try {
      mode.value = nextMode;
      if (nextMode == 'demo') {
        await MockSeedService.seedIfNeeded(force: true, reseed: false);
        await FirebaseDatabase.instance
            .ref('meta/runtimeDemoActive')
            .set(true);
        _startLeaderLoop();
      } else {
        await _stopLeaderLoop();
        MockLiveFeedService.stop();
        final markerRef = FirebaseDatabase.instance.ref('meta/runtimeDemoActive');
        final markerUpdate = await markerRef.runTransaction((current) {
          if (current == true) return Transaction.success(false);
          return Transaction.abort();
        });
        if (markerUpdate.committed) {
          await MockSeedService.clearRuntimeDemoData();
        }
      }
    } catch (e) {
      debugPrint('RuntimeModeService apply failed: $e');
    } finally {
      _applying = false;
    }
  }
}
