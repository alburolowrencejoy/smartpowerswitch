import 'package:flutter/material.dart';

class EnergyItem {
  final String deviceId;
  final String building;
  final String room;
  final double kwh;
  final double cost;
  final double voltage;
  final List<double> kwhHistory; // Sparkline data
  final bool isOnline;

  const EnergyItem({
    required this.deviceId,
    required this.building,
    required this.room,
    required this.kwh,
    required this.cost,
    required this.voltage,
    required this.kwhHistory,
    required this.isOnline,
  });
}

class EnergyListWidget extends StatelessWidget {
  final List<EnergyItem> devices;
  final VoidCallback? onDeviceTap;

  const EnergyListWidget({
    super.key,
    required this.devices,
    this.onDeviceTap,
  });

  @override
  Widget build(BuildContext context) {
    if (devices.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Padding(
          padding: EdgeInsets.all(24.0),
          child: Center(
            child: Text(
              'No devices found',
              style: TextStyle(
                color: Color(0xFF999999),
                fontSize: 14,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < devices.length; i++) ...[
            GestureDetector(
              onTap: onDeviceTap,
              child: EnergyRow(device: devices[i]),
            ),
            if (i < devices.length - 1)
              const Divider(
                color: Color(0xFFEEEEEE),
                height: 1,
                indent: 16,
                endIndent: 16,
              ),
          ],
        ],
      ),
    );
  }
}

class EnergyRow extends StatelessWidget {
  final EnergyItem device;

  const EnergyRow({super.key, required this.device});

  @override
  Widget build(BuildContext context) {
    final changeColor = device.isOnline
        ? const Color(0xFF66BB6A) // Green - Online
        : const Color(0xFFEF5350); // Red - Offline

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          // Device ID + Location
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device.deviceId,
                  style: const TextStyle(
                    color: Color(0xFF1B5E20),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${device.building} • ${device.room}',
                  style: const TextStyle(
                    color: Color(0xFF999999),
                    fontSize: 12,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),

          // Sparkline (kWh history trend)
          Expanded(
            flex: 3,
            child: SizedBox(
              height: 36,
              child: CustomPaint(
                painter: SparklinePainter(
                  data: device.kwhHistory,
                  color: const Color(0xFF66BB6A),
                ),
              ),
            ),
          ),

          // kWh + Cost
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      device.kwh.toStringAsFixed(3),
                      style: const TextStyle(
                        color: Color(0xFF1B5E20),
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 2),
                    const Text(
                      'kWh',
                      style: TextStyle(
                        color: Color(0xFF999999),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      '₱${device.cost.toStringAsFixed(2)}',
                      style: TextStyle(
                        color: changeColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      device.isOnline ? '🟢' : '🔴',
                      style: const TextStyle(fontSize: 10),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SparklinePainter extends CustomPainter {
  final List<double> data;
  final Color color;

  SparklinePainter({required this.data, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty || data.length < 2) return;

    final double minVal = data.reduce((a, b) => a < b ? a : b);
    final double maxVal = data.reduce((a, b) => a > b ? a : b);
    final double range = (maxVal - minVal).abs();
    final double safeRange = range == 0 ? 1 : range;

    // Draw background fill with gradient
    final fillPaint = Paint()
      ..color = color.withValues(alpha: 0.1)
      ..style = PaintingStyle.fill;

    // Draw line
    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final linePath = Path();
    final fillPath = Path();

    for (int i = 0; i < data.length; i++) {
      final double x = (i / (data.length - 1)) * size.width;
      final double y = size.height - ((data[i] - minVal) / safeRange) * size.height;

      if (i == 0) {
        linePath.moveTo(x, y);
        fillPath.moveTo(x, y);
      } else {
        linePath.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }

    // Complete fill path with bottom edge
    fillPath.lineTo(size.width, size.height);
    fillPath.lineTo(0, size.height);
    fillPath.close();

    // Draw fill
    canvas.drawPath(fillPath, fillPaint);

    // Draw line
    canvas.drawPath(linePath, linePaint);

    // Draw end point circle
    final lastData = data.last;
    final lastX = size.width;
    final lastY = size.height - ((lastData - minVal) / safeRange) * size.height;

    final circlePaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    canvas.drawCircle(Offset(lastX, lastY), 2.5, circlePaint);
  }

  @override
  bool shouldRepaint(covariant SparklinePainter oldDelegate) =>
      oldDelegate.data != data || oldDelegate.color != color;
}

/// Helper to create sample device data for testing
EnergyItem createSampleDevice({
  String deviceId = 'ESP32-ROOM101-001',
  String building = 'GYM',
  String room = 'Room 1 (TEST)',
  double kwh = 0.065,
  double cost = 0.747,
  double voltage = 220.5,
  bool isOnline = true,
}) {
  // Generate sample sparkline data (simulating kWh history)
  final sparklineData = [
    0.010,
    0.015,
    0.020,
    0.035,
    0.050,
    0.058,
    0.062,
    0.065,
  ];

  return EnergyItem(
    deviceId: deviceId,
    building: building,
    room: room,
    kwh: kwh,
    cost: cost,
    voltage: voltage,
    kwhHistory: sparklineData,
    isOnline: isOnline,
  );
}
