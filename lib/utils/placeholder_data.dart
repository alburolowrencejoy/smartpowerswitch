/// Realistically-shaped fake data used only while a screen's skeleton
/// shimmer is showing (see [ScreenSkeleton]). This app has no dedicated
/// model classes for buildings/devices/history/etc. -- every screen passes
/// raw `Map<String, dynamic>` around -- so placeholders are plain map
/// builders instead of model factories, matching the rest of the codebase.
library;

/// A single fake building, shaped like a `buildings/{code}` entry.
Map<String, dynamic> placeholderBuilding({String code = 'BLDG'}) => {
      'code': code,
      'name': 'Loading Building',
      'floors': 3,
    };

List<Map<String, dynamic>> placeholderBuildingList([int count = 4]) =>
    List.generate(
      count,
      (i) => placeholderBuilding(code: 'B${i + 1}'),
    );

/// A single fake device, shaped like a `devices/{id}` / `master_devices/{id}`
/// entry (superset of fields read across dashboard, building floor, and
/// device detail screens).
Map<String, dynamic> placeholderDevice({String id = 'device-0000'}) => {
      'device_id': id,
      'utility': 'Electricity',
      'building': 'B1',
      'room': 'Room 101',
      'floor': 1,
      'relay': false,
      'power': 120.0,
      'kwh': 4.2,
      'assignedTo': 'B1/1',
      'last_seen': DateTime.now().millisecondsSinceEpoch,
    };

List<Map<String, dynamic>> placeholderDeviceList([int count = 6]) =>
    List.generate(
      count,
      (i) => placeholderDevice(id: 'device-${1000 + i}'),
    );

/// A single fake analytics entry, shaped like the daily/weekly/monthly/
/// yearly history rows used for charts and totals (`{'label','kwh','cost'}`).
Map<String, dynamic> placeholderHistoryEntry({String label = '2026-01-01'}) => {
      'label': label,
      'kwh': 12.5,
      'cost': 143.75,
    };

List<Map<String, dynamic>> placeholderHistoryList([int count = 7]) =>
    List.generate(
      count,
      (i) => placeholderHistoryEntry(label: '2026-01-0${i + 1}'),
    );

/// A single fake notification, shaped like a `notifications/{id}` entry.
Map<String, dynamic> placeholderNotification({String id = 'notif-0'}) => {
      'id': id,
      'type': 'alert',
      'message': 'Loading notification message text',
      'building': 'B1',
      'deviceId': 'device-1000',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

List<Map<String, dynamic>> placeholderNotificationList([int count = 5]) =>
    List.generate(
      count,
      (i) => placeholderNotification(id: 'notif-$i'),
    );

/// A single fake managed-user row, shaped like a `users/{uid}` entry.
Map<String, dynamic> placeholderUser({String uid = 'uid-0000'}) => {
      'uid': uid,
      'name': 'Loading User',
      'email': 'loading.user@example.com',
      'role': 'faculty',
      'institute': 'CCS',
    };

List<Map<String, dynamic>> placeholderUserList([int count = 5]) =>
    List.generate(
      count,
      (i) => placeholderUser(uid: 'uid-000$i'),
    );
