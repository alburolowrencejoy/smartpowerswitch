import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_fonts.dart';
import '../theme/app_text_styles.dart';
import 'app_button.dart';
import 'app_text_field.dart';
import 'top_toast.dart';

/// Every place in the app the two-step delete flow applies (handoff §7).
/// `notifications` covers "clear all", which removes many items at once
/// rather than one.
enum DeleteType { building, room, device, account, schedule, notifications }

/// The Firebase write for a confirmed deletion, provided by the screen that
/// calls [showDeleteFlow]. Called only after the 5s Undo window elapses
/// without Undo being tapped (see [showDeleteFlow] doc) -- so this should be
/// a single atomic multi-path `update()` that both removes the source
/// path(s) *and* writes the `deletion_log/{pushId}` entry (per
/// `aaron`'s recommended write pattern: nothing is touched during the 5s
/// window itself, so there's nothing to roll back if Undo is tapped -- just
/// cancel the timer).
///
/// For types that remove more than one thing at once (e.g. `notifications`
/// "clear all" scoped to one institute, or `building` cascading to its
/// rooms/devices/schedules), build the scoped multi-path removal inside this
/// callback -- [showDeleteFlow] itself has no opinion on how many paths a
/// single deletion touches.
typedef DeleteCommit = Future<void> Function(String reason, String? otherText);

/// Static per-[DeleteType] copy from handoff §7.2/§7.3: the confirm-card
/// icon/title and the reason list every delete dialog ends with ("...
/// Other"). Exposed so screens don't have to retype the exact §7.2 wording;
/// still overridable via [showDeleteFlow]'s `reasons`/`title`/`icon`
/// parameters for a screen that needs to diverge later.
class DeleteFlowDefaults {
  DeleteFlowDefaults._();

  static IconData iconFor(DeleteType type) => switch (type) {
        DeleteType.building => Icons.domain_disabled,
        DeleteType.room => Icons.meeting_room,
        DeleteType.device => Icons.memory,
        DeleteType.schedule => Icons.event_busy,
        DeleteType.notifications => Icons.notifications_off,
        DeleteType.account => Icons.person_remove,
      };

  static String titleFor(DeleteType type) => switch (type) {
        DeleteType.building => 'Delete building?',
        DeleteType.room => 'Delete room?',
        DeleteType.device => 'Remove device?',
        DeleteType.schedule => 'Delete schedule?',
        DeleteType.notifications => 'Clear all notifications?',
        DeleteType.account => 'Delete account?',
      };

  static String successMessageFor(DeleteType type) => switch (type) {
        DeleteType.building => 'Building deleted',
        DeleteType.room => 'Room deleted',
        DeleteType.device => 'Device removed',
        DeleteType.schedule => 'Schedule deleted',
        DeleteType.notifications => 'Notifications cleared',
        DeleteType.account => 'Account deleted',
      };

  /// Sample impact bullets from the handoff's worked examples. Screens with
  /// live data (e.g. an actual room/device count) should pass their own
  /// `impact` list to [showDeleteFlow] instead of relying on this.
  static List<String> sampleImpactFor(DeleteType type) => switch (type) {
        DeleteType.building => const [
            '2 floors and 3 rooms',
            '8 devices will be unassigned',
            '3 schedules will stop',
            'Usage history stays in Analytics',
          ],
        DeleteType.room => const [
            '3 devices will be unassigned',
            'Schedules for these devices will stop',
            'Usage history stays in Analytics',
          ],
        DeleteType.device => const [
            'The device will be unassigned from this room',
            '1 schedule will stop',
            'It can be registered again later',
          ],
        DeleteType.schedule => const [
            'Its on/off times will stop running',
            'The device stays in its current state',
            'Other schedules are not affected',
          ],
        DeleteType.notifications => const [
            'All notifications in this list are removed',
            'New alerts will still arrive',
            'Device and usage data are not affected',
          ],
        DeleteType.account => const [
            'They can no longer sign in',
            'Their schedules stay but show "deleted user"',
            'This cannot be undone',
          ],
      };

