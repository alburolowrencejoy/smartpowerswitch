import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme/app_colors.dart';
import '../../theme/institute_colors.dart';
import '../../services/automation_scheduler_service.dart';
import '../../utils/placeholder_data.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';
import '../../widgets/trend_chart_painters.dart';
import 'automation_screen.dart';
import 'building_floor_screen.dart';
import '../shared/campus_map_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  static const String _lastSeenNotificationTsKey =
      'notifications_last_seen_timestamp';

  int _selectedIndex = 0;
  String _role = 'faculty';
  String? _institute;
  String _userName = '';
  bool _roleLoaded = false;
  bool _compactMenuOpen = false;

  bool get _isSuperAdmin =>
      _role == 'main_admin' || _role == 'admin' || _role == 'super_admin';
  bool get _isInstituteAdmin => _role == 'institute_admin';
  bool get _canAccessManagement => _isSuperAdmin || _isInstituteAdmin;

  /// Resolution now lives centrally in `InstituteTheme.resolve` (see
  /// theme/institute_colors.dart) instead of being recomputed here.
  ///
  /// Note: this deliberately calls `InstituteTheme.resolve` directly rather
  /// than reading `context.institutePalette`. `build()` below wraps its
  /// *returned* subtree in a local `Theme` carrying the resolved
  /// `InstituteTheme` extension, but `context` here is this State's own
  /// BuildContext -- which sits *above* that locally-created Theme in the
  /// element tree, not below it. `Theme.of(context)` walks up from a
  /// context's position looking for ancestors, so a lookup from this
  /// State's context can never see a Theme that this State's own build()
  /// call introduces further down; it would silently keep resolving to the
  /// ambient (unthemed) app Theme and always fall back to green. Calling
  /// the resolver directly avoids that pitfall. The `Theme` wrap is still
  /// registered below for genuine descendants (e.g. nested screens/shared
  /// widgets with their own BuildContext) that read `context.institutePalette`.
  InstitutePalette get _palette =>
      InstituteTheme.resolve(_role, _institute).palette;

  // Buildings loaded from Firebase
  List<Map<String, dynamic>> _buildings = [];

  double _totalKwh = 0;
  double _monthlyKwh = 0.0;
  double _monthlyCostPhp = 0.0;
  // Compatibility alias: some hot-reload states or older code may set
  // `_totalCostPhp`. Provide a forwarding setter/getter to avoid
  // NoSuchMethodError until a full restart is performed.
  // ignore: unused_element, unnecessary_getters_setters
  double get _totalCostPhp => _monthlyCostPhp;
  // ignore: unused_element, unnecessary_getters_setters
  set _totalCostPhp(double v) => _monthlyCostPhp = v;
  double _electricityRate = 11.5;
  int _assignedDevices = 0;
  int _unassignedDevices = 0;

  // ── Institute-scoped summary (institute_admin home tab only) ──────────
  // Populated by _listenInstituteScoped(), filtered strictly to `_institute`
  // -- never derived from the system-wide totals above. See
  // building_floor_screen.dart for the field-filtering pattern this mirrors.
  double _instituteKwh = 0.0;
  double _instituteMonthlyKwh = 0.0;
  int _instituteAssignedDevices = 0;
  int _instituteOnlineDevices = 0;
  StreamSubscription? _instituteSub;
  Map<String, int> _buildingDeviceCounts = {};
  Map<String, double> _buildingEnergy = {};
  Map<String, double> _utilityTotals = {};
  String _analyticsRange = 'daily';
  String _trendChartType = 'line';
  List<Map<String, dynamic>> _historyData = [];
  // Raw `history` node cached so the analytics range can be re-parsed
  // locally (see _setAnalyticsRange) without re-touching Firebase.
  Map<String, dynamic> _historyRoot = {};
  int _unreadNotificationCount = 0;
  int _lastSeenNotificationTimestamp = 0;
  int _latestNotificationTimestamp = 0;
  Object? _latestNotificationsRaw;

  // True until the very first combined emission of all of this screen's
  // Firebase streams has been received; never reverts to true afterwards
  // for the life of this State, so a later transient null snapshot cannot
  // blank out already-loaded data (see _listenAll).
  bool _isLoading = true;

  // Set only if the combined listener fails (or times out) before the
  // first successful load ever completes -- gives the skeleton shimmer a
  // real escape hatch instead of spinning forever. Once a first load has
  // succeeded, a later error no longer blanks the screen (see onError in
  // _listenAll); it just surfaces a non-blocking toast.
  String? _errorText;
  Timer? _loadTimeoutTimer;
  bool _postLoadErrorNotified = false;

  // Sticky guard for the notification badge, which listens on its own path
  // separately from _combinedSub: once a real notifications snapshot has
  // been parsed, a later null/empty snapshot (reconnect blip) must not
  // reset the unread count back to 0.
  bool _notificationsLoadedOnce = false;

  StreamSubscription? _combinedSub;
  StreamSubscription? _notificationsSub;

  bool _isPermissionDenied(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('permission-denied') ||
        text.contains('permission_denied');
  }

  Future<void> _cancelRealtimeSubs() async {
    await _combinedSub?.cancel();
    await _notificationsSub?.cancel();
    await _instituteSub?.cancel();
    _combinedSub = null;
    _notificationsSub = null;
    _instituteSub = null;
  }

  @override
  void dispose() {
    _loadTimeoutTimer?.cancel();
    _cancelRealtimeSubs();
    super.dispose();
  }

  /// Clears the error state and re-attaches the combined listener from
  /// scratch. Used by the Retry button shown when the first load fails.
  void _retryLoad() {
    _combinedSub?.cancel();
    _loadTimeoutTimer?.cancel();
    setState(() {
      _errorText = null;
      _isLoading = true;
      _postLoadErrorNotified = false;
    });
    _listenAll();
  }

  Future<void> _hydrateSessionFromAuth() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final snap =
          await FirebaseDatabase.instance.ref('users/${user.uid}').get();
      final data = snap.value;
      if (data is! Map) return;

      final map = Map<String, dynamic>.from(data);
      final role = (map['role'] as String?) ?? 'faculty';
      final name =
          (map['name'] as String?) ?? user.email?.split('@').first ?? '';
      final institute = (map['institute'] as String?)?.trim();

      if (!mounted) return;
      setState(() {
        _role = role;
        _userName = name;
        _institute = institute;
      });
      if (_isInstituteAdmin) {
        _listenInstituteScoped();
      }
    } catch (_) {
      // Keep existing role defaults if role hydration fails.
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_roleLoaded) {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map<String, dynamic>) {
        _role = args['role'] as String? ?? 'faculty';
        _userName = args['name'] as String? ?? '';
      }
      _roleLoaded = true;
      _hydrateSessionFromAuth();
      _listenAll();
      _loadNotificationReadState();
      _listenToNotifications();
    }
  }

  Future<void> _loadNotificationReadState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _lastSeenNotificationTimestamp =
          prefs.getInt(_lastSeenNotificationTsKey) ?? 0;
      if (!mounted) return;
      _recalculateUnreadNotificationCount();
    } catch (_) {
      // Keep the badge hidden if unread state cannot be loaded.
    }
  }

  void _listenToNotifications() {
    _notificationsSub?.cancel();
    _notificationsSub = FirebaseDatabase.instance
        .ref('notifications')
        .orderByChild('timestamp')
        .limitToLast(100)
        .onValue
        .listen((event) {
      if (!mounted) return;
      _latestNotificationsRaw = event.snapshot.value;
      _recalculateUnreadNotificationCount();
    }, onError: (Object error) {
      debugPrint('[NotificationsBadge] Listen error: $error');
    });
  }

  void _recalculateUnreadNotificationCount() {
    final raw = _latestNotificationsRaw;
    if (raw == null || raw is! Map) {
      if (_notificationsLoadedOnce) return;
      if (!mounted) return;
      setState(() {
        _latestNotificationTimestamp = 0;
        _unreadNotificationCount = 0;
      });
      return;
    }

    int unread = 0;
    int latest = 0;
    for (final value in raw.values) {
      if (value is! Map) continue;
      final map = Map<String, dynamic>.from(value);
      final timestamp = _asTimestamp(map['timestamp']);
      if (timestamp <= 0) continue;
      if (timestamp > _lastSeenNotificationTimestamp) {
        unread++;
      }
      if (timestamp > latest) {
        latest = timestamp;
      }
    }

    if (!mounted) return;
    setState(() {
      _latestNotificationTimestamp = latest;
      _unreadNotificationCount = unread;
      _notificationsLoadedOnce = true;
    });
  }

  int _asTimestamp(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<void> _openNotifications() async {
    final latest = _latestNotificationTimestamp;
    if (latest > 0) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_lastSeenNotificationTsKey, latest);
      if (!mounted) return;
      _lastSeenNotificationTimestamp = latest;
      setState(() => _unreadNotificationCount = 0);
    }

    if (!mounted) return;
    Navigator.pushNamed(context, '/notifications');
  }

  // ── Listen to every Firebase path this screen needs in one combined
  // stream so a transient null on any single path can never blank out
  // data this screen has already loaded (see class-level `_isLoading`).
  void _listenAll() {
    _loadTimeoutTimer?.cancel();
    _loadTimeoutTimer = Timer(const Duration(seconds: 15), () {
      if (!mounted || !_isLoading) return;
      setState(() {
        _isLoading = false;
        _errorText =
            'Taking too long to load dashboard data. Check your connection.';
      });
    });

    _combinedSub = Rx.combineLatestList<DatabaseEvent>([
      FirebaseDatabase.instance.ref('buildings').onValue,
      FirebaseDatabase.instance.ref('master_devices').onValue,
      FirebaseDatabase.instance.ref('devices').onValue,
      FirebaseDatabase.instance.ref('settings/electricityRate').onValue,
      FirebaseDatabase.instance.ref('history').onValue,
    ]).listen((events) {
      if (!mounted) return;
      _loadTimeoutTimer?.cancel();
      setState(() {
        // ── buildings ──────────────────────────────────────────────
        final buildingsRaw = events[0].snapshot.value;
        if (buildingsRaw is Map) {
          try {
            final data = Map<String, dynamic>.from(buildingsRaw);
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
            list.sort((a, b) =>
                (a['code'] as String).compareTo(b['code'] as String));
            _buildings = list;
          } catch (e, st) {
            debugPrint('[Buildings] Exception: $e\n$st');
            if (_isLoading) _buildings = [];
          }
        } else if (_isLoading) {
          _buildings = [];
        }

        // ── master_devices (assigned/unassigned counts) ───────────
        final masterRaw = events[1].snapshot.value;
        if (masterRaw is Map) {
          final data = Map<String, dynamic>.from(masterRaw);
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
          _assignedDevices = assigned;
          _unassignedDevices = unassigned;
          _buildingDeviceCounts = bCounts;
        } else if (_isLoading) {
          _assignedDevices = 0;
          _unassignedDevices = 0;
          _buildingDeviceCounts = {};
        }

        // ── devices (today's energy totals) ───────────────────────
        final devicesRaw = events[2].snapshot.value;
        if (devicesRaw is Map) {
          final data = Map<String, dynamic>.from(devicesRaw);
          double totalKwh = 0;
          Map<String, double> uTotals = {};
          data.forEach((id, val) {
            if (val is! Map) return;
            final device = Map<String, dynamic>.from(val);
            final utility = (device['utility'] ?? '').toString();
            final kwhValue = device['kwh'];
            final kwh = kwhValue is num
                ? kwhValue.toDouble()
                : double.tryParse(kwhValue?.toString() ?? '') ?? 0.0;

            totalKwh += kwh;
            final n = _capitalizeFirst(utility);
            if (n.isNotEmpty) uTotals[n] = (uTotals[n] ?? 0) + kwh;
          });
          _totalKwh = totalKwh;
          _utilityTotals = uTotals;
        } else if (_isLoading) {
          _totalKwh = 0;
          _utilityTotals = {};
        }

        // ── electricity rate ───────────────────────────────────────
        final rateRaw = events[3].snapshot.value;
        if (rateRaw is num) {
          _electricityRate = rateRaw.toDouble();
        } else if (_isLoading) {
          _electricityRate = 11.5;
        }

        // ── history (monthly totals + per-building energy) ───────
        final historyRaw = events[4].snapshot.value;
        if (historyRaw is Map) {
          _historyRoot = Map<String, dynamic>.from(historyRaw);
          _historyData = _parseAnalyticsEntries(_historyRoot, _analyticsRange);
          _buildingEnergy = _currentMonthBuildingEnergy(_historyRoot);
          _updateMonthlyTotals(_historyRoot);
        } else if (_isLoading) {
          _historyRoot = {};
          _historyData = [];
          _buildingEnergy = {};
          _monthlyKwh = 0;
          _monthlyCostPhp = 0;
        }

        // Cost is always shown live against the current rate.
        _monthlyCostPhp = _monthlyKwh * _electricityRate;

        _isLoading = false;
        _errorText = null;
        _postLoadErrorNotified = false;
      });
    }, onError: (Object error) {
      if (!mounted) return;
      debugPrint('[Dashboard] Combined listen error: $error');
      _loadTimeoutTimer?.cancel();
      if (_isLoading) {
        // Never loaded successfully yet -- surface a real error state
        // instead of leaving the skeleton shimmer spinning forever.
        setState(() {
          _isLoading = false;
          _errorText = _isPermissionDenied(error)
              ? 'You do not have permission to view dashboard data.'
              : 'Failed to load dashboard data.';
        });
      } else if (!_postLoadErrorNotified) {
        // Already showing real data this session -- keep the sticky data
        // on screen and just surface a lightweight, non-blocking notice.
        _postLoadErrorNotified = true;
        TopToast.show(
          context,
          'Lost connection to live dashboard data.',
          isError: true,
        );
      }
    });
  }

  // ── Institute-scoped combined listener (institute_admin only) ─────────
  // Mirrors the exact field-filtering pattern already proven in
  // building_floor_screen.dart (`_listenAll` there): `devices` filtered by
  // `building == _institute` for today's kWh + online count, `master_devices`
  // filtered by `assignedTo` starting with `"$code/"` for the assigned
  // count, and `history/monthly/{monthKey}/buildings/{code}/kwh` for this
  // month's institute energy. Every number here is scoped to `_institute`
  // only -- never falls back to the system-wide totals used elsewhere on
  // this screen.
  void _listenInstituteScoped() {
    final code = _institute;
    if (code == null || code.isEmpty) return;

    _instituteSub?.cancel();
    final monthKey = _monthKey(DateTime.now());
    _instituteSub = Rx.combineLatestList<DatabaseEvent>([
      FirebaseDatabase.instance.ref('devices').onValue,
      FirebaseDatabase.instance.ref('master_devices').onValue,
      FirebaseDatabase.instance
          .ref('history/monthly/$monthKey/buildings/$code/kwh')
          .onValue,
    ]).listen((events) {
      if (!mounted) return;
      setState(() {
        // ── devices: today's institute kWh + online count ──────────
        final devicesRaw = events[0].snapshot.value;
        if (devicesRaw is Map) {
          final data = Map<String, dynamic>.from(devicesRaw);
          double kwh = 0;
          int online = 0;
          data.forEach((id, val) {
            if (val is! Map) return;
            final device = Map<String, dynamic>.from(val);
            final building = (device['building'] ?? '').toString();
            if (building != code) return;
            kwh += ((device['kwh'] ?? 0.0) as num).toDouble();

            final lastSeen = device['last_seen'];
            if (lastSeen != null && lastSeen != 0) {
              final dt =
                  DateTime.fromMillisecondsSinceEpoch(lastSeen as int);
              if (DateTime.now().difference(dt).inMinutes < 2) online++;
            }
          });
          _instituteKwh = kwh;
          _instituteOnlineDevices = online;
        } else {
          _instituteKwh = 0;
          _instituteOnlineDevices = 0;
        }

        // ── master_devices: assigned count for this institute only ─
        final masterRaw = events[1].snapshot.value;
        if (masterRaw is Map) {
          final data = Map<String, dynamic>.from(masterRaw);
          int assigned = 0;
          data.forEach((id, val) {
            if (val is! Map) return;
            final assignedTo = (val['assignedTo'] ?? '').toString();
            if (assignedTo.startsWith('$code/')) assigned++;
          });
          _instituteAssignedDevices = assigned;
        } else {
          _instituteAssignedDevices = 0;
        }

        // ── this month's institute energy from history ──────────────
        final historyRaw = events[2].snapshot.value;
        if (historyRaw is num) {
          _instituteMonthlyKwh = historyRaw.toDouble();
        } else {
          _instituteMonthlyKwh = 0;
        }
      });
    }, onError: (Object error) {
      debugPrint('[Dashboard] Institute-scoped listen error: $error');
    });
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

  void _updateMonthlyTotals(Map<String, dynamic> root) {
    try {
      final monthKey = _monthKey(DateTime.now());
      final monthlyNode = root['monthly'];

      if (monthlyNode is! Map) {
        _monthlyKwh = 0;
        _monthlyCostPhp = 0;
        return;
      }

      final monthlyMap = Map<String, dynamic>.from(monthlyNode);
      final monthNode = monthlyMap[monthKey];
      if (monthNode is! Map) {
        _monthlyKwh = 0;
        _monthlyCostPhp = 0;
        return;
      }

      final monthMap = Map<String, dynamic>.from(monthNode);
      final totalKwh = monthMap['total_kwh'] ?? 0.0;
      final totalCost = monthMap['total_cost'] ?? 0.0;

      _monthlyKwh = (totalKwh is num) ? totalKwh.toDouble() : 0.0;
      _monthlyCostPhp = (totalCost is num) ? totalCost.toDouble() : 0.0;
    } catch (e) {
      _monthlyKwh = 0;
      _monthlyCostPhp = 0;
    }
  }

  void _setAnalyticsRange(String range) {
    // Re-parse from the already-cached `history` root instead of touching
    // Firebase again -- avoids a spurious re-subscription for a value we
    // already have.
    setState(() {
      _analyticsRange = range;
      _historyData = _parseAnalyticsEntries(_historyRoot, range);
    });
  }

  Map<String, dynamic> _pickRangeNode(
      Map<String, dynamic> root, String targetRange) {
    final direct = root[targetRange];
    if (direct is Map) {
      final directMap = Map<String, dynamic>.from(direct);
      if (_matchingKeyCount(directMap, targetRange) > 0) return directMap;
    }

    final keys = ['daily', 'weekly', 'monthly', 'yearly'];
    String bestKey = targetRange;
    int bestScore = -1;

    for (final k in keys) {
      final node = root[k];
      if (node is! Map) continue;
      final map = Map<String, dynamic>.from(node);
      final score = _matchingKeyCount(map, targetRange);
      if (score > bestScore) {
        bestScore = score;
        bestKey = k;
      }
    }

    final best = root[bestKey];
    return best is Map ? Map<String, dynamic>.from(best) : <String, dynamic>{};
  }

  List<Map<String, dynamic>> _parseAnalyticsEntries(
      Map<String, dynamic> root, String rangeKey) {
    final data = _pickRangeNode(root, rangeKey);
    final list = <Map<String, dynamic>>[];

    data.forEach((key, val) {
      if (val is! Map) return;
      final entry = Map<String, dynamic>.from(val);
      list.add({
        'label': key,
        'kwh': (entry['total_kwh'] ?? 0.0) as num,
        'cost': (entry['total_cost'] ?? 0.0) as num,
      });
    });

    if (list.isNotEmpty) {
      list.sort((a, b) => a['label'].compareTo(b['label']));
      return list;
    }

    final rawRoot = root['raw'];
    if (rawRoot is! Map) return list;

    final grouped = <String, Map<String, dynamic>>{};
    final rawMap = Map<String, dynamic>.from(rawRoot);

    rawMap.forEach((key, val) {
      if (val is! Map) return;
      final entry = Map<String, dynamic>.from(val);
      final timestamp = _analyticsRawTimestamp(entry, key.toString());
      if (timestamp == null) return;

      final label = _analyticsRangeLabel(timestamp, rangeKey);
      final kwh = _asDouble(entry['kwh']);
      final cost = _asDouble(entry['cost']);

      final bucket = grouped.putIfAbsent(
          label,
          () => {
                'label': label,
                'kwh': 0.0,
                'cost': 0.0,
              });
      bucket['kwh'] = (bucket['kwh'] as double) + kwh;
      bucket['cost'] = (bucket['cost'] as double) + cost;
    });

    final groupedList = grouped.values.toList()
      ..sort((a, b) => a['label'].compareTo(b['label']));
    return groupedList;
  }

  DateTime? _analyticsRawTimestamp(
      Map<String, dynamic> entry, String fallbackKey) {
    final rawTs = entry['ts'] ?? entry['last_update'] ?? entry['timestamp'];
    if (rawTs is num) {
      return DateTime.fromMillisecondsSinceEpoch(rawTs.toInt());
    }
    if (rawTs is String) {
      final asInt = int.tryParse(rawTs);
      if (asInt != null) {
        return DateTime.fromMillisecondsSinceEpoch(asInt);
      }
      return DateTime.tryParse(rawTs);
    }

    final prefix = fallbackKey.contains('_')
        ? fallbackKey.substring(0, fallbackKey.indexOf('_'))
        : fallbackKey;
    final keyTs = int.tryParse(prefix);
    if (keyTs != null) {
      return DateTime.fromMillisecondsSinceEpoch(keyTs);
    }
    return null;
  }

  String _analyticsRangeLabel(DateTime timestamp, String rangeKey) {
    switch (rangeKey) {
      case 'daily':
        return '${timestamp.year}-${_pad(timestamp.month)}-${_pad(timestamp.day)}';
      case 'weekly':
        return '${timestamp.year}-W${_pad(_isoWeek(timestamp))}';
      case 'monthly':
        return '${timestamp.year}-${_pad(timestamp.month)}';
      case 'yearly':
        return '${timestamp.year}';
      default:
        return '${timestamp.year}-${_pad(timestamp.month)}-${_pad(timestamp.day)}';
    }
  }

  double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  int _isoWeek(DateTime date) {
    final startOfYear = DateTime(date.year, 1, 1);
    final firstMonday = startOfYear.weekday;
    final dayOfYear = date.difference(startOfYear).inDays + 1;
    final weekNumber = ((dayOfYear + firstMonday - 2) / 7).ceil();
    return weekNumber < 1 ? 1 : weekNumber;
  }

  int _matchingKeyCount(Map<String, dynamic> node, String range) {
    int count = 0;
    for (final k in node.keys) {
      if (_isExpectedKeyForRange(k, range)) count++;
    }
    return count;
  }

  bool _isExpectedKeyForRange(String key, String range) {
    switch (range) {
      case 'daily':
        return RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(key);
      case 'weekly':
        return RegExp(r'^\d{4}-W\d{2}$').hasMatch(key);
      case 'monthly':
        return RegExp(r'^\d{4}-\d{2}$').hasMatch(key);
      case 'yearly':
        return RegExp(r'^\d{4}$').hasMatch(key);
      default:
        return false;
    }
  }

  /// History data for the chart, backfilled with realistic-looking
  /// placeholder rows while the first load is still in flight so the
  /// skeleton shimmer has something to draw bones over.
  List<Map<String, dynamic>> get _historyDisplay =>
      _historyData.isEmpty && _isLoading
          ? placeholderHistoryList()
          : _historyData;

  double get _maxKwh => _historyDisplay.isEmpty
      ? 1
      : _historyDisplay.fold(
          0.0,
          (m, d) => (d['kwh'] as num).toDouble() > m
              ? (d['kwh'] as num).toDouble()
              : m);

  Future<void> _logout() async {
    await _cancelRealtimeSubs();
    await AutomationSchedulerService.stop();
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/login');
  }

  String _capitalizeFirst(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();

  String _safeFormatDouble(dynamic value, int decimals) {
    if (value == null) return '0.${'0' * decimals}';
    if (value is double) return value.toStringAsFixed(decimals);
    if (value is int) return value.toDouble().toStringAsFixed(decimals);
    if (value is num) {
      return (value).toDouble().toStringAsFixed(decimals);
    }
    return '0.${'0' * decimals}';
  }

  String _pad(int value) => value.toString().padLeft(2, '0');

  String _monthKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}';

  String _energyLevel(String code) {
    final kwh = _buildingEnergy[code] ?? 0;
    if (kwh > 100) return 'HIGH';
    if (kwh > 50) return 'MID';
    return 'LOW';
  }

  Color _energyColor(String code) {
    switch (_energyLevel(code)) {
      case 'HIGH':
        return const Color(0xFFD64A4A);
      case 'MID':
        return const Color(0xFFE8922A);
      default:
        // Semantic: 3-tier severity indicator (HIGH=red/MID=orange/
        // LOW=green), not brand chrome -- deliberately NOT retheme'd per
        // the institute-theming rollout heuristic.
        return AppColors.greenMid;
    }
  }

  // ── Add Building ─────────────────────────────────────────────────────────
  Future<void> _addBuilding() async {
    final codeCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final floorCtrl = TextEditingController(text: '1');
    String? error;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text(
            'Add Building',
            style: TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: codeCtrl,
                textCapitalization: TextCapitalization.characters,
                decoration: _inputDeco('Building Code (e.g. IC)', Icons.tag),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameCtrl,
                decoration: _inputDeco('Building Name', Icons.business),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: floorCtrl,
                keyboardType: TextInputType.number,
                decoration: _inputDeco('Building Floors', Icons.layers),
              ),
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(
                  error!,
                  style: const TextStyle(fontSize: 12, color: AppColors.error),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'Cancel',
                style: TextStyle(color: AppColors.textMuted),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _palette.dark,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () async {
                final code = codeCtrl.text.trim().toUpperCase();
                final name = nameCtrl.text.trim();
                final floors = int.tryParse(floorCtrl.text.trim()) ?? 1;

                if (code.isEmpty) {
                  setS(() => error = 'Code is required');
                  return;
                }
                if (name.isEmpty) {
                  setS(() => error = 'Name is required');
                  return;
                }

                try {
                  await FirebaseDatabase.instance.ref('buildings/$code').set({
                    'name': name,
                    'floors': floors,
                  });
                  if (!mounted || !ctx.mounted) return;
                  Navigator.pop(ctx);
                  TopToast.show(context, '$code added.');
                } catch (e) {
                  setS(() => error = 'Failed: $e');
                }
              },
              child: const Text(
                'Add',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editBuildingName(Map<String, dynamic> building) async {
    final code = building['code'] as String;
    final currentName = (building['name'] ?? code).toString();
    final nameCtrl = TextEditingController(text: currentName);
    String? error;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Edit Building Name',
              style:
                  TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Code: $code',
                  style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textMuted,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              TextField(
                controller: nameCtrl,
                decoration: _inputDeco('Building Name', Icons.business),
                autofocus: true,
              ),
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(error!,
                    style:
                        const TextStyle(fontSize: 12, color: AppColors.error)),
              ],
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel',
                    style: TextStyle(color: AppColors.textMuted))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: _palette.dark,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              onPressed: () async {
                final newName = nameCtrl.text.trim();
                if (newName.isEmpty) {
                  setS(() => error = 'Name is required');
                  return;
                }
                if (newName == currentName) {
                  if (!ctx.mounted) return;
                  Navigator.pop(ctx);
                  return;
                }

                try {
                  await FirebaseDatabase.instance
                      .ref('buildings/$code/name')
                      .set(newName);
                  if (!mounted || !ctx.mounted) return;
                  Navigator.pop(ctx);
                  TopToast.show(context, '$code renamed.');
                } catch (e) {
                  setS(() => error = 'Failed: $e');
                }
              },
              child: const Text('Save', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  // ── Delete Building ───────────────────────────────────────────────────────
  Future<void> _deleteBuilding(Map<String, dynamic> building) async {
    final code = building['code'] as String;

    final assignedDeviceIds = <String>{};

    final devicesSnap = await FirebaseDatabase.instance.ref('devices').get();
    if (devicesSnap.value is Map) {
      final devices = Map<String, dynamic>.from(devicesSnap.value as Map);
      devices.forEach((id, val) {
        if (val is! Map) return;
        final device = Map<String, dynamic>.from(val);
        final buildingCode = (device['building'] ?? '').toString();
        if (buildingCode == code) {
          assignedDeviceIds.add(id.toString());
        }
      });
    }

    final masterSnap =
        await FirebaseDatabase.instance.ref('master_devices').get();
    if (masterSnap.value is Map) {
      final masters = Map<String, dynamic>.from(masterSnap.value as Map);
      masters.forEach((id, val) {
        if (val is! Map) return;
        final master = Map<String, dynamic>.from(val);
        final assignedTo = (master['assignedTo'] ?? '').toString();
        if (assignedTo.startsWith('$code/')) {
          assignedDeviceIds.add(id.toString());
        }
      });
    }

    final assignedCount = assignedDeviceIds.length;
    final warning = assignedCount > 0
        ? 'This building has $assignedCount assigned device${assignedCount == 1 ? '' : 's'}. Deleting will unassign them from rooms.'
        : 'This will also remove its hotspot from the map.';

    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Building',
            style:
                TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Delete "$code"?'),
            const SizedBox(height: 8),
            Text(
              warning,
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel',
                  style: TextStyle(color: AppColors.textMuted))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final updates = <String, dynamic>{
      'buildings/$code': null,
      'hotspots/$code': null,
    };

    for (final deviceId in assignedDeviceIds) {
      updates['master_devices/$deviceId/assignedTo'] = '';
      updates['devices/$deviceId/building'] = '';
      updates['devices/$deviceId/floor'] = '';
      updates['devices/$deviceId/room'] = '';
      updates['devices/$deviceId/status'] = 'offline';
    }

    await FirebaseDatabase.instance.ref().update(updates);

    if (!mounted) return;
    TopToast.show(
      context,
      assignedCount > 0
          ? '$code removed. $assignedCount device${assignedCount == 1 ? '' : 's'} unassigned.'
          : '$code removed.',
    );
  }

  // ── Manage Buildings Sheet ────────────────────────────────────────────────
  void _showManageBuildings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.55,
          maxChildSize: 0.85,
          builder: (_, ctrl) => Column(children: [
            Container(
              margin: const EdgeInsets.only(top: 10),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(children: [
                const Text('Manage Buildings',
                    style: TextStyle(
                        fontFamily: 'Outfit',
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textDark)),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await _addBuilding();
                  },
                  icon: const Icon(Icons.add, size: 16, color: Colors.white),
                  label: const Text('Add',
                      style: TextStyle(color: Colors.white, fontSize: 12)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _palette.dark,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: _buildings.isEmpty
                  ? const Center(
                      child: Text('No buildings found.',
                          style: TextStyle(
                              fontSize: 13, color: AppColors.textMuted)))
                  : ListView.builder(
                      controller: ctrl,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      itemCount: _buildings.length,
                      itemBuilder: (_, i) {
                        final b = _buildings[i];
                        final code = b['code'] as String;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.cardBg,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                                color: _palette.mid.withAlpha(31)),
                          ),
                          child: Row(children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                  color: _palette.pale,
                                  borderRadius: BorderRadius.circular(10)),
                              child: Center(
                                  child: Text(code,
                                      style: TextStyle(
                                          fontFamily: 'Outfit',
                                          fontSize: 9,
                                          fontWeight: FontWeight.w700,
                                          color: _palette.dark))),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  Text(b['name'],
                                      style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.textDark)),
                                  Text(
                                      '${b['floors']} ${b['floors'] == 1 ? 'floor' : 'floors'}',
                                      style: const TextStyle(
                                          fontSize: 11,
                                          color: AppColors.textMuted)),
                                ])),
                            Row(mainAxisSize: MainAxisSize.min, children: [
                              GestureDetector(
                                onTap: () async {
                                  Navigator.pop(ctx);
                                  await _editBuildingName(b);
                                },
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: _palette.pale,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Icon(Icons.edit_outlined,
                                      size: 18, color: _palette.dark),
                                ),
                              ),
                              const SizedBox(width: 6),
                              GestureDetector(
                                onTap: () async {
                                  Navigator.pop(ctx);
                                  await _deleteBuilding(b);
                                },
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: AppColors.error.withAlpha(15),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(Icons.delete_outline,
                                      size: 18, color: AppColors.error),
                                ),
                              ),
                            ]),
                          ]),
                        );
                      },
                    ),
            ),
          ]),
        ),
      ),
    );
  }

  InputDecoration _inputDeco(String hint, IconData icon) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 13),
      prefixIcon: Icon(icon, size: 18, color: AppColors.textMuted),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _palette.mid.withAlpha(51))),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _palette.mid.withAlpha(51))),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _palette.mid)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showAnalytics = !_isInstituteAdmin;
    final safeIndex =
        (!showAnalytics && _selectedIndex == 2) ? 0 : _selectedIndex;

    // Local theme override carrying the resolved InstituteTheme extension,
    // so any genuine descendant widget (its own BuildContext, below this
    // point in the tree) can read `context.institutePalette`. This State's
    // own `_palette` getter does not rely on this -- see its doc comment.
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(_role, _institute)],
      ),
      child: Scaffold(
        backgroundColor: AppColors.surface,
        body: SafeArea(
          child: Column(children: [
            _buildTopBar(),
            Expanded(
              child: IndexedStack(
                index: safeIndex,
                children: [
                  _isInstituteAdmin
                      ? _buildInstituteHomeTab()
                      : (_errorText != null
                          ? _buildError()
                          : ScreenSkeleton(
                              isLoading: _isLoading, child: _buildHomeTab())),
                  CampusMapScreen(role: _role, showAppBar: false),
                  _errorText != null
                      ? _buildError()
                      : ScreenSkeleton(
                          isLoading: _isLoading, child: _buildAnalyticsTab()),
                  AutomationScreen(role: _role),
                ],
              ),
            ),
          ]),
        ),
        bottomNavigationBar: _buildBottomNav(showAnalytics: showAnalytics),
      ),
    );
  }

  /// An institute admin's "Dashboard" tab: their institute's rooms directly,
  /// themed to their institute's color — no campus-wide buildings list.
  Widget _buildInstituteHomeTab() {
    final code = _institute ?? '';
    if (code.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(40.0),
          child: Text(
            'Your account has no institute assigned yet.\nAsk your main admin to assign one.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textMuted),
          ),
        ),
      );
    }
    final match = _buildings.firstWhere(
      (b) => (b['code'] ?? '').toString() == code,
      orElse: () => <String, dynamic>{},
    );
    final floors = (match['floors'] as int?) ?? 1;
    final name = (match['name'] as String?) ?? code;
    return Column(children: [
      _buildInstituteEnergyCard(),
      Expanded(
        child: BuildingFloorScreen(
          key: ValueKey('dash-institute-$code'),
          buildingCode: code,
          buildingName: name,
          floors: floors,
          role: _role,
          showBackButton: false,
        ),
      ),
    ]);
  }

  /// Institute-scoped summary card shown above the floor/room picker on an
  /// institute_admin's home tab. Visually mirrors `_buildEnergyCards()` (the
  /// main-admin equivalent) but every number is filtered to `_institute`
  /// only -- see `_listenInstituteScoped()`. Branded with `_palette` instead
  /// of the hardcoded main-admin green.
  Widget _buildInstituteEnergyCard() {
    final monthlyCost = _instituteMonthlyKwh * _electricityRate;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
            colors: [_palette.dark, _palette.mid],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
              color: _palette.dark.withAlpha(77),
              blurRadius: 20,
              offset: const Offset(0, 8))
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Energy consumed today',
            style: TextStyle(fontSize: 12, color: Colors.white)),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(_safeFormatDouble(_instituteKwh, 2),
              style: const TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 40,
                  fontWeight: FontWeight.w700,
                  color: Colors.white)),
          const Padding(
              padding: EdgeInsets.only(bottom: 6, left: 6),
              child: Text('kWh',
                  style: TextStyle(
                      fontSize: 14,
                      color: Colors.white,
                      fontWeight: FontWeight.w500))),
        ]),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: Colors.white.withAlpha(15),
              borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            _miniStat(
                'Month Cost', '₱ ${_safeFormatDouble(monthlyCost, 0)}'),
            _vertDivider(),
            _miniStat('Assigned', '$_instituteAssignedDevices devices'),
            _vertDivider(),
            _miniStat('Online', '$_instituteOnlineDevices devices'),
          ]),
        ),
      ]),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                  color: _palette.pale,
                  borderRadius: BorderRadius.circular(20)),
              child: Icon(Icons.wifi_off_rounded,
                  size: 34, color: _palette.mid)),
          const SizedBox(height: 16),
          const Text('Cannot load dashboard',
              style: TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark)),
          const SizedBox(height: 8),
          Text(_errorText ?? 'Something went wrong.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppColors.textMuted)),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _retryLoad,
            icon: const Icon(Icons.refresh, size: 16, color: Colors.white),
            label:
                const Text('Retry', style: TextStyle(color: Colors.white)),
            style: ElevatedButton.styleFrom(
                backgroundColor: _palette.dark,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
          ),
        ]),
      ),
    );
  }

  /// The top-bar role badge, 3-way branched on `_isSuperAdmin` /
  /// `_isInstituteAdmin` (not the raw `_role` string -- that only matched
  /// the literal `'admin'`, mislabeling `main_admin`/`super_admin` and
  /// `institute_admin` accounts as "Faculty"). Institute admins get their
  /// own label/icon, styled off `_palette` to stay institute-branded.
  Widget _roleBadge() {
    final IconData icon;
    final String label;
    final Color color;
    final bool highlighted;
    if (_isSuperAdmin) {
      icon = Icons.star;
      label = 'Admin';
      // _palette always resolves to the green admin ramp for this role
      // (see InstituteTheme.resolve), so this is equivalent to the old
      // hardcoded AppColors.greenLight but routes through the single
      // resolver instead of duplicating the literal.
      color = _palette.light;
      highlighted = true;
    } else if (_isInstituteAdmin) {
      icon = Icons.school;
      label = 'Institute Admin';
      color = _palette.light;
      highlighted = true;
    } else {
      icon = Icons.person;
      label = 'Faculty';
      color = Colors.white;
      highlighted = false;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: highlighted ? color.withAlpha(51) : Colors.white.withAlpha(26),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: highlighted
                ? color.withAlpha(102)
                : Colors.white.withAlpha(51)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 11, color: color),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600, color: color)),
      ]),
    );
  }

  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      decoration: BoxDecoration(
        color: _palette.dark,
      ),
      child: Row(children: [
            Container(
              width: 34,
              height: 34,
              padding: const EdgeInsets.all(4),
              child: Image.asset(
                'promo/img/logo.png',
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text('Smart Switch',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: 'Outfit',
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white)),
            ),
            // Always the compact burger menu (not just under the old 430px
            // breakpoint) -- one menu button reading Notifications/Manage
            // Users/Settings/Logout is cleaner than 4 separate icons, and
            // the unread-notification badge still shows as an overlay dot
            // on the menu icon itself (see below).
            _roleBadge(),
            PopupMenuButton<String>(
                // Bug fix: this hardcoded the main-admin green (both the
                // menu surface and its border) instead of following
                // `_palette`, so an institute_admin viewing e.g. IC
                // (violet) got a top bar that went violet everywhere
                // except this popup, which silently stayed green.
                color: _palette.dark,
                surfaceTintColor: Colors.transparent,
                elevation: 12,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: _palette.light.withAlpha(140))),
                onOpened: () {
                  if (mounted) setState(() => _compactMenuOpen = true);
                },
                icon: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOut,
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: _compactMenuOpen
                            ? _palette.light.withAlpha(46)
                            : Colors.white.withAlpha(20),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white.withAlpha(60)),
                      ),
                      child: AnimatedRotation(
                        turns: _compactMenuOpen ? 0.125 : 0,
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut,
                        child: Icon(
                            _compactMenuOpen
                                ? Icons.close_rounded
                                : Icons.menu_rounded,
                            color: Colors.white,
                            size: 20),
                      ),
                    ),
                    if (_unreadNotificationCount > 0)
                      Positioned(
                        right: -4,
                        top: -4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          constraints: const BoxConstraints(minWidth: 16),
                          decoration: BoxDecoration(
                            color: AppColors.warning,
                            borderRadius: BorderRadius.circular(99),
                            // This border exists only to mask the badge's
                            // corner against the top bar behind it, so it
                            // must match the top bar's own background
                            // (_palette.dark, set in _buildTopBar) rather
                            // than a hardcoded green -- else a visible
                            // green ring shows through on non-green
                            // institutes.
                            border:
                                Border.all(color: _palette.dark, width: 1.2),
                          ),
                          child: Text(
                            _unreadNotificationCount > 99
                                ? '99+'
                                : _unreadNotificationCount.toString(),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                onCanceled: () {
                  if (mounted) setState(() => _compactMenuOpen = false);
                },
                onSelected: (value) {
                  if (mounted) setState(() => _compactMenuOpen = false);
                  if (value == 'notifications') {
                    unawaited(_openNotifications());
                  } else if (value == 'manage-users') {
                    Navigator.pushNamed(context, '/manage-users', arguments: {
                      'role': _role,
                      'institute': _institute,
                    });
                  } else if (value == 'settings') {
                    Navigator.pushNamed(context, '/settings');
                  } else if (value == 'logout') {
                    _logout();
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem<String>(
                      value: 'notifications',
                      child: Row(children: [
                        Icon(Icons.notifications_outlined,
                            size: 18, color: Colors.white),
                        SizedBox(width: 10),
                        Text('Notifications',
                            style: TextStyle(color: Colors.white))
                      ])),
                  if (_canAccessManagement)
                    const PopupMenuItem<String>(
                        value: 'manage-users',
                        child: Row(children: [
                          Icon(Icons.admin_panel_settings_outlined,
                              size: 18, color: Colors.white),
                          SizedBox(width: 10),
                          Text('Manage Users',
                              style: TextStyle(color: Colors.white))
                        ])),
                  if (_canAccessManagement)
                    const PopupMenuItem<String>(
                        value: 'settings',
                        child: Row(children: [
                          Icon(Icons.settings_outlined,
                              size: 18, color: Colors.white),
                          SizedBox(width: 10),
                          Text('Settings',
                              style: TextStyle(color: Colors.white))
                        ])),
                  const PopupMenuItem<String>(
                      value: 'logout',
                      child: Row(children: [
                        Icon(Icons.logout, size: 18, color: Colors.white),
                        SizedBox(width: 10),
                        Text('Logout', style: TextStyle(color: Colors.white))
                      ])),
                ],
              ),
          ]),
    );
  }

  Widget _buildHomeTab() {
    final buildingsSource =
        _buildings.isEmpty && _isLoading ? placeholderBuildingList() : _buildings;
    final sortedBuildings = [...buildingsSource]..sort((a, b) {
        final aCode = (a['code'] as String?) ?? '';
        final bCode = (b['code'] as String?) ?? '';
        final aKwh = _buildingEnergy[aCode] ?? 0;
        final bKwh = _buildingEnergy[bCode] ?? 0;
        final byKwh = bKwh.compareTo(aKwh);
        if (byKwh != 0) return byKwh;
        return aCode.compareTo(bCode);
      });

    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 380;

        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            isCompact ? 16 : 20,
            isCompact ? 16 : 20,
            isCompact ? 16 : 20,
            isCompact ? 18 : 20,
          ),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _buildGreeting(compact: isCompact),
            SizedBox(height: isCompact ? 14 : 20),
            _buildEnergyCards(compact: isCompact),
            SizedBox(height: isCompact ? 18 : 24),
            // ── Buildings header with edit action ──────────────
            Row(children: [
              const Expanded(
                child: Text('Campus Buildings',
                    style: TextStyle(
                        fontFamily: 'Outfit',
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textDark)),
              ),
              const SizedBox(width: 6),
              if (_role == 'admin')
                GestureDetector(
                  onTap: _showManageBuildings,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: _palette.pale,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.edit_outlined,
                            size: 14, color: _palette.dark),
                        const SizedBox(width: 4),
                        Text(
                          'Edit',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: _palette.dark,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              Text('${buildingsSource.length} buildings',
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textMuted)),
            ]),
            SizedBox(height: isCompact ? 10 : 12),
            if (buildingsSource.isEmpty)
              Container(
                padding: EdgeInsets.all(isCompact ? 16 : 20),
                decoration: BoxDecoration(
                  color: AppColors.cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _palette.mid.withAlpha(31)),
                ),
                child: Center(
                  child: Column(children: [
                    const Icon(Icons.business_outlined,
                        size: 32, color: AppColors.textMuted),
                    const SizedBox(height: 8),
                    const Text('No buildings yet',
                        style: TextStyle(
                            fontSize: 13, color: AppColors.textMuted)),
                    if (_role == 'admin') ...[
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: _addBuilding,
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add Building'),
                        style: TextButton.styleFrom(
                            foregroundColor: _palette.dark),
                      ),
                    ],
                  ]),
                ),
              )
            else
              ...sortedBuildings.map((building) => _buildBuildingCard(
                    building,
                    compact: isCompact,
                  )),
          ]),
        );
      },
    );
  }

  Widget _buildGreeting({bool compact = false}) {
    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? 'Good morning'
        : hour < 17
            ? 'Good afternoon'
            : 'Good evening';
    return Row(children: [
      Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(greeting,
            style: TextStyle(
                fontSize: compact ? 12 : 13, color: AppColors.textMuted)),
        Row(children: [
          Text(_userName.isNotEmpty ? _userName : 'User',
              style: TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: compact ? 19 : 22,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textDark)),
          if (_role == 'admin') ...[
            const SizedBox(width: 8),
            Icon(Icons.star,
                size: compact ? 18 : 22, color: _palette.light),
          ],
        ]),
      ])),
      Container(
        padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 10, vertical: compact ? 5 : 6),
        decoration: BoxDecoration(
            color: _palette.pale,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _palette.mid.withAlpha(60))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 7,
              height: 7,
              decoration:
                  BoxDecoration(color: _palette.mid, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text('Live',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: _palette.dark)),
        ]),
      ),
    ]);
  }

  Widget _buildEnergyCards({bool compact = false}) {
    return Column(children: [
      Container(
        width: double.infinity,
        padding: EdgeInsets.all(compact ? 16 : 20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
              colors: [_palette.dark, _palette.mid],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
                color: _palette.dark.withAlpha(77),
                blurRadius: 20,
                offset: const Offset(0, 8))
          ],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Energy consumed today',
              style: TextStyle(
                  fontSize: compact ? 11 : 12, color: Colors.white)),
          SizedBox(height: compact ? 4 : 6),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(_safeFormatDouble(_totalKwh, 2),
                style: TextStyle(
                    fontFamily: 'Outfit',
                    fontSize: compact ? 32 : 40,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
            Padding(
                padding: EdgeInsets.only(bottom: compact ? 4 : 6, left: 6),
                child: Text('kWh',
                    style: TextStyle(
                        fontSize: compact ? 13 : 14,
                        color: Colors.white,
                        fontWeight: FontWeight.w500))),
          ]),
          SizedBox(height: compact ? 12 : 16),
          Container(
            padding: EdgeInsets.all(compact ? 10 : 12),
            decoration: BoxDecoration(
                color: Colors.white.withAlpha(15),
                borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              _miniStat(
                  'Month Cost', '₱ ${_safeFormatDouble(_monthlyCostPhp, 0)}',
                  compact: compact),
              _vertDivider(),
              _miniStat('Assigned', '$_assignedDevices devices',
                  compact: compact),
              _vertDivider(),
              _miniStat('Unassigned', '$_unassignedDevices devices',
                  compact: compact),
            ]),
          ),
        ]),
      ),
    ]);
  }

  Widget _vertDivider() => Container(
      width: 1,
      height: 28,
      margin: const EdgeInsets.symmetric(horizontal: 10),
      color: Colors.white.withAlpha(30));

  Widget _miniStat(String label, String value, {bool compact = false}) {
    return Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: TextStyle(fontSize: compact ? 9 : 10, color: Colors.white)),
      const SizedBox(height: 2),
      Text(value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: compact ? 11 : 12,
              fontWeight: FontWeight.w600,
              color: Colors.white)),
    ]));
  }

  Widget _buildBuildingCard(Map<String, dynamic> building,
      {bool compact = false}) {
    final code = building['code'] as String;
    final level = _energyLevel(code);
    final color = _energyColor(code);
    final devices = _buildingDeviceCounts[code] ?? 0;
    return GestureDetector(
      onTap: () => Navigator.pushNamed(context, '/building', arguments: {
        'buildingCode': code,
        'buildingName': building['name'],
        'floors': building['floors'],
        'role': _role,
      }),
      child: Container(
        margin: EdgeInsets.only(bottom: compact ? 8 : 10),
        padding: EdgeInsets.all(compact ? 12 : 14),
        decoration: BoxDecoration(
            color: AppColors.cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _palette.mid.withAlpha(31))),
        child: Row(children: [
          Container(
              width: compact ? 40 : 44,
              height: compact ? 40 : 44,
              decoration: BoxDecoration(
                  color: _palette.pale,
                  borderRadius: BorderRadius.circular(12)),
              child: Center(
                  child: Text(code,
                      style: TextStyle(
                          fontFamily: 'Outfit',
                          fontSize: compact ? 9 : 10,
                          fontWeight: FontWeight.w700,
                          color: _palette.dark)))),
          SizedBox(width: compact ? 10 : 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(building['name'],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: compact ? 12 : 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textDark)),
                const SizedBox(height: 2),
                Text(
                    '${building['floors']} ${building['floors'] == 1 ? 'floor' : 'floors'} · $devices devices',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: compact ? 10 : 11,
                        color: AppColors.textMuted)),
              ])),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(
                '${_safeFormatDouble(_buildingEnergy[code] ?? 0, 1)} kWh this month',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    TextStyle(fontSize: compact ? 9 : 10, color: Colors.black)),
            const SizedBox(height: 3),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: color.withAlpha(26),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: color.withAlpha(77))),
              child: Text(level,
                  style: TextStyle(
                      fontSize: compact ? 9 : 10,
                      fontWeight: FontWeight.w700,
                      color: color)),
            ),
          ]),
          const SizedBox(width: 6),
          const Icon(Icons.chevron_right, color: AppColors.textMuted, size: 18),
        ]),
      ),
    );
  }

  Widget _buildAnalyticsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Analytics',
            style: TextStyle(
                fontFamily: 'Outfit',
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: AppColors.textDark)),
        const SizedBox(height: 4),
        const Text('Realtime energy insights',
            style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
        const SizedBox(height: 20),
        _buildRangeSelector(),
        const SizedBox(height: 20),
        _buildLineChart(),
        const SizedBox(height: 16),
        _buildDeviceStatusCard(),
        const SizedBox(height: 16),
        _buildTopUtilityCard(),
        const SizedBox(height: 16),
        _buildTopBuildingCard(),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: OutlinedButton.icon(
            onPressed: () => Navigator.pushNamed(context, '/history'),
            icon: const Icon(Icons.history, size: 18),
            label: const Text('View Full History'),
            style: OutlinedButton.styleFrom(
                foregroundColor: _palette.dark,
                side: BorderSide(color: _palette.mid, width: 1.5),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14))),
          ),
        ),
      ]),
    );
  }

  Widget _buildRangeSelector() {
    final ranges = [
      {'key': 'daily', 'label': 'Daily'},
      {'key': 'weekly', 'label': 'Weekly'},
      {'key': 'monthly', 'label': 'Monthly'},
      {'key': 'yearly', 'label': 'Yearly'},
    ];
    return Container(
      height: 42,
      decoration: BoxDecoration(
          color: _palette.pale, borderRadius: BorderRadius.circular(12)),
      child: Row(
          children: ranges.map((r) {
        final isSelected = _analyticsRange == r['key'];
        return Expanded(
            child: GestureDetector(
          onTap: () => _setAnalyticsRange(r['key']!),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.all(4),
            decoration: BoxDecoration(
                color: isSelected ? _palette.dark : Colors.transparent,
                borderRadius: BorderRadius.circular(8)),
            child: Center(
                child: Text(r['label']!,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isSelected ? Colors.white : _palette.dark))),
          ),
        ));
      }).toList()),
    );
  }

  Widget _buildLineChart() {
    final historyDisplay = _historyDisplay;
    final canSwitchChart = historyDisplay.length > 1;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _palette.mid.withAlpha(26))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text('Consumption Trend',
                    style: TextStyle(
                        fontFamily: 'Outfit',
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textDark)),
                SizedBox(height: 2),
                Text('kWh over time · realtime',
                    style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
              ])),
          if (canSwitchChart) ...[
            _chartTypeButton('line', Icons.show_chart),
            const SizedBox(width: 6),
            _chartTypeButton('bar', Icons.bar_chart),
            const SizedBox(width: 10),
          ],
          Container(
              width: 8,
              height: 8,
              decoration:
                  BoxDecoration(color: _palette.mid, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text('Live',
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: _palette.mid)),
        ]),
        const SizedBox(height: 20),
        historyDisplay.isEmpty
            ? const Center(
                child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Text('No data yet',
                        style: TextStyle(
                            fontSize: 13, color: AppColors.textMuted))))
            : SizedBox(
                height: 160,
                child: CustomPaint(
                    painter: _trendChartType == 'bar'
                        ? BarChartPainter(
                            data: historyDisplay
                                .map((d) => (d['kwh'] as num).toDouble())
                                .toList(),
                            maxKwh: _maxKwh)
                        : LineChartPainter(
                            data: historyDisplay
                                .map((d) => (d['kwh'] as num).toDouble())
                                .toList(),
                            maxKwh: _maxKwh),
                    child: Container())),
        if (historyDisplay.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(historyDisplay.first['label'],
                style:
                    const TextStyle(fontSize: 9, color: AppColors.textMuted)),
            if (historyDisplay.length > 2)
              Text(historyDisplay[historyDisplay.length ~/ 2]['label'],
                  style:
                      const TextStyle(fontSize: 9, color: AppColors.textMuted)),
            Text(historyDisplay.last['label'],
                style:
                    const TextStyle(fontSize: 9, color: AppColors.textMuted)),
          ]),
        ],
      ]),
    );
  }

  Widget _chartTypeButton(String type, IconData icon) {
    final isSelected = _trendChartType == type;
    return GestureDetector(
      onTap: () {
        if (_trendChartType == type) return;
        setState(() => _trendChartType = type);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? _palette.dark : _palette.pale,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: isSelected ? _palette.dark : _palette.mid.withAlpha(80)),
        ),
        child: Icon(
          icon,
          size: 14,
          color: isSelected ? Colors.white : _palette.dark,
        ),
      ),
    );
  }

  Widget _buildDeviceStatusCard() {
    final total = _assignedDevices + _unassignedDevices;
    final assignedPct = total == 0 ? 0.0 : _assignedDevices / total;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _palette.mid.withAlpha(26))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Device Status',
            style: TextStyle(
                fontFamily: 'Outfit',
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textDark)),
        const SizedBox(height: 16),
        // Semantic: Assigned (green) vs Unassigned (AppColors.warning) is a
        // 2-state status pairing in the same widget -- deliberately NOT
        // retheme'd (assignment status, not brand chrome).
        Row(children: [
          Expanded(
              child: _statusBadge('Assigned', _assignedDevices,
                  AppColors.greenMid, Icons.check_circle_outline)),
          const SizedBox(width: 12),
          Expanded(
              child: _statusBadge('Unassigned', _unassignedDevices,
                  AppColors.warning, Icons.device_unknown_outlined)),
        ]),
        const SizedBox(height: 14),
        // Same semantic pairing as above (assigned-fill on a warning-color
        // track) -- NOT retheme'd for the same reason.
        ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
                value: assignedPct,
                minHeight: 8,
                backgroundColor: AppColors.warning.withAlpha(40),
                valueColor:
                    const AlwaysStoppedAnimation<Color>(AppColors.greenMid))),
        const SizedBox(height: 6),
        Text('${_safeFormatDouble(assignedPct * 100, 0)}% devices assigned',
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
      ]),
    );
  }

  Widget _statusBadge(String label, int count, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: color.withAlpha(20),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withAlpha(50))),
      child: Row(children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$count',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: color,
                  fontFamily: 'Outfit')),
          Text(label,
              style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
        ]),
      ]),
    );
  }

  Widget _buildTopUtilityCard() {
    if (_utilityTotals.isEmpty) return const SizedBox();
    final sorted = _utilityTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxVal = sorted.first.value;
    // Categorical legend colors for utility types -- 'Lights' used the
    // brand green as its arbitrary default series color (no semantic
    // meaning vs Outlets/AC), so it's rethemed along with the rest of this
    // screen's brand chrome; Outlets/AC keep their own fixed hues.
    final Map<String, Color> colors = {
      'Lights': _palette.mid,
      'Outlets': const Color(0xFFE8922A),
      'AC': const Color(0xFF2196F3)
    };
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _palette.mid.withAlpha(26))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Top Consuming Utilities',
            style: TextStyle(
                fontFamily: 'Outfit',
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textDark)),
        const SizedBox(height: 16),
        ...sorted.map((e) {
          final pct = maxVal == 0 ? 0.0 : e.value / maxVal;
          final color = colors[e.key] ?? _palette.mid;
          return Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Row(children: [
                              Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                      color: color, shape: BoxShape.circle)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  e.key,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      color: AppColors.textDark),
                                ),
                              ),
                            ]),
                          ),
                          const SizedBox(width: 8),
                          Text('${_safeFormatDouble(e.value, 1)} kWh',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: _palette.dark)),
                        ]),
                    const SizedBox(height: 6),
                    ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                            value: pct,
                            minHeight: 7,
                            backgroundColor: color.withAlpha(25),
                            valueColor: AlwaysStoppedAnimation<Color>(color))),
                  ]));
        }),
      ]),
    );
  }

  Widget _buildTopBuildingCard() {
    if (_buildingEnergy.isEmpty) return const SizedBox();
    final sorted = _buildingEnergy.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxVal = sorted.first.value;
    // Ordinal rank-cycling colors for the bars (rank 1/2/3 reuse the brand
    // ramp's dark/mid/light tiers purely for visual variety, not tied to
    // any specific real institute's identity) -- rethemed like the rest of
    // this screen's chrome; the blue/orange entries keep their fixed hues.
    final List<Color> barColors = [
      _palette.dark,
      _palette.mid,
      _palette.light,
      const Color(0xFF2196F3),
      const Color(0xFFE8922A)
    ];
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _palette.mid.withAlpha(26))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Top Consuming Institutes This Month',
            style: TextStyle(
                fontFamily: 'Outfit',
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textDark)),
        const SizedBox(height: 16),
        ...sorted.asMap().entries.map((entry) {
          final i = entry.key;
          final e = entry.value;
          final pct = maxVal == 0 ? 0.0 : e.value / maxVal;
          final color = barColors[i % barColors.length];
          return Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(children: [
                Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                        color: i == 0 ? _palette.dark : _palette.pale,
                        shape: BoxShape.circle),
                    child: Center(
                        child: Text('${i + 1}',
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: i == 0 ? Colors.white : _palette.dark)))),
                const SizedBox(width: 10),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(e.key,
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: AppColors.textDark)),
                            Text('${_safeFormatDouble(e.value, 1)} kWh',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: _palette.dark)),
                          ]),
                      const SizedBox(height: 5),
                      ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                              value: pct,
                              minHeight: 7,
                              backgroundColor: color.withAlpha(25),
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(color))),
                    ])),
              ]));
        }),
      ]),
    );
  }

  Widget _buildBottomNav({required bool showAnalytics}) {
    // The IndexedStack keeps fixed conceptual slots (0 Dashboard, 1 Map,
    // 2 Analytics, 3 Automation); this just hides the Analytics slot from
    // the nav bar and remaps taps to the slot they actually mean.
    final tabIndices = <int>[0, 1, if (showAnalytics) 2, 3];
    final navSlot = tabIndices.indexOf(_selectedIndex);
    final currentNavSlot = navSlot < 0 ? 0 : navSlot;

    return Container(
      decoration: BoxDecoration(color: Colors.white, boxShadow: [
        BoxShadow(
            color: Colors.black.withAlpha(15),
            blurRadius: 16,
            offset: const Offset(0, -4))
      ]),
      child: BottomNavigationBar(
        currentIndex: currentNavSlot,
        onTap: (slot) => setState(() => _selectedIndex = tabIndices[slot]),
        backgroundColor: Colors.white,
        selectedItemColor: _palette.dark,
        unselectedItemColor: AppColors.textMuted,
        selectedLabelStyle:
            const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 11),
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        items: [
          const BottomNavigationBarItem(
              icon: Icon(Icons.dashboard_outlined),
              activeIcon: Icon(Icons.dashboard),
              label: 'Dashboard'),
          const BottomNavigationBarItem(
              icon: Icon(Icons.map_outlined),
              activeIcon: Icon(Icons.map),
              label: 'Map'),
          if (showAnalytics)
            const BottomNavigationBarItem(
                icon: Icon(Icons.bar_chart_outlined),
                activeIcon: Icon(Icons.bar_chart),
                label: 'Analytics'),
          const BottomNavigationBarItem(
              icon: Icon(Icons.schedule_outlined),
              activeIcon: Icon(Icons.schedule),
              label: 'Automation'),
        ],
      ),
    );
  }
}

