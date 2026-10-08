import 'dart:async';

import 'package:firebase_database/firebase_database.dart';

import 'davao_light_service.dart';

/// How much a Davao Light item matters to DNSC, most pressing first.
enum NewsUrgency { urgent, important, normal }

extension NewsUrgencyLabel on NewsUrgency {
  String get label => switch (this) {
        NewsUrgency.urgent => 'Urgent',
        NewsUrgency.important => 'Important',
        NewsUrgency.normal => 'Normal',
      };
}

/// One row of the dashboard's Davao Light card: a newsroom post
/// (`davao_light_news`) or an applied rate change (`rate_change` /
/// `rate_change_manual`), read from `notifications`.
class DavaoLightFeedItem {
  final String id;
  final String kind; // 'news' | 'rate_applied'
  final String title;
  final String message;
  final String link;
  final String source;
  final int timestamp;
  final NewsUrgency urgency;

  const DavaoLightFeedItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.message,
    required this.link,
    required this.source,
    required this.timestamp,
    required this.urgency,
  });
}

/// Everything the dashboard card shows.
class DavaoLightFeed {
  /// A verified advisory still waiting to be applied or dismissed.
  final RateProposal? pendingProposal;

  /// The newest rate change that was applied (approved) inside the window.
  final DavaoLightFeedItem? lastRateApplied;

  /// Newsroom posts inside the window, most urgent first, then newest.
  final List<DavaoLightFeedItem> news;

  const DavaoLightFeed({
    this.pendingProposal,
    this.lastRateApplied,
    this.news = const [],
  });

  static const empty = DavaoLightFeed();

  bool get isEmpty =>
      pendingProposal == null && lastRateApplied == null && news.isEmpty;

  /// The most pressing level on the card (drives its header badge).
  NewsUrgency? get topUrgency {
    if (pendingProposal != null) return NewsUrgency.urgent;
    final levels = [
      if (lastRateApplied != null) lastRateApplied!.urgency,
      for (final n in news) n.urgency,
    ];
    if (levels.isEmpty) return null;
    return levels.reduce((a, b) => a.index <= b.index ? a : b);
  }
}

// Power interruptions, grid alerts and maintenance work.
final _outage = RegExp(
  r'interrupt|brownout|black\s?out|outage|power\s?cut|no\s?power|'
  r'shut\s?down|maintenance|line\s?work|rotational|load\s?shedding|'
  r'(red|yellow)\s?alert',
  caseSensitive: false,
);

// DNSC is in Panabo City, Davao del Norte.
final _local = RegExp(
  r'panabo|\bdnsc\b|davao del norte',
  caseSensitive: false,
);

final _redAlert = RegExp(r'red\s?alert', caseSensitive: false);

final _rateNews = RegExp(
  r'\brates?\b|per\s?kwh|/kwh|\bkwh\b|generation charge|tariff|'
  r'electric(ity)? bill|power bill',
  caseSensitive: false,
);

/// Urgency of a newsroom post from its title and summary:
/// - urgent: a power interruption that touches Panabo / DNSC, or a grid
///   red alert (it hits the whole franchise);
/// - important: rate changes only;
/// - normal: everything else, including interruptions elsewhere.
NewsUrgency classifyNews(String text) {
  if (_redAlert.hasMatch(text)) return NewsUrgency.urgent;
  if (_outage.hasMatch(text)) {
    return _local.hasMatch(text) ? NewsUrgency.urgent : NewsUrgency.normal;
  }
  if (_rateNews.hasMatch(text)) return NewsUrgency.important;
  return NewsUrgency.normal;
}

int _ts(Object? v) =>
    v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

String _peso(Object? v) =>
    v is num ? RateProposal.formatPeso(v.toDouble()) : '—';