  /// The exact §7.2 reason lists, each always ending in "Other".
  static List<String> reasonsFor(DeleteType type) => switch (type) {
        DeleteType.building => const [
            'Building is no longer in use',
            'Merged with another building',
            'Added by mistake or a duplicate',
            'Will be re-added with a new code or name',
            'Devices moved to another building',
            'Energy monitoring no longer needed',
            'Other',
          ],
        DeleteType.room => const [
            'Room was converted or closed',
            'Merged with another room',
            'Added by mistake or a duplicate',
            'Devices moved to another room',
            'Room is under renovation',
            'Other',
          ],
        DeleteType.device => const [
            'Device is broken or faulty',
            'Replaced with a new device',
            'Moved to another room',
            'Registered by mistake',
            'Utility no longer monitored',
            'Other',
          ],
        DeleteType.account => const [
            'Left the college',
            'Moved to another institute or role',
            'Duplicate account',
            'Security concern',
            'Requested by the account owner',
            'Inactive for a long time',
            'Other',
          ],
        DeleteType.schedule => const [
            'No longer needed',
            'Class or office hours changed',
            'Device was removed or replaced',
            'Duplicate of another schedule',
            'Created by mistake or for testing',
            'Other',
          ],
        DeleteType.notifications => const [
            'Already reviewed them',
            'The issues are resolved',
            'Not relevant to me',
            'Too many alerts',
            'Cleaning up the list',
            'Other',
          ],
      };
}

/// Runs the redesign's full deletion flow end-to-end (handoff §7):
///
/// 1. The two-step confirm dialog (impact -> reason, [DeleteFlowDefaults]
///    supplies the §7.2 copy unless overridden).
/// 2. If the user picks a reason and taps Delete, [onOptimisticRemove] fires
///    immediately (hook a screen's [DeleteRowTransition] up here) and a
///    floating dark Undo snackbar appears above the bottom nav for 5s.
/// 3. If Undo is tapped, the timer is cancelled, [onRestore] fires, a
///    "Restored" toast shows, and [onCommit] is **never called** -- nothing
///    was written, so there's nothing to roll back.
/// 4. If the 5s elapses without Undo, [onCommit] is awaited (the screen's
///    atomic Firebase `update()`), and a small success toast shows using
///    [DeleteFlowDefaults.successMessageFor] (or [successMessage]).
///
/// Returns `true` if the deletion actually committed, `false` if the user
/// cancelled the dialog or undid it.
///
/// This function owns the dialog and the deferred-commit timing; it does
/// NOT know how to visually animate a specific screen's row out of its list
/// (that's screen-specific layout) -- pair it with [DeleteRowTransition] via
/// [onOptimisticRemove]/[onRestore].
Future<bool> showDeleteFlow(
  BuildContext context, {
  required DeleteType type,
  required String itemName,
  List<String>? impact,
  List<String>? reasons,
  String? title,
  IconData? icon,
  String? successMessage,
  required DeleteCommit onCommit,
  VoidCallback? onOptimisticRemove,
  VoidCallback? onRestore,
  Duration undoWindow = const Duration(seconds: 5),
}) async {
  final result = await showDialog<_DeleteDialogResult>(
    context: context,
    barrierColor: const Color(0x730E2E1A), // rgba(14,46,26,.45)
    builder: (context) => _DeleteDialog(
      title: title ?? DeleteFlowDefaults.titleFor(type),
      icon: icon ?? DeleteFlowDefaults.iconFor(type),
      itemName: itemName,
      impact: impact ?? DeleteFlowDefaults.sampleImpactFor(type),
      reasons: reasons ?? DeleteFlowDefaults.reasonsFor(type),
    ),
  );

  if (result == null) return false; // Cancelled.

  if (!context.mounted) return false;
  onOptimisticRemove?.call();

  final undoTapped = await _showDeleteUndoBar(
    context,
    message: successMessage ?? DeleteFlowDefaults.successMessageFor(type),
    duration: undoWindow,
  );

  if (undoTapped) {
    onRestore?.call();
    if (context.mounted) TopToast.success(context, 'Restored');
    return false;
  }

  await onCommit(result.reason, result.otherText);
  return true;
}

