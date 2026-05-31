import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

class DownloadOpenService {
  static Future<bool> openRemoteUrl(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null) return false;
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  static Future<bool> downloadAndOpenRemoteFile(
    String rawUrl, {
    String? suggestedFileName,
  }) async {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return false;

    final uri = Uri.tryParse(trimmed);
    if (uri == null) return false;

    if (kIsWeb || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return launchUrl(uri, mode: LaunchMode.externalApplication);
    }

    try {
      final client = http.Client();
      try {
        final request = http.Request('GET', uri);
        request.headers['User-Agent'] = 'SmartPowerSwitch-Updater';
        final streamed = await client.send(request).timeout(const Duration(seconds: 30));
        if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
          return launchUrl(uri, mode: LaunchMode.externalApplication);
        }

        final bytes = await streamed.stream.toBytes();
        if (bytes.isEmpty) return launchUrl(uri, mode: LaunchMode.externalApplication);

        final directory = await getTemporaryDirectory();
        final fileName = _resolveFileName(uri, suggestedFileName);
        final file = File('${directory.path}/$fileName');
        await file.writeAsBytes(bytes, flush: true);

        final result = await OpenFilex.open(file.path);
        if (result.type == ResultType.done) return true;
        return launchUrl(uri, mode: LaunchMode.externalApplication);
      } finally {
        client.close();
      }
    } catch (e) {
      // If anything fails, fallback to opening the remote URL in browser
      return launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  static String _resolveFileName(Uri uri, String? suggestedFileName) {
    final rawName =
        (suggestedFileName != null && suggestedFileName.trim().isNotEmpty)
            ? suggestedFileName.trim()
            : (uri.pathSegments.isNotEmpty
                ? uri.pathSegments.last
                : 'download.bin');

    final sanitized = rawName.split('?').first.split('#').first.trim();
    if (sanitized.isEmpty) {
      return 'download.bin';
    }

    return sanitized.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }
}
