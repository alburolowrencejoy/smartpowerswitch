import 'package:flutter/material.dart';

import '../services/history_clock.dart';

/// "Showing the latest recorded data (Jun 1, 2026)" -- shown while
/// [HistoryClock] is falling back to an older period because nothing has
/// been recorded for the current month. Hidden otherwise.
class HistoryFallbackNotice extends StatelessWidget {
  const HistoryFallbackNotice({super.key, this.padding = EdgeInsets.zero});

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
        final latest = clock.latestRecorded;
        if (!clock.isFallback || latest == null) {
          return const SizedBox.shrink();
        }
        final date =
            '${_months[latest.month - 1]} ${latest.day}, ${latest.year}';
        return Padding(
          padding: padding,
          child: Tooltip(
            message: 'Nothing has been recorded since $date, so energy '
                'figures show that period. They switch back to current '
                'dates automatically once the meters report again.',
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF4E0),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFF2C77B)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.history, size: 14, color: Color(0xFF8A5A00)),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'Showing latest recorded data · $date',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8A5A00),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
