import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// Wraps a single list row (a building row, a schedule card, a device row,
/// ...) with the redesign's ~2s delete animation (handoff §7.4, preview
/// `animateDelete()`): a red strip slides out from under the row, holds,
/// tucks back, then the row itself slides left + fades and its height
/// collapses.
///
/// This widget only *animates* -- it does not remove the item from any
/// list. The screen using it owns the underlying data: flip [deleting] to
/// `true` when the user confirms the two-step delete dialog
/// (`showDeleteFlow`'s `onOptimisticRemove` hook is a good place), then
/// actually drop the item from its list/state in [onDeleteAnimationComplete]
/// (at which point this widget unmounts along with the row). If the item
/// needs to come back before the animation finishes (Undo tapped quickly),
/// flip [deleting] back to `false` and this widget reverses smoothly.
///
/// If Undo is tapped *after* the row has already fully animated out (it was
/// already removed from the list/unmounted), the caller re-inserts the item
/// and should mount a fresh [DeleteRowTransition] with
/// [playRestoreEntrance]: true so it pops back in (matches preview
/// `.undo-in`) instead of just appearing.
///
/// For multiple items removed together (e.g. "clear all notifications"),
/// the preview staggers each row's animation 60ms apart -- this widget
/// doesn't do that internally since it only knows about one row; stagger by
/// delaying when each row's [deleting] flips to `true` (e.g.
/// `Future.delayed(Duration(milliseconds: 60 * index), ...)`).
///
/// Respects reduced motion: when the platform/[MediaQuery] disables
/// animations, [deleting] jumps straight to [onDeleteAnimationComplete]
/// with no visible transition, and [playRestoreEntrance] is a no-op.
/// Rows deleted from a *detail* page (e.g. a device removed on its own
/// page), keyed like `device:<id>`. The detail page navigates back first and
/// then marks the key, so the list row -- which only exists once the list is
/// on screen again -- plays the delete animation (handoff §7.4: "the app
/// first navigates back to the list, then animates"). List screens wrap the
/// row in a [ValueListenableBuilder] on this and feed `contains(key)` into
/// [DeleteRowTransition.deleting].
final ValueNotifier<Set<String>> pendingRowDeletes = ValueNotifier({});

/// Marks [key] for its list row's delete animation. Delayed a moment so the
/// list the caller just navigated back to is built first (a row that mounts
/// already `deleting` is hidden instantly instead of animating).
void markPendingRowDelete(String key) {
  Future.delayed(const Duration(milliseconds: 180), () {
    pendingRowDeletes.value = {...pendingRowDeletes.value, key};
  });
}

/// Clears [key] after Undo (the row slides back) or once the delete saved.
void clearPendingRowDelete(String key) {
  if (!pendingRowDeletes.value.contains(key)) return;
  pendingRowDeletes.value = {...pendingRowDeletes.value}..remove(key);
}

class DeleteRowTransition extends StatefulWidget {
  const DeleteRowTransition({
    super.key,
    required this.deleting,
    required this.child,
    this.message = 'Deleted',
    this.playRestoreEntrance = false,
    this.onDeleteAnimationComplete,
  });

  final bool deleting;
  final Widget child;

  /// Text shown on the red strip, e.g. "Building deleted".
  final String message;

  /// One-shot: when true at first build, plays a quick pop-in-from-left
  /// entrance (preview `.undo-in`) instead of appearing instantly. Only
  /// read in [initState] -- toggling it later has no effect (mount a new
  /// widget, e.g. via a fresh [ValueKey], to replay it).
  final bool playRestoreEntrance;

  /// Fires once the ~2.08s hide sequence finishes. The screen should remove
  /// the underlying item from its list/state here.
  final VoidCallback? onDeleteAnimationComplete;

  @override
  State<DeleteRowTransition> createState() => _DeleteRowTransitionState();
}

