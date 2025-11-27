import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../theme/app_theme.dart';
import '../../components/bottom_nav.dart';
import '../../providers/active_camera_provider.dart';
import 'package:fl_chart/fl_chart.dart';

class AnalyticsPage extends ConsumerStatefulWidget {
  const AnalyticsPage({super.key});

  @override
  ConsumerState<AnalyticsPage> createState() => _AnalyticsPageState();
}

class _AnalyticsPageState extends ConsumerState<AnalyticsPage> {
  List<ZoneData> _zones = [];
  String? _selectedZoneId;
  List<CountSnapshot> _analyticsData = [];
  bool _isLoading = true;
  DateTime _startDate = DateTime.now().subtract(const Duration(days: 7));
  DateTime _endDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    _loadZones();
  }

  @override
  Widget build(BuildContext context) {
    // Watch active camera provider
    final activeCameraId = ref.watch(activeCameraProvider);
    
    // Update selected zone if active camera changed
    if (activeCameraId != null && activeCameraId != _selectedZoneId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() {
          _selectedZoneId = activeCameraId;
          if (_selectedZoneId != null) {
            _loadAnalytics();
          }
        });
      });
    }

    return _buildAnalyticsContent();
  }

  Future<void> _loadZones() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final user = AuthService.getCurrentUser();
      if (user != null) {
        final zones = await DataService.getUserZones(user.uid);
        final activeCameraId = ref.read(activeCameraProvider);
        
        setState(() {
          _zones = zones;
          if (zones.isNotEmpty) {
            // Use active camera if set, otherwise use first zone
            _selectedZoneId = activeCameraId ?? zones.first.id;
            _loadAnalytics();
          }
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _loadAnalytics() async {
    if (_selectedZoneId == null) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final data = await DataService.getAnalyticsData(
        _selectedZoneId!,
        _startDate.millisecondsSinceEpoch,
        _endDate.millisecondsSinceEpoch,
      );
      setState(() {
        _analyticsData = data;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _selectDateRange() async {
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(start: _startDate, end: _endDate),
    );
    if (picked != null) {
      setState(() {
        _startDate = picked.start;
        _endDate = picked.end;
      });
      _loadAnalytics();
    }
  }

  Widget _buildAnalyticsContent() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Analytics'),
      ),
      bottomNavigationBar: const BottomNav(currentIndex: 1),
      body: _isLoading && _zones.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _zones.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.analytics_outlined, size: 64, color: AppTheme.mutedForeground),
                      const SizedBox(height: 16),
                      Text(
                        'No Zones Available',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.foreground,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Create zones to view analytics',
                        style: TextStyle(color: AppTheme.mutedForeground),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    // Zone selector and date range
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          DropdownButtonFormField<String>(
                            value: _selectedZoneId,
                            decoration: const InputDecoration(
                              labelText: 'Select Zone',
                              border: OutlineInputBorder(),
                            ),
                            items: _zones.map((zone) {
                              return DropdownMenuItem(
                                value: zone.id,
                                child: Text(zone.name),
                              );
                            }).toList(),
                            onChanged: (value) {
                              setState(() {
                                _selectedZoneId = value;
                              });
                              _loadAnalytics();
                            },
                          ),
                          const SizedBox(height: 16),
                          OutlinedButton.icon(
                            onPressed: _selectDateRange,
                            icon: const Icon(Icons.calendar_today),
                            label: Text(
                              '${_formatDate(_startDate)} - ${_formatDate(_endDate)}',
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Chart
                    Expanded(
                      child: _analyticsData.isEmpty
                          ? Center(
                              child: Text(
                                'No data available for selected period',
                                style: TextStyle(color: AppTheme.mutedForeground),
                              ),
                            )
                          : Padding(
                              padding: const EdgeInsets.all(16),
                              child: Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'People Count Over Time',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: AppTheme.foreground,
                                        ),
                                      ),
                                      const SizedBox(height: 24),
                                      Expanded(
                                        child: LineChart(
                                          _buildChartData(),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                    ),
                    // Statistics
                    if (_analyticsData.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Expanded(
                              child: _buildStatCard(
                                'Average',
                                '${(_analyticsData.map((e) => e.count).reduce((a, b) => a + b) / _analyticsData.length).toStringAsFixed(1)}',
                                Icons.trending_up,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _buildStatCard(
                                'Peak',
                                '${_analyticsData.map((e) => e.count).reduce((a, b) => a > b ? a : b)}',
                                Icons.show_chart,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _buildStatCard(
                                'Data Points',
                                '${_analyticsData.length}',
                                Icons.data_usage,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
    );
  }

  LineChartData _buildChartData() {
    return LineChartData(
      gridData: FlGridData(show: true),
      titlesData: FlTitlesData(
        leftTitles: AxisTitles(
          sideTitles: SideTitles(showTitles: true),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            getTitlesWidget: (value, meta) {
              if (value.toInt() >= 0 && value.toInt() < _analyticsData.length) {
                final date = DateTime.fromMillisecondsSinceEpoch(
                  _analyticsData[value.toInt()].timestamp,
                );
                return Text(
                  '${date.day}/${date.month}',
                  style: const TextStyle(fontSize: 10),
                );
              }
              return const Text('');
            },
          ),
        ),
        rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      borderData: FlBorderData(show: true),
      lineBarsData: [
        LineChartBarData(
          spots: _analyticsData.asMap().entries.map((entry) {
            return FlSpot(entry.key.toDouble(), entry.value.count.toDouble());
          }).toList(),
          isCurved: true,
          color: AppTheme.primary,
          barWidth: 3,
          dotData: FlDotData(show: false),
          belowBarData: BarAreaData(show: false),
        ),
      ],
      minX: 0,
      maxX: _analyticsData.length > 0 ? (_analyticsData.length - 1).toDouble() : 1,
      minY: 0,
      maxY: _analyticsData.isEmpty
          ? 100
          : _analyticsData.map((e) => e.count).reduce((a, b) => a > b ? a : b).toDouble() * 1.1,
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: AppTheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      color: AppTheme.mutedForeground,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.foreground,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }
}
