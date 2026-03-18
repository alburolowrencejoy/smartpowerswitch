import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../theme/app_colors.dart';

class DeviceDetailScreen extends StatefulWidget {
  final String deviceId;
  final String utility;
  final String building;
  final int floor;

  const DeviceDetailScreen({
    super.key,
    required this.deviceId,
    required this.utility,
    required this.building,
    required this.floor,
  });

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  Map<String, dynamic> _readings = {};
  bool _relay    = false;
  bool _isOnline = false;
  bool _toggling = false;
  double _ratePhp = 11.5;

  @override
  void initState() {
    super.initState();
    _listenToReadings();
    _listenToRelay();
    _fetchRate();
  }

  void _listenToReadings() {
    FirebaseDatabase.instance
        .ref('readings/${widget.deviceId}')
        .onValue
        .listen((event) {
      if (!mounted) return;
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      setState(() {
        _readings = data?.map((k, v) => MapEntry(k.toString(), v)) ?? {};
        _isOnline = _readings.isNotEmpty;
      });
    });
  }

  void _listenToRelay() {
    FirebaseDatabase.instance
        .ref('buildings/${widget.building}/floorData/${widget.floor}/devices/${widget.deviceId}/relay')
        .onValue
        .listen((event) {
      if (!mounted) return;
      setState(() => _relay = (event.snapshot.value as bool?) ?? false);
    });
  }

  void _fetchRate() {
    FirebaseDatabase.instance.ref('settings/electricityRate').once().then((event) {
      if (!mounted) return;
      setState(() => _ratePhp = (event.snapshot.value as num?)?.toDouble() ?? 11.5);
    });
  }

  Future<void> _toggleRelay() async {
    setState(() => _toggling = true);
    await FirebaseDatabase.instance
        .ref('buildings/${widget.building}/floorData/${widget.floor}/devices/${widget.deviceId}/relay')
        .set(!_relay);
    setState(() => _toggling = false);
  }

