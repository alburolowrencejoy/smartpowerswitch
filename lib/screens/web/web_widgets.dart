import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_colors.dart';
import '../../theme/institute_colors.dart';
import 'web_theme.dart';

/// Shared building blocks for the web screens: icon-only action buttons and
/// form dialogs whose fields show their own error (red border, message
/// underneath, a short shake) and clear it as soon as they are edited.

// ── Icon-only action button ──────────────────────────────────────────────

/// A square, tooltip-labelled icon button used for add / edit / delete
/// actions. [solid] fills it with the palette colour (primary "add"
/// actions); [danger] tints it red (delete / remove).
class WebIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool danger;
  final bool solid;
  final double size;

  const WebIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.danger = false,
    this.solid = false,
    this.size = 34,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.institutePalette;
    final Color fg;
    final Color bg;
    if (solid) {
      fg = Colors.white;
      bg = palette.dark;
    } else if (danger) {
      fg = AppColors.error;
      bg = AppColors.error.withAlpha(18);
    } else {
      fg = palette.dark;
      bg = palette.pale.withAlpha(170);
    }
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: Material(
          color: onPressed == null ? bg.withAlpha(60) : bg,
          borderRadius: BorderRadius.circular(9),
          child: InkWell(
            borderRadius: BorderRadius.circular(9),
            onTap: onPressed,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon, size: size * 0.53, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Shake ────────────────────────────────────────────────────────────────

/// Plays a short horizontal shake every time [trigger] changes.
class ShakeOnChange extends StatefulWidget {
  final int trigger;
  final Widget child;

  const ShakeOnChange({super.key, required this.trigger, required this.child});

  @override
  State<ShakeOnChange> createState() => _ShakeOnChangeState();
}

class _ShakeOnChangeState extends State<ShakeOnChange>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );

  @override
  void didUpdateWidget(covariant ShakeOnChange oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trigger != widget.trigger) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        final t = _c.value;
        final dx = math.sin(t * math.pi * 6) * 7 * (1 - t);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
    );
  }
}

// ── Form dialog ──────────────────────────────────────────────────────────

/// One field in [showWebFormDialog]. Give [options] for a dropdown.
class WebField {
  final String id;
  final String label;
  final String? hint;
  final String initial;
  final List<String>? options;
  final TextInputType? keyboardType;
  final bool uppercase;
  final bool obscure;

  const WebField({
    required this.id,
    required this.label,
    this.hint,
    this.initial = '',
    this.options,
    this.keyboardType,
    this.uppercase = false,
    this.obscure = false,
  });
}

/// Validates / saves the submitted values. Return `null` on success, or a
/// map of field id -> message to show those errors (use the key `''` for an
/// error that is not tied to one field). Throwing shows the error text.
typedef WebFormSubmit = Future<Map<String, String>?> Function(
    Map<String, String> values);

/// Shows a modal form. Resolves to `true` once [onSubmit] succeeds.
Future<bool> showWebFormDialog({
  required BuildContext context,
  required String title,
  String? subtitle,
  required List<WebField> fields,
  required WebFormSubmit onSubmit,
  String okLabel = 'Save',
  bool danger = false,
}) async {
  final palette = context.institutePalette;
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => Theme(
      data: Theme.of(context),
      child: _WebFormDialog(
        palette: palette,
        title: title,
        subtitle: subtitle,
        fields: fields,
        onSubmit: onSubmit,
        okLabel: okLabel,
        danger: danger,
      ),
    ),
  );
  return ok == true;
}

class _WebFormDialog extends StatefulWidget {
  final InstitutePalette palette;
  final String title;
  final String? subtitle;
  final List<WebField> fields;
  final WebFormSubmit onSubmit;
  final String okLabel;
  final bool danger;

  const _WebFormDialog({
    required this.palette,
    required this.title,
    required this.subtitle,
    required this.fields,
    required this.onSubmit,
    required this.okLabel,
    required this.danger,
  });

  @override
  State<_WebFormDialog> createState() => _WebFormDialogState();
}

