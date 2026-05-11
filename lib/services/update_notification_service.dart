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

      final versionComparison = GithubUpdateService.compareVersions(
        release.latestVersion,
        release.currentVersion,
      );
      if (versionComparison < 0) return;
      if (versionComparison == 0 && release.releaseBody.trim().isEmpty) return;

      final releaseSignature = _buildReleaseSignature(release);

      final lockRef = FirebaseDatabase.instance
          .ref('settings/updateNotifications/lastReleaseSignatureNotified');

      final tx = await lockRef.runTransaction((current) {
        final existing = (current ?? '').toString();
        if (existing == releaseSignature) {
          return Transaction.abort();
        }
        return Transaction.success(releaseSignature);
      });

      if (!tx.committed) return;

      final summary = _toSummary(release.releaseBody);
      final updateLabel = release.releaseName.isEmpty
          ? release.latestVersion
          : release.releaseName;

      await FirebaseDatabase.instance.ref('notifications').push().set({
        'type': 'app_update',
        'message': versionComparison > 0
            ? 'New update available: $updateLabel'
            : 'Release notes updated: $updateLabel',
        'releaseName': release.releaseName,
        'version': release.latestVersion,
        'currentVersion': release.currentVersion,
        'details': summary,
        'changelog': release.releaseBody,
        'publishedAt': release.publishedAt?.toIso8601String() ?? '',
        'releaseUrl': release.releaseUrl,
        'assetName': release.assetName ?? '',
        'assetUrl': release.assetUrl ?? '',
        'releaseSignature': releaseSignature,
        'timestamp': ServerValue.timestamp,
      });
    } catch (_) {
      // Ignore update-check failures; startup should remain resilient.
    }
  }

  static String _buildReleaseSignature(GithubReleaseInfo release) {
    final parts = [
      release.repoSlug,
      release.tagName,
      release.releaseName,
      release.releaseBody,
      release.releaseUrl,
      release.publishedAt?.toIso8601String() ?? '',
      release.assetName ?? '',
      release.assetUrl ?? '',
    ];
    return _hash32(parts.join('\u001f'));
  }

  static String _hash32(String input) {
    var hash = 0x811c9dc5;
    for (final codeUnit in input.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toUnsigned(32).toRadixString(16).padLeft(8, '0');
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
