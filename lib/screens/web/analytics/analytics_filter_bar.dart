import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/institute_colors.dart';
import '../web_theme.dart';
import 'analytics_data.dart';
import 'analytics_filter.dart';
import 'analytics_ui.dart';
import '../../../theme/app_fonts.dart';

/// A building offered in the Scope panel.
@immutable
class BuildingInfo {
  final String code;
  final String name;
  final int floors;
  const BuildingInfo(this.code, this.name, this.floors);
}

enum _Chunk { range, group, scope, util, more }

/// The Analytics filter bar: one rounded bar of five chunks (Time range,
/// Group by, Scope, Utility, More). Clicking a chunk opens its panel just
/// below it; only one panel is open at a time, and Esc or a click outside
/// closes it. Active filters show as removable chips under the bar.
class AnalyticsFilterBar extends StatefulWidget {
  final AnalyticsFilter filter;
  final ValueChanged<AnalyticsFilter> onChanged;
  final List<BuildingInfo> buildings;
  final Map<String, DeviceMeta> devices;

  const AnalyticsFilterBar({
    super.key,
    required this.filter,
    required this.onChanged,
    required this.buildings,
    required this.devices,
  });

  @override
  State<AnalyticsFilterBar> createState() => _AnalyticsFilterBarState();
}

class _AnalyticsFilterBarState extends State<AnalyticsFilterBar> {
  _Chunk? _open;
  OverlayEntry? _entry;
  final _links = {for (final c in _Chunk.values) c: LayerLink()};
  final _keys = {for (final c in _Chunk.values) c: GlobalKey()};

