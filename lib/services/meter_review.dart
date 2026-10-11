import 'package:firebase_database/firebase_database.dart';

/// A device whose energy counting the server has paused
/// (`meterState/{id}/flag`, written by the `rollupEnergy` function): its
/// meter jumped or dropped by more than is physically possible, so nothing
/// is counted until an admin reviews it.
class MeterReview {
  const MeterReview({
    required this.reason,
    required this.at,
    this.observedKwh,
    this.answered = false,
  });

  /// 'spike' (meter jumped) or 'decrease' (meter dropped).
  final String reason;
  final int at;
  final double? observedKwh;

  /// An admin has answered; the server applies it on the board's next
  /// meter reading.
  final bool answered;

  bool get isSpike => reason == 'spike';

  /// The review a `meterState/{id}` value needs, or null when counting
  /// isn't paused.
  static MeterReview? parse(Object? raw) {
    if (raw is! Map) return null;
    final flag = raw['flag'];
    if (flag is! Map || flag['frozen'] != true) return null;
    final at = flag['at'];
    final kwh = flag['observedKwh'];
    return MeterReview(
      reason: '${flag['reason'] ?? ''}',
      at: at is num ? at.toInt() : 0,
      observedKwh: kwh is num ? kwh.toDouble() : null,
      answered: raw['resolve'] != null,
    );
  }

  static DatabaseReference ref(String deviceId) =>
      FirebaseDatabase.instance.ref('meterState/$deviceId');

  /// Records an admin's answer; the next server run (within a minute)
  /// applies it. 'accept' counts the reading ('accept' on a drop means the
  /// meter was reset); 'rebaseline' starts counting over from it.
  static Future<void> resolve(String deviceId, {required bool accept}) =>
      ref(deviceId).child('resolve').set(accept ? 'accept' : 'rebaseline');
}
