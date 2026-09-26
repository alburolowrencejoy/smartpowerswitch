import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme/institute_colors.dart';
import '../web_theme.dart';
import 'analytics_data.dart';
import 'analytics_ui.dart';
import '../../../theme/app_fonts.dart';

/// What a breakdown drawer is about.
enum BreakdownKind { utility, building, room }

/// Opens the right-side breakdown drawer (460 px) over a dimmed background.
/// It closes with ×, Esc or a click outside. [rows] are the rows of the
/// active filters; the drawer keeps only the ones that belong to [id].
Future<void> showBreakdownPanel(
  BuildContext context, {
  required BreakdownKind kind,
  required String id,
  required String rangeName,
  required List<UsageRow> rows,
  required double cardTotal,
  required Map<String, DeviceMeta> devices,
  required Map<String, String> buildingNames,
  required double rate,
  required ValueChanged<DeviceMeta>? onOpenDevice,
}) {
  final palette = context.institutePalette;
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close breakdown',
    barrierColor: const Color(0x590E2E1A),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (dialogContext, _, __) => InheritedTheme.captureAll(
      context,
      Align(
        alignment: Alignment.centerRight,
        child: BreakdownPanel(
          kind: kind,
          id: id,
          rangeName: rangeName,
          rows: rows,
          cardTotal: cardTotal,
          devices: devices,
          buildingNames: buildingNames,
          rate: rate,
          palette: palette,
          onClose: () => Navigator.of(dialogContext).pop(),
          onOpenDevice: onOpenDevice == null
              ? null
              : (d) {
                  Navigator.of(dialogContext).pop();
                  onOpenDevice(d);
                },
        ),
      ),
    ),
    transitionBuilder: (context, anim, _, child) {
      final reduce = MediaQuery.of(context).disableAnimations;
      if (reduce) return child;
      final t = CurvedAnimation(parent: anim, curve: Curves.easeOut);
      return FadeTransition(
        opacity: t,
        child: AnimatedBuilder(
          animation: t,
          builder: (_, c) => Transform.translate(
              offset: Offset(30 * (1 - t.value), 0), child: c),
          child: child,
        ),
      );
    },
  );
}

class BreakdownPanel extends StatelessWidget {
  final BreakdownKind kind;
  final String id;
  final String rangeName;
  final List<UsageRow> rows;
  final double cardTotal;
  final Map<String, DeviceMeta> devices;
  final Map<String, String> buildingNames;
  final double rate;
  final InstitutePalette palette;
  final VoidCallback onClose;
  final ValueChanged<DeviceMeta>? onOpenDevice;

  const BreakdownPanel({
    super.key,
    required this.kind,
    required this.id,
    required this.rangeName,
    required this.rows,
    required this.cardTotal,
    required this.devices,
    required this.buildingNames,
    required this.rate,
    required this.palette,
    required this.onClose,
    required this.onOpenDevice,
  });

  bool _belongs(UsageRow r) => switch (kind) {
        BreakdownKind.utility => r.utility == id,
        BreakdownKind.building => r.building == id,
        BreakdownKind.room => r.roomKey == id,
      };

  String _bName(String code) => buildingNames[code] ?? code;

  String get _title {
    switch (kind) {
      case BreakdownKind.utility:
        return id;
      case BreakdownKind.building:
        return _bName(id);
      case BreakdownKind.room:
        final parts = id.split('|');
        return '${parts.length > 2 ? parts[2] : id} · Floor ${parts.length > 1 ? parts[1] : ''}';
    }
  }

  String get _kindLabel => switch (kind) {
        BreakdownKind.utility => 'Utility',
        BreakdownKind.building => 'Institute',
        BreakdownKind.room => 'Room',
      };

  String get _ofAll => switch (kind) {
        BreakdownKind.utility => 'utilities',
        BreakdownKind.building => 'institutes',
        BreakdownKind.room => 'rooms',
      };

