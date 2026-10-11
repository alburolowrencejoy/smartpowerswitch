import 'dart:async';
import 'dart:math';

/// Commands to a board (master plan Phase 5): what the app asks for, kept
/// apart from what the board reports, so a telemetry push can never
/// overwrite a command (the old shared `devices/{id}/relay` field could).
///
///   device_commands/{id}: { desiredRelay, commandId, issuedAt, issuedBy,
///                           wifiReset? }       written by the app/schedulers
///   device_live/{id}/state: { reportedRelay, lastCommandId, lastCommandAt }
///                                              written by the board (fw v2)
///
/// Transition (until every board runs firmware v2): each command also
/// writes the old field (`devices/{id}/relay` / `wifiReset`) in the same
/// atomic update, so boards on the old firmware keep obeying. One writer,
/// two paths, so they can't disagree. Remove the old field once all boards
/// are flashed (Phase 5c).
class DeviceCommands {
  DeviceCommands._();

  static final Random _random = Random();

  /// Unique, roughly time-ordered command ID.
  static String newCommandId([DateTime? now]) =>
      '${(now ?? DateTime.now()).millisecondsSinceEpoch}-'
      '${_random.nextInt(1 << 30).toRadixString(36)}';

  /// Multi-path update asking [id] to switch its relay [on].
  /// [issuedAt] is normally `ServerValue.timestamp`.
  static Map<String, Object?> relayUpdate(
    String id,
    bool on, {
    required String issuedBy,
    required Object issuedAt,
    String? commandId,
  }) =>
      {
        'device_commands/$id/desiredRelay': on,
        'device_commands/$id/commandId': commandId ?? newCommandId(),
        'device_commands/$id/issuedAt': issuedAt,
        'device_commands/$id/issuedBy': issuedBy,
        // Old firmware reads this field (transition, see class doc).
        'devices/$id/relay': on,
      };

  /// How long a screen waits for the database to accept a command. Long
  /// enough for a slow phone connection: giving up early made the switch
  /// bounce back while the queued write still reached the board.
  static const sendTimeout = Duration(seconds: 15);

  /// A short message for a command that couldn't be sent.
  static String failureMessage(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('permission') || text.contains('denied')) {
      return "You don't have permission to control this device.";
    }
    if (error is TimeoutException) {
      return 'No response from the server. Check your connection and '
          'try again.';
    }
    return "Couldn't send the command. Try again.";
  }

  /// Multi-path update asking [id] to forget its Wi-Fi ([reset] = true), or
  /// cancelling that request.
  static Map<String, Object?> wifiResetUpdate(String id, bool reset) => {
        'device_commands/$id/wifiReset': reset ? true : null,
        'devices/$id/wifiReset': reset ? true : null,
      };

  /// Whether the board has confirmed the latest command.
  ///
  /// [command] is `device_commands/{id}`, [liveState] is
  /// `device_live/{id}/state`. A board on the old firmware has no
  /// `device_live` record, so its commands are [CommandStatus.unconfirmed]
  /// (it can't acknowledge), not failed.
  static CommandStatus statusOf(
    Object? command,
    Object? liveState, {
    required DateTime now,
    Duration timeout = const Duration(seconds: 30),
  }) {
    if (command is! Map || command['commandId'] == null) {
      return CommandStatus.none;
    }
    if (liveState is! Map) return CommandStatus.unconfirmed;
    final commandId = '${command['commandId']}';
    if ('${liveState['lastCommandId']}' == commandId) {
      return liveState['reportedRelay'] == command['desiredRelay']
          ? CommandStatus.acknowledged
          : CommandStatus.failed; // seen, but the relay didn't follow
    }
    final issuedAt = command['issuedAt'];
    if (issuedAt is num &&
        now.difference(DateTime.fromMillisecondsSinceEpoch(issuedAt.toInt())) >
            timeout) {
      return CommandStatus.failed; // never acknowledged
    }
    return CommandStatus.pending;
  }
}

enum CommandStatus {
  /// No command has been sent.
  none,

  /// Sent; the board hasn't confirmed it yet.
  pending,

  /// The board confirmed it and its relay matches.
  acknowledged,

  /// Not confirmed in time, or confirmed but the relay didn't follow.
  failed,

  /// The board runs the old firmware, which can't confirm commands.
  unconfirmed,
}
