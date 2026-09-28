import 'package:flutter/material.dart';

import '../services/davao_light_service.dart';
import '../services/download_open_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_fonts.dart';
import '../theme/institute_colors.dart';
import 'app_button.dart';

/// "Davao Light announced a new rate" review card (Settings, web and
/// mobile): the verified rate, where it came from, the checks it passed,
/// and Apply / Dismiss. The rate is only changed when an admin applies it.
class RateProposalCard extends StatelessWidget {
  const RateProposalCard({
    super.key,
    required this.proposal,
    required this.currentRate,
    required this.onApply,
    required this.onDismiss,
    this.busy = false,
    this.palette,
  });

  final RateProposal proposal;
  final double currentRate;
  final VoidCallback? onApply;
  final VoidCallback? onDismiss;
  final bool busy;
  final InstitutePalette? palette;

  @override
  Widget build(BuildContext context) {
    final p = palette ?? context.institutePalette;
    final r = proposal;
    final diff = r.rate - currentRate;
    final official = r.trust == 'official';
    final trustColor = official || r.trust == 'confirmed'
        ? AppColors.successText
        : AppColors.warningText;

    TextStyle s(double size,
            {FontWeight w = FontWeight.w400, Color c = AppColors.ink}) =>
        TextStyle(
            fontFamily: AppFonts.family,
            fontSize: size,
            fontWeight: w,
            color: c,
            height: 1.35);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.dark, width: 1.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.campaign_outlined, color: p.dark, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Davao Light announced a new rate',
                style: s(15, w: FontWeight.w700)),
          ),
        ]),
        const SizedBox(height: 10),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.end,
          spacing: 10,
          runSpacing: 4,
          children: [
            Text('₱${r.rateText}/kWh',
                style: s(24, w: FontWeight.w700).copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()])),
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                  '${diff >= 0 ? '+' : '−'}₱${diff.abs().toStringAsFixed(2)} vs your '
                  '₱${currentRate.toStringAsFixed(2)}',
                  style: s(13,
                      w: FontWeight.w600,
                      c: diff >= 0
                          ? AppColors.errorText
                          : AppColors.successText)),
            ),
          ],
        ),
        if (r.periodLabel.isNotEmpty)
          Text('Billing period: ${r.periodLabel}',
              style: s(13, c: AppColors.inkMid)),
        const SizedBox(height: 10),
        Row(children: [
          Icon(official ? Icons.verified_outlined : Icons.newspaper_outlined,
              size: 16, color: trustColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(r.trustLabel,
                style: s(13, w: FontWeight.w600, c: trustColor)),
          ),
        ]),
        const SizedBox(height: 8),
        for (final c in r.checks)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(c.pass ? Icons.check_circle_outline : Icons.cancel_outlined,
                  size: 16,
                  color: c.pass ? AppColors.successText : AppColors.errorText),
              const SizedBox(width: 6),
              Expanded(
                child: Text.rich(TextSpan(children: [
                  TextSpan(
                      text: '${c.name}. ', style: s(13, w: FontWeight.w600)),
                  TextSpan(text: c.detail, style: s(13, c: AppColors.inkMid)),
                ])),
              ),
            ]),
          ),
        if (!official) ...[
          const SizedBox(height: 4),
          Text(
              r.trust == 'pasted'
                  ? 'This was pasted in by an admin. Compare it with Davao '
                      "Light's post before applying."
                  : 'This comes from news reports, not Davao Light directly. '
                      'Check the source before applying.',
              style: s(12.5, c: AppColors.inkMid)),
        ],
        const SizedBox(height: 12),
        Wrap(spacing: 10, runSpacing: 8, children: [
          AppPrimaryButton(
            label: busy ? 'Applying…' : 'Apply ₱${r.rateText}',
            icon: Icons.check,
            palette: p,
            onPressed: busy ? null : onApply,
          ),
          AppOutlineButton(
            label: 'View source',
            icon: Icons.open_in_new,
            palette: p,
            onPressed: r.sourceUrl.isEmpty
                ? null
                : () => DownloadOpenService.openRemoteUrl(r.sourceUrl),
          ),
          AppTextButton(
            label: 'Dismiss',
            palette: p,
            onPressed: busy ? null : onDismiss,
          ),
        ]),
      ]),
    );
  }
}