  @override
  Widget build(BuildContext context) {
    final mine = rows.where(_belongs).toList();
    final total = sumKwh(mine);
    // Stored per-record costs, so past days keep the rate they were billed at.
    final cost = sumCost(mine);
    final avgRate = total > 0 ? cost / total : rate;
    final byDevice = groupSum(mine.where((r) => r.deviceId.isNotEmpty),
        (r) => r.deviceId);
    // Every device of this group, including ones that reported nothing.
    final ids = <String>{
      ...byDevice.map((e) => e.key),
      for (final r in mine)
        if (r.deviceId.isNotEmpty) r.deviceId,
    };
    final offline =
        ids.where((d) => devices[d] != null && !devices[d]!.online).length;
    final width = math.min(460.0, MediaQuery.sizeOf(context).width);

    UsageRow? sample(String deviceId) {
      for (final r in mine) {
        if (r.deviceId == deviceId) return r;
      }
      return null;
    }

    // ── plain-language summary ─────────────────────────────────────────
    InlineSpan? note;
    if (total > 0) {
      final groups = groupSum(
          mine,
          (r) => kind == BreakdownKind.utility
              ? r.building
              : r.utility);
      final g = groups.first;
      final gPct = (g.value / total * 100).round();
      final lead = byDevice.isEmpty ? null : byDevice.first;
      final leadRow = lead == null ? null : sample(lead.key);
      final leadPct = lead == null ? 0 : (lead.value / total * 100).round();
      const b = TextStyle(fontWeight: FontWeight.w700);
      final whose = kind == BreakdownKind.room ? "room's" : "building's";
      note = TextSpan(children: [
        if (kind == BreakdownKind.utility) ...[
          TextSpan(text: _bName(g.key), style: b),
          TextSpan(text: ' uses the most $id ($gPct%).'),
        ] else ...[
          TextSpan(text: g.key, style: b),
          TextSpan(text: ' is the biggest source here ($gPct% of the $whose use).'),
        ],
        if (lead != null && leadRow != null) ...[
          const TextSpan(text: ' The single biggest device is '),
          TextSpan(text: lead.key, style: b),
          TextSpan(
              text: kind == BreakdownKind.utility
                  ? ' in ${_roomText(leadRow)}, ${leadRow.building}, at $leadPct% of the total.'
                  : ' (${leadRow.utility}, ${_roomText(leadRow)}) at $leadPct%.'),
        ],
      ]);
    }

    return Material(
      color: Colors.white,
      elevation: 0,
      child: Container(
        width: width,
        height: double.infinity,
        decoration: const BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
                color: Color(0x2E000000),
                blurRadius: 34,
                offset: Offset(-12, 0)),
          ],
        ),
        child: SafeArea(
          left: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('$_kindLabel breakdown · $rangeName',
                              style: const TextStyle(
                                  fontSize: 12.5, color: WebColors.muted)),
                          const SizedBox(height: 4),
                          Row(children: [
                            if (kind == BreakdownKind.building) _code(id),
                            Flexible(
                              child: Text(_title,
                                  style: const TextStyle(
                                      fontFamily: AppFonts.family,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w700,
                                      color: WebColors.ink)),
                            ),
                          ]),
                        ]),
                  ),
                  HoverRegion(
                    semanticLabel: 'Close',
                    onTap: onClose,
                    builder: (context, hovered) => Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: hovered
                            ? palette.pale.withAlpha(153)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(Icons.close_rounded,
                          size: 18, color: palette.dark),
                    ),
                  ),
                ]),
                const SizedBox(height: 14),
                Text.rich(TextSpan(children: [
                  TextSpan(
                      text: total.toStringAsFixed(1),
                      style: const TextStyle(
                          fontFamily: AppFonts.family,
                          fontSize: 34,
                          fontWeight: FontWeight.w700,
                          color: WebColors.ink)),
                  TextSpan(
                      text:
                          ' kWh · ${cardTotal <= 0 ? 0 : (total / cardTotal * 100).round()}% of all $_ofAll',
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: WebColors.muted)),
                ])),
                const SizedBox(height: 2),
                Text.rich(
                  TextSpan(
                      style:
                          const TextStyle(fontSize: 12.5, color: WebColors.muted),
                      children: [
                        TextSpan(
                            text:
                                '₱${_money(cost)} at ₱${avgRate.toStringAsFixed(2)} ${(avgRate - rate).abs() < 0.005 ? '' : 'avg '}per kWh · ${ids.length} device${ids.length == 1 ? '' : 's'}'),
                        if (offline > 0)
                          TextSpan(
                              text: ' · $offline offline',
                              style: const TextStyle(
                                  color: AnalyticsUi.danger,
                                  fontWeight: FontWeight.w600)),
                      ]),
                ),
                if (note != null)
                  Container(
                    margin: const EdgeInsets.fromLTRB(0, 14, 0, 4),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: WebColors.track,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text.rich(note,
                        style: const TextStyle(
                            fontSize: 13.5, height: 1.45, color: WebColors.ink)),
                  ),
                if (total <= 0)
                  const Padding(
                    padding: EdgeInsets.only(top: 18),
                    child: Text('No usage recorded for these filters.',
                        style: TextStyle(fontSize: 14, color: WebColors.mid)),
                  )
                else ..._splits(mine, total),
                ..._topDevices(byDevice, total, sample),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _splits(List<UsageRow> mine, double total) {
    final out = <Widget>[];
    if (kind == BreakdownKind.utility) {
      out
        ..add(_h3('By building'))
        ..add(_group(
          groupSum(mine, (r) => r.building),
          total,
          label: (k) => Row(children: [
            _code(k.isEmpty ? '—' : k),
            Flexible(child: Text(_bName(k), overflow: TextOverflow.ellipsis)),
          ]),
          color: (k, i) => AnalyticsUi.buildingColor(k, i),
        ));
    } else {
      out
        ..add(_h3('By utility'))
        ..add(_group(
          groupSum(mine, (r) => r.utility),
          total,
          label: (k) => Text(k),
          color: (k, _) => AnalyticsUi.utilityColor(k),
        ));
    }
    if (kind != BreakdownKind.room) {
      final perDevice = mine.where((r) => r.deviceId.isNotEmpty);
      var rooms = groupSum(
          perDevice,
          (r) =>
              '${kind == BreakdownKind.utility ? '${r.building} · ' : ''}Floor ${r.floor} · ${r.room.isEmpty ? 'No room' : r.room}');
      if (rooms.length > 7) {
        final rest = rooms.sublist(6);
        rooms = [
          ...rooms.sublist(0, 6),
          MapEntry('${rest.length} other rooms',
              rest.fold<double>(0, (a, e) => a + e.value)),
        ];
      }
      if (rooms.isNotEmpty) {
        out
          ..add(_h3('By room'))
          ..add(_group(
            rooms,
            total,
            label: (k) => Text(k, overflow: TextOverflow.ellipsis),
            color: (k, i) => k.endsWith('other rooms')
                ? const Color(0xFFD5DED8)
                : AnalyticsUi.shades[i % AnalyticsUi.shades.length],
          ));
      }
    }
    return out;
  }

  List<Widget> _topDevices(List<MapEntry<String, double>> byDevice,
      double total, UsageRow? Function(String) sample) {
    if (byDevice.isEmpty) return const [];
    final shown = byDevice.take(8).toList();
    return [
      Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 10),
        child: Text.rich(TextSpan(children: [
          const TextSpan(
              text: 'Top devices',
              style: TextStyle(
                  fontFamily: AppFonts.family,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: WebColors.ink)),
          if (byDevice.length > 8)
            TextSpan(
                text: '  (8 of ${byDevice.length})',
                style: const TextStyle(fontSize: 12.5, color: WebColors.muted)),
        ])),
      ),
      for (final e in shown) _deviceRow(e, total, sample(e.key)),
      if (onOpenDevice != null)
        const Padding(
          padding: EdgeInsets.only(top: 14),
          child: Text('Click a device to open it.',
              style: TextStyle(fontSize: 12.5, color: WebColors.muted)),
        ),
    ];
  }

  Widget _deviceRow(MapEntry<String, double> e, double total, UsageRow? r) {
    final m = devices[e.key];
    final status = m == null
        ? 'Unknown'
        : !m.online
            ? 'Offline'
            : m.relay
                ? 'On now'
                : 'Off now';
    final dot = m == null || !m.online
        ? AnalyticsUi.off
        : m.relay
            ? const Color(0xFF2E9E52)
            : AnalyticsUi.warn;
    final canOpen = m != null && onOpenDevice != null;
    return HoverRegion(
      semanticLabel: 'Open ${e.key}',
      onTap: canOpen ? () => onOpenDevice!(m) : null,
      builder: (context, hovered) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: hovered ? palette.pale.withAlpha(89) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          Tooltip(
            message: status,
            child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(e.key,
                  style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: WebColors.ink)),
              Text(
                r == null
                    ? status
                    : '${r.utility} · ${_roomText(r)}, Floor ${r.floor} · ${r.building} · $status',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: WebColors.muted),
              ),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${e.value.toStringAsFixed(1)} kWh',
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: WebColors.ink)),
            Text('${total <= 0 ? 0 : (e.value / total * 100).round()}%',
                style: const TextStyle(fontSize: 11.5, color: WebColors.muted)),
          ]),
          const SizedBox(width: 8),
          Text('›',
              style: TextStyle(
                  fontSize: 16,
                  color: hovered ? palette.dark : WebColors.muted)),
        ]),
      ),
    );
  }

  static String _roomText(UsageRow r) => r.room.isEmpty ? 'No room' : r.room;

  Widget _h3(String t) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 10),
        child: Text(t,
            style: const TextStyle(
                fontFamily: AppFonts.family,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: WebColors.ink)),
      );

  Widget _code(String c) => Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: palette.pale.withAlpha(153),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(c,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: palette.dark)),
      );

  /// A stacked bar followed by one legend row per group.
  Widget _group(
    List<MapEntry<String, double>> groups,
    double total, {
    required Widget Function(String key) label,
    required Color Function(String key, int index) color,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          height: 14,
          child: Row(children: [
            for (var i = 0; i < groups.length; i++) ...[
              if (i > 0) const SizedBox(width: 2),
              Expanded(
                flex: math.max(1, (groups[i].value / total * 1000).round()),
                child: Tooltip(
                  message:
                      '${groups[i].key}: ${groups[i].value.toStringAsFixed(1)} kWh',
                  child: ColoredBox(color: color(groups[i].key, i)),
                ),
              ),
            ],
          ]),
        ),
      ),
      const SizedBox(height: 12),
      for (var i = 0; i < groups.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: DefaultTextStyle.merge(
            style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: WebColors.ink),
            child: Row(children: [
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                    color: color(groups[i].key, i),
                    borderRadius: BorderRadius.circular(3)),
              ),
              Expanded(child: label(groups[i].key)),
              const SizedBox(width: 8),
              Text(
                  '${groups[i].value.toStringAsFixed(1)} kWh · ${(groups[i].value / total * 100).round()}%',
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: WebColors.muted)),
            ]),
          ),
        ),
    ]);
  }
}

String _money(double v) {
  final whole = v.round().toString();
  return whole.replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
}
