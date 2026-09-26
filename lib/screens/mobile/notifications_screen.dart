import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import '../../services/notification_seen.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../theme/institute_colors.dart';
import '../../services/download_open_service.dart';
import '../../utils/placeholder_data.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/app_top_bar.dart';
import '../../widgets/delete_flow.dart';
import '../../widgets/delete_row_transition.dart';
import '../../widgets/screen_skeleton.dart';
import '../../widgets/top_toast.dart';

/// Notifications (handoff §4.10, institute-admin variant §5).
///
/// This is a single **shared** Firebase list (`notifications`), not a
/// per-user inbox -- there is no per-notification "read by me" flag, so
/// "unread" is derived client-side from a locally-stored
/// "last seen" timestamp ([NotificationSeen]) (as the old screen already did).
/// [_lastSeenAtOpen] captures that value once, *before* this screen's own
/// visit silently advances it, so rows opened this session still render
/// their correct unread dot instead of a lastSeen value that already moved.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

enum _NotifFilter { all, alerts, rate, updates }

class _NotificationsScreenState extends State<NotificationsScreen> {

  List<Map<String, dynamic>> _notifications = [];
  bool _loading = true;
  String? _errorText;
  StreamSubscription<DatabaseEvent>? _notificationsSub;

  // Unread bookkeeping -- see class doc.
  int? _lastSeenAtOpen;
  bool _lastSeenCaptured = false;

  _NotifFilter _filter = _NotifFilter.all;

  // Ids currently mid-clear-all animation (see [_clearAll]). Rows stay
  // mounted (never spliced out of [_notifications] by this screen) while an
  // id is in here -- DeleteRowTransition animates them out locally, and the
  // real removal only becomes visible once the deferred Firebase delete
  // commits and the listener naturally drops the row.
  final Set<String> _clearingIds = {};

  // ── Institute theming ──────────────────────────────────────────────────
  // This screen is a standalone pushed route (no role/institute constructor
  // args -- see main.dart's '/notifications' route), so role/institute are
  // hydrated directly from the signed-in user's own record, mirroring
  // dashboard_screen.dart's _hydrateSessionFromAuth.
  String _role = 'faculty';
  String? _institute;

  InstitutePalette get _palette =>
      InstituteTheme.resolve(_role, _institute).palette;

  bool get _isInstituteAdmin =>
      _role == 'institute_admin' && (_institute?.trim().isNotEmpty ?? false);

  String? get _instituteCode => _institute?.trim().toUpperCase();

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

  @override
  void initState() {
    super.initState();
    _captureLastSeen();
    _hydrateSessionFromAuth();
    _listenToNotifications();
  }

  @override
  void dispose() {
    _notificationsSub?.cancel();
    super.dispose();
  }