class _DeleteRowTransitionState extends State<DeleteRowTransition>
    with TickerProviderStateMixin {
  static const _totalDuration = Duration(milliseconds: 2080);

  // Phase boundaries as fractions of the 2080ms total, matching the
  // preview's millisecond offsets.
  static const _stripInEnd = 440 / 2080;
  static const _stripHoldEnd = 1250 / 2080;
  static const _stripOutEnd = 1510 / 2080;
  static const _slideStart = 1500 / 2080;
  static const _slideEnd = 1780 / 2080;
  static const _collapseStart = 1800 / 2080;

  late final AnimationController _hideController =
      AnimationController(vsync: this, duration: _totalDuration)
        ..addStatusListener(_onHideStatus);
  AnimationController? _entranceController;

  // The red strip lives in the Overlay, pinned to the row's bottom edge, so
  // it can hang *below* the row (preview `.del-note`: absolutely positioned
  // at the card's bottom, above the rows that follow) instead of being
  // clipped to, and drawn over, the row itself.
  final LayerLink _link = LayerLink();
  final OverlayPortalController _portal = OverlayPortalController();

  static double _phase(double t, double start, double end) {
    if (t <= start) return 0;
    if (t >= end) return 1;
    return (t - start) / (end - start);
  }

  double get _stripVisible {
    final t = _hideController.value;
    return (_phase(t, 0, _stripInEnd) - _phase(t, _stripHoldEnd, _stripOutEnd))
        .clamp(0.0, 1.0);
  }

  void _onHideStatus(AnimationStatus status) {
    if (status == AnimationStatus.forward && !_portal.isShowing) {
      // Not synchronously: the forward() call happens during build
      // (didUpdateWidget), where the portal can't be marked dirty.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_portal.isShowing) _portal.show();
      });
    } else if ((status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed) &&
        _portal.isShowing) {
      _portal.hide();
    }
  }

  bool get _reducedMotion =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void initState() {
    super.initState();
    if (widget.deleting) {
      _hideController.value = 1;
    }
    if (widget.playRestoreEntrance) {
      final controller = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 300),
      );
      _entranceController = controller;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
          controller.value = 1;
        } else {
          controller.forward();
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant DeleteRowTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.deleting && widget.deleting) {
      if (_reducedMotion) {
        widget.onDeleteAnimationComplete?.call();
      } else {
        _hideController.forward(from: 0).whenCompleteOrCancel(() {
          if (mounted && _hideController.isCompleted) {
            widget.onDeleteAnimationComplete?.call();
          }
        });
      }
    } else if (oldWidget.deleting && !widget.deleting) {
      // Undo, before the hide sequence finished -- reverse back to visible.
      _hideController.animateBack(0,
          duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    }
  }

  @override
  void dispose() {
    _hideController.dispose();
    _entranceController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget content = widget.child;

    if (_entranceController != null) {
      content = AnimatedBuilder(
        animation: _entranceController!,
        builder: (context, child) {
          final t = _entranceController!.value;
          return Opacity(
            opacity: t,
            child: Transform.translate(offset: Offset((1 - t) * -30, 0), child: child),
          );
        },
        child: content,
      );
    }

    final row = AnimatedBuilder(
      animation: _hideController,
      builder: (context, child) {
        final t = _hideController.value;
        if (t == 0) return child!;

        final slide = _phase(t, _slideStart, _slideEnd);
        final collapse = _phase(t, _collapseStart, 1);
        final heightFactor = 1 - collapse;

        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: heightFactor <= 0 ? 0.0001 : heightFactor,
            child: FractionalTranslation(
              translation: Offset(-slide * 1.05, 0),
              child: Opacity(opacity: 1 - slide, child: child),
            ),
          ),
        );
      },
      child: content,
    );

    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _buildStrip,
      child: CompositedTransformTarget(link: _link, child: row),
    );
  }

  Widget _buildStrip(BuildContext context) {
    return AnimatedBuilder(
      animation: _hideController,
      builder: (context, _) {
        final visible = _stripVisible;
        final width = _link.leaderSize?.width;
        if (visible <= 0 || width == null) return const SizedBox.shrink();
        return CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: Alignment.bottomLeft,
          child: IgnorePointer(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                // Clipped at the row's bottom edge, so the strip appears to
                // slide out from under the row and tuck back in.
                child: ClipRect(
                  child: FractionalTranslation(
                    translation: Offset(0, visible - 1),
                    child: Opacity(
                      opacity: visible,
                      child: _RedStrip(message: widget.message),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RedStrip extends StatelessWidget {
  const _RedStrip({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      // The preview's 18px top padding tucks 10px under the card; the strip
      // here starts at the card's bottom edge instead, so 8px shows.
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      decoration: const BoxDecoration(
        color: AppColors.errorText,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(14)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, size: 20, color: Colors.white),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              message,
              style: AppTextStyles.label.copyWith(color: Colors.white),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
