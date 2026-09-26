import 'dart:async';
import 'dart:math' as math;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:rxdart/rxdart.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_fonts.dart';
import '../../theme/app_text_styles.dart';
import '../../theme/institute_colors.dart';
import '../../services/history_clock.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_segmented_control.dart';
import '../../widgets/app_top_bar.dart';
import '../../widgets/outline_icon_box.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';

/// The mobile "Devices → Map" screen (handoff §4.3/§5/§8), reusing the exact
/// Firebase data model and Approximate/Precise logic already proven by
/// `lib/screens/web/campus_map_screen_web.dart` (read-only reference this
/// phase -- NOT imported here, since the web screen owns its own admin
/// zone-editing UI that this phase intentionally does not port to phone; see
/// the class doc below for that trade-off).
///
/// Two modes, mirroring the web's Approximate/Precise:
/// - **Buildings** ("Approximate"): one translucent zone per building
///   (`hotspots/{code}`, x/y/w/h fractions of the campus image), colored by
///   that building's *this month* kWh (thresholds: high >= 100, mid 50-100,
///   low < 50 -- same as `dashboard_screen.dart`'s Building Load section).
/// - **Devices** ("Precise"): dashed zone outlines + one dot per device,
///   colored by that device's *today* kWh (high >= 2, mid 1-2, low < 1,
///   offline = grey). A device without a saved position under
///   `hotspots/{code}/devices/{id}` is grid-spread inside its zone using the
///   same column/row formula as the web screen's `_layout`.
///
/// An institute admin never sees the mode toggle: per the redesign's ground
/// truth (`smartswitch-mobile-preview.html`'s `mapView`, which forces
/// `precise = scopeCode ? true : MAP.mode === 'precise'`), a scoped session
/// always renders Devices/precise -- a single colored zone blob would be
/// redundant when there's only ever one building in view. Their map is also
/// cropped to that building's zone with a flat 6% padding (of the whole
/// image, matching the preview's `pad = 0.06` -- NOT 6% of the zone's own
/// size) and has no zoom controls or pan (the preview's cropped `.map-vp` is
/// `overflow:hidden`, not `overflow:auto`), while a campus admin's view zooms
/// 1x-3x with drag-to-pan once zoomed in.
///
/// Role/institute are self-hydrated from the signed-in user's own
/// `users/{uid}` record (mirroring `HistoryScreen`'s `_hydrateSessionFromAuth`
/// pattern) rather than trusting a caller-supplied `role`/institute pair --
/// this screen is reachable both embedded (`dashboard_screen.dart`'s Devices
/// tab, which already knows the right role) and as the standalone `/map`
/// route in `main.dart` (which passes nothing at all today). The `role`
/// constructor parameter is kept only as the initial paint's best guess
/// before hydration completes, exactly like the old file's default.
///
/// Trade-off flagged for the user: the OLD version of this file let a campus
/// admin add/move/resize/remove hotspot zones directly on the phone (an
/// "Edit Zones" toggle with drag handles). Nothing in the redesign handoff
/// (§4.3/§8) asks for that on phone, and precise corner-drag geometry editing
/// is a poor fit for a touchscreen anyway -- that capability still exists,
/// unchanged, on the desktop web map (`campus_map_screen_web.dart`'s
/// "Edit zones"/"Edit positions" toggle, not touched by this phase). If a
/// campus admin still needs to place a *new* building's zone from their
/// phone, that's now a gap -- flagged in the handoff report, not silently
/// dropped.
class CampusMapScreen extends StatefulWidget {
  /// Best-guess role before self-hydration completes (see class doc). Not
  /// trusted afterwards.
  final String role;

  /// Whether this screen owns its own [AppTopBar] + [Scaffold] (the
  /// standalone `/map` route) or renders bare content to slot into an
  /// existing shell's tab body (`dashboard_screen.dart`'s Devices tab,
  /// which already shows a "Devices" top bar above the List|Map toggle).
  final bool showAppBar;

  /// When non-null, called instead of `Navigator.pushNamed(context,
  /// '/building', ...)` on "View building" -- lets an embedding shell (e.g.
  /// a future desktop-in-shell host) show the building in place instead of
  /// pushing a full-screen route. Mobile never passes this today.
  final void Function(String buildingCode, String buildingName, int floors)?
      onBuildingTap;

  const CampusMapScreen({
    super.key,
    this.role = 'faculty',
    this.showAppBar = false,
    this.onBuildingTap,
  });

  @override
  State<CampusMapScreen> createState() => _CampusMapScreenState();
}

