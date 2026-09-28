import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

/// One verification step the server ran on an advisory
/// (functions/davao_light_parse.js `parseRateAdvisory`).
class AdvisoryCheck {
  final String name;
  final bool pass;
  final String detail;
  const AdvisoryCheck(this.name, this.pass, this.detail);
}

/// A verified Davao Light rate advisory waiting for an admin to apply or
/// dismiss it (`settings/rateProposal`, written by the server watcher).
class RateProposal {
  final double rate;
  final double? previousRate;
  final double? delta;
  final String periodLabel;
  final String sourceUrl;
  final String sourceTitle;

  /// 'official' (Davao Light / Aboitiz), 'confirmed' (2+ news outlets
  /// agree) or 'news' (one outlet).
  final String trust;
  final List<String> sources;
  final List<AdvisoryCheck> checks;
  final String excerpt;
  final String status; // pending | applied | dismissed
  final int detectedAt;

  const RateProposal({
    required this.rate,
    required this.previousRate,
    required this.delta,
    required this.periodLabel,
    required this.sourceUrl,
    required this.sourceTitle,
    required this.trust,
    required this.sources,
    required this.checks,
    required this.excerpt,
    required this.status,
    required this.detectedAt,
  });

  static double? _num(Object? v) => v is num ? v.toDouble() : null;

  static RateProposal? fromValue(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final rate = _num(m['rate']);
    if (rate == null) return null;
    final checks = <AdvisoryCheck>[];
    final rawChecks = m['checks'];
    final list = rawChecks is List
        ? rawChecks
        : rawChecks is Map
            ? rawChecks.values.toList()
            : const [];
    for (final c in list) {
      if (c is Map) {
        checks.add(AdvisoryCheck(
            '${c['name'] ?? ''}', c['pass'] == true, '${c['detail'] ?? ''}'));
      }
    }
    final rawSources = m['sources'];
    return RateProposal(
      rate: rate,
      previousRate: _num(m['previousRate']),
      delta: _num(m['delta']),
      periodLabel: '${m['periodLabel'] ?? ''}',
      sourceUrl: '${m['sourceUrl'] ?? ''}',
      sourceTitle: '${m['sourceTitle'] ?? ''}',
      trust: '${m['trust'] ?? 'news'}',
      sources: rawSources is List
          ? rawSources.map((e) => '$e').toList()
          : rawSources is Map
              ? rawSources.values.map((e) => '$e').toList()
              : const [],
      checks: checks,
      excerpt: '${m['excerpt'] ?? ''}',
      status: '${m['status'] ?? 'pending'}',
      detectedAt: (m['detectedAt'] as num?)?.toInt() ?? 0,
    );
  }

  /// 12.9 -> "12.90", 10.6407 -> "10.6407".
  String get rateText => formatPeso(rate);

  static String formatPeso(double v) {
    final cents = v * 100;
    return (cents - cents.roundToDouble()).abs() < 1e-6
        ? v.toStringAsFixed(2)
        : v.toString();
  }

  String get trustLabel => switch (trust) {
        'official' => 'Official source',
        'confirmed' => 'Confirmed by ${sources.length} news outlets',
        'pasted' => 'Pasted by ${sources.isEmpty ? 'an admin' : sources.first}',
        _ => 'Reported by ${sources.isEmpty ? 'a news outlet' : sources.first}',
      };
}

/// Result of Settings > Fetch Latest Rate (the `checkDavaoLightNow`
/// callable, functions/davao_light_watch.js).
class DavaoLightCheck {
  /// 'up_to_date' | 'new_rate' | 'no_advisory'
  final String rateStatus;
  final RateProposal? proposal;
  final int newPosts;

  /// Readable names of sources that could not be reached this time.
  final List<String> failedSources;
  const DavaoLightCheck(
      this.rateStatus, this.proposal, this.newPosts, this.failedSources);
}

/// Source keys (functions/davao_light_watch.js) -> names people know.
const _sourceNames = {
  'davaolight': 'Davao Light newsroom',
  'davaolightSearch': "Davao Light's website",
  'aboitizeyes': 'Aboitiz Eyes',
  'mindanaotimes': 'Mindanao Times',
  'sunstar': 'SunStar',
  'edgedavao': 'Edge Davao',
  'davaocity': 'Davao City newsroom',
};

/// Result of checking pasted advisory text (the `verifyAdvisoryText` callable).
class AdvisoryTextResult {
  /// 'proposed' | 'up_to_date' | 'failed_checks' | 'not_an_advisory'
  final String status;
  final double? rate;
  final String periodLabel;
  final List<AdvisoryCheck> checks;
  const AdvisoryTextResult(
      this.status, this.rate, this.periodLabel, this.checks);
}

class DavaoLightService {
  DavaoLightService._();

  static final _db = FirebaseDatabase.instance.ref();

  static Stream<RateProposal?> proposal() => _db
      .child('settings/rateProposal')
      .onValue
      .map((e) => RateProposal.fromValue(e.snapshot.value));

