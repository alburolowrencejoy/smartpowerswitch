import 'package:flutter/material.dart';

import '../services/history_clock.dart';

/// Tells the viewer where recorded energy history begins, so dates before
/// it read as "no data" rather than 0 kWh: "Energy history starts Oct 12,
/// 2026 · earlier dates have no data" when [rangeStart] is earlier than the
/// first recorded day, or "No energy recorded yet" when there is none.
/// Hidden otherwise. History restarted clean on 2026-10-10 (the old demo
/// history was archived).
class HistoryStartNotice extends StatelessWidget {
  const HistoryStartNotice({
    super.key,
    required this.rangeStart,
    this.padding = EdgeInsets.zero,
  });

  /// First day of the range being shown.
  final DateTime rangeStart;
  final EdgeInsetsGeometry padding;

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: HistoryClock.instance,
      builder: (context, _) {
        final clock = HistoryClock.instance;
        if (!clock.earliestKnown) return const SizedBox.shrink();
        final first = clock.earliestRecorded;
        final String text;
        if (first == null) {
          text = 'No energy recorded yet · history starts when a board '
              'reports energy';
        } else if (DateTime(rangeStart.year, rangeStart.month, rangeStart.day)
            .isBefore(first)) {
          text = 'Energy history starts '
              '${_months[first.month - 1]} ${first.day}, ${first.year} · '
              'earlier dates have no data';
        } else {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: padding,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F6F8),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFD5DDE3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.info_outline,
                    size: 14, color: Color(0xFF4A5A66)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    text,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF4A5A66),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
