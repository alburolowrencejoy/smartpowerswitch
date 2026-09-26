import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/download_open_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/institute_colors.dart';
import '../../utils/placeholder_data.dart';
import '../../widgets/delete_flow.dart';
import '../../widgets/delete_row_transition.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';
import 'web_theme.dart';
import '../../theme/app_fonts.dart';

/// The desktop "Notifications" section: the same alert feed as
/// [NotificationsScreen] (high-consumption/offline alerts, app-update
/// entries with release notes) laid out as a card grid instead of a single
/// scrolled list. Independent Firebase listener from the mobile screen, so
/// [NotificationsScreen] itself is never touched.
class NotificationsScreenWeb extends StatefulWidget {
  const NotificationsScreenWeb({super.key});

  @override
  State<NotificationsScreenWeb> createState() => _NotificationsScreenWebState();
}

class _NotificationsScreenWebState extends State<NotificationsScreenWeb> {
  static const String _lastSeenNotificationTsKey =
      'notifications_last_seen_timestamp';

  List<Map<String, dynamic>> _notifications = [];
  bool _loading = true;
  String? _errorText;
  bool _newestFirst = true;
  StreamSubscription<DatabaseEvent>? _notificationsSub;

  // ── Institute theming ──────────────────────────────────────────────────
  // This screen has no role/institute constructor params (it's pushed from
  // dashboard_web.dart with no arguments -- see DashboardWeb's IndexedStack
  // and _buildNotificationPanel), so role/institute are hydrated directly
  // from the signed-in user's own record, mirroring mobile
  // notifications_screen.dart's _hydrateSessionFromAuth.
  String _role = 'faculty';
  String? _institute;

  InstitutePalette get _palette =>
      InstituteTheme.resolve(_role, _institute).palette;

