import 'dart:async';
import 'dart:math' as math;

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/institute_colors.dart';
import '../../viewmodels/dashboard_viewmodel.dart';
import '../../widgets/responsive_center.dart';
import '../../widgets/screen_skeleton.dart';
import 'web_theme.dart';

/// The web "Dashboard" tab: an at-a-glance overview modelled on a classic
/// admin layout -- a row of stat cards, a device-status card with a
/// utility donut, a per-building area chart, a building-load table and a
/// recent-usage bar chart.
///
/// The detailed view that used to live here (hero energy card, building
/// grid, recent entries) now lives under the side nav's "Devices" item.
///
/// Scope: when [instituteCode] is set (institute admins), every number and
/// chart is filtered to that building only; otherwise it is campus-wide.
/// Charts are drawn with CustomPainter / plain widgets, so no new package
/// is needed in pubspec.yaml.
class WebOverviewTab extends StatefulWidget {
  final DashboardViewModel vm;
  final InstitutePalette palette;
  final String? instituteCode;
  final String? userName;
  final VoidCallback onOpenDevices;
  final VoidCallback? onOpenAnalytics;
  final void Function(String code, String name, int floors) onBuildingTap;

  const WebOverviewTab({
    super.key,
    required this.vm,
    required this.palette,
    required this.onOpenDevices,
    required this.onBuildingTap,
    this.onOpenAnalytics,
    this.instituteCode,
    this.userName,
  });

  @override
  State<WebOverviewTab> createState() => _WebOverviewTabState();
}

class _BuildingStat {
  final String code;
  final String name;
  final int floors;
  final int devices;
  final double monthKwh;

  const _BuildingStat({
    required this.code,
    required this.name,
    required this.floors,
    required this.devices,
    required this.monthKwh,
  });
}

class _WebOverviewTabState extends State<WebOverviewTab> {
  StreamSubscription<DatabaseEvent>? _devicesSub;
  int _online = 0;
  int _offline = 0;
  double _scopedKwh = 0;
  Map<String, double> _utilityKwh = const {
    'Lights': 0,
    'Outlets': 0,
    'AC': 0,
  };

  @override
  void initState() {
    super.initState();
    _listenDevices();
  }

