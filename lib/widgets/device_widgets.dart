import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ENERGY DISPLAY CARD - Shows kWh, cost, voltage, current, power, power factor
// ─────────────────────────────────────────────────────────────────────────────

class EnergyDisplayCard extends StatelessWidget {
  final double kwh;
  final double cost;
  final double voltage;
  final double current;
  final double power;
  final double powerFactor;
  final bool isOnline;
  final String deviceName;

  const EnergyDisplayCard({
    super.key,
    required this.kwh,
    required this.cost,
    required this.voltage,
    required this.current,
    required this.power,
    required this.powerFactor,
    required this.isOnline,
    required this.deviceName,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isOnline
              ? [const Color(0xFF1E88E5), const Color(0xFF1565C0)]
              : [const Color(0xFF757575), const Color(0xFF424242)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with device name and status
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                deviceName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isOnline
                      ? const Color(0xFF4CAF50)
                      : const Color(0xFFFF6B6B),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  isOnline ? 'Online' : 'Offline',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Main metrics grid
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            children: [
              _MetricTile(
                label: 'Energy',
                value: kwh.toString(),
                unit: 'kWh',
                icon: Icons.bolt,
              ),
              _MetricTile(
                label: 'Cost',
                value: '₱${cost.toStringAsFixed(2)}',
                unit: 'PHP',
                icon: Icons.currency_pound,
              ),
              _MetricTile(
                label: 'Voltage',
                value: voltage.toStringAsFixed(1),
                unit: 'V',
                icon: Icons.electric_bolt,
              ),
              _MetricTile(
                label: 'Current',
                value: current.toStringAsFixed(2),
                unit: 'A',
                icon: Icons.waves,
              ),
              _MetricTile(
                label: 'Power',
                value: power.toStringAsFixed(1),
                unit: 'W',
                icon: Icons.flash_on,
              ),
              _MetricTile(
                label: 'Power Factor',
                value: powerFactor.toStringAsFixed(2),
                unit: 'pf',
                icon: Icons.trending_up,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final IconData icon;

  const _MetricTile({
    required this.label,
    required this.value,
    required this.unit,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 2),
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                TextSpan(
                  text: ' $unit',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// VOLTAGE ALERT WIDGET - Shows voltage status with brownout/surge alerts
// ─────────────────────────────────────────────────────────────────────────────

enum VoltageAlertType { normal, underVoltage, overVoltage }

class VoltageAlertWidget extends StatelessWidget {
  final double voltage;
  final bool showAlert;

  // Voltage thresholds (from calibration)
  static const double underVoltageThreshold = 207.0; // Brownout
  static const double overVoltageThreshold = 253.0; // Surge
  static const double normalMin = 207.0;
  static const double normalMax = 253.0;

  const VoltageAlertWidget({
    super.key,
    required this.voltage,
    this.showAlert = true,
  });

  VoltageAlertType get alertType {
    if (voltage < underVoltageThreshold) {
      return VoltageAlertType.underVoltage;
    } else if (voltage > overVoltageThreshold) {
      return VoltageAlertType.overVoltage;
    }
    return VoltageAlertType.normal;
  }

  bool get hasAlert => alertType != VoltageAlertType.normal;

  String get _title {
    switch (alertType) {
      case VoltageAlertType.underVoltage:
        return 'Low Voltage Alert';
      case VoltageAlertType.overVoltage:
        return 'High Voltage Alert';
      case VoltageAlertType.normal:
        return 'Voltage Normal';
    }
  }

  String get _message {
    switch (alertType) {
      case VoltageAlertType.underVoltage:
        return 'Brownout detected! Voltage dropped below ${underVoltageThreshold}V. This may damage devices.';
      case VoltageAlertType.overVoltage:
        return 'Surge detected! Voltage exceeded ${overVoltageThreshold}V. Turn off critical devices.';
      case VoltageAlertType.normal:
        return 'Voltage is within safe operating range (${normalMin}V - ${normalMax}V)';
    }
  }

  Color get _backgroundColor {
    switch (alertType) {
      case VoltageAlertType.underVoltage:
        return const Color(0xFFFFEBEE); // Light red
      case VoltageAlertType.overVoltage:
        return const Color(0xFFFFEBEE); // Light red
      case VoltageAlertType.normal:
        return const Color(0xFFE8F5E9); // Light green
    }
  }

  Color get _borderColor {
    switch (alertType) {
      case VoltageAlertType.underVoltage:
        return const Color(0xFFD64A4A); // Dark red
      case VoltageAlertType.overVoltage:
        return const Color(0xFFD64A4A); // Dark red
      case VoltageAlertType.normal:
        return const Color(0xFF4CAF50); // Green
    }
  }

  Color get _textColor {
    switch (alertType) {
      case VoltageAlertType.underVoltage:
        return const Color(0xFFB42318); // Dark red
      case VoltageAlertType.overVoltage:
        return const Color(0xFFB42318); // Dark red
      case VoltageAlertType.normal:
        return const Color(0xFF2E7D32); // Dark green
    }
  }

  IconData get _icon {
    switch (alertType) {
      case VoltageAlertType.underVoltage:
        return Icons.warning_rounded;
      case VoltageAlertType.overVoltage:
        return Icons.warning_rounded;
      case VoltageAlertType.normal:
        return Icons.check_circle_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!showAlert && alertType == VoltageAlertType.normal) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _backgroundColor,
        border: Border.all(color: _borderColor, width: 1.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            _icon,
            color: _textColor,
            size: 24,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _title,
                  style: TextStyle(
                    color: _textColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _message,
                  style: TextStyle(
                    color: _textColor.withValues(alpha: 0.8),
                    fontSize: 12,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            children: [
              Text(
                '${voltage.toStringAsFixed(1)}V',
                style: TextStyle(
                  color: _textColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                _getPercentageBar(),
                style: TextStyle(
                  color: _textColor.withValues(alpha: 0.6),
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _getPercentageBar() {
    // Show visual indicator of voltage level
    if (voltage < underVoltageThreshold) {
      return '◀ Low';
    } else if (voltage > overVoltageThreshold) {
      return 'High ▶';
    }
    final percentage =
        ((voltage - normalMin) / (normalMax - normalMin) * 100).toInt();
    return '$percentage%';
  }
}

/// Compact version for use in lists or cards
class CompactVoltageAlert extends StatelessWidget {
  final double voltage;

  const CompactVoltageAlert({
    super.key,
    required this.voltage,
  });

  @override
  Widget build(BuildContext context) {
    final isNormal = voltage >= VoltageAlertWidget.underVoltageThreshold &&
        voltage <= VoltageAlertWidget.overVoltageThreshold;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isNormal
            ? const Color(0xFFE8F5E9)
            : const Color(0xFFFFEBEE),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isNormal
              ? const Color(0xFF4CAF50)
              : const Color(0xFFD64A4A),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isNormal ? Icons.check_circle : Icons.warning_rounded,
            size: 14,
            color: isNormal
                ? const Color(0xFF2E7D32)
                : const Color(0xFFB42318),
          ),
          const SizedBox(width: 4),
          Text(
            '${voltage.toStringAsFixed(1)}V',
            style: TextStyle(
              color: isNormal
                  ? const Color(0xFF2E7D32)
                  : const Color(0xFFB42318),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
