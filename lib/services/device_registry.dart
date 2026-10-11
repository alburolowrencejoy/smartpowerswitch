/// The one device list (master plan Phase 4).
///
/// `master_devices/{id}` is the registry: which devices exist and where they
/// are (`assignedTo` = "BUILDING/floor/Room", "" when unassigned), plus their
/// `name` and `utility`. `devices/{id}` holds only what the board reports
/// (live readings, relay, last_seen) -- screens join it by ID and never count
/// or list devices from it.
///
/// During the transition `devices/{id}` also keeps a copy of building / floor
/// / room / utility, because the ESP32 firmware and the security rules still
/// read it there. It is written only by [assignmentUpdate] /
/// [unassignmentUpdate], in the same atomic update as the registry, so the
/// two can't disagree. The old third copy under
/// `buildings/{B}/floorData/{n}/devices` is no longer written or read.
class RegisteredDevice {
  final String id;
  final String name;
  final String utility;
  final String source;

  /// Upper-case building code, or '' when unassigned.
  final String building;

  /// Floor number, or 0 when unassigned.
  final int floor;

  /// Room name, or '' when unassigned.
  final String room;

  /// `devices/{id}` (live readings), or empty when the board never reported.
  final Map<String, dynamic> live;

  const RegisteredDevice({
    required this.id,
    required this.name,
    required this.utility,
    required this.source,
    required this.building,
    required this.floor,
    required this.room,
    required this.live,
  });

  bool get isAssigned => building.isNotEmpty;
  bool get isRealIot => source == 'real_iot';

  /// Name to show: the given name, else the device ID.
  String get displayName => name.isNotEmpty ? name : id;

  /// `assignedTo` value for this device ("BUILDING/floor/Room" or "").
  String get assignedTo =>
      isAssigned ? DeviceRegistry.assignedToValue(building, floor, room) : '';
}

/// Building / floor / room parsed from an `assignedTo` string.
typedef DeviceAssignment = ({String building, int floor, String room});

class DeviceRegistry {
  DeviceRegistry._();

  /// Parses "IC/1/Room 101" (room names may contain '/'). Unassigned or
  /// malformed values give an empty building.
  static DeviceAssignment parseAssignedTo(Object? raw) {
    final parts = (raw ?? '').toString().split('/');
    final building = parts.first.trim().toUpperCase();
    if (building.isEmpty || parts.length < 3) {
      return (building: '', floor: 0, room: '');
    }
    return (
      building: building,
      floor: int.tryParse(parts[1].trim()) ?? 0,
      room: parts.sublist(2).join('/').trim(),
    );
  }

  static String assignedToValue(String building, int floor, String room) =>
      '${building.trim().toUpperCase()}/$floor/${room.trim()}';

  /// Every registered device (from `master_devices`), joined with its live
  /// readings from `devices` by ID, sorted by ID. Entries that exist only in
  /// `devices` are not devices of this system and are ignored.
  static List<RegisteredDevice> parse(Object? masterRaw, Object? liveRaw) {
    if (masterRaw is! Map) return const [];
    final out = <RegisteredDevice>[];
    masterRaw.forEach((key, value) {
      if (value is! Map) return;
      final id = key.toString();
      final liveVal = liveRaw is Map ? liveRaw[id] : null;
      final live = liveVal is Map
          ? Map<String, dynamic>.from(liveVal)
          : <String, dynamic>{};
      final a = parseAssignedTo(value['assignedTo']);
      // Name and utility move into the registry; until a device has been
      // re-saved, fall back to the copy on its live record.
      String pick(String field) {
        final own = (value[field] ?? '').toString().trim();
        if (own.isNotEmpty && own != 'Unassigned') return own;
        return (live[field] ?? own).toString().trim();
      }

      out.add(RegisteredDevice(
        id: id,
        name: pick('name'),
        utility: pick('utility'),
        source: (value['source'] ?? '').toString(),
        building: a.building,
        floor: a.floor,
        room: a.room,
        live: live,
      ));
    });
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  /// Whether [id] is in the registry snapshot [masterRaw]. Screens that walk
  /// `devices` (live readings) use this so a stray entry there is never
  /// counted as a device.
  static bool isRegistered(Object? masterRaw, Object? id) =>
      masterRaw is Map && masterRaw['$id'] is Map;

  /// Devices assigned to one building (and floor / room when given).
  static List<RegisteredDevice> inPlace(List<RegisteredDevice> all,
      {required String building, int? floor, String? room}) {
    final code = building.trim().toUpperCase();
    return [
      for (final d in all)
        if (d.building == code &&
            (floor == null || d.floor == floor) &&
            (room == null || d.room == room))
          d,
    ];
  }

  /// Multi-path update assigning [id] to a room. Never touches the board's
  /// live readings (`kwh` etc.): resetting them would look like a meter drop
  /// to the energy rollup and freeze the device's history.
  static Map<String, Object?> assignmentUpdate({
    required String id,
    required String building,
    required int floor,
    required String room,
    required String utility,
    String? name,
    Object? updatedAt,
  }) {
    final code = building.trim().toUpperCase();
    return {
      'master_devices/$id/assignedTo': assignedToValue(code, floor, room),
      'master_devices/$id/utility': utility,
      if (name != null) 'master_devices/$id/name': name.trim(),
      if (updatedAt != null) 'master_devices/$id/updatedAt': updatedAt,
      // Transition copy for the firmware and the rules (see class doc).
      'devices/$id/building': code,
      'devices/$id/floor': '$floor',
      'devices/$id/room': room.trim(),
      'devices/$id/utility': utility,
    };
  }

  /// Multi-path update removing [id] from its room (it stays registered).
  static Map<String, Object?> unassignmentUpdate(String id) => {
        'master_devices/$id/assignedTo': '',
        'devices/$id/building': '',
        'devices/$id/floor': '',
        'devices/$id/room': '',
      };

  /// Multi-path update renaming [id].
  static Map<String, Object?> renameUpdate(String id, String name) => {
        'master_devices/$id/name': name.trim(),
      };
}