  Future<void> _hydrateSessionFromAuth() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final snap =
          await FirebaseDatabase.instance.ref('users/${user.uid}').get();
      final data = snap.value;
      if (data is! Map) return;
      final map = Map<String, dynamic>.from(data);
      final role = (map['role'] as String?) ?? 'faculty';
      final institute = (map['institute'] as String?)?.trim();
      if (!mounted) return;
      setState(() {
        _role = role;
        _institute = institute;
      });
    } catch (_) {
      // Keep existing role defaults if role hydration fails.
    }
  }

  List<Map<String, dynamic>> get _sortedNotifications {
    final sorted = [..._notifications];
    sorted.sort((a, b) {
      final aTs = _notificationTimestamp(a['timestamp']);
      final bTs = _notificationTimestamp(b['timestamp']);
      return _newestFirst ? bTs.compareTo(aTs) : aTs.compareTo(bTs);
    });
    return sorted;
  }

  @override
  void initState() {
    super.initState();
    _hydrateSessionFromAuth();
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
        // A transient null read (reconnect blip) must never blank a
        // notification feed that already loaded once -- only accept "no
        // notifications" before the first successful load.
        setState(() {
          if (_loading) {
            _notifications = [];
          }
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

      unawaited(_markNotificationsAsRead(list));
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

  Future<void> _markNotificationsAsRead(List<Map<String, dynamic>> list) async {
    if (list.isEmpty) return;

    final newestTimestamp = _notificationTimestamp(list.first['timestamp']);
    if (newestTimestamp <= 0) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastSeenNotificationTsKey, newestTimestamp);
  }

  /// Notification ids whose delete animation is playing / commit pending.
  final Set<String> _clearingIds = {};

  /// Same two-step confirm -> reason flow, staggered red strips, 5s Undo
  /// and deferred commit as mobile. An institute admin only clears their
  /// own institute's notifications, never the whole campus's.
  Future<void> _clearAll() async {
    final isInstAdmin = _role == 'institute_admin';
    final code = (_institute ?? '').trim().toUpperCase();
    final targets = isInstAdmin
        ? _notifications
            .where((n) =>
                (n['building'] as String? ?? '').trim().toUpperCase() == code)
            .toList()
        : _notifications;
    if (targets.isEmpty) {
      TopToast.show(context, 'No notifications to clear.', isError: true);
      return;
    }
    final ids =
        targets.map((n) => n['id'] as String?).whereType<String>().toList();

    await showDeleteFlow(
      context,
      type: DeleteType.notifications,
      itemName: isInstAdmin ? '$code notifications' : 'All notifications',
      onOptimisticRemove: () {
        for (var i = 0; i < ids.length; i++) {
          final id = ids[i];
          Future.delayed(Duration(milliseconds: 60 * i), () {
            if (mounted) setState(() => _clearingIds.add(id));
          });
        }
      },
      onRestore: () {
        if (mounted) setState(() => _clearingIds.clear());
      },
      onCommit: (reason, otherText) async {
        try {
          final db = FirebaseDatabase.instance.ref();
          final updates = <String, Object?>{
            if (isInstAdmin)
              for (final id in ids) 'notifications/$id': null
            else
              'notifications': null,
          };
          final logId = db.child('deletion_log').push().key;
          updates['deletion_log/$logId'] = {
            'type': 'notifications',
            'scope': isInstAdmin ? code : 'campus',
            'count': ids.length,
            'reason': reason,
            if (otherText != null && otherText.trim().isNotEmpty)
              'otherText': otherText.trim(),
            'deletedBy': FirebaseAuth.instance.currentUser?.uid ?? 'unknown',
            'deletedByEmail': FirebaseAuth.instance.currentUser?.email ?? '',
            'timestamp': ServerValue.timestamp,
          };
          await db.update(updates);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt(_lastSeenNotificationTsKey, 0);
        } catch (_) {
          if (mounted) setState(() => _clearingIds.removeAll(ids));
          if (!mounted) return;
          TopToast.error(context, 'Unable to clear notifications.');
        }
      },
    );
  }

  int _notificationTimestamp(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<void> _openUrlExternal(String rawUrl) async {
    if (rawUrl.trim().isEmpty) {
      TopToast.error(context, 'No link available.');
      return;
    }

    final launched = await DownloadOpenService.openRemoteUrl(rawUrl);
    if (!launched && mounted) {
      TopToast.error(context, 'Unable to open link.');
    }
  }

  Future<void> _downloadAndOpenFile(String rawUrl, String assetName) async {
    if (rawUrl.trim().isEmpty) {
      TopToast.error(context, 'No download link available.');
      return;
    }

    TopToast.threshold(context, 'Downloading update...');
    final opened = await DownloadOpenService.downloadAndOpenRemoteFile(
      rawUrl,
      suggestedFileName: assetName,
    );
    if (!opened && mounted) {
      TopToast.error(context,
          'Unable to download or open the update. Opening release page instead.');
      await DownloadOpenService.openRemoteUrl(rawUrl);
    } else if (opened && mounted) {
      TopToast.success(context, 'Update downloaded and opened.');
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
    final notes =
        changelog.trim().isNotEmpty ? changelog.trim() : details.trim();

    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: AppFonts.family,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textDark,
                  ),
                ),
                if (message.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(message,
                      style: const TextStyle(
                          fontSize: 13, color: AppColors.textMid)),
                ],
                if (versionLine.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(Icons.system_update_alt_outlined,
                          size: 16, color: _palette.dark),
                      const SizedBox(width: 6),
                      Text(
                        'Version: $versionLine',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: _palette.dark),
                      ),
                    ],
                  ),
                ],
                if (publishedAt != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Published: ${publishedAt.day}/${publishedAt.month}/${publishedAt.year}',
                    style: const TextStyle(
                        fontSize: 12, color: WebColors.muted),
                  ),
                ],
                const SizedBox(height: 14),
                const Text(
                  'What\'s New',
                  style: TextStyle(
                    fontFamily: AppFonts.family,
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
                    color: _palette.pale,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _palette.mid.withAlpha(40)),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      notes.isEmpty
                          ? 'No detailed release notes were provided for this version.'
                          : notes,
                      style: const TextStyle(
                          fontSize: 13.5,
                          height: 1.35,
                          color: AppColors.textDark),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      // Bug fix: no explicit style meant this fell back to
                      // the app-wide seed-green ColorScheme.primary
                      // (main.dart) instead of this viewer's resolved
                      // institute theme -- WebColors.muted matches the
                      // "Cancel"/neutral-dismiss convention used by every
                      // other dialog button in this file.
                      child: const Text('Close',
                          style: TextStyle(color: WebColors.muted)),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: releaseUrl.isEmpty
                          ? null
                          : () => _openUrlExternal(releaseUrl),
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: const Text('Release Page'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _palette.dark,
                        side: BorderSide(color: _palette.dark.withAlpha(80)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: assetUrl.isEmpty
                          ? null
                          : () => _downloadAndOpenFile(assetUrl, assetName),
                      icon: const Icon(Icons.download_rounded,
                          size: 16, color: Colors.white),
                      label: Text(
                        assetName.isNotEmpty ? 'Download & Open' : 'Download',
                        style: const TextStyle(color: Colors.white),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _palette.dark,
                        disabledBackgroundColor:
                            WebColors.muted.withAlpha(70),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showLoadingPlaceholder = _loading && _notifications.isEmpty;
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(_role, _institute)],
      ),
      child: ScreenSkeleton(
      isLoading: showLoadingPlaceholder,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_notifications.isNotEmpty || showLoadingPlaceholder) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_notifications.length} ${_notifications.length == 1 ? 'alert' : 'alerts'}',
                      style: const TextStyle(
                          fontSize: 13, color: WebColors.muted),
                    ),
                  ),
                  _iconToggle(
                    icon: _newestFirst
                        ? Icons.arrow_downward
                        : Icons.arrow_upward,
                    tooltip: _newestFirst ? 'Newest first' : 'Oldest first',
                    onTap: () => setState(() => _newestFirst = !_newestFirst),
                  ),
                  const SizedBox(width: 6),
                  _iconToggle(
                    icon: Icons.clear_all,
                    tooltip: 'Clear all',
                    onTap: _clearAll,
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            if (showLoadingPlaceholder)
              _buildList(placeholderNotificationList())
            else if (_errorText != null)
              _buildError()
            else if (_notifications.isEmpty)
              _buildEmpty()
            else
              _buildList(_sortedNotifications),
          ],
        ),
      ),
      ),
    );
  }

  Widget _iconToggle({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: _palette.pale,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Icon(icon, size: 16, color: _palette.dark),
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 40),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _palette.mid.withAlpha(26)),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: _palette.pale,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(Icons.notifications_none,
                  size: 30, color: _palette.mid),
            ),
            const SizedBox(height: 14),
            const Text('No notifications',
                style: TextStyle(
                    fontFamily: AppFonts.family,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textDark)),
            const SizedBox(height: 6),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                  'Alerts for high consumption and offline devices will appear here.',
                  style: TextStyle(fontSize: 13, color: WebColors.muted),
                  textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _palette.mid.withAlpha(26)),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: _palette.pale,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(Icons.lock_outline, size: 28, color: _palette.mid),
            ),
            const SizedBox(height: 14),
            const Text('Cannot load notifications',
                style: TextStyle(
                    fontFamily: AppFonts.family,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textDark)),
            const SizedBox(height: 8),
            Text(_errorText ?? 'Something went wrong.',
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 13, color: WebColors.muted)),
          ],
        ),
      ),
    );
  }

  Widget _buildList(List<Map<String, dynamic>> items) {
    return Column(
      children: [
        for (var i = 0; i < items.length; i++)
          // Gap outside the transition so the red strip hangs from the card
          // itself, not from the gap below it.
          Padding(
            key: ValueKey(items[i]['id']),
            padding: EdgeInsets.only(top: i > 0 ? 8 : 0),
            child: DeleteRowTransition(
              deleting: _clearingIds.contains(items[i]['id']),
              message: 'Notification cleared',
              child: _buildNotifCard(items[i]),
            ),
          ),
      ],
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
    final isRateChange = type == 'rate_change' ||
        type == 'rate_change_manual' ||
        type == 'rate_change_manual';

    // Semantic: notification-type severity tier (rate-change/update = green
    // "info", high-consumption = warning, offline-device = error) -- not
    // brand chrome, so deliberately NOT retheme'd (matches mobile
    // notifications_screen.dart). Drives this card's icon, icon background,
    // and border below.
    final color = isRateChange
        ? AppColors.greenMid
        : isUpdate
            ? AppColors.greenMid
            : isHigh
                ? AppColors.warning
                : AppColors.error;
    final icon = isRateChange
        ? Icons.check_circle
        : isUpdate
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
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.cardBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withAlpha(51)),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color.withAlpha(26),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 17, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textDark)),
                    const SizedBox(height: 3),
                    Text(sourceLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: WebColors.muted)),
                    if (isUpdate && details.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        details,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11.5, color: AppColors.textMid),
                      ),
                    ],
                    const SizedBox(height: 2),
                    Text(timeStr,
                        style: const TextStyle(
                            fontSize: 11, color: WebColors.muted)),
                  ]),
            ),
          ]),
        ),
      ),
    );
  }
}