  @override
  void didUpdateWidget(covariant AnalyticsFilterBar old) {
    super.didUpdateWidget(old);
    // Panels like "More" apply instantly and stay open; rebuild them.
    if (_entry != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _entry?.markNeedsBuild();
      });
    }
  }

  @override
  void dispose() {
    _removeEntry();
    super.dispose();
  }

  void _removeEntry() {
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
  }

  void _toggle(_Chunk c) {
    if (_open == c) {
      _close();
    } else {
      _openChunk(c);
    }
  }

  void _openChunk(_Chunk c) {
    _removeEntry();
    setState(() => _open = c);
    _entry = OverlayEntry(builder: _buildOverlay);
    Overlay.of(context).insert(_entry!);
  }

  void _close() {
    _removeEntry();
    if (mounted) setState(() => _open = null);
  }

  void _apply(AnalyticsFilter f, {bool close = true}) {
    if (close) _close();
    widget.onChanged(f.withValidGroup());
  }

  Rect? _chunkRect(_Chunk c) {
    final box = _keys[c]!.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  double _panelWidth(_Chunk c, AnalyticsFilter f, bool customDraft) {
    switch (c) {
      case _Chunk.range:
        return customDraft ? 590 : 300;
      case _Chunk.more:
        return 370;
      default:
        return 300;
    }
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final c = _open;
    if (c == null) return const SizedBox.shrink();
    final screen = MediaQuery.sizeOf(overlayContext);
    final rect = _chunkRect(c);
    final palette = context.institutePalette;

    // The overlay sits above the web shell's Theme; carry it (DM Sans,
    // institute palette) over to the panel.
    return InheritedTheme.captureAll(context, Stack(children: [
      // Click outside closes. Translucent, so the click still reaches what
      // is underneath (e.g. another chunk, which then opens instead).
      Positioned.fill(
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (e) {
            final r = _chunkRect(c);
            if (r != null && r.contains(e.position)) return; // chunk toggles
            _close();
          },
        ),
      ),
      Positioned(
        left: 0,
        top: 0,
        child: CompositedTransformFollower(
          link: _links[c]!,
          targetAnchor: Alignment.bottomLeft,
          showWhenUnlinked: false,
          child: Builder(builder: (_) {
            return _PanelHost(
              key: ValueKey(c),
              chunk: c,
              filter: widget.filter,
              buildings: widget.buildings,
              devices: widget.devices,
              palette: palette,
              onApply: _apply,
              onClose: _close,
              layout: (customDraft) {
                final want = _panelWidth(c, widget.filter, customDraft);
                final w = math.min(want, screen.width - 32);
                final left = rect == null
                    ? 0.0
                    : (rect.left.clamp(16.0, math.max(16.0, screen.width - w - 16)) -
                        rect.left);
                final maxH = rect == null
                    ? 480.0
                    : math.max(260.0, screen.height - rect.bottom - 24);
                return (dx: left, width: w, maxHeight: maxH);
              },
            );
          }),
        ),
      ),
    ]));
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.filter;
    final p = context.institutePalette;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Flexible(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: p.mid.withAlpha(56)),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x0A000000),
                    blurRadius: 14,
                    offset: Offset(0, 4)),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(13),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: IntrinsicHeight(
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    _chunk(_Chunk.range, Icons.calendar_today_outlined,
                        'Time range', f.rangeName),
                    _divider(),
                    _chunk(_Chunk.group, Icons.bar_chart_rounded, 'Group by',
                        f.group.label),
                    _divider(),
                    _chunk(_Chunk.scope, Icons.apartment_outlined, 'Scope',
                        f.scopeName),
                    _divider(),
                    _chunk(_Chunk.util, Icons.bolt_outlined, 'Utility',
                        f.utilityName),
                    _divider(),
                    _chunk(_Chunk.more, Icons.tune_rounded, 'More',
                        f.moreCount == 0 ? 'None' : '${f.moreCount} on'),
                  ]),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        _ResetLink(
          enabled: !f.isDefault,
          color: p.dark,
          onTap: () => _apply(AnalyticsFilter.defaults),
        ),
      ]),
      ..._chips(f, p),
    ]);
  }

  Widget _divider() =>
      const VerticalDivider(width: 1, thickness: 1, color: AnalyticsUi.line);

  Widget _chunk(_Chunk c, IconData icon, String label, String value) {
    final p = context.institutePalette;
    final open = _open == c;
    return CompositedTransformTarget(
      link: _links[c]!,
      child: HoverRegion(
        key: _keys[c],
        semanticLabel: '$label: $value',
        onTap: () => _toggle(c),
        builder: (context, hovered) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          color: open
              ? p.pale.withAlpha(153)
              : hovered
                  ? p.pale.withAlpha(77)
                  : Colors.transparent,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 20, color: p.dark),
            const SizedBox(width: 10),
            Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: WebColors.muted)),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 190),
                    child: Text(value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: WebColors.ink)),
                  ),
                ]),
            const SizedBox(width: 8),
            AnimatedRotation(
              turns: open ? 0.5 : 0,
              duration: const Duration(milliseconds: 150),
              child: const Icon(Icons.keyboard_arrow_down_rounded,
                  size: 18, color: WebColors.muted),
            ),
          ]),
        ),
      ),
    );
  }

  List<Widget> _chips(AnalyticsFilter f, InstitutePalette p) {
    final chips = <(String, AnalyticsFilter)>[];
    if (f.range != RangePreset.last30) {
      chips.add((f.rangeName, f.withRange(RangePreset.last30)));
    }
    if (!f.isDefaultGroup) {
      chips.add((f.group.label, f.copyWith(group: suggestedGroup(f.days))));
    }
    if (f.hasScope) chips.add((f.scopeName, f.clearedScope()));
    if (f.hasUtility) {
      chips.add((f.utilityName, f.copyWith(utilities: const [])));
    }
    if (f.dayType != DayType.all) {
      chips.add((f.dayType.label, f.copyWith(dayType: DayType.all)));
    }
    if (f.timeOfDay != TimeOfDayFilter.all) {
      chips.add(
          (f.timeOfDay.label, f.copyWith(timeOfDay: TimeOfDayFilter.all)));
    }
    if (f.compare != CompareMode.off) {
      chips.add((
        f.compare == CompareMode.previous
            ? 'vs previous period'
            : 'vs last year',
        f.copyWith(compare: CompareMode.off)
      ));
    }
    if (f.metric != ValueMetric.kwh) {
      chips.add((f.metric.label, f.copyWith(metric: ValueMetric.kwh)));
    }
    if (chips.isEmpty) return const [];
    return [
      const SizedBox(height: 10),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final (label, next) in chips)
          HoverRegion(
            semanticLabel: 'Remove filter: $label',
            onTap: () => _apply(next),
            builder: (context, hovered) => Container(
              padding: const EdgeInsets.fromLTRB(11, 4, 6, 4),
              decoration: BoxDecoration(
                color: p.pale.withAlpha(153),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: p.mid.withAlpha(77)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: p.dark)),
                const SizedBox(width: 6),
                Container(
                  width: 18,
                  height: 18,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: hovered ? p.dark.withAlpha(36) : Colors.transparent,
                  ),
                  child: Text('×',
                      style: TextStyle(
                          fontSize: 14, height: 1, color: p.dark)),
                ),
              ]),
            ),
          ),
      ]),
    ];
  }
}

