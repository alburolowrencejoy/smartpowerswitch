import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import '../theme/app_colors.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _rateController = TextEditingController();
  bool _saving = false;
  double _currentRate = 11.5;

  // Users list
  List<Map<String, dynamic>> _users = [];

  @override
  void initState() {
    super.initState();
    _loadRate();
    _loadUsers();
  }

  @override
  void dispose() {
    _rateController.dispose();
    super.dispose();
  }

  void _loadRate() {
    FirebaseDatabase.instance.ref('settings/electricityRate').once().then((event) {
      if (!mounted) return;
      final rate = (event.snapshot.value as num?)?.toDouble() ?? 11.5;
      setState(() {
        _currentRate = rate;
        _rateController.text = rate.toString();
      });
    });
  }

  void _loadUsers() {
    FirebaseDatabase.instance.ref('users').once().then((event) {
      if (!mounted) return;
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data == null) return;
      final list = data.entries.map((e) {
        final val = Map<String, dynamic>.from(e.value as Map);
        val['uid'] = e.key;
        return val;
      }).toList();
      setState(() => _users = list);
    });
  }

  Future<void> _saveRate() async {
    final rate = double.tryParse(_rateController.text.trim());
    if (rate == null || rate <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid rate.')),
      );
      return;
    }
    setState(() => _saving = true);
    await FirebaseDatabase.instance.ref('settings/electricityRate').set(rate);
    setState(() { _saving = false; _currentRate = rate; });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Electricity rate updated.')),
    );
  }

  Future<void> _changeRole(String uid, String currentRole) async {
    final newRole = currentRole == 'admin' ? 'faculty' : 'admin';
    await FirebaseDatabase.instance.ref('users/$uid/role').set(newRole);
    _loadUsers();
  }

  Future<void> _logout() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/login');
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
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildRateSection(),
                    const SizedBox(height: 24),
                    _buildUsersSection(),
                    const SizedBox(height: 24),
                    _buildAccountSection(),
                    const SizedBox(height: 24),
                    _buildAppInfoSection(),
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
        const Expanded(
          child: Text('Settings',
              style: TextStyle(fontFamily: 'Outfit', fontSize: 18,
                  fontWeight: FontWeight.w700, color: Colors.white)),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.greenLight.withAlpha(51),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Text('Admin',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                  color: AppColors.greenLight)),
        ),
      ]),
    );
  }

  Widget _buildRateSection() {
    return _section(
      title: 'Electricity Rate',
      icon: Icons.payments_outlined,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Current rate: ₱${_currentRate.toStringAsFixed(2)} / kWh',
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _rateController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(fontSize: 14, color: AppColors.textDark),
              decoration: InputDecoration(
                prefixText: '₱ ',
                hintText: '11.5',
                hintStyle: const TextStyle(color: AppColors.textMuted),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppColors.greenMid.withAlpha(51)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppColors.greenMid.withAlpha(51)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.greenMid),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            height: 46,
            child: ElevatedButton(
              onPressed: _saving ? null : _saveRate,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.greenDark,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: _saving
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Text('Save', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _buildUsersSection() {
    return _section(
      title: 'Manage Users',
      icon: Icons.people_outline,
      child: _users.isEmpty
          ? const Text('No users found.',
              style: TextStyle(fontSize: 13, color: AppColors.textMuted))
          : Column(
              children: _users.map((user) {
                final role  = user['role']  as String? ?? 'faculty';
                final email = user['email'] as String? ?? '';
                final uid   = user['uid']   as String? ?? '';
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.greenMid.withAlpha(26)),
                  ),
                  child: Row(children: [
                    Container(
                      width: 36, height: 36,
                      decoration: BoxDecoration(
                        color: AppColors.greenPale,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Center(
                        child: Text(email.isNotEmpty ? email[0].toUpperCase() : 'U',
                            style: const TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w700,
                                color: AppColors.greenDark)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(email, style: const TextStyle(fontSize: 12,
                          fontWeight: FontWeight.w500, color: AppColors.textDark),
                          overflow: TextOverflow.ellipsis),
                      Text(role, style: TextStyle(fontSize: 11,
                          color: role == 'admin' ? AppColors.greenMid : AppColors.textMuted)),
                    ])),
                    GestureDetector(
                      onTap: () => _changeRole(uid, role),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: AppColors.greenPale,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text('Change role',
                            style: TextStyle(fontSize: 10,
                                fontWeight: FontWeight.w600, color: AppColors.greenDark)),
                      ),
                    ),
                  ]),
                );
              }).toList(),
            ),
    );
  }

  Widget _buildAccountSection() {
    final user = FirebaseAuth.instance.currentUser;
    return _section(
      title: 'Account',
      icon: Icons.person_outline,
      child: Column(children: [
        _settingRow(Icons.email_outlined, 'Email', user?.email ?? ''),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 46,
          child: OutlinedButton.icon(
            onPressed: _logout,
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Sign Out'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.error,
              side: BorderSide(color: AppColors.error.withAlpha(102)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildAppInfoSection() {
    return _section(
      title: 'App Info',
      icon: Icons.info_outline,
      child: Column(children: [
        _settingRow(Icons.business, 'Institution', 'Davao del Norte State College'),
        _settingRow(Icons.location_on_outlined, 'Location', 'Davao del Norte, PH'),
        _settingRow(Icons.tag, 'Version', '1.0.0'),
      ]),
    );
  }

  Widget _section({required String title, required IconData icon, required Widget child}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, size: 16, color: AppColors.greenMid),
        const SizedBox(width: 6),
        Text(title, style: const TextStyle(fontFamily: 'Outfit', fontSize: 15,
            fontWeight: FontWeight.w600, color: AppColors.textDark)),
      ]),
      const SizedBox(height: 12),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.greenMid.withAlpha(26)),
        ),
        child: child,
      ),
    ]);
  }

  Widget _settingRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(icon, size: 16, color: AppColors.textMuted),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(fontSize: 13, color: AppColors.textMuted)),
        const Spacer(),
        Flexible(
          child: Text(value,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500,
                  color: AppColors.textDark),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right),
        ),
      ]),
    );
  }
}