  @override
  Widget build(BuildContext context) {
    final energy = (_readings['energy'] as num?)?.toDouble() ?? 0.0;
    final cost   = energy * _ratePhp;

    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    _buildStatusCard(),
                    const SizedBox(height: 16),
                    _buildRelayCard(),
                    const SizedBox(height: 16),
                    _buildReadingsGrid(),
                    const SizedBox(height: 16),
                    _buildCostCard(energy, cost),
                    const SizedBox(height: 16),
                    _buildDeviceInfoCard(),
                  ],
                ),
              ),
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
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${widget.building} · Floor ${widget.floor}',
                style: const TextStyle(fontSize: 11, color: AppColors.greenLight,
                    fontWeight: FontWeight.w500, letterSpacing: 0.5)),
            Text(_utilityLabel(widget.utility),
                style: const TextStyle(fontFamily: 'Outfit', fontSize: 18,
                    fontWeight: FontWeight.w700, color: Colors.white)),
          ]),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _isOnline
                ? AppColors.greenLight.withAlpha(51)
                : Colors.white.withAlpha(26),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 6, height: 6,
                decoration: BoxDecoration(shape: BoxShape.circle,
                    color: _isOnline ? AppColors.greenLight : AppColors.offline)),
            const SizedBox(width: 5),
            Text(_isOnline ? 'Online' : 'Offline',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                    color: _isOnline ? AppColors.greenLight : AppColors.offline)),
          ]),
        ),
      ]),
    );
  }

  Widget _buildStatusCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.greenMid.withAlpha(26)),
      ),
      child: Row(children: [
        Container(
          width: 52, height: 52,
          decoration: BoxDecoration(
            color: _utilityColor(widget.utility).withAlpha(31),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(_utilityIcon(widget.utility), size: 28,
              color: _utilityColor(widget.utility)),
        ),
        const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.deviceId,
              style: const TextStyle(fontFamily: 'Outfit', fontSize: 15,
                  fontWeight: FontWeight.w600, color: AppColors.textDark)),
          const SizedBox(height: 2),
          Text('${widget.building} · Floor ${widget.floor} · ${_utilityLabel(widget.utility)}',
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
        ])),
      ]),
    );
  }

  Widget _buildRelayCard() {
    final isAc = widget.utility == 'ac';
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _relay ? AppColors.greenDark : AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: _relay ? AppColors.greenMid : AppColors.greenMid.withAlpha(26),
        ),
      ),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(isAc ? 'Contactor' : 'Relay',
              style: TextStyle(fontSize: 12, color: _relay ? AppColors.greenPale : AppColors.textMuted)),
          const SizedBox(height: 4),
          Text(_relay ? 'Turned ON' : 'Turned OFF',
              style: TextStyle(fontFamily: 'Outfit', fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: _relay ? Colors.white : AppColors.textDark)),
          const SizedBox(height: 2),
          Text(_relay ? 'Tap to turn off' : 'Tap to turn on',
              style: TextStyle(fontSize: 12,
                  color: _relay ? AppColors.greenPale.withAlpha(179) : AppColors.textMuted)),
        ])),
        GestureDetector(
          onTap: _isOnline && !_toggling ? _toggleRelay : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: 64, height: 34,
            decoration: BoxDecoration(
              color: _relay ? AppColors.greenLight : const Color(0xFFE0E0E0),
              borderRadius: BorderRadius.circular(17),
            ),
            child: Stack(children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 250),
                left: _relay ? 32 : 2,
                top: 2, bottom: 2,
                child: Container(
                  width: 30,
                  decoration: const BoxDecoration(
                    color: Colors.white, shape: BoxShape.circle,
                  ),
                  child: _toggling
                      ? const Padding(
                          padding: EdgeInsets.all(6),
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.greenMid))
                      : null,
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _buildReadingsGrid() {
    final voltage     = (_readings['voltage']     as num?)?.toStringAsFixed(1) ?? '--';
    final current     = (_readings['current']     as num?)?.toStringAsFixed(2) ?? '--';
    final power       = (_readings['power']       as num?)?.toStringAsFixed(1) ?? '--';
    final powerFactor = (_readings['powerFactor'] as num?)?.toStringAsFixed(2) ?? '--';
    final frequency   = (_readings['frequency']   as num?)?.toStringAsFixed(1) ?? '--';
    final energy      = (_readings['energy']      as num?)?.toStringAsFixed(2) ?? '--';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('PZEM-004T Readings',
            style: TextStyle(fontFamily: 'Outfit', fontSize: 15,
                fontWeight: FontWeight.w600, color: AppColors.textDark)),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.05,
          children: [
            _readingTile('Voltage', voltage, 'V',    Icons.electrical_services, AppColors.greenMid),
            _readingTile('Current', current, 'A',    Icons.bolt,                AppColors.warning),
            _readingTile('Power',   power,   'W',    Icons.power,               AppColors.greenDark),
            _readingTile('Energy',  energy,  'kWh',  Icons.battery_charging_full, const Color(0xFF2196F3)),
            _readingTile('Freq.',   frequency,'Hz',  Icons.waves,               AppColors.greenLight),
            _readingTile('P.Factor',powerFactor,'',  Icons.speed,               const Color(0xFF9C27B0)),
          ],
        ),
      ],
    );
  }

  Widget _readingTile(String label, String value, String unit, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withAlpha(38)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, size: 18, color: color),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(value, style: const TextStyle(fontFamily: 'Outfit', fontSize: 16,
                    fontWeight: FontWeight.w700, color: AppColors.textDark)),
                if (unit.isNotEmpty) ...[
                  const SizedBox(width: 2),
                  Padding(padding: const EdgeInsets.only(bottom: 1),
                      child: Text(unit, style: const TextStyle(fontSize: 9, color: AppColors.textMuted))),
                ],
              ],
            ),
            Text(label, style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
          ]),
        ],
      ),
    );
  }

  Widget _buildCostCard(double energy, double cost) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.greenPale,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.greenMid.withAlpha(51)),
      ),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Estimated Cost',
              style: TextStyle(fontSize: 12, color: AppColors.textMid)),
          const SizedBox(height: 4),
          Text('₱ ${cost.toStringAsFixed(2)}',
              style: const TextStyle(fontFamily: 'Outfit', fontSize: 24,
                  fontWeight: FontWeight.w700, color: AppColors.greenDark)),
          Text('at ₱${_ratePhp.toStringAsFixed(2)} / kWh',
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
        ])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          const Text('Total Energy',
              style: TextStyle(fontSize: 11, color: AppColors.textMid)),
          Text('${energy.toStringAsFixed(2)} kWh',
              style: const TextStyle(fontFamily: 'Outfit', fontSize: 16,
                  fontWeight: FontWeight.w600, color: AppColors.greenDark)),
        ]),
      ]),
    );
  }

  Widget _buildDeviceInfoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.greenMid.withAlpha(26)),
      ),
      child: Column(children: [
        _infoRow('Device ID',  widget.deviceId),
        _infoRow('Building',   widget.building),
        _infoRow('Floor',      'Floor ${widget.floor}'),
        _infoRow('Utility',    _utilityLabel(widget.utility)),
        _infoRow('Control',    widget.utility == 'ac' ? 'Contactor 220V' : 'Relay 220V'),
        _infoRow('Sensor',     'PZEM-004T + CT Clamp'),
      ]),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
        const Spacer(),
        Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
            color: AppColors.textDark)),
      ]),
    );
  }

  String _utilityLabel(String u) {
    switch (u) {
      case 'lights':  return 'Lights';
      case 'outlets': return 'Outlets';
      case 'ac':      return 'AC Unit';
      default:        return 'Device';
    }
  }

  IconData _utilityIcon(String u) {
    switch (u) {
      case 'lights':  return Icons.lightbulb_outline;
      case 'outlets': return Icons.electrical_services;
      case 'ac':      return Icons.ac_unit;
      default:        return Icons.device_unknown_outlined;
    }
  }

  Color _utilityColor(String u) {
    switch (u) {
      case 'lights':  return const Color(0xFFE8922A);
      case 'outlets': return AppColors.greenMid;
      case 'ac':      return const Color(0xFF2196F3);
      default:        return AppColors.textMuted;
    }
  }
}
