import 'package:flutter/material.dart';

/// Caps [child] to [maxWidth] and centers it once the available width
/// exceeds [breakpoint]. Below the breakpoint (phones) it renders [child]
/// unchanged, so mobile layouts are never affected.
class ResponsiveCenter extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  final double breakpoint;

  const ResponsiveCenter({
    super.key,
    required this.child,
    this.maxWidth = 900,
    this.breakpoint = 700,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <= breakpoint) return child;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: child,
          ),
        );
      },
    );
  }
}

/// Picks a grid column count from the available width, but never returns
/// fewer than [mobileColumns] so phone-width layouts are unaffected.
int responsiveColumnCount(
  double width, {
  required int mobileColumns,
  double breakpoint = 700,
  double idealTileWidth = 200,
  int maxColumns = 6,
}) {
  if (width <= breakpoint) return mobileColumns;
  final computed = (width / idealTileWidth).floor();
  return computed.clamp(mobileColumns, maxColumns);
}
