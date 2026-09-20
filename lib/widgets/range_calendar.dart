// range_calendar.dart
//
// A calendar widget with:
//  - Hover preview (desktop/web, via MouseRegion)
//  - Tap a day to select it as a single day; tap it again to reset
//  - Long-press a day and drag to select a range; tapping afterward resets
//
// Pure Flutter (material), no external packages required.

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

class RangeCalendar extends StatefulWidget {
  final ValueChanged<DateTimeRange?>? onRangeChanged;
  final ValueChanged<DateTime?>? onDaySelected;

  /// Fired with `true` when a long-press-drag starts and `false` when it
  /// ends. If this calendar sits inside a scrollable ancestor (e.g. a
  /// dialog's `SingleChildScrollView`), that scroll view's own drag
  /// recognizer can compete with the calendar's drag-to-select and swallow
  /// it -- use this to temporarily disable the ancestor's scrolling for the
  /// duration of the drag.
  final ValueChanged<bool>? onDragActiveChanged;

  const RangeCalendar({
    super.key,
    this.onRangeChanged,
    this.onDaySelected,
    this.onDragActiveChanged,
  });

  @override
  State<RangeCalendar> createState() => _RangeCalendarState();
}

class _RangeCalendarState extends State<RangeCalendar> {
  late DateTime _visibleMonth; // first day of the visible month
  DateTime? _anchor; // start of selection (single day or range start)
  DateTime? _focusDay; // current end of selection (drag target)
  DateTime? _hoverDay; // mouse hover preview
  bool _longPressActive = false;

  // Must stay stable across rebuilds -- a fresh GlobalKey generated inside
  // build() makes Flutter treat the keyed GestureDetector as a brand-new
  // widget on every setState (every long-press-move event triggers one via
  // _onLongPressMoveUpdate), which tears down its in-flight
  // LongPressGestureRecognizer and kills the drag before it can continue.
  final GlobalKey _gridKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _visibleMonth = DateTime(now.year, now.month, 1);
  }

  bool get _isRange =>
      _anchor != null && _focusDay != null && !_isSameDay(_anchor!, _focusDay!);

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  void _prevMonth() {
    setState(() {
      _visibleMonth = DateTime(_visibleMonth.year, _visibleMonth.month - 1, 1);
    });
  }

  void _nextMonth() {
    setState(() {
      _visibleMonth = DateTime(_visibleMonth.year, _visibleMonth.month + 1, 1);
    });
  }

  void _onLongPressStart(DateTime day) {
    setState(() {
      _longPressActive = true;
      _anchor = day;
      _focusDay = day;
    });
    widget.onDragActiveChanged?.call(true);
  }

  void _onLongPressMoveUpdate(DateTime day) {
    if (!_longPressActive) return;
    if (_focusDay == null || !_isSameDay(_focusDay!, day)) {
      setState(() => _focusDay = day);
    }
  }

  void _onLongPressEnd() {
    if (!_longPressActive) return;
    setState(() => _longPressActive = false);
    widget.onDragActiveChanged?.call(false);
    _emitChange();
  }

  void _onTapDay(DateTime day) {
    if (_longPressActive) return; // ignore stray tap right after a long-press
    setState(() {
      if (_anchor != null &&
          ((!_isRange && _isSameDay(_anchor!, day)) || _isRange)) {
        // tapping resets an existing single selection or range
        _anchor = null;
        _focusDay = null;
      } else {
        // select this single day
        _anchor = day;
        _focusDay = day;
      }
    });
    _emitChange();
  }

  void _emitChange() {
    if (_anchor == null || _focusDay == null) {
      widget.onDaySelected?.call(null);
      widget.onRangeChanged?.call(null);
      return;
    }
    if (_isRange) {
      final lo = _anchor!.isBefore(_focusDay!) ? _anchor! : _focusDay!;
      final hi = _anchor!.isBefore(_focusDay!) ? _focusDay! : _anchor!;
      widget.onRangeChanged?.call(DateTimeRange(start: lo, end: hi));
      widget.onDaySelected?.call(null);
    } else {
      widget.onDaySelected?.call(_anchor);
      widget.onRangeChanged?.call(null);
    }
  }

  List<DateTime?> _daysInGrid() {
    final firstOfMonth = DateTime(_visibleMonth.year, _visibleMonth.month, 1);
    final daysInMonth =
        DateTime(_visibleMonth.year, _visibleMonth.month + 1, 0).day;
    final leadingEmpty = firstOfMonth.weekday % 7; // Sunday=0 ... Saturday=6

    final List<DateTime?> cells = [];
    for (int i = 0; i < leadingEmpty; i++) {
      cells.add(null);
    }
    for (int d = 1; d <= daysInMonth; d++) {
      cells.add(DateTime(_visibleMonth.year, _visibleMonth.month, d));
    }
    return cells;
  }

  String _monthLabel() {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December'
    ];
    return '${months[_visibleMonth.month - 1]} ${_visibleMonth.year}';
  }

  String _fmt(DateTime d) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  String _infoText() {
    if (_anchor != null && _focusDay != null) {
      if (_isRange) {
        final lo = _anchor!.isBefore(_focusDay!) ? _anchor! : _focusDay!;
        final hi = _anchor!.isBefore(_focusDay!) ? _focusDay! : _anchor!;
        return 'Range: ${_fmt(lo)} to ${_fmt(hi)} — tap to reset';
      }
      return 'Selected: ${_fmt(_anchor!)} — tap to reset';
    }
    return 'Tap a day to select it, or long-press and drag for a range.';
  }

  @override
  Widget build(BuildContext context) {
    final days = _daysInGrid();
    const dowLabels = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: _prevMonth,
              ),
              Text(
                _monthLabel(),
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: _nextMonth,
              ),
            ],
          ),
          Row(
            children: dowLabels
                .map((l) => Expanded(
                      child: Center(
                        child: Text(
                          l,
                          style:
                              const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ),
                    ))
                .toList(),
          ),
          const SizedBox(height: 4),
          LayoutBuilder(
            builder: (context, constraints) {
              const crossAxisCount = 7;
              const spacing = 4.0;
              final cellSize =
                  (constraints.maxWidth - spacing * (crossAxisCount - 1)) /
                      crossAxisCount;
              final rowCount = (days.length / crossAxisCount).ceil();

              DateTime? dayAtLocalOffset(Offset local) {
                if (local.dx < 0 || local.dy < 0) return null;
                final col = (local.dx / (cellSize + spacing)).floor();
                final row = (local.dy / (cellSize + spacing)).floor();
                if (col < 0 ||
                    col >= crossAxisCount ||
                    row < 0 ||
                    row >= rowCount) {
                  return null;
                }
                final index = row * crossAxisCount + col;
                if (index < 0 || index >= days.length) return null;
                return days[index];
              }

              return GestureDetector(
                key: _gridKey,
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) {
                  final box =
                      _gridKey.currentContext!.findRenderObject() as RenderBox;
                  final local = box.globalToLocal(details.globalPosition);
                  final day = dayAtLocalOffset(local);
                  if (day != null) _onTapDay(day);
                },
                onLongPressStart: (details) {
                  final box =
                      _gridKey.currentContext!.findRenderObject() as RenderBox;
                  final local = box.globalToLocal(details.globalPosition);
                  final day = dayAtLocalOffset(local);
                  if (day != null) _onLongPressStart(day);
                },
                onLongPressMoveUpdate: (details) {
                  final box =
                      _gridKey.currentContext!.findRenderObject() as RenderBox;
                  final local = box.globalToLocal(details.globalPosition);
                  final day = dayAtLocalOffset(local);
                  if (day != null) _onLongPressMoveUpdate(day);
                },
                onLongPressEnd: (_) => _onLongPressEnd(),
                child: GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: days.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    mainAxisSpacing: spacing,
                    crossAxisSpacing: spacing,
                    childAspectRatio: 1,
                  ),
                  itemBuilder: (context, index) {
                    final day = days[index];
                    if (day == null) return const SizedBox.shrink();
                    return _DayCell(
                      day: day,
                      isHovered:
                          _hoverDay != null && _isSameDay(_hoverDay!, day),
                      isSelectedSingle: !_isRange &&
                          _anchor != null &&
                          _isSameDay(_anchor!, day),
                      isRangeEnd: _isRange &&
                          (_isSameDay(day, _rangeLo()!) ||
                              _isSameDay(day, _rangeHi()!)),
                      isInRange: _isRange &&
                          day.isAfter(_rangeLo()!) &&
                          day.isBefore(_rangeHi()!),
                      isPending: _longPressActive &&
                          _anchor != null &&
                          _isSameDay(_anchor!, day),
                      onHoverChanged: (hovering) {
                        setState(() => _hoverDay = hovering ? day : null);
                      },
                    );
                  },
                ),
              );
            },
          ),
          const SizedBox(height: 14),
          Text(
            _infoText(),
            style: const TextStyle(fontSize: 13, color: Colors.black54),
          ),
        ],
      ),
    );
  }

  DateTime? _rangeLo() {
    if (_anchor == null || _focusDay == null) return null;
    return _anchor!.isBefore(_focusDay!) ? _anchor : _focusDay;
  }

  DateTime? _rangeHi() {
    if (_anchor == null || _focusDay == null) return null;
    return _anchor!.isBefore(_focusDay!) ? _focusDay : _anchor;
  }
}

