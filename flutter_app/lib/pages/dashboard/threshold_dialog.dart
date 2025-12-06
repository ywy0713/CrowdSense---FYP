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
      final low = int.tryParse(_lowController.text) ?? widget.zone.thresholds.low;
      final medium = int.tryParse(_mediumController.text) ?? widget.zone.thresholds.medium;
      final high = int.tryParse(_highController.text) ?? widget.zone.thresholds.high;
      final critical = int.tryParse(_criticalController.text) ?? widget.zone.thresholds.critical;

      // Validate that thresholds are in strictly increasing order
      String? errorMessage;
      if (medium <= low) {
        errorMessage = 'Medium threshold must be greater than Low threshold.';
      } else if (high <= medium) {
        errorMessage = 'High threshold must be greater than Medium threshold.';
      } else if (critical <= high) {
        errorMessage = 'Critical threshold must be greater than High threshold.';
      }

      if (errorMessage != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(errorMessage),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 3),
            ),
          );
        }
        return;
      }

      final thresholds = {
        'thresholds': {
          'low': low,
          'medium': medium,
          'high': high,
          'critical': critical,
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
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.9,
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                Expanded(
                  child: Text(
                    'Set Congestion Thresholds',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.visible,
                    maxLines: 2,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(false),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 40,
                  ),
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
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      final value = int.tryParse(controller.text) ?? 0;
                      if (value > 0) {
                        controller.text = (value - 1).toString();
                      }
                    },
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      width: 20,
                      height: 20,
                      alignment: Alignment.center,
                      child: const Icon(Icons.remove, size: 14),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      final value = int.tryParse(controller.text) ?? 0;
                      controller.text = (value + 1).toString();
                    },
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      width: 20,
                      height: 20,
                      alignment: Alignment.center,
                      child: const Icon(Icons.add, size: 14),
                    ),
                  ),
                ),
              ],
            ),
            suffixIconConstraints: const BoxConstraints(
              maxWidth: 48,
              minWidth: 48,
            ),
          ),
        ),
      ],
    );
  }
}

