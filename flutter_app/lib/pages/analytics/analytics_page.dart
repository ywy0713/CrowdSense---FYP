import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../theme/app_theme.dart';
import '../../components/bottom_nav.dart';
import '../../providers/active_camera_provider.dart';
import 'package:fl_chart/fl_chart.dart';
import 'summary_report_dialog.dart';

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
    final activeCameras = ref.watch(activeCameraProvider);
    final activeCameraId = activeCameras.isNotEmpty ? activeCameras.first : null;
    
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
        final activeCameras = ref.read(activeCameraProvider);
        final activeCameraId = activeCameras.isNotEmpty ? activeCameras.first : null;
        
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
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _selectDateRange,
                                  icon: const Icon(Icons.calendar_today),
                                  label: Text(
                                    '${_formatDate(_startDate)} - ${_formatDate(_endDate)}',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: _analyticsData.isEmpty ? null : _generateSummaryReport,
                              icon: const Icon(Icons.summarize),
                              label: Text(_analyticsData.isEmpty 
                                ? 'Generate Summary Report (No Data)' 
                                : 'Generate Summary Report'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _analyticsData.isEmpty 
                                  ? AppTheme.muted 
                                  : AppTheme.primary,
                                foregroundColor: _analyticsData.isEmpty 
                                  ? AppTheme.mutedForeground 
                                  : Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                disabledBackgroundColor: AppTheme.muted,
                                disabledForegroundColor: AppTheme.mutedForeground,
                              ),
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
                                        child: SingleChildScrollView(
                                          scrollDirection: Axis.horizontal,
                                          child: SizedBox(
                                            width: _calculateChartWidth(),
                                            height: 400,
                                            child: LineChart(
                                              _buildChartData(),
                                            ),
                                          ),
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

  double _calculateChartWidth() {
    // Ensure minimum width is the screen width minus padding
    final minWidth = MediaQuery.of(context).size.width - 64;
    
    // Calculate required width based on data points to allow comfortable scrolling
    // Use 30 pixels per point to ensure density but readability
    final contentWidth = _analyticsData.length * 30.0;
    
    // Return the larger of the two
    return contentWidth < minWidth ? minWidth : contentWidth;
  }

  LineChartData _buildChartData() {
    if (_analyticsData.isEmpty) {
       return LineChartData(); // Return empty chart if no data
    }

    // Use all data points (no downsampling) to allow full scrolling
    final chartData = _analyticsData;
    
    final maxCount = chartData.map((e) => e.count).reduce((a, b) => a > b ? a : b);
    // Ensure maxCount is at least 5 to avoid flat lines at bottom
    final yMax = (maxCount > 5 ? maxCount : 5).toDouble() * 1.2; 
    
    // Calculate interval for X-axis labels (show roughly every 2-3 points for clarity)
    // Since we have wide scrolling, we can show frequent labels
    final xInterval = 3.0;
    
    return LineChartData(
      gridData: FlGridData(
        show: true,
        drawVerticalLine: false, // Reduce clutter
        horizontalInterval: 1,
        getDrawingHorizontalLine: (value) => FlLine(
          color: AppTheme.border,
          strokeWidth: 1,
          dashArray: [5, 5], // Dashed lines
        ),
      ),
      titlesData: FlTitlesData(
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 35,
            interval: (yMax / 5).ceil().toDouble(), // Smart interval
            getTitlesWidget: (value, meta) {
               if (value % 1 == 0) {
                 return Text(value.toInt().toString(), style: const TextStyle(fontSize: 10));
              }
               return const SizedBox.shrink();
            },
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 40, // Increased height for 2-line date/time
            interval: xInterval,
            getTitlesWidget: (value, meta) {
              final index = value.toInt();
              if (index >= 0 && index < chartData.length) {
                final date = DateTime.fromMillisecondsSinceEpoch(
                  chartData[index].timestamp,
                );
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '${date.month}/${date.day}\n${date.hour}:${date.minute.toString().padLeft(2, '0')}',
                    style: const TextStyle(fontSize: 9),
                    textAlign: TextAlign.center,
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ),
        rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      borderData: FlBorderData(show: false),
      lineBarsData: [
        LineChartBarData(
          spots: chartData.asMap().entries.map((entry) {
            return FlSpot(entry.key.toDouble(), entry.value.count.toDouble());
          }).toList(),
          isCurved: true, // Smooth lines
          color: AppTheme.primary,
          barWidth: 3,
          dotData: FlDotData(show: false),
          belowBarData: BarAreaData(
             show: true, 
             color: AppTheme.primary.withValues(alpha: 0.1)
          ),
        ),
      ],
      minX: 0,
      maxX: (chartData.length - 1).toDouble(),
      minY: 0,
      maxY: yMax,
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
                Icon(icon, size: 16, color: AppTheme.primary),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 10,
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

  Future<void> _generateSummaryReport() async {
    if (_selectedZoneId == null || _analyticsData.isEmpty) return;

    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      // Get zone data
      final zone = _zones.firstWhere((z) => z.id == _selectedZoneId);
      
      // Get alerts in the date range
      final alerts = await DataService.getAlertsInRange(
        _selectedZoneId!,
        _startDate.millisecondsSinceEpoch,
        _endDate.millisecondsSinceEpoch,
      );

      // Find peak time
      CountSnapshot? peakSnapshot;
      if (_analyticsData.isNotEmpty) {
        peakSnapshot = _analyticsData.reduce((a, b) => a.count > b.count ? a : b);
      }

      // Filter alerts by level
      final criticalAlerts = alerts.where((a) => a.level == 'critical').toList();
      final highAlerts = alerts.where((a) => a.level == 'high').toList();

      // Calculate total people count
      final totalPeople = _analyticsData.map((e) => e.count).reduce((a, b) => a + b);

      // Generate recommendation
      final recommendation = _generateRecommendation(
        peakSnapshot,
        criticalAlerts,
        highAlerts,
        zone.thresholds,
      );

      // Create report
      final report = SummaryReport(
        zoneName: zone.name,
        startDate: _startDate,
        endDate: _endDate,
        peakTime: peakSnapshot != null ? DateTime.fromMillisecondsSinceEpoch(peakSnapshot.timestamp) : null,
        peakCount: peakSnapshot?.count ?? 0,
        criticalAlerts: criticalAlerts,
        highAlerts: highAlerts,
        totalPeople: totalPeople,
        analyticsData: _analyticsData,
        thresholds: zone.thresholds,
        recommendation: recommendation,
        averageServiceSpeed: zone.averageServiceSpeed,
      );

      // Close loading dialog
      if (mounted) {
        Navigator.of(context).pop();
        
        // Show report dialog
        showDialog(
          context: context,
          builder: (context) => SummaryReportDialog(report: report),
        );
      }
    } catch (e) {
      // Close loading dialog
      if (mounted) {
        Navigator.of(context).pop();
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to generate report: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  String _generateRecommendation(
    CountSnapshot? peakSnapshot,
    List<AlertLog> criticalAlerts,
    List<AlertLog> highAlerts,
    ZoneThresholds thresholds,
  ) {
    final recommendations = <String>[];

    // Peak time recommendation
    if (peakSnapshot != null) {
      final peakTime = DateTime.fromMillisecondsSinceEpoch(peakSnapshot.timestamp);
      final hour = peakTime.hour;
      String timeOfDay;
      if (hour >= 6 && hour < 12) {
        timeOfDay = 'morning';
      } else if (hour >= 12 && hour < 18) {
        timeOfDay = 'afternoon';
      } else if (hour >= 18 && hour < 22) {
        timeOfDay = 'evening';
      } else {
        timeOfDay = 'night';
      }
      
      recommendations.add(
        'Peak crowd occurs during $timeOfDay hours (${peakTime.hour}:${peakTime.minute.toString().padLeft(2, '0')}) with ${peakSnapshot.count} people. Consider increasing staff during this period.',
      );
    }

    // Critical alerts recommendation
    if (criticalAlerts.isNotEmpty) {
      final criticalTimes = criticalAlerts.map((a) {
        final dt = DateTime.fromMillisecondsSinceEpoch(a.timestamp);
        return '${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
      }).toSet().toList();
      
      recommendations.add(
        'Critical threshold was reached ${criticalAlerts.length} time(s) at: ${criticalTimes.join(', ')}. Immediate action required during these times.',
      );
    }

    // High alerts recommendation
    if (highAlerts.isNotEmpty && criticalAlerts.isEmpty) {
      final highTimes = highAlerts.map((a) {
        final dt = DateTime.fromMillisecondsSinceEpoch(a.timestamp);
        return '${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
      }).toSet().toList();
      
      recommendations.add(
        'High threshold was reached ${highAlerts.length} time(s) at: ${highTimes.join(', ')}. Consider proactive management during these periods.',
      );
    }

    // General recommendation
    if (recommendations.isEmpty) {
      recommendations.add(
        'No significant congestion events detected during this period. Current staffing levels appear adequate.',
      );
    }

    return recommendations.join('\n\n');
  }
}
