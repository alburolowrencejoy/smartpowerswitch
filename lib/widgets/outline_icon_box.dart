import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/institute_colors.dart';

/// The "Outline icon style" row-leading icon box (handoff §3.1/§3.2, chosen
/// over Tinted/Neutral/Plain -- see preview `body.ic-outline .r-icon`,
/// `.dev .add-ic`): 40x40, `radius-md` (12px) corners, white fill, a 1px
/// border in the current institute's hairline [InstitutePalette.line], and
/// the glyph itself in the institute's [InstitutePalette.dark] (700 tier).
///
/// Used as the leading icon on rows everywhere (device rows, building rows,
/// schedule rows, ...), and as the base for the icon-only Add button
/// (see `app_button.dart`'s `IconAddButton`, which reuses this exact box).
///
/// Status variants (`OutlineIconBoxVariant.warning`/`.error`) mirror the
/// preview's `.r-icon.ic-warn`/`.ic-err` -- these stay on the fixed
/// warning/error tokens regardless of institute, per "status colors never
/// change" (handoff §3.2).
enum OutlineIconBoxVariant { normal, warning, error }

class OutlineIconBox extends StatelessWidget {
  const OutlineIconBox({
    super.key,
    required this.icon,
    this.variant = OutlineIconBoxVariant.normal,
    this.size = 40,
    this.iconSize = 20,
    this.palette,
  });

  final IconData icon;
  final OutlineIconBoxVariant variant;
  final double size;
  final double iconSize;

  /// Overrides the institute palette read from context (e.g. when a row
  /// needs a *different* institute's color than the screen it's on, as with
  /// campus-wide building lists where each row is a different institute).
  final InstitutePalette? palette;

  @override
  Widget build(BuildContext context) {
    final resolvedPalette = palette ?? context.institutePalette;

    Color background;
    Color borderColor;
    Color iconColor;
    switch (variant) {
      case OutlineIconBoxVariant.warning:
        background = Colors.white;
        borderColor = AppColors.warning.withAlpha(120);
        iconColor = AppColors.warningText;
        break;
      case OutlineIconBoxVariant.error:
        background = Colors.white;
        borderColor = AppColors.error.withAlpha(120);
        iconColor = AppColors.errorText;
        break;
      case OutlineIconBoxVariant.normal:
        background = Colors.white;
        borderColor = resolvedPalette.line;
        iconColor = resolvedPalette.dark;
        break;
    }

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Icon(icon, size: iconSize, color: iconColor),
    );
  }
}