class _DeleteDialogResult {
  const _DeleteDialogResult(this.reason, this.otherText);
  final String reason;
  final String? otherText;
}

class _DeleteDialog extends StatefulWidget {
  const _DeleteDialog({
    required this.title,
    required this.icon,
    required this.itemName,
    required this.impact,
    required this.reasons,
  });

  final String title;
  final IconData icon;
  final String itemName;
  final List<String> impact;
  final List<String> reasons;

  @override
  State<_DeleteDialog> createState() => _DeleteDialogState();
}

class _DeleteDialogState extends State<_DeleteDialog> {
  int _step = 1;
  int? _reasonIndex;
  final _otherController = TextEditingController();
  int _shakeTrigger = 0;

  bool get _isOtherSelected =>
      _reasonIndex != null && widget.reasons[_reasonIndex!] == 'Other';

  @override
  void dispose() {
    _otherController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          // Phone-card width on desktop/web too, instead of stretching.
          maxWidth: 440,
          maxHeight: MediaQuery.of(context).size.height * 0.88,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _StepIndicator(step: _step),
              const SizedBox(height: 14),
              if (_step == 1) _buildStepOne(context) else _buildStepTwo(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStepOne(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.errorText, width: 1.5),
          ),
          child: Icon(widget.icon, color: AppColors.errorText),
        ),
        const SizedBox(height: 14),
        Text(widget.title, style: AppTextStyles.sheetTitle.copyWith(color: AppColors.ink)),
        const SizedBox(height: 4),
        Text(
          widget.itemName,
          style: AppTextStyles.subtitle.copyWith(color: AppColors.inkMid),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.disabledText.withAlpha(90)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'This will:',
                style: AppTextStyles.bodySm.copyWith(
                  color: AppColors.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              for (final line in widget.impact)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('•  ', style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMid)),
                      Expanded(
                        child: Text(
                          line,
                          style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMid),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: AppOutlineButton(
                label: 'Cancel',
                onPressed: () => Navigator.of(context).pop(),
                expand: true,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: AppDangerButton(
                label: 'Continue',
                onPressed: () => setState(() => _step = 2),
                expand: true,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStepTwo(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Why are you deleting it?',
          style: AppTextStyles.sheetTitle.copyWith(color: AppColors.ink),
        ),
        const SizedBox(height: 4),
        Text(
          'Pick one. This is saved with the deletion record.',
          style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMid),
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < widget.reasons.length; i++)
          _ReasonRow(
            label: widget.reasons[i],
            selected: _reasonIndex == i,
            onTap: () => setState(() => _reasonIndex = i),
          ),
        if (_isOtherSelected)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: AppTextField(
              controller: _otherController,
              shakeTrigger: _shakeTrigger,
              decoration: const InputDecoration(
                hintText: 'Tell us briefly why',
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                ),
              ),
            ),
          ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: AppOutlineButton(
                label: 'Back',
                onPressed: () => setState(() => _step = 1),
                expand: true,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: AppDangerButton(
                label: 'Delete',
                onPressed: _reasonIndex == null ? null : _submit,
                expand: true,
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _submit() {
    if (_reasonIndex == null) return;
    final reason = widget.reasons[_reasonIndex!];
    final otherText = reason == 'Other' ? _otherController.text.trim() : null;
    if (reason == 'Other' && (otherText == null || otherText.isEmpty)) {
      setState(() => _shakeTrigger++);
      return;
    }
    Navigator.of(context).pop(_DeleteDialogResult(reason, otherText));
  }
}

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.step});

  final int step;

  @override
  Widget build(BuildContext context) {
    Widget circle(int n) {
      final active = step == n;
      final done = step > n;
      return Container(
        width: 24,
        height: 24,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: done ? AppColors.errorText : Colors.transparent,
          border: active
              ? Border.all(color: AppColors.errorText, width: 1.5)
              : Border.all(color: AppColors.disabledText.withAlpha(120), width: 1.5),
        ),
        child: Text(
          '$n',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: done
                ? Colors.white
                : (active ? AppColors.errorText : AppColors.inkMid),
          ),
        ),
      );
    }

