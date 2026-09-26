import 'package:flutter/material.dart';

import '../../../theme/institute_colors.dart';
import '../web_theme.dart';

/// Colors from the Analytics design preview that aren't part of a palette.
class AnalyticsUi {
  AnalyticsUi._();

  /// `--line`: hairline borders and dividers.
  static const line = WebColors.outline;

  /// `--track`: empty part of a progress bar.
  static const track = WebColors.track;

  static const high = Color(0xFFD64A4A);
  static const warn = Color(0xFFE8922A);
  static const off = Color(0xFF9E9E9E);
  static const danger = Color(0xFFA83434);

  /// Fixed utility colors (categorical, never institute-themed).
  static const utilityColors = {
    'Lights': Color(0xFF1A5C35),
    'Outlets': Color(0xFF2E9E52),
    'AC': Color(0xFF6ECB8A),
  };
  static Color utilityColor(String u) =>
      utilityColors[u] ?? const Color(0xFFA7DDB9);

  /// Categorical building colors for the utility breakdown.
  static const buildingColors = {
    'IC': Color(0xFF1A5C35),
    'ILEGG': Color(0xFF2E9E52),
    'ITED': Color(0xFF6ECB8A),
    'IAAS': Color(0xFFE8922A),
    'ADMIN': Color(0xFF2A78D6),
  };
  static const shades = [
    Color(0xFF1A5C35),
    Color(0xFF2E9E52),
    Color(0xFF6ECB8A),
    Color(0xFFA7DDB9),
    Color(0xFFC2EDD0),
    Color(0xFF8FB9A0),
  ];
  static Color buildingColor(String code, int i) =>
      buildingColors[code] ?? shades[i % shades.length];

  static BoxDecoration card(InstitutePalette p) => BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: WebColors.outline),
      );
}

/// Rebuilds [builder] with whether the mouse is over it, and shows a click
/// cursor when [onTap] is set.
class HoverRegion extends StatefulWidget {
  final Widget Function(BuildContext context, bool hovered) builder;
  final VoidCallback? onTap;
  final String? semanticLabel;

  const HoverRegion(
      {super.key, required this.builder, this.onTap, this.semanticLabel});

  @override
  State<HoverRegion> createState() => _HoverRegionState();
}

class _HoverRegionState extends State<HoverRegion> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    Widget child = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: widget.builder(context, _hover && enabled),
      ),
    );
    if (enabled) {
      child = Semantics(
        button: true,
        label: widget.semanticLabel,
        child: FocusableActionDetector(
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) => widget.onTap!.call()),
          },
          child: child,
        ),
      );
    }
    return child;
  }
}
