import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../theme/breakpoints.dart';
import '../../theme/institute_colors.dart';
import '../../utils/last_seen.dart';
import '../../utils/placeholder_data.dart';
import '../../widgets/app_bottom_nav.dart';
import '../../widgets/app_bottom_sheet.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/app_segmented_control.dart';
import '../../widgets/app_top_bar.dart';
import '../../widgets/delete_flow.dart';
import '../../widgets/delete_row_transition.dart';
import '../../widgets/outline_icon_box.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';
import 'automation_screen.dart';
import 'building_floor_screen.dart';
import 'history_screen.dart';
import 'more_screen.dart';
import '../shared/campus_map_screen.dart';
import '../web/history_trend_panel.dart';
import '../../widgets/app_text_field.dart';
import '../../theme/app_fonts.dart';
import '../../services/history_clock.dart';
import '../../services/rate_timeline.dart';
import '../../widgets/history_fallback_notice.dart';

/// One-shot snapshot of what deleting a building would touch, used to build
/// a real (not sample) impact list for its two-step delete dialog.
class _BuildingDeleteImpact {
  const _BuildingDeleteImpact({
    required this.assignedDeviceIds,
    required this.roomCount,
    required this.floorCount,
    required this.scheduleCount,
  });

  final Set<String> assignedDeviceIds;
  final int roomCount;
  final int floorCount;
  final int scheduleCount;
}

/// One room's live load, grouped from the flat `devices` node's `room`
/// field (see `_listenInstituteScoped`). [kwh] is today's live figure, not
/// a "this month" total -- there is no per-room node under `history/` to
/// read a real monthly figure from (only per-device and per-building sums
/// are written, see `history_service.dart`), so the Home tab's "Room load"
/// section is honestly labelled "Today" here rather than showing a
/// fabricated monthly number.
class _RoomLoad {
  const _RoomLoad({
    required this.name,
    required this.floor,
    required this.deviceCount,
    required this.kwh,
  });

  final String name;
  final int floor;
  final int deviceCount;
  final double kwh;
}

/// One tile in the Home tab's 2x2 KPI grid (handoff §4.1/§5).
class _KpiItem {
  const _KpiItem({
    required this.icon,
    required this.label,
    required this.value,
    this.unit,
    this.foot,
    this.footColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? unit;
  final String? foot;
  final Color? footColor;
}

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
  // Hydrated from the user's session; used to derive the top bar avatar's
  // initials (see `_initials`) now that the top bar shows a real avatar
  // (handoff §2/§3.7) instead of the old burger menu.
  String _userName = '';
  bool _roleLoaded = false;

  // ── Devices tab (redesign phase 2: List | Map segmented) ───────────────
  int _devicesViewMode = 0; // 0 = List, 1 = Map
  int _devicesStatusFilter = 0; // 0 All, 1 Online, 2 Offline, 3 Unassigned
  final TextEditingController _deviceSearchCtrl = TextEditingController();
  String _deviceSearchQuery = '';
  final Set<String> _deletingBuildingCodes = {};

  bool get _isSuperAdmin =>
      _role == 'main_admin' || _role == 'admin' || _role == 'super_admin';
  bool get _isInstituteAdmin => _role == 'institute_admin';

  /// Initials for the top bar avatar (mirrors `more_screen.dart`'s own
  /// `_initials`, the screen that avatar tap opens).
  String get _initials {
    final source = _userName.isNotEmpty
        ? _userName
        : (FirebaseAuth.instance.currentUser?.email ?? '');
    if (source.isEmpty) return '?';
    final parts = source.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return (parts[0][0] + parts[1][0]).toUpperCase();
    }
    return source.substring(0, source.length >= 2 ? 2 : 1).toUpperCase();
  }

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
  List<_RoomLoad> _instituteRooms = [];
  StreamSubscription? _instituteSub;
  Map<String, int> _buildingDeviceCounts = {};
  Map<String, double> _buildingEnergy = {};

  // ── Redesign (phase 2) additions: real per-building/per-device signals
  // sourced from the same `devices` snapshot already read in `_listenAll`,
  // kept as separate maps rather than folded into the existing ones above
  // so the pre-existing fields' meaning doesn't shift under older callers.
  int _onlineDevicesCount = 0;
  Map<String, double> _buildingTodayKwh = {}; // code -> today's live kWh
  Map<String, int> _buildingOnlineCounts = {}; // code -> devices seen <2min
  Map<String, int> _buildingOfflineCounts =
      {}; // code -> devices not recently seen
  Map<String, int> _buildingOnCounts = {}; // code -> devices with relay==true

  // Automations, read once here (campus-wide) purely so the institute admin
  // home tab can show a real "Schedules" KPI -- campus admin doesn't use
  // this. Heuristic: a schedule counts toward an institute if its `scope`
  // is 'building' and `target` equals that institute's code. Device-scoped
  // schedules (`scope == 'device'`) are not resolved to a building here
  // (would need a deviceId -> building join); flagged as a known gap.
  int _instituteScheduleCount = 0;
  int _instituteActiveScheduleCount = 0;

  // Raw `history` node cached so per-building/weekly/monthly lookups and
  // `_peakHourLabel` can re-derive their figures locally without
  // re-touching Firebase.
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

  // Reported up by the embedded `AutomationScreen` via its
  // `onSubtitleChanged` callback (see `_buildTopBar`/`_topBarSubtitle`) so
  // the shared shell top bar can show "N of M schedules active" the same
  // way Devices/Analytics already get a subtitle computed here, instead of
  // that text living inside AutomationScreen's own scrollable body.
  String? _automationSubtitle;

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
    _deviceSearchCtrl.dispose();
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
      FirebaseDatabase.instance.ref('automations').onValue,
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
            list.sort(
                (a, b) => (a['code'] as String).compareTo(b['code'] as String));
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

        // ── devices (today's energy totals + per-building signals) ─
        final devicesRaw = events[2].snapshot.value;
        if (devicesRaw is Map) {
          final data = Map<String, dynamic>.from(devicesRaw);
          double totalKwh = 0;
          int onlineCount = 0;
          Map<String, double> buildingTodayKwh = {};
          Map<String, int> buildingOnline = {};
          Map<String, int> buildingOffline = {};
          Map<String, int> buildingOnCounts = {};
          data.forEach((id, val) {
            if (val is! Map) return;
            final device = Map<String, dynamic>.from(val);
            final kwhValue = device['kwh'];
            final kwh = kwhValue is num
                ? kwhValue.toDouble()
                : double.tryParse(kwhValue?.toString() ?? '') ?? 0.0;

            totalKwh += kwh;

            final building = (device['building'] ?? '').toString();
            final lastSeen = device['last_seen'];
            bool isOnline = false;
            if (lastSeen != null && lastSeen != 0) {
              final ms = lastSeen is num
                  ? lastSeen.toInt()
                  : int.tryParse(lastSeen.toString()) ?? 0;
              if (ms > 0) {
                final dt = DateTime.fromMillisecondsSinceEpoch(ms);
                isOnline = DateTime.now().difference(dt).inMinutes < 2;
              }
            }
            if (isOnline) onlineCount++;

            if (building.isNotEmpty) {
              buildingTodayKwh[building] =
                  (buildingTodayKwh[building] ?? 0) + kwh;
              if (isOnline) {
                buildingOnline[building] = (buildingOnline[building] ?? 0) + 1;
              } else {
                buildingOffline[building] =
                    (buildingOffline[building] ?? 0) + 1;
              }
              if (device['relay'] == true) {
                buildingOnCounts[building] =
                    (buildingOnCounts[building] ?? 0) + 1;
              }
            }
          });
          _totalKwh = totalKwh;
          _onlineDevicesCount = onlineCount;
          _buildingTodayKwh = buildingTodayKwh;
          _buildingOnlineCounts = buildingOnline;
          _buildingOfflineCounts = buildingOffline;
          _buildingOnCounts = buildingOnCounts;
        } else if (_isLoading) {
          _totalKwh = 0;
          _onlineDevicesCount = 0;
          _buildingTodayKwh = {};
          _buildingOnlineCounts = {};
          _buildingOfflineCounts = {};
          _buildingOnCounts = {};
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
          _buildingEnergy = _currentMonthBuildingEnergy(_historyRoot);
          _updateMonthlyTotals(_historyRoot);
        } else if (_isLoading) {
          _historyRoot = {};
          _buildingEnergy = {};
          _monthlyKwh = 0;
          _monthlyCostPhp = 0;
        }

