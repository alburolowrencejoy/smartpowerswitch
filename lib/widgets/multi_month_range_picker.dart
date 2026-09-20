// multi_month_range_picker.dart
//
// A multi-month calendar grid (2 months per row, vertically scrollable) for
// picking either a single day or a date *range*, via single- vs
// double-click/tap. This is intentionally a different interaction model
// from `range_calendar.dart` (which uses long-press-and-drag).
//
// Interaction:
//  - Single click/tap a day to select just that one day (start == end ==
//    that day), replacing whatever was pending.
//  - Double-click a day to set it as a range start; double-click a
//    *different* day to set the end (reordered automatically if the second
//    pick is earlier than the first).
//  - Double-click the pending range start again (before an end is picked)
//    clears the pending selection.
//  - Double-clicking anywhere once a full selection (single day or range)
//    is already pending starts a fresh range from that day (there is no
//    drag to "extend" a selection here, so this keeps the widget always
//    interactive without a separate reset button).
//
// NOTE on double-click detection: this widget does its *own* double-click
// detection (see `_onDayTapped` below) rather than relying on
// `GestureDetector`'s built-in `onTap`/`onDoubleTap` combo. When both are
// set on the same detector, Flutter delays `onTap` by `kDoubleTapTimeout`
// (a hardcoded 300ms) to see whether a second tap follows; if the user's
// two clicks land even slightly slower than that -- easy to do with a
// deliberate "double-click" gesture that isn't a literal fast OS-level
// double-click -- Flutter fires two independent `onTap` events instead of
// one `onDoubleTap`, and a range never gets started. This was confirmed to
// be the actual cause of the range highlight never appearing (see
// `test/multi_month_range_picker_slow_click_test.dart`), so we use a
// manually-armed `Timer` with a more generous window instead.
//
// This widget only reports the *pending* selection via [onPendingChanged];
// it never commits anything on its own -- the caller (an "Apply" button in
// a surrounding dialog, see `HistoryScreenWeb`) decides when the pending
// selection actually takes effect.

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

class MultiMonthRangePicker extends StatefulWidget {
  /// First-of-month for the earliest month to show (bottom of the grid).
  final DateTime earliestMonth;

  /// First-of-month for the latest month to show (top of the grid).
  final DateTime latestMonth;

  final DateTime? initialStart;
  final DateTime? initialEnd;

  /// Fired whenever the pending selection changes. Called with `null`
  /// whenever the selection isn't a complete start+end pair yet (i.e.
  /// nothing selected, or only a start picked so far).
  final ValueChanged<DateTimeRange?> onPendingChanged;

  const MultiMonthRangePicker({
    super.key,
    required this.earliestMonth,
    required this.latestMonth,
    this.initialStart,
    this.initialEnd,
    required this.onPendingChanged,
  });

  @override
  State<MultiMonthRangePicker> createState() => _MultiMonthRangePickerState();
}

class _MultiMonthRangePickerState extends State<MultiMonthRangePicker> {
  DateTime? _pendingStart;
  DateTime? _pendingEnd;

  /// Manual double-click detection state (see the file-level doc comment
  /// for why this doesn't just use `GestureDetector.onDoubleTap`).
  DateTime? _armedDay;
  Timer? _armedTimer;

  /// Generous on purpose: a real user "double-click" is often noticeably
  /// slower than Flutter's built-in `kDoubleTapTimeout` (300ms).
  static const Duration _doubleClickWindow = Duration(milliseconds: 500);

  @override
  void initState() {
    super.initState();
    _pendingStart = widget.initialStart;
    _pendingEnd = widget.initialEnd;
  }