// ─── Energy level (handoff §8): building = this month's kWh, device =
// today's kWh -- exact thresholds/colors from campus_map_screen_web.dart. ──

enum _Level { low, mid, high, off }

const Map<_Level, Color> _levelColor = {
  _Level.high: AppColors.error, // #D64A4A
  _Level.mid: AppColors.warning, // #E8922A
  _Level.low: AppColors.success, // green
  _Level.off: AppColors.offline, // #9E9E9E
};

_Level _buildingLevel(double kwh) =>
    kwh >= 100 ? _Level.high : (kwh >= 50 ? _Level.mid : _Level.low);

_Level _deviceLevel(bool online, double kwh) => !online
    ? _Level.off
    : kwh >= 2
        ? _Level.high
        : (kwh >= 1 ? _Level.mid : _Level.low);

String _levelLabel(_Level l) => switch (l) {
      _Level.high => 'HIGH',
      _Level.mid => 'MID',
      _Level.low => 'LOW',
      _Level.off => 'OFFLINE',
    };

/// pill colors, matching preview `.pill.ok/.warn/.err/.mute`.
(Color bg, Color fg) _pillColors(_Level l) => switch (l) {
      _Level.high => (AppColors.errorBg, AppColors.errorText),
      _Level.mid => (AppColors.warningBg, AppColors.warningText),
      _Level.low => (const Color(0xFFE6F5EB), AppColors.successText),
      _Level.off => (const Color(0xFFEEF2EF), AppColors.inkMid),
    };

IconData _utilityIcon(String type) => switch (type.toLowerCase()) {
      'lights' => Icons.lightbulb_outline,
      'outlets' => Icons.electrical_services,
      'ac' => Icons.ac_unit,
      _ => Icons.memory_outlined,
    };

/// "Aircon" for `ac` (preview wording), otherwise the raw utility string.
String _deviceLabel(String utility) =>
    utility.toLowerCase() == 'ac' ? 'Aircon' : (utility.isEmpty ? 'Device' : utility);

double _num(Object? v) =>
    v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0.0;

/// Intrinsic campus map image size (`assets/images/campus_map.png`).
const double _imgW = 354, _imgH = 496;

// ─── Data models ────────────────────────────────────────────────────────────

class _Zone {
  final String code;
  double x, y, w, h; // fractions (0-1) of the campus image
  final Map<String, Offset> devicePositions; // deviceId -> fraction of zone

  _Zone(this.code, this.x, this.y, this.w, this.h, this.devicePositions);
}

class _MapDevice {
  final String id;
  final String building;
  final String room;
  final int floor;
  final String utility;
  final double kwh; // today's energy
  final bool online;
  final bool relay;
  final double power;

  const _MapDevice({
    required this.id,
    required this.building,
    required this.room,
    required this.floor,
    required this.utility,
    required this.kwh,
    required this.online,
    required this.relay,
    required this.power,
  });
}

/// A fraction-space rectangle (0-1 of the campus image).
class _Box {
  final double x, y, w, h;
  const _Box(this.x, this.y, this.w, this.h);
}

class _CampusMapScreenState extends State<CampusMapScreen> {
  // ── Session (self-hydrated; see class doc) ─────────────────────────────
  late String _role = widget.role;
  String? _institute;

  bool get _isInstituteAdmin => _role == 'institute_admin';

  /// Non-null only for an institute admin with an institute assigned --
  /// forces the whole screen into a single-building, precise-only, cropped
  /// view (handoff §5/§8).
  String? get _lockCode {
    if (!_isInstituteAdmin) return null;
    final code = _institute?.trim();
    if (code == null || code.isEmpty) return null;
    // Resolve to the stored key case-insensitively, so a user record saying
    // 'ic' still finds the 'IC' zone, building and devices.
    final upper = code.toUpperCase();
    for (final k in [..._zones.keys, ..._buildingsInfo.keys]) {
      if (k.toUpperCase() == upper) return k;
    }
    return upper;
  }

  /// Where each building sits on the campus image when `hotspots/{code}`
  /// hasn't been placed yet (handoff §8's by-eye estimates). Only used so an
  /// institute admin's cropped map still has something to zoom to; the
  /// real `hotspots` zone always wins once a campus admin places it.
  static final _defaultZones = <String, List<double>>{
    'IC': [.41, .29, .20, .10],
    'ILEGG': [.68, .37, .31, .30],
    'ITED': [.84, .07, .16, .27],
    'IAAS': [.66, .85, .33, .10],
    'ADMIN': [.12, .77, .46, .10],
  };

