import 'package:flutter/foundation.dart';

/// Sections of the Analytics page that other screens (mainly the web
/// dashboard) can link straight to.
enum AnalyticsSection {
  /// "Consumption Trend" chart.
  trend,

  /// ARIMA / comparison forecast cards.
  forecast,

  /// "Top Consuming Utilities".
  utilities,

  /// "Top Consuming Institutes / Rooms / Devices".
  institutes,

  /// "History" table (latest days with trend), at the bottom.
  history,
}

/// Set by a caller to ask the Analytics page to scroll to a section; the
/// page scrolls there once it can and then resets this to null.
typedef AnalyticsFocus = ValueNotifier<AnalyticsSection?>;
