import 'dart:async';

import 'package:flutter/material.dart';

import '../services/davao_light_feed.dart';
import '../services/davao_light_service.dart';
import '../services/download_open_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_fonts.dart';
import '../theme/institute_colors.dart';
import 'app_button.dart';
import 'top_toast.dart';

/// Dashboard card (web and mobile, placed just above History) with the
/// pending Davao Light rate advisory, the last applied rate, and recent
/// newsroom posts, each tagged Urgent / Important / Normal
/// ([classifyNews]). Hidden when there is nothing from the last 30 days.
///
/// Only campus admins ([canApply]) get Apply / Dismiss; everyone else sees
/// the advisory read-only, plus its estimated effect on [scopeLabel] when
/// [scopeMonthKwh] is given.
class DavaoLightUpdatesCard extends StatefulWidget {
  final InstitutePalette palette;
  final bool canApply;
  final double currentRate;
  final String? scopeLabel;
  final double? scopeMonthKwh;
  final bool compact;

  /// Space below the card, only added while it is visible.
  final double bottomGap;

  /// Overrides the live [davaoLightFeed] (tests and previews).
  final Stream<DavaoLightFeed>? feed;

  const DavaoLightUpdatesCard({
    super.key,
    required this.palette,
    required this.canApply,
    required this.currentRate,
    this.scopeLabel,
    this.scopeMonthKwh,
    this.compact = false,
    this.bottomGap = 0,
    this.feed,
  });

  @override
  State<DavaoLightUpdatesCard> createState() => _DavaoLightUpdatesCardState();
}

class _DavaoLightUpdatesCardState extends State<DavaoLightUpdatesCard> {
  late final Stream<DavaoLightFeed> _feed = widget.feed ?? davaoLightFeed();
  bool _applying = false;

