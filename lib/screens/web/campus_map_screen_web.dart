import 'dart:async';
import 'dart:math' as math;

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:rxdart/rxdart.dart';

import '../../theme/app_colors.dart';
import '../../theme/institute_colors.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';
import 'web_theme.dart';
import 'web_widgets.dart';
import '../../theme/app_fonts.dart';
import '../../services/history_clock.dart';

/// Web campus map with two views over the real campus image:
///
/// - **Approximate**: one coloured zone per building (`hotspots/{code}`,
///   x/y/w/h as 0–1 fractions of the image, shared with mobile), coloured by
///   this month's kWh. Admins can add, move, resize and remove zones.
/// - **Precise**: one dot per device inside its building's zone, coloured by
///   today's kWh. A dot's position is stored relative to its zone under
///   `hotspots/{code}/devices/{deviceId}` (`x`, `y` as 0–1 of the zone), so
///   dots follow the zone when it moves and go away with it. Devices without
///   a saved position are spread evenly over the zone. Admins can drag dots.
class CampusMapScreenWeb extends StatefulWidget {
  final String role;
  final void Function(String code, String name, int floors) onBuildingTap;
  final void Function(String deviceId, String utility, String building,
      String room, int floor) onDeviceTap;

  const CampusMapScreenWeb({
    super.key,
    required this.role,
    required this.onBuildingTap,
    required this.onDeviceTap,
  });

  @override
  State<CampusMapScreenWeb> createState() => _CampusMapScreenWebState();
}

const double _mapAspect = 354 / 496;

class _Zone {
  final String code;
  double x, y, w, h;
  final Map<String, Offset> devicePositions;

  _Zone(this.code, this.x, this.y, this.w, this.h, this.devicePositions);

  Map<String, double> get rect => {'x': x, 'y': y, 'w': w, 'h': h};
}

class _Device {
  final String id;
  final String building;
  final String room;
  final int floor;
  final String utility;
  final double kwh;
  final bool online;
  final bool relay;
  final double power;

