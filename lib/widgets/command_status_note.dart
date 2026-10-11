import 'package:flutter/material.dart';

import '../services/device_commands.dart';

/// One line under a device's ON/OFF control saying whether the board has
/// confirmed the last command (see [DeviceCommands.statusOf]). Hidden when
/// there's nothing to say: no command, confirmed, or a board on the old
/// firmware (which can't confirm).
class CommandStatusNote extends StatelessWidget {
  const CommandStatusNote({
    super.key,
    required this.status,
    this.padding = const EdgeInsets.only(top: 8),
  });

  final CommandStatus status;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final (String text, Color color, IconData icon) = switch (status) {
      CommandStatus.pending => (
          'Waiting for the device to confirm…',
          const Color(0xFF4A5A66),
          Icons.hourglass_top_rounded,
        ),
      CommandStatus.failed => (
          'The device didn\'t confirm the last command. Check it\'s online '
              'and try again.',
          const Color(0xFFA83434),
          Icons.error_outline_rounded,
        ),
      _ => ('', Colors.transparent, Icons.circle),
    };
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: padding,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(text,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: color)),
        ),
      ]),
    );
  }
}