  /// Runs the server-side check now (reads the official and news feeds,
  /// verifies any advisory, records news). Throws [FirebaseFunctionsException].
  static Future<DavaoLightCheck> checkNow() async {
    final res = await FirebaseFunctions.instance
        .httpsCallable('checkDavaoLightNow',
            options: HttpsCallableOptions(timeout: const Duration(seconds: 90)))
        .call<Object?>();
    final data = res.data is Map
        ? Map<String, dynamic>.from(res.data as Map)
        : <String, dynamic>{};
    final news = data['news'] is Map ? data['news'] as Map : const {};
    final sources = data['sources'] is Map ? data['sources'] as Map : const {};
    return DavaoLightCheck(
      '${data['rateStatus'] ?? 'no_advisory'}',
      RateProposal.fromValue(data['proposal']),
      (news['newPosts'] as num?)?.toInt() ?? 0,
      [
        for (final e in sources.entries)
          if (e.value is! Map || (e.value as Map)['ok'] != true)
            _sourceNames[e.key] ?? '${e.key}',
      ],
    );
  }

  /// Runs the server checks on pasted advisory text (e.g. copied from
  /// Davao Light's Facebook post). On success the server stores it as the
  /// pending proposal. Throws [FirebaseFunctionsException].
  static Future<AdvisoryTextResult> verifyText(String text, String link) async {
    final res = await FirebaseFunctions.instance
        .httpsCallable('verifyAdvisoryText')
        .call<Object?>({'text': text.trim(), 'link': link.trim()});
    final data = res.data is Map
        ? Map<String, dynamic>.from(res.data as Map)
        : <String, dynamic>{};
    final checks =
        RateProposal.fromValue({'rate': 0, 'checks': data['checks']})?.checks ??
            const <AdvisoryCheck>[];
    return AdvisoryTextResult(
      '${data['status'] ?? 'not_an_advisory'}',
      (data['rate'] as num?)?.toDouble(),
      '${data['periodLabel'] ?? ''}',
      checks,
    );
  }

  /// Applies [p] as the electricity rate, logged like a manual update but
  /// with the advisory as its source.
  ///
  /// Returns false (and writes nothing) if the proposal was no longer
  /// pending, e.g. a double click or another admin got there first: the
  /// pending -> applied flip is a transaction, so only one caller wins.
  static Future<bool> apply(RateProposal p, double currentRate) async {
    final claim = await _db
        .child('settings/rateProposal/status')
        .runTransaction((status) => status == 'pending'
            ? Transaction.success('applied')
            : Transaction.abort());
    if (!claim.committed) return false;

    final ts = DateTime.now().millisecondsSinceEpoch;
    final user = FirebaseAuth.instance.currentUser;
    final notifId = _db.child('notifications').push().key;
    await _db.update({
      'settings/electricityRate': p.rate,
      'settings/lastRateUpdate': ts,
      'rate_changes/$ts': {
        'oldRate': currentRate,
        'newRate': p.rate,
        'source': 'davao_light_advisory',
        'sourceUrl': p.sourceUrl,
        'period': p.periodLabel,
        'trust': p.trust,
        'updatedBy': user?.uid ?? 'unknown',
        'timestamp': ts,
      },
      'notifications/$notifId': {
        'type': 'rate_change',
        'message': 'Electricity rate updated to ₱${p.rateText}/kWh from the Davao '
            'Light advisory${p.periodLabel.isEmpty ? '' : ' (${p.periodLabel})'}',
        'oldRate': currentRate,
        'newRate': p.rate,
        'link': p.sourceUrl,
        'updatedByEmail': user?.email ?? 'admin',
        'timestamp': ServerValue.timestamp,
      },
    });
    return true;
  }

  static Future<void> dismiss() =>
      _db.child('settings/rateProposal/status').set('dismissed');

  /// One-line result for a toast after [checkNow].
  static String summary(DavaoLightCheck c) {
    final p = c.proposal;
    final period =
        p == null || p.periodLabel.isEmpty ? '' : ', ${p.periodLabel}';
    final main = switch (c.rateStatus) {
      'up_to_date' =>
        "Your rate matches Davao Light's latest verified advisory (₱${p?.rateText}/kWh$period).",
      'new_rate' =>
        'Found a verified new Davao Light rate: ₱${p?.rateText}/kWh$period. Review it below.',
      _ => 'No current Davao Light rate advisory has been published yet. '
          "You'll be notified when one is.",
    };
    final news = c.newPosts > 0
        ? ' ${c.newPosts} new Davao Light ${c.newPosts == 1 ? 'post' : 'posts'}.'
        : '';
    final failed = c.failedSources.isEmpty
        ? ''
        : ' (${c.failedSources.join(', ')} could not be reached; the other '
            'sources were checked.)';
    return '$main$news$failed';
  }

  /// Friendly text for a failed [checkNow].
  static String errorText(Object e) {
    if (e is FirebaseFunctionsException) {
      switch (e.code) {
        case 'not-found':
          return 'The rate checker is not deployed yet. Deploy the Cloud '
              'Functions (see functions/DEPLOY.md).';
        case 'permission-denied':
          return 'Only campus admins can check for rate updates.';
        case 'unauthenticated':
          return 'Please sign in again.';
        default:
          return e.message ?? 'Could not check Davao Light right now.';
      }
    }
    return 'Could not check Davao Light right now: $e';
  }
}