  const _Device({
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

enum _Level { low, mid, high, off }

const _levelColor = {
  _Level.high: Color(0xFFD64A4A),
  _Level.mid: Color(0xFFE8922A),
  _Level.low: AppColors.greenMid,
  _Level.off: Color(0xFF9E9E9E),
};

_Level _buildingLevel(double kwh) =>
    kwh >= 100 ? _Level.high : (kwh >= 50 ? _Level.mid : _Level.low);

_Level _deviceLevel(_Device d) => !d.online
    ? _Level.off
    : d.kwh >= 2
        ? _Level.high
        : (d.kwh >= 1 ? _Level.mid : _Level.low);

String _levelLabel(_Level l) => switch (l) {
      _Level.high => 'HIGH',
      _Level.mid => 'MID',
      _Level.low => 'LOW',
      _Level.off => 'OFFLINE',
    };

double _num(Object? v) =>
    v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0.0;

class _CampusMapScreenWebState extends State<CampusMapScreenWeb> {
  StreamSubscription? _sub;
  bool _isLoading = true;
  String? _errorText;

  Map<String, Map<String, dynamic>> _buildings = {}; // code -> name, floors
  Map<String, double> _monthKwh = {};
  List<_Device> _devices = [];
  Map<String, _Zone> _zones = {};

  bool _precise = false;
  bool _editing = false;
  String? _selectedBuilding;
  String? _selectedDevice;

  bool get _isAdmin => const {
        'admin',
        'main_admin',
        'super_admin',
        'institute_admin'
      }.contains(widget.role);

  InstitutePalette get _p => context.institutePalette;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _listen() {
    _sub?.cancel();
    final now = HistoryClock.instance.now();
    final month = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    _sub = Rx.combineLatestList<DatabaseEvent>([
      FirebaseDatabase.instance.ref('devices').onValue,
      FirebaseDatabase.instance.ref('history/monthly/$month/buildings').onValue,
      FirebaseDatabase.instance.ref('buildings').onValue,
      FirebaseDatabase.instance.ref('hotspots').onValue,
    ]).listen((events) {
      if (!mounted) return;
      setState(() {
        _applyBuildings(events[2].snapshot.value);
        _applyDevices(events[0].snapshot.value);
        _applyHistory(events[1].snapshot.value);
        // Keep local edits while a drag is in progress.
        if (!_dragging) _applyZones(events[3].snapshot.value);
        _isLoading = false;
        _errorText = null;
      });
    }, onError: (Object e) {
      if (!mounted) return;
      if (_isLoading) {
        setState(() {
          _isLoading = false;
          _errorText = e.toString().toLowerCase().contains('permission')
              ? 'You do not have permission to view the campus map.'
              : 'Failed to load the campus map.';
        });
      } else {
        TopToast.show(context, 'Lost connection to live map data.',
            isError: true);
      }
    });
  }

  void _applyBuildings(Object? raw) {
    if (raw is! Map) {
      if (_isLoading) _buildings = {};
      return;
    }
    _buildings = {
      for (final e in raw.entries)
        if (e.value is Map)
          e.key.toString(): {
            'name': ((e.value as Map)['name'] ?? e.key).toString(),
            'floors': int.tryParse('${(e.value as Map)['floors'] ?? 1}') ?? 1,
          },
    };
  }

  void _applyDevices(Object? raw) {
    if (raw is! Map) {
      if (_isLoading) _devices = [];
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final list = <_Device>[];
    raw.forEach((id, val) {
      if (val is! Map) return;
      final building = (val['building'] ?? '').toString();
      if (building.isEmpty) return;
      final lastSeen = _num(val['last_seen']);
      final online = lastSeen > 0
          ? now - lastSeen < 2 * 60 * 1000
          : (val['status'] ?? '') == 'online';
      list.add(_Device(
        id: id.toString(),
        building: building,
        room: (val['room'] ?? '').toString(),
        floor: int.tryParse('${val['floor'] ?? 1}') ?? 1,
        utility: (val['utility'] ?? '').toString(),
        kwh: _num(val['kwh']),
        online: online,
        relay: val['relay'] == true,
        power: _num(val['power']),
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
      _zones = {}; // null: every zone has been removed
      return;
    }
    final zones = <String, _Zone>{};
    raw.forEach((code, val) {
      if (val is! Map) return;
      final positions = <String, Offset>{};
      final devs = val['devices'];
      if (devs is Map) {
        devs.forEach((id, p) {
          if (p is Map) {
            positions[id.toString()] = Offset(
                _num(p['x']).clamp(0.0, 1.0), _num(p['y']).clamp(0.0, 1.0));
          }
        });
      }
      zones[code.toString()] = _Zone(
        code.toString(),
        val['x'] == null ? 0.1 : _num(val['x']),
        val['y'] == null ? 0.1 : _num(val['y']),
        val['w'] == null ? 0.2 : _num(val['w']),
        val['h'] == null ? 0.1 : _num(val['h']),
        positions,
      );
    });
    _zones = zones;
  }

  // ── Zone + dot editing ─────────────────────────────────────────────────

  bool _dragging = false;

  Future<void> _saveZone(_Zone z) async {
    _dragging = false;
    try {
      await FirebaseDatabase.instance.ref('hotspots/${z.code}').update(z.rect);
    } catch (_) {
      if (mounted) {
        TopToast.show(context, 'Could not save the zone.', isError: true);
      }
    }
  }

  Future<void> _saveDot(_Zone z, String deviceId, Offset pos) async {
    _dragging = false;
    try {
      await FirebaseDatabase.instance
          .ref('hotspots/${z.code}/devices/$deviceId')
          .set({'x': pos.dx, 'y': pos.dy});
    } catch (_) {
      if (mounted) {
        TopToast.show(context, 'Could not save the position.', isError: true);
      }
    }
  }

  Future<void> _addZone() async {
    final free = _buildings.keys.where((c) => !_zones.containsKey(c)).toList()
      ..sort();
    if (free.isEmpty) {
      TopToast.show(context,
          'Every building already has a zone. Remove one first to redraw it.');
      return;
    }
    String? added;
    await showWebFormDialog(
      context: context,
      title: 'Add zone',
      subtitle: 'The zone appears near the middle of the map. Drag it into '
          'place and resize it from the corners.',
      okLabel: 'Add',
      fields: [
        WebField(
          id: 'b',
          label: 'Building',
          options: [
            for (final c in free) '$c · ${_buildings[c]?['name'] ?? c}',
          ],
        ),
      ],
      onSubmit: (v) async {
        final code = v['b']!.split(' · ').first;
        await FirebaseDatabase.instance
            .ref('hotspots/$code')
            .set({'x': 0.35, 'y': 0.35, 'w': 0.22, 'h': 0.10});
        added = code;
        return null;
      },
    );
    if (added != null && mounted) {
      TopToast.show(context, 'Zone added for $added. Drag it into place.');
    }
  }

  Future<void> _removeZone(String code) async {
    final ok = await showWebConfirmDialog(
      context: context,
      title: 'Remove zone?',
      message: 'The $code zone and its device positions will be removed from '
          'the map. The building and its devices stay.',
      okLabel: 'Remove',
      onConfirm: () =>
          FirebaseDatabase.instance.ref('hotspots/$code').remove(),
    );
    if (ok && mounted) TopToast.show(context, 'Zone removed.');
  }

  /// Where each device of [z] sits inside it (0–1 of the zone): its saved
  /// position, or an even grid over the zone for the rest.
  Map<String, Offset> _layout(_Zone z, Size map) {
    final devs = _devices.where((d) => d.building == z.code).toList();
    final unplaced = devs.where((d) => !z.devicePositions.containsKey(d.id)).toList();
    final out = <String, Offset>{
      for (final d in devs)
        if (z.devicePositions.containsKey(d.id)) d.id: z.devicePositions[d.id]!,
    };
    final n = unplaced.length;
    if (n > 0) {
      final pw = math.max(1.0, z.w * map.width);
      final ph = math.max(1.0, z.h * map.height);
      final cols = math.max(1, math.min(n, (math.sqrt(n * pw / ph)).round()));
      final rows = (n / cols).ceil();
      for (var i = 0; i < n; i++) {
        out[unplaced[i].id] =
            Offset((i % cols + 0.5) / cols, (i ~/ cols + 0.5) / rows);
      }
    }
    return out;
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ScreenSkeleton(
      isLoading: _isLoading,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            const SizedBox(height: 16),
            Expanded(
              child: _errorText != null
                  ? Center(
                      child: Text(_errorText!,
                          style: const TextStyle(color: WebColors.mid)))
                  : LayoutBuilder(builder: (context, c) {
                      final wide = c.maxWidth >= 980;
                      final map = _mapCard();
                      if (!wide) {
                        return Column(children: [
                          Expanded(child: map),
                          if (_hasSelection) ...[
                            const SizedBox(height: 12),
                            SizedBox(height: 300, child: _sidePanel()),
                          ],
                        ]);
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: map),
                          const SizedBox(width: 20),
                          SizedBox(width: 340, child: _sidePanel()),
                        ],
                      );
                    }),
            ),
          ],
        ),
      ),
    );
  }

  bool get _hasSelection =>
      (_precise ? _selectedDevice : _selectedBuilding) != null;

  Widget _header() {
    final p = _p;
    return Padding(
      // Clear of the shell's floating role badge and bell.
      padding: const EdgeInsets.only(right: 180),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 12,
        children: [
          const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Campus Map',
                  style: TextStyle(
                      fontFamily: AppFonts.family,
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: WebColors.ink)),
              SizedBox(height: 2),
              Text('Buildings and devices by energy use',
                  style: TextStyle(fontSize: 14, color: WebColors.muted)),
            ],
          ),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                  value: false,
                  icon: Icon(Icons.crop_square_rounded, size: 18),
                  label: Text('Approximate')),
              ButtonSegment(
                  value: true,
                  icon: Icon(Icons.scatter_plot_outlined, size: 18),
                  label: Text('Precise')),
            ],
            selected: {_precise},
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: p.dark,
              selectedForegroundColor: Colors.white,
              foregroundColor: p.dark,
              side: BorderSide(color: p.mid.withAlpha(80)),
            ),
            onSelectionChanged: (s) => setState(() {
              _precise = s.first;
              _selectedBuilding = null;
              _selectedDevice = null;
            }),
          ),
          if (_isAdmin && !_editing)
            OutlinedButton.icon(
              onPressed: () => setState(() {
                _editing = true;
                _selectedBuilding = null;
                _selectedDevice = null;
              }),
              icon: const Icon(Icons.edit_location_alt_outlined, size: 18),
              label: Text(_precise ? 'Edit positions' : 'Edit zones'),
              style: OutlinedButton.styleFrom(
                foregroundColor: p.dark,
                side: BorderSide(color: p.mid.withAlpha(80)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              ),
            ),
          if (_editing) ...[
            if (!_precise)
              WebIconButton(
                icon: Icons.add_rounded,
                tooltip: 'Add zone',
                solid: true,
                size: 40,
                onPressed: _addZone,
              ),
            ElevatedButton.icon(
              onPressed: () {
                setState(() => _editing = false);
                TopToast.show(context,
                    _precise ? 'Positions saved.' : 'Zones saved.');
              },
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('Done'),
              style: ElevatedButton.styleFrom(
                backgroundColor: p.dark,
                foregroundColor: Colors.white,
                elevation: 0,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _mapCard() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: WebColors.outline),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(children: [
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            var w = c.maxWidth;
            var h = w / _mapAspect;
            if (h > c.maxHeight) {
              h = c.maxHeight;
              w = h * _mapAspect;
            }
            final size = Size(w, h);
            return Center(
              child: SizedBox(
                width: w,
                height: h,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() {
                    _selectedBuilding = null;
                    _selectedDevice = null;
                  }),
                  child: Stack(clipBehavior: Clip.none, children: [
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.asset('assets/images/campus_map.png',
                            fit: BoxFit.fill),
                      ),
                    ),
                    for (final z in _zones.values)
                      if (_precise)
                        ..._preciseZone(z, size)
                      else
                        _approxZone(z, size),
                  ]),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 10),
        _legend(),
      ]),
    );
  }

  Widget _legend() {
    final hidden = _devices.where((d) => !_zones.containsKey(d.building)).length;
    final items = _precise
        ? const [_Level.low, _Level.mid, _Level.high, _Level.off]
        : const [_Level.low, _Level.mid, _Level.high];
    return Wrap(
      spacing: 16,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(_precise ? "Today's kWh per device:" : "This month's kWh:",
            style: const TextStyle(fontSize: 13, color: WebColors.muted)),
        for (final l in items)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                    color: _levelColor[l], shape: BoxShape.circle)),
            const SizedBox(width: 5),
            Text(
                _precise
                    ? switch (l) {
                        _Level.low => 'Low (<1)',
                        _Level.mid => 'Mid (1–2)',
                        _Level.high => 'High (≥2)',
                        _Level.off => 'Offline',
                      }
                    : switch (l) {
                        _Level.low => 'Low (<50)',
                        _Level.mid => 'Mid (50–100)',
                        _ => 'High (≥100)',
                      },
                style: const TextStyle(fontSize: 13, color: WebColors.ink)),
          ]),
        if (_precise && hidden > 0)
          Text('$hidden device${hidden == 1 ? '' : 's'} hidden: building has '
              'no zone',
              style: const TextStyle(fontSize: 12.5, color: WebColors.muted)),
        if (_editing)
          Text(
              _precise
                  ? 'Drag a dot to place the device inside its building.'
                  : 'Drag a zone to move it · drag a corner to resize · ✕ removes it',
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: _p.dark)),
      ],
    );
  }

  // ── Approximate view ───────────────────────────────────────────────────

  Widget _approxZone(_Zone z, Size map) {
    final color = _levelColor[_buildingLevel(_monthKwh[z.code] ?? 0)]!;
    final selected = _selectedBuilding == z.code;
    final label = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
          color: _editing ? _p.dark : color.withAlpha(220),
          borderRadius: BorderRadius.circular(4)),
      child: Text(z.code,
          style: const TextStyle(
              color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
    );

    final box = Container(
      decoration: BoxDecoration(
        color: (_editing ? _p.dark : color).withAlpha(selected ? 120 : 60),
        border: Border.all(
            color: _editing ? _p.dark : color,
            width: selected || _editing ? 2.5 : 1.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Center(child: FittedBox(fit: BoxFit.scaleDown, child: label)),
    );

    return Positioned(
      left: z.x * map.width,
      top: z.y * map.height,
      width: z.w * map.width,
      height: z.h * map.height,
      child: _editing
          ? _editableZone(z, map, box)
          : MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Tooltip(
                message:
                    '${_buildings[z.code]?['name'] ?? z.code} · ${(_monthKwh[z.code] ?? 0).toStringAsFixed(1)} kWh this month',
                child: GestureDetector(
                  onTap: () => setState(() => _selectedBuilding =
                      _selectedBuilding == z.code ? null : z.code),
                  child: box,
                ),
              ),
            ),
    );
  }

  Widget _editableZone(_Zone z, Size map, Widget box) {
    const minW = 0.04, minH = 0.03, hs = 16.0;
    Widget handle(Alignment a, void Function(Offset d) onDrag) {
      return Positioned(
        left: a.x < 0 ? -hs / 2 : null,
        right: a.x > 0 ? -hs / 2 : null,
        top: a.y < 0 ? -hs / 2 : null,
        bottom: a.y > 0 ? -hs / 2 : null,
        child: MouseRegion(
          cursor: a.x == a.y
              ? SystemMouseCursors.resizeUpLeftDownRight
              : SystemMouseCursors.resizeUpRightDownLeft,
          child: GestureDetector(
            onPanStart: (_) => _dragging = true,
            onPanUpdate: (d) => setState(() => onDrag(Offset(
                d.delta.dx / map.width, d.delta.dy / map.height))),
            onPanEnd: (_) => _saveZone(z),
            child: Container(
              width: hs,
              height: hs,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: _p.dark, width: 2),
              ),
            ),
          ),
        ),
      );
    }

    void east(double dx) => z.w = (z.w + dx).clamp(minW, 1 - z.x);
    void south(double dy) => z.h = (z.h + dy).clamp(minH, 1 - z.y);
    void west(double dx) {
      final nx = (z.x + dx).clamp(0.0, z.x + z.w - minW);
      z.w += z.x - nx;
      z.x = nx;
    }

    void north(double dy) {
      final ny = (z.y + dy).clamp(0.0, z.y + z.h - minH);
      z.h += z.y - ny;
      z.y = ny;
    }

    return Stack(clipBehavior: Clip.none, children: [
      Positioned.fill(
        child: MouseRegion(
          cursor: SystemMouseCursors.move,
          child: GestureDetector(
            onPanStart: (_) => _dragging = true,
            onPanUpdate: (d) => setState(() {
              z.x = (z.x + d.delta.dx / map.width).clamp(0.0, 1 - z.w);
              z.y = (z.y + d.delta.dy / map.height).clamp(0.0, 1 - z.h);
            }),
            onPanEnd: (_) => _saveZone(z),
            child: box,
          ),
        ),
      ),
      handle(Alignment.topLeft, (d) {
        west(d.dx);
        north(d.dy);
      }),
      handle(Alignment.topRight, (d) {
        east(d.dx);
        north(d.dy);
      }),
      handle(Alignment.bottomLeft, (d) {
        west(d.dx);
        south(d.dy);
      }),
      handle(Alignment.bottomRight, (d) {
        east(d.dx);
        south(d.dy);
      }),
      Positioned(
        top: -12,
        right: 14,
        child: Tooltip(
          message: 'Remove zone',
          child: Material(
            color: AppColors.error,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _removeZone(z.code),
              child: const Padding(
                padding: EdgeInsets.all(3),
                child: Icon(Icons.close_rounded, size: 15, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    ]);
  }

  // ── Precise view ───────────────────────────────────────────────────────

  List<Widget> _preciseZone(_Zone z, Size map) {
    final layout = _layout(z, map);
    final zl = z.x * map.width, zt = z.y * map.height;
    final zw = z.w * map.width, zh = z.h * map.height;
    const dot = 14.0;
    return [
      Positioned(
        left: zl,
        top: zt,
        width: zw,
        height: zh,
        child: IgnorePointer(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(50),
              border: Border.all(color: _p.dark.withAlpha(110), width: 1.2),
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.topLeft,
            padding: const EdgeInsets.all(2),
            child: Text(z.code,
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: _p.dark.withAlpha(200))),
          ),
        ),
      ),
      for (final d in _devices.where((d) => d.building == z.code))
        if (layout[d.id] != null)
          Positioned(
            left: zl + layout[d.id]!.dx * zw - dot / 2,
            top: zt + layout[d.id]!.dy * zh - dot / 2,
            width: dot,
            height: dot,
            child: _dot(z, d, layout[d.id]!, Size(zw, zh), dot),
          ),
    ];
  }

  Widget _dot(_Zone z, _Device d, Offset pos, Size zone, double size) {
    final color = _levelColor[_deviceLevel(d)]!;
    final selected = _selectedDevice == d.id;
    final circle = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: selected ? 3 : 2),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withAlpha(selected ? 90 : 50), blurRadius: 4),
        ],
      ),
    );
    if (_editing) {
      return MouseRegion(
        cursor: SystemMouseCursors.move,
        child: GestureDetector(
          onPanStart: (_) {
            _dragging = true;
            z.devicePositions[d.id] = pos;
          },
          onPanUpdate: (u) => setState(() {
            final cur = z.devicePositions[d.id] ?? pos;
            z.devicePositions[d.id] = Offset(
              (cur.dx + u.delta.dx / zone.width).clamp(0.0, 1.0),
              (cur.dy + u.delta.dy / zone.height).clamp(0.0, 1.0),
            );
          }),
          onPanEnd: (_) => _saveDot(z, d.id, z.devicePositions[d.id]!),
          child: circle,
        ),
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Tooltip(
        message: '${d.utility} · ${d.room} · ${d.kwh.toStringAsFixed(2)} kWh',
        child: GestureDetector(
          onTap: () => setState(
              () => _selectedDevice = _selectedDevice == d.id ? null : d.id),
          child: circle,
        ),
      ),
    );
  }

  // ── Side panel ─────────────────────────────────────────────────────────

  Widget _sidePanel() {
    Widget body;
    if (_precise && _selectedDevice != null) {
      final d = _devices.where((x) => x.id == _selectedDevice).firstOrNull;
      body = d == null ? _hint() : _deviceCard(d);
    } else if (!_precise && _selectedBuilding != null) {
      body = _buildingCard(_selectedBuilding!);
    } else {
      body = _hint();
    }
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: WebColors.outline),
      ),
      child: SingleChildScrollView(child: body),
    );
  }

  Widget _hint() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(_precise ? Icons.scatter_plot_outlined : Icons.touch_app_outlined,
          color: _p.mid, size: 30),
      const SizedBox(height: 10),
      Text(_precise ? 'Pick a device' : 'Pick a building',
          style: const TextStyle(
              fontFamily: AppFonts.family,
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: WebColors.ink)),
      const SizedBox(height: 4),
      Text(
          _precise
              ? 'Click a dot to see that device’s live reading.'
              : 'Click a zone to see its energy use, rooms and devices.',
          style: const TextStyle(fontSize: 14, color: WebColors.muted)),
      const SizedBox(height: 18),
      _stat('Buildings on map', '${_zones.length} of ${_buildings.length}'),
      _stat('Devices assigned', '${_devices.length}'),
      _stat('Online now', '${_devices.where((d) => d.online).length}'),
    ]);
  }

  Widget _stat(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Expanded(
              child: Text(label,
                  style: const TextStyle(fontSize: 14, color: WebColors.mid))),
          Text(value,
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: WebColors.ink)),
        ]),
      );

  Widget _pill(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withAlpha(28),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withAlpha(90)),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w700, color: color)),
      );

  Widget _buildingCard(String code) {
    final info = _buildings[code] ?? const {};
    final name = (info['name'] ?? code).toString();
    final floors = (info['floors'] as int?) ?? 1;
    final kwh = _monthKwh[code] ?? 0;
    final level = _buildingLevel(kwh);
    final devs = _devices.where((d) => d.building == code).toList();
    final rooms = <String, List<_Device>>{};
    for (final d in devs) {
      rooms.putIfAbsent(d.room.isEmpty ? 'No room' : d.room, () => []).add(d);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: Text(name,
              style: const TextStyle(
                  fontFamily: AppFonts.family,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: WebColors.ink)),
        ),
        WebIconButton(
          icon: Icons.close_rounded,
          tooltip: 'Close',
          size: 30,
          onPressed: () => setState(() => _selectedBuilding = null),
        ),
      ]),
      const SizedBox(height: 6),
      Row(children: [
        _pill(_levelLabel(level), _levelColor[level]!),
        const SizedBox(width: 8),
        Text('$code · ${kwh.toStringAsFixed(1)} kWh this month',
            style: const TextStyle(fontSize: 13, color: WebColors.muted)),
      ]),
      const SizedBox(height: 14),
      _stat('Floors', '$floors'),
      _stat('Rooms', '${rooms.length}'),
      _stat('Devices', '${devs.length}'),
      _stat('Online now', '${devs.where((d) => d.online).length}'),
      if (rooms.isNotEmpty) ...[
        const Divider(height: 24),
        for (final e in rooms.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              Icon(Icons.meeting_room_outlined, size: 16, color: _p.mid),
              const SizedBox(width: 8),
              Expanded(
                child: Text(e.key,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: WebColors.ink)),
              ),
              Text(
                  '${e.value.length} device${e.value.length == 1 ? '' : 's'} · '
                  '${e.value.fold<double>(0, (a, d) => a + d.kwh).toStringAsFixed(1)} kWh',
                  style:
                      const TextStyle(fontSize: 12.5, color: WebColors.muted)),
            ]),
          ),
      ],
      const SizedBox(height: 14),
      ElevatedButton.icon(
        onPressed: () => widget.onBuildingTap(code, name, floors),
        icon: const Icon(Icons.arrow_forward_rounded, size: 18),
        label: const Text('View building'),
        style: ElevatedButton.styleFrom(
          backgroundColor: _p.dark,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
        ),
      ),
    ]);
  }

  Widget _deviceCard(_Device d) {
    final level = _deviceLevel(d);
    final icon = switch (d.utility.toLowerCase()) {
      'lights' => Icons.lightbulb_outline,
      'outlets' => Icons.electrical_services,
      'ac' => Icons.ac_unit,
      _ => Icons.memory_outlined,
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
              color: _p.pale, borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, color: _p.dark, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${d.utility.isEmpty ? 'Device' : d.utility} · ${d.room}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontFamily: AppFonts.family,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: WebColors.ink)),
            Text(d.id,
                style: const TextStyle(fontSize: 12.5, color: WebColors.muted)),
          ]),
        ),
        WebIconButton(
          icon: Icons.close_rounded,
          tooltip: 'Close',
          size: 30,
          onPressed: () => setState(() => _selectedDevice = null),
        ),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        _pill(_levelLabel(level), _levelColor[level]!),
        const SizedBox(width: 8),
        _pill(d.relay ? 'ON' : 'OFF',
            d.relay ? AppColors.success : AppColors.offline),
      ]),
      const SizedBox(height: 10),
      _stat('Energy today', '${d.kwh.toStringAsFixed(2)} kWh'),
      _stat('Power now', '${d.power.toStringAsFixed(0)} W'),
      _stat('Location', '${d.building} · Floor ${d.floor}'),
      _stat('Status', d.online ? 'Online' : 'Offline'),
      const SizedBox(height: 14),
      ElevatedButton.icon(
        onPressed: () =>
            widget.onDeviceTap(d.id, d.utility, d.building, d.room, d.floor),
        icon: const Icon(Icons.arrow_forward_rounded, size: 18),
        label: const Text('View device'),
        style: ElevatedButton.styleFrom(
          backgroundColor: _p.dark,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
        ),
      ),
    ]);
  }
}
