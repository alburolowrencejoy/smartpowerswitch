import 'package:flutter/material.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../theme/app_colors.dart';

/// Pure wrapper around [Skeletonizer] so every screen shows the same
/// shimmer look during loading. When [isLoading] is false this has zero
/// visual side effects -- it just returns [child].
class ScreenSkeleton extends StatelessWidget {
  final bool isLoading;
  final Widget child;

  const ScreenSkeleton({
    super.key,
    required this.isLoading,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Skeletonizer(
      enabled: isLoading,
      effect: ShimmerEffect(
        baseColor: AppColors.skeleton,
        highlightColor: Color.lerp(AppColors.skeleton, Colors.white, 0.6)!,
      ),
      child: child,
    );
  }
}