  @override
  void didUpdateWidget(covariant WebOverviewTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.instituteCode != widget.instituteCode) _listenDevices();
  }

  @override
  void dispose() {
    _devicesSub?.cancel();
    super.dispose();
  }

  /// One listener on `devices` for what the shared view model does not
  /// track: online/offline counts (same <2 min `last_seen` window the rest
  /// of the app uses), plus today's kWh and utility split for an
  /// institute-scoped viewer (campus-wide uses `vm.utilityTotals`).
  void _listenDevices() {
    _devicesSub?.cancel();
    final code = widget.instituteCode;
    _devicesSub =
        FirebaseDatabase.instance.ref('devices').onValue.listen((event) {
      if (!mounted) return;
      final raw = event.snapshot.value;
      var online = 0;
      var offline = 0;
      var kwh = 0.0;
      final util = <String, double>{'Lights': 0, 'Outlets': 0, 'AC': 0};
      if (raw is Map) {
        raw.forEach((_, val) {
          if (val is! Map) return;
          final d = Map<String, dynamic>.from(val);
          if (code != null && (d['building'] ?? '').toString() != code) {
            return;
          }
          final k = _toDouble(d['kwh']);
          kwh += k;
          final u = _utilityOf(d);
          util[u] = (util[u] ?? 0) + k;
          if (_isOnline(d['last_seen'])) {
            online++;
          } else {
            offline++;
          }
        });
      }
      setState(() {
        _online = online;
        _offline = offline;
        _scopedKwh = kwh;
        _utilityKwh = util;
      });
    }, onError: (Object e) {
      debugPrint('[Overview] devices listen error: $e');
    });
  }

  Color _utilityColor(String key) {
    final p = widget.palette;
    switch (key) {
      case 'Lights':
        return p.dark;
      case 'Outlets':
        return p.mid;
      case 'AC':
        return p.light;
      default:
        return WebColors.muted.withAlpha(140);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.vm,
      builder: (context, _) {
        final vm = widget.vm;
        final code = widget.instituteCode;
        final scoped = code != null;

        final rows = <_BuildingStat>[];
        for (final raw in vm.buildings) {
          final b = Map<String, dynamic>.from(raw as Map);
          final bc = (b['code'] ?? '').toString();
          if (scoped && bc != code) continue;
          rows.add(_BuildingStat(
            code: bc,
            name: (b['name'] ?? bc).toString(),
            floors: int.tryParse('${b['floors'] ?? 1}') ?? 1,
            devices: (vm.buildingDeviceCounts[bc] ?? 0).toInt(),
            monthKwh: (vm.buildingEnergy[bc] ?? 0).toDouble(),
          ));
        }

        final rate = vm.electricityRate.toDouble();
        final todayKwh = scoped ? _scopedKwh : vm.totalKwh.toDouble();
        final monthKwh = rows.fold<double>(0, (a, r) => a + r.monthKwh);
        final monthCost =
            scoped ? monthKwh * rate : vm.monthlyCostPhp.toDouble();
        final highLoad =
            rows.where((r) => _levelFor(r.monthKwh) == 'HIGH').length;
        final reporting = _online + _offline;
        final p = widget.palette;

        final stats = <Widget>[
          _StatCard(
            palette: p,
            icon: Icons.bolt_rounded,
            value: _fmt(todayKwh),
            unit: 'kWh',
            label: 'Energy today',
            caption: scoped ? '$code only · live' : 'Campus-wide · live',
          ),
          _StatCard(
            palette: p,
            icon: Icons.payments_outlined,
            value: _fmtPeso(monthCost),
            label: 'Month cost',
            caption: '₱${rate.toStringAsFixed(2)} per kWh',
          ),
          _StatCard(
            palette: p,
            icon: Icons.wifi_tethering_rounded,
            value: '$_online',
            label: 'Devices online',
            caption: 'of $reporting reporting',
          ),
          _StatCard(
            palette: p,
            icon: Icons.warning_amber_rounded,
            value: '$highLoad',
            label: 'High-load buildings',
            caption: '≥ 100 kWh this month',
            alert: highLoad > 0,
          ),
        ];

        return ScreenSkeleton(
          isLoading: vm.isLoading,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
            child: ResponsiveCenter(
              maxWidth: 1320,
              child: LayoutBuilder(
                builder: (context, c) {
                  final w = c.maxWidth;
                  final wide = w >= 1000;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _header(),
                      const SizedBox(height: 22),
                      _statGrid(stats, w),
                      const SizedBox(height: 22),
                      _pair(
                        wide,
                        _deviceStatusPanel(
                          vm.unassignedDevices,
                          scoped
                              ? _utilityKwh
                              : _normalizeUtilities(vm.utilityTotals),
                        ),
                        _buildingChartPanel(rows),
                        5,
                        6,
                      ),
                      const SizedBox(height: 22),
                      _pair(
                        wide,
                        _buildingTablePanel(rows),
                        _recentUsagePanel(vm.historyData),
                        6,
                        4,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Layout helpers ────────────────────────────────────────────────────

  Widget _header() {
    final first = (widget.userName ?? '').trim().split(' ').first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Dashboard',
              style: TextStyle(
                fontFamily: 'Outfit',
                fontSize: 26,
                fontWeight: FontWeight.w700,
                color: AppColors.textDark,
              ),
            ),
            const SizedBox(width: 12),
            _LivePill(palette: widget.palette),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          first.isEmpty
              ? 'Live overview of campus energy usage'
              : 'Welcome back, $first — here is your campus energy at a glance',
          style: const TextStyle(fontSize: 14, color: WebColors.muted),
        ),
      ],
    );
  }

  Widget _statGrid(List<Widget> cards, double w) {
    const gap = 18.0;
    final perRow = w >= 1000 ? 4 : (w >= 560 ? 2 : 1);
    final itemW = ((w - gap * (perRow - 1)) / perRow).floorToDouble();
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [for (final c in cards) SizedBox(width: itemW, child: c)],
    );
  }

  /// Two panels side by side on wide windows (equal height), stacked
  /// otherwise. Nothing inside a panel may use LayoutBuilder, because
  /// IntrinsicHeight cannot measure it.
  Widget _pair(bool wide, Widget a, Widget b, int flexA, int flexB) {
    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [a, const SizedBox(height: 22), b],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: flexA, child: a),
          const SizedBox(width: 22),
          Expanded(flex: flexB, child: b),
        ],
      ),
    );
  }

  // ── Panels ────────────────────────────────────────────────────────────

  Widget _deviceStatusPanel(int unassigned, Map<String, double> util) {
    final p = widget.palette;
    final entries = util.entries.toList();
    final total = entries.fold<double>(0, (a, e) => a + e.value);

    return _Panel(
      palette: p,
      title: 'Device Status',
      subtitle: "Connection state and today's load by utility",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
            decoration: BoxDecoration(
              color: p.pale.withAlpha(110),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: p.dark,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$_online',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Devices online',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textDark,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 7,
                  height: 7,
                  decoration:
                      BoxDecoration(color: p.mid, shape: BoxShape.circle),
                ),
                const Spacer(),
                TextButton(
                  onPressed: widget.onOpenDevices,
                  style: TextButton.styleFrom(foregroundColor: p.dark),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Manage devices',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      Icon(Icons.chevron_right_rounded, size: 18),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                  child: _CountBox(palette: p, value: _online, label: 'Online')),
              const SizedBox(width: 12),
              Expanded(
                  child:
                      _CountBox(palette: p, value: _offline, label: 'Offline')),
              const SizedBox(width: 12),
              Expanded(
                  child: _CountBox(
                      palette: p, value: unassigned, label: 'Unassigned')),
            ],
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              SizedBox(
                width: 148,
                height: 148,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CustomPaint(
                      size: const Size(148, 148),
                      painter: _DonutPainter(
                        values: [for (final e in entries) e.value],
                        colors: [for (final e in entries) _utilityColor(e.key)],
                        track: p.pale.withAlpha(140),
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _fmt(total),
                          style: const TextStyle(
                            fontFamily: 'Outfit',
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textDark,
                          ),
                        ),
                        const Text('kWh today',
                            style: TextStyle(
                                fontSize: 12, color: WebColors.muted)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final e in entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _LegendBar(
                          label: e.key,
                          value: e.value,
                          share: total <= 0 ? 0 : e.value / total,
                          color: _utilityColor(e.key),
                          track: p.pale.withAlpha(110),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildingChartPanel(List<_BuildingStat> rows) {
    final p = widget.palette;
    return _Panel(
      palette: p,
      title: 'Consumption by Building',
      subtitle: 'kWh this month, per building',
      trailing: _SoftChip(
          palette: p,
          text: '${rows.length} ${rows.length == 1 ? 'building' : 'buildings'}'),
      child: SizedBox(
        height: 250,
        child: _AreaChart(
          values: [for (final r in rows) r.monthKwh],
          labels: [for (final r in rows) r.code],
          line: p.mid,
          highlight: p.dark,
        ),
      ),
    );
  }

  Widget _buildingTablePanel(List<_BuildingStat> rows) {
    final p = widget.palette;
    final sorted = [...rows]..sort((a, b) => b.monthKwh.compareTo(a.monthKwh));
    final top = sorted.take(6).toList();
    final maxK = top.isEmpty ? 0.0 : top.first.monthKwh;

    const headStyle = TextStyle(
      fontSize: 11.5,
      fontWeight: FontWeight.w600,
      color: WebColors.muted,
      letterSpacing: 0.3,
    );

    return _Panel(
      palette: p,
      title: 'Building Load',
      subtitle: 'This month, ranked against the heaviest building',
      trailing: TextButton(
        onPressed: widget.onOpenDevices,
        child: Text('View devices',
            style: TextStyle(color: p.dark, fontWeight: FontWeight.w600)),
      ),
      child: top.isEmpty
          ? const _EmptyText('No buildings yet')
          : Column(
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      Expanded(flex: 4, child: Text('Building', style: headStyle)),
                      Expanded(flex: 2, child: Text('Devices', style: headStyle)),
                      Expanded(
                          flex: 2, child: Text('This month', style: headStyle)),
                      Expanded(flex: 4, child: Text('Load', style: headStyle)),
                    ],
                  ),
                ),
                Divider(height: 18, color: p.mid.withAlpha(25)),
                for (final r in top) _tableRow(r, maxK),
              ],
            ),
    );
  }

  Widget _tableRow(_BuildingStat r, double maxK) {
    final p = widget.palette;
    final level = _levelFor(r.monthKwh);
    final color = _levelColor(level);
    final share = maxK <= 0 ? 0.0 : r.monthKwh / maxK;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => widget.onBuildingTap(r.code, r.name, r.floors),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
        child: Row(
          children: [
            Expanded(
              flex: 4,
              child: Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: p.pale.withAlpha(150),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      r.code,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: p.dark,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      r.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textDark),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Text('${r.devices}',
                  style:
                      const TextStyle(fontSize: 14, color: AppColors.textDark)),
            ),
            Expanded(
              flex: 2,
              child: Text(
                '${_fmt(r.monthKwh)} kWh',
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textDark),
              ),
            ),
            Expanded(
              flex: 4,
              child: Row(
                children: [
                  Expanded(
                    child: _Bar(
                      share: share,
                      color: color,
                      track: p.pale.withAlpha(110),
                    ),
                  ),
                  const SizedBox(width: 10),
                  _LevelPill(level: level, color: color),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _recentUsagePanel(List<dynamic> history) {
    final p = widget.palette;
    final recent =
        history.length > 7 ? history.sublist(history.length - 7) : history;
    final fullLabels = <String>[];
    final shortLabels = <String>[];
    final values = <double>[];
    for (final raw in recent) {
      if (raw is! Map) continue;
      final label = '${raw['label'] ?? ''}';
      fullLabels.add(label);
      shortLabels.add(_shortLabel(label));
      values.add(_toDouble(raw['kwh']));
    }

    return _Panel(
      palette: p,
      title: 'Recent Usage',
      subtitle: values.isEmpty
          ? 'No history yet'
          : 'Last ${values.length} history entries (kWh)',
      trailing: widget.onOpenAnalytics == null
          ? null
          : IconButton(
              tooltip: 'Open analytics',
              onPressed: widget.onOpenAnalytics,
              icon: Icon(Icons.insights_rounded, color: p.dark),
            ),
      child: values.isEmpty
          ? const _EmptyText('No data yet')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 210,
                  child: _BarChart(
                    values: values,
                    labels: shortLabels,
                    tooltips: fullLabels,
                    palette: p,
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 16,
                  runSpacing: 6,
                  children: [
                    _LegendDot(color: p.dark, label: 'Latest'),
                    const _LegendDot(color: AppColors.warning, label: 'Peak'),
                    _LegendDot(color: p.light, label: 'Earlier'),
                  ],
                ),
              ],
            ),
    );
  }
}

// ── Small widgets ────────────────────────────────────────────────────────

class _Panel extends StatelessWidget {
  final InstitutePalette palette;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  const _Panel({
    required this.palette,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
      decoration: _cardDecoration(palette, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontFamily: 'Outfit',
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textDark,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(subtitle!,
                          style: const TextStyle(
                              fontSize: 13, color: WebColors.muted)),
                    ],
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }
}

BoxDecoration _cardDecoration(InstitutePalette p, double radius) =>
    BoxDecoration(
      color: AppColors.cardBg,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: p.mid.withAlpha(22)),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withAlpha(10),
          blurRadius: 20,
          offset: const Offset(0, 6),
        ),
      ],
    );

class _StatCard extends StatelessWidget {
  final InstitutePalette palette;
  final IconData icon;
  final String value;
  final String? unit;
  final String label;
  final String caption;
  final bool alert;

  const _StatCard({
    required this.palette,
    required this.icon,
    required this.value,
    required this.label,
    required this.caption,
    this.unit,
    this.alert = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = alert ? AppColors.error : palette.dark;
    final chipBg =
        alert ? AppColors.error.withAlpha(24) : palette.pale.withAlpha(150);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: _cardDecoration(palette, 16),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(color: chipBg, shape: BoxShape.circle),
            child: Icon(icon, color: accent, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Outfit',
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textDark,
                          height: 1.1,
                        ),
                      ),
                    ),
                    if (unit != null) ...[
                      const SizedBox(width: 4),
                      Text(unit!,
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: WebColors.muted)),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(label,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textDark)),
                const SizedBox(height: 2),
                Text(caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: WebColors.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LivePill extends StatelessWidget {
  final InstitutePalette palette;
  const _LivePill({required this.palette});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: palette.pale.withAlpha(140),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration:
                BoxDecoration(color: palette.mid, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text('Live',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: palette.dark)),
        ],
      ),
    );
  }
}