class _ResetLink extends StatelessWidget {
  final bool enabled;
  final Color color;
  final VoidCallback onTap;
  const _ResetLink(
      {required this.enabled, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: HoverRegion(
        semanticLabel: 'Reset filters',
        onTap: enabled ? onTap : null,
        builder: (context, hovered) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: hovered ? const Color(0x73C2EDD0) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text('Reset',
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: color)),
        ),
      ),
    );
  }
}

typedef _PanelLayout = ({double dx, double width, double maxHeight});

/// The dropdown panel of one chunk. Keeps a draft for the panels that apply
/// with a button (custom range, scope, utility).
class _PanelHost extends StatefulWidget {
  final _Chunk chunk;
  final AnalyticsFilter filter;
  final List<BuildingInfo> buildings;
  final Map<String, DeviceMeta> devices;
  final InstitutePalette palette;
  final void Function(AnalyticsFilter f, {bool close}) onApply;
  final VoidCallback onClose;
  final _PanelLayout Function(bool customDraft) layout;

  const _PanelHost({
    super.key,
    required this.chunk,
    required this.filter,
    required this.buildings,
    required this.devices,
    required this.palette,
    required this.onApply,
    required this.onClose,
    required this.layout,
  });

  @override
  State<_PanelHost> createState() => _PanelHostState();
}

class _PanelHostState extends State<_PanelHost> {
  late AnalyticsFilter _draft = widget.filter;
  late bool _customDraft = widget.filter.range == RangePreset.custom;
  DateTime? _from;
  DateTime? _to;
  late DateTime _month;

  InstitutePalette get p => widget.palette;

