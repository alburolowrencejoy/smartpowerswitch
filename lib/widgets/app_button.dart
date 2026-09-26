import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/institute_colors.dart';
import 'outline_icon_box.dart';

/// The redesign's 48dp buttons (handoff §3.7, preview `.btn` family).
///
/// - [AppPrimaryButton]: solid institute-700 fill, white text/icon.
/// - [AppOutlineButton]: white fill, `ink`-mid; border is the fixed neutral
///   `#B9D6C3` from the preview's base `.btn.outline` rule -- there is no
///   `.theme-*  .btn.outline` override in the HTML, so (unlike chips/icon
///   boxes) this border is NOT institute-tinted. Text color IS institute
///   700, since it reads `var(--green-dark)`, which the theme classes do
///   redefine.
/// - [AppDangerButton]: solid `errorText` (#B42318) fill, white text --
///   never themed. Per the handoff, this is used *only* inside delete
///   dialogs.
/// - [AppTextButton]: no fill/border, institute-700 text.
class AppPrimaryButton extends StatelessWidget {
  const AppPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.palette,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final InstitutePalette? palette;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final resolvedPalette = palette ?? context.institutePalette;
    final disabled = onPressed == null;
    final child = ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: resolvedPalette.dark,
        disabledBackgroundColor: resolvedPalette.dark.withAlpha(120),
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white70,
        elevation: 0,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: _ButtonContent(label: label, icon: icon, opacity: disabled ? 0.7 : 1),
    );
    return expand ? SizedBox(width: double.infinity, child: child) : child;
  }
}

class AppOutlineButton extends StatelessWidget {
  const AppOutlineButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.palette,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final InstitutePalette? palette;
  final bool expand;

  /// Fixed, non-themed border color -- see class doc.
  static const _borderColor = Color(0xFFB9D6C3);

  @override
  Widget build(BuildContext context) {
    final resolvedPalette = palette ?? context.institutePalette;
    final child = OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: resolvedPalette.dark,
        disabledForegroundColor: AppColors.disabledText,
        side: BorderSide(
          color: onPressed == null ? AppColors.disabledText : _borderColor,
        ),
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: _ButtonContent(label: label, icon: icon),
    );
    return expand ? SizedBox(width: double.infinity, child: child) : child;
  }
}

class AppDangerButton extends StatelessWidget {
  const AppDangerButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    final child = ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.errorText,
        disabledBackgroundColor: AppColors.errorText.withAlpha(100),
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white70,
        elevation: 0,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: _ButtonContent(label: label, icon: icon, opacity: disabled ? 0.6 : 1),
    );
    return expand ? SizedBox(width: double.infinity, child: child) : child;
  }
}

class AppTextButton extends StatelessWidget {
  const AppTextButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.palette,
  });

  final String label;
  final VoidCallback? onPressed;
  final InstitutePalette? palette;

  @override
  Widget build(BuildContext context) {
    final resolvedPalette = palette ?? context.institutePalette;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: resolvedPalette.dark,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        minimumSize: const Size(0, 48),
      ),
      child: Text(label, style: AppTextStyles.label.copyWith(color: resolvedPalette.dark)),
    );
  }
}

class _ButtonContent extends StatelessWidget {
  const _ButtonContent({required this.label, this.icon, this.opacity = 1});

  final String label;
  final IconData? icon;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 20),
          const SizedBox(width: 8),
        ],
        Text(label, style: AppTextStyles.label),
      ],
    );
    return opacity == 1 ? content : Opacity(opacity: opacity, child: content);
  }
}

/// Icon-only "Add" trigger (handoff §3.7/§4.2/§4.4: "Add = icon only"):
/// literally an [OutlineIconBox] with a `+` glyph, used as a static header
/// action (Add building / Add room / Add schedule) rather than a FAB.
class IconAddButton extends StatelessWidget {
  const IconAddButton({
    super.key,
    required this.onPressed,
    this.palette,
    this.semanticLabel,
  });

  final VoidCallback onPressed;
  final InstitutePalette? palette;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel ?? 'Add',
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onPressed,
        child: OutlineIconBox(icon: Icons.add, palette: palette),
      ),
    );
  }
}

/// Icon-only "Delete" trigger (handoff §3.7: "Delete = icon only, grey
/// (ink-mid), not red" -- preview `.del-btn` final `.dev` cascade). Never
/// themed, never red at rest; red only appears inside the delete dialog
/// itself.
class IconDeleteButton extends StatelessWidget {
  const IconDeleteButton({
    super.key,
    required this.onPressed,
    this.icon = Icons.delete_outline,
    this.semanticLabel,
  });

  final VoidCallback onPressed;
  final IconData icon;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, color: AppColors.inkMid),
      tooltip: semanticLabel,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
    );
  }
}