  @override
  void dispose() {
    _armedTimer?.cancel();
    super.dispose();
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Called for every click/tap on a day cell. Decides -- using an armed
  /// [Timer] rather than wall-clock timestamps (so it stays correct under
  /// `WidgetTester.pump`'s virtual clock in tests, as well as in real use)
  /// -- whether this is a fresh click, or the second click of a
  /// double-click on the same day that arrived before [_doubleClickWindow]
  /// elapsed.
  void _onDayTapped(DateTime day) {
    if (_armedDay != null && _isSameDay(day, _armedDay!)) {
      // Second click on the same day while still within the window: this
      // is the double-click.
      _armedTimer?.cancel();
      _armedTimer = null;
      _armedDay = null;
      _handleDoubleClick(day);
      return;
    }

    // First click of a possible double-click (or a fresh single click):
    // arm it and defer the single-day-selection action until the window
    // elapses without a matching second click on the same day.
    _armedTimer?.cancel();
    _armedDay = day;
    _armedTimer = Timer(_doubleClickWindow, () {
      _armedTimer = null;
      _armedDay = null;
      _handleSingleClick(day);
    });
  }

  List<DateTime> _months() {
    final months = <DateTime>[];
    final earliest =
        DateTime(widget.earliestMonth.year, widget.earliestMonth.month, 1);
    var cursor =
        DateTime(widget.latestMonth.year, widget.latestMonth.month, 1);
    // Newest first -- the grid scrolls *down* to reach further back in time.
    while (!cursor.isBefore(earliest)) {
      months.add(cursor);
      cursor = DateTime(cursor.year, cursor.month - 1, 1);
    }
    if (months.isEmpty) months.add(earliest);
    return months;
  }

  void _handleSingleClick(DateTime day) {
    // A plain single click always selects just that one day, overwriting
    // whatever was pending (including a range in progress).
    setState(() {
      _pendingStart = day;
      _pendingEnd = day;
    });
    widget.onPendingChanged(DateTimeRange(start: day, end: day));
  }

  void _handleDoubleClick(DateTime day) {
    setState(() {
      if (_pendingStart != null &&
          _pendingEnd == null &&
          _isSameDay(day, _pendingStart!)) {
        // Double-clicking the pending start again cancels the selection.
        _pendingStart = null;
        _pendingEnd = null;
      } else if (_pendingStart == null || _pendingEnd != null) {
        // Nothing pending yet, or a full range is already picked -- start
        // a fresh selection at this day.
        _pendingStart = day;
        _pendingEnd = null;
      } else {
        // A start is pending; this completes the range (auto-ordered).
        if (day.isBefore(_pendingStart!)) {
          _pendingEnd = _pendingStart;
          _pendingStart = day;
        } else {
          _pendingEnd = day;
        }
      }
    });
    widget.onPendingChanged(
      (_pendingStart != null && _pendingEnd != null)
          ? DateTimeRange(start: _pendingStart!, end: _pendingEnd!)
          : null,
    );
  }

  // Natural (unsquished) width of one month block, and of a 2-wide row of
  // them -- used below to decide when the grid needs to scroll
  // horizontally instead of squishing the day cells. Must account for
  // *everything* _MonthBlock adds around the day grid (padding + border),
  // or the grid ends up exactly a couple of pixels too tight, silently
  // pushing one day onto an extra row and overflowing.
  static const double _blockWidth = _MonthBlock._cellSize * 7 +
      _MonthBlock._cellSpacing * 6 +
      _MonthBlock._horizontalPadding * 2 +
      _MonthBlock._borderWidth * 2;
  static const double _crossAxisSpacing = 12;
  static const double _twoColumnWidth = _blockWidth * 2 + _crossAxisSpacing;

  @override
  Widget build(BuildContext context) {
    final months = _months();
    final grid = GridView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisExtent: 208,
        crossAxisSpacing: _crossAxisSpacing,
        mainAxisSpacing: 10,
      ),
      itemCount: months.length,
      itemBuilder: (context, i) => _MonthBlock(
        month: months[i],
        pendingStart: _pendingStart,
        pendingEnd: _pendingEnd,
        onDayTap: _onDayTapped,
      ),
    );

    // Always 2 months wide; if that doesn't fit the available width,
    // scroll horizontally instead of squishing or overflowing. The
    // vertical scroll through months (built into GridView) keeps working
    // either way.
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= _twoColumnWidth) {
          return grid;
        }
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: _twoColumnWidth, child: grid),
        );
      },
    );
  }
}