class _SoftChip extends StatelessWidget {
  final InstitutePalette palette;
  final String text;
  const _SoftChip({required this.palette, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: palette.pale.withAlpha(110),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600, color: palette.dark)),
    );
  }
}

class _CountBox extends StatelessWidget {
  final InstitutePalette palette;
  final int value;
  final String label;
  const _CountBox(
      {required this.palette, required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.mid.withAlpha(34)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$value',
              style: const TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textDark)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(fontSize: 13, color: WebColors.muted)),
        ],
      ),
    );
  }
}

/// A thin horizontal progress bar (share 0..1).
class _Bar extends StatelessWidget {
  final double share;
  final Color color;
  final Color track;
  static const double height = 6;
  const _Bar({
    required this.share,
    required this.color,
    required this.track,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: track)),
            Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: share.clamp(0.0, 1.0).toDouble(),
                heightFactor: 1,
                child: ColoredBox(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LegendBar extends StatelessWidget {
  final String label;
  final double value;
  final double share;
  final Color color;
  final Color track;
  const _LegendBar({
    required this.label,
    required this.value,
    required this.share,
    required this.color,
    required this.track,
  });

  @override
  Widget build(BuildContext context) {
    final pct = (share * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                  color: color, borderRadius: BorderRadius.circular(3)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text('$label ($pct%)',
                  style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textDark)),
            ),
            Text('${_fmt(value)} kWh',
                style:
                    const TextStyle(fontSize: 13, color: WebColors.muted)),
          ],
        ),
        const SizedBox(height: 6),
        _Bar(share: share, color: color, track: track),
      ],
    );
  }
}

