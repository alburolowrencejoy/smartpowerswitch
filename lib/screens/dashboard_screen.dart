import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import '../theme/app_colors.dart';
import '../widgets/top_toast.dart';
import 'campus_map_screen.dart';
import 'automation_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _selectedIndex = 0;
  String _role = 'faculty';
  String _userName = '';
  String? _userUid;
  bool _roleLoaded = false;
  bool _compactMenuOpen = false;

  // Buildings loaded from Firebase
  List<Map<String, dynamic>> _buildings = [];

  double _totalKwh = 0;
  double _totalCostPhp = 0;
  double _monthlyKwh = 0.0;
  double _monthlyCostPhp = 0.0;
  double _electricityRate = 11.5;
  int _assignedDevices = 0;
  int _unassignedDevices = 0;
  Map<String, int> _buildingDeviceCounts = {};
  Map<String, double> _buildingEnergy = {};
  Map<String, double> _utilityTotals = {};
  String _analyticsRange = 'daily';
  String _trendChartType = 'line';
  List<Map<String, dynamic>> _historyData = [];

  StreamSubscription? _masterSub;
  StreamSubscription? _devicesSub;
  StreamSubscription? _rateSub;
  StreamSubscription? _historySub;
  StreamSubscription? _buildingsSub;

  bool _isPermissionDenied(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('permission-denied') ||
        text.contains('permission_denied');
  }

  Future<void> _cancelRealtimeSubs() async {
    await _masterSub?.cancel();
    await _devicesSub?.cancel();
    await _rateSub?.cancel();
    await _historySub?.cancel();
    await _buildingsSub?.cancel();
    _masterSub = _devicesSub = _rateSub = _historySub = _buildingsSub = null;
  }

  @override
  void dispose() {
    _cancelRealtimeSubs();
    super.dispose();
  }

  Future<void> _hydrateSessionFromAuth() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    _userUid = user.uid;

    try {
      final snap =
          await FirebaseDatabase.instance.ref('users/${user.uid}').get();
      final data = snap.value;
      if (data is! Map) return;

      final map = Map<String, dynamic>.from(data);
      final role = (map['role'] as String?) ?? 'faculty';
      final name =
          (map['name'] as String?) ?? user.email?.split('@').first ?? '';

      if (!mounted) return;
      setState(() {
        _role = role;
        _userName = name;
      });
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
      _listenToBuildings();
      _listenToMasterDevices();
      _listenToEnergyData();
      _listenToRate();
      _listenToHistory();
    }
  }

  // ── Listen to buildings from Firebase ─────────────────────────────────────
  void _listenToBuildings() {
    _buildingsSub =
        FirebaseDatabase.instance.ref('buildings').onValue.listen((event) {
      if (!mounted) return;
      final raw = event.snapshot.value;

      if (raw == null || raw is! Map) {
        debugPrint('[Buildings] Expected Map, got ${raw.runtimeType}: $raw');
        setState(() => _buildings = []);
        return;
      }

      try {
        final data = Map<String, dynamic>.from(raw);
        debugPrint('[Buildings] Got ${data.length} buildings');
        final List<Map<String, dynamic>> list = [];

        data.forEach((code, val) {
          if (val is! Map) {
            return;
          }
          final b = Map<String, dynamic>.from(val);
          list.add({
            'code': code,
            'name': (b['name'] ?? code).toString(),
            'floors': (b['floors'] ?? 1) as int,
          });
        });

        list.sort(
            (a, b) => (a['code'] as String).compareTo(b['code'] as String));
        setState(() => _buildings = list);
      } catch (e, st) {
        debugPrint('[Buildings] Exception: $e\n$st');
        setState(() => _buildings = []);
      }
    }, onError: (Object error) {
      debugPrint('[Buildings] Listen error: $error');
    });
  }

  void _listenToMasterDevices() {
    _masterSub =
        FirebaseDatabase.instance.ref('master_devices').onValue.listen((event) {
      if (!mounted) return;
      final raw = event.snapshot.value;
      if (raw == null) {
        setState(() {
          _assignedDevices = 0;
          _unassignedDevices = 0;
          _buildingDeviceCounts = {};
        });
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
      setState(() {
        _assignedDevices = assigned;
        _unassignedDevices = unassigned;
        _buildingDeviceCounts = bCounts;
      });
    }, onError: (Object error) {
      if (!mounted || _isPermissionDenied(error)) return;
    });
  }

  void _listenToEnergyData() {
    _devicesSub =
        FirebaseDatabase.instance.ref('devices').onValue.listen((event) {
      if (!mounted) return;
      final raw = event.snapshot.value;
      if (raw == null) {
        setState(() {
          _totalKwh = 0;
          _totalCostPhp = 0;
          _utilityTotals = {};
        });
        return;
      }
      final data = Map<String, dynamic>.from(raw as Map);
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
      setState(() {
        _totalKwh = totalKwh;
        _totalCostPhp = totalKwh * _electricityRate;
        _utilityTotals = uTotals;
      });
    }, onError: (Object error) {
      if (!mounted || _isPermissionDenied(error)) return;
    });
  }

  void _listenToRate() {
    _rateSub = FirebaseDatabase.instance
        .ref('settings/electricityRate')
        .onValue
        .listen((event) {
      if (!mounted) return;
      final rate = (event.snapshot.value as num?)?.toDouble() ?? 11.5;
      setState(() {
        _electricityRate = rate;
        _totalCostPhp = _totalKwh * rate;
      });
    }, onError: (Object error) {
      if (!mounted || _isPermissionDenied(error)) return;
    });
  }

  void _listenToHistory() {
    _historySub?.cancel();
    _historySub =
        FirebaseDatabase.instance.ref('history').onValue.listen((event) {
      if (!mounted) return;
      final raw = event.snapshot.value;
      if (raw == null) {
        setState(() {
          _historyData = [];
          _buildingEnergy = {};
        });
        return;
      }

      final root = Map<String, dynamic>.from(raw as Map);
      final data = _pickRangeNode(root, _analyticsRange);
      final List<Map<String, dynamic>> list = [];
      data.forEach((key, val) {
        if (val is! Map) return;
        final entry = Map<String, dynamic>.from(val);
        list.add({
          'label': key,
          'kwh': (entry['total_kwh'] ?? 0.0) as num,
          'cost': (entry['total_cost'] ?? 0.0) as num,
        });
      });
      list.sort((a, b) => a['label'].compareTo(b['label']));
      setState(() {
        _historyData = list;
        _buildingEnergy = _currentMonthBuildingEnergy(root);
        _updateMonthlyTotals(root);
      });
    }, onError: (Object error) {
      if (!mounted || _isPermissionDenied(error)) return;
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
    setState(() => _analyticsRange = range);
    _listenToHistory();
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

  double get _maxKwh => _historyData.isEmpty
      ? 1
      : _historyData.fold(
          0.0,
          (m, d) => (d['kwh'] as num).toDouble() > m
              ? (d['kwh'] as num).toDouble()
              : m);

  Future<void> _logout() async {
    await _cancelRealtimeSubs();
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
    if (value is num)
      return (value as num).toDouble().toStringAsFixed(decimals);
    return '0.${'0' * decimals}';
  }

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
                decoration: _inputDeco('Full Name', Icons.business),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: floorCtrl,
                keyboardType: TextInputType.number,
                decoration: _inputDeco('Number of Floors', Icons.layers),
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
                backgroundColor: AppColors.greenDark,
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
                  backgroundColor: AppColors.greenDark,
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
                    backgroundColor: AppColors.greenDark,
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
                                color: AppColors.greenMid.withAlpha(31)),
                          ),
                          child: Row(children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                  color: AppColors.greenPale,
                                  borderRadius: BorderRadius.circular(10)),
                              child: Center(
                                  child: Text(code,
                                      style: const TextStyle(
                                          fontFamily: 'Outfit',
                                          fontSize: 9,
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.greenDark))),
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
                                    color: AppColors.greenPale,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(Icons.edit_outlined,
                                      size: 18, color: AppColors.greenDark),
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
          borderSide: BorderSide(color: AppColors.greenMid.withAlpha(51))),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.greenMid.withAlpha(51))),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.greenMid)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Column(children: [
          _buildTopBar(),
          Expanded(
            child: IndexedStack(
              index: _selectedIndex,
              children: [
                _buildHomeTab(),
                CampusMapScreen(role: _role, showAppBar: false),
                _buildAnalyticsTab(),
                AutomationScreen(role: _role),
              ],
            ),
          ),
        ]),
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      decoration: const BoxDecoration(
        color: AppColors.greenDark,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = constraints.maxWidth < 430;
          return Row(children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                  color: AppColors.greenMid,
                  borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.bolt, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text('SmartPowerSwitch',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: 'Outfit',
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white)),
            ),
            if (!isCompact) ...[
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _role == 'admin'
                      ? AppColors.greenLight.withAlpha(51)
                      : Colors.white.withAlpha(26),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: _role == 'admin'
                          ? AppColors.greenLight.withAlpha(102)
                          : Colors.white.withAlpha(51)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(_role == 'admin' ? Icons.star : Icons.person,
                      size: 11,
                      color: _role == 'admin'
                          ? AppColors.greenLight
                          : Colors.white),
                  const SizedBox(width: 4),
                  Text(_role == 'admin' ? 'Admin' : 'Faculty',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: _role == 'admin'
                              ? AppColors.greenLight
                              : Colors.white)),
                ]),
              ),
              IconButton(
                  icon: const Icon(Icons.notifications_outlined,
                      color: Colors.white, size: 22),
                  onPressed: () =>
                      Navigator.pushNamed(context, '/notifications')),
              if (_role == 'admin')
                IconButton(
                    icon: const Icon(Icons.settings_outlined,
                        color: Colors.white, size: 22),
                    onPressed: () => Navigator.pushNamed(context, '/settings')),
              IconButton(
                  icon: const Icon(Icons.logout, color: Colors.white, size: 20),
                  onPressed: _logout),
            ] else
              PopupMenuButton<String>(
                color: const Color(0xFF0F5C31),
                surfaceTintColor: Colors.transparent,
                elevation: 12,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side:
                        BorderSide(color: AppColors.greenLight.withAlpha(140))),
                onOpened: () {
                  if (mounted) setState(() => _compactMenuOpen = true);
                },
                icon: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: _compactMenuOpen
                        ? AppColors.greenLight.withAlpha(46)
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
                onCanceled: () {
                  if (mounted) setState(() => _compactMenuOpen = false);
                },
                onSelected: (value) {
                  if (mounted) setState(() => _compactMenuOpen = false);
                  if (value == 'notifications') {
                    Navigator.pushNamed(context, '/notifications');
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
                  if (_role == 'admin')
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
          ]);
        },
      ),
    );
  }

  Widget _buildHomeTab() {
    final sortedBuildings = [..._buildings]..sort((a, b) {
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
                      color: AppColors.greenPale,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.edit_outlined,
                            size: 14, color: AppColors.greenDark),
                        SizedBox(width: 4),
                        Text(
                          'Edit',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppColors.greenDark,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              Text('${_buildings.length} buildings',
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textMuted)),
            ]),
            SizedBox(height: isCompact ? 10 : 12),
            if (_buildings.isEmpty)
              Container(
                padding: EdgeInsets.all(isCompact ? 16 : 20),
                decoration: BoxDecoration(
                  color: AppColors.cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.greenMid.withAlpha(31)),
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
                            foregroundColor: AppColors.greenDark),
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
        Text(_userName.isNotEmpty ? _userName : 'User',
            style: TextStyle(
                fontFamily: 'Outfit',
                fontSize: compact ? 19 : 22,
                fontWeight: FontWeight.w700,
                color: AppColors.textDark)),
      ])),
      Container(
        padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 10, vertical: compact ? 5 : 6),
        decoration: BoxDecoration(
            color: AppColors.greenPale,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.greenMid.withAlpha(60))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 7,
              height: 7,
              decoration: const BoxDecoration(
                  color: AppColors.greenMid, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          const Text('Live',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.greenDark)),
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
          gradient: const LinearGradient(
              colors: [AppColors.greenDark, Color(0xFF1E7A42)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
                color: AppColors.greenDark.withAlpha(77),
                blurRadius: 20,
                offset: const Offset(0, 8))
          ],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('This Month Energy Consumed',
              style: TextStyle(
                  fontSize: compact ? 11 : 12, color: const Color(0xB3C2EDD0))),
          SizedBox(height: compact ? 4 : 6),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(_safeFormatDouble(_monthlyKwh, 2),
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
                        color: AppColors.greenLight,
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
      SizedBox(height: compact ? 10 : 12),
      Row(children: [
        Expanded(
            child: _statCard('Today', '${_safeFormatDouble(_totalKwh, 1)} kWh',
                Icons.bolt, AppColors.greenMid,
                compact: compact)),
        SizedBox(width: compact ? 8 : 10),
        Expanded(
            child: _statCard('Online', '$_assignedDevices devices', Icons.wifi,
                AppColors.greenLight,
                compact: compact)),
        SizedBox(width: compact ? 8 : 10),
        Expanded(
            child: _statCard(
                'Status', 'Live', Icons.check_circle, AppColors.greenPale,
                textColor: AppColors.greenDark, compact: compact)),
      ]),
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
          style: TextStyle(
              fontSize: compact ? 9 : 10, color: const Color(0x99C2EDD0))),
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

  Widget _statCard(String label, String value, IconData icon, Color bg,
      {Color textColor = Colors.white, bool compact = false}) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 12, vertical: compact ? 12 : 14),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: compact ? 16 : 18, color: textColor.withAlpha(204)),
        SizedBox(height: compact ? 6 : 8),
        Text(value,
            style: TextStyle(
                fontFamily: 'Outfit',
                fontSize: compact ? 13 : 15,
                fontWeight: FontWeight.w700,
                color: textColor)),
        Text(label,
            style: TextStyle(
                fontSize: compact ? 9 : 10, color: textColor.withAlpha(179))),
      ]),
    );
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
            border: Border.all(color: AppColors.greenMid.withAlpha(31))),
        child: Row(children: [
          Container(
              width: compact ? 40 : 44,
              height: compact ? 40 : 44,
              decoration: BoxDecoration(
                  color: AppColors.greenPale,
                  borderRadius: BorderRadius.circular(12)),
              child: Center(
                  child: Text(code,
                      style: TextStyle(
                          fontFamily: 'Outfit',
                          fontSize: compact ? 9 : 10,
                          fontWeight: FontWeight.w700,
                          color: AppColors.greenDark)))),
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
            const SizedBox(height: 3),
            Text(
                '${_safeFormatDouble(_buildingEnergy[code] ?? 0, 1)} kWh this month',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: compact ? 9 : 10, color: AppColors.textMuted)),
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
                foregroundColor: AppColors.greenDark,
                side: const BorderSide(color: AppColors.greenMid, width: 1.5),
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
          color: AppColors.greenPale, borderRadius: BorderRadius.circular(12)),
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
                color: isSelected ? AppColors.greenDark : Colors.transparent,
                borderRadius: BorderRadius.circular(8)),
            child: Center(
                child: Text(r['label']!,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color:
                            isSelected ? Colors.white : AppColors.textMuted))),
          ),
        ));
      }).toList()),
    );
  }

  Widget _buildLineChart() {
    final canSwitchChart = _historyData.length > 1;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.greenMid.withAlpha(26))),
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
              decoration: const BoxDecoration(
                  color: AppColors.greenMid, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          const Text('Live',
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: AppColors.greenMid)),
        ]),
        const SizedBox(height: 20),
        _historyData.isEmpty
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
                        ? _BarChartPainter(
                            data: _historyData
                                .map((d) => (d['kwh'] as num).toDouble())
                                .toList(),
                            maxKwh: _maxKwh)
                        : _LineChartPainter(
                            data: _historyData
                                .map((d) => (d['kwh'] as num).toDouble())
                                .toList(),
                            maxKwh: _maxKwh),
                    child: Container())),
        if (_historyData.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(_historyData.first['label'],
                style:
                    const TextStyle(fontSize: 9, color: AppColors.textMuted)),
            if (_historyData.length > 2)
              Text(_historyData[_historyData.length ~/ 2]['label'],
                  style:
                      const TextStyle(fontSize: 9, color: AppColors.textMuted)),
            Text(_historyData.last['label'],
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
          color: isSelected ? AppColors.greenDark : AppColors.greenPale,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: isSelected
                  ? AppColors.greenDark
                  : AppColors.greenMid.withAlpha(80)),
        ),
        child: Icon(
          icon,
          size: 14,
          color: isSelected ? Colors.white : AppColors.greenDark,
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
          border: Border.all(color: AppColors.greenMid.withAlpha(26))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Device Status',
            style: TextStyle(
                fontFamily: 'Outfit',
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textDark)),
        const SizedBox(height: 16),
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
    final Map<String, Color> colors = {
      'Lights': AppColors.greenMid,
      'Outlets': const Color(0xFFE8922A),
      'AC': const Color(0xFF2196F3)
    };
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.greenMid.withAlpha(26))),
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
          final color = colors[e.key] ?? AppColors.greenMid;
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
                              style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.greenDark)),
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
    final List<Color> barColors = [
      AppColors.greenDark,
      AppColors.greenMid,
      AppColors.greenLight,
      const Color(0xFF2196F3),
      const Color(0xFFE8922A)
    ];
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.greenMid.withAlpha(26))),
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
                        color:
                            i == 0 ? AppColors.greenDark : AppColors.greenPale,
                        shape: BoxShape.circle),
                    child: Center(
                        child: Text('${i + 1}',
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: i == 0
                                    ? Colors.white
                                    : AppColors.greenDark)))),
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
                                style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.greenDark)),
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

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(color: Colors.white, boxShadow: [
        BoxShadow(
            color: Colors.black.withAlpha(15),
            blurRadius: 16,
            offset: const Offset(0, -4))
      ]),
      child: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (i) => setState(() => _selectedIndex = i),
        backgroundColor: Colors.white,
        selectedItemColor: AppColors.greenDark,
        unselectedItemColor: AppColors.textMuted,
        selectedLabelStyle:
            const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 11),
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
              icon: Icon(Icons.dashboard_outlined),
              activeIcon: Icon(Icons.dashboard),
              label: 'Dashboard'),
          BottomNavigationBarItem(
              icon: Icon(Icons.map_outlined),
              activeIcon: Icon(Icons.map),
              label: 'Map'),
          BottomNavigationBarItem(
              icon: Icon(Icons.bar_chart_outlined),
              activeIcon: Icon(Icons.bar_chart),
              label: 'Analytics'),
          BottomNavigationBarItem(
              icon: Icon(Icons.schedule_outlined),
              activeIcon: Icon(Icons.schedule),
              label: 'Automation'),
        ],
      ),
    );
  }
}

