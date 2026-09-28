import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../services/davao_light_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_fonts.dart';
import '../theme/institute_colors.dart';
import 'app_button.dart';
import 'app_text_field.dart';
import 'top_toast.dart';

/// Settings > "Paste advisory": for months when Davao Light posts the new
/// rate only on Facebook (which the server can't read). The pasted text
/// goes through the same server-side checks as fetched advisories
/// (`verifyAdvisoryText`); if they pass, the rate appears as the review
/// card in Settings. Nothing is applied from here.
Future<void> showPasteAdvisoryDialog(
    BuildContext context, InstitutePalette palette) {
  final theme = InstituteTheme(palette: palette).applyTo(Theme.of(context));
  return showDialog<void>(
    context: context,
    builder: (_) => Theme(data: theme, child: _PasteAdvisoryDialog(palette)),
  );
}

class _PasteAdvisoryDialog extends StatefulWidget {
  const _PasteAdvisoryDialog(this.palette);
  final InstitutePalette palette;

  @override
  State<_PasteAdvisoryDialog> createState() => _PasteAdvisoryDialogState();
}

class _PasteAdvisoryDialogState extends State<_PasteAdvisoryDialog> {
  final _text = TextEditingController();
  final _link = TextEditingController();
  bool _checking = false;
  String? _error;
  int _shake = 0;
  List<AdvisoryCheck> _failed = const [];

  @override
  void dispose() {
    _text.dispose();
    _link.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    if (_text.text.trim().length < 30) {
      setState(() {
        _error = 'Paste the full advisory text.';
        _shake++;
      });
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
      _failed = const [];
    });
    try {
      final r = await DavaoLightService.verifyText(_text.text, _link.text);
      if (!mounted) return;
      switch (r.status) {
        case 'proposed':
          Navigator.pop(context);
          TopToast.success(context,
              'Checks passed. Review ₱${RateProposal.formatPeso(r.rate!)} in Settings before applying.');
          return;
        case 'up_to_date':
          Navigator.pop(context);
          TopToast.show(context,
              'Checks passed, and your rate already matches (₱${RateProposal.formatPeso(r.rate!)}).');
          return;
        case 'failed_checks':
          setState(() {
            _checking = false;
            _failed = r.checks;
            _error =
                'Found ₱${RateProposal.formatPeso(r.rate!)}, but it did not pass every check:';
            _shake++;
          });
          return;
        default:
          setState(() {
            _checking = false;
            _error =
                "That doesn't look like a Davao Light rate advisory. Paste "
                'the text that states the new residential rate per kWh.';
            _shake++;
          });
      }
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = DavaoLightService.errorText(e);
        _shake++;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = 'Could not check it: $e';
        _shake++;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    TextStyle s(double size,
            {FontWeight w = FontWeight.w400, Color c = AppColors.ink}) =>
        TextStyle(
            fontFamily: AppFonts.family,
            fontSize: size,
            fontWeight: w,
            color: c,
            height: 1.35);

    return AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Text('Paste a Davao Light advisory',
          style: s(18, w: FontWeight.w700)),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  'Davao Light sometimes posts the new rate only on Facebook. Copy '
                  'the text of that post and paste it here. It is checked the same '
                  'way as fetched advisories, then shown for review. Nothing is '
                  'applied yet.',
                  style: s(13.5, c: AppColors.inkMid)),
              const SizedBox(height: 14),
              AppTextField(
                controller: _text,
                shakeTrigger: _shake,
                minLines: 5,
                maxLines: 8,
                decoration: InputDecoration(
                  hintText:
                      "e.g. Davao Light's residential electricity rate increased "
                      'to ₱13.24 per kilowatt-hour (kWh) for the September 11 to '
                      'October 10, 2026 billing period…',
                  hintMaxLines: 4,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
              ),
              const SizedBox(height: 10),
              AppTextField(
                controller: _link,
                decoration: InputDecoration(
                  labelText: 'Link to the post (optional)',
                  hintText: 'https://www.facebook.com/DavaoLightOfficial/…',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                    style: s(13, w: FontWeight.w600, c: AppColors.errorText)),
              ],
              for (final c in _failed)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                            c.pass
                                ? Icons.check_circle_outline
                                : Icons.cancel_outlined,
                            size: 16,
                            color: c.pass
                                ? AppColors.successText
                                : AppColors.errorText),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text('${c.name}. ${c.detail}',
                              style: s(13, c: AppColors.inkMid)),
                        ),
                      ]),
                ),
            ],
          ),
        ),
      ),
      actions: [
        AppTextButton(
          label: 'Cancel',
          palette: p,
          onPressed: _checking ? null : () => Navigator.pop(context),
        ),
        AppPrimaryButton(
          label: _checking ? 'Checking…' : 'Check advisory',
          icon: Icons.fact_check_outlined,
          palette: p,
          onPressed: _checking ? null : _check,
        ),
      ],
    );
  }
}
