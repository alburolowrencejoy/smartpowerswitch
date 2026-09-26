import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/institute_colors.dart';

/// A single segment in an [AppSegmentedControl].
class AppSegment {
  const AppSegment({required this.label, this.icon});

  final String label;
  final IconData? icon;
}

/// The redesign's segmented control (handoff §3.2/§3.7, preview `.seg` /
/// `.seg span`): 40dp-tall segments in a neutral (non-themed) track, the
/// selected segment gets a white fill plus a 1.5px institute-color ring --
/// "no fill" per the outline system, i.e. the ring is the only themed part.
///
/// The track is white with a 1px hairline outline (no grey-green fill) --
/// the app-wide white + outline rule.
class AppSegmentedControl extends StatelessWidget {
  const AppSegmentedControl({
    super.key,
    required this.segments,
    required this.selectedIndex,
    required this.onChanged,
    this.palette,
    this.enabled = true,
  });

  final List<AppSegment> segments;
  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final InstitutePalette? palette;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final resolvedPalette = palette ?? context.institutePalette;

    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: IgnorePointer(
        ignoring: !enabled,
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.hairline),
          ),
          child: Row(
            children: [
              for (var i = 0; i < segments.length; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                Expanded(
                  child: _Segment(
                    segment: segments[i],
                    selected: i == selectedIndex,
                    palette: resolvedPalette,
                    onTap: () => onChanged(i),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.segment,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  final AppSegment segment;
  final bool selected;
  final InstitutePalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? palette.dark : AppColors.inkMid;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          height: 40,
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            border: selected
                ? Border.all(color: palette.dark, width: 1.5)
                : null,
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (segment.icon != null) ...[
                Icon(segment.icon, size: 18, color: color),
                const SizedBox(width: 6),
              ],
              Text(
                segment.label,
                style: AppTextStyles.label.copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
