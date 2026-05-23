import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:http/http.dart' as http;

/// Represents a change in electricity rates from Davao Light.
class RateChangeData {
  RateChangeData({
    required this.oldRate,
    required this.newRate,
    required this.hasChanged,
    required this.fetchedAt,
    this.effectiveDate,
    this.source,
    this.errorMessage,
  });

  /// Current rate stored in Firebase (before fetch)
  final double oldRate;

  /// Latest rate fetched from Davao Light
  final double newRate;

  /// Whether the rate has changed compared to oldRate
  final bool hasChanged;

  /// When the rate data was fetched
  final DateTime fetchedAt;

  /// When the new rate becomes effective (if available)
  final DateTime? effectiveDate;

  /// Source of the rate (e.g., 'davaolight_faq', 'manual', 'error')
  final String? source;

  /// Error message if fetch failed
  final String? errorMessage;

  @override
  String toString() =>
      'RateChangeData(oldRate: $oldRate, newRate: $newRate, hasChanged: $hasChanged, '
      'fetchedAt: $fetchedAt, effectiveDate: $effectiveDate, source: $source, error: $errorMessage)';
}

/// Service for monitoring Davao Light electricity rates.
///
/// This service fetches electricity rates from Davao Light's FAQ page and
/// compares them with rates stored in Firebase. Since Davao Light's website
/// uses JavaScript to render rates dynamically, this service attempts to
/// parse available rate numbers from the page content.
///
/// TODO: Update this to use Davao Light's API or a structured data source once available.
/// TODO: Consider implementing a web scraping solution with Selenium or similar if HTML parsing becomes unreliable.
class DavaoLightRateMonitor {
  static const String _logPrefix = '[DavaoLightRateMonitor]';
  static const String _davaoLightFaqUrl =
      'https://www.davaolight.com/customer-services/faq';
  static const Duration _requestTimeout = Duration(seconds: 15);
  static const String _firebaseRatePath = 'settings/electricityRate';

  static void debugPrint(String message) {
    // Use print here so logging works even if Flutter debug utilities are
    // unavailable in certain release/build environments.
    // ignore: avoid_print
    print(message);
  }

  final FirebaseDatabase _firebaseDb;

  DavaoLightRateMonitor({FirebaseDatabase? firebaseDb})
      : _firebaseDb = firebaseDb ?? FirebaseDatabase.instance;

  /// Checks for electricity rate changes.
  ///
  /// Fetches the latest rate from Davao Light's FAQ page and compares it
  /// with the provided [currentRate]. Returns a [RateChangeData] object
  /// with the comparison results.
  ///
  /// Parameters:
  ///   - [currentRate]: The current rate stored in Firebase (for comparison)
  ///
  /// Returns:
  ///   A [RateChangeData] object containing the old rate, new rate, change status,
  ///   and timestamp. If the fetch fails, [hasChanged] will be false and
  ///   [errorMessage] will contain the error details.
  Future<RateChangeData> checkForRateChange(double currentRate) async {
    debugPrint(
      '$_logPrefix Checking for rate changes (current: \$${currentRate.toStringAsFixed(4)}/kWh)',
    );

    try {
      final fetchedRate = await _fetchLatestRate();
      final now = DateTime.now();

      if (fetchedRate == null) {
        debugPrint(
          '$_logPrefix Could not extract rate from Davao Light website. '
          'Returning hasChanged=false',
        );
        return RateChangeData(
          oldRate: currentRate,
          newRate: currentRate,
          hasChanged: false,
          fetchedAt: now,
          source: 'error_no_rate_found',
          errorMessage: 'Could not extract rate from Davao Light FAQ page',
        );
      }

      final hasChanged = (fetchedRate - currentRate).abs() > 0.0001;
      debugPrint(
        '$_logPrefix Rate comparison: old=\$${currentRate.toStringAsFixed(4)}, '
        'new=\$${fetchedRate.toStringAsFixed(4)}, hasChanged=$hasChanged',
      );

      return RateChangeData(
        oldRate: currentRate,
        newRate: fetchedRate,
        hasChanged: hasChanged,
        fetchedAt: now,
        source: 'davaolight_faq',
      );
    } catch (e, stackTrace) {
      debugPrint('$_logPrefix Error checking rate: $e');
      debugPrint('$_logPrefix Stack trace: $stackTrace');

      return RateChangeData(
        oldRate: currentRate,
        newRate: currentRate,
        hasChanged: false,
        fetchedAt: DateTime.now(),
        source: 'error',
        errorMessage: 'Network or parsing error: $e',
      );
    }
  }