class _MonthBlock extends StatelessWidget {
  final DateTime month;
  final DateTime? pendingStart;
  final DateTime? pendingEnd;
  final ValueChanged<DateTime> onDayTap;

  const _MonthBlock({
    required this.month,
    required this.pendingStart,
    required this.pendingEnd,
    required this.onDayTap,
  });

  static const double _cellSize = 22;
  static const double _cellSpacing = 2;

  /// Horizontal padding + border width the block's outer [Container] adds
  /// on top of the day-grid content (see [build]) -- kept in sync with
  /// `_MultiMonthRangePickerState._blockWidth` below, which needs to know
  /// this block's true minimum width to size the horizontal-scroll
  /// fallback correctly.
  static const double _horizontalPadding = 8;
  static const double _borderWidth = 1;

  static const _monthNames = [
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
  static const _dowLabels = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  List<DateTime?> _daysInGrid() {
    final firstOfMonth = DateTime(month.year, month.month, 1);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final leadingEmpty = firstOfMonth.weekday % 7; // Sunday=0 ... Saturday=6
    final cells = <DateTime?>[];
    for (var i = 0; i < leadingEmpty; i++) {
      cells.add(null);
    }
    for (var d = 1; d <= daysInMonth; d++) {
      cells.add(DateTime(month.year, month.month, d));
    }
    return cells;
  }

  @override
  Widget build(BuildContext context) {
    final days = _daysInGrid();
    const gridWidth = _cellSize * 7 + _cellSpacing * 6;

    DateTime? lo;
    DateTime? hi;
    if (pendingStart != null && pendingEnd != null) {
      lo = pendingStart!.isBefore(pendingEnd!) ? pendingStart : pendingEnd;
      hi = pendingStart!.isBefore(pendingEnd!) ? pendingEnd : pendingStart;
    }

    return Container(
      padding: const EdgeInsets.symmetric(
          vertical: 8, horizontal: _horizontalPadding),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: AppColors.greenMid.withAlpha(26), width: _borderWidth),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${_monthNames[month.month - 1]} ${month.year}',
            style: const TextStyle(
              fontFamily: 'Outfit',
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.textDark,
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: gridWidth,
            child: Row(
              children: _dowLabels
                  .map((l) => SizedBox(
                        width: _cellSize,
                        child: Center(
                          child: Text(
                            l,
                            style: const TextStyle(
                                fontSize: 9, color: AppColors.textMuted),
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: gridWidth,
            child: Wrap(
              spacing: _cellSpacing,
              runSpacing: _cellSpacing,
              children: days.map((day) {
                if (day == null) {
                  return const SizedBox(width: _cellSize, height: _cellSize);
                }
                final isSingleStart = pendingStart != null &&
                    pendingEnd == null &&
                    _isSameDay(day, pendingStart!);
                final isRangeEndpoint = lo != null &&
                    hi != null &&
                    (_isSameDay(day, lo) || _isSameDay(day, hi));
                final isInRange =
                    lo != null && hi != null && day.isAfter(lo) && day.isBefore(hi);

                Color? bg;
                Color fg = AppColors.textDark;
                if (isSingleStart || isRangeEndpoint) {
                  bg = AppColors.greenDark;
                  fg = Colors.white;
                } else if (isInRange) {
                  bg = AppColors.greenPale;
                  fg = AppColors.greenDark;
                }

                return _DayButton(
                  day: day,
                  size: _cellSize,
                  bg: bg,
                  fg: fg,
                  onTap: () => onDayTap(day),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _DayButton extends StatefulWidget {
  final DateTime day;
  final double size;
  final Color? bg;
  final Color fg;
  final VoidCallback onTap;

  const _DayButton({
    required this.day,
    required this.size,
    required this.bg,
    required this.fg,
    required this.onTap,
  });

  @override
  State<_DayButton> createState() => _DayButtonState();
}

class _DayButtonState extends State<_DayButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.bg ?? (_hovered ? const Color(0xFFF2F2F2) : null);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(7),
          ),
          alignment: Alignment.center,
          child: Text(
            '${widget.day.day}',
            style: TextStyle(fontSize: 11, color: widget.fg),
          ),
        ),
      ),
    );
  }
}
