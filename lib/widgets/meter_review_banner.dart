import 'dart:async';

import 'package:flutter/material.dart';

import '../services/meter_review.dart';
import '../theme/app_fonts.dart';

/// Shown on a device page while the server has paused energy counting for
/// the device because its meter jumped or dropped unexpectedly (see
/// [MeterReview]). Admins answer it here: count the reading, or start
/// counting over from it. Renders nothing for everyone else, and nothing
/// while counting is normal.
class MeterReviewBanner extends StatefulWidget {
  const MeterReviewBanner({
    super.key,
    required this.deviceId,
    required this.canResolve,
    this.padding = const EdgeInsets.only(top: 12),
  });

  final String deviceId;
  final bool canResolve;
  final EdgeInsetsGeometry padding;

  @override
  State<MeterReviewBanner> createState() => _MeterReviewBannerState();
}

class _MeterReviewBannerState extends State<MeterReviewBanner> {
  StreamSubscription? _sub;
  MeterReview? _review;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(MeterReviewBanner old) {
    super.didUpdateWidget(old);
    if (old.deviceId != widget.deviceId || old.canResolve != widget.canResolve) {
      _listen();
    }
  }

  void _listen() {
    _sub?.cancel();
    _sub = null;
    _review = null;
    // Only admins may read meterState; nobody else needs to know.
    if (!widget.canResolve) return;
    _sub = MeterReview.ref(widget.deviceId).onValue.listen(
      (e) {
        if (mounted) setState(() => _review = MeterReview.parse(e.snapshot.value));
      },
      onError: (_) {
        if (mounted) setState(() => _review = null);
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _answer(bool accept) async {
    final review = _review;
    if (review == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(accept ? 'Count this reading?' : 'Start counting over?',
            style: const TextStyle(fontFamily: AppFonts.family)),
        content: Text(
          accept
              ? (review.isSpike
                  ? 'The jump will be added to this device\'s energy history '
                      'and cost.'
                  : 'Use this if the meter was reset. Counting continues from '
                      'the new reading.')
              : 'Nothing is added for the jump or drop. Counting continues '
                  'from the meter\'s current reading.',
          style: const TextStyle(fontFamily: AppFonts.family),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(accept ? 'Count it' : 'Start over')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await MeterReview.resolve(widget.deviceId, accept: accept);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text('Couldn\'t save the review: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final review = _review;
    if (review == null) return const SizedBox.shrink();
    return Padding(
      padding: widget.padding,
      child: MeterReviewCard(
          review: review, saving: _saving, onAnswer: _answer),
    );
  }
}

/// The look of [MeterReviewBanner]: what happened, and the two answers.
class MeterReviewCard extends StatelessWidget {
  const MeterReviewCard({
    super.key,
    required this.review,
    required this.onAnswer,
    this.saving = false,
  });

  final MeterReview review;

  /// Called with true for "count it" / "meter was reset", false for
  /// "start over".
  final void Function(bool accept) onAnswer;
  final bool saving;

  static const _amber = Color(0xFF9A5B00);
  static final _button = TextButton.styleFrom(
    foregroundColor: _amber,
    visualDensity: VisualDensity.compact,
    textStyle: const TextStyle(
        fontFamily: AppFonts.family, fontSize: 13, fontWeight: FontWeight.w700),
  );

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
        fontFamily: AppFonts.family, fontSize: 12, color: _amber, height: 1.35);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      decoration: BoxDecoration(
        color: const Color(0xFFE8922A).withAlpha(30),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE8922A).withAlpha(90)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            const Icon(Icons.pause_circle_outline_rounded,
                size: 16, color: _amber),
            const SizedBox(width: 6),
            Expanded(
              child: Text('Energy counting paused',
                  style:
                      style.copyWith(fontSize: 13, fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            review.isSpike
                ? 'The meter jumped more than this device can use. Nothing '
                    'is being added to its history until you decide.'
                : 'The meter reading went down. Nothing is being added to '
                    'its history until you decide.',
            style: style,
          ),
          if (review.answered)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                  'Answer saved. It applies on the device\'s next meter '
                  'reading.',
                  style: style.copyWith(fontWeight: FontWeight.w600)),
            )
          else
            Wrap(spacing: 8, children: [
              TextButton(
                style: _button,
                onPressed: saving ? null : () => onAnswer(true),
                child: Text(review.isSpike ? 'Count it' : 'Meter was reset'),
              ),
              TextButton(
                style: _button,
                onPressed: saving ? null : () => onAnswer(false),
                child: const Text('Start over'),
              ),
            ]),
        ],
      ),
    );
  }
}