class _WebFormDialogState extends State<_WebFormDialog> {
  late final Map<String, TextEditingController> _text = {
    for (final f in widget.fields)
      if (f.options == null) f.id: TextEditingController(text: f.initial),
  };
  late final Map<String, String> _choice = {
    for (final f in widget.fields)
      if (f.options != null)
        f.id: f.options!.contains(f.initial) ? f.initial : f.options!.first,
  };
  Map<String, String> _errors = {};
  int _shake = 0;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, String> _values() => {
        for (final e in _text.entries) e.key: e.value.text.trim(),
        ..._choice,
      };

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _errors = {};
    });
    Map<String, String>? errs;
    try {
      errs = await widget.onSubmit(_values());
    } catch (e) {
      errs = {'': 'Something went wrong: $e'};
    }
    if (!mounted) return;
    if (errs == null || errs.isEmpty) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _busy = false;
      _errors = errs!;
      _shake++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final general = _errors[''];
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 14, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title,
              style: const TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  color: WebColors.ink)),
          if (widget.subtitle != null) ...[
            const SizedBox(height: 4),
            Text(widget.subtitle!,
                style: const TextStyle(fontSize: 13.5, color: WebColors.muted)),
          ],
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final f in widget.fields) ...[
              ShakeOnChange(
                trigger: _errors.containsKey(f.id) ? _shake : 0,
                child: _field(f, p),
              ),
              const SizedBox(height: 14),
            ],
            if (general != null)
              ShakeOnChange(
                trigger: _shake,
                child: Text(general,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.error)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel', style: TextStyle(color: WebColors.mid)),
        ),
        ElevatedButton(
          onPressed: _busy ? null : _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: widget.danger ? AppColors.error : p.dark,
            foregroundColor: Colors.white,
            elevation: 0,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : Text(widget.okLabel),
        ),
      ],
    );
  }

  Widget _field(WebField f, InstitutePalette p) {
    final err = _errors[f.id];
    final deco = webInputDecoration(p, label: f.label, hint: f.hint, error: err);
    if (f.options != null) {
      return DropdownButtonFormField<String>(
        initialValue: _choice[f.id],
        decoration: deco,
        items: [
          for (final o in f.options!) DropdownMenuItem(value: o, child: Text(o)),
        ],
        onChanged: (v) => setState(() {
          _choice[f.id] = v ?? _choice[f.id]!;
          _errors.remove(f.id);
        }),
      );
    }
    return TextField(
      controller: _text[f.id],
      autofocus: f == widget.fields.first,
      obscureText: f.obscure,
      keyboardType: f.keyboardType,
      textCapitalization:
          f.uppercase ? TextCapitalization.characters : TextCapitalization.none,
      inputFormatters: f.uppercase ? [_UpperCaseFormatter()] : null,
      decoration: deco,
      onChanged: (_) {
        if (_errors.containsKey(f.id)) setState(() => _errors.remove(f.id));
      },
      onSubmitted: (_) => _submit(),
    );
  }
}

/// The outlined input style used by every web form: a red border and the
/// message under the field when [error] is set.
InputDecoration webInputDecoration(InstitutePalette p,
    {required String label, String? hint, String? error}) {
  OutlineInputBorder border(Color c, [double w = 1.2]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: c, width: w),
      );
  return InputDecoration(
    labelText: label,
    hintText: hint,
    errorText: error,
    errorMaxLines: 2,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    enabledBorder: border(p.mid.withAlpha(60)),
    focusedBorder: border(p.dark, 1.8),
    errorBorder: border(AppColors.error, 1.6),
    focusedErrorBorder: border(AppColors.error, 2),
  );
}

class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
          TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.copyWith(text: newValue.text.toUpperCase());
}

// ── Confirm dialog ───────────────────────────────────────────────────────

/// A yes/no confirmation. [onConfirm] runs while the dialog shows a
/// spinner; if it throws, the error is shown in the dialog.
Future<bool> showWebConfirmDialog({
  required BuildContext context,
  required String title,
  required String message,
  String okLabel = 'Delete',
  bool danger = true,
  Future<void> Function()? onConfirm,
}) {
  return showWebFormDialog(
    context: context,
    title: title,
    subtitle: message,
    fields: const [],
    okLabel: okLabel,
    danger: danger,
    onSubmit: (_) async {
      await onConfirm?.call();
      return null;
    },
  );
}
