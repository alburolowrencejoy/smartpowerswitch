import 'package:flutter/material.dart';
import '../../theme/institute_colors.dart';
import '../../widgets/responsive_center.dart';
import 'room_devices_panel.dart';
import '../../theme/app_fonts.dart';

/// Thin pushed screen for a single room's devices, composed from
/// [RoomDevicesPanel]. Used by the institute-admin room-tap path (see
/// `BuildingFloorScreen._buildRoomCard`'s onTap when `showBackButton` is
/// false) instead of `BuildingFloorScreen`'s in-place room swap -- it never
/// renders floor tabs because it never composes them in the first place.
class RoomDevicesScreen extends StatelessWidget {
  final String buildingCode;
  final String buildingName;
  final int floor;
  final String room;
  final String role;

  const RoomDevicesScreen({
    super.key,
    required this.buildingCode,
    required this.buildingName,
    required this.floor,
    required this.room,
    required this.role,
  });

  bool get _isAdmin =>
      role == 'admin' ||
      role == 'main_admin' ||
      role == 'super_admin' ||
      role == 'institute_admin';

  InstitutePalette get _palette => InstituteColors.forCode(buildingCode);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(children: [
          _buildHeader(context),
          Expanded(
            child: ResponsiveCenter(
              maxWidth: 900,
              child: RoomDevicesPanel(
                buildingCode: buildingCode,
                buildingName: buildingName,
                floor: floor,
                room: room,
                role: role,
              ),
            ),
          ),
        ]),
      ),
    );
  }

  // Matches BuildingFloorScreen._buildHeader's visual style (dark
  // _palette-colored bar, back arrow, title, Admin/Faculty badge).
  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      color: _palette.dark,
      child: Row(children: [
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
                color: Colors.white.withAlpha(38),
                borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.arrow_back_ios_new,
                color: Colors.white, size: 16),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (buildingName.trim().toUpperCase() !=
                buildingCode.trim().toUpperCase())
              Text(buildingCode,
                  style: TextStyle(
                      fontSize: 11,
                      color: _palette.light,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1)),
            Text(
              '$buildingName - $room',
              style: const TextStyle(
                  fontFamily: AppFonts.family,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Colors.white),
              overflow: TextOverflow.ellipsis,
            ),
          ]),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
              color: Colors.white.withAlpha(26),
              borderRadius: BorderRadius.circular(12)),
          child: Text(_isAdmin ? 'Admin' : 'Faculty',
              style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: Colors.white)),
        ),
      ]),
    );
  }
}
