import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:rxdart/rxdart.dart';
import '../services/energy_history.dart';
import '../services/history_clock.dart';
import '../services/history_keys.dart';
import '../services/notification_seen.dart';
import '../services/rate_timeline.dart';

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

  /// This month's cost per building (₱), as recorded with each reading.
  Map<String, double> buildingCost = {};

  /// This month's `total_cost` as stored in history -- costs are locked in
  /// at the rate in force when each reading was recorded, so a later rate
  /// change never reprices them. Null when the month has no stored cost.
  double? _storedMonthlyCost;

  /// The one cost rule ([RateTimeline.costOf]): the stored cost, else kWh at
  /// the rate in force at the end of the month.
  void _refreshMonthlyCost() => monthlyCostPhp = rates.costOf(
      _storedMonthlyCost,
      monthlyKwh,
      RateTimeline.monthEnd(HistoryClock.instance.now()));

  /// Past rates, for [RateTimeline.costOf].
  RateTimeline get rates => RateHistory.instance.timeline(electricityRate);
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
  Object? _latestNotificationsRaw;

  /// Institute code of an institute admin, so the bell only counts the
  /// notifications they can see (null = sees everything).
  String? _notificationInstitute;
  void setNotificationViewer({String? instituteCode}) {
    if (_notificationInstitute == instituteCode) return;
    _notificationInstitute = instituteCode;
    _recalculateUnreadNotificationCount();
    notifyListeners();
  }

  void _onSeenChanged() {
    _recalculateUnreadNotificationCount();
    notifyListeners();
  }

  StreamSubscription? _combinedSub;

  Future<void> initialize() async {
    await NotificationSeen.instance.ensureLoaded();
    NotificationSeen.instance.lastSeen.addListener(_onSeenChanged);
    _listenAll();
  }

  Future<void> disposeViewModel() async {
    NotificationSeen.instance.lastSeen.removeListener(_onSeenChanged);
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
      FirebaseDatabase.instance.ref(EnergyHistory.root).onValue,
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

    unreadNotificationCount = NotificationSeen.instance
        .unreadCount(raw.values, instituteCode: _notificationInstitute);
  }

  /// Marks every notification as seen (clears every bell and badge).
  Future<void> markNotificationsSeen() async {
    final raw = _latestNotificationsRaw;
    if (raw is! Map) return;
    await NotificationSeen.instance
        .markSeen(NotificationSeen.newestOf(raw.values));
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

  /// Each device's utility ("Lights", "Aircon", ...) from `devices`, used to
  /// split today's energy by utility.
  Map<String, String> _deviceUtility = {};

  /// Only reads each device's utility. Energy never comes from
  /// `devices/{id}/kwh`: that is the meter's lifetime total, not today's use.
  void _applyEnergyData(Object? raw) {
    if (raw is! Map) return;
    final utilities = <String, String>{};
    raw.forEach((id, val) {
      if (val is! Map) return;
      final utility = (val['utility'] ?? '').toString();
      if (utility.isEmpty) return;
      utilities[id.toString()] =
          utility[0].toUpperCase() + utility.substring(1).toLowerCase();
    });
    _deviceUtility = utilities;
  }

  /// Today's campus total and its split by utility, from the daily summary.
  void _applyToday(Map<String, dynamic> root) {
    final now = HistoryClock.instance.now();
    final daily = root['daily'];
    final today = daily is Map
        ? daily[HistoryKeys.dailyKey(now.year, now.month, now.day)]
        : null;
    if (today is! Map) {
      totalKwh = 0;
      utilityTotals = {};
      return;
    }
    final total = today['total_kwh'];
    totalKwh = total is num ? total.toDouble() : 0.0;
    final split = <String, double>{};
    final devices = today['devices'];
    if (devices is Map) {
      devices.forEach((id, d) {
        final utility = _deviceUtility[id.toString()];
        final kwh = d is Map ? d['kwh'] : null;
        if (utility == null || kwh is! num) return;
        split[utility] = (split[utility] ?? 0) + kwh.toDouble();
      });
    }
    utilityTotals = split;
  }

  void _applyRate(Object? raw) {
    final rate = (raw as num?)?.toDouble();
    if (rate == null) {
      // electricityRate already defaults to 11.5 and should never regress.
      return;
    }
    electricityRate = rate;
    _refreshMonthlyCost();
  }

  void _applyHistory(Object? raw) {
    if (raw == null) {
      // Nothing recorded yet (new or freshly cleaned database).
      historyData = [];
      buildingEnergy = {};
      buildingCost = {};
      monthlyKwh = 0;
      _storedMonthlyCost = null;
      totalKwh = 0;
      utilityTotals = {};
      _refreshMonthlyCost();
      return;
    }
    try {
      final root = EnergyHistory.legacyRoot(raw);
      _applyToday(root);
      buildingEnergy = _currentMonthBuildingEnergy(root);
      buildingCost = _currentMonthBuildingEnergy(root, field: 'cost');
      final monthKey = _monthKey(HistoryClock.instance.now());
      final monthlyNode = root['monthly'];
      final monthNode = monthlyNode is Map ? monthlyNode[monthKey] : null;
      if (monthNode is Map) {
        final totalKwh = monthNode['total_kwh'];
        monthlyKwh = (totalKwh is num) ? totalKwh.toDouble() : 0.0;
        final storedCost = monthNode['total_cost'];
        _storedMonthlyCost = storedCost is num ? storedCost.toDouble() : null;
      } else {
        monthlyKwh = 0;
        _storedMonthlyCost = null;
      }
      _refreshMonthlyCost();
      historyData = _parseAnalyticsEntries(root, 'daily');
    } catch (_) {
      if (isLoading) {
        historyData = [];
        buildingEnergy = {};
      }
    }
  }

  /// This month's per-building [field] (`kwh` or `cost`).
  Map<String, double> _currentMonthBuildingEnergy(Map<String, dynamic> root,
      {String field = 'kwh'}) {
    final monthKey = _monthKey(HistoryClock.instance.now());
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
        final v = data[field];
        if (v is num) result[building.toString()] = v.toDouble();
      } else if (value is num && field == 'kwh') {
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
