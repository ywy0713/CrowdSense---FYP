import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/data_service.dart';
import '../../theme/app_theme.dart';

class ThresholdDialog extends StatefulWidget {
  final ZoneData zone;

  const ThresholdDialog({super.key, required this.zone});

  @override
  State<ThresholdDialog> createState() => _ThresholdDialogState();
}

class _ThresholdDialogState extends State<ThresholdDialog> {
  late TextEditingController _lowController;
  late TextEditingController _mediumController;
  late TextEditingController _highController;
  late TextEditingController _criticalController;

  @override
  void initState() {
    super.initState();
    _lowController = TextEditingController(text: widget.zone.thresholds.low.toString());
    _mediumController = TextEditingController(text: widget.zone.thresholds.medium.toString());
    _highController = TextEditingController(text: widget.zone.thresholds.high.toString());
    _criticalController = TextEditingController(text: widget.zone.thresholds.critical.toString());
  }

  @override
  void dispose() {
    _lowController.dispose();
    _mediumController.dispose();
    _highController.dispose();
    _criticalController.dispose();
    super.dispose();
  }

  Future<void> _saveThresholds() async {
    try {
      final thresholds = {
        'thresholds': {
          'low': int.tryParse(_lowController.text) ?? widget.zone.thresholds.low,
          'medium': int.tryParse(_mediumController.text) ?? widget.zone.thresholds.medium,
          'high': int.tryParse(_highController.text) ?? widget.zone.thresholds.high,
          'critical': int.tryParse(_criticalController.text) ?? widget.zone.thresholds.critical,
        },
      };

      await DataService.updateZone(widget.zone.id, thresholds);
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update thresholds: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Set Congestion Thresholds',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(false),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Define the people count upper bounds for each level.',
              style: TextStyle(
                fontSize: 14,
                color: AppTheme.mutedForeground,
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: _buildThresholdField('Low ≤', _lowController),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildThresholdField('Medium ≤', _mediumController),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildThresholdField('High ≤', _highController),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildThresholdField('Critical ≤', _criticalController),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _saveThresholds,
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThresholdField(String label, TextEditingController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: AppTheme.mutedForeground,
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            constraints: const BoxConstraints(
              maxHeight: 48,
            ),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Icons.remove, size: 18),
                  onPressed: () {
                    final value = int.tryParse(controller.text) ?? 0;
                    if (value > 0) {
                      controller.text = (value - 1).toString();
                    }
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                    maxWidth: 28,
                    maxHeight: 28,
                  ),
                  iconSize: 18,
                ),
                IconButton(
                  icon: const Icon(Icons.add, size: 18),
                  onPressed: () {
                    final value = int.tryParse(controller.text) ?? 0;
                    controller.text = (value + 1).toString();
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                    maxWidth: 28,
                    maxHeight: 28,
                  ),
                  iconSize: 18,
                ),
              ],
            ),
            suffixIconConstraints: const BoxConstraints(
              maxWidth: 64,
              minWidth: 64,
            ),
          ),
        ),
      ],
    );
  }
}