    return Row(
      children: [
        circle(1),
        Container(width: 24, height: 1.5, color: AppColors.disabledText.withAlpha(120)),
        circle(2),
        const Spacer(),
        Text(
          'Step $step of 2',
          style: AppTextStyles.caption.copyWith(color: AppColors.inkMid, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class _ReasonRow extends StatelessWidget {
  const _ReasonRow({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.errorText : AppColors.inkMid;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.disabledText.withAlpha(70))),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 20,
              color: color,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontFamily: AppFonts.family,
                  fontSize: 15,
                  height: 20 / 15,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: AppColors.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The floating dark Undo snackbar (handoff §7.4, preview `showUndo()`):
/// shown above the bottom nav, dark [AppColors.ink] background, red trash
/// icon, message, outlined Undo button, and a red progress line that
/// shrinks over [duration]. Returns `true` if Undo was tapped, `false` if
/// [duration] elapsed first.
Future<bool> _showDeleteUndoBar(
  BuildContext context, {
  required String message,
  Duration duration = const Duration(seconds: 5),
  double bottomOffset = 92,
}) {
  final completer = Completer<bool>();
  final overlay = Overlay.of(context, rootOverlay: true);
  late OverlayEntry entry;
  bool resolved = false;

  void resolve(bool undone) {
    if (resolved) return;
    resolved = true;
    entry.remove();
    completer.complete(undone);
  }

  entry = OverlayEntry(builder: (context) {
    final bar = _DeleteUndoBarContent(
      message: message,
      duration: duration,
      onUndo: () => resolve(true),
      onElapsed: () => resolve(false),
    );
    // Desktop/web layout (>= 900dp) has no bottom nav: a compact bar in the
    // bottom-left corner instead of a full-width strip above the nav.
    if (MediaQuery.sizeOf(context).width >= 900) {
      return Positioned(left: 24, bottom: 24, width: 420, child: bar);
    }
    return Positioned(left: 12, right: 12, bottom: bottomOffset, child: bar);
  });

  overlay.insert(entry);
  return completer.future;
}

class _DeleteUndoBarContent extends StatefulWidget {
  const _DeleteUndoBarContent({
    required this.message,
    required this.duration,
    required this.onUndo,
    required this.onElapsed,
  });

  final String message;
  final Duration duration;
  final VoidCallback onUndo;
  final VoidCallback onElapsed;

  @override
  State<_DeleteUndoBarContent> createState() => _DeleteUndoBarContentState();
}

class _DeleteUndoBarContentState extends State<_DeleteUndoBarContent>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onElapsed();
    });

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static const _accent = Color(0xFFFF9A8F);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 14),
          decoration: BoxDecoration(
            color: AppColors.ink,
            boxShadow: [
              BoxShadow(color: Colors.black.withAlpha(80), blurRadius: 30, offset: const Offset(0, 10)),
            ],
          ),
          child: Stack(
            children: [
              Row(
                children: [
                  const Icon(Icons.delete, size: 20, color: _accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.message,
                      style: AppTextStyles.bodySm.copyWith(color: Colors.white, fontWeight: FontWeight.w500),
                    ),
                  ),
                  TextButton(
                    onPressed: widget.onUndo,
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: const BorderSide(color: Colors.white54, width: 1.5),
                      ),
                    ),
                    child: const Text(
                      'Undo',
                      style: TextStyle(
                        fontFamily: AppFonts.family,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ],
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: -14,
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) => Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: (1 - _controller.value).clamp(0.0, 1.0),
                      child: Container(height: 3, color: _accent),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