class _DayCell extends StatelessWidget {
  final DateTime day;
  final bool isHovered;
  final bool isSelectedSingle;
  final bool isRangeEnd;
  final bool isInRange;
  final bool isPending;
  final ValueChanged<bool> onHoverChanged;

  const _DayCell({
    required this.day,
    required this.isHovered,
    required this.isSelectedSingle,
    required this.isRangeEnd,
    required this.isInRange,
    required this.isPending,
    required this.onHoverChanged,
  });

  static const Color accent = AppColors.greenDark;
  static const Color accentLight = AppColors.greenPale;
  static const Color hoverGrey = Color(0xFFF2F2F2);

  @override
  Widget build(BuildContext context) {
    Color? bg;
    Color fg = Colors.black87;
    BoxBorder? border;

    if (isRangeEnd || isSelectedSingle) {
      bg = accent;
      fg = Colors.white;
    } else if (isInRange) {
      bg = accentLight;
      fg = accent;
    } else if (isPending) {
      bg = hoverGrey;
      border = Border.all(color: accent, width: 1);
    } else if (isHovered) {
      bg = hoverGrey;
    }

    // IgnorePointer: taps/long-presses are handled by the GestureDetector
    // wrapping the whole grid (see RangeCalendar.build), so this cell only
    // needs to report hover state and render its visual state.
    return MouseRegion(
      onEnter: (_) => onHoverChanged(true),
      onExit: (_) => onHoverChanged(false),
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
            border: border,
          ),
          alignment: Alignment.center,
          child: Text(
            '${day.day}',
            style: TextStyle(fontSize: 14, color: fg),
          ),
        ),
      ),
    );
  }
}
