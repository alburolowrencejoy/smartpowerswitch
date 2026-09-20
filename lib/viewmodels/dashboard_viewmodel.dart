import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DashboardViewModel extends ChangeNotifier {
  // Data fields
  List<Map<String, dynamic>> buildings = [];
  double totalKwh = 0.0;
  double monthlyKwh = 0.0;
  double monthlyCostPhp = 0.0;
  double electricityRate = 11.5;
  int assignedDevices = 0;
  int unassignedDevices = 0;
  Map<String, int> buildingDeviceCounts = {};
  Map<String, double> buildingEnergy = {};
  Map<String, double> utilityTotals = {};
  List<Map<String, dynamic>> historyData = [];

  /// True until the very first combined emission has been processed for
  /// this ViewModel instance. Never reverts to true afterwards -- a fresh
  /// instance (re-navigating to the dashboard) is the only legitimate reset.
  bool isLoading = true;

  /// True when the combined stream failed (or timed out) before its first
  /// successful emission -- i.e. this screen has never had real data to
  /// show. [dashboard_web.dart] renders a retry affordance while this is
  /// true. Never set once [_hasLoadedOnce] is true: a later stream error
  /// must not blank data that already loaded once.
  bool hasError = false;
  String? errorMessage;

  /// True once the combined stream has emitted successfully at least once
  /// for this instance. Tracked separately from [isLoading] because the
  /// timeout below can flip [isLoading] to false (to escape the skeleton)
  /// before any real data has arrived.
  bool _hasLoadedOnce = false;

  /// How long to wait for the combined stream's first emission before
  /// surfacing an error instead of spinning forever.
  static const Duration _loadTimeout = Duration(seconds: 15);
  Timer? _timeoutTimer;

  int unreadNotificationCount = 0;
  int _lastSeenNotificationTimestamp = 0;
  int _latestNotificationTimestamp = 0;
  Object? _latestNotificationsRaw;

  StreamSubscription? _combinedSub;

  Future<void> initialize() async {
    await _loadNotificationReadState();
    _listenAll();
  }

  Future<void> disposeViewModel() async {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    await _combinedSub?.cancel();
    _combinedSub = null;
    super.dispose();
  }

  /// Clears any error state, resets the loading flag, and re-attaches the
  /// combined listener from scratch. Called from the retry button
  /// [dashboard_web.dart] renders while [hasError] is true.
  void retry() {
    hasError = false;
    errorMessage = null;
    isLoading = true;
    notifyListeners();
    _timeoutTimer?.cancel();
    _combinedSub?.cancel();
    _listenAll();
  }

  Future<void> _loadNotificationReadState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _lastSeenNotificationTimestamp =
          prefs.getInt('notifications_last_seen_timestamp') ?? 0;
    } catch (_) {}
  }

  void _listenAll() {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(_loadTimeout, () {
      if (_hasLoadedOnce) return;
      isLoading = false;
      hasError = true;
      errorMessage =
          'Loading is taking too long. Check your connection and try again.';
      notifyListeners();
    });

    _combinedSub = Rx.combineLatestList<DatabaseEvent>([
      FirebaseDatabase.instance.ref('buildings').onValue,
      FirebaseDatabase.instance.ref('master_devices').onValue,
      FirebaseDatabase.instance.ref('devices').onValue,
      FirebaseDatabase.instance.ref('settings/electricityRate').onValue,
      FirebaseDatabase.instance.ref('history').onValue,
      FirebaseDatabase.instance
          .ref('notifications')
          .orderByChild('timestamp')
          .limitToLast(100)
          .onValue,
    ]).listen((events) {
      _applyBuildings(events[0].snapshot.value);
      _applyMasterDevices(events[1].snapshot.value);
      _applyEnergyData(events[2].snapshot.value);
      _applyRate(events[3].snapshot.value);
      _applyHistory(events[4].snapshot.value);
      _applyNotifications(events[5].snapshot.value);

      _hasLoadedOnce = true;
      isLoading = false;
      hasError = false;
      errorMessage = null;
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
      notifyListeners();
    }, onError: (Object error) {
      if (!_hasLoadedOnce) {
        // Real failure (permission-denied, RTDB outage, offline with no
        // reconnect, parse exception) before any successful load -- the
        // skeleton must not spin forever.
        _timeoutTimer?.cancel();
        _timeoutTimer = null;
        isLoading = false;
        hasError = true;
        final text = error.toString().toLowerCase();
        final denied = text.contains('permission-denied') ||
            text.contains('permission_denied') ||
            text.contains('permission');
        errorMessage = denied
            ? 'You do not have permission to view dashboard data.'
            : 'Failed to load dashboard data.';
        notifyListeners();
      } else {
        // Sticky data already loaded once -- preserve existing behavior
        // (don't blank real data on a transient error). No BuildContext is
        // available here for a toast; log for diagnostics only.
        debugPrint('[DashboardViewModel] post-load stream error: $error');
      }
    });
  }

  void _applyNotifications(Object? raw) {
    if (raw == null || raw is! Map) {
      if (isLoading) {
        unreadNotificationCount = 0;
      }
      return;
    }
    _latestNotificationsRaw = raw;
    _recalculateUnreadNotificationCount();
  }

  void _recalculateUnreadNotificationCount() {
    final raw = _latestNotificationsRaw;
    if (raw == null || raw is! Map) {
      if (isLoading) {
        unreadNotificationCount = 0;
      }
      return;
    }

    int unread = 0;
    int latest = 0;
    for (final value in raw.values) {
      if (value is! Map) continue;
      final map = Map<String, dynamic>.from(value);
      final timestamp = _asTimestamp(map['timestamp']);
      if (timestamp <= 0) continue;
      if (timestamp > _lastSeenNotificationTimestamp) unread++;
      if (timestamp > latest) latest = timestamp;
    }
    unreadNotificationCount = unread;
    _latestNotificationTimestamp = latest;
  }

  int _asTimestamp(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  /// Mirrors the mobile dashboard's `_openNotifications()`: persists the
  /// latest notification timestamp as "seen" and clears the badge.
  Future<void> markNotificationsSeen() async {
    final latest = _latestNotificationTimestamp;
    if (latest <= 0) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('notifications_last_seen_timestamp', latest);
      _lastSeenNotificationTimestamp = latest;
      unreadNotificationCount = 0;
      notifyListeners();
    } catch (_) {}
  }

  void _applyBuildings(Object? raw) {
    if (raw == null || raw is! Map) {
      if (isLoading) {
        buildings = [];
      }
      return;
    }
    try {
      final data = Map<String, dynamic>.from(raw);
      final List<Map<String, dynamic>> list = [];
      data.forEach((code, val) {
        if (val is! Map) return;
        final b = Map<String, dynamic>.from(val);
        list.add({
          'code': code,
          'name': (b['name'] ?? code).toString(),
          'floors': (b['floors'] ?? 1) as int,
        });
      });
      list.sort(
          (a, b) => (a['code'] as String).compareTo(b['code'] as String));
      buildings = list;
    } catch (_) {
      if (isLoading) {
        buildings = [];
      }
    }
  }

  void _applyMasterDevices(Object? raw) {
    if (raw == null) {
      if (isLoading) {
        assignedDevices = 0;
        unassignedDevices = 0;
        buildingDeviceCounts = {};
      }
      return;
    }
    final data = Map<String, dynamic>.from(raw as Map);
    int assigned = 0, unassigned = 0;
    Map<String, int> bCounts = {};
    data.forEach((id, val) {
      if (val is! Map) return;
      final device = Map<String, dynamic>.from(val);
      final assignedTo = (device['assignedTo'] ?? '').toString();
      if (assignedTo.isNotEmpty) {
        assigned++;
        final parts = assignedTo.split('/');
        if (parts.isNotEmpty) {
          bCounts[parts[0]] = (bCounts[parts[0]] ?? 0) + 1;
        }
      } else {
        unassigned++;
      }
    });
    assignedDevices = assigned;
    unassignedDevices = unassigned;
    buildingDeviceCounts = bCounts;
  }

  void _applyEnergyData(Object? raw) {
    if (raw == null) {
      if (isLoading) {
        totalKwh = 0;
        utilityTotals = {};
      }
      return;
    }
    final data = Map<String, dynamic>.from(raw as Map);
    double total = 0;
    Map<String, double> uTotals = {};
    data.forEach((id, val) {
      if (val is! Map) return;
      final device = Map<String, dynamic>.from(val);
      final utility = (device['utility'] ?? '').toString();
      final kwhValue = device['kwh'];
      final kwh = kwhValue is num
          ? kwhValue.toDouble()
          : double.tryParse(kwhValue?.toString() ?? '') ?? 0.0;
      total += kwh;
      final n = utility.isEmpty
          ? ''
          : utility[0].toUpperCase() + utility.substring(1).toLowerCase();
      if (n.isNotEmpty) uTotals[n] = (uTotals[n] ?? 0) + kwh;
    });
    totalKwh = total;
    utilityTotals = uTotals;
    monthlyCostPhp = monthlyKwh * electricityRate;
  }

  void _applyRate(Object? raw) {
    final rate = (raw as num?)?.toDouble();
    if (rate == null) {
      // electricityRate already defaults to 11.5 and should never regress.
      return;
    }
    electricityRate = rate;
    monthlyCostPhp = monthlyKwh * rate;
  }

  void _applyHistory(Object? raw) {
    if (raw == null) {
      if (isLoading) {
        historyData = [];
        buildingEnergy = {};
      }
      return;
    }
    try {
      final root = Map<String, dynamic>.from(raw as Map);
      buildingEnergy = _currentMonthBuildingEnergy(root);
      final monthKey = _monthKey(DateTime.now());
      final monthlyNode = root['monthly'];
      if (monthlyNode is Map) {
        final monthlyMap = Map<String, dynamic>.from(monthlyNode);
        final monthNode = monthlyMap[monthKey];
        if (monthNode is Map) {
          final monthMap = Map<String, dynamic>.from(monthNode);
          final totalKwh = monthMap['total_kwh'] ?? 0.0;
          monthlyKwh = (totalKwh is num) ? totalKwh.toDouble() : 0.0;
          monthlyCostPhp = (monthMap['total_cost'] is num)
              ? (monthMap['total_cost'] as num).toDouble()
              : monthlyKwh * electricityRate;
        }
      }
      historyData = _parseAnalyticsEntries(root, 'daily');
    } catch (_) {
      if (isLoading) {
        historyData = [];
        buildingEnergy = {};
      }
    }
  }

  Map<String, double> _currentMonthBuildingEnergy(Map<String, dynamic> root) {
    final monthKey = _monthKey(DateTime.now());
    final monthlyNode = root['monthly'];
    if (monthlyNode is! Map) return {};
    final monthlyMap = Map<String, dynamic>.from(monthlyNode);
    final monthNode = monthlyMap[monthKey];
    if (monthNode is! Map) return {};
    final monthMap = Map<String, dynamic>.from(monthNode);
    final buildingsNode = monthMap['buildings'];
    if (buildingsNode is! Map) return {};
    final result = <String, double>{};
    final buildingsMap = Map<String, dynamic>.from(buildingsNode);
    buildingsMap.forEach((building, value) {
      if (value is Map) {
        final data = Map<String, dynamic>.from(value);
        final kwh = (data['kwh'] ?? 0.0) as num;
        result[building.toString()] = kwh.toDouble();
      } else if (value is num) {
        result[building.toString()] = value.toDouble();
      }
    });
    return result;
  }

  List<Map<String, dynamic>> _parseAnalyticsEntries(
      Map<String, dynamic> root, String rangeKey) {
    final data = root[rangeKey];
    if (data is! Map) return [];
    final list = <Map<String, dynamic>>[];
    final map = Map<String, dynamic>.from(data);
    map.forEach((key, val) {
      if (val is! Map) return;
      final entry = Map<String, dynamic>.from(val);
      list.add({
        'label': key,
        'kwh': (entry['total_kwh'] ?? 0.0) as num,
        'cost': (entry['total_cost'] ?? 0.0) as num
      });
    });
    if (list.isNotEmpty) {
      list.sort((a, b) => a['label'].compareTo(b['label']));
    }
    return list;
  }

  String _monthKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}';
}
