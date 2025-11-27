import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../theme/app_theme.dart';
import '../../providers/active_camera_provider.dart';
import 'dart:convert';

class NotificationsPage extends ConsumerStatefulWidget {
  const NotificationsPage({super.key});

  @override
  ConsumerState<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends ConsumerState<NotificationsPage> {
  List<ZoneData> _zones = [];
  Map<String, List<AlertLog>> _alertsByZone = {};
  Map<String, bool> _readAlerts = {}; // Track read status
  bool _isLoading = true;
  String? _selectedZoneId;
  bool _showUnreadOnly = true; // Show unread or all alerts

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
          _subscribeToAlerts();
        });
      });
    }

    return _buildNotificationsContent();
  }

  Widget _buildNotificationsContent() {
    final alerts = _getFilteredAlerts();
    final unreadCount = _getUnreadCount();

    return Scaffold(
      appBar: AppBar(
        title: const Text('CrowdSense'),
        actions: [
          Stack(
            children: [
              IconButton(
                icon: const Icon(Icons.notifications),
                onPressed: () {},
              ),
              if (unreadCount > 0)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 16,
                      minHeight: 16,
                    ),
                    child: Text(
                      unreadCount > 9 ? '9+' : '$unreadCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
      body: _isLoading && _zones.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _zones.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.notifications_none,
                    size: 64,
                    color: AppTheme.mutedForeground,
                  ),
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
                    'Create zones to receive alerts',
                    style: TextStyle(color: AppTheme.mutedForeground),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                // Tabs and Mark all read
                if (_zones.isNotEmpty && !_isLoading)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      border: Border(
                        bottom: BorderSide(color: AppTheme.border),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Expanded(
                                child: _buildTabButton(
                                  'Unread',
                                  _showUnreadOnly,
                                  () {
                                    setState(() {
                                      _showUnreadOnly = true;
                                    });
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _buildTabButton(
                                  'All',
                                  !_showUnreadOnly,
                                  () {
                                    setState(() {
                                      _showUnreadOnly = false;
                                    });
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        TextButton(
                          onPressed: unreadCount > 0 ? _markAllAsRead : null,
                          child: const Text('Mark all read'),
                        ),
                      ],
                    ),
                  ),
                // Zone selector
                if (_zones.isNotEmpty && !_isLoading)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: DropdownButtonFormField<String>(
                      value: _selectedZoneId,
                      decoration: const InputDecoration(
                        labelText: 'Select Zone',
                        border: OutlineInputBorder(),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
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
                        _subscribeToAlerts();
                      },
                    ),
                  ),
                // Alerts list
                Expanded(
                  child: _isLoading && _zones.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : _zones.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.notifications_none,
                                size: 64,
                                color: AppTheme.mutedForeground,
                              ),
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
                                'Create zones to receive alerts',
                                style: TextStyle(
                                  color: AppTheme.mutedForeground,
                                ),
                              ),
                            ],
                          ),
                        )
                      : alerts.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.notifications_off,
                                size: 64,
                                color: AppTheme.mutedForeground,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'No ${_showUnreadOnly ? "Unread " : ""}Alerts',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: AppTheme.foreground,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _showUnreadOnly
                                    ? 'All caught up!'
                                    : 'Alerts will appear here when congestion is detected',
                                style: TextStyle(
                                  color: AppTheme.mutedForeground,
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: alerts.length,
                          itemBuilder: (context, index) {
                            final alert = alerts[index];
                            final isRead = _readAlerts[alert.id] == true;
                            return _buildAlertCard(alert, isRead);
                          },
                        ),
                ),
              ],
            ),
      // No bottom nav for notifications page when shown as sheet
    );
  }

  void _subscribeToAlerts() {
    if (_selectedZoneId == null) return;

    DataService.subscribeToAlerts(_selectedZoneId!).listen((alerts) {
      setState(() {
        _alertsByZone[_selectedZoneId!] = alerts;
        // Initialize read status for new alerts
        for (var alert in alerts) {
          if (!_readAlerts.containsKey(alert.id)) {
            _readAlerts[alert.id] = false;
          }
        }
      });
    });
  }

  void _markAllAsRead() {
    setState(() {
      for (var alertList in _alertsByZone.values) {
        for (var alert in alertList) {
          _readAlerts[alert.id] = true;
        }
      }
    });
  }

  void _markAsRead(String alertId) {
    setState(() {
      _readAlerts[alertId] = true;
    });
  }

  List<AlertLog> _getFilteredAlerts() {
    final alerts = _selectedZoneId != null
        ? (_alertsByZone[_selectedZoneId] ?? [])
        : <AlertLog>[];

    if (_showUnreadOnly) {
      return alerts.where((alert) => _readAlerts[alert.id] != true).toList();
    }
    return alerts;
  }

  int _getUnreadCount() {
    int count = 0;
    for (var alertList in _alertsByZone.values) {
      count += alertList.where((alert) => _readAlerts[alert.id] != true).length;
    }
    return count;
  }

  // Original build method removed - now using _buildNotificationsContent

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
            _subscribeToAlerts();
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

  Widget _buildTabButton(String label, bool isSelected, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.muted : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              color: isSelected
                  ? AppTheme.foreground
                  : AppTheme.mutedForeground,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAlertCard(AlertLog alert, bool isRead) {
    final levelColor = AppTheme.getCongestionColor(alert.level);
    final levelText =
        {
          'low': 'Low',
          'medium': 'Medium',
          'high': 'High',
          'critical': 'Critical',
        }[alert.level] ??
        'Unknown';

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: isRead ? null : AppTheme.primary.withValues(alpha: 0.05),
      child: InkWell(
        onTap: () {
          _markAsRead(alert.id);
          _showAlertDetail(alert);
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      alert.zoneName,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: levelColor,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      levelText,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.people, size: 16, color: AppTheme.mutedForeground),
                  const SizedBox(width: 4),
                  Text(
                    '${alert.peopleCount} people',
                    style: TextStyle(
                      fontSize: 14,
                      color: AppTheme.mutedForeground,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Icon(
                    Icons.access_time,
                    size: 16,
                    color: AppTheme.mutedForeground,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${alert.waitingTimeMin} min wait',
                    style: TextStyle(
                      fontSize: 14,
                      color: AppTheme.mutedForeground,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _formatTime(alert.timestamp),
                style: TextStyle(fontSize: 12, color: AppTheme.mutedForeground),
              ),
              if (alert.screenshotBase64 != null ||
                  alert.screenshotUrl != null) ...[
                const SizedBox(height: 12),
                _buildScreenshot(alert),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showAlertDetail(AlertLog alert) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
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
                    'Alert Detail',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildDetailRow('Zone', alert.zoneName),
              _buildDetailRow('Timestamp', _formatFullTime(alert.timestamp)),
              _buildDetailRow('People Count', '${alert.peopleCount}'),
              _buildDetailRow('Level', alert.level.toUpperCase()),
              _buildDetailRow(
                'Estimated Waiting Time',
                '${alert.waitingTimeMin} minutes',
              ),
              if (alert.screenshotBase64 != null ||
                  alert.screenshotUrl != null) ...[
                const SizedBox(height: 16),
                const Text(
                  'Camera Snapshot',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                _buildScreenshot(alert),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppTheme.mutedForeground,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  String _formatFullTime(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}/${date.year}, ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')} ${date.hour >= 12 ? 'PM' : 'AM'}';
  }

  Widget _buildScreenshot(AlertLog alert) {
    return GestureDetector(
      onTap: () {
        // Show full screen image
        showDialog(
          context: context,
          builder: (context) => Dialog(
            child: Stack(
              children: [
                Center(
                  child: alert.screenshotBase64 != null
                      ? Image.memory(
                          base64Decode(alert.screenshotBase64!),
                          fit: BoxFit.contain,
                        )
                      : alert.screenshotUrl != null
                      ? Image.network(alert.screenshotUrl!, fit: BoxFit.contain)
                      : const SizedBox(),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
      child: Container(
        height: 150,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.border),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: alert.screenshotBase64 != null
              ? Image.memory(
                  base64Decode(alert.screenshotBase64!),
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      color: AppTheme.muted,
                      child: const Center(
                        child: Icon(Icons.broken_image, size: 48),
                      ),
                    );
                  },
                )
              : alert.screenshotUrl != null
              ? Image.network(
                  alert.screenshotUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      color: AppTheme.muted,
                      child: const Center(
                        child: Icon(Icons.broken_image, size: 48),
                      ),
                    );
                  },
                )
              : Container(
                  color: AppTheme.muted,
                  child: const Center(child: Icon(Icons.image, size: 48)),
                ),
        ),
      ),
    );
  }

  String _formatTime(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes} min ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours} hr ago';
    } else {
      return '${difference.inDays} days ago';
    }
  }
}