  Future<void> _apply(RateProposal p) async {
    // A second tap can land before the button rebuilds as disabled.
    if (_applying) return;
    setState(() => _applying = true);
    try {
      final applied = await DavaoLightService.apply(p, widget.currentRate);
      if (!mounted) return;
      if (applied) {
        TopToast.success(context, 'Rate updated to ₱${p.rateText}/kWh.');
      } else {
        TopToast.show(context, 'This rate was already applied or dismissed.');
      }
    } catch (e) {
      if (mounted) TopToast.error(context, 'Could not apply the rate: $e');
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<void> _dismiss() async {
    try {
      await DavaoLightService.dismiss();
    } catch (e) {
      if (mounted) TopToast.error(context, 'Could not dismiss: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DavaoLightFeed>(
      stream: _feed,
      builder: (context, snap) {
        final feed = snap.data ?? DavaoLightFeed.empty;
        if (feed.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: EdgeInsets.only(bottom: widget.bottomGap),
          child: _card(feed),
        );
      },
    );
  }

  Widget _card(DavaoLightFeed feed) {
    final p = widget.palette;
    final compact = widget.compact;
    final scope = widget.scopeLabel;
    final top = feed.topUrgency;
    final news = feed.news.take(compact ? 2 : 3).toList();

    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: compact ? 36 : 44,
          height: compact ? 36 : 44,
          decoration: BoxDecoration(color: p.wash, shape: BoxShape.circle),
          child: Icon(Icons.bolt_rounded,
              color: p.dark, size: compact ? 20 : 24),
        ),
        SizedBox(width: compact ? 10 : 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(compact ? 'Davao Light' : 'Davao Light Updates',
                  style: _s(compact ? 16 : 17, w: FontWeight.w700)),
              if (!compact) ...[
                const SizedBox(height: 3),
                Text(
                  widget.canApply || scope == null
                      ? 'Rate advisories and news, checked every 6 hours'
                      : 'What changes for $scope when the electricity rate moves',
                  style: _s(13, c: AppColors.inkMuted),
                ),
              ],
            ],
          ),
        ),
        if (top != null) _UrgencyChip(urgency: top, palette: p, large: true),
      ],
    );

    final rateBlock = feed.pendingProposal != null
        ? _proposalBlock(feed.pendingProposal!)
        : feed.lastRateApplied != null
            ? _appliedBlock(feed.lastRateApplied!)
            : null;

    final newsBlock = news.isEmpty
        ? null
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!compact)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: Text('LATEST NEWS',
                      style: _s(12,
                          w: FontWeight.w600,
                          c: AppColors.inkMuted,
                          spacing: 0.3)),
                ),
              for (final n in news) _newsRow(n),
            ],
          );

    return Container(
      padding: EdgeInsets.all(compact ? 14 : 22),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(compact ? 16 : 18),
        border: Border.all(color: p.mid, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          SizedBox(height: compact ? 12 : 18),
          LayoutBuilder(builder: (context, c) {
            // Side by side only for a pending advisory (tall: price,
            // buttons); a short "rate applied" box sits above the news.
            final side = !compact &&
                c.maxWidth >= 720 &&
                feed.pendingProposal != null &&
                rateBlock != null &&
                newsBlock != null;
            if (side) {
              // Equal-height columns, so a short rate box doesn't leave a
              // blank gap under it beside the news list.
              return IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 5, child: rateBlock),
                    const SizedBox(width: 22),
                    Expanded(flex: 6, child: newsBlock),
                  ],
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (rateBlock != null) rateBlock,
                if (rateBlock != null && newsBlock != null)
                  SizedBox(height: compact ? 10 : 16),
                if (newsBlock != null) newsBlock,
              ],
            );
          }),
        ],
      ),
    );
  }

  Widget _rateBox({required List<Widget> children}) {
    final p = widget.palette;
    return Container(
      padding: EdgeInsets.all(widget.compact ? 12 : 18),
      decoration: BoxDecoration(
        color: p.wash,
        borderRadius: BorderRadius.circular(widget.compact ? 12 : 14),
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) SizedBox(height: widget.compact ? 8 : 12),
            children[i],
          ],
        ],
      ),
    );
  }

  Widget _proposalBlock(RateProposal r) {
    final p = widget.palette;
    final compact = widget.compact;
    final diff = r.rate - widget.currentRate;
    final up = diff >= 0;
    final kwh = widget.scopeMonthKwh;
    final scope = widget.scopeLabel;
    final official = r.trust == 'official' || r.trust == 'confirmed';

    final children = <Widget>[
      Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _UrgencyChip(urgency: NewsUrgency.urgent, palette: p),
          _Tag(
              text: widget.canApply
                  ? 'NEW RATE ADVISORY'
                  : 'RATE CHANGE ANNOUNCED',
              palette: p),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(official ? Icons.verified_outlined : Icons.newspaper_outlined,
                size: 14,
                color:
                    official ? AppColors.successText : AppColors.warningText),
            const SizedBox(width: 4),
            Text(r.trustLabel,
                style: _s(12,
                    w: FontWeight.w600,
                    c: official
                        ? AppColors.successText
                        : AppColors.warningText)),
          ]),
        ],
      ),
      Wrap(
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 6,
        children: [
          Text('₱${r.rateText}',
              style: _s(compact ? 26 : 34, w: FontWeight.w700, h: 1.1)),
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text('per kWh',
                style: _s(compact ? 13 : 15,
                    w: FontWeight.w600, c: AppColors.inkMuted)),
          ),
        ],
      ),
      Wrap(
        spacing: 10,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: up ? AppColors.warningBg : AppColors.surface,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                  size: 13,
                  color: up ? AppColors.warningText : AppColors.successText),
              const SizedBox(width: 2),
              Text('₱${diff.abs().toStringAsFixed(2)}',
                  style: _s(12.5,
                      w: FontWeight.w700,
                      c: up ? AppColors.warningText : AppColors.successText)),
            ]),
          ),
          Text(
              'from ₱${widget.currentRate.toStringAsFixed(2)}'
              '${r.periodLabel.isEmpty ? '' : ' · ${r.periodLabel}'}',
              style: _s(13, c: AppColors.inkMid)),
        ],
      ),
    ];

    if (widget.canApply) {
      if (!compact) {
        children.add(Text(
            'Applying updates the campus rate used for cost on every '
            'dashboard and in History.',
            style: _s(13, c: AppColors.inkMid)));
      }
      children.add(Wrap(spacing: 10, runSpacing: 8, children: [
        AppPrimaryButton(
          label: _applying ? 'Applying…' : 'Apply ₱${r.rateText}',
          icon: Icons.check,
          palette: p,
          onPressed: _applying ? null : () => unawaited(_apply(r)),
        ),
        AppOutlineButton(
          label: 'Dismiss',
          palette: p,
          onPressed: _applying ? null : () => unawaited(_dismiss()),
        ),
        if (r.sourceUrl.isNotEmpty)
          AppTextButton(
            label: 'Read advisory',
            palette: p,
            onPressed: () =>
                unawaited(DownloadOpenService.openRemoteUrl(r.sourceUrl)),
          ),
      ]));
    } else {
      if (kwh != null && kwh > 0 && scope != null) {
        final effect = diff * kwh;
        children.add(Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.cardBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Estimated effect on $scope this month',
                  style: _s(12, c: AppColors.inkMuted)),
              const SizedBox(height: 2),
              Text.rich(TextSpan(children: [
                TextSpan(
                    text:
                        '${effect >= 0 ? '+' : '−'}₱${effect.abs().toStringAsFixed(0)} ',
                    style: _s(18, w: FontWeight.w700, c: p.shade900)),
                TextSpan(
                    text:
                        "at $scope's current usage (${kwh.toStringAsFixed(1)} kWh)",
                    style: _s(13, c: AppColors.inkMuted)),
              ])),
            ],
          ),
        ));
      }
      children.add(Text(
          'Waiting for the main admin to apply it. '
          '${scope == null ? 'Costs' : "$scope's costs"} switch to the new '
          'rate once applied.',
          style: _s(13, c: AppColors.inkMid)));
      if (r.sourceUrl.isNotEmpty) {
        children.add(AppTextButton(
          label: 'Read advisory',
          palette: p,
          onPressed: () =>
              unawaited(DownloadOpenService.openRemoteUrl(r.sourceUrl)),
        ));
      }
    }
    return _rateBox(children: children);
  }

  Widget _appliedBlock(DavaoLightFeedItem item) {
    final p = widget.palette;
    return _rateBox(children: [
      Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _UrgencyChip(urgency: item.urgency, palette: p),
          _Tag(text: 'RATE APPLIED', palette: p),
        ],
      ),
      Text(item.title,
          style: _s(widget.compact ? 18 : 22, w: FontWeight.w700)),
      Text('${item.message} ${item.source} · ${_ago(item.timestamp)}.',
          style: _s(13, c: AppColors.inkMid)),
    ]);
  }

  Widget _newsRow(DavaoLightFeedItem n) {
    final p = widget.palette;
    return InkWell(
      onTap: n.link.isEmpty
          ? null
          : () => unawaited(DownloadOpenService.openRemoteUrl(n.link)),
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        decoration:
            BoxDecoration(border: Border(top: BorderSide(color: p.line))),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Fixed column so headlines line up whatever the label width.
            SizedBox(
              width: widget.compact ? 84 : 92,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _UrgencyChip(urgency: n.urgency, palette: p),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(n.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: _s(widget.compact ? 13 : 14,
                          w: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text('${n.source} · ${_ago(n.timestamp)}',
                      style: _s(12, c: AppColors.inkMuted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UrgencyChip extends StatelessWidget {
  final NewsUrgency urgency;
  final InstitutePalette palette;
  final bool large;
  const _UrgencyChip(
      {required this.urgency, required this.palette, this.large = false});

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg, Color dot) = switch (urgency) {
      NewsUrgency.urgent =>
        (AppColors.errorBg, AppColors.errorText, AppColors.error),
      NewsUrgency.important =>
        (AppColors.warningBg, AppColors.warningText, AppColors.warning),
      NewsUrgency.normal => (palette.wash, palette.dark, palette.mid),
    };
    return Semantics(
      label: 'Priority: ${urgency.label}',
      excludeSemantics: true,
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: large ? 10 : 8, vertical: large ? 5 : 3),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(large ? 8 : 6),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(urgency.label,
              style: _s(large ? 12.5 : 11.5, w: FontWeight.w700, c: fg)),
        ]),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final InstitutePalette palette;
  const _Tag({required this.text, required this.palette});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: palette.dark,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: _s(11,
              w: FontWeight.w700, c: Colors.white, spacing: 0.4)),
    );
  }
}

TextStyle _s(double size,
        {FontWeight w = FontWeight.w400,
        Color c = AppColors.ink,
        double? h,
        double? spacing}) =>
    TextStyle(
      fontFamily: AppFonts.family,
      fontSize: size,
      fontWeight: w,
      color: c,
      height: h,
      letterSpacing: spacing,
    );

String _ago(int ms) {
  if (ms <= 0) return 'recently';
  final d = DateTime.now()
      .difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays == 1) return 'Yesterday';
  return '${d.inDays} days ago';
}
