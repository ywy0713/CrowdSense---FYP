import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../../services/data_service.dart';
import '../../theme/app_theme.dart';

/// Summary report data model
class SummaryReport {
  final String zoneName;
  final DateTime startDate;
  final DateTime endDate;
  final DateTime? peakTime;
  final int peakCount;
  final List<AlertLog> criticalAlerts;
  final List<AlertLog> highAlerts;
  final int totalPeople;
  final List<CountSnapshot> analyticsData;
  final ZoneThresholds thresholds;
  final String recommendation;
  final double? averageServiceSpeed; // Add service speed for waiting time calculation

  SummaryReport({
    required this.zoneName,
    required this.startDate,
    required this.endDate,
    this.peakTime,
    required this.peakCount,
    required this.criticalAlerts,
    required this.highAlerts,
    required this.totalPeople,
    required this.analyticsData,
    required this.thresholds,
    required this.recommendation,
    this.averageServiceSpeed,
  });
}

class SummaryReportDialog extends StatelessWidget {
  final SummaryReport report;

  const SummaryReportDialog({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.9,
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: const Text(
                    'Summary Report',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const Divider(height: 32),
            // Content
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Zone and Date Range
                    _buildSection(
                      'Report Period',
                      [
                        _buildInfoRow('Zone', report.zoneName),
                        _buildInfoRow(
                          'Date Range',
                          '${_formatDateTime(report.startDate)} - ${_formatDateTime(report.endDate)}',
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    // Insights
                    _buildSection(
                      'Key Insights',
                      [
                        if (report.peakTime != null)
                          _buildInsightCard(
                            Icons.people,
                            'Peak Crowd Time',
                            '${_formatDateTime(report.peakTime!)}',
                            'Maximum people count: ${report.peakCount}',
                            Colors.blue,
                          ),
                        if (report.criticalAlerts.isNotEmpty)
                          _buildInsightCard(
                            Icons.warning,
                            'Critical Threshold Events',
                            '${report.criticalAlerts.length} occurrence(s)',
                            report.criticalAlerts
                                .map((a) => _formatDateTime(DateTime.fromMillisecondsSinceEpoch(a.timestamp)))
                                .join(', '),
                            Colors.red,
                          ),
                        if (report.highAlerts.isNotEmpty)
                          _buildInsightCard(
                            Icons.trending_up,
                            'High Threshold Events',
                            '${report.highAlerts.length} occurrence(s)',
                            report.highAlerts
                                .map((a) => _formatDateTime(DateTime.fromMillisecondsSinceEpoch(a.timestamp)))
                                .join(', '),
                            Colors.orange,
                          ),
                        _buildInsightCard(
                          Icons.analytics,
                          'Total People Count',
                          '${report.totalPeople}',
                          'Sum of all recorded counts',
                          Colors.green,
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    // Recommendation
                    _buildSection(
                      'Management Recommendation',
                      [
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: AppTheme.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.lightbulb, color: AppTheme.primary, size: 24),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  report.recommendation,
                                  style: const TextStyle(fontSize: 14),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    // Detailed Statistics
                    _buildSection(
                      'Detailed Statistics',
                      [
                        _buildStatRow('Average Count', _calculateAverage()),
                        _buildStatRow('Minimum Count', _calculateMinimum()),
                        _buildStatRow('Maximum Count', report.peakCount.toString()),
                        _buildStatRow('Data Points', report.analyticsData.length.toString()),
                        _buildStatRow('Critical Threshold', report.thresholds.critical.toString()),
                        _buildStatRow('High Threshold', report.thresholds.high.toString()),
                        _buildStatRow('Medium Threshold', report.thresholds.medium.toString()),
                        _buildStatRow('Low Threshold', report.thresholds.low.toString()),
                      ],
                    ),
                    const SizedBox(height: 24),
                    // Alert Details
                    if (report.criticalAlerts.isNotEmpty || report.highAlerts.isNotEmpty)
                      _buildSection(
                        'Alert Details',
                        [
                          if (report.criticalAlerts.isNotEmpty) ...[
                            const Text(
                              'Critical Alerts',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.red,
                              ),
                            ),
                            const SizedBox(height: 8),
                            ...report.criticalAlerts.map((alert) => _buildAlertCard(alert, Colors.red)),
                          ],
                          if (report.highAlerts.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            const Text(
                              'High Alerts',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.orange,
                              ),
                            ),
                            const SizedBox(height: 8),
                            ...report.highAlerts.map((alert) => _buildAlertCard(alert, Colors.orange)),
                          ],
                        ],
                      ),
                  ],
                ),
              ),
            ),
            // Export PDF Button at bottom
            const Divider(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _exportToPdf(context),
                icon: const Icon(Icons.picture_as_pdf),
                label: const Text('Export to PDF'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: AppTheme.foreground,
          ),
        ),
        const SizedBox(height: 12),
        ...children,
      ],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              '$label:',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: AppTheme.mutedForeground,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: AppTheme.foreground),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInsightCard(IconData icon, String title, String value, String subtitle, Color color) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 32),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.mutedForeground,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(color: AppTheme.mutedForeground),
          ),
          Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAlertCard(AlertLog alert, Color color) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDateTime(DateTime.fromMillisecondsSinceEpoch(alert.timestamp)),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  alert.level.toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('People Count: ${alert.peopleCount}'),
          Text('Waiting Time: ${_calculateWaitingTime(alert)} minutes'),
          if (alert.message.isNotEmpty)
            Text(
              alert.message,
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.mutedForeground,
                fontStyle: FontStyle.italic,
              ),
            ),
        ],
      ),
    );
  }

  String _calculateAverage() {
    if (report.analyticsData.isEmpty) return '0';
    final sum = report.analyticsData.map((e) => e.count).reduce((a, b) => a + b);
    return (sum / report.analyticsData.length).toStringAsFixed(1);
  }

  String _calculateMinimum() {
    if (report.analyticsData.isEmpty) return '0';
    return report.analyticsData.map((e) => e.count).reduce((a, b) => a < b ? a : b).toString();
  }

  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.year}-${dateTime.month.toString().padLeft(2, '0')}-${dateTime.day.toString().padLeft(2, '0')} ${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
  }

  int _calculateWaitingTime(AlertLog alert) {
    // If waitingTimeMin is already calculated and > 0, use it
    if (alert.waitingTimeMin > 0) {
      return alert.waitingTimeMin;
    }
    
    // Otherwise, calculate from service speed if available
    if (report.averageServiceSpeed != null && report.averageServiceSpeed! > 0) {
      // serviceSpeed is in minutes/person
      // waitingTime = count * serviceSpeed
      return (alert.peopleCount * report.averageServiceSpeed!).round();
    }
    
    // Default to 0 if no service speed available
    return 0;
  }

  Future<void> _exportToPdf(BuildContext context) async {
    try {
      final pdf = pw.Document();
      
      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(40),
          build: (pw.Context context) {
            return [
              // Header
              pw.Header(
                level: 0,
                child: pw.Text(
                  'Summary Report - ${report.zoneName}',
                  style: pw.TextStyle(
                    fontSize: 24,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              pw.SizedBox(height: 20),
              
              // Report Period
              pw.Text(
                'Report Period',
                style: pw.TextStyle(
                  fontSize: 18,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 8),
              pw.Text('Zone: ${report.zoneName}'),
              pw.Text('Date Range: ${_formatDateTime(report.startDate)} - ${_formatDateTime(report.endDate)}'),
              pw.SizedBox(height: 20),
              
              // Key Insights
              pw.Text(
                'Key Insights',
                style: pw.TextStyle(
                  fontSize: 18,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 8),
              if (report.peakTime != null)
                pw.Text('Peak Crowd Time: ${_formatDateTime(report.peakTime!)} (${report.peakCount} people)'),
              pw.Text('Critical Threshold Events: ${report.criticalAlerts.length}'),
              pw.Text('High Threshold Events: ${report.highAlerts.length}'),
              pw.Text('Total People Count: ${report.totalPeople}'),
              pw.SizedBox(height: 20),
              
              // Recommendation
              pw.Text(
                'Management Recommendation',
                style: pw.TextStyle(
                  fontSize: 18,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 8),
              pw.Text(report.recommendation),
              pw.SizedBox(height: 20),
              
              // Detailed Statistics
              pw.Text(
                'Detailed Statistics',
                style: pw.TextStyle(
                  fontSize: 18,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 8),
              pw.Text('Average Count: ${_calculateAverage()}'),
              pw.Text('Minimum Count: ${_calculateMinimum()}'),
              pw.Text('Maximum Count: ${report.peakCount}'),
              pw.Text('Data Points: ${report.analyticsData.length}'),
              pw.Text('Critical Threshold: ${report.thresholds.critical}'),
              pw.Text('High Threshold: ${report.thresholds.high}'),
              pw.Text('Medium Threshold: ${report.thresholds.medium}'),
              pw.Text('Low Threshold: ${report.thresholds.low}'),
              
              // Alert Details
              if (report.criticalAlerts.isNotEmpty || report.highAlerts.isNotEmpty) ...[
                pw.SizedBox(height: 20),
                pw.Text(
                  'Alert Details',
                  style: pw.TextStyle(
                    fontSize: 18,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.SizedBox(height: 8),
                if (report.criticalAlerts.isNotEmpty) ...[
                  pw.Text(
                    'Critical Alerts',
                    style: pw.TextStyle(
                      fontSize: 14,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.red,
                    ),
                  ),
                  ...report.criticalAlerts.map((alert) => pw.Padding(
                    padding: const pw.EdgeInsets.only(bottom: 8),
                    child: pw.Text(
                      '${_formatDateTime(DateTime.fromMillisecondsSinceEpoch(alert.timestamp))} - ${alert.peopleCount} people - ${alert.waitingTimeMin} min wait',
                    ),
                  )),
                ],
                if (report.highAlerts.isNotEmpty) ...[
                  pw.SizedBox(height: 8),
                  pw.Text(
                    'High Alerts',
                    style: pw.TextStyle(
                      fontSize: 14,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.orange,
                    ),
                  ),
                  ...report.highAlerts.map((alert) => pw.Padding(
                    padding: const pw.EdgeInsets.only(bottom: 8),
                    child: pw.Text(
                      '${_formatDateTime(DateTime.fromMillisecondsSinceEpoch(alert.timestamp))} - ${alert.peopleCount} people - ${alert.waitingTimeMin} min wait',
                    ),
                  )),
                ],
              ],
            ];
          },
        ),
      );

      // Use printing package to share/print PDF
      if (context.mounted) {
        await Printing.layoutPdf(
          onLayout: (PdfPageFormat format) async => pdf.save(),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to export PDF: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