  Future<void> _captureLastSeen() async {
    await NotificationSeen.instance.ensureLoaded();
    if (!mounted) return;
    setState(() {
      _lastSeenAtOpen = NotificationSeen.instance.lastSeen.value;
      _lastSeenCaptured = true;
    });
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
          // Only accept "no notifications" before the first successful
          // load -- once real data has been shown this session, a later
          // null/empty snapshot (e.g. a reconnect blip) must not blank it
          // back out. `_loading` never reverts to true after this.
          if (_loading) _notifications = [];
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
        if (_loading) _notifications = [];
        _loading = false;
        _errorText = denied
            ? 'You do not have permission to view notifications.'
            : 'Failed to load notifications. Please try again.';
      });
    });
  }

  /// Newest of the list, whatever its sort order, through the shared seen
  /// state so every bell and badge clears at once.
  Future<void> _markNotificationsAsRead(List<Map<String, dynamic>> list) =>
      NotificationSeen.instance.markSeen(NotificationSeen.newestOf(list));

  Future<void> _markAllRead() async {
    if (_notifications.isEmpty) return;
    final newest = NotificationSeen.newestOf(_notifications);
    await NotificationSeen.instance.markSeen(newest);
    if (!mounted) return;
    setState(() => _lastSeenAtOpen = newest);
    TopToast.success(context, 'All notifications marked as read.');
  }

  /// The two-step delete flow for "clear all" (handoff §4.10/§5/§7).
  ///
  /// Bug fix: `notifications` is one shared Firebase list, not a per-user
  /// inbox. The previous implementation always ran an unscoped
  /// `ref('notifications').remove()` -- an institute admin tapping "clear
  /// all" wiped every user's notifications, including other institutes' and
  /// campus-wide (rate/update) ones. Per handoff §5 ("clear all clears
  /// institute notifications"), an institute admin's clear-all must only
  /// remove the rows scoped to their own institute (`building` matches
  /// their institute code); campus/main admins keep clearing the whole
  /// node. The actual Firebase write is deferred to [DeleteCommit], which
  /// only runs once the 5s Undo window in [showDeleteFlow] elapses.
  Future<void> _clearAll() async {
    if (_notifications.isEmpty) return;

    final isInstAdmin = _isInstituteAdmin;
    final code = _instituteCode;
    final targets = isInstAdmin
        ? _notifications
            .where((n) =>
                (n['building'] as String? ?? '').trim().toUpperCase() == code)
            .toList()
        : _notifications;

    if (targets.isEmpty) {
      TopToast.show(context, 'No notifications to clear for $code.',
          isError: true);
      return;
    }

    final ids = targets
        .map((n) => n['id'] as String?)
        .whereType<String>()
        .toList();

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
          final updates = <String, Object?>{};
          if (isInstAdmin) {
            for (final id in ids) {
              updates['notifications/$id'] = null;
            }
          } else {
            updates['notifications'] = null;
          }
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
          await NotificationSeen.instance.reset();
        } catch (e) {
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

  bool _isUnread(Map<String, dynamic> notif) {
    if (!_lastSeenCaptured) return false;
    return _notificationTimestamp(notif['timestamp']) >
        (_lastSeenAtOpen ?? 0);
  }

  _NotifFilter _categoryOf(Map<String, dynamic> notif) {
    final type = notif['type'] as String? ?? '';
    if (type == 'app_update') return _NotifFilter.updates;
    if (type == 'rate_change' || type == 'rate_change_manual') {
      return _NotifFilter.rate;
    }
    return _NotifFilter.alerts; // high_consumption, offline, unknown.
  }

  /// Rows an institute admin is allowed to see at all: their own
  /// institute's building-scoped alerts, plus campus-wide entries (rate
  /// changes, app updates) that have no `building` and affect everyone.
  /// [source] defaults to the live [_notifications] list; the loading
  /// skeleton passes in the placeholder list instead so the shimmer shows a
  /// realistically-grouped/filtered shape rather than an empty state.
  List<Map<String, dynamic>> _visibleForRole([
    List<Map<String, dynamic>>? source,
  ]) {
    final base = source ?? _notifications;
    if (!_isInstituteAdmin) return base;
    final code = _instituteCode;
    return base.where((n) {
      final building = (n['building'] as String? ?? '').trim().toUpperCase();
      return building.isEmpty || building == code;
    }).toList();
  }

  List<Map<String, dynamic>> _filtered([List<Map<String, dynamic>>? source]) {
    final visible = _visibleForRole(source);
    if (_filter == _NotifFilter.all) return visible;
    return visible.where((n) => _categoryOf(n) == _filter).toList();
  }

  int get _unreadCount => _visibleForRole().where(_isUnread).length;

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

  /// Tap navigation (handoff §4.10: "Tap navigates to the relevant screen
  /// (building/device/settings)"). The shared `notifications` list only
  /// carries a building **code**/device **id** string, not the full
  /// building-floor/device-detail record those screens require -- so each
  /// case does one explicit, error-handled Firebase read first rather than
  /// guessing at floors/utility/room, and surfaces a toast instead of
  /// navigating into a broken screen if that read comes back empty.
  Future<void> _openBuilding(String code) async {
    if (code.trim().isEmpty) return;
    try {
      final snap = await FirebaseDatabase.instance.ref('buildings/$code').get();
      if (!mounted) return;
      if (!snap.exists) {
        TopToast.error(context, 'That building no longer exists.');
        return;
      }
      final data = Map<String, dynamic>.from(snap.value as Map);
      Navigator.pushNamed(context, '/building', arguments: {
        'buildingCode': code,
        'buildingName': (data['name'] as String?) ?? code,
        'floors': (data['floors'] as num?)?.toInt() ?? 1,
        'role': _role,
      });
    } catch (_) {
      if (!mounted) return;
      TopToast.error(context, 'Unable to open that building right now.');
    }
  }

  Future<void> _openDevice(String deviceId) async {
    if (deviceId.trim().isEmpty) return;
    try {
      final snap =
          await FirebaseDatabase.instance.ref('devices/$deviceId').get();
      if (!mounted) return;
      if (!snap.exists) {
        TopToast.error(context, 'That device is no longer registered.');
        return;
      }
      final data = Map<String, dynamic>.from(snap.value as Map);
      Navigator.pushNamed(context, '/device', arguments: {
        'deviceId': deviceId,
        'utility': (data['utility'] as String?) ?? 'Electricity',
        'building': (data['building'] as String?) ?? '',
        'room': (data['room'] as String?) ?? 'unknown',
        'floor': (data['floor'] as num?)?.toInt() ?? 1,
        'role': _role,
      });
    } catch (_) {
      if (!mounted) return;
      TopToast.error(context, 'Unable to open that device right now.');
    }
  }

  void _openSettings() {
    Navigator.pushNamed(context, '/settings');
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

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final bottomPadding = MediaQuery.of(ctx).viewInsets.bottom;
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
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
                      color: _palette.mid.withAlpha(90),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(title,
                    style: AppTextStyles.title.copyWith(color: AppColors.ink)),
                if (message.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(message,
                      style: AppTextStyles.bodySm
                          .copyWith(color: AppColors.inkMid)),
                ],
                if (versionLine.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(Icons.system_update_alt_outlined,
                          size: 16, color: _palette.dark),
                      const SizedBox(width: 6),
                      Text('Version: $versionLine',
                          style: AppTextStyles.caption
                              .copyWith(color: _palette.dark)),
                    ],
                  ),
                ],
                if (publishedAt != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Published: ${publishedAt.day}/${publishedAt.month}/${publishedAt.year}',
                    style:
                        AppTextStyles.caption.copyWith(color: AppColors.inkMuted),
                  ),
                ],
                const SizedBox(height: 14),
                Text('What\'s New',
                    style: AppTextStyles.subtitle.copyWith(color: AppColors.ink)),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 280),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _palette.line),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      notes.isEmpty
                          ? 'No detailed release notes were provided for this version.'
                          : notes,
                      style:
                          AppTextStyles.bodySm.copyWith(color: AppColors.ink),
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
                          foregroundColor: _palette.dark,
                          side: BorderSide(color: _palette.dark.withAlpha(80)),
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
                            : () => _downloadAndOpenFile(assetUrl, assetName),
                        icon: const Icon(Icons.download_rounded,
                            size: 16, color: Colors.white),
                        label: Text(
                          assetName.isNotEmpty
                              ? 'Download & Open APK'
                              : 'Download',
                          style: const TextStyle(color: Colors.white),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _palette.dark,
                          disabledBackgroundColor:
                              AppColors.disabledText.withAlpha(70),
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
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [InstituteTheme.resolve(_role, _institute)],
      ),
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppTopBar(
          title: 'Notifications',
          subtitle: _isInstituteAdmin
              ? '$_unreadCount unread · $_instituteCode only'
              : '$_unreadCount unread',
          variant: AppTopBarVariant.small,
          showBackButton: true,
          showInstituteLine: _isInstituteAdmin,
          actions: [
            AppTopBarAction(
              icon: Icons.done_all,
              tooltip: 'Mark all read',
              onTap: _markAllRead,
            ),
            AppTopBarAction(
              icon: Icons.delete_sweep_outlined,
              tooltip: 'Clear all',
              onTap: _clearAll,
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: _errorText != null
              ? _buildError()
              : ScreenSkeleton(
                  isLoading: _loading,
                  child: Builder(builder: (context) {
                    final usingPlaceholder =
                        _notifications.isEmpty && _loading;
                    final source = usingPlaceholder
                        ? placeholderNotificationList()
                        : null;
                    final displayNotifications = _visibleForRole(source);
                    return displayNotifications.isEmpty
                        ? _buildEmpty()
                        : _buildList(source);
                  }),
                ),
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.notifications_none, size: 48, color: AppColors.inkMuted),
            const SizedBox(height: 16),
            Text('No notifications',
                style:
                    AppTextStyles.subtitle.copyWith(color: AppColors.ink)),
            const SizedBox(height: 6),
            Text(
                'Alerts for high consumption\nand offline devices will appear here.',
                style: AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted),
                textAlign: TextAlign.center),
          ],
        ),
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
            const Icon(Icons.lock_outline, size: 44, color: AppColors.inkMuted),
            const SizedBox(height: 16),
            Text('Cannot load notifications',
                style:
                    AppTextStyles.subtitle.copyWith(color: AppColors.ink)),
            const SizedBox(height: 8),
            Text(_errorText ?? 'Something went wrong.',
                textAlign: TextAlign.center,
                style:
                    AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
          ],
        ),
      ),
    );
  }

  Widget _buildList([List<Map<String, dynamic>>? source]) {
    final filtered = _filtered(source);
    final today = <Map<String, dynamic>>[];
    final yesterday = <Map<String, dynamic>>[];
    final earlier = <Map<String, dynamic>>[];
    final now = DateTime.now();
    final todayDate = DateTime(now.year, now.month, now.day);
    final yesterdayDate = todayDate.subtract(const Duration(days: 1));

    for (final n in filtered) {
      final dt =
          DateTime.fromMillisecondsSinceEpoch(_notificationTimestamp(n['timestamp']));
      final d = DateTime(dt.year, dt.month, dt.day);
      if (d == todayDate) {
        today.add(n);
      } else if (d == yesterdayDate) {
        yesterday.add(n);
      } else {
        earlier.add(n);
      }
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              AppFilterChip(
                label: 'All',
                selected: _filter == _NotifFilter.all,
                onTap: () => setState(() => _filter = _NotifFilter.all),
              ),
              AppFilterChip(
                label:
                    'Alerts ${_visibleForRole(source).where((n) => _categoryOf(n) == _NotifFilter.alerts).length}',
                selected: _filter == _NotifFilter.alerts,
                onTap: () => setState(() => _filter = _NotifFilter.alerts),
              ),
              AppFilterChip(
                label: 'Rate',
                selected: _filter == _NotifFilter.rate,
                onTap: () => setState(() => _filter = _NotifFilter.rate),
              ),
              AppFilterChip(
                label: 'Updates',
                selected: _filter == _NotifFilter.updates,
                onTap: () => setState(() => _filter = _NotifFilter.updates),
              ),
            ],
          ),
        ),
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: Text('Nothing in this filter.',
                  style:
                      AppTextStyles.bodySm.copyWith(color: AppColors.inkMuted)),
            ),
          ),
        if (today.isNotEmpty) ..._buildGroup('Today', today),
        if (yesterday.isNotEmpty) ..._buildGroup('Yesterday', yesterday),
        if (earlier.isNotEmpty) ..._buildGroup('Earlier', earlier),
      ],
    );
  }

  List<Widget> _buildGroup(String label, List<Map<String, dynamic>> items) {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(label,
            style: AppTextStyles.label.copyWith(color: AppColors.ink)),
      ),
      for (final n in items)
        DeleteRowTransition(
          key: ValueKey(n['id']),
          deleting: _clearingIds.contains(n['id']),
          message: 'Notification cleared',
          child: _buildNotifRow(n),
        ),
    ];
  }

  Widget _buildNotifRow(Map<String, dynamic> notif) {
    final type = notif['type'] as String? ?? '';
    final message = notif['message'] as String? ?? '';
    final building = notif['building'] as String? ?? '';
    final deviceId = notif['deviceId'] as String? ?? '';
    final latestVersion = notif['version'] as String? ?? '';
    final currentVersion = notif['currentVersion'] as String? ?? '';
    final timestamp = notif['timestamp'];
    final isHigh = type == 'high_consumption';
    final isUpdate = type == 'app_update';
    final isRateChange = type == 'rate_change' || type == 'rate_change_manual';
    final unread = _isUnread(notif);

    late final IconData icon;
    late final Color iconColor;
    late final Color iconBg;
    late final Color iconBorder;
    String title;
    if (isRateChange) {
      icon = Icons.receipt_long;
      iconColor = AppColors.successText;
      iconBg = Colors.white;
      iconBorder = AppColors.success.withAlpha(60);
      title = 'Rate updated';
    } else if (isUpdate) {
      icon = Icons.system_update_alt_outlined;
      iconColor = AppColors.successText;
      iconBg = Colors.white;
      iconBorder = AppColors.success.withAlpha(60);
      title = 'Update ready';
    } else if (isHigh) {
      icon = Icons.local_fire_department_outlined;
      iconColor = AppColors.warningText;
      iconBg = Colors.white;
      iconBorder = AppColors.warning.withAlpha(120);
      title = 'High usage';
    } else {
      icon = Icons.wifi_off;
      iconColor = AppColors.errorText;
      iconBg = Colors.white;
      iconBorder = AppColors.error.withAlpha(120);
      title = 'Device offline';
    }

    final dt = DateTime.fromMillisecondsSinceEpoch(_notificationTimestamp(timestamp));
    final timeStr =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

    String fallbackMessage;
    if (isUpdate) {
      final from = currentVersion.isEmpty ? 'current' : currentVersion;
      final to = latestVersion.isEmpty ? 'latest' : latestVersion;
      fallbackMessage = 'Version $from -> $to';
    } else if (isRateChange) {
      fallbackMessage = message;
    } else {
      fallbackMessage = '$building · $deviceId';
    }
    final displayMessage = message.isNotEmpty ? message : fallbackMessage;

    VoidCallback? onTap;
    if (isUpdate) {
      onTap = () => _showUpdateDetails(notif);
    } else if (isRateChange) {
      onTap = _openSettings;
    } else if (isHigh && building.isNotEmpty) {
      onTap = () => _openBuilding(building);
    } else if (!isHigh && !isUpdate && !isRateChange && deviceId.isNotEmpty) {
      onTap = () => _openDevice(deviceId);
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: _palette.line)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: iconBorder, width: 1),
                ),
                child: Icon(icon, size: 20, color: iconColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(title,
                              style: AppTextStyles.subtitle
                                  .copyWith(color: AppColors.ink)),
                        ),
                        if (unread) ...[
                          const SizedBox(width: 6),
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: _palette.dark,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(displayMessage,
                        style: AppTextStyles.bodySm
                            .copyWith(color: AppColors.inkMid)),
                    const SizedBox(height: 4),
                    Text(timeStr,
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.inkMuted)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
