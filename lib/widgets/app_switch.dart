import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/institute_colors.dart';

/// The redesign's switch (handoff §3.7, preview `.switch` / `.switch.on`):
/// 52x32 pill. Off = white track with a grey outline and grey thumb (no
/// grey fill, per the white + outline rule); on = the institute's 700
/// [dark] fill with a white thumb.
/// A plain custom painter rather than [Switch]/[CupertinoSwitch] so the
/// exact 52x32 size and colors match the spec precisely rather than
/// approximating platform defaults.
class AppSwitch extends StatelessWidget {
  const AppSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.palette,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final InstitutePalette? palette;

  static const _offColor = Color(0xFF9E9E9E); // AppColors.offline, outline + thumb

  @override
  Widget build(BuildContext context) {
    final resolvedPalette = palette ?? context.institutePalette;
    final enabled = onChanged != null;
    return GestureDetector(
      onTap: enabled ? () => onChanged!(!value) : null,
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          width: 52,
          height: 32,
          // 2.5 + 1.5px border each side leaves exactly 24px for the thumb.
          padding: const EdgeInsets.all(2.5),
          decoration: BoxDecoration(
            color: value ? resolvedPalette.dark : Colors.white,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: value ? resolvedPalette.dark : _offColor, width: 1.5),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: value ? AppColors.white : _offColor,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