class _LineChartPainter extends CustomPainter {
  final List<double> data;
  final double maxKwh;
  _LineChartPainter({required this.data, required this.maxKwh});

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final safeMaxKwh = maxKwh <= 0 ? 1.0 : maxKwh;
    final linePaint = Paint()
      ..color = AppColors.greenMid
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fillPaint = Paint()
      ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.greenMid.withAlpha(80),
            AppColors.greenMid.withAlpha(0)
          ]).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..style = PaintingStyle.fill;
    final stepX = size.width / (data.length - 1);
    Offset off(int i) => Offset(
        i * stepX,
        (size.height - (data[i] / safeMaxKwh) * size.height)
            .clamp(0.0, size.height));
    final gridPaint = Paint()
      ..color = AppColors.greenMid.withAlpha(20)
      ..strokeWidth = 1;
    for (int i = 1; i < 4; i++) {
      canvas.drawLine(Offset(0, size.height * i / 4),
          Offset(size.width, size.height * i / 4), gridPaint);
    }
    final fillPath = Path()
      ..moveTo(0, size.height)
      ..lineTo(off(0).dx, off(0).dy);
    for (int i = 1; i < data.length; i++) {
      final p = off(i - 1);
      final c = off(i);
      fillPath.cubicTo(
          (p.dx + c.dx) / 2, p.dy, (p.dx + c.dx) / 2, c.dy, c.dx, c.dy);
    }
    fillPath
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(fillPath, fillPaint);
    final linePath = Path()..moveTo(off(0).dx, off(0).dy);
    for (int i = 1; i < data.length; i++) {
      final p = off(i - 1);
      final c = off(i);
      linePath.cubicTo(
          (p.dx + c.dx) / 2, p.dy, (p.dx + c.dx) / 2, c.dy, c.dx, c.dy);
    }
    canvas.drawPath(linePath, linePaint);
    for (int i = 0; i < data.length; i++) {
      canvas.drawCircle(
          off(i),
          3.5,
          Paint()
            ..color = AppColors.greenDark
            ..style = PaintingStyle.fill);
      canvas.drawCircle(
          off(i),
          3.5,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(_LineChartPainter old) =>
      old.data != data || old.maxKwh != maxKwh;
}

class _BarChartPainter extends CustomPainter {
  final List<double> data;
  final double maxKwh;
  _BarChartPainter({required this.data, required this.maxKwh});

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;
    final safeMaxKwh = maxKwh <= 0 ? 1.0 : maxKwh;
    final gridPaint = Paint()
      ..color = AppColors.greenMid.withAlpha(20)
      ..strokeWidth = 1;

    for (int i = 1; i < 4; i++) {
      canvas.drawLine(Offset(0, size.height * i / 4),
          Offset(size.width, size.height * i / 4), gridPaint);
    }

    final slotWidth = size.width / data.length;
    final barWidth = (slotWidth * 0.62).clamp(2.0, 18.0);
    final barPaint = Paint()..color = AppColors.greenMid;

    for (int i = 0; i < data.length; i++) {
      final normalized = (data[i] / safeMaxKwh).clamp(0.0, 1.0);
      final barHeight = normalized * size.height;
      final left = i * slotWidth + (slotWidth - barWidth) / 2;
      final top = size.height - barHeight;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, barWidth, barHeight),
        const Radius.circular(4),
      );
      canvas.drawRRect(rect, barPaint);
    }
  }

  @override
  bool shouldRepaint(_BarChartPainter old) =>
      old.data != data || old.maxKwh != maxKwh;
}
