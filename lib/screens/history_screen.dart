import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  String _range = '30d';
  final List<Map<String, String>> _ranges = [
    {'key': '30d',  'label': '30 Days'},
    {'key': '12w',  'label': '12 Weeks'},
    {'key': '12mo', 'label': '12 Months'},
    {'key': '3yr',  'label': '3 Years'},
  ];

  // Mock history data — replace with Firebase reads grouped by range
  final List<Map<String, dynamic>> _mockData = List.generate(30, (i) => {
    'label': 'Day ${i + 1}',
    'kwh':   10.0 + (i % 7) * 3.5 + (i % 3) * 1.2,
    'cost':  (10.0 + (i % 7) * 3.5 + (i % 3) * 1.2) * 11.5,
  });

  double get _totalKwh  => _mockData.fold(0, (sum, d) => sum + (d['kwh'] as double));
  double get _totalCost => _mockData.fold(0, (sum, d) => sum + (d['cost'] as double));
  double get _maxKwh    => _mockData.fold(0.0, (max, d) => (d['kwh'] as double) > max ? d['kwh'] as double : max);

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
                  children: [
                    _buildRangeSelector(),
                    const SizedBox(height: 20),
                    _buildSummaryRow(),
                    const SizedBox(height: 20),
                    _buildChart(),
                    const SizedBox(height: 20),
                    _buildHistoryList(),
                    const SizedBox(height: 20),
                    _buildExportButton(),
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
          child: Text('Energy History',
              style: TextStyle(fontFamily: 'Outfit', fontSize: 18,
                  fontWeight: FontWeight.w700, color: Colors.white)),
        ),
      ]),
    );
  }

  Widget _buildRangeSelector() {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: AppColors.greenPale,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: _ranges.map((r) {
          final isSelected = _range == r['key'];
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _range = r['key']!),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: isSelected ? AppColors.greenDark : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: Text(r['label']!,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isSelected ? Colors.white : AppColors.textMid,
                      )),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSummaryRow() {
    return Row(children: [
      Expanded(child: _summaryCard('Total kWh', '${_totalKwh.toStringAsFixed(1)} kWh', Icons.bolt)),
      const SizedBox(width: 12),
      Expanded(child: _summaryCard('Total Cost', '₱ ${_totalCost.toStringAsFixed(0)}', Icons.payments_outlined)),
    ]);
  }

  Widget _summaryCard(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.greenMid.withAlpha(26)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20, color: AppColors.greenMid),
        const SizedBox(height: 10),
        Text(value, style: const TextStyle(fontFamily: 'Outfit', fontSize: 18,
            fontWeight: FontWeight.w700, color: AppColors.textDark)),
        Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
      ]),
    );
  }

  Widget _buildChart() {
    final displayData = _mockData.take(14).toList();
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.greenMid.withAlpha(26)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Consumption Chart',
              style: TextStyle(fontFamily: 'Outfit', fontSize: 14,
                  fontWeight: FontWeight.w600, color: AppColors.textDark)),
          const SizedBox(height: 4),
          const Text('kWh per period',
              style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
          const SizedBox(height: 20),
          SizedBox(
            height: 140,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: displayData.map((d) {
                final pct = (d['kwh'] as double) / _maxKwh;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 400),
                          height: 120 * pct,
                          decoration: BoxDecoration(
                            color: pct > 0.8
                                ? AppColors.warning
                                : pct > 0.5
                                    ? AppColors.greenMid
                                    : AppColors.greenLight,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Breakdown',
            style: TextStyle(fontFamily: 'Outfit', fontSize: 15,
                fontWeight: FontWeight.w600, color: AppColors.textDark)),
        const SizedBox(height: 12),
        ..._mockData.take(10).map((d) => Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.greenMid.withAlpha(20)),
          ),
          child: Row(children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: AppColors.greenPale,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.calendar_today, size: 16, color: AppColors.greenDark),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(d['label'],
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500,
                    color: AppColors.textDark))),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('${(d['kwh'] as double).toStringAsFixed(1)} kWh',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                      color: AppColors.greenDark)),
              Text('₱ ${(d['cost'] as double).toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
            ]),
          ]),
        )),
      ],
    );
  }

  Widget _buildExportButton() {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: OutlinedButton.icon(
        onPressed: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('CSV export coming soon.')),
          );
        },
        icon: const Icon(Icons.download_outlined, size: 18),
        label: const Text('Export as CSV'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.greenDark,
          side: const BorderSide(color: AppColors.greenMid, width: 1.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    );
  }
}