  /// Fetches the latest electricity rate from Davao Light's FAQ page.
  ///
  /// Attempts to parse the HTML response to find rate information.
  /// Looks for patterns like "PHP X.XXXX" or "$X.XXXX" in the page content.
  ///
  /// Returns:
  ///   The fetched rate as a double, or null if no rate could be extracted.
  ///
  /// Throws:
  ///   An exception if the HTTP request fails.
  Future<double?> _fetchLatestRate() async {
    debugPrint('$_logPrefix Fetching from: $_davaoLightFaqUrl');

    final uri = Uri.parse(_davaoLightFaqUrl);
    final response = await http.get(uri).timeout(
      _requestTimeout,
      onTimeout: () {
        throw TimeoutException(
          'Request to Davao Light FAQ timed out after ${_requestTimeout.inSeconds}s',
        );
      },
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to fetch Davao Light FAQ (HTTP ${response.statusCode})',
      );
    }

    debugPrint('$_logPrefix Successfully fetched page (${response.body.length} bytes)');

    return _parseRateFromHtml(response.body);
  }

  /// Parses rate information from the HTML content of the Davao Light FAQ page.
  ///
  /// Attempts multiple strategies to extract the rate:
  /// 1. Looks for "PHP X.XXXX" patterns
  /// 2. Looks for "$X.XXXX" patterns
  /// 3. Looks for "rate" followed by a number
  /// 4. Looks for "kwh" or "kWh" followed by a number
  ///
  /// TODO: This is a best-effort approach. Once Davao Light provides an API
  /// or structured data feed, switch to that instead of HTML parsing.
  ///
  /// Returns:
  ///   The extracted rate as a double, or null if no valid rate was found.
  double? _parseRateFromHtml(String htmlContent) {
    // Strategy 1: Look for "PHP X.XXXX" pattern
    final phpPattern = RegExp(r'PHP\s*([\d.]+)', caseSensitive: false);
    final phpMatch = phpPattern.firstMatch(htmlContent);
    if (phpMatch != null) {
      final rateStr = phpMatch.group(1);
      if (rateStr != null) {
        final rate = double.tryParse(rateStr);
        if (rate != null && rate > 0 && rate < 100) {
          debugPrint('$_logPrefix Found rate via PHP pattern: \$$rate');
          return rate;
        }
      }
    }

    // Strategy 2: Look for "$X.XXXX" pattern (standalone dollar amounts)
    // Filter for 2-5 digit patterns (typical rate range)
    final dollarPattern = RegExp(r'\$\s*([\d.]+)');
    for (final match in dollarPattern.allMatches(htmlContent)) {
      final rateStr = match.group(1);
      if (rateStr != null) {
        final rate = double.tryParse(rateStr);
        if (rate != null && rate > 0 && rate < 100) {
          debugPrint('$_logPrefix Found rate via dollar pattern: \$$rate');
          return rate;
        }
      }
    }

    // Strategy 3: Look for "rate" followed by a number
    final ratePattern = RegExp(
      r'rate\s*[:\=]?\s*(?:php\s*)?([\d.]+)',
      caseSensitive: false,
    );
    final rateMatch = ratePattern.firstMatch(htmlContent);
    if (rateMatch != null) {
      final rateStr = rateMatch.group(1);
      if (rateStr != null) {
        final rate = double.tryParse(rateStr);
        if (rate != null && rate > 0 && rate < 100) {
          debugPrint('$_logPrefix Found rate via rate pattern: \$$rate');
          return rate;
        }
      }
    }

    // Strategy 4: Look for "kwh" or "kWh" followed by currency info
    final kwhPattern = RegExp(
      r'(?:kwh|kWh|kw\/h)\s*(?:rate|=|:)?\s*(?:php\s*)?([\d.]+)',
      caseSensitive: false,
    );
    final kwhMatch = kwhPattern.firstMatch(htmlContent);
    if (kwhMatch != null) {
      final rateStr = kwhMatch.group(1);
      if (rateStr != null) {
        final rate = double.tryParse(rateStr);
        if (rate != null && rate > 0 && rate < 100) {
          debugPrint('$_logPrefix Found rate via kWh pattern: \$$rate');
          return rate;
        }
      }
    }

    debugPrint('$_logPrefix No valid rate pattern found in HTML content');
    return null;
  }

  /// Retrieves the current electricity rate from Firebase.
  ///
  /// Returns:
  ///   The current rate, or null if not set in Firebase.
  Future<double?> getCurrentRateFromFirebase() async {
    try {
      final ref = _firebaseDb.ref().child(_firebaseRatePath);
      final snapshot = await ref.get();

      if (!snapshot.exists) {
        debugPrint('$_logPrefix No rate found in Firebase at $_firebaseRatePath');
        return null;
      }

      final value = snapshot.value;
      if (value is num) {
        final rate = value.toDouble();
        debugPrint('$_logPrefix Current rate from Firebase: \$$rate');
        return rate;
      }

      debugPrint('$_logPrefix Firebase rate value is not a number: $value');
      return null;
    } catch (e) {
      debugPrint('$_logPrefix Error retrieving rate from Firebase: $e');
      return null;
    }
  }

  /// Saves a new electricity rate to Firebase.
  ///
  /// Stores the rate at `settings/electricityRate` and also updates
  /// the `settings/lastRateUpdate` timestamp.
  ///
  /// Parameters:
  ///   - [rate]: The new rate to store
  ///
  /// Returns:
  ///   True if the save was successful, false otherwise.
  Future<bool> saveRateToFirebase(double rate) async {
    try {
      final updates = {
        _firebaseRatePath: rate,
        'settings/lastRateUpdate': DateTime.now().millisecondsSinceEpoch,
      };

      await _firebaseDb.ref().update(updates);
      debugPrint('$_logPrefix Saved rate \$$rate to Firebase');
      return true;
    } catch (e) {
      debugPrint('$_logPrefix Error saving rate to Firebase: $e');
      return false;
    }
  }

  /// Performs a complete rate monitoring cycle.
  ///
  /// This is a convenience method that:
  /// 1. Retrieves the current rate from Firebase
  /// 2. Checks for rate changes from Davao Light
  /// 3. Saves the new rate if it has changed
  ///
  /// Returns:
  ///   The [RateChangeData] object with comparison results and current rate from Firebase.
  Future<RateChangeData> monitorAndUpdateRate() async {
    try {
      final currentRate = await getCurrentRateFromFirebase() ?? 9.0;
      final changeData = await checkForRateChange(currentRate);

      if (changeData.hasChanged) {
        final saved = await saveRateToFirebase(changeData.newRate);
        if (saved) {
          debugPrint(
            '$_logPrefix Rate updated: \$${changeData.oldRate.toStringAsFixed(4)} '
            '-> \$${changeData.newRate.toStringAsFixed(4)}',
          );
        } else {
          debugPrint('$_logPrefix Rate change detected but failed to save to Firebase');
        }
      }

      return changeData;
    } catch (e) {
      debugPrint('$_logPrefix Error in monitorAndUpdateRate: $e');
      rethrow;
    }
  }
}
