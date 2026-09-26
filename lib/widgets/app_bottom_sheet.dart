import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/institute_colors.dart';
import 'app_button.dart';

/// Shows a [BottomSheetScaffold] (or any [child]) using the redesign's sheet
/// chrome: transparent route background (the scaffold itself draws the
/// white 24px-top-radius card), scrollable, sized to content up to 88% of
/// the screen height (preview `.sheet{max-height:88%}`).
Future<T?> showAppBottomSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool isDismissible = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    isDismissible: isDismissible,
    backgroundColor: Colors.transparent,
    constraints: BoxConstraints(
      maxWidth: double.infinity,
      maxHeight: MediaQuery.of(context).size.height * 0.88,
    ),
    builder: builder,
  );
}

/// The redesign's bottom sheet scaffold (handoff §3.7, preview `.sheet` /
/// `.grab` / `.s-head` / `.s-body` / `.s-foot`): 24px top corners, a grab
/// handle, a header with a title and an optional trailing action (e.g.
/// "Clear"/"Reset" as a text button, or a close icon), a scrollable body,
/// and an optional footer with Cancel/Apply-style actions.
class BottomSheetScaffold extends StatelessWidget {
  const BottomSheetScaffold({
    super.key,
    required this.title,
    this.headerAction,
    required this.body,
    this.footer,
    this.palette,
  });

  final String title;

  /// e.g. `AppTextButton(label: 'Clear', onPressed: ...)` or a close
  /// [IconButton] -- matches preview patterns like
  /// `<h3>Filters</h3><a class="btn text" data-close>Reset</a>` and
  /// `<h3>IC Building</h3>...<span class="icon-btn" data-close>close</span>`.
  final Widget? headerAction;

  final Widget body;

  /// e.g. a `Row` of `AppOutlineButton` (Cancel) + `AppPrimaryButton`
  /// (Apply), each `Expanded` per preview `.s-foot .btn{flex:1}`.
  final Widget? footer;

  final InstitutePalette? palette;

  @override
  Widget build(BuildContext context) {
    final resolvedPalette = palette ?? context.institutePalette;

    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFC6D6CB),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: resolvedPalette.line, width: 1),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: AppTextStyles.sheetTitle.copyWith(color: AppColors.ink),
                    ),
                  ),
                  if (headerAction != null) headerAction!,
                ],
              ),
            ),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: SingleChildScrollView(child: body),
              ),
            ),
            if (footer != null)
              Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: resolvedPalette.line, width: 1),
                  ),
                ),
                child: footer!,
              ),
          ],
        ),
      ),
    );
  }
}

/// Convenience Cancel/Apply footer row matching preview `.s-foot` exactly
/// (`AppOutlineButton` + `AppPrimaryButton`, both `Expanded`, 12px gap).
class BottomSheetFooter extends StatelessWidget {
  const BottomSheetFooter({
    super.key,
    required this.onCancel,
    required this.onApply,
    this.cancelLabel = 'Cancel',
    this.applyLabel = 'Apply',
    this.palette,
  });

  final VoidCallback onCancel;
  final VoidCallback? onApply;
  final String cancelLabel;
  final String applyLabel;
  final InstitutePalette? palette;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: AppOutlineButton(
            label: cancelLabel,
            onPressed: onCancel,
            palette: palette,
            expand: true,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: AppPrimaryButton(
            label: applyLabel,
            onPressed: onApply,
            palette: palette,
            expand: true,
          ),
        ),
      ],
    );
  }
}
