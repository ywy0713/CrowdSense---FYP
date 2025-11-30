import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/ai_service.dart';
import '../../services/firebase_monitoring_service.dart';
import '../../core/config/firebase_config.dart';
import '../../theme/app_theme.dart';
import '../../components/bottom_nav.dart';
import '../camera/camera_setup_page.dart';
import '../notifications/notifications_page.dart';
import '../../providers/active_camera_provider.dart';
import 'threshold_dialog.dart';

class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});

  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  List<ZoneData> _zones = [];
  Map<String, StreamSubscription?> _zoneSubscriptions = {};
  Map<String, StreamSubscription?> _apiPollingSubscriptions = {}; // API polling for people count
  Map<String, bool> _zoneMonitoringStatus = {}; // Track monitoring status for each zone
  bool _isLoading = true;
  String? _errorMessage;
  String? _selectedZoneId;
  int _unreadNotificationCount = 0;
  Map<String, StreamSubscription> _notificationSubscriptions = {}; // Store subscriptions for each zone
  final AudioPlayer _audioPlayer = AudioPlayer();
  Map<String, String?> _lastThresholdLevel = {}; // Track last threshold level for each zone to avoid duplicate alerts
  Map<String, int> _zoneUnreadCounts = {}; // Track unread count per zone (instance variable)

  @override
  void initState() {
    super.initState();
    _loadZones();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Refresh data immediately when page becomes visible
    // This ensures we get the latest state from Python service
    // IMPORTANT: Don't reset _zoneMonitoringStatus here - keep previous state
    // until API confirms new state. This prevents showing "offline" briefly
    // when switching back to dashboard if camera is actually active.
    if (_zones.isNotEmpty) {
      _refreshAllZonesImmediately();
    }
  }

  // Immediately refresh all zones from API (don't wait for polling)
  Future<void> _refreshAllZonesImmediately() async {
    for (final zone in _zones) {
      _refreshZoneImmediately(zone.id);
    }
  }

  // Immediately refresh a single zone from API
  Future<void> _refreshZoneImmediately(String zoneId) async {
    try {
      final baseUrl = AIService.baseUrl;
      final url = '$baseUrl/zones/$zoneId/count';
      
      final response = await http.get(
        Uri.parse(url),
      ).timeout(const Duration(seconds: 3));
      
      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(response.body);
        final isMonitoring = data['is_monitoring'] as bool? ?? false;
        final peopleCount = data['peopleCount'] as int? ?? 0;
        final lastUpdated = data['lastUpdated'] as int? ?? 0;
        
        final index = _zones.indexWhere((z) => z.id == zoneId);
        if (index != -1) {
          setState(() {
            // Update monitoring status - explicitly set based on API response
            _zoneMonitoringStatus[zoneId] = isMonitoring;
            
            // Update zone data
            _zones[index] = ZoneData(
              id: _zones[index].id,
              name: _zones[index].name,
              peopleCount: peopleCount,
              lastUpdated: lastUpdated,
              thresholds: _zones[index].thresholds,
              cameraUrl: _zones[index].cameraUrl,
              rtspUrl: _zones[index].rtspUrl,
              averageServiceSpeed: _zones[index].averageServiceSpeed,
            );
          });
          print('🔄 Dashboard immediately refreshed zone $zoneId: count=$peopleCount, isMonitoring=$isMonitoring');
          
          // Check threshold and trigger notification if needed
          _checkThresholdAndNotify(zoneId, peopleCount, _zones[index].thresholds, _zones[index].name);
        }
      } else {
        // If API call fails, keep previous state (don't reset to false)
        // This prevents showing "offline" when switching back to dashboard
        // if the API call is just slow or temporarily unavailable
        // Only set to false if we don't have a previous state (first load)
        if (mounted) {
          final index = _zones.indexWhere((z) => z.id == zoneId);
          if (index != -1 && !_zoneMonitoringStatus.containsKey(zoneId)) {
            // Only set to false if we don't have a previous state
            setState(() {
              _zoneMonitoringStatus[zoneId] = false;
            });
          }
        }
      }
    } catch (e) {
      // If API call fails, keep previous state (don't reset to false)
      // This prevents showing "offline" when switching back to dashboard
      // if the API call is just slow or temporarily unavailable
      // Only set to false if we don't have a previous state (first load)
      if (mounted) {
        final index = _zones.indexWhere((z) => z.id == zoneId);
        if (index != -1 && !_zoneMonitoringStatus.containsKey(zoneId)) {
          // Only set to false if we don't have a previous state
          setState(() {
            _zoneMonitoringStatus[zoneId] = false;
          });
        }
      }
    }
  }

  @override
  void dispose() {
    // Cancel all subscriptions
    for (var subscription in _zoneSubscriptions.values) {
      subscription?.cancel();
    }
    _zoneSubscriptions.clear();
    for (var subscription in _apiPollingSubscriptions.values) {
      subscription?.cancel();
    }
    _apiPollingSubscriptions.clear();
    // Cancel all notification subscriptions
    for (var subscription in _notificationSubscriptions.values) {
      subscription.cancel();
    }
    _notificationSubscriptions.clear();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _loadZones() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final user = AuthService.getCurrentUser();
      if (user != null) {
        final zones = await DataService.getUserZones(user.uid);
        setState(() {
          _zones = zones;
          // Initialize all zones as not monitoring until API confirms status
          // This ensures "Never" is shown on startup if camera is deactivated
          for (var zone in zones) {
            _zoneMonitoringStatus[zone.id] = false;
          }
          if (zones.isNotEmpty) {
            _selectedZoneId = zones.first.id;
            _subscribeToZones(zones);
            // Immediately refresh all zones from API to get actual status
            // This prevents showing stale Firebase data on startup
            _refreshAllZonesImmediately();
          }
          _isLoading = false;
        });
      } else {
        setState(() {
          _errorMessage = 'Not logged in';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to load zones: $e';
        _isLoading = false;
      });
    }
  }

  void _subscribeToZones(List<ZoneData> zones) {
    // Cancel existing subscriptions
    for (var subscription in _zoneSubscriptions.values) {
      subscription?.cancel();
    }
    _zoneSubscriptions.clear();
    for (var subscription in _apiPollingSubscriptions.values) {
      subscription?.cancel();
    }
    _apiPollingSubscriptions.clear();
    // Initialize monitoring status for new zones only (don't reset existing ones)
    // This ensures "Never" is shown for new zones on startup, but preserves
    // existing state when re-subscribing (e.g., after page navigation)
    for (var zone in zones) {
      if (!_zoneMonitoringStatus.containsKey(zone.id)) {
        _zoneMonitoringStatus[zone.id] = false;
      }
    }

    // Subscribe to each zone (Firebase for zone config and local mode people count, API for HTTP mode people count)
    for (var zone in zones) {
      // Check if zone is local mode
      final isLocalMode = zone.cameraUrl == 'local';
      
      // Firebase subscription for zone config updates and people count (for local mode)
      final subscription = DataService.subscribeToZone(zone.id).listen((updatedZone) {
        if (updatedZone != null && mounted) {
          setState(() {
            final index = _zones.indexWhere((z) => z.id == updatedZone.id);
            if (index != -1) {
              // For local mode, use Firebase data for people count
              // For HTTP mode, keep API data (will be updated by API polling)
              final shouldUseFirebaseCount = isLocalMode;
              _zones[index] = ZoneData(
                id: updatedZone.id,
                name: updatedZone.name,
                peopleCount: shouldUseFirebaseCount ? updatedZone.peopleCount : _zones[index].peopleCount,
                lastUpdated: shouldUseFirebaseCount ? updatedZone.lastUpdated : _zones[index].lastUpdated,
                thresholds: updatedZone.thresholds,
                cameraUrl: updatedZone.cameraUrl,
                rtspUrl: updatedZone.rtspUrl,
                averageServiceSpeed: updatedZone.averageServiceSpeed,
              );
              
              // Update monitoring status from Firebase (for local mode)
              if (shouldUseFirebaseCount && updatedZone.lastUpdated > 0) {
                _zoneMonitoringStatus[zone.id] = true;
              }
            }
          });
        }
      });
      _zoneSubscriptions[zone.id] = subscription;
      
      // Also subscribe to FirebaseMonitoringService for real-time updates (local mode)
      if (isLocalMode) {
        FirebaseMonitoringService.subscribeToZoneCount(zone.id).listen((data) {
          if (data != null && mounted) {
            setState(() {
              final index = _zones.indexWhere((z) => z.id == zone.id);
              if (index != -1) {
                _zones[index] = ZoneData(
                  id: _zones[index].id,
                  name: _zones[index].name,
                  peopleCount: data['peopleCount'] as int? ?? 0,
                  lastUpdated: data['lastUpdated'] as int? ?? 0,
                  thresholds: _zones[index].thresholds,
                  cameraUrl: _zones[index].cameraUrl,
                  rtspUrl: _zones[index].rtspUrl,
                  averageServiceSpeed: _zones[index].averageServiceSpeed,
                );
                _zoneMonitoringStatus[zone.id] = data['isMonitoring'] as bool? ?? false;
              }
            });
          }
        });
      }
      
      // API polling for people count (for HTTP mode only)
      if (!isLocalMode) {
        _startApiPollingForZone(zone.id);
      }
    }

    // Subscribe to notifications count
    _subscribeToNotifications(zones);
  }
  
  void _startApiPollingForZone(String zoneId) {
    _apiPollingSubscriptions[zoneId]?.cancel();
    
    final baseUrl = AIService.baseUrl;
    print('🔍 Dashboard polling URL for $zoneId: $baseUrl/zones/$zoneId/count (baseUrl=$baseUrl)');
    
    // Poll API every 5 seconds for people count (reduced frequency to avoid spam)
    _apiPollingSubscriptions[zoneId] = Stream.periodic(const Duration(seconds: 5)).asyncMap((_) async {
      try {
        final url = '$baseUrl/zones/$zoneId/count';
        
        final response = await http.get(
          Uri.parse(url),
        ).timeout(const Duration(seconds: 8)); // Increased timeout to handle slow responses
        
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          
          // Always parse and return data, even if monitoring is false
          final isMonitoring = data['is_monitoring'] as bool? ?? false;
          final peopleCount = data['peopleCount'] as int? ?? 0;
          final lastUpdated = data['lastUpdated'] as int? ?? 0;
          
          // Debug: Always log successful API response to verify connection
          final currentZone = _zones.firstWhere((z) => z.id == zoneId, orElse: () => ZoneData(id: '', name: '', peopleCount: -1, lastUpdated: 0, thresholds: ZoneThresholds(low: 0, medium: 0, high: 0, critical: 0)));
          print('📥 Dashboard API success: zone=$zoneId, count=$peopleCount (current=${currentZone.peopleCount}), isMonitoring=$isMonitoring, lastUpdated=$lastUpdated, response=${response.body}');
          
          // Python API returns timestamp in milliseconds already (time.time() * 1000)
          // No conversion needed - Python already returns milliseconds
          
          return {
            'zoneId': zoneId,
            'peopleCount': peopleCount,
            'lastUpdated': lastUpdated,
            'isMonitoring': isMonitoring,
          };
        } else {
          print('❌ Dashboard API returned status ${response.statusCode}: ${response.body}');
        }
      } catch (e) {
        // Suppress timeout errors - they're common and not critical
        // The next poll will retry automatically
        if (e.toString().contains('TimeoutException')) {
          // Timeout errors are silently ignored - they'll be retried on next poll
          return null;
        } else if (e.toString().contains('Connection refused') || e.toString().contains('SocketException')) {
          // Connection errors - log to help debug
          print('❌ Dashboard connection error (will retry silently): $e');
          print('   Make sure Python service is running at $baseUrl');
          return null;
        } else {
          // Only log other errors (not timeout or connection refused)
          print('⚠️ Dashboard API polling error: $e');
        }
      }
      return null;
    }).listen((data) {
      print('🔔 Dashboard API listener received: data=$data, mounted=$mounted');
      if (data != null && mounted) {
        final index = _zones.indexWhere((z) => z.id == data['zoneId']);
        print('🔔 Dashboard found zone at index: $index (total zones: ${_zones.length})');
        if (index != -1) {
          final previousCount = _zones[index].peopleCount;
          final newCount = data['peopleCount'] as int;
          final isMonitoring = data['isMonitoring'] as bool? ?? false;
          
          // Update monitoring status (for status display only)
          final zoneId = data['zoneId'] as String? ?? '';
          setState(() {
            if (zoneId.isNotEmpty) {
              _zoneMonitoringStatus[zoneId] = isMonitoring;
            }
          });
          
          // Always update people count and lastUpdated from API
          // We'll handle display logic in _buildStatusCard based on isMonitoring
          int lastUpdated = data['lastUpdated'] as int;
          
          // Always log when we receive data
          print('✅ Dashboard updating zone ${data['zoneId']}: count=$newCount (was $previousCount), isMonitoring=$isMonitoring, lastUpdated=$lastUpdated');
          
          setState(() {
            // Always update data from API
            _zones[index] = ZoneData(
              id: _zones[index].id,
              name: _zones[index].name,
              peopleCount: newCount,
              lastUpdated: lastUpdated,
              thresholds: _zones[index].thresholds,
              cameraUrl: _zones[index].cameraUrl,
              rtspUrl: _zones[index].rtspUrl,
              averageServiceSpeed: _zones[index].averageServiceSpeed,
            );
          });
          print('✅ Dashboard UI updated: zone ${data['zoneId']} count=${_zones[index].peopleCount}, lastUpdated=${_zones[index].lastUpdated}');
          
          // Check threshold and trigger notification if needed
          final zoneIdStr = data['zoneId']?.toString() ?? '';
          if (zoneIdStr.isNotEmpty) {
            _checkThresholdAndNotify(zoneIdStr, newCount, _zones[index].thresholds, _zones[index].name);
            _savePeopleCountToFirebase(zoneIdStr, newCount, previousCount);
          }
        }
        // Removed excessive logging for null data (timeouts are expected)
      }
    }, onError: (error) {
      print('❌ Dashboard API polling stream error: $error');
    });
  }
  
  Map<String, DateTime?> _lastSaveTimes = {};
  Map<String, int?> _lastSavedCounts = {};
  
  void _savePeopleCountToFirebase(String zoneId, int count, int previousCount) async {
    final now = DateTime.now();
    final lastSaveTime = _lastSaveTimes[zoneId];
    
    // Save conditions:
    // 1. Every 5 minutes (for analytics)
    // 2. When count changes significantly (difference >= 2)
    final shouldSave = lastSaveTime == null || 
                      now.difference(lastSaveTime).inMinutes >= 5 ||
                      (previousCount != count && (count - previousCount).abs() >= 2);
    
    if (shouldSave) {
      try {
        await DataService.updatePeopleCount(zoneId, count);
        _lastSaveTimes[zoneId] = now;
        _lastSavedCounts[zoneId] = count;
        print('💾 [Dashboard] Saved people count to Firebase: zone=$zoneId, count=$count');
      } catch (e) {
        print('⚠️ [Dashboard] Failed to save people count to Firebase: $e');
      }
    }
  }

  void _subscribeToNotifications(List<ZoneData> zones) {
    // Cancel all existing subscriptions
    for (var subscription in _notificationSubscriptions.values) {
      subscription.cancel();
    }
    _notificationSubscriptions.clear();
    
    if (zones.isEmpty) {
      setState(() {
        _unreadNotificationCount = 0;
      });
      return;
    }

    // Subscribe to alerts from all zones and count recent ones
    final database = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: FirebaseConfig.databaseURL,
    ).ref();
    
    // Reset count
    setState(() {
      _unreadNotificationCount = 0;
    });

    // Track unread count across all zones using instance variable
    _zoneUnreadCounts.clear();
    
    for (var zone in zones) {
      final subscription = database.child('alerts/${zone.id}').onValue.listen((event) {
        if (mounted) {
          int unreadCount = 0;
          
          if (event.snapshot.exists) {
            final alerts = event.snapshot.value as Map<dynamic, dynamic>?;
            if (alerts != null) {
              // Count recent unread alerts (within last 24 hours)
              final now = DateTime.now().millisecondsSinceEpoch;
              final oneDayAgo = now - (24 * 60 * 60 * 1000);
              
              alerts.forEach((key, value) {
                final alert = value as Map<dynamic, dynamic>;
                final timestamp = alert['timestamp'] as int? ?? 0;
                final read = alert['read'] as bool? ?? false;
                // Only count unread alerts within last 24 hours
                if (timestamp > oneDayAgo && !read) {
                  unreadCount++;
                }
              });
            }
          }
          
          // Update count for this zone (using instance variable)
          _zoneUnreadCounts[zone.id] = unreadCount;
          
          // Calculate total unread count across all zones
          final totalUnreadCount = _zoneUnreadCounts.values.fold(0, (sum, count) => sum + count);
          setState(() {
            _unreadNotificationCount = totalUnreadCount;
          });
        }
      });
      
      // Store subscription for this zone (important: store all, not just the last one)
      _notificationSubscriptions[zone.id] = subscription;
    }
  }

  String _getCongestionLevel(int count, ZoneThresholds thresholds) {
    if (count >= thresholds.critical) return 'critical';
    if (count >= thresholds.high) return 'high';
    if (count >= thresholds.medium) return 'medium';
    return 'low';
  }

  void _checkThresholdAndNotify(String zoneId, int count, ZoneThresholds thresholds, String zoneName) {
    final currentLevel = _getCongestionLevel(count, thresholds);
    final lastLevel = _lastThresholdLevel[zoneId];
    
    // Only notify when threshold reaches high or critical, and only if it's a new level (not already notified)
    if ((currentLevel == 'high' || currentLevel == 'critical') && currentLevel != lastLevel) {
      _lastThresholdLevel[zoneId] = currentLevel;
      
      // Find zone to get averageServiceSpeed for waiting time calculation
      final zone = _zones.firstWhere((z) => z.id == zoneId, orElse: () => ZoneData(
        id: zoneId,
        name: zoneName,
        peopleCount: count,
        lastUpdated: DateTime.now().millisecondsSinceEpoch,
        thresholds: thresholds,
        cameraUrl: null,
        rtspUrl: null,
        averageServiceSpeed: null,
      ));
      
      // Calculate waiting time
      final waitingTimeMin = _calculateWaitingTime(count, zone.averageServiceSpeed).round();
      
      // Generate notification message
      final levelText = currentLevel == 'critical' ? 'Critical' : 'High';
      final message = 'People count has reached $levelText threshold!';
      
      // Play sound notification
      _playNotificationSound();
      
      // Update notification badge
      setState(() {
        _unreadNotificationCount++;
      });
      
      // Show modal alert
      _showThresholdAlertModal(zoneName, count, currentLevel, thresholds);
      
      // Save alert to Firebase with all required data
      _saveAlertToFirebase(zoneId, count, currentLevel, zoneName, waitingTimeMin, message);
    } else if (currentLevel != 'high' && currentLevel != 'critical') {
      // Reset last level when count drops below high/critical
      _lastThresholdLevel[zoneId] = currentLevel;
    }
  }

  Future<void> _playNotificationSound() async {
    try {
      // Use system sound (works on emulator)
      SystemSound.play(SystemSoundType.alert);
      print('🔔 Played notification sound');
    } catch (e) {
      print('⚠️ Could not play notification sound: $e');
      // Try audio player as fallback
      try {
        await _audioPlayer.play(AssetSource('sounds/notification.mp3'));
      } catch (e2) {
        print('⚠️ Could not play audio file: $e2');
      }
    }
  }

  void _showThresholdAlertModal(String zoneName, int count, String level, ZoneThresholds thresholds) {
    // Show dialog if context is available
    if (!mounted) return;
    
    final levelText = level == 'critical' ? 'Critical' : 'High';
    final levelColor = level == 'critical' ? Colors.red : Colors.orange;
    final thresholdValue = level == 'critical' ? thresholds.critical : thresholds.high;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning, color: levelColor, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Threshold Alert',
                style: TextStyle(
                  color: levelColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Zone: $zoneName',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'People count has reached $levelText threshold!',
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: levelColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Current Count:',
                    style: TextStyle(fontSize: 14),
                  ),
                  Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: levelColor,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Threshold: $levelText ≤ $thresholdValue',
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.mutedForeground,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveAlertToFirebase(String zoneId, int count, String level, String zoneName, int waitingTimeMin, String message) async {
    try {
      final database = FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: FirebaseConfig.databaseURL,
      ).ref();
      
      final alertRef = database.child('alerts/$zoneId').push();
      await alertRef.set({
        'zoneId': zoneId,
        'zoneName': zoneName,
        'peopleCount': count, // Use 'peopleCount' instead of 'count' to match AlertLog
        'level': level,
        'waitingTimeMin': waitingTimeMin,
        'message': message,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'read': false,
      });
      
      print('✅ Alert saved to Firebase: zone=$zoneId, zoneName=$zoneName, count=$count, level=$level, waitingTime=$waitingTimeMin min, message=$message');
    } catch (e) {
      print('⚠️ Failed to save alert to Firebase: $e');
    }
  }


  double _calculateWaitingTime(int count, double? serviceSpeed) {
    // serviceSpeed is now in minutes/person (not people/min)
    // waitingTime = count * serviceSpeed (e.g., 10 people * 2 min/person = 20 minutes)
    if (serviceSpeed == null || serviceSpeed <= 0) return 0;
    return (count * serviceSpeed).clamp(0, 999);
  }

  double _calculateLoadPercentage(int count, ZoneThresholds thresholds) {
    if (thresholds.critical <= 0) return 0;
    return (count / thresholds.critical * 100).clamp(0, 100);
  }

  Future<void> _showThresholdDialog(ZoneData zone) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => ThresholdDialog(zone: zone),
    );
    if (result == true) {
      _loadZones(); // Reload zones after update
    }
  }

  Future<void> _editZone(ZoneData zone) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => CameraSetupPage(zoneId: zone.id),
      ),
    );
    if (result == true) {
      _loadZones(); // Reload zones after update
    }
  }

  int _getUnreadNotificationCount() {
    return _unreadNotificationCount;
  }

  void _showNotificationsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, scrollController) => Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              // Handle bar
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.mutedForeground.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Notifications content
              Expanded(
                child: const NotificationsPage(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNotificationIcon(BuildContext context) {
    final unreadCount = _getUnreadNotificationCount();
    
    return Stack(
      children: [
        IconButton(
          icon: const Icon(Icons.notifications),
          onPressed: () => _showNotificationsSheet(context),
          tooltip: 'Notifications',
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
    );
  }

  @override
  Widget build(BuildContext context) {
    // Use user-selected zone, or fallback to active camera from provider
    // User selection takes priority over active camera provider
    final activeCameras = ref.watch(activeCameraProvider);
    final activeCameraId = activeCameras.isNotEmpty ? activeCameras.first : null;
    // Use _selectedZoneId first (user selection), then fallback to activeCameraId
    final activeZoneId = _selectedZoneId ?? activeCameraId;
    
    final selectedZone = _zones.firstWhere(
      (zone) => zone.id == activeZoneId,
      orElse: () => _zones.isNotEmpty ? _zones.first : ZoneData(
        id: '',
        name: '',
        peopleCount: 0,
        lastUpdated: 0,
        thresholds: ZoneThresholds(low: 20, medium: 50, high: 80, critical: 120),
      ),
    );

    // Update selected zone ID if active camera changed AND user hasn't manually selected a zone
    // Only auto-update if _selectedZoneId is null (no manual selection)
    if (activeCameraId != null && _selectedZoneId == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _selectedZoneId = activeCameraId;
          });
        }
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('CrowdSense'),
        actions: [
          // Notification icon with badge
          _buildNotificationIcon(context),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadZones,
            tooltip: 'Refresh',
          ),
        ],
      ),
      bottomNavigationBar: const BottomNav(currentIndex: 0),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline, size: 48, color: AppTheme.destructive),
                      const SizedBox(height: 16),
                      Text(_errorMessage!),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _loadZones,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : _zones.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.location_on_outlined, size: 64, color: AppTheme.mutedForeground),
                          const SizedBox(height: 16),
                          Text(
                            'No Monitoring Zones',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.foreground,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Please create and link monitoring zones first',
                            style: TextStyle(color: AppTheme.mutedForeground),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _loadZones,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Zone selector (same design as analytics page)
                            if (_zones.length > 1)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: DropdownButtonFormField<String>(
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
                                  },
                                ),
                              ),
                            // WAITING ZONE Card (matches image design)
                            _buildWaitingZoneCard(selectedZone),
                            const SizedBox(height: 16),
                            // Estimated Waiting Time Section
                            _buildWaitingTimeSection(selectedZone),
                            const SizedBox(height: 16),
                            // Tips and Status Cards
                            Row(
                              children: [
                                Expanded(child: _buildTipsCard()),
                                const SizedBox(width: 12),
                                Expanded(child: _buildStatusCard(selectedZone)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
    );
  }

  Widget _buildWaitingZoneCard(ZoneData zone) {
    final level = _getCongestionLevel(zone.peopleCount, zone.thresholds);
    final levelColor = AppTheme.getCongestionColor(level);
    final levelText = {
      'low': 'Low',
      'medium': 'Medium',
      'high': 'High',
      'critical': 'Critical',
    }[level] ?? 'Unknown';

    return GestureDetector(
      onTap: () => _showThresholdDialog(zone),
      child: Card(
        color: levelColor.withValues(alpha: 0.2),
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    zone.name.toUpperCase(),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.foreground,
                      letterSpacing: 1.2,
                    ),
                  ),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 20),
                        onPressed: _loadZones,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.filter_list, size: 20),
                        onPressed: () => _editZone(zone),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Last updated ${_getLastUpdatedDisplay(zone)}',
                style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.mutedForeground,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    '${zone.peopleCount}',
                    style: TextStyle(
                      fontSize: 48,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.foreground,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: levelColor,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      levelText,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.foreground,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWaitingTimeSection(ZoneData zone) {
    final waitingTime = _calculateWaitingTime(
      zone.peopleCount,
      zone.averageServiceSpeed,
    );
    final loadPercentage = _calculateLoadPercentage(
      zone.peopleCount,
      zone.thresholds,
    );

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Estimated Waiting Time',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.foreground,
                  ),
                ),
                Icon(Icons.access_time, color: AppTheme.mutedForeground),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              '${waitingTime.toStringAsFixed(0)}m',
              style: TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.bold,
                color: AppTheme.foreground,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: loadPercentage / 100,
                    backgroundColor: AppTheme.muted,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      loadPercentage >= 80 ? AppTheme.destructive : AppTheme.primary,
                    ),
                    minHeight: 8,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Load ${loadPercentage.toStringAsFixed(0)}% of critical',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.mutedForeground,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTipsCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tips',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppTheme.foreground,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Tap the people card to set thresholds.',
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.mutedForeground,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard(ZoneData zone) {
    // Check monitoring status from map
    // IMPORTANT: Don't infer from lastUpdated - only use explicit API response
    // Default to false (offline) if status is not yet known
    final isMonitoring = _zoneMonitoringStatus[zone.id] ?? false;
    
    // If not monitoring, always show offline
    if (!isMonitoring) {
      return Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Status',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.foreground,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'System offline.',
                style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.mutedForeground,
                ),
              ),
            ],
          ),
        ),
      );
    }
    
    // If monitoring, check if updated within last 20 seconds
    // Only check if we know it's monitoring (don't infer)
    final now = DateTime.now().millisecondsSinceEpoch;
    final timeSinceUpdate = now - zone.lastUpdated;
    final isActive = isMonitoring && zone.lastUpdated > 0 && timeSinceUpdate < 20000; // Active if monitoring and updated within last 20 seconds

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Status',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppTheme.foreground,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              isActive ? 'System online. Streaming updates.' : 'System offline.',
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.mutedForeground,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getLastUpdatedDisplay(ZoneData zone) {
    // Check monitoring status from map only
    // IMPORTANT: Don't infer from lastUpdated - only use explicit API response
    // Default to false (Never) if status is not yet known
    final isMonitoring = _zoneMonitoringStatus[zone.id] ?? false;
    
    if (!isMonitoring) {
      return 'Never';
    }
    
    // If monitoring, show actual time
    return _formatTime(zone.lastUpdated);
  }

  String _formatTime(int timestamp) {
    if (timestamp == 0) return 'Never';
    
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inSeconds < 1) {
      return 'Just now';
    } else if (difference.inSeconds < 60) {
      return '${difference.inSeconds}s ago';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}d ago';
    } else {
      // For older updates, show the actual date
      return '${date.day}/${date.month}/${date.year}';
    }
  }
}