        // ── automations (institute admin "Schedules" KPI only) ─────
        final automationsRaw = events[5].snapshot.value;
        if (automationsRaw is Map && _institute != null) {
          final code = _institute!;
          int total = 0;
          int active = 0;
          automationsRaw.forEach((id, val) {
            if (val is! Map) return;
            final schedule = Map<String, dynamic>.from(val);
            final scope = (schedule['scope'] ?? '').toString();
            final target = (schedule['target'] ?? '').toString();
            if (scope != 'building' || target != code) return;
            total++;
            final enabled = schedule['enabled'];
            final isEnabled = enabled is bool
                ? enabled
                : (enabled ?? true).toString().toLowerCase().trim() == 'true';
            if (isEnabled) active++;
          });
          _instituteScheduleCount = total;
          _instituteActiveScheduleCount = active;
        } else if (_isLoading) {
          _instituteScheduleCount = 0;
          _instituteActiveScheduleCount = 0;
        }

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
    final monthKey = _monthKey(HistoryClock.instance.now());
    _instituteSub = Rx.combineLatestList<DatabaseEvent>([
      FirebaseDatabase.instance.ref('devices').onValue,
      FirebaseDatabase.instance.ref('master_devices').onValue,
      FirebaseDatabase.instance
          .ref('history/monthly/$monthKey/buildings/$code/kwh')
          .onValue,
    ]).listen((events) {
      if (!mounted) return;
      setState(() {
        // ── devices: today's institute kWh + online count + per-room
        // grouping for the Home tab's "Room load" section (handoff §5) --
        // grouped by whichever room each live device reports, so it's real
        // data with no extra Firebase reads (there is no per-room history
        // node to read a true "this month" figure from; see `_RoomLoad`
        // doc for why this is today's live kWh, not a monthly total). ────
        final devicesRaw = events[0].snapshot.value;
        if (devicesRaw is Map) {
          final data = Map<String, dynamic>.from(devicesRaw);
          double kwh = 0;
          int online = 0;
          final rooms = <String, _RoomLoad>{};
          data.forEach((id, val) {
            if (val is! Map) return;
            final device = Map<String, dynamic>.from(val);
            final building = (device['building'] ?? '').toString();
            if (building != code) return;
            final deviceKwh = ((device['kwh'] ?? 0.0) as num).toDouble();
            kwh += deviceKwh;

            if (isRecentlySeen(device['last_seen'])) online++;

            final room = (device['room'] ?? '').toString();
            if (room.isNotEmpty) {
              final floor =
                  int.tryParse((device['floor'] ?? '').toString()) ?? 1;
              final existing = rooms[room];
              rooms[room] = _RoomLoad(
                name: room,
                floor: floor,
                deviceCount: (existing?.deviceCount ?? 0) + 1,
                kwh: (existing?.kwh ?? 0) + deviceKwh,
              );
            }
          });
          _instituteKwh = kwh;
          _instituteOnlineDevices = online;
          _instituteRooms = rooms.values.toList()
            ..sort((a, b) => b.kwh.compareTo(a.kwh));
        } else {
          _instituteKwh = 0;
          _instituteOnlineDevices = 0;
          _instituteRooms = [];
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
      final monthKey = _monthKey(HistoryClock.instance.now());
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
      final totalCost = monthMap['total_cost'];

      _monthlyKwh = (totalKwh is num) ? totalKwh.toDouble() : 0.0;
      // The recorded cost: each reading was priced at the rate in force when
      // it was saved, so changing the rate never reprices past usage. Only a
      // month with no stored cost falls back to kWh x the current rate.
      _monthlyCostPhp = (totalCost is num)
          ? totalCost.toDouble()
          : _monthlyKwh * _electricityRate;
    } catch (e) {
      _monthlyKwh = 0;
      _monthlyCostPhp = 0;
    }
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

  // Thresholds match the web dashboard (>=100 kWh/month = high, 50-100 =
  // mid, <50 = low) -- NOT the redesign preview's scaled-for-sample-data
  // 400/200 figures. See handoff §8's explicit callout to use web values.
  String _energyLevel(String code) {
    final kwh = _buildingEnergy[code] ?? 0;
    if (kwh >= 100) return 'HIGH';
    if (kwh >= 50) return 'MID';
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

  // ── Redesign (phase 2) helpers: real numbers for the Home hero/KPI/
  // building-load/last-7-days/history sections, all derived from the
  // already-loaded `_historyRoot` (the whole `history` node, fetched once
  // by `_listenAll` for every role) or the per-building maps populated
  // above -- nothing here is a new Firebase listener.
  static const _weekdayNames = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday',
    'Sunday' //
  ];
  static const _monthShort = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _dailyKeyFor(DateTime d) =>
      '${d.year}-${_pad(d.month)}-${_pad(d.day)}';

  /// "Thursday, Sep 24" -- the real device date, never the preview's
  /// hardcoded sample date.
  String get _dashboardDateLabel {
    final now = HistoryClock.instance.now();
    return '${_weekdayNames[now.weekday - 1]}, ${_monthShort[now.month - 1]} ${now.day}';
  }

  Map<String, dynamic>? _dailyNode(DateTime d) {
    final daily = _historyRoot['daily'];
    if (daily is! Map) return null;
    final node = daily[_dailyKeyFor(d)];
    return node is Map ? Map<String, dynamic>.from(node) : null;
  }

  /// Campus-wide total kWh recorded for day [d], or null if that day has no
  /// recorded history yet (distinct from a real 0 kWh day).
  double? _dailyTotalKwh(DateTime d) {
    final node = _dailyNode(d);
    final v = node?['total_kwh'];
    return v is num ? v.toDouble() : null;
  }

  /// One building's kWh for day [d], or null if unrecorded.
  double? _dailyBuildingKwh(DateTime d, String code) {
    final node = _dailyNode(d);
    final buildings = node?['buildings'];
    if (buildings is! Map) return null;
    final b = buildings[code];
    if (b is Map) {
      final v = b['kwh'];
      return v is num ? v.toDouble() : null;
    }
    if (b is num) return b.toDouble();
    return null;
  }

  double? _weeklyTotalKwh(DateTime d) {
    final weekly = _historyRoot['weekly'];
    if (weekly is! Map) return null;
    final node = weekly[_weeklyKeyForDate(d)];
    if (node is! Map) return null;
    final v = node['total_kwh'];
    return v is num ? v.toDouble() : null;
  }

  double? _weeklyBuildingKwh(DateTime d, String code) {
    final weekly = _historyRoot['weekly'];
    if (weekly is! Map) return null;
    final node = weekly[_weeklyKeyForDate(d)];
    if (node is! Map) return null;
    final buildings = node['buildings'];
    if (buildings is! Map) return null;
    final b = buildings[code];
    if (b is Map) {
      final v = b['kwh'];
      return v is num ? v.toDouble() : null;
    }
    return null;
  }

  double? _monthlyTotalCost(DateTime d) {
    final monthly = _historyRoot['monthly'];
    if (monthly is! Map) return null;
    final node = monthly[_monthKey(d)];
    if (node is! Map) return null;
    final v = node['total_cost'];
    return v is num ? v.toDouble() : null;
  }

  double? _monthlyBuildingCost(DateTime d, String code) {
    final monthly = _historyRoot['monthly'];
    if (monthly is! Map) return null;
    final node = monthly[_monthKey(d)];
    if (node is! Map) return null;
    final buildings = node['buildings'];
    if (buildings is! Map) return null;
    final b = buildings[code];
    if (b is! Map) return null;
    final cost = b['cost'];
    if (cost is num) return cost.toDouble();
    final kwh = b['kwh'];
    if (kwh is num) {
      // No stored cost: price it at the rate in force at the end of that
      // month, not today's rate.
      final monthEnd = DateTime(d.year, d.month + 1, 0);
      return kwh.toDouble() *
          RateHistory.instance.timeline(_electricityRate).rateForDay(monthEnd);
    }
    return null;
  }

  String _weeklyKeyForDate(DateTime d) => '${d.year}-W${_pad(_isoWeek(d))}';

  /// Attempts to bucket today's `history/raw` entries (if any exist) by
  /// hour of day, to find the busiest hour so far -- there is no dedicated
  /// hourly-history node in this app's Firebase schema (see
  /// `history_service.dart`: only daily/weekly/monthly/yearly totals are
  /// ever written), so this degrades to `null` ("no data yet") rather than
  /// inventing a figure when `history/raw` is empty, which is the normal
  /// case today.
  String? _peakHourLabel({String? buildingCode}) {
    final raw = _historyRoot['raw'];
    if (raw is! Map) return null;
    final now = HistoryClock.instance.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    final hourly = List<double>.filled(24, 0);
    bool any = false;
    raw.forEach((key, val) {
      if (val is! Map) return;
      final entry = Map<String, dynamic>.from(val);
      if (buildingCode != null &&
          (entry['building'] ?? '').toString() != buildingCode) {
        return;
      }
      final ts = _analyticsRawTimestamp(entry, key.toString());
      if (ts == null || ts.isBefore(startOfDay) || ts.isAfter(now)) return;
      hourly[ts.hour] += _asDouble(entry['kwh']);
      any = true;
    });
    if (!any) return null;
    var peakHour = 0;
    var peakVal = -1.0;
    for (var h = 0; h <= now.hour; h++) {
      if (hourly[h] > peakVal) {
        peakVal = hourly[h];
        peakHour = h;
      }
    }
    return _hourRangeLabel(peakHour);
  }

  String _hourRangeLabel(int hour) {
    String fmt(int h) {
      final period = h < 12 ? 'AM' : 'PM';
      var h12 = h % 12;
      if (h12 == 0) h12 = 12;
      return '$h12 $period';
    }

    final next = (hour + 1) % 24;
    // Same AM/PM suffix on both sides of the dash when they match (e.g.
    // "2–3 PM"), full "12 AM – 1 AM" style only when they differ.
    final aSuffix = hour < 12 ? 'AM' : 'PM';
    final bSuffix = next < 12 ? 'AM' : 'PM';
    if (aSuffix == bSuffix) {
      final a = hour % 12 == 0 ? 12 : hour % 12;
      final b = next % 12 == 0 ? 12 : next % 12;
      return '$a–$b $aSuffix';
    }
    return '${fmt(hour)} – ${fmt(next)}';
  }

  /// Last 7 days of kWh (oldest first, last entry = today), campus-wide or
  /// scoped to one building. Missing days read as 0 -- shown, not hidden,
  /// since a 0-kWh day is a real (if unlikely) data point once a building
  /// has any recorded history at all.
  List<double> _last7DaysKwh({String? buildingCode}) {
    final now = HistoryClock.instance.now();
    return [
      for (var i = 6; i >= 0; i--)
        (buildingCode == null
                ? _dailyTotalKwh(now.subtract(Duration(days: i)))
                : _dailyBuildingKwh(
                    now.subtract(Duration(days: i)), buildingCode)) ??
            0.0,
    ];
  }

  List<String> get _last7DaysLabels {
    final now = HistoryClock.instance.now();
    const short = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return [
      for (var i = 6; i >= 0; i--)
        i == 0 ? 'Today' : short[now.subtract(Duration(days: i)).weekday - 1],
    ];
  }

  String _buildingDisplayName(String code) {
    final match = _buildings.firstWhere(
      (b) => (b['code'] ?? '').toString() == code,
      orElse: () => <String, dynamic>{},
    );
    return (match['name'] as String?) ?? code;
  }

  // ── Add building (redesign phase 2, handoff §10.2) ─────────────────────
  // Same Firebase write shape and validation as the web "Add building"
  // dialog (`dashboard_web.dart._addBuilding`): code = 2-8 letters/numbers,
  // unique; name required; floors 1-20.
  static final _buildingCodePattern = RegExp(r'^[A-Z0-9]{2,8}$');

  String? _floorsError(String raw) {
    final f = int.tryParse(raw);
    if (f == null || f < 1 || f > 20)
      return 'Enter a whole number from 1 to 20.';
    return null;
  }

  void _showAddBuildingSheet() {
    final codeCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final floorCtrl = TextEditingController(text: '1');
    final existing = {
      for (final b in _buildings) (b['code'] ?? '').toString().toUpperCase()
    };

    showAppBottomSheet(
      context,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setS) {
          String? codeError;
          String? nameError;
          String? floorsError;
          int shake = 0;
          bool submitting = false;

          Future<void> submit(void Function(void Function()) setState) async {
            final code = codeCtrl.text.trim().toUpperCase();
            final name = nameCtrl.text.trim();
            final floorsRaw = floorCtrl.text.trim();
            String? ce, ne, fe;
            if (code.isEmpty) {
              ce = 'Building code is required.';
            } else if (!_buildingCodePattern.hasMatch(code)) {
              ce = 'Use 2–8 letters or numbers, no spaces.';
            } else if (existing.contains(code)) {
              ce = 'That code already exists.';
            }
            if (name.isEmpty) ne = 'Building name is required.';
            fe = _floorsError(floorsRaw);
            if (ce != null || ne != null || fe != null) {
              setState(() {
                codeError = ce;
                nameError = ne;
                floorsError = fe;
                shake++;
              });
              return;
            }
            setState(() => submitting = true);
            try {
              await FirebaseDatabase.instance.ref('buildings/$code').set({
                'name': name,
                'floors': int.parse(floorsRaw),
              });
              if (!sheetCtx.mounted) return;
              Navigator.pop(sheetCtx);
              if (mounted) TopToast.show(context, '$code added.');
            } catch (e) {
              if (!sheetCtx.mounted) return;
              setState(() {
                submitting = false;
                ce = 'Could not add building: $e';
                codeError = ce;
              });
            }
          }

          return BottomSheetScaffold(
            title: 'Add building',
            palette: _palette,
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Building code',
                    style: AppTextStyles.label.copyWith(color: AppColors.ink)),
                const SizedBox(height: 6),
                AppTextField(
                  controller: codeCtrl,
                  shakeTrigger: shake,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    hintText: 'e.g. CLINIC',
                    errorText: codeError,
                    border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(12))),
                  ),
                  autofocus: true,
                ),
                const SizedBox(height: 14),
                Text('Building name',
                    style: AppTextStyles.label.copyWith(color: AppColors.ink)),
                const SizedBox(height: 6),
                AppTextField(
                  controller: nameCtrl,
                  shakeTrigger: shake,
                  decoration: InputDecoration(
                    hintText: 'e.g. Clinic Building',
                    errorText: nameError,
                    border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(12))),
                  ),
                ),
                const SizedBox(height: 14),
                Text('Floors',
                    style: AppTextStyles.label.copyWith(color: AppColors.ink)),
                const SizedBox(height: 6),
                AppTextField(
                  controller: floorCtrl,
                  shakeTrigger: shake,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    errorText: floorsError,
                    border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(12))),
                  ),
                ),
              ],
            ),
            footer: BottomSheetFooter(
              palette: _palette,
              onCancel: () => Navigator.pop(sheetCtx),
              applyLabel: submitting ? 'Adding…' : 'Add',
              onApply: submitting ? null : () => submit(setS),
            ),
          );
        },
      ),
    );
  }

  /// One-shot read of exactly how many rooms/devices/schedules a building
  /// delete would touch, for the delete dialog's impact list (handoff §7.2
  /// "adapt the actual counts to the real building's data").
  Future<_BuildingDeleteImpact> _loadBuildingDeleteImpact(String code) async {
    final assignedDeviceIds = <String>{};

    final devicesSnap = await FirebaseDatabase.instance.ref('devices').get();
    if (devicesSnap.value is Map) {
      final devices = Map<String, dynamic>.from(devicesSnap.value as Map);
      devices.forEach((id, val) {
        if (val is! Map) return;
        final device = Map<String, dynamic>.from(val);
        if ((device['building'] ?? '').toString() == code) {
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

    var roomCount = 0;
    var floorCount = 0;
    final floorDataSnap =
        await FirebaseDatabase.instance.ref('buildings/$code/floorData').get();
    if (floorDataSnap.value is Map) {
      final floorData = Map<String, dynamic>.from(floorDataSnap.value as Map);
      floorCount = floorData.length;
      for (final floor in floorData.values) {
        if (floor is! Map) continue;
        final rooms = floor['rooms'];
        if (rooms is List) {
          roomCount += rooms.length;
        } else if (rooms is Map) {
          roomCount += rooms.length;
        }
      }
    }

    var scheduleCount = 0;
    final automationsSnap =
        await FirebaseDatabase.instance.ref('automations').get();
    if (automationsSnap.value is Map) {
      final automations =
          Map<String, dynamic>.from(automationsSnap.value as Map);
      automations.forEach((id, val) {
        if (val is! Map) return;
        final schedule = Map<String, dynamic>.from(val);
        final scope = (schedule['scope'] ?? '').toString();
        final target = (schedule['target'] ?? '').toString();
        if (scope == 'building' && target == code) {
          scheduleCount++;
        } else if (scope == 'device' && assignedDeviceIds.contains(target)) {
          scheduleCount++;
        }
      });
    }

    return _BuildingDeleteImpact(
      assignedDeviceIds: assignedDeviceIds,
      roomCount: roomCount,
      floorCount: floorCount,
      scheduleCount: scheduleCount,
    );
  }

  /// Runs the shared two-step delete flow (`showDeleteFlow`) for one
  /// building row on the Devices list, wiring its optimistic-remove /
  /// restore hooks into [_deletingBuildingCodes] (drives each row's
  /// [DeleteRowTransition]) and deferring the actual Firebase write until
  /// the 5s Undo window elapses, per handoff §7.4.
  Future<void> _deleteBuildingViaFlow(Map<String, dynamic> building) async {
    final code = building['code'] as String;
    final name = (building['name'] ?? code).toString();

    _BuildingDeleteImpact? impact;
    try {
      impact = await _loadBuildingDeleteImpact(code);
    } catch (e) {
      if (mounted) {
        TopToast.error(
            context, 'Could not check what this building affects: $e');
      }
      return;
    }
    if (!mounted) return;

    final assignedCount = impact.assignedDeviceIds.length;
    final impactLines = [
      if (impact.floorCount > 0)
        '${impact.floorCount} ${impact.floorCount == 1 ? 'floor' : 'floors'}'
            '${impact.roomCount > 0 ? ' and ${impact.roomCount} ${impact.roomCount == 1 ? 'room' : 'rooms'}' : ''}',
      '$assignedCount device${assignedCount == 1 ? '' : 's'} will be unassigned',
      if (impact.scheduleCount > 0)
        '${impact.scheduleCount} schedule${impact.scheduleCount == 1 ? '' : 's'} will stop',
      'Usage history stays in Analytics',
    ];

    await showDeleteFlow(
      context,
      type: DeleteType.building,
      itemName: name,
      impact: impactLines,
      onOptimisticRemove: () =>
          setState(() => _deletingBuildingCodes.add(code)),
      onRestore: () => setState(() => _deletingBuildingCodes.remove(code)),
      onCommit: (reason, otherText) async {
        final updates = <String, dynamic>{
          'buildings/$code': null,
          'hotspots/$code': null,
        };
        for (final deviceId in impact!.assignedDeviceIds) {
          updates['master_devices/$deviceId/assignedTo'] = '';
          updates['devices/$deviceId/building'] = '';
          updates['devices/$deviceId/floor'] = '';
          updates['devices/$deviceId/room'] = '';
          updates['devices/$deviceId/status'] = 'offline';
        }
        final logRef = FirebaseDatabase.instance.ref('deletion_log').push();
        updates['deletion_log/${logRef.key}'] = {
          'type': 'building',
          'code': code,
          'name': name,
          'reason': reason,
          if (otherText != null && otherText.isNotEmpty) 'otherText': otherText,
          'deletedBy': FirebaseAuth.instance.currentUser?.uid ?? '',
          'timestamp': ServerValue.timestamp,
          'impact': {
            'devicesUnassigned': assignedCount,
            'floors': impact.floorCount,
            'rooms': impact.roomCount,
            'schedulesStopped': impact.scheduleCount,
          },
        };
        await FirebaseDatabase.instance.ref().update(updates);
      },
    );
    if (mounted) setState(() => _deletingBuildingCodes.remove(code));
  }

  @override
  Widget build(BuildContext context) {
    // Analytics is always a visible tab now -- per the redesign handoff §2,
    // institute admins DO get Analytics (the embedded HistoryScreen below
    // self-locks their view to their own institute; see its `_lockCode`),
    // so there's no hidden-tab/safe-index fallback to compute here anymore.
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(_role, _institute)],
      ),
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Column(children: [
            _buildTopBar(_selectedIndex),
            Expanded(
              child: IndexedStack(
                index: _selectedIndex,
                children: [
                  _isInstituteAdmin
                      ? _buildInstituteHomeTab()
                      : (_errorText != null
                          ? _buildError()
                          : ScreenSkeleton(
                              isLoading: _isLoading, child: _buildHomeTab())),
                  _buildDevicesTab(),
                  const HistoryScreen(showBackButton: false),
                  AutomationScreen(
                    role: _role,
                    onSubtitleChanged: (subtitle) {
                      if (!mounted || subtitle == _automationSubtitle) return;
                      setState(() => _automationSubtitle = subtitle);
                    },
                  ),
                  const MoreScreen(showBackButton: false),
                ],
              ),
            ),
          ]),
        ),
        bottomNavigationBar: _buildBottomNav(),
      ),
    );
  }

  /// The "Devices" tab (handoff §4.2/§4.3/§5): a List | Map segmented
  /// control. List is a new campus-wide Buildings list (add/delete building
  /// live here now, not inside the building) for campus admins, or the
  /// existing [BuildingFloorScreen] embed (moved here from Home, see
  /// `_buildInstituteHomeTab`'s doc) for institute admins. Map embeds
  /// [CampusMapScreen] (handoff §8: Buildings/Devices modes, institute crop).
  Widget _buildDevicesTab() {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: AppSegmentedControl(
          palette: _palette,
          segments: const [
            AppSegment(label: 'List', icon: Icons.view_list_outlined),
            AppSegment(label: 'Map', icon: Icons.map_outlined),
          ],
          selectedIndex: _devicesViewMode,
          onChanged: (i) => setState(() => _devicesViewMode = i),
        ),
      ),
      Expanded(
        child: _devicesViewMode == 1
            ? CampusMapScreen(role: _role, showAppBar: false)
            : (_isInstituteAdmin
                ? _buildInstituteDevicesList()
                : (_errorText != null
                    ? _buildError()
                    : ScreenSkeleton(
                        isLoading: _isLoading,
                        child: _buildCampusDevicesList()))),
      ),
    ]);
  }

  Widget _buildInstituteDevicesList() {
    final code = _institute ?? '';
    if (code.isEmpty) {
      return const Center(
        child: Text('No institute assigned yet.',
            style: TextStyle(color: AppColors.inkMid)),
      );
    }
    final match = _buildings.firstWhere(
      (b) => (b['code'] ?? '').toString() == code,
      orElse: () => <String, dynamic>{},
    );
    final floors = (match['floors'] as int?) ?? 1;
    final name = (match['name'] as String?) ?? code;
    return BuildingFloorScreen(
      key: ValueKey('devices-institute-$code'),
      buildingCode: code,
      buildingName: name,
      floors: floors,
      role: _role,
      showBackButton: false,
    );
  }

  Widget _buildCampusDevicesList() {
    final query = _deviceSearchQuery.trim().toLowerCase();
    var buildings = [..._buildings]..sort((a, b) {
        final aCode = (a['code'] ?? '').toString();
        final bCode = (b['code'] ?? '').toString();
        final aKwh = _buildingTodayKwh[aCode] ?? 0;
        final bKwh = _buildingTodayKwh[bCode] ?? 0;
        final byKwh = bKwh.compareTo(aKwh);
        if (byKwh != 0) return byKwh;
        return aCode.compareTo(bCode);
      });
    if (query.isNotEmpty) {
      buildings = buildings.where((b) {
        final code = (b['code'] ?? '').toString().toLowerCase();
        final name = (b['name'] ?? '').toString().toLowerCase();
        return code.contains(query) || name.contains(query);
      }).toList();
    }
    switch (_devicesStatusFilter) {
      case 1: // Online
        buildings = buildings
            .where((b) =>
                (_buildingOnlineCounts[(b['code'] ?? '').toString()] ?? 0) > 0)
            .toList();
      case 2: // Offline
        buildings = buildings
            .where((b) =>
                (_buildingOfflineCounts[(b['code'] ?? '').toString()] ?? 0) > 0)
            .toList();
      case 3: // Unassigned -- devices, not buildings; nothing to narrow the
        // buildings list to, so show all buildings plus an explanatory note
        // above the list instead of an empty result.
        break;
    }

    final totalOnline = _onlineDevicesCount;
    final totalOffline = (_assignedDevices - totalOnline)
        .clamp(0, _assignedDevices > 0 ? _assignedDevices : 0);

    return LayoutBuilder(builder: (context, constraints) {
      final isCompact = constraints.maxWidth < Breakpoints.compact;
      return SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            isCompact ? 16 : 20, 16, isCompact ? 16 : 20, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 16),
          AppTextField(
            controller: _deviceSearchCtrl,
            onChanged: (v) => setState(() => _deviceSearchQuery = v),
            decoration: const InputDecoration(
              hintText: 'Search building or code',
              prefixIcon: Icon(Icons.search, size: 20),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(12))),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            AppFilterChip(
              label: 'All $_assignedDevices',
              selected: _devicesStatusFilter == 0,
              onTap: () => setState(() => _devicesStatusFilter = 0),
              palette: _palette,
            ),
            AppFilterChip(
              label: 'Online $totalOnline',
              selected: _devicesStatusFilter == 1,
              onTap: () => setState(() => _devicesStatusFilter = 1),
              palette: _palette,
            ),
            AppFilterChip(
              label: 'Offline $totalOffline',
              selected: _devicesStatusFilter == 2,
              onTap: () => setState(() => _devicesStatusFilter = 2),
              palette: _palette,
            ),
            AppFilterChip(
              label: 'Unassigned $_unassignedDevices',
              selected: _devicesStatusFilter == 3,
              onTap: () => setState(() => _devicesStatusFilter = 3),
              palette: _palette,
            ),
          ]),
          if (_devicesStatusFilter == 3 && _unassignedDevices > 0)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                'Unassigned devices aren\'t linked to a building yet -- assign them from a building\'s room screen.',
                style: AppTextStyles.caption.copyWith(color: AppColors.inkMid),
              ),
            ),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(
              child: _sectionHeader('Buildings',
                  subtitle: 'Sorted by usage today'),
            ),
            if (_isSuperAdmin) ...[
              const SizedBox(width: 8),
              IconAddButton(
                onPressed: _showAddBuildingSheet,
                palette: _palette,
                semanticLabel: 'Add building',
              ),
            ],
          ]),
          const SizedBox(height: 8),
          if (buildings.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text('No buildings match.',
                    style:
                        AppTextStyles.bodySm.copyWith(color: AppColors.inkMid)),
              ),
            )
          else
            ...buildings
                .map((b) => _buildDevicesBuildingRow(b, compact: isCompact)),
        ]),
      );
    });
  }

  Widget _buildDevicesBuildingRow(Map<String, dynamic> building,
      {bool compact = false}) {
    final code = (building['code'] ?? '').toString();
    final floors = (building['floors'] as int?) ?? 1;
    final onCount = _buildingOnCounts[code] ?? 0;
    final totalCount = _buildingDeviceCounts[code] ?? 0;
    final todayKwh = _buildingTodayKwh[code] ?? 0;
    final buildingPalette = InstituteColors.forCode(code);
    final icon =
        code.toUpperCase() == 'ADMIN' ? Icons.account_balance : Icons.apartment;
    final deleting = _deletingBuildingCodes.contains(code);

    return DeleteRowTransition(
      key: ValueKey('devices-building-$code'),
      deleting: deleting,
      message: '$code deleted',
      onDeleteAnimationComplete: () {
        // The row is already visually gone; nothing further to remove from
        // local state -- `_buildings` updates itself once the Firebase
        // write in `_deleteBuildingViaFlow`'s onCommit lands.
      },
      child: GestureDetector(
        onTap: () => Navigator.pushNamed(context, '/building', arguments: {
          'buildingCode': code,
          'buildingName': building['name'],
          'floors': building['floors'],
          'role': _role,
        }),
        child: Container(
          padding: EdgeInsets.symmetric(vertical: compact ? 10 : 12),
          decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: _palette.line))),
          child: Row(children: [
            OutlineIconBox(
                icon: icon, palette: buildingPalette, size: compact ? 36 : 40),
            SizedBox(width: compact ? 10 : 12),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text((building['name'] ?? code).toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.subtitle.copyWith(
                          color: AppColors.ink, fontSize: compact ? 14 : 16)),
                  const SizedBox(height: 2),
                  Text(
                      '$floors ${floors > 1 ? 'floors' : 'floor'} · $onCount/$totalCount on',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.inkMid)),
                ])),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(_safeFormatDouble(todayKwh, 1),
                  style: AppTextStyles.subtitle.copyWith(
                      color: AppColors.ink, fontSize: compact ? 14 : 16)),
              Text('kWh today',
                  style:
                      AppTextStyles.caption.copyWith(color: AppColors.inkMid)),
            ]),
            if (_isSuperAdmin) ...[
              const SizedBox(width: 4),
              IconDeleteButton(
                onPressed: () => _deleteBuildingViaFlow(building),
                semanticLabel: 'Delete $code',
              ),
            ],
          ]),
        ),
      ),
    );
  }

  /// An institute admin's "Dashboard" tab: their institute's rooms directly,
  /// themed to their institute's color — no campus-wide buildings list.
  /// An institute admin's Home tab (handoff §5): hero + KPIs + Room load +
  /// Last 7 days + History, all scoped to `_institute` only. The live
  /// floor/room screen used to be embedded directly here -- it now lives on
  /// the Devices tab instead (see `_buildDevicesTab`), matching the
  /// redesign's split between "overview" (Home) and "control" (Devices).
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < Breakpoints.compact;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            isCompact ? 16 : 20,
            isCompact ? 14 : 18,
            isCompact ? 16 : 20,
            isCompact ? 18 : 20,
          ),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const HistoryFallbackNotice(),
            SizedBox(height: isCompact ? 14 : 20),
            _buildInstituteEnergyHero(
                code: code, floors: floors, compact: isCompact),
            SizedBox(height: isCompact ? 18 : 24),
            _buildKpiGrid(_instituteKpis(code, floors), compact: isCompact),
            SizedBox(height: isCompact ? 18 : 24),
            _sectionHeader('Room load', subtitle: 'Today, heaviest first'),
            SizedBox(height: isCompact ? 10 : 12),
            if (_instituteRooms.isEmpty)
              Container(
                padding: EdgeInsets.all(isCompact ? 16 : 20),
                decoration: BoxDecoration(
                  color: AppColors.cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _palette.line),
                ),
                child: const Center(
                  child: Text('No room devices yet',
                      style: TextStyle(fontSize: 13, color: AppColors.inkMid)),
                ),
              )
            else
              ..._instituteRooms
                  .map((r) => _buildRoomLoadRow(r, compact: isCompact)),
            SizedBox(height: isCompact ? 18 : 24),
            _sectionHeader('Last 7 days', subtitle: 'kWh per day'),
            SizedBox(height: isCompact ? 10 : 12),
            _buildLast7DaysCard(
                _last7DaysKwh(buildingCode: code), _last7DaysLabels),
            SizedBox(height: isCompact ? 18 : 24),
            HistoryTrendPanel(
              palette: _palette,
              instituteCode: code,
              days: 5,
              onOpen: () => setState(() => _selectedIndex = 2),
            ),
          ]),
        );
      },
    );
  }

  Widget _buildInstituteEnergyHero(
      {required String code, required int floors, bool compact = false}) {
    final now = HistoryClock.instance.now();
    final yesterday =
        _dailyBuildingKwh(now.subtract(const Duration(days: 1)), code);
    double? deltaPct;
    if (yesterday != null && yesterday > 0) {
      deltaPct = ((_instituteKwh - yesterday) / yesterday) * 100;
    }
    final weekKwh = _weeklyBuildingKwh(now, code);
    final roomCount = _instituteRooms.length;
    final monthCost = _monthlyBuildingCost(now, code) ??
        _instituteMonthlyKwh * _electricityRate;

    return Container(
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
        Row(children: [
          Text('$code energy today',
              style: AppTextStyles.label.copyWith(color: Colors.white)),
          const Spacer(),
          _livePill(),
        ]),
        SizedBox(height: compact ? 8 : 10),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(_safeFormatDouble(_instituteKwh, 2),
              style: AppTextStyles.display
                  .copyWith(color: Colors.white, fontSize: compact ? 32 : 36)),
          Padding(
              padding: EdgeInsets.only(bottom: compact ? 4 : 6, left: 6),
              child: Text('kWh',
                  style: TextStyle(
                      fontFamily: AppFonts.family,
                      fontSize: compact ? 13 : 14,
                      color: Colors.white,
                      fontWeight: FontWeight.w500))),
        ]),
        if (deltaPct != null) ...[
          const SizedBox(height: 6),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(deltaPct <= 0 ? Icons.trending_down : Icons.trending_up,
                size: 18, color: Colors.white),
            const SizedBox(width: 4),
            Text(
              '${deltaPct.abs().toStringAsFixed(0)}% ${deltaPct <= 0 ? 'less' : 'more'} than yesterday',
              style: AppTextStyles.bodySm.copyWith(color: Colors.white),
            ),
          ]),
        ],
        SizedBox(height: compact ? 12 : 16),
        Container(
          padding: EdgeInsets.all(compact ? 10 : 12),
          decoration: BoxDecoration(
              color: Colors.white.withAlpha(15),
              borderRadius: BorderRadius.circular(12)),
          child: Column(children: [
            Row(children: [
              _miniStat(weekKwh == null ? '—' : _safeFormatDouble(weekKwh, 1),
                  'This week',
                  compact: compact, unit: weekKwh == null ? null : 'kWh'),
              _vertDivider(),
              _miniStat(_safeFormatDouble(_instituteMonthlyKwh, 1),
                  'This month',
                  compact: compact, unit: 'kWh'),
              _vertDivider(),
              _miniStat('$floors ${floors > 1 ? 'floors' : 'floor'}',
                  '$roomCount rooms',
                  compact: compact),
            ]),
            _heroRowDivider(compact),
            Row(children: [
              _miniStat(
                  yesterday == null ? '—' : _safeFormatDouble(yesterday, 1),
                  'Yesterday',
                  compact: compact, unit: yesterday == null ? null : 'kWh'),
              _vertDivider(),
              _miniStat('₱${_safeFormatDouble(monthCost, 0)}', 'Month cost',
                  compact: compact),
              _vertDivider(),
              _miniStat('$_instituteOnlineDevices', 'Online',
                  compact: compact, unit: '/ $_instituteAssignedDevices'),
            ]),
          ]),
        ),
      ]),
    );
  }

  List<_KpiItem> _instituteKpis(String code, int floors) {
    final now = HistoryClock.instance.now();
    final lastMonth = DateTime(now.year, now.month - 1, 1);
    final lastMonthCost = _monthlyBuildingCost(lastMonth, code);
    final monthCost = _monthlyBuildingCost(now, code) ??
        _instituteMonthlyKwh * _electricityRate;
    double? costDeltaPct;
    if (lastMonthCost != null && lastMonthCost > 0) {
      costDeltaPct = ((monthCost - lastMonthCost) / lastMonthCost) * 100;
    }
    final total = _instituteAssignedDevices;
    final offline =
        (total - _instituteOnlineDevices).clamp(0, total > 0 ? total : 0);

    return [
      _KpiItem(
        icon: Icons.payments_outlined,
        label: 'Month cost',
        value: '₱${_safeFormatDouble(monthCost, 0)}',
        foot: costDeltaPct == null
            ? '₱${_electricityRate.toStringAsFixed(2)} per kWh'
            : '${costDeltaPct >= 0 ? '▲' : '▼'} ${costDeltaPct.abs().toStringAsFixed(0)}% vs last month',
        footColor: costDeltaPct == null
            ? null
            : (costDeltaPct >= 0 ? AppColors.errorText : AppColors.successText),
      ),
      _KpiItem(
        icon: Icons.wifi_tethering,
        label: 'Online',
        value: '$_instituteOnlineDevices',
        unit: '/ $total',
        foot: '$offline offline',
      ),
      _KpiItem(
        icon: Icons.meeting_room_outlined,
        label: 'Rooms',
        value: '${_instituteRooms.length}',
        foot: '$floors ${floors > 1 ? 'floors' : 'floor'}',
      ),
      _KpiItem(
        icon: Icons.schedule_outlined,
        label: 'Schedules',
        value: '$_instituteScheduleCount',
        foot: '$_instituteActiveScheduleCount active',
      ),
    ];
  }

  Widget _buildRoomLoadRow(_RoomLoad room, {bool compact = false}) {
    final maxKwh =
        _instituteRooms.fold<double>(1, (m, r) => r.kwh > m ? r.kwh : m);
    return GestureDetector(
      onTap: () => setState(() => _selectedIndex = 1),
      child: Container(
        padding: EdgeInsets.symmetric(vertical: compact ? 10 : 12),
        decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: _palette.line))),
        child: Row(children: [
          OutlineIconBox(icon: Icons.meeting_room, size: compact ? 36 : 40),
          SizedBox(width: compact ? 10 : 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(room.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.subtitle.copyWith(
                        color: AppColors.ink, fontSize: compact ? 14 : 16)),
                const SizedBox(height: 2),
                Text(
                    'Floor ${room.floor} · ${room.deviceCount} ${room.deviceCount == 1 ? 'device' : 'devices'}',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.inkMid)),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value:
                        maxKwh <= 0 ? 0 : (room.kwh / maxKwh).clamp(0.0, 1.0),
                    minHeight: 6,
                    backgroundColor: AppColors.skeleton,
                    valueColor: AlwaysStoppedAnimation<Color>(_palette.dark),
                  ),
                ),
              ])),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(_safeFormatDouble(room.kwh, 1),
                style: AppTextStyles.subtitle.copyWith(
                    color: AppColors.ink, fontSize: compact ? 14 : 16)),
            Text('kWh',
                style: AppTextStyles.caption.copyWith(color: AppColors.inkMid)),
          ]),
        ]),
      ),
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
                  color: Colors.white,
                  border: Border.all(color: AppColors.hairline),
                  borderRadius: BorderRadius.circular(20)),
              child:
                  Icon(Icons.wifi_off_rounded, size: 34, color: _palette.mid)),
          const SizedBox(height: 16),
          const Text('Cannot load dashboard',
              style: TextStyle(
                  fontFamily: AppFonts.family,
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
            label: const Text('Retry', style: TextStyle(color: Colors.white)),
            style: ElevatedButton.styleFrom(
                backgroundColor: _palette.dark,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
          ),
        ]),
      ),
    );
  }

  /// The shared root-tab top bar (handoff §2/§3.4): white `AppTopBar` with
  /// a bell (unread badge) + avatar (→ More), replacing the old green bar
  /// and its burger `PopupMenuButton` (Notifications/Manage Users/Settings/
  /// Logout now live in `MoreScreen`, reachable from the avatar and the
  /// bottom nav's "More" tab -- see `_buildBottomNav`). Home gets the big
  /// 30/36 "Dashboard" + date title (handoff §3.4/§4.1); the other 3 root
  /// tabs use the standard title size.
  Widget _buildTopBar(int tabIndex) {
    const titles = ['Dashboard', 'Devices', 'Analytics', 'Automation', 'More'];
    final isHome = tabIndex == 0;
    return AppTopBar(
      title: titles[tabIndex],
      subtitle: _topBarSubtitle(tabIndex, isHome: isHome),
      variant: isHome ? AppTopBarVariant.big : AppTopBarVariant.standard,
      palette: _palette,
      showInstituteLine: _isInstituteAdmin,
      // The More tab's own top bar is where the avatar leads *to* -- showing
      // it there too would be a circular affordance the preview never has
      // (its More screen top bar is title + bell only). Every other root
      // tab keeps the avatar as the way to reach More.
      showAvatar: _navTabOrder[tabIndex] != AppNavTab.more,
      avatarInitials: _initials,
      onAvatarTap: () =>
          setState(() => _selectedIndex = _navTabOrder.indexOf(AppNavTab.more)),
      actions: [
        AppTopBarAction(
          icon: Icons.notifications_outlined,
          tooltip: 'Notifications',
          badgeCount: _unreadNotificationCount,
          onTap: () => unawaited(_openNotifications()),
        ),
      ],
    );
  }

  /// Per-tab subtitle for the shared shell top bar. Home keeps its date
  /// label; Devices and Analytics mirror the subtitle each tab's own screen
  /// used to compute for itself before the embedded screens' own top bars
  /// were suppressed (see `_buildCampusDevicesList` and `HistoryScreen`'s
  /// `build()`) -- kept here instead so there's exactly one top bar per tab.
  /// Automation's subtitle ("N of M schedules active") is reported up by
  /// the embedded `AutomationScreen` itself via `_automationSubtitle` (see
  /// its `onSubtitleChanged` callback above), since the schedule counts it
  /// reflects live only in that screen's own state. More (and an institute
  /// admin's Devices tab, which embeds `BuildingFloorScreen` and already
  /// shows an equivalent summary of its own) get no subtitle.
  String? _topBarSubtitle(int tabIndex, {required bool isHome}) {
    if (isHome) return _dashboardDateLabel;
    if (tabIndex == 1 && !_isInstituteAdmin) {
      return '$_assignedDevices devices in ${_buildings.length} buildings';
    }
    if (tabIndex == 2) {
      final code = _institute;
      if (_isInstituteAdmin && code != null && code.isNotEmpty) {
        return '${_buildingDisplayName(code)} energy and forecast';
      }
      return 'Energy and forecast';
    }
    if (tabIndex == 3) return _automationSubtitle;
    return null;
  }

  Widget _buildHomeTab() {
    final buildingsSource = _buildings.isEmpty && _isLoading
        ? placeholderBuildingList()
        : _buildings;
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
        final isCompact = constraints.maxWidth < Breakpoints.compact;

        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            isCompact ? 16 : 20,
            isCompact ? 14 : 18,
            isCompact ? 16 : 20,
            isCompact ? 18 : 20,
          ),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const HistoryFallbackNotice(),
            SizedBox(height: isCompact ? 14 : 20),
            _buildEnergyHero(compact: isCompact),
            SizedBox(height: isCompact ? 18 : 24),
            _buildKpiGrid(_campusKpis(), compact: isCompact),
            SizedBox(height: isCompact ? 18 : 24),
            _sectionHeader('Building load', subtitle: 'This month'),
            SizedBox(height: isCompact ? 10 : 12),
            if (buildingsSource.isEmpty)
              Container(
                padding: EdgeInsets.all(isCompact ? 16 : 20),
                decoration: BoxDecoration(
                  color: AppColors.cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _palette.mid.withAlpha(31)),
                ),
                child: const Center(
                  child: Text('No buildings yet',
                      style: TextStyle(fontSize: 13, color: AppColors.inkMid)),
                ),
              )
            else
              ...sortedBuildings.map((building) => _buildBuildingLoadRow(
                    building,
                    compact: isCompact,
                  )),
            SizedBox(height: isCompact ? 18 : 24),
            _sectionHeader('Last 7 days', subtitle: 'kWh per day'),
            SizedBox(height: isCompact ? 10 : 12),
            _buildLast7DaysCard(_last7DaysKwh(), _last7DaysLabels),
            SizedBox(height: isCompact ? 18 : 24),
            HistoryTrendPanel(
              palette: _palette,
              days: 5,
              onOpen: () => setState(() => _selectedIndex = 2),
            ),
          ]),
        );
      },
    );
  }

  Widget _sectionHeader(String title,
      {String? subtitle, VoidCallback? onLink, String? linkLabel}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: AppTextStyles.title.copyWith(color: AppColors.ink)),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(subtitle,
                      style: AppTextStyles.bodySm
                          .copyWith(color: AppColors.inkMid)),
                ),
            ],
          ),
        ),
        if (onLink != null)
          AppTextButton(
              label: linkLabel ?? 'All', onPressed: onLink, palette: _palette),
      ],
    );
  }

  /// The redesigned "Energy today" hero card (handoff §4.1): title + Live
  /// pill, big kWh, a real "% vs yesterday" delta (hidden when yesterday
  /// has no recorded history), and 3 stat cells (This week / This month /
  /// Peak hour). No fabricated hourly sparkline -- see `_peakHourLabel`'s
  /// doc for why "Peak hour" degrades to "—" rather than inventing a time.
  Widget _buildEnergyHero({bool compact = false}) {
    final now = HistoryClock.instance.now();
    final yesterday = _dailyTotalKwh(now.subtract(const Duration(days: 1)));
    double? deltaPct;
    if (yesterday != null && yesterday > 0) {
      deltaPct = ((_totalKwh - yesterday) / yesterday) * 100;
    }
    final weekKwh = _weeklyTotalKwh(now);
    final peakHour = _peakHourLabel();

    return Container(
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
        Row(children: [
          Text('Energy today',
              style: AppTextStyles.label.copyWith(color: Colors.white)),
          const Spacer(),
          _livePill(),
        ]),
        SizedBox(height: compact ? 8 : 10),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(_safeFormatDouble(_totalKwh, 2),
              style: AppTextStyles.display
                  .copyWith(color: Colors.white, fontSize: compact ? 32 : 36)),
          Padding(
              padding: EdgeInsets.only(bottom: compact ? 4 : 6, left: 6),
              child: Text('kWh',
                  style: TextStyle(
                      fontFamily: AppFonts.family,
                      fontSize: compact ? 13 : 14,
                      color: Colors.white,
                      fontWeight: FontWeight.w500))),
        ]),
        if (deltaPct != null) ...[
          const SizedBox(height: 6),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(deltaPct <= 0 ? Icons.trending_down : Icons.trending_up,
                size: 18, color: Colors.white),
            const SizedBox(width: 4),
            Text(
              '${deltaPct.abs().toStringAsFixed(0)}% ${deltaPct <= 0 ? 'less' : 'more'} than yesterday',
              style: AppTextStyles.bodySm.copyWith(color: Colors.white),
            ),
          ]),
        ],
        SizedBox(height: compact ? 12 : 16),
        Container(
          padding: EdgeInsets.all(compact ? 10 : 12),
          decoration: BoxDecoration(
              color: Colors.white.withAlpha(15),
              borderRadius: BorderRadius.circular(12)),
          child: Column(children: [
            Row(children: [
              _miniStat(weekKwh == null ? '—' : _safeFormatDouble(weekKwh, 1),
                  'This week',
                  compact: compact, unit: weekKwh == null ? null : 'kWh'),
              _vertDivider(),
              _miniStat(_safeFormatDouble(_monthlyKwh, 1), 'This month',
                  compact: compact, unit: 'kWh'),
              _vertDivider(),
              _miniStat(peakHour ?? '—', 'Peak hour', compact: compact),
            ]),
            _heroRowDivider(compact),
            Row(children: [
              _miniStat(
                  yesterday == null ? '—' : _safeFormatDouble(yesterday, 1),
                  'Yesterday',
                  compact: compact, unit: yesterday == null ? null : 'kWh'),
              _vertDivider(),
              _miniStat('₱${_safeFormatDouble(_monthlyCostPhp, 0)}',
                  'Month cost',
                  compact: compact),
              _vertDivider(),
              _miniStat('$_onlineDevicesCount', 'Online',
                  compact: compact, unit: '/ $_assignedDevices'),
            ]),
          ]),
        ),
      ]),
    );
  }

  Widget _livePill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(30),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
                color: Colors.white, shape: BoxShape.circle)),
        const SizedBox(width: 5),
        const Text('Live',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.white)),
      ]),
    );
  }

  /// Hairline between the hero's two stat rows.
  Widget _heroRowDivider(bool compact) => Container(
      height: 1,
      margin: EdgeInsets.symmetric(vertical: compact ? 8 : 10),
      color: Colors.white.withAlpha(30));

  Widget _vertDivider() => Container(
      width: 1,
      height: 32,
      margin: const EdgeInsets.symmetric(horizontal: 10),
      color: Colors.white.withAlpha(30));

  /// A hero stat cell: **value** above a caption label (handoff §4.1 "3
  /// cells" / preview `.h-cell`). Kept as `(value, label)` -- the order
  /// callers pass this in changed from the pre-redesign `(label, value)`
  /// signature, so every call site above was updated together with this.
  Widget _miniStat(String value, String label,
      {bool compact = false, String? unit}) {
    return Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text.rich(
          TextSpan(children: [
            TextSpan(text: value),
            if (unit != null)
              TextSpan(
                  text: ' $unit',
                  style: TextStyle(
                      fontSize: compact ? 10 : 11,
                      fontWeight: FontWeight.w500,
                      color: Colors.white70)),
          ]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontFamily: AppFonts.family,
              fontSize: compact ? 15 : 16,
              fontWeight: FontWeight.w700,
              color: Colors.white)),
      const SizedBox(height: 2),
      Text(label,
          style: TextStyle(fontSize: compact ? 10 : 11, color: Colors.white70)),
    ]));
  }

  /// The real KPI numbers for the campus admin's 2x2 grid (handoff §4.1).
  List<_KpiItem> _campusKpis() {
    final now = HistoryClock.instance.now();
    final lastMonth = DateTime(now.year, now.month - 1, 1);
    final lastMonthCost = _monthlyTotalCost(lastMonth);
    double? costDeltaPct;
    if (lastMonthCost != null && lastMonthCost > 0) {
      costDeltaPct = ((_monthlyCostPhp - lastMonthCost) / lastMonthCost) * 100;
    }
    final totalForOnline = _assignedDevices;
    final offline = (totalForOnline - _onlineDevicesCount)
        .clamp(0, totalForOnline > 0 ? totalForOnline : 0);
    final highLoadBuildings = _buildings
        .where((b) => _energyLevel((b['code'] ?? '').toString()) == 'HIGH')
        .toList();
    final highLoadName = highLoadBuildings.isEmpty
        ? null
        : _buildingDisplayName(
            (highLoadBuildings.first['code'] ?? '').toString());

    return [
      _KpiItem(
        icon: Icons.payments_outlined,
        label: 'Month cost',
        value: '₱${_safeFormatDouble(_monthlyCostPhp, 0)}',
        foot: costDeltaPct == null
            ? null
            : '${costDeltaPct >= 0 ? '▲' : '▼'} ${costDeltaPct.abs().toStringAsFixed(0)}% vs last month',
        footColor: costDeltaPct == null
            ? null
            : (costDeltaPct >= 0 ? AppColors.errorText : AppColors.successText),
      ),
      _KpiItem(
        icon: Icons.wifi_tethering,
        label: 'Online',
        value: '$_onlineDevicesCount',
        unit: '/ $totalForOnline',
        foot: '$offline offline',
      ),
      _KpiItem(
        icon: Icons.local_fire_department_outlined,
        label: 'High load',
        value: '${highLoadBuildings.length}',
        foot: highLoadName ?? 'None this month',
      ),
      _KpiItem(
        icon: Icons.device_unknown_outlined,
        label: 'Unassigned',
        value: '$_unassignedDevices',
        foot: _unassignedDevices > 0 ? 'Need a room' : 'All assigned',
      ),
    ];
  }

  /// The 2x2 KPI grid, split by hairlines with no tile fills (handoff
  /// §3.1 "no boxes" / §3.2 outline system).
  Widget _buildKpiGrid(List<_KpiItem> items, {bool compact = false}) {
    final line = _palette.line;
    Widget cell(_KpiItem item,
        {bool borderRight = false, bool borderBottom = false}) {
      return Expanded(
        child: Container(
          padding: EdgeInsets.symmetric(
              vertical: compact ? 10 : 12, horizontal: compact ? 10 : 12),
          decoration: BoxDecoration(
            border: Border(
              right: borderRight ? BorderSide(color: line) : BorderSide.none,
              bottom: borderBottom ? BorderSide(color: line) : BorderSide.none,
            ),
          ),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(item.icon, size: 16, color: _palette.dark),
              const SizedBox(width: 6),
              Expanded(
                child: Text(item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.caption.copyWith(
                        color: AppColors.ink, fontWeight: FontWeight.w600)),
              ),
            ]),
            SizedBox(height: compact ? 6 : 8),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(item.value,
                  style: AppTextStyles.statTabular.copyWith(
                      color: AppColors.ink, fontSize: compact ? 20 : 24)),
              if (item.unit != null)
                Padding(
                  padding: const EdgeInsets.only(left: 3, bottom: 2),
                  child: Text(item.unit!,
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.inkMid)),
                ),
            ]),
            if (item.foot != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(item.foot!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.caption
                        .copyWith(color: item.footColor ?? AppColors.inkMid)),
              ),
          ]),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
          border: Border.all(color: line),
          borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Row(children: [
          cell(items[0], borderRight: true, borderBottom: true),
          cell(items[1], borderBottom: true),
        ]),
        Row(children: [
          cell(items[2], borderRight: true),
          cell(items[3]),
        ]),
      ]),
    );
  }

  /// A building-load row for the Home tab (handoff §4.1): outline icon
  /// colored per-institute (Admin = `account_balance`, others =
  /// `apartment`), no building-code badge, load bar + HIGH/MID/LOW pill.
  Widget _buildBuildingLoadRow(Map<String, dynamic> building,
      {bool compact = false}) {
    final code = (building['code'] ?? '').toString();
    final level = _energyLevel(code);
    final color = _energyColor(code);
    final devices = _buildingDeviceCounts[code] ?? 0;
    final kwh = _buildingEnergy[code] ?? 0;
    final maxKwh =
        _buildingEnergy.values.fold<double>(1, (m, v) => v > m ? v : m);
    final buildingPalette = InstituteColors.forCode(code);
    final icon =
        code.toUpperCase() == 'ADMIN' ? Icons.account_balance : Icons.apartment;

    return GestureDetector(
      onTap: () => Navigator.pushNamed(context, '/building', arguments: {
        'buildingCode': code,
        'buildingName': building['name'],
        'floors': building['floors'],
        'role': _role,
      }),
      child: Container(
        padding: EdgeInsets.symmetric(vertical: compact ? 10 : 12),
        decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: _palette.line))),
        child: Row(children: [
          OutlineIconBox(
              icon: icon, palette: buildingPalette, size: compact ? 36 : 40),
          SizedBox(width: compact ? 10 : 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text((building['name'] ?? code).toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.subtitle.copyWith(
                        color: AppColors.ink, fontSize: compact ? 14 : 16)),
                const SizedBox(height: 2),
                Text('$devices ${devices == 1 ? 'device' : 'devices'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.inkMid)),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: maxKwh <= 0 ? 0 : (kwh / maxKwh).clamp(0.0, 1.0),
                    minHeight: 6,
                    backgroundColor: AppColors.skeleton,
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                ),
              ])),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(_safeFormatDouble(kwh, 1),
                style: AppTextStyles.subtitle.copyWith(
                    color: AppColors.ink, fontSize: compact ? 14 : 16)),
            const SizedBox(height: 3),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: color.withAlpha(77))),
              child: Text(level,
                  style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w700, color: color)),
            ),
          ]),
        ]),
      ),
    );
  }

  /// Last-7-days bar chart (handoff §4.1/§5): today emphasized + value
  /// label, the highest non-today day in orange, the rest in light green.
  Widget _buildLast7DaysCard(List<double> values, List<String> labels) {
    final maxVal = values.fold<double>(0, (m, v) => v > m ? v : m);
    var peakIndex = -1;
    var peakVal = -1.0;
    for (var i = 0; i < values.length - 1; i++) {
      if (values[i] > peakVal) {
        peakVal = values[i];
        peakIndex = i;
      }
    }
    const chartHeight = 110.0;
    final todayIndex = values.length - 1;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _palette.line),
      ),
      child: Column(children: [
        SizedBox(
          height: chartHeight + 24,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < values.length; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (i == todayIndex)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(_safeFormatDouble(values[i], 0),
                                style: AppTextStyles.caption.copyWith(
                                    color: AppColors.ink,
                                    fontWeight: FontWeight.w700)),
                          ),
                        Container(
                          height: maxVal <= 0
                              ? 4
                              : (8 + (values[i] / maxVal) * (chartHeight - 8)),
                          decoration: BoxDecoration(
                            color: i == todayIndex
                                ? _palette.dark
                                : (i == peakIndex
                                    ? AppColors.warning
                                    : _palette.light),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(labels[i],
                            style: AppTextStyles.caption
                                .copyWith(color: AppColors.inkMuted)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _legendDot(_palette.dark, 'Today'),
          const SizedBox(width: 14),
          _legendDot(AppColors.warning, 'Peak'),
          const SizedBox(width: 14),
          _legendDot(_palette.light, 'Earlier'),
        ]),
      ]),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 5),
      Text(label,
          style: AppTextStyles.caption.copyWith(color: AppColors.inkMid)),
    ]);
  }

  // The IndexedStack keeps fixed conceptual slots (0 Dashboard, 1 Devices
  // [List | Map segmented], 2 Analytics, 3 Automation, 4 More) -- this maps
  // them to the matching `AppNavTab`s for the `AppBottomNav` widget (handoff
  // §2/§3.7). More is a real 5th tab in the same IndexedStack (embedding
  // `MoreScreen(showBackButton: false)`, see `build()`), not a pushed route
  // -- only the screens More itself links out to (Manage Users, Settings,
  // Notifications) are pushed routes with a back arrow.
  static const _navTabOrder = [
    AppNavTab.home,
    AppNavTab.devices,
    AppNavTab.analytics,
    AppNavTab.automation,
    AppNavTab.more,
  ];

  Widget _buildBottomNav() {
    return AppBottomNav(
      palette: _palette,
      selected: _navTabOrder[_selectedIndex],
      // Analytics is never hidden anymore -- see the `build()` comment above
      // this widget's call site.
      hiddenTabs: const {},
      onSelect: (tab) =>
          setState(() => _selectedIndex = _navTabOrder.indexOf(tab)),
    );
  }
}