  /// The locked institute's zone: the saved hotspot, else its default.
  _Zone? get _lockZone {
    final lock = _lockCode;
    if (lock == null) return null;
    final saved = _zones[lock];
    if (saved != null) return saved;
    final d = _defaultZones[lock.toUpperCase()];
    return d == null ? null : _Zone(lock, d[0], d[1], d[2], d[3], const {});
  }

  InstitutePalette get _palette =>
      InstituteTheme.resolve(_role, _institute).palette;

  Future<void> _hydrateSession() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final snap =
          await FirebaseDatabase.instance.ref('users/${user.uid}').get();
      final data = snap.value;
      if (data is! Map) return;
      final map = Map<String, dynamic>.from(data);
      if (!mounted) return;
      setState(() {
        _role = (map['role'] as String?) ?? _role;
        _institute = (map['institute'] as String?)?.trim();
      });
    } catch (_) {
      // Keep the constructor-supplied role if hydration fails.
    }
  }

  // ── Firebase-backed data ────────────────────────────────────────────────
  Map<String, Map<String, dynamic>> _buildingsInfo = {}; // code -> name/floors
  List<_MapDevice> _devices = [];
  Map<String, double> _monthKwh = {}; // code -> this month's kWh
  Map<String, _Zone> _zones = {};

  StreamSubscription? _combinedSub;
  bool _isLoading = true;
  String? _errorText;
  Timer? _loadTimeoutTimer;
  bool _postLoadErrorNotified = false;

  // ── Mode / selection / zoom-pan state ───────────────────────────────────
  bool _devicesModeChoice = false; // user's Buildings(false)/Devices(true) pick
  bool get _precise => _lockCode != null ? true : _devicesModeChoice;

  String? _selectedBuilding;
  String? _selectedDevice;

  double _zoom = 1.0; // 1x-3x, campus admin only
  Offset _pan = Offset.zero; // fraction offset within the current box
  Size _viewportSize = Size.zero; // cached for interpreting drag deltas

  @override
  void initState() {
    super.initState();
    _hydrateSession();
    _listen();
  }

  @override
  void dispose() {
    _combinedSub?.cancel();
    _loadTimeoutTimer?.cancel();
    super.dispose();
  }

  void _retryLoad() {
    _combinedSub?.cancel();
    _loadTimeoutTimer?.cancel();
    setState(() {
      _errorText = null;
      _isLoading = true;
      _postLoadErrorNotified = false;
    });
    _listen();
  }

  String _monthKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}';

  bool _isPermissionDenied(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('permission-denied') || text.contains('permission_denied');
  }

  // Same 4 Firebase paths, same combined-listener shape as the web screen
  // and the old version of this file (devices, this month's building
  // history, buildings, hotspots) -- a transient null on any one path can't
  // blank out data already shown this session.
  void _listen() {
    _loadTimeoutTimer?.cancel();
    _loadTimeoutTimer = Timer(const Duration(seconds: 15), () {
      if (!mounted || !_isLoading) return;
      setState(() {
        _isLoading = false;
        _errorText =
            'Taking too long to load the campus map. Check your connection.';
      });
    });

    final monthKey = _monthKey(HistoryClock.instance.now());
    _combinedSub = Rx.combineLatestList<DatabaseEvent>([
      FirebaseDatabase.instance.ref('devices').onValue,
      FirebaseDatabase.instance
          .ref('history/monthly/$monthKey/buildings')
          .onValue,
      FirebaseDatabase.instance.ref('buildings').onValue,
      FirebaseDatabase.instance.ref('hotspots').onValue,
    ]).listen((events) {
      if (!mounted) return;
      _loadTimeoutTimer?.cancel();
      setState(() {
        _applyBuildings(events[2].snapshot.value);
        _applyDevices(events[0].snapshot.value);
        _applyHistory(events[1].snapshot.value);
        _applyZones(events[3].snapshot.value);
        _isLoading = false;
        _errorText = null;
        _postLoadErrorNotified = false;
      });
    }, onError: (Object error) {
      if (!mounted) return;
      debugPrint('[CampusMap] Combined listen error: $error');
      _loadTimeoutTimer?.cancel();
      if (_isLoading) {
        setState(() {
          _isLoading = false;
          _errorText = _isPermissionDenied(error)
              ? 'You do not have permission to view the campus map.'
              : 'Failed to load the campus map.';
        });
      } else if (!_postLoadErrorNotified) {
        _postLoadErrorNotified = true;
        TopToast.show(context, 'Lost connection to live map data.', isError: true);
      }
    });
  }

  void _applyBuildings(Object? raw) {
    if (raw is! Map) {
      if (_isLoading) _buildingsInfo = {};
      return;
    }
    final data = Map<String, dynamic>.from(raw);
    final info = <String, Map<String, dynamic>>{};
    data.forEach((code, val) {
      if (val is! Map) return;
      final b = Map<String, dynamic>.from(val);
      info[code.toString()] = {
        'name': (b['name'] ?? code).toString(),
        'floors': int.tryParse('${b['floors'] ?? 1}') ?? 1,
      };
    });
    _buildingsInfo = info;
  }

  void _applyDevices(Object? raw) {
    if (raw is! Map) {
      if (_isLoading) _devices = [];
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final data = Map<String, dynamic>.from(raw);
    final list = <_MapDevice>[];
    data.forEach((id, val) {
      if (val is! Map) return;
      final d = Map<String, dynamic>.from(val);
      final building = (d['building'] ?? '').toString();
      if (building.isEmpty) return;
      final lastSeen = _num(d['last_seen']);
      final online = lastSeen > 0
          ? now - lastSeen < 2 * 60 * 1000
          : (d['status'] ?? '') == 'online';
      list.add(_MapDevice(
        id: id.toString(),
        building: building,
        room: (d['room'] ?? '').toString(),
        floor: int.tryParse('${d['floor'] ?? 1}') ?? 1,
        utility: (d['utility'] ?? '').toString(),
        kwh: _num(d['kwh']),
        online: online,
        relay: d['relay'] == true,
        power: _num(d['power']),
      ));
    });
    list.sort((a, b) => a.id.compareTo(b.id));
    _devices = list;
  }

  void _applyHistory(Object? raw) {
    final totals = <String, double>{};
    for (final d in _devices) {
      totals[d.building] = (totals[d.building] ?? 0) + d.kwh;
    }
    if (raw is Map) {
      raw.forEach((code, v) {
        totals[code.toString()] = v is Map ? _num(v['kwh']) : _num(v);
      });
    }
    _monthKwh = totals;
  }

  void _applyZones(Object? raw) {
    if (raw is! Map) {
      _zones = {};
      return;
    }
    final zones = <String, _Zone>{};
    raw.forEach((code, val) {
      if (val is! Map) return;
      final v = Map<String, dynamic>.from(val);
      final positions = <String, Offset>{};
      final devs = v['devices'];
      if (devs is Map) {
        devs.forEach((id, p) {
          if (p is Map) {
            positions[id.toString()] = Offset(
              _num(p['x']).clamp(0.0, 1.0),
              _num(p['y']).clamp(0.0, 1.0),
            );
          }
        });
      }
      zones[code.toString()] = _Zone(
        code.toString(),
        v['x'] == null ? 0.1 : _num(v['x']),
        v['y'] == null ? 0.1 : _num(v['y']),
        v['w'] == null ? 0.2 : _num(v['w']),
        v['h'] == null ? 0.1 : _num(v['h']),
        positions,
      );
    });
    _zones = zones;
  }

  // ── Derived helpers ─────────────────────────────────────────────────────

  String _buildingName(String code) =>
      (_buildingsInfo[code]?['name'] as String?) ?? code;

  int _buildingFloors(String code) =>
      (_buildingsInfo[code]?['floors'] as int?) ?? 1;

  List<_MapDevice> get _scopedDevices {
    final lock = _lockCode;
    return lock == null ? _devices : _devices.where((d) => d.building == lock).toList();
  }

  /// Where each device of [zone] sits inside it (0-1 of the zone): its saved
  /// position, or an even grid over the zone for the rest -- identical
  /// column/row formula to the web screen's `_layout`, using the image's
  /// intrinsic aspect ratio (the ratio is all that matters, so the actual
  /// rendered pixel size doesn't need to be threaded in here).
  Map<String, Offset> _layoutDots(_Zone zone, List<_MapDevice> devsInBuilding) {
    final unplaced =
        devsInBuilding.where((d) => !zone.devicePositions.containsKey(d.id)).toList();
    final out = <String, Offset>{
      for (final d in devsInBuilding)
        if (zone.devicePositions.containsKey(d.id)) d.id: zone.devicePositions[d.id]!,
    };
    final n = unplaced.length;
    if (n > 0) {
      final pw = math.max(1.0, zone.w * _imgW);
      final ph = math.max(1.0, zone.h * _imgH);
      final cols = math.max(1, math.min(n, (math.sqrt(n * pw / ph)).round()));
      final rows = (n / cols).ceil();
      for (var i = 0; i < n; i++) {
        out[unplaced[i].id] = Offset((i % cols + 0.5) / cols, (i ~/ cols + 0.5) / rows);
      }
    }
    return out;
  }

  /// The visible fraction-space box: the whole image for a campus admin, or
  /// the locked building's zone padded by a flat 6% of the image on each
  /// side (handoff §8 / preview `mapView`'s `pad = 0.06`) for an institute
  /// admin. Falls back to the whole image if their zone doesn't exist yet.
  _Box get _box {
    final lock = _lockCode;
    if (lock != null) {
      final z = _lockZone;
      if (z != null) {
        const pad = 0.06;
        final bx = math.max(0.0, z.x - pad);
        final by = math.max(0.0, z.y - pad);
        final bw = math.min(1.0, z.x + z.w + pad) - bx;
        final bh = math.min(1.0, z.y + z.h + pad) - by;
        return _Box(bx, by, bw, bh);
      }
    }
    return const _Box(0, 0, 1, 1);
  }

  void _clampPan() {
    final box = _box;
    final visibleW = box.w / _zoom;
    final visibleH = box.h / _zoom;
    _pan = Offset(
      _pan.dx.clamp(0.0, math.max(0.0, box.w - visibleW)),
      _pan.dy.clamp(0.0, math.max(0.0, box.h - visibleH)),
    );
  }

  void _zoomIn() {
    if (_lockCode != null) return; // no zoom UI for a scoped session
    setState(() {
      _zoom = (_zoom + 0.5).clamp(1.0, 3.0);
      _clampPan();
    });
  }

  void _zoomOut() {
    if (_lockCode != null) return;
    setState(() {
      _zoom = (_zoom - 0.5).clamp(1.0, 3.0);
      _clampPan();
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (_lockCode != null || _zoom <= 1.0) return;
    final box = _box;
    final visibleW = box.w / _zoom;
    final visibleH = box.h / _zoom;
    if (_viewportSize.width <= 0 || _viewportSize.height <= 0) return;
    final scaleX = _viewportSize.width / visibleW;
    final scaleY = _viewportSize.height / visibleH;
    setState(() {
      _pan = Offset(
        (_pan.dx - d.delta.dx / scaleX)
            .clamp(0.0, math.max(0.0, box.w - visibleW)),
        (_pan.dy - d.delta.dy / scaleY)
            .clamp(0.0, math.max(0.0, box.h - visibleH)),
      );
    });
  }

  void _dismissSelection() {
    if (_selectedBuilding == null && _selectedDevice == null) return;
    setState(() {
      _selectedBuilding = null;
      _selectedDevice = null;
    });
  }

  void _onModeChanged(int i) {
    setState(() {
      _devicesModeChoice = i == 1;
      _selectedBuilding = null;
      _selectedDevice = null;
    });
  }

  void _onZoneTap(String code) {
    if (_precise) return; // dashed zones aren't tappable in Devices mode
    setState(() {
      _selectedDevice = null;
      _selectedBuilding = _selectedBuilding == code ? null : code;
    });
  }

  void _onDotTap(String id) {
    setState(() {
      _selectedBuilding = null;
      _selectedDevice = _selectedDevice == id ? null : id;
    });
  }

  void _openBuilding(String code) {
    final name = _buildingName(code);
    final floors = _buildingFloors(code);
    if (widget.onBuildingTap != null) {
      widget.onBuildingTap!(code, name, floors);
      return;
    }
    Navigator.pushNamed(context, '/building', arguments: {
      'buildingCode': code,
      'buildingName': name,
      'floors': floors,
      'role': _role,
    });
  }

  void _openDevice(_MapDevice d) {
    Navigator.pushNamed(context, '/device', arguments: {
      'deviceId': d.id,
      'utility': d.utility,
      'building': d.building,
      'room': d.room.isEmpty ? 'unknown' : d.room,
      'floor': d.floor,
      'role': _role,
    });
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(_role, _institute)],
      ),
      child: widget.showAppBar
          ? Scaffold(
              backgroundColor: Colors.white,
              body: SafeArea(
                child: Column(children: [
                  AppTopBar(
                    title: 'Campus Map',
                    subtitle: _lockCode != null
                        ? '${_buildingName(_lockCode!)} · $_lockCode'
                        : 'Buildings and devices by energy use',
                    variant: AppTopBarVariant.small,
                    showBackButton: true,
                    showInstituteLine: _lockCode != null,
                  ),
                  Expanded(child: _buildBody()),
                ]),
              ),
            )
          : _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_errorText != null) return _buildError();
    return ScreenSkeleton(
      isLoading: _isLoading,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_lockCode == null) ...[
            AppSegmentedControl(
              palette: _palette,
              segments: const [
                AppSegment(label: 'Buildings'),
                AppSegment(label: 'Devices'),
              ],
              selectedIndex: _devicesModeChoice ? 1 : 0,
              onChanged: _onModeChanged,
            ),
            const SizedBox(height: 12),
          ],
          _mapCard(),
          const SizedBox(height: 10),
          _legend(),
          const SizedBox(height: 16),
          _panel(),
        ]),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          OutlineIconBox(icon: Icons.map_outlined, size: 64, iconSize: 30, palette: _palette),
          const SizedBox(height: 16),
          Text('Cannot load campus map',
              style: AppTextStyles.title.copyWith(color: AppColors.ink)),
          const SizedBox(height: 8),
          Text(_errorText ?? 'Something went wrong.',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
          const SizedBox(height: 16),
          AppOutlineButton(label: 'Retry', icon: Icons.refresh, onPressed: _retryLoad, palette: _palette),
        ]),
      ),
    );
  }

  // ── Map card ─────────────────────────────────────────────────────────────

  Widget _mapCard() {
    final box = _box;
    final aspectRatio = (box.w * _imgW) / (box.h * _imgH);
    final zoomable = _lockCode == null;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFE9EFE9),
        border: Border.all(color: _palette.line),
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(children: [
        AspectRatio(
          aspectRatio: aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : _imgW / _imgH,
          child: LayoutBuilder(builder: (context, constraints) {
            _viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
            final visibleW = box.w / _zoom;
            final visibleH = box.h / _zoom;
            final visibleX = (box.x + _pan.dx).clamp(box.x, math.max(box.x, box.x + box.w - visibleW));
            final visibleY = (box.y + _pan.dy).clamp(box.y, math.max(box.y, box.y + box.h - visibleH));
            final scaleX = visibleW > 0 ? constraints.maxWidth / visibleW : 0.0;
            final scaleY = visibleH > 0 ? constraints.maxHeight / visibleH : 0.0;

            Offset toPx(double fx, double fy) =>
                Offset((fx - visibleX) * scaleX, (fy - visibleY) * scaleY);

            final lockZone = _lockZone;
            final zones = _lockCode != null
                ? [if (lockZone != null) lockZone]
                : _zones.values.toList();

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _dismissSelection,
              onPanUpdate: zoomable ? _onPanUpdate : null,
              child: ClipRect(
                child: Stack(children: [
                  Positioned(
                    left: toPx(0, 0).dx,
                    top: toPx(0, 0).dy,
                    width: scaleX,
                    height: scaleY,
                    child: Image.asset('assets/images/campus_map.png', fit: BoxFit.fill),
                  ),
                  for (final zone in zones)
                    _zoneWidget(zone, toPx, scaleX, scaleY),
                ]),
              ),
            );
          }),
        ),
        if (zoomable)
          Positioned(
            right: 8,
            bottom: 8,
            child: Column(children: [
              _zoomButton(Icons.add, _zoomIn),
              const SizedBox(height: 6),
              _zoomButton(Icons.remove, _zoomOut),
            ]),
          ),
      ]),
    );
  }

  Widget _zoomButton(IconData icon, VoidCallback onTap) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _palette.line),
          ),
          child: Icon(icon, size: 20, color: AppColors.ink),
        ),
      ),
    );
  }

  Widget _zoneWidget(_Zone zone, Offset Function(double, double) toPx, double scaleX, double scaleY) {
    final topLeft = toPx(zone.x, zone.y);
    final size = Size(zone.w * scaleX, zone.h * scaleY);
    final devsInBuilding = _devices.where((d) => d.building == zone.code).toList();

    if (_precise) {
      final layout = _layoutDots(zone, devsInBuilding);
      const dot = 14.0;
      return Positioned(
        left: topLeft.dx,
        top: topLeft.dy,
        width: size.width,
        height: size.height,
        child: Stack(clipBehavior: Clip.none, children: [
          IgnorePointer(
            child: CustomPaint(
              size: size,
              painter: _DashedRectPainter(color: Colors.white.withAlpha(230)),
            ),
          ),
          Positioned(
            left: 4,
            top: 4,
            child: _zoneLabel(zone.code),
          ),
          for (final d in devsInBuilding)
            if (layout[d.id] != null)
              Positioned(
                left: layout[d.id]!.dx * size.width - dot / 2,
                top: layout[d.id]!.dy * size.height - dot / 2,
                width: dot,
                height: dot,
                child: _dotWidget(d),
              ),
        ]),
      );
    }

    final level = _buildingLevel(_monthKwh[zone.code] ?? 0);
    final color = _levelColor[level]!;
    final selected = _selectedBuilding == zone.code;
    return Positioned(
      left: topLeft.dx,
      top: topLeft.dy,
      width: size.width,
      height: size.height,
      child: GestureDetector(
        onTap: () => _onZoneTap(zone.code),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: color.withAlpha(selected ? 120 : 60),
            border: Border.all(color: color, width: selected ? 3 : 1.5),
            borderRadius: BorderRadius.circular(6),
            boxShadow: selected
                ? const [BoxShadow(color: Colors.white, blurRadius: 0, spreadRadius: 3)]
                : null,
          ),
          child: Align(alignment: Alignment.topLeft, child: Padding(
            padding: const EdgeInsets.all(4),
            child: _zoneLabel(zone.code),
          )),
        ),
      ),
    );
  }

  Widget _zoneLabel(String code) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 2)],
      ),
      child: Text(code,
          style: const TextStyle(
              fontFamily: AppFonts.family,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppColors.ink)),
    );
  }

  Widget _dotWidget(_MapDevice d) {
    final level = _deviceLevel(d.online, d.kwh);
    final color = _levelColor[level]!;
    final selected = _selectedDevice == d.id;
    final size = selected ? 20.0 : 14.0;
    return GestureDetector(
      onTap: () => _onDotTap(d.id),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: selected ? 3 : 2),
          boxShadow: [
            BoxShadow(color: Colors.black.withAlpha(selected ? 90 : 50), blurRadius: 4),
          ],
        ),
      ),
    );
  }

  // ── Legend (handoff §8, exact web wording) ──────────────────────────────

  Widget _legend() {
    final items = _precise
        ? const [_Level.low, _Level.mid, _Level.high, _Level.off]
        : const [_Level.low, _Level.mid, _Level.high];
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: double.infinity,
          child: Text(
            _precise ? "Today's kWh per device:" : "This month's kWh:",
            style: AppTextStyles.caption.copyWith(color: AppColors.inkMid),
          ),
        ),
        for (final l in items)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: _levelColor[l], shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
            Text(
              _precise
                  ? switch (l) {
                      _Level.low => 'Low (<1)',
                      _Level.mid => 'Mid (1-2)',
                      _Level.high => 'High (>=2)',
                      _Level.off => 'Offline',
                    }
                  : switch (l) {
                      _Level.low => 'Low (<50)',
                      _Level.mid => 'Mid (50-100)',
                      _ => 'High (>=100)',
                    },
              style: AppTextStyles.caption.copyWith(color: AppColors.ink),
            ),
          ]),
      ],
    );
  }

  // ── Detail panel ─────────────────────────────────────────────────────────

  Widget _panel() {
    if (_precise && _selectedDevice != null) {
      final matches = _devices.where((x) => x.id == _selectedDevice);
      return matches.isEmpty ? _emptyPanel() : _deviceCard(matches.first);
    }
    if (!_precise && _selectedBuilding != null) {
      return _buildingCard(_selectedBuilding!);
    }
    return _emptyPanel();
  }

  BoxDecoration get _panelDecoration => BoxDecoration(
        border: Border.all(color: _palette.line),
        borderRadius: BorderRadius.circular(16),
      );

  Widget _statRow(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFDCEBE1))),
      ),
      child: Row(children: [
        Expanded(
          child: Text(label,
              style: const TextStyle(
                  fontFamily: AppFonts.family,
                  fontSize: 15,
                  height: 20 / 15,
                  fontWeight: FontWeight.w500,
                  color: AppColors.inkMid)),
        ),
        Text(value,
            style: const TextStyle(
                fontFamily: AppFonts.family,
                fontSize: 15,
                height: 20 / 15,
                fontWeight: FontWeight.w700,
                color: AppColors.ink)),
      ]),
    );
  }

  Widget _levelPill(_Level level) {
    final (_, fg) = _pillColors(level);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: fg.withAlpha(140)),
          borderRadius: BorderRadius.circular(20)),
      child: Text(_levelLabel(level),
          style: TextStyle(
              fontFamily: AppFonts.family, fontSize: 11.5, fontWeight: FontWeight.w700, color: fg)),
    );
  }

  Widget _onOffPill(bool on) {
    final fg = on ? AppColors.successText : AppColors.inkMid;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: fg.withAlpha(140)),
          borderRadius: BorderRadius.circular(20)),
      child: Text(on ? 'ON' : 'OFF',
          style: TextStyle(
              fontFamily: AppFonts.family, fontSize: 11.5, fontWeight: FontWeight.w700, color: fg)),
    );
  }

  Widget _emptyPanel() {
    final wantsDevice = _precise;
    final zonesOnMap = _zones.length;
    final totalBuildings = _buildingsInfo.length;
    final scoped = _scopedDevices;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _panelDecoration,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(wantsDevice ? 'Pick a device' : 'Pick a building',
            style: const TextStyle(
                fontFamily: AppFonts.family,
                fontSize: 17,
                height: 22 / 17,
                fontWeight: FontWeight.w700,
                color: AppColors.ink)),
        const SizedBox(height: 2),
        Text(
          'Tap ${wantsDevice ? 'a dot' : 'a zone'} on the map to see its details.',
          style: const TextStyle(
              fontFamily: AppFonts.family, fontSize: 14, height: 20 / 14, color: AppColors.inkMid),
        ),
        if (_lockCode == null) _statRow('Buildings on map', '$zonesOnMap of $totalBuildings'),
        _statRow('Devices assigned', '${scoped.length}'),
        _statRow('Online now', '${scoped.where((d) => d.online).length}'),
      ]),
    );
  }

  Widget _buildingCard(String code) {
    final name = _buildingName(code);
    final floors = _buildingFloors(code);
    final kwh = _monthKwh[code] ?? 0.0;
    final level = _buildingLevel(kwh);
    final devs = _devices.where((d) => d.building == code).toList();
    final rooms = <String>{for (final d in devs) d.room.isEmpty ? 'No room' : d.room};
    final online = devs.where((d) => d.online).length;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _panelDecoration,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name,
                  style: const TextStyle(
                      fontFamily: AppFonts.family,
                      fontSize: 17,
                      height: 22 / 17,
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink)),
              Text('$code · ${kwh.toStringAsFixed(1)} kWh this month',
                  style: const TextStyle(
                      fontFamily: AppFonts.family, fontSize: 14, height: 20 / 14, color: AppColors.inkMid)),
            ]),
          ),
          _levelPill(level),
        ]),
        _statRow('Floors', '$floors'),
        _statRow('Rooms', '${rooms.length}'),
        _statRow('Devices', '${devs.length}'),
        _statRow('Online now', '$online'),
        const SizedBox(height: 12),
        AppPrimaryButton(
          label: 'View building',
          icon: Icons.arrow_forward,
          palette: _palette,
          expand: true,
          onPressed: () => _openBuilding(code),
        ),
      ]),
    );
  }

  Widget _deviceCard(_MapDevice d) {
    final level = _deviceLevel(d.online, d.kwh);
    final label = _deviceLabel(d.utility);
    final on = d.relay && d.online;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _panelDecoration,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          OutlineIconBox(icon: _utilityIcon(d.utility), palette: _palette),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$label · ${d.room.isEmpty ? 'No room' : d.room}',
                  style: const TextStyle(
                      fontFamily: AppFonts.family,
                      fontSize: 17,
                      height: 22 / 17,
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink)),
              Text('${d.building} · Floor ${d.floor} · ${d.id}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontFamily: AppFonts.family, fontSize: 14, height: 20 / 14, color: AppColors.inkMid)),
            ]),
          ),
          _onOffPill(on),
        ]),
        _statRow('Status', d.online ? 'Online' : 'Offline'),
        _statRow("Today's energy", '${d.kwh.toStringAsFixed(2)} kWh'),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: Color(0xFFDCEBE1))),
          ),
          child: Row(children: [
            const Expanded(
              child: Text('Level',
                  style: TextStyle(
                      fontFamily: AppFonts.family,
                      fontSize: 15,
                      height: 20 / 15,
                      fontWeight: FontWeight.w500,
                      color: AppColors.inkMid)),
            ),
            _levelPill(level),
          ]),
        ),
        const SizedBox(height: 12),
        AppPrimaryButton(
          label: 'View device',
          icon: Icons.arrow_forward,
          palette: _palette,
          expand: true,
          onPressed: () => _openDevice(d),
        ),
      ]),
    );
  }
}

/// Dashed rounded-rect outline for a zone in Devices/precise mode (preview
/// `.zone.zp`: `border: 1.5px dashed rgba(255,255,255,.9)`).
class _DashedRectPainter extends CustomPainter {
  final Color color;
  const _DashedRectPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(6),
    );
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    const dashWidth = 5.0, dashGap = 4.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = math.min(distance + dashWidth, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRectPainter oldDelegate) => oldDelegate.color != color;
}