class _LevelPill extends StatelessWidget {
  final String level;
  final Color color;
  const _LevelPill({required this.level, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(26),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withAlpha(77)),
      ),
      child: Text(level,
          style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              // Darkened so MID (orange) text stays readable on its tint.
              color: Color.lerp(color, Colors.black, 0.3))),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
              color: color, borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 6),
        Text(label,
            style: const TextStyle(fontSize: 11.5, color: WebColors.muted)),
      ],
    );
  }
}

class _EmptyText extends StatelessWidget {
  final String text;
  const _EmptyText(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Center(
        child: Text(text, style: const TextStyle(color: WebColors.muted)),
      ),
    );
  }
}

// ── Charts ───────────────────────────────────────────────────────────────

/// Vertical bars on pale full-height tracks (like the reference's
/// "Top Selling" card). Latest bar = palette.dark, the peak = warning.
class _BarChart extends StatelessWidget {
  final List<double> values;
  final List<String> labels;
  final List<String> tooltips;
  final InstitutePalette palette;

  const _BarChart({
    required this.values,
    required this.labels,
    required this.tooltips,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    final maxV = values.fold<double>(0, (a, b) => b > a ? b : a);
    final last = values.length - 1;
    final peak = maxV <= 0 ? -1 : values.indexOf(maxV);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < values.length; i++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Tooltip(
                message: '${tooltips[i]}: ${values[i].toStringAsFixed(2)} kWh',
                child: Column(
                  children: [
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: palette.pale.withAlpha(90),
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: FractionallySizedBox(
                              widthFactor: 1,
                              heightFactor: maxV <= 0
                                  ? 0.02
                                  : (values[i] / maxV)
                                      .clamp(0.02, 1.0)
                                      .toDouble(),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: i == last
                                      ? palette.dark
                                      : i == peak
                                          ? AppColors.warning
                                          : palette.light,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(labels[i],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: WebColors.muted)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Area/line chart with a hover crosshair + tooltip (like the reference's
/// "Top Department" chart).
class _AreaChart extends StatefulWidget {
  final List<double> values;
  final List<String> labels;
  final Color line;
  final Color highlight;

  const _AreaChart({
    required this.values,
    required this.labels,
    required this.line,
    required this.highlight,
  });

  @override
  State<_AreaChart> createState() => _AreaChartState();
}

class _AreaChartState extends State<_AreaChart> {
  int? _hover;

  @override
  Widget build(BuildContext context) {
    if (widget.values.isEmpty) return const _EmptyText('No data yet');
    return MouseRegion(
      onExit: (_) => setState(() => _hover = null),
      onHover: (e) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) return;
        final i = _AreaChartPainter.indexAt(
            e.localPosition.dx, box.size.width, widget.values.length);
        if (i != _hover) setState(() => _hover = i);
      },
      child: CustomPaint(
        size: Size.infinite,
        painter: _AreaChartPainter(
          values: widget.values,
          labels: widget.labels,
          line: widget.line,
          highlight: widget.highlight,
          hover: _hover,
        ),
      ),
    );
  }
}

class _AreaChartPainter extends CustomPainter {
  static const double _left = 44;
  static const double _right = 14;
  static const double _top = 16;
  static const double _bottom = 28;

  final List<double> values;
  final List<String> labels;
  final Color line;
  final Color highlight;
  final int? hover;

  _AreaChartPainter({
    required this.values,
    required this.labels,
    required this.line,
    required this.highlight,
    this.hover,
  });

  static int indexAt(double dx, double width, int n) {
    if (n <= 1) return 0;
    final plotW = width - _left - _right;
    final step = plotW / (n - 1);
    return ((dx - _left) / step).round().clamp(0, n - 1).toInt();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxV =
        _niceMax(values.fold<double>(0, (a, b) => b > a ? b : a));
    final plotW = size.width - _left - _right;
    final plotH = size.height - _top - _bottom;
    final baseY = _top + plotH;
    final n = values.length;

    // Grid + y labels (recessive).
    final gridPaint = Paint()
      ..color = WebColors.muted.withAlpha(34)
      ..strokeWidth = 1;
    for (var g = 0; g <= 4; g++) {
      final y = _top + plotH * g / 4;
      canvas.drawLine(Offset(_left, y), Offset(size.width - _right, y), gridPaint);
      _text(canvas, _fmtAxis(maxV * (4 - g) / 4), Offset(_left - 8, y),
          alignRight: true);
    }

    final pts = <Offset>[
      for (var i = 0; i < n; i++)
        Offset(
          n == 1 ? _left + plotW / 2 : _left + plotW * i / (n - 1),
          _top + plotH * (1 - values[i] / maxV),
        ),
    ];

    // Area fill.
    final area = Path()..moveTo(pts.first.dx, baseY);
    for (final p in pts) {
      area.lineTo(p.dx, p.dy);
    }
    area
      ..lineTo(pts.last.dx, baseY)
      ..close();
    final rect = Rect.fromLTRB(_left, _top, size.width - _right, baseY);
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [line.withAlpha(115), line.withAlpha(10)],
        ).createShader(rect),
    );

    // Line (2px).
    if (n > 1) {
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final p in pts.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = line
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round,
      );
    }

    // X labels.
    final every = n > 10 ? 2 : 1;
    for (var i = 0; i < n; i += every) {
      _text(canvas, labels[i], Offset(pts[i].dx, baseY + 16), center: true);
    }

    // Point markers.
    if (n <= 14) {
      for (final p in pts) {
        canvas.drawCircle(p, 4, Paint()..color = Colors.white);
        canvas.drawCircle(
          p,
          4,
          Paint()
            ..color = line
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }

    // Hover crosshair + tooltip.
    final h = hover;
    if (h != null && h >= 0 && h < n) {
      final p = pts[h];
      canvas.drawLine(
        Offset(p.dx, _top),
        Offset(p.dx, baseY),
        Paint()
          ..color = highlight.withAlpha(90)
          ..strokeWidth = 1,
      );
      canvas.drawCircle(p, 6.5, Paint()..color = Colors.white);
      canvas.drawCircle(p, 5, Paint()..color = highlight);
      _tooltip(canvas, size, p,
          '${labels[h]} · ${values[h].toStringAsFixed(1)} kWh');
    }
  }

  void _text(Canvas canvas, String text, Offset anchor,
      {bool alignRight = false, bool center = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(fontSize: 11.5, color: WebColors.muted),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = alignRight
        ? anchor.dx - tp.width
        : center
            ? anchor.dx - tp.width / 2
            : anchor.dx;
    tp.paint(canvas, Offset(dx, anchor.dy - tp.height / 2));
  }

  void _tooltip(Canvas canvas, Size size, Offset p, String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
            color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    const padH = 10.0;
    const padV = 6.0;
    final w = tp.width + padH * 2;
    final hgt = tp.height + padV * 2;
    final left =
        (p.dx - w / 2).clamp(0.0, math.max(0.0, size.width - w)).toDouble();
    var top = p.dy - hgt - 12;
    if (top < 0) top = p.dy + 12;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(left, top, w, hgt), const Radius.circular(8)),
      Paint()..color = AppColors.textDark,
    );
    tp.paint(canvas, Offset(left + padH, top + padV));
  }

  @override
  bool shouldRepaint(covariant _AreaChartPainter oldDelegate) => true;
}

class _DonutPainter extends CustomPainter {
  final List<double> values;
  final List<Color> colors;
  final Color track;
  static const double stroke = 20;

  _DonutPainter({
    required this.values,
    required this.colors,
    required this.track,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.width, size.height) / 2 - stroke / 2;
    final c = size.center(Offset.zero);
    final rect = Rect.fromCircle(center: c, radius: r);
    final total = values.fold<double>(0, (a, b) => a + b);
    if (total <= 0) {
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..color = track
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke,
      );
      return;
    }
    // A small gap between segments so neighbours stay distinct.
    final nonZero = values.where((v) => v > 0).length;
    final gap = nonZero > 1 ? 0.035 : 0.0;
    var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      final sweep = 2 * math.pi * values[i] / total;
      if (sweep <= 0) continue;
      canvas.drawArc(
        rect,
        start + gap / 2,
        math.max(0.0, sweep - gap),
        false,
        Paint()
          ..color = colors[i]
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter oldDelegate) => true;
}

// ── Helpers ──────────────────────────────────────────────────────────────

double _toDouble(Object? v) =>
    v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0.0;

bool _isOnline(Object? lastSeen) {
  if (lastSeen is! num || lastSeen == 0) return false;
  final dt = DateTime.fromMillisecondsSinceEpoch(lastSeen.toInt());
  return DateTime.now().difference(dt).inMinutes < 2;
}

/// Maps a device's `utility` field onto the three utilities every building
/// has. Anything unrecognised is grouped under "Other".
String _utilityOf(Map<String, dynamic> d) {
  final u = (d['utility'] ?? d['type'] ?? '').toString().toLowerCase();
  if (u.contains('light')) return 'Lights';
  if (u.contains('outlet') || u.contains('socket') || u.contains('plug')) {
    return 'Outlets';
  }
  if (u == 'ac' || u.startsWith('ac ') || u.startsWith('ac_') ||
      u.contains('air') || u.contains('aircon')) {
    return 'AC';
  }
  return 'Other';
}

/// Groups the view model's `utilityTotals` (keys like "Lights", "Ac")
/// into Lights / Outlets / AC (+ Other when non-zero), in that order.
Map<String, double> _normalizeUtilities(Map<String, double> raw) {
  final out = <String, double>{'Lights': 0, 'Outlets': 0, 'AC': 0};
  raw.forEach((key, value) {
    final k = _utilityOf({'utility': key});
    out[k] = (out[k] ?? 0) + value;
  });
  if ((out['Other'] ?? 0) <= 0) out.remove('Other');
  return out;
}

/// Same thresholds as `_energyLevelForValue` in the dashboard shell --
/// keep the two in sync.
String _levelFor(double kwh) {
  if (kwh >= 100) return 'HIGH';
  if (kwh >= 50) return 'MID';
  return 'LOW';
}

Color _levelColor(String level) {
  switch (level) {
    case 'HIGH':
      return AppColors.error;
    case 'MID':
      return AppColors.warning;
    default:
      return AppColors.greenMid;
  }
}

double _niceMax(double v) {
  if (v <= 0) return 10;
  final exp = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
  final f = v / exp;
  final double nice;
  if (f <= 1) {
    nice = 1;
  } else if (f <= 2) {
    nice = 2;
  } else if (f <= 2.5) {
    nice = 2.5;
  } else if (f <= 5) {
    nice = 5;
  } else {
    nice = 10;
  }
  return nice * exp;
}

String _fmtAxis(double v) {
  if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
  return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}

String _fmt(double v) {
  if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
  if (v >= 10000) return '${(v / 1000).toStringAsFixed(1)}k';
  return v.toStringAsFixed(1);
}

String _fmtPeso(double v) =>
    '₱${v >= 10000 ? _fmt(v) : v.toStringAsFixed(0)}';

String _shortLabel(String s) {
  final dt = DateTime.tryParse(s);
  if (dt != null) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days[dt.weekday - 1];
  }
  return s.length > 6 ? s.substring(s.length - 5) : s;
}
