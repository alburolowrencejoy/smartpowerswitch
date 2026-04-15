import 'dart:async';

import 'package:flutter/material.dart';

enum TopToastVariant { success, error, warning }
enum TopToastAction { add, delete, change }

class TopToast {
  static OverlayEntry? _entry;
  static Timer? _dismissTimer;
  static Timer? _removeTimer;

  static void show(
    BuildContext context,
    String message, {
    bool isError = false,
    TopToastVariant? variant,
    TopToastAction? action,
    Duration visibleFor = const Duration(seconds: 2),
  }) {
    _clearCurrent();

    final overlay = Overlay.of(context, rootOverlay: true);
    final resolvedVariant =
        variant ?? (isError ? TopToastVariant.error : TopToastVariant.success);
    final resolvedAction = _resolveAction(
      message,
      variant: resolvedVariant,
      isError: isError,
      action: action,
    );

    Color bgColor;
    Color borderColor;
    Color textColor;
    Color indicatorColor;

    switch (resolvedAction) {
      case TopToastAction.delete:
        bgColor = const Color(0xFFFFF3F3);
        borderColor = const Color(0xFFD64A4A);
        textColor = const Color(0xFFB42318);
        indicatorColor = const Color(0xFFD64A4A);
        break;
      case TopToastAction.change:
        bgColor = const Color(0xFFF3F8FF);
        borderColor = const Color(0xFF2874A6);
        textColor = const Color(0xFF245B8A);
        indicatorColor = const Color(0xFF2874A6);
        break;
      case TopToastAction.add:
        switch (resolvedVariant) {
          case TopToastVariant.error:
            bgColor = const Color(0xFFD64A4A);
            borderColor = const Color(0xFFD64A4A);
            textColor = Colors.white;
            indicatorColor = const Color(0xFFFFD1D1);
            break;
          case TopToastVariant.warning:
            bgColor = const Color(0xFFFFF7E8);
            borderColor = const Color(0xFFE8922A);
            textColor = const Color(0xFF8A4A00);
            indicatorColor = const Color(0xFFE8922A);
            break;
          case TopToastVariant.success:
            bgColor = Colors.white;
            borderColor = const Color(0xFF2E8B57);
            textColor = const Color(0xFF2E8B57);
            indicatorColor = const Color(0xFF2E8B57);
            break;
        }
        break;
    }

    IconData icon;

    switch (resolvedVariant) {
      case TopToastVariant.error:
        icon = Icons.error_outline;
        break;
      case TopToastVariant.warning:
        icon = Icons.warning_amber_outlined;
        break;
      case TopToastVariant.success:
        icon = resolvedAction == TopToastAction.delete
            ? Icons.delete_outline
            : Icons.check_circle_outline;
        break;
    }

    bool droppedIn = false;
    bool slideOutRight = false;
    void Function(void Function())? repaint;

    final entry = OverlayEntry(
      builder: (overlayContext) {
        final topInset = MediaQuery.of(overlayContext).padding.top + 12;

        return IgnorePointer(
          child: Padding(
            padding: EdgeInsets.only(top: topInset, left: 16, right: 16),
            child: Align(
              alignment: Alignment.topRight,
              child: StatefulBuilder(
                builder: (context, setState) {
                  repaint = setState;

                  return AnimatedSlide(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    offset: droppedIn ? Offset.zero : const Offset(0, -1.2),
                    child: AnimatedSlide(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeInCubic,
                      offset:
                          slideOutRight ? const Offset(1.25, 0) : Offset.zero,
                      child: Material(
                        color: Colors.transparent,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 420),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 11),
                            decoration: BoxDecoration(
                              color: bgColor,
                              border: Border.all(color: borderColor, width: 1.2),
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withAlpha(35),
                                  blurRadius: 14,
                                  offset: const Offset(0, 6),
                                )
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 4,
                                  height: 26,
                                  decoration: BoxDecoration(
                                    color: indicatorColor,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                _ToastGlyph(
                                  action: resolvedAction,
                                  icon: icon,
                                  color: textColor,
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    message,
                                    style: TextStyle(
                                      color: textColor,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );

    _entry = entry;
    overlay.insert(entry);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_entry != entry || repaint == null) return;
      repaint!(() => droppedIn = true);
    });

    _dismissTimer = Timer(visibleFor, () {
      if (_entry != entry || repaint == null) return;
      repaint!(() => slideOutRight = true);
      _removeTimer = Timer(const Duration(milliseconds: 240), () {
        if (_entry == entry) {
          entry.remove();
          _entry = null;
        }
      });
    });
  }

  static void success(BuildContext context, String message,
      {Duration visibleFor = const Duration(seconds: 2)}) {
    show(context, message,
        variant: TopToastVariant.success, visibleFor: visibleFor);
  }

  static void error(BuildContext context, String message,
      {Duration visibleFor = const Duration(seconds: 2)}) {
    show(context, message,
        variant: TopToastVariant.error, visibleFor: visibleFor);
  }

  static void threshold(BuildContext context, String message,
      {Duration visibleFor = const Duration(seconds: 2)}) {
    show(context, message,
        variant: TopToastVariant.warning, visibleFor: visibleFor);
  }

  static TopToastAction _resolveAction(
    String message, {
    required TopToastVariant variant,
    required bool isError,
    TopToastAction? action,
  }) {
    if (action != null) return action;
    if (isError || variant == TopToastVariant.error || variant == TopToastVariant.warning) {
      return TopToastAction.add;
    }

    final text = message.toLowerCase();
    if (_containsAny(text, const [
      'deleted',
      'delete',
      'removed',
      'remove',
      'cleared',
      'clear',
      'unassigned',
    ])) {
      return TopToastAction.delete;
    }

    if (_containsAny(text, const [
      'updated',
      'update',
      'changed',
      'change',
      'renamed',
      'rename',
      'edited',
      'edit',
      'saved',
      'save',
      'enabled',
      'disabled',
    ])) {
      return TopToastAction.change;
    }

    return TopToastAction.add;
  }

  static bool _containsAny(String text, List<String> phrases) {
    for (final phrase in phrases) {
      if (text.contains(phrase)) return true;
    }
    return false;
  }

  static void _clearCurrent() {
    _dismissTimer?.cancel();
    _removeTimer?.cancel();
    _dismissTimer = null;
    _removeTimer = null;

    if (_entry != null) {
      _entry!.remove();
      _entry = null;
    }
  }
}

class _ToastGlyph extends StatelessWidget {
  const _ToastGlyph({
    required this.action,
    required this.icon,
    required this.color,
  });

  final TopToastAction action;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    switch (action) {
      case TopToastAction.delete:
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: -0.16, end: 0.0),
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutBack,
          builder: (context, value, child) {
            return Transform.rotate(
              angle: value,
              child: Transform.scale(scale: 1.0 + value.abs() * 0.8, child: child),
            );
          },
          child: Icon(icon, size: 16, color: color),
        );
      case TopToastAction.change:
        return SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2.1,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        );
      case TopToastAction.add:
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.65, end: 1.0),
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutBack,
          builder: (context, value, child) {
            return Transform.scale(scale: value, child: child);
          },
          child: Icon(icon, size: 16, color: color),
        );
    }
  }
}
