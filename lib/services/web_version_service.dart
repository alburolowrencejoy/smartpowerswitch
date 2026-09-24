import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// A version as `flutter build web` writes it to `version.json`.
class WebVersion {
  const WebVersion(this.version, this.buildNumber);

  final String version;
  final String buildNumber;

  String get label =>
      buildNumber.isEmpty ? version : '$version (build $buildNumber)';

  @override
  bool operator ==(Object other) =>
      other is WebVersion &&
      other.version == version &&
      other.buildNumber == buildNumber;

  @override
  int get hashCode => Object.hash(version, buildNumber);
}

/// Website update check: compares the version this page was loaded with
/// against the one currently deployed to Firebase Hosting. (The phone app
/// updates through GitHub releases instead -- see GithubUpdateService.)
class WebVersionService {
  WebVersionService._();

  static Future<WebVersion>? _running;

  /// The version of the code running in this tab. `package_info_plus` reads
  /// `version.json` once and caches it, so call this early (app start-up)
  /// for it to reflect what was loaded rather than a later deployment.
  static Future<WebVersion> running() => _running ??= () async {
        final info = await PackageInfo.fromPlatform();
        return WebVersion(info.version, info.buildNumber);
      }();

  /// The version deployed right now, fetched fresh (cache-busted). Web only.
  static Future<WebVersion> deployed() async {
    if (!kIsWeb) {
      throw UnsupportedError('Only available on the website.');
    }
    final uri = Uri.base.resolve('version.json').replace(queryParameters: {
      't': '${DateTime.now().millisecondsSinceEpoch}',
    });
    final res = await http.get(uri).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw Exception('Server returned ${res.statusCode}.');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return WebVersion(
      (json['version'] ?? '').toString(),
      (json['build_number'] ?? '').toString(),
    );
  }

  /// Reloads the page so the browser picks up the newly deployed files.
  static Future<void> reload() async {
    await launchUrl(Uri.base, webOnlyWindowName: '_self');
  }
}
