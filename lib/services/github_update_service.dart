import 'dart:convert';

import 'package:http/http.dart' as http;

class GithubReleaseInfo {
  const GithubReleaseInfo({
    required this.repoSlug,
    required this.tagName,
    required this.releaseName,
    required this.releaseUrl,
    required this.currentVersion,
    required this.latestVersion,
    required this.updateAvailable,
    this.assetName,
    this.assetUrl,
    this.publishedAt,
  });

  final String repoSlug;
  final String tagName;
  final String releaseName;
  final String releaseUrl;
  final String currentVersion;
  final String latestVersion;
  final bool updateAvailable;
  final String? assetName;
  final String? assetUrl;
  final DateTime? publishedAt;
}

class GithubUpdateService {
  static const _userAgent = 'SmartPowerSwitch-Updater';

  static String? normalizeRepoSlug(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    if (!trimmed.contains('github.com')) {
      return _normalizeSlug(trimmed);
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;

    final segments = uri.pathSegments.where((segment) => segment.isNotEmpty).toList();
    if (segments.length < 2) return null;

    return _normalizeSlug('${segments[0]}/${segments[1]}');
  }

  static Future<GithubReleaseInfo> fetchLatestRelease({
    required String repositoryInput,
    required String currentVersion,
  }) async {
    final repoSlug = normalizeRepoSlug(repositoryInput);
    if (repoSlug == null) {
      throw const FormatException('Enter a GitHub repository like owner/repo.');
    }

    final response = await http.get(
      Uri.parse('https://api.github.com/repos/$repoSlug/releases/latest'),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': _userAgent,
      },
    );

    if (response.statusCode != 200) {
      throw Exception('GitHub release lookup failed (${response.statusCode}).');
    }

    final payload = jsonDecode(response.body);
    if (payload is! Map<String, dynamic>) {
      throw Exception('Unexpected GitHub response format.');
    }

    final tagName = (payload['tag_name'] ?? '').toString().trim();
    final releaseName = (payload['name'] ?? tagName).toString().trim();
    final releaseUrl = (payload['html_url'] ?? '').toString();
    final publishedAtRaw = (payload['published_at'] ?? '').toString();
    final assets = (payload['assets'] as List?) ?? const [];
    String? assetName;
    String? assetUrl;

    for (final asset in assets) {
      if (asset is! Map) continue;
      final data = Map<String, dynamic>.from(asset);
      final name = (data['name'] ?? '').toString();
      final downloadUrl = (data['browser_download_url'] ?? '').toString();
      if (name.toLowerCase().endsWith('.apk')) {
        assetName = name;
        assetUrl = downloadUrl;
        break;
      }
      if (assetUrl == null && downloadUrl.isNotEmpty) {
        assetName ??= name;
        assetUrl = downloadUrl;
      }
    }

    final latestVersion = _normalizeVersion(tagName.isNotEmpty ? tagName : releaseName);
    final current = _normalizeVersion(currentVersion);
    final updateAvailable = compareVersions(latestVersion, current) > 0;

    return GithubReleaseInfo(
      repoSlug: repoSlug,
      tagName: tagName,
      releaseName: releaseName,
      releaseUrl: releaseUrl,
      currentVersion: currentVersion,
      latestVersion: latestVersion,
      updateAvailable: updateAvailable,
      assetName: assetName,
      assetUrl: assetUrl,
      publishedAt: publishedAtRaw.isEmpty ? null : DateTime.tryParse(publishedAtRaw),
    );
  }

  static String _normalizeSlug(String value) {
    final cleaned = value
        .replaceAll('https://', '')
        .replaceAll('http://', '')
        .replaceAll('github.com/', '')
        .trim();
    final parts = cleaned.split('/').where((part) => part.isNotEmpty).toList();
    if (parts.length < 2) {
      throw const FormatException('Enter a GitHub repository like owner/repo.');
    }
    final owner = parts[0];
    final repo = parts[1].replaceAll('.git', '');
    return '$owner/$repo';
  }

  static String _normalizeVersion(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '0.0.0';
    final stripped = trimmed
        .replaceFirst(RegExp(r'^[vV]'), '')
        .split('+')
        .first
        .replaceAll(RegExp(r'[^0-9.]'), '.');
    final parts = stripped
        .split('.')
        .where((part) => part.trim().isNotEmpty)
        .map((part) => int.tryParse(part) ?? 0)
        .toList();
    while (parts.length < 3) {
      parts.add(0);
    }
    return parts.take(3).join('.');
  }

  static int compareVersions(String left, String right) {
    final leftParts = _parseVersion(left);
    final rightParts = _parseVersion(right);
    for (var i = 0; i < 3; i++) {
      final comparison = leftParts[i].compareTo(rightParts[i]);
      if (comparison != 0) return comparison;
    }
    return 0;
  }

  static List<int> _parseVersion(String value) {
    final normalized = _normalizeVersion(value);
    return normalized
        .split('.')
        .map((part) => int.tryParse(part) ?? 0)
        .toList(growable: false);
  }
}