/// Builds the card's rows from a `notifications` snapshot value, keeping
/// only items newer than [since] (ms since epoch).
({DavaoLightFeedItem? lastRateApplied, List<DavaoLightFeedItem> news})
    parseFeedNotifications(Object? raw, {required int since}) {
  final news = <DavaoLightFeedItem>[];
  DavaoLightFeedItem? applied;
  if (raw is! Map) return (lastRateApplied: null, news: news);

  raw.forEach((key, value) {
    if (value is! Map) return;
    final n = Map<String, dynamic>.from(value);
    final type = '${n['type'] ?? ''}';
    final ts = _ts(n['timestamp']);
    if (ts < since) return;

    if (type == 'davao_light_news') {
      final title = '${n['title'] ?? ''}'.trim();
      final message = '${n['message'] ?? ''}'.trim();
      news.add(DavaoLightFeedItem(
        id: '$key',
        kind: 'news',
        title: title.isEmpty ? 'Davao Light update' : title,
        message: message,
        link: '${n['link'] ?? ''}',
        source: _sourceName('${n['source'] ?? ''}'),
        timestamp: ts,
        urgency: classifyNews('$title $message'),
      ));
    } else if (type == 'rate_change' || type == 'rate_change_manual') {
      if (applied != null && applied!.timestamp >= ts) return;
      applied = DavaoLightFeedItem(
        id: '$key',
        kind: 'rate_applied',
        title: 'Rate updated to ₱${_peso(n['newRate'])}/kWh',
        message: n['oldRate'] is num
            ? 'Was ₱${_peso(n['oldRate'])}/kWh. Costs now use the new rate.'
            : 'Costs now use the new rate.',
        link: '${n['link'] ?? ''}',
        source: type == 'rate_change' ? 'Davao Light advisory' : 'Set by an admin',
        timestamp: ts,
        urgency: NewsUrgency.important,
      );
    }
  });

  news.sort((a, b) => a.urgency != b.urgency
      ? a.urgency.index.compareTo(b.urgency.index)
      : b.timestamp.compareTo(a.timestamp));
  return (lastRateApplied: applied, news: news);
}

String _sourceName(String host) {
  final h = host.toLowerCase();
  if (h.contains('davaolight')) return 'Davao Light';
  if (h.contains('aboitiz')) return 'Aboitiz';
  if (h.contains('sunstar')) return 'SunStar';
  if (h.contains('mindanaotimes')) return 'Mindanao Times';
  if (h.contains('edgedavao')) return 'Edge Davao';
  if (h.contains('davaocity')) return 'Davao City';
  return host.isEmpty ? 'Davao Light' : host;
}

/// Live [DavaoLightFeed]: the pending rate proposal plus the last
/// [window] of Davao Light notifications.
Stream<DavaoLightFeed> davaoLightFeed(
    {Duration window = const Duration(days: 30)}) {
  late StreamController<DavaoLightFeed> controller;
  StreamSubscription<RateProposal?>? proposalSub;
  StreamSubscription<DatabaseEvent>? notifSub;
  RateProposal? proposal;
  ({DavaoLightFeedItem? lastRateApplied, List<DavaoLightFeedItem> news})
      parsed = (lastRateApplied: null, news: const []);

  void emit() {
    controller.add(DavaoLightFeed(
      pendingProposal: proposal?.status == 'pending' ? proposal : null,
      lastRateApplied: parsed.lastRateApplied,
      news: parsed.news,
    ));
  }

  controller = StreamController<DavaoLightFeed>(
    onListen: () {
      final since = DateTime.now().subtract(window).millisecondsSinceEpoch;
      proposalSub = DavaoLightService.proposal().listen((p) {
        proposal = p;
        emit();
      }, onError: controller.addError);
      notifSub = FirebaseDatabase.instance
          .ref('notifications')
          .orderByChild('timestamp')
          .startAt(since)
          .onValue
          .listen((e) {
        parsed = parseFeedNotifications(e.snapshot.value, since: since);
        emit();
      }, onError: controller.addError);
    },
    onCancel: () async {
      await proposalSub?.cancel();
      await notifSub?.cancel();
    },
  );
  return controller.stream;
}
