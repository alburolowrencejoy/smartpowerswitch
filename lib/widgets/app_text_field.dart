import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Every text input in the app goes through [AppTextField] or
/// [AppTextFormField] so that a field with an error gives the same short
/// horizontal shake on every screen, mobile and web. Don't use a raw
/// `TextField` / `TextFormField` in `lib/` — `test/ui_conventions_test.dart`
/// fails the build if one appears outside this file.

// ── Shake primitives ─────────────────────────────────────────────────────

/// Plays a short horizontal shake every time [trigger] changes.
class ShakeOnChange extends StatefulWidget {
  const ShakeOnChange({super.key, required this.trigger, required this.child});

  final int trigger;
  final Widget child;

  @override
  State<ShakeOnChange> createState() => _ShakeOnChangeState();
}

class _ShakeOnChangeState extends State<ShakeOnChange>
    with SingleTickerProviderStateMixin, _ShakeMotion {
  @override
  void didUpdateWidget(covariant ShakeOnChange oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trigger != widget.trigger) shake();
  }

  @override
  Widget build(BuildContext context) => buildShake(widget.child);
}

/// Shakes [child] when [error] appears or changes, and again whenever
/// [trigger] changes while an error is showing (bump it on every failed
/// submit so a repeated mistake still gets feedback).
class ShakeOnError extends StatefulWidget {
  const ShakeOnError({
    super.key,
    required this.error,
    this.trigger = 0,
    required this.child,
  });

  final String? error;
  final int trigger;
  final Widget child;

  @override
  State<ShakeOnError> createState() => _ShakeOnErrorState();
}

class _ShakeOnErrorState extends State<ShakeOnError>
    with SingleTickerProviderStateMixin, _ShakeMotion {
  @override
  void didUpdateWidget(covariant ShakeOnError oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.error != null &&
        (widget.error != oldWidget.error ||
            widget.trigger != oldWidget.trigger)) {
      shake();
    }
  }

  @override
  Widget build(BuildContext context) => buildShake(widget.child);
}

mixin _ShakeMotion<T extends StatefulWidget>
    on State<T>, SingleTickerProviderStateMixin<T> {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );

  void shake() {
    // Respect the OS "reduce motion" setting.
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
    _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget buildShake(Widget child) {
    return AnimatedBuilder(
      animation: _c,
      child: child,
      builder: (context, child) {
        final t = _c.value;
        final dx = math.sin(t * math.pi * 6) * 7 * (1 - t);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
    );
  }
}

// ── Fields ───────────────────────────────────────────────────────────────

/// A [TextField] that shakes when `decoration.errorText` appears or
/// changes. Pass [shakeTrigger] (incremented on each failed submit) to
/// shake again when the same error is re-reported.
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.decoration = const InputDecoration(),
    this.shakeTrigger = 0,
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.style,
    this.textAlign = TextAlign.start,
    this.autofocus = false,
    this.obscureText = false,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.maxLines = 1,
    this.minLines,
    this.maxLength,
    this.onChanged,
    this.onSubmitted,
    this.onTap,
    this.inputFormatters,
    this.enabled,
    this.readOnly = false,
    this.autofillHints,
    this.cursorColor,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final InputDecoration? decoration;
  final int shakeTrigger;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final TextStyle? style;
  final TextAlign textAlign;
  final bool autofocus;
  final bool obscureText;
  final bool autocorrect;
  final bool enableSuggestions;
  final int? maxLines;
  final int? minLines;
  final int? maxLength;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final GestureTapCallback? onTap;
  final List<TextInputFormatter>? inputFormatters;
  final bool? enabled;
  final bool readOnly;
  final Iterable<String>? autofillHints;
  final Color? cursorColor;

  @override
  Widget build(BuildContext context) {
    return ShakeOnError(
      error: decoration?.errorText,
      trigger: shakeTrigger,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        decoration: decoration,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        textCapitalization: textCapitalization,
        style: style,
        textAlign: textAlign,
        autofocus: autofocus,
        obscureText: obscureText,
        autocorrect: autocorrect,
        enableSuggestions: enableSuggestions,
        maxLines: maxLines,
        minLines: minLines,
        maxLength: maxLength,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        onTap: onTap,
        inputFormatters: inputFormatters,
        enabled: enabled,
        readOnly: readOnly,
        autofillHints: autofillHints,
        cursorColor: cursorColor,
      ),
    );
  }
}

/// A [TextFormField] that shakes whenever its [validator] reports an error
/// (every `Form.validate()` call, or each change of message when
/// auto-validating).
class AppTextFormField extends StatefulWidget {
  const AppTextFormField({
    super.key,
    this.controller,
    this.focusNode,
    this.decoration = const InputDecoration(),
    this.validator,
    this.autovalidateMode,
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.style,
    this.autofocus = false,
    this.obscureText = false,
    this.onChanged,
    this.onFieldSubmitted,
    this.inputFormatters,
    this.enabled,
    this.autofillHints,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final InputDecoration? decoration;
  final FormFieldValidator<String>? validator;
  final AutovalidateMode? autovalidateMode;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final TextStyle? style;
  final bool autofocus;
  final bool obscureText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onFieldSubmitted;
  final List<TextInputFormatter>? inputFormatters;
  final bool? enabled;
  final Iterable<String>? autofillHints;

  @override
  State<AppTextFormField> createState() => _AppTextFormFieldState();
}

class _AppTextFormFieldState extends State<AppTextFormField> {
  final _shaker = GlobalKey<_ShakeOnChangeState>();
  String? _lastError;

  String? _validate(String? value) {
    final error = widget.validator?.call(value);
    final autovalidating = widget.autovalidateMode != null &&
        widget.autovalidateMode != AutovalidateMode.disabled;
    // With auto-validation the validator runs on every rebuild, so only
    // shake when the message changes; otherwise every validate() is a
    // deliberate submit and deserves feedback.
    if (error != null && (!autovalidating || error != _lastError)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _shaker.currentState?.shake();
      });
    }
    _lastError = error;
    return error;
  }

  @override
  Widget build(BuildContext context) {
    return ShakeOnChange(
      key: _shaker,
      trigger: 0,
      child: TextFormField(
        controller: widget.controller,
        focusNode: widget.focusNode,
        decoration: widget.decoration,
        validator: widget.validator == null ? null : _validate,
        autovalidateMode: widget.autovalidateMode,
        keyboardType: widget.keyboardType,
        textInputAction: widget.textInputAction,
        textCapitalization: widget.textCapitalization,
        style: widget.style,
        autofocus: widget.autofocus,
        obscureText: widget.obscureText,
        onChanged: widget.onChanged,
        onFieldSubmitted: widget.onFieldSubmitted,
        inputFormatters: widget.inputFormatters,
        enabled: widget.enabled,
        autofillHints: widget.autofillHints,
      ),
    );
  }
}
