import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/services/davao_light_feed.dart';

void main() {
  group('classifyNews', () {
    test('interruption in Panabo / DNSC is urgent', () {
      expect(
          classifyNews('Scheduled power interruption in Panabo City on Saturday'),
          NewsUrgency.urgent);
      expect(classifyNews('Brownout to affect DNSC area'), NewsUrgency.urgent);
      expect(
          classifyNews('Line maintenance in parts of Davao del Norte'),
          NewsUrgency.urgent);
    });

    test('grid red alert is urgent anywhere', () {
      expect(classifyNews('NGCP raises red alert on Mindanao grid'),
          NewsUrgency.urgent);
    });

    test('interruption elsewhere is normal', () {
      expect(classifyNews('Power interruption in Toril, Davao City'),
          NewsUrgency.normal);
      expect(
          classifyNews(
              'Switching power interruptions on October 10 in Davao City and IGACOS'),
          NewsUrgency.normal);
      expect(classifyNews('Yellow alert on the grid'), NewsUrgency.normal);
    });

    test('rate news is important', () {
      expect(
          classifyNews('Davao Light adjusts overall residential rate for October'),
          NewsUrgency.important);
      expect(classifyNews('Generation charge eases this month'),
          NewsUrgency.important);
    });

    test('anything else is normal', () {
      expect(classifyNews('Davao Light holds tree-planting drive'),
          NewsUrgency.normal);
    });
  });

  group('parseFeedNotifications', () {
    test('keeps recent news sorted by urgency, then newest', () {
      final r = parseFeedNotifications({
        'a': {
          'type': 'davao_light_news',
          'title': 'Tree-planting drive',
          'timestamp': 300,
          'source': 'www.davaolight.com',
        },
        'b': {
          'type': 'davao_light_news',
          'title': 'Power interruption in Panabo',
          'timestamp': 200,
        },
        'c': {
          'type': 'davao_light_news',
          'title': 'Old post',
          'timestamp': 50,
        },
        'd': {'type': 'offline', 'timestamp': 400},
      }, since: 100);

      expect(r.news.map((n) => n.id), ['b', 'a']);
      expect(r.news.first.urgency, NewsUrgency.urgent);
      expect(r.news.last.source, 'Davao Light');
    });

    test('picks the newest applied rate change as important', () {
      final r = parseFeedNotifications({
        'x': {'type': 'rate_change', 'newRate': 12.5, 'timestamp': 200},
        'y': {
          'type': 'rate_change_manual',
          'newRate': 12.9,
          'oldRate': 12.5,
          'timestamp': 300,
        },
      }, since: 0);

      expect(r.lastRateApplied?.id, 'y');
      expect(r.lastRateApplied?.title, 'Rate updated to ₱12.90/kWh');
      expect(r.lastRateApplied?.urgency, NewsUrgency.important);
    });
  });

  group('DavaoLightFeed.topUrgency', () {
    test('is null when empty and the most pressing level otherwise', () {
      expect(DavaoLightFeed.empty.topUrgency, isNull);
      const item = DavaoLightFeedItem(
        id: '1',
        kind: 'news',
        title: 't',
        message: '',
        link: '',
        source: '',
        timestamp: 1,
        urgency: NewsUrgency.normal,
      );
      expect(const DavaoLightFeed(news: [item]).topUrgency, NewsUrgency.normal);
    });
  });
}