  @override
  void initState() {
    super.initState();
    final f = widget.filter;
    if (f.range == RangePreset.custom && f.from != null) {
      _from = dateOnly(f.from!);
      _to = f.to == null ? null : dateOnly(f.to!);
    }
    final shown = _from ?? DateTime.now();
    _month = DateTime(shown.year, shown.month, 1);
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.layout(widget.chunk == _Chunk.range && _customDraft);
    final Widget body = switch (widget.chunk) {
      _Chunk.range => _rangePanel(l.width),
      _Chunk.group => _groupPanel(),
      _Chunk.scope => _scopePanel(),
      _Chunk.util => _utilPanel(),
      _Chunk.more => _morePanel(),
    };
    return Transform.translate(
      offset: Offset(l.dx, 8),
      child: Focus(
        autofocus: true,
        onKeyEvent: (node, e) {
          if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
            widget.onClose();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Material(
          color: Colors.white,
          elevation: 0,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: l.width,
            constraints: BoxConstraints(maxHeight: l.maxHeight),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AnalyticsUi.line),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x2E000000),
                    blurRadius: 34,
                    offset: Offset(0, 14)),
              ],
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(10),
              child: DefaultTextStyle.merge(
                style: const TextStyle(color: WebColors.ink),
                child: body,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── shared bits ──────────────────────────────────────────────────────

  Widget _option({
    required String title,
    required String subtitle,
    required bool selected,
    VoidCallback? onTap,
  }) {
    return Opacity(
      opacity: onTap == null ? 0.5 : 1,
      child: HoverRegion(
        onTap: onTap,
        semanticLabel: title,
        builder: (context, hovered) => Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: selected
                ? p.pale.withAlpha(166)
                : hovered
                    ? p.pale.withAlpha(102)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: selected ? p.dark : WebColors.ink)),
            const SizedBox(height: 1),
            Text(subtitle,
                style: const TextStyle(fontSize: 12, color: WebColors.muted)),
          ]),
        ),
      ),
    );
  }

  Widget _section(String text, {bool first = false}) => Padding(
        padding: EdgeInsets.fromLTRB(2, first ? 2 : 12, 2, 6),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: WebColors.mid)),
      );

  Widget _check({
    required bool value,
    required Widget label,
    required VoidCallback onTap,
  }) {
    return HoverRegion(
      onTap: onTap,
      builder: (context, hovered) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: hovered ? p.pale.withAlpha(89) : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(children: [
          SizedBox(
            width: 20,
            height: 20,
            child: Checkbox(
              value: value,
              onChanged: (_) => onTap(),
              activeColor: p.dark,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: label),
        ]),
      ),
    );
  }

  Widget _foot({
    Widget? left,
    VoidCallback? onClear,
    required VoidCallback? onApply,
  }) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.only(top: 10),
      decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AnalyticsUi.line))),
      child: Row(children: [
        if (left != null) Expanded(child: left),
        if (onClear != null)
          TextButton(
            onPressed: onClear,
            style: TextButton.styleFrom(foregroundColor: p.dark),
            child: const Text('Clear'),
          ),
        if (left == null) const Spacer(),
        ElevatedButton(
          onPressed: onApply,
          style: ElevatedButton.styleFrom(
            backgroundColor: p.dark,
            foregroundColor: Colors.white,
            disabledBackgroundColor: p.dark.withAlpha(128),
            disabledForegroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('Apply'),
        ),
      ]),
    );
  }

  Widget _codeChip(String code) => Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: p.pale.withAlpha(153),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(code,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: p.dark)),
      );

  // ── Time range ───────────────────────────────────────────────────────

  Widget _rangePanel(double width) {
    final today = DateTime.now();
    final list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in RangePreset.values)
          _option(
            title: r.label,
            subtitle: r == RangePreset.custom
                ? 'Pick dates on a calendar'
                : spanText(presetSpan(r, today)),
            selected: r == RangePreset.custom
                ? _customDraft
                : (!_customDraft && widget.filter.range == r),
            onTap: () {
              if (r == RangePreset.custom) {
                setState(() => _customDraft = true);
              } else {
                widget.onApply(widget.filter.withRange(r));
              }
            },
          ),
      ],
    );
    if (!_customDraft) return list;

    final picked = _from == null
        ? null
        : DateTimeRange(start: _from!, end: _to ?? _from!);
    final cal = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _RangeCalendar(
        month: _month,
        from: _from,
        to: _to,
        palette: p,
        onMonth: (m) => setState(() => _month = m),
        onPick: (a, b) => setState(() {
          _from = a;
          _to = b;
        }),
      ),
      const SizedBox(height: 8),
      const Text('Click a day, or click two days (or drag) for a range.',
          style: TextStyle(fontSize: 12, color: WebColors.muted)),
      _foot(
        left: Text(
          picked == null
              ? 'No dates picked yet'
              : '${spanText(picked)} · ${spanDays(picked)} days',
          style: const TextStyle(fontSize: 12, color: WebColors.muted),
        ),
        onApply: _from == null
            ? null
            : () => widget.onApply(widget.filter
                .withRange(RangePreset.custom, from: _from, to: _to ?? _from)),
      ),
    ]);

    if (width < 560) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        list,
        const SizedBox(height: 10),
        cal,
      ]);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 200, child: list),
      const SizedBox(width: 12),
      Expanded(child: cal),
    ]);
  }

  // ── Group by ─────────────────────────────────────────────────────────

  Widget _groupPanel() {
    final f = widget.filter;
    final n = f.days;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final g in GroupBy.values)
        _option(
          title: g.label,
          subtitle: !groupAllowed(g, n)
              ? groupDisabledReason(g)
              : g == suggestedGroup(n)
                  ? 'Suggested for this range'
                  : 'Available',
          selected: f.group == g,
          onTap: groupAllowed(g, n)
              ? () => widget.onApply(f.copyWith(group: g))
              : null,
        ),
    ]);
  }

  // ── Scope ────────────────────────────────────────────────────────────

  Widget _scopePanel() {
    final d = _draft;
    final one = d.buildings.length == 1 ? d.buildings.first : null;
    final b = one == null
        ? null
        : widget.buildings.firstWhere((x) => x.code == one,
            orElse: () => BuildingInfo(one, one, 1));

    void setB(List<String> list) {
      final all = widget.buildings.map((x) => x.code).toSet();
      final full = list.toSet().containsAll(all) && list.length >= all.length;
      setState(() => _draft = d.copyWith(
          buildings: full ? const [] : list, floor: 0, room: '', device: ''));
    }

    final inBuilding = one == null
        ? const <DeviceMeta>[]
        : widget.devices.values.where((x) => x.building == one).toList();
    final maxFloor = math.max(
        b?.floors ?? 1,
        inBuilding.fold<int>(1, (a, x) => math.max(a, x.floor)));
    final rooms = <String>{
      for (final x in inBuilding)
        if ((d.floor == 0 || x.floor == d.floor) && x.room.isNotEmpty) x.room
    }.toList()
      ..sort();
    final devs = inBuilding
        .where((x) =>
            (d.floor == 0 || x.floor == d.floor) &&
            (d.room.isEmpty || x.room == d.room))
        .toList()
      ..sort((a, b) => a.id.compareTo(b.id));

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _section('Buildings', first: true),
      _check(
        value: d.buildings.isEmpty,
        label: const Text('All buildings', style: TextStyle(fontSize: 14)),
        onTap: () => setB(const []),
      ),
      for (final x in widget.buildings)
        _check(
          value: d.buildings.contains(x.code),
          label: Row(children: [
            _codeChip(x.code),
            Expanded(
              child: Text(x.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14)),
            ),
          ]),
          onTap: () => setB(d.buildings.contains(x.code)
              ? d.buildings.where((c) => c != x.code).toList()
              : [...d.buildings, x.code]),
        ),
      if (one != null) ...[
        _section('Inside ${b!.name}'),
        _select<int>(
          label: 'Floor',
          value: d.floor,
          items: {
            0: 'All floors',
            for (var i = 1; i <= maxFloor; i++) i: 'Floor $i',
          },
          onChanged: (v) =>
              setState(() => _draft = d.copyWith(floor: v, room: '', device: '')),
        ),
        const SizedBox(height: 8),
        _select<String>(
          label: 'Room',
          value: rooms.contains(d.room) ? d.room : '',
          items: {'': 'All rooms', for (final r in rooms) r: r},
          onChanged: (v) =>
              setState(() => _draft = d.copyWith(room: v, device: '')),
        ),
        const SizedBox(height: 8),
        _select<String>(
          label: 'Device',
          value: devs.any((x) => x.id == d.device) ? d.device : '',
          items: {
            '': 'All devices',
            for (final x in devs)
              x.id: '${x.id} · ${x.utility}${d.room.isEmpty ? ' · ${x.room}' : ''}',
          },
          onChanged: (v) => setState(() => _draft = d.copyWith(device: v)),
        ),
      ] else
        const Padding(
          padding: EdgeInsets.fromLTRB(2, 10, 2, 0),
          child: Text(
              'Pick one building to narrow down to a floor, room or device.',
              style: TextStyle(fontSize: 12, color: WebColors.muted)),
        ),
      _foot(
        onClear: () => setState(() => _draft = d.clearedScope()),
        onApply: () => widget.onApply(widget.filter.copyWith(
          buildings: d.buildings,
          floor: d.floor,
          room: d.room,
          device: d.device,
        )),
      ),
    ]);
  }

  Widget _select<T>({
    required String label,
    required T value,
    required Map<T, String> items,
    required ValueChanged<T> onChanged,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: WebColors.mid)),
      const SizedBox(height: 4),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFFBFEFC),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: p.mid.withAlpha(77)),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: items.containsKey(value) ? value : items.keys.first,
            isExpanded: true,
            isDense: false,
            itemHeight: 48,
            borderRadius: BorderRadius.circular(12),
            style: const TextStyle(fontSize: 14, color: WebColors.ink),
            items: [
              for (final e in items.entries)
                DropdownMenuItem<T>(
                  value: e.key,
                  child: Text(e.value,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: items.length <= 1
                ? null
                : (v) {
                    if (v != null) onChanged(v);
                  },
          ),
        ),
      ),
    ]);
  }

  // ── Utility ──────────────────────────────────────────────────────────

  Widget _utilPanel() {
    final d = _draft;
    void setU(List<String> list) => setState(() => _draft = d.copyWith(
        utilities: list.length >= kUtilities.length ? const [] : list));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _check(
        value: d.utilities.isEmpty,
        label: const Text('All utilities', style: TextStyle(fontSize: 14)),
        onTap: () => setU(const []),
      ),
      for (final u in kUtilities)
        _check(
          value: d.utilities.contains(u),
          label: Row(children: [
            Container(
              width: 10,
              height: 10,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                  color: AnalyticsUi.utilityColor(u),
                  borderRadius: BorderRadius.circular(3)),
            ),
            Text(u, style: const TextStyle(fontSize: 14)),
          ]),
          onTap: () => setU(d.utilities.contains(u)
              ? d.utilities.where((x) => x != u).toList()
              : [...d.utilities, u]),
        ),
      _foot(
        onClear: () => setState(() => _draft = d.copyWith(utilities: const [])),
        onApply: () =>
            widget.onApply(widget.filter.copyWith(utilities: d.utilities)),
      ),
    ]);
  }

  // ── More (applies instantly) ─────────────────────────────────────────

  Widget _morePanel() {
    final f = widget.filter;
    void set(AnalyticsFilter n) => widget.onApply(n, close: false);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _section('Day type', first: true),
      _seg<DayType>(DayType.values, f.dayType, (v) => set(f.copyWith(dayType: v)),
          (v) => v.label),
      _section('Time of day'),
      _seg<TimeOfDayFilter>(
        TimeOfDayFilter.values,
        f.timeOfDay,
        kHasHourlyData ? (v) => set(f.copyWith(timeOfDay: v)) : null,
        (v) => v.label,
      ),
      // TODO(analytics): drop the second sentence once kHasHourlyData is true.
      const Padding(
        padding: EdgeInsets.fromLTRB(2, 6, 2, 0),
        child: Text(
          'Class hours are 7:00 AM to 6:00 PM. Needs hourly readings; '
          'history only has daily totals for now.',
          style: TextStyle(fontSize: 12, color: WebColors.muted),
        ),
      ),
      _section('Compare with'),
      _seg<CompareMode>(CompareMode.values, f.compare,
          (v) => set(f.copyWith(compare: v)), (v) => v.label),
      _section('Show values as'),
      _seg<ValueMetric>(ValueMetric.values, f.metric,
          (v) => set(f.copyWith(metric: v)), (v) => v.label),
    ]);
  }

  Widget _seg<T>(List<T> values, T selected, ValueChanged<T>? onTap,
      String Function(T) label) {
    return Opacity(
      opacity: onTap == null ? 0.5 : 1,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: p.pale.withAlpha(102),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          for (final v in values)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: HoverRegion(
                  semanticLabel: label(v),
                  onTap: onTap == null ? null : () => onTap(v),
                  builder: (context, hovered) => Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: v == selected ? Colors.white : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: v == selected
                          ? const [
                              BoxShadow(
                                  color: Color(0x14000000),
                                  blurRadius: 4,
                                  offset: Offset(0, 1)),
                            ]
                          : null,
                    ),
                    child: Text(label(v),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: v == selected ? p.dark : WebColors.mid)),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Month calendar for the custom range: click one day, click a second day,
/// or drag across days. Future days are disabled.
class _RangeCalendar extends StatefulWidget {
  final DateTime month;
  final DateTime? from;
  final DateTime? to;
  final InstitutePalette palette;
  final ValueChanged<DateTime> onMonth;
  final void Function(DateTime from, DateTime? to) onPick;

  const _RangeCalendar({
    required this.month,
    required this.from,
    required this.to,
    required this.palette,
    required this.onMonth,
    required this.onPick,
  });

  @override
  State<_RangeCalendar> createState() => _RangeCalendarState();
}

class _RangeCalendarState extends State<_RangeCalendar> {
  static const _rowH = 37.0;
  DateTime? _dragStart;
  bool _moved = false;

  DateTime get _today => dateOnly(DateTime.now());

  int get _lead => (widget.month.weekday - 1) % 7;
  int get _days => DateTime(widget.month.year, widget.month.month + 1, 0).day;

  DateTime? _dayAt(Offset local, double width) {
    final col = (local.dx / (width / 7)).floor();
    final row = (local.dy / _rowH).floor();
    if (col < 0 || col > 6 || row < 0) return null;
    final n = row * 7 + col - _lead + 1;
    if (n < 1 || n > _days) return null;
    final d = DateTime(widget.month.year, widget.month.month, n);
    return d.isAfter(_today) ? null : d;
  }

  void _click(DateTime k) {
    final a = widget.from, b = widget.to;
    if (a == null || b != null) {
      widget.onPick(k, null);
    } else if (k.isBefore(a)) {
      widget.onPick(k, null);
    } else if (k.isAfter(a)) {
      widget.onPick(a, k);
    } else {
      widget.onPick(a, null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final m = widget.month;
    final canNext = DateTime(m.year, m.month + 1, 1).isBefore(
        DateTime(_today.year, _today.month + 1, 1));
    final from = widget.from, to = widget.to ?? widget.from;
    final rows = ((_lead + _days) / 7).ceil();

    Widget navBtn(IconData icon, String label, VoidCallback? onTap) => Opacity(
          opacity: onTap == null ? 0.35 : 1,
          child: HoverRegion(
            semanticLabel: label,
            onTap: onTap,
            builder: (context, hovered) => Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: hovered ? p.pale.withAlpha(153) : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 20, color: p.dark),
            ),
          ),
        );

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFBFEFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.mid.withAlpha(64)),
      ),
      child: Column(children: [
        Row(children: [
          navBtn(Icons.chevron_left_rounded, 'Previous month',
              () => widget.onMonth(DateTime(m.year, m.month - 1, 1))),
          Expanded(
            child: Text('${_monthLong[m.month - 1]} ${m.year}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontFamily: AppFonts.family,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: WebColors.ink)),
          ),
          navBtn(Icons.chevron_right_rounded, 'Next month',
              canNext ? () => widget.onMonth(DateTime(m.year, m.month + 1, 1)) : null),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          for (final d in const ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'])
            Expanded(
              child: Text(d,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: WebColors.muted)),
            ),
        ]),
        const SizedBox(height: 4),
        LayoutBuilder(builder: (context, c) {
          final w = c.maxWidth;
          return MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Listener(
              onPointerDown: (e) {
                final d = _dayAt(e.localPosition, w);
                _dragStart = d;
                _moved = false;
              },
              onPointerMove: (e) {
                final s = _dragStart;
                if (s == null) return;
                final d = _dayAt(e.localPosition, w);
                if (d == null || (d == s && !_moved)) return;
                _moved = true;
                widget.onPick(d.isBefore(s) ? d : s, d.isBefore(s) ? s : d);
              },
              onPointerUp: (e) {
                final s = _dragStart;
                _dragStart = null;
                if (s == null || _moved) return;
                if (_dayAt(e.localPosition, w) == s) _click(s);
              },
              child: SizedBox(
                height: rows * _rowH,
                child: Column(children: [
                  for (var r = 0; r < rows; r++)
                    SizedBox(
                      height: _rowH,
                      child: Row(children: [
                        for (var col = 0; col < 7; col++)
                          Expanded(child: _cell(r * 7 + col - _lead + 1, from, to)),
                      ]),
                    ),
                ]),
              ),
            ),
          );
        }),
      ]),
    );
  }

  Widget _cell(int n, DateTime? from, DateTime? to) {
    if (n < 1 || n > _days) return const SizedBox.shrink();
    final p = widget.palette;
    final d = DateTime(widget.month.year, widget.month.month, n);
    final future = d.isAfter(_today);
    final inRange =
        from != null && to != null && !d.isBefore(from) && !d.isAfter(to);
    final edge = d == from || d == to;
    final isToday = d == _today;
    return Semantics(
      button: !future,
      selected: inRange,
      label: fmtDate(d, year: true),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1.5),
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: edge
                ? p.dark
                : inRange
                    ? p.pale.withAlpha(191)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(edge || !inRange ? 9 : 0),
            border: isToday && !edge
                ? Border.all(color: p.mid, width: 1.5)
                : null,
          ),
          child: Text('$n',
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: edge
                      ? Colors.white
                      : future
                          ? const Color(0xFFB7C3BB)
                          : WebColors.ink)),
        ),
      ),
    );
  }
}

const _monthLong = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December'
];
