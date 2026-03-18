import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../theme/app_colors.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<Map<String, dynamic>> _notifications = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _listenToNotifications();
  }

  void _listenToNotifications() {
    FirebaseDatabase.instance
        .ref('notifications')
        .orderByChild('timestamp')
        .limitToLast(50)
        .onValue
        .listen((event) {
      if (!mounted) return;
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data == null) {
        setState(() { _notifications = []; _loading = false; });
        return;
      }
      final list = data.entries.map((e) {
        final val = Map<String, dynamic>.from(e.value as Map);
        val['id'] = e.key;
        return val;
      }).toList();
      list.sort((a, b) => (b['timestamp'] as int).compareTo(a['timestamp'] as int));
      setState(() { _notifications = list; _loading = false; });
    });
  }

  Future<void> _clearAll() async {
    await FirebaseDatabase.instance.ref('notifications').remove();
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
                  ? const Center(child: CircularProgressIndicator(color: AppColors.greenMid))
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
          bottomLeft: Radius.circular(28), bottomRight: Radius.circular(28),
        ),
      ),
      child: Row(children: [
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(38),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 16),
          ),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Text('Notifications',
              style: TextStyle(fontFamily: 'Outfit', fontSize: 18,
                  fontWeight: FontWeight.w700, color: Colors.white)),
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
            width: 72, height: 72,
            decoration: BoxDecoration(
              color: AppColors.greenPale,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(Icons.notifications_none, size: 36, color: AppColors.greenMid),
          ),
          const SizedBox(height: 16),
          const Text('No notifications',
              style: TextStyle(fontFamily: 'Outfit', fontSize: 16,
                  fontWeight: FontWeight.w600, color: AppColors.textDark)),
          const SizedBox(height: 6),
          const Text('Alerts for high consumption\nand offline devices will appear here.',
              style: TextStyle(fontSize: 13, color: AppColors.textMuted),
              textAlign: TextAlign.center),
        ],
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
    final type      = notif['type']     as String? ?? '';
    final message   = notif['message']  as String? ?? '';
    final building  = notif['building'] as String? ?? '';
    final deviceId  = notif['deviceId'] as String? ?? '';
    final timestamp = notif['timestamp'] as int? ?? 0;
    final isHigh    = type == 'high_consumption';

    final color = isHigh ? AppColors.warning : AppColors.error;
    final icon  = isHigh ? Icons.warning_amber_outlined : Icons.wifi_off;
    final dt    = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final timeStr = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}  ${dt.day}/${dt.month}/${dt.year}';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withAlpha(51)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: color.withAlpha(26),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 20, color: color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(message, style: const TextStyle(fontSize: 13,
                fontWeight: FontWeight.w600, color: AppColors.textDark)),
            const SizedBox(height: 4),
            Text('$building · $deviceId',
                style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
            const SizedBox(height: 2),
            Text(timeStr, style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
          ]),
        ),
      ]),
    );
  }
}
