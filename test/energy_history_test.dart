import 'package:flutter_test/flutter_test.dart';
import 'package:smart_power_switch/services/energy_history.dart';

void main() {
  final raw = {
    'daily': {
      '2026-10-11': {
        'campus': {'kwh': 0.009, 'cost': 0.119},
        'buildings': {
          'IC': {'kwh': 0.005, 'cost': 0.066},
        },
        'devices': {
          'ESP32-A': {'kwh': 0.002, 'cost': 0.026, 'building': 'IC'},
        },
      },
    },
    'monthly': {
      '2026-10': {
        'campus': {'kwh': 1.5, 'cost': 19.86},
      },
    },
  };

  test('campus becomes total_kwh/total_cost; buildings and devices unchanged',
      () {
    final day = EnergyHistory.legacyRoot(raw)['daily']['2026-10-11'];
    expect(day['total_kwh'], 0.009);
    expect(day['total_cost'], 0.119);
    expect(day.containsKey('campus'), isFalse);
    expect(day['buildings']['IC']['kwh'], 0.005);
    expect(day['devices']['ESP32-A']['building'], 'IC');
  });

  test('a single range converts the same way', () {
    final months = EnergyHistory.legacyRange(raw['monthly']);
    expect(months['2026-10']['total_kwh'], 1.5);
    expect(months['2026-10']['total_cost'], 19.86);
  });

  test('missing or malformed data gives empty maps, never throws', () {
    expect(EnergyHistory.legacyRoot(null), isEmpty);
    expect(EnergyHistory.legacyRange('x'), isEmpty);
    expect(EnergyHistory.legacyPeriod(null), isEmpty);
    expect(EnergyHistory.legacyRange({'2026-10-11': 5}), isEmpty);
    expect(EnergyHistory.legacyPeriod({'devices': {}}).containsKey('total_kwh'),
        isFalse);
  });

  test('paths', () {
    expect(EnergyHistory.path('daily'), 'energy_summaries/daily');
    expect(EnergyHistory.path('daily', '2026-10-11'),
        'energy_summaries/daily/2026-10-11');
  });
}
