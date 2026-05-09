import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_colors.dart';
import '../widgets/top_toast.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<Map<String, dynamic>> _notifications = [];
  bool _loading = true;
  String? _errorText;
  StreamSubscription<DatabaseEvent>? _notificationsSub;

  @override
  void initState() {
    super.initState();
    _listenToNotifications();
  }

  @override
  void dispose() {
    _notificationsSub?.cancel();
    super.dispose();
  }

  void _listenToNotifications() {
    _notificationsSub?.cancel();
    _notificationsSub = FirebaseDatabase.instance
        .ref('notifications')
        .orderByChild('timestamp')
        .limitToLast(50)
        .onValue
        .listen((event) {
      if (!mounted) return;
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data == null) {
        setState(() {
          _notifications = [];
          _loading = false;
          _errorText = null;
        });
        return;
      }
      final list = data.entries.map((e) {
        final val = Map<String, dynamic>.from(e.value as Map);
        val['id'] = e.key;
        return val;
      }).toList();
      list.sort(
          (a, b) => (b['timestamp'] as int).compareTo(a['timestamp'] as int));
      setState(() {
        _notifications = list;
        _loading = false;
        _errorText = null;
      });
    }, onError: (Object error) {
      if (!mounted) return;
      final text = error.toString().toLowerCase();
      final denied = text.contains('permission-denied') ||
          text.contains('permission_denied');
      setState(() {
        _notifications = [];
        _loading = false;
        _errorText = denied
            ? 'You do not have permission to view notifications.'
            : 'Failed to load notifications. Please try again.';
      });
    });
  }

  Future<void> _clearAll() async {
    try {
      await FirebaseDatabase.instance.ref('notifications').remove();
    } catch (_) {
      if (!mounted) return;
      TopToast.error(context, 'Unable to clear notifications.');
    }
  }

  Future<void> _openUrlExternal(String rawUrl) async {
    if (rawUrl.trim().isEmpty) {
      TopToast.error(context, 'No link available.');
      return;
    }

    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null) {
      TopToast.error(context, 'Invalid link.');
      return;
    }

    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      TopToast.error(context, 'Unable to open link.');
    }
  }

  void _showUpdateDetails(Map<String, dynamic> notif) {
    final message = (notif['message'] ?? '').toString();
    final releaseName = (notif['releaseName'] ?? '').toString();
    final latestVersion = (notif['version'] ?? '').toString();
    final currentVersion = (notif['currentVersion'] ?? '').toString();
    final details = (notif['details'] ?? '').toString();
    final changelog = (notif['changelog'] ?? '').toString();
    final releaseUrl = (notif['releaseUrl'] ?? '').toString();
    final assetUrl = (notif['assetUrl'] ?? '').toString();
    final assetName = (notif['assetName'] ?? '').toString();
    final publishedAtRaw = (notif['publishedAt'] ?? '').toString();
    final publishedAt = DateTime.tryParse(publishedAtRaw);

    final title = releaseName.isNotEmpty
        ? releaseName
        : (latestVersion.isNotEmpty ? 'Version $latestVersion' : 'App Update');
    final versionLine = currentVersion.isNotEmpty && latestVersion.isNotEmpty
        ? '$currentVersion -> $latestVersion'
        : latestVersion;
    final notes = changelog.trim().isNotEmpty ? changelog.trim() : details.trim();

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final bottomPadding = MediaQuery.of(ctx).viewInsets.bottom;
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.cardBg,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + bottomPadding),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.greenMid.withAlpha(90),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: 'Outfit',
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textDark,
                  ),
                ),
                if (message.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    message,
                    style: const TextStyle(fontSize: 12, color: AppColors.textMid),
                  ),
                ],
                if (versionLine.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Icon(Icons.system_update_alt_outlined,
                          size: 16, color: AppColors.greenDark),
                      const SizedBox(width: 6),
                      Text(
                        'Version: $versionLine',
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppColors.greenDark),
                      ),
                    ],
                  ),
                ],
                if (publishedAt != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Published: ${publishedAt.day}/${publishedAt.month}/${publishedAt.year}',
                    style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                  ),
                ],
                const SizedBox(height: 14),
                const Text(
                  'What\'s New',
                  style: TextStyle(
                    fontFamily: 'Outfit',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textDark,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 280),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.greenPale,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.greenMid.withAlpha(40)),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      notes.isEmpty
                          ? 'No detailed release notes were provided for this version.'
                          : notes,
                      style: const TextStyle(
                          fontSize: 12.5, height: 1.35, color: AppColors.textDark),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: releaseUrl.isEmpty
                            ? null
                            : () => _openUrlExternal(releaseUrl),
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text('Release Page'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.greenDark,
                          side: BorderSide(color: AppColors.greenDark.withAlpha(80)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: assetUrl.isEmpty
                            ? null
                            : () => _openUrlExternal(assetUrl),
                        icon: const Icon(Icons.download_rounded,
                            size: 16, color: Colors.white),
                        label: Text(
                          assetName.isNotEmpty ? 'Download APK' : 'Download',
                          style: const TextStyle(color: Colors.white),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.greenDark,
                          disabledBackgroundColor: AppColors.textMuted.withAlpha(70),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: _loading
                  ? const Center(
                      child:
                          CircularProgressIndicator(color: AppColors.greenMid))
                  : _errorText != null
                      ? _buildError()
                      : _notifications.isEmpty
                          ? _buildEmpty()
                          : _buildList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      decoration: const BoxDecoration(
        color: AppColors.greenDark,
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(28),
          bottomRight: Radius.circular(28),
        ),
      ),
      child: Row(children: [
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(38),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.arrow_back_ios_new,
                color: Colors.white, size: 16),
          ),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Text('Notifications',
              style: TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.white)),
        ),
        if (_notifications.isNotEmpty)
          TextButton(
            onPressed: _clearAll,
            child: const Text('Clear all',
                style: TextStyle(fontSize: 12, color: AppColors.greenLight)),
          ),
      ]),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: AppColors.greenPale,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(Icons.notifications_none,
                size: 36, color: AppColors.greenMid),
          ),
          const SizedBox(height: 16),
          const Text('No notifications',
              style: TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark)),
          const SizedBox(height: 6),
          const Text(
              'Alerts for high consumption\nand offline devices will appear here.',
              style: TextStyle(fontSize: 13, color: AppColors.textMuted),
              textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.greenPale,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(Icons.lock_outline,
                  size: 34, color: AppColors.greenMid),
            ),
            const SizedBox(height: 16),
            const Text('Cannot load notifications',
                style: TextStyle(
                    fontFamily: 'Outfit',
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textDark)),
            const SizedBox(height: 8),
            Text(_errorText ?? 'Something went wrong.',
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 13, color: AppColors.textMuted)),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    return ListView.separated(
      padding: const EdgeInsets.all(20),
      itemCount: _notifications.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) => _buildNotifCard(_notifications[i]),
    );
  }

  Widget _buildNotifCard(Map<String, dynamic> notif) {
    final type = notif['type'] as String? ?? '';
    final message = notif['message'] as String? ?? '';
    final building = notif['building'] as String? ?? '';
    final deviceId = notif['deviceId'] as String? ?? '';
    final details = notif['details'] as String? ?? '';
    final latestVersion = notif['version'] as String? ?? '';
    final currentVersion = notif['currentVersion'] as String? ?? '';
    final timestamp = notif['timestamp'] as int? ?? 0;
    final isHigh = type == 'high_consumption';
    final isUpdate = type == 'app_update';

    final color = isUpdate
        ? AppColors.greenMid
        : isHigh
            ? AppColors.warning
            : AppColors.error;
    final icon = isUpdate
        ? Icons.system_update_alt_outlined
        : isHigh
            ? Icons.warning_amber_outlined
            : Icons.wifi_off;
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final timeStr =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}  ${dt.day}/${dt.month}/${dt.year}';

    String sourceLine = '';
    if (isUpdate) {
      final from = currentVersion.isEmpty ? 'current' : currentVersion;
      final to = latestVersion.isEmpty ? 'latest' : latestVersion;
      sourceLine = 'Version $from -> $to';
    } else {
      sourceLine = '$building · $deviceId';
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: isUpdate ? () => _showUpdateDetails(notif) : null,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withAlpha(51)),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withAlpha(26),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 20, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(message,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textDark)),
                const SizedBox(height: 4),
                Text(sourceLine,
                    style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
                if (isUpdate && details.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    details,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: AppColors.textMid),
                  ),
                ],
                const SizedBox(height: 2),
                Text(timeStr,
                    style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
