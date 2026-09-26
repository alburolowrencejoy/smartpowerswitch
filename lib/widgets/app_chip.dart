import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/institute_colors.dart';

/// The redesign's filter chip (handoff §3.2/§3.7, preview `.chip` /
/// `.chip.on` final `.dev` cascade): 40dp pill, unselected = white fill +
/// 1px hairline border + `ink` text; selected = white fill (unchanged) +
/// 1px institute-color (700) border + institute-color text -- "no tinted
/// fills" per the outline system.
class AppFilterChip extends StatelessWidget {
  const AppFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.palette,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final InstitutePalette? palette;

  @override
  Widget build(BuildContext context) {
    final resolvedPalette = palette ?? context.institutePalette;
    final borderColor = selected ? resolvedPalette.dark : resolvedPalette.line;
    final textColor = selected ? resolvedPalette.dark : AppColors.ink;
    final iconColor = selected ? resolvedPalette.dark : AppColors.inkMid;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: borderColor,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: iconColor),
                const SizedBox(width: 6),
              ],
              Text(label, style: AppTextStyles.label.copyWith(color: textColor)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The removable chip used in the Analytics filter bar (handoff §4.6,
/// preview `.xchip` final `.dev` cascade): white fill, 1px institute-color
/// (700) border, institute-color text, and a small "x" circle (18x18,
/// 1px currentColor border, transparent fill) that clears the filter.
class AppRemovableChip extends StatelessWidget {
  const AppRemovableChip({
    super.key,
    required this.label,
    required this.onRemove,
    this.palette,
  });

  final String label;
  final VoidCallback onRemove;
  final InstitutePalette? palette;

  @override
  Widget build(BuildContext context) {
    final resolvedPalette = palette ?? context.institutePalette;
    final color = resolvedPalette.dark;

    return Container(
      height: 32,
      padding: const EdgeInsets.only(left: 12, right: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: AppTextStyles.caption.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: onRemove,
            child: Container(
              width: 18,
              height: 18,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: color, width: 1),
              ),
              child: Icon(Icons.close, size: 12, color: color),
            ),
          ),
        ],
      ),
    );
  }
}
