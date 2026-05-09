import 'package:firebase_database/firebase_database.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'github_update_service.dart';

class UpdateNotificationService {
  static const String _fixedGithubRepo = 'alburolowrencejoy/smartpowerswitch';

  static Future<void> checkAndNotifyIfNewRelease() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version.isEmpty ? '0.0.0' : packageInfo.version;

      final release = await GithubUpdateService.fetchLatestRelease(
        repositoryInput: _fixedGithubRepo,
        currentVersion: currentVersion,
      );

      if (!release.updateAvailable) return;

      final lockRef = FirebaseDatabase.instance
          .ref('settings/updateNotifications/lastVersionNotified');

      final tx = await lockRef.runTransaction((current) {
        final existing = (current ?? '').toString();
        if (existing == release.latestVersion) {
          return Transaction.abort();
        }
        return Transaction.success(release.latestVersion);
      });

      if (!tx.committed) return;

      final summary = _toSummary(release.releaseBody);
      final updateLabel = release.releaseName.isEmpty
          ? release.latestVersion
          : release.releaseName;

      await FirebaseDatabase.instance.ref('notifications').push().set({
        'type': 'app_update',
        'message': 'New update available: $updateLabel',
        'releaseName': release.releaseName,
        'version': release.latestVersion,
        'currentVersion': release.currentVersion,
        'details': summary,
        'changelog': release.releaseBody,
        'publishedAt': release.publishedAt?.toIso8601String() ?? '',
        'releaseUrl': release.releaseUrl,
        'assetName': release.assetName ?? '',
        'assetUrl': release.assetUrl ?? '',
        'timestamp': ServerValue.timestamp,
      });
    } catch (_) {
      // Ignore update-check failures; startup should remain resilient.
    }
  }

  static String _toSummary(String body) {
    final text = body
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .take(3)
        .join(' • ');

    if (text.isEmpty) {
      return 'A new version was published with improvements and fixes.';
    }

    return text.length > 260 ? '${text.substring(0, 257)}...' : text;
  }
}
