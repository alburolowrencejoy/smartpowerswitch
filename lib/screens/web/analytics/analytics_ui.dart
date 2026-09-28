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

  /// Utility colors, drawn from the viewer's institute ramp so an IC user
  /// sees indigo series, ITED gold, and so on: Lights = 700, Outlets = 500,
  /// AC = halfway from 500 to 200. The themed institutes have `light ==
  /// mid`, so AC can't use [InstitutePalette.light] without merging into
  /// Outlets; the blend keeps all three distinct. For the green admin ramp
  /// this lands on (almost) the old fixed greens.
  static Color utilityColor(String u,
      [InstitutePalette p = InstituteColors.admin]) {
    switch (u) {
      case 'Lights':
        return p.dark;
      case 'Outlets':
        return p.mid;
      case 'AC':
        return Color.lerp(p.mid, p.pale, 0.5)!;
      default:
        return Color.lerp(p.mid, p.pale, 0.8)!;
    }
  }

  /// A building's color in breakdowns: each institute's own 500 tier
  /// (IC indigo, ILEGG berry, ITED gold, IAAS blue, ADMIN green), falling
  /// back to [shades] for buildings without a palette.
  static const _paletteCodes = {'IC', 'ILEGG', 'ITED', 'IAAS', 'ADMIN'};
  static const shades = [
    Color(0xFF1A5C35),
    Color(0xFF2E9E52),
    Color(0xFF6ECB8A),
    Color(0xFFA7DDB9),
    Color(0xFFC2EDD0),
    Color(0xFF8FB9A0),
  ];
  static Color buildingColor(String code, int i) =>
      _paletteCodes.contains(code.trim().toUpperCase())
          ? InstituteColors.forCode(code).mid
          : shades[i % shades.length];

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
