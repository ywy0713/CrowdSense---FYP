import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/ai_service.dart';
import '../../services/local_camera_service.dart';
import '../../services/local_ai_service.dart';
import '../../services/firebase_monitoring_service.dart';
import '../../theme/app_theme.dart';
import '../../providers/active_camera_provider.dart';
import '../../components/bottom_nav.dart';
import 'camera_setup_page.dart';

class CameraListPage extends ConsumerStatefulWidget {
  const CameraListPage({super.key});

  @override
  ConsumerState<CameraListPage> createState() => _CameraListPageState();
}

class _CameraListPageState extends ConsumerState<CameraListPage> {
  List<ZoneData> _zones = [];
  bool _isLoading = true;
  String? _errorMessage;
  // Track monitoring status for each zone (from API)
  final Map<String, bool> _zoneMonitoringStatus = {};

  @override
  void initState() {
    super.initState();
    _loadZones();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Refresh monitoring status when page becomes visible
    if (_zones.isNotEmpty) {
      for (final zone in _zones) {
        _checkMonitoringStatus(zone.id);
      }
    }
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
          _isLoading = false;
        });
        // Check monitoring status for each zone
        for (final zone in zones) {
          _checkMonitoringStatus(zone.id);
        }
      } else {
        setState(() {
          _errorMessage = 'Not logged in';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to load cameras: $e';
        _isLoading = false;
      });
    }
  }

  // Check monitoring status from Firebase (for local mode) and Python API (for HTTP mode)
  Future<void> _checkMonitoringStatus(String zoneId) async {
    bool isMonitoring = false;
    
    // First check Firebase monitoring status (works for both local and HTTP modes)
    try {
      isMonitoring = await FirebaseMonitoringService.getMonitoringStatus(zoneId);
    } catch (e) {
      print('⚠️ Failed to check Firebase monitoring status for $zoneId: $e');
    }
    
    // Also check Python service status (for HTTP mode)
    if (!isMonitoring) {
      try {
        final baseUrl = AIService.baseUrl;
        final url = '$baseUrl/zones/$zoneId/count';
        
        final response = await http.get(
          Uri.parse(url),
        ).timeout(const Duration(seconds: 3));
        
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          isMonitoring = data['is_monitoring'] as bool? ?? false;
        }
      } catch (e) {
        // Python service might not be available for local mode, that's OK
        print('⚠️ Python service check failed for $zoneId (this is OK for local mode): $e');
      }
    }
    
    // Update state
    if (mounted) {
      setState(() {
        _zoneMonitoringStatus[zoneId] = isMonitoring;
      });
    }
  }

  Future<void> _activateCamera(ZoneData zone) async {
    // Check if using local mode or HTTP mode
    // 'local' mode uses Flutter camera package to access device camera
    // 'http' mode uses Python service to access computer camera via HTTP stream
    final isLocalMode = zone.cameraUrl == 'local';
    final isHttpMode = zone.cameraUrl != null && zone.cameraUrl!.startsWith('http');

    // Add to active cameras
    ref.read(activeCameraProvider.notifier).addActiveCamera(zone.id);

    if (isLocalMode) {
      // Local mode - use device camera directly via Flutter camera package
      try {
        if (mounted) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => const Center(
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Starting local camera...'),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        // Initialize local camera
        final cameraInitialized = await LocalCameraService.initialize();
        
        if (!mounted) return;
        Navigator.of(context).pop(); // Dismiss loading dialog

        if (cameraInitialized) {
          // Update monitoring status in Firebase
          await FirebaseMonitoringService.setMonitoringStatus(zone.id, true);
          
          // Update local state immediately
          setState(() {
            _zoneMonitoringStatus[zone.id] = true;
          });
          
          // Reload zones to update status and refresh UI
          await _loadZones();
          
          // Double-check Firebase status to ensure consistency
          await _checkMonitoringStatus(zone.id);
          
          // Navigate to surveillance page
          if (mounted) {
            await Future.delayed(const Duration(milliseconds: 500));
            if (mounted) {
              context.go('/surveillance');
            }
          }
          
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('✅ Camera "${zone.name}" activated (Local Mode)!'),
                backgroundColor: Colors.green,
                duration: const Duration(seconds: 2),
              ),
            );
          }
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('❌ Failed to initialize local camera. Please check camera permissions.'),
              backgroundColor: Colors.red,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          Navigator.of(context).pop(); // Dismiss loading dialog
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('❌ Error starting local camera: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } else if (isHttpMode) {
      // HTTP mode - use Python service to access computer camera
      try {
        if (mounted) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => Center(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      const Text('Connecting to HTTP camera...'),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        // For HTTP mode, start Python service monitoring
        // This ensures proper camera resource management and people detection
        final success = await AIService.startZoneMonitoring(zone.id, zone);
        if (!mounted) return;
        Navigator.of(context).pop(); // Dismiss loading dialog
        
        if (!success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('❌ Failed to start Python service. Please ensure Python service is running.'),
              backgroundColor: Colors.red,
            ),
          );
          return;
        }
        
        // Update monitoring status in Firebase
        await FirebaseMonitoringService.setMonitoringStatus(zone.id, true);
        
        if (!mounted) return;
        
        // Update local state immediately
        setState(() {
          _zoneMonitoringStatus[zone.id] = true;
        });
        
        // Reload zones to update status and refresh UI
        await _loadZones();
        
        // Double-check Firebase status to ensure consistency
        await _checkMonitoringStatus(zone.id);
        
        // Navigate to surveillance page
        if (mounted) {
          await Future.delayed(const Duration(milliseconds: 500));
          if (mounted) {
            context.go('/surveillance');
          }
        }
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✅ Camera "${zone.name}" activated (HTTP Mode)!'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          Navigator.of(context).pop(); // Dismiss loading dialog
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('❌ Error activating camera: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } else {
      // Fallback - should not reach here
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('❌ Unknown camera mode'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }


  Future<void> _deactivateCamera(String zoneId) async {
    try {
      // Get zone to check if it's local mode
      final zone = _zones.firstWhere((z) => z.id == zoneId, orElse: () => _zones.first);
      final isLocalMode = zone.cameraUrl == 'local';
      final isHttpMode = zone.cameraUrl != null && zone.cameraUrl!.startsWith('http');
      
      if (isLocalMode) {
        // Local mode - dispose camera and update Firebase
        await LocalCameraService.stopPreview();
        await LocalCameraService.dispose();
        LocalAIService.dispose();
        await FirebaseMonitoringService.setMonitoringStatus(zoneId, false);
      } else if (isHttpMode) {
        // HTTP mode - stop Python AI service to release camera
        try {
          final success = await AIService.stopZoneMonitoring(zoneId);
          if (!success) {
            print('ℹ️ HTTP mode zone $zoneId may not have Python monitoring task (this is OK if using external stream)');
          } else {
            print('✅ Python service stopped successfully for zone $zoneId');
          }
        } catch (e) {
          // Handle 404 error gracefully for HTTP mode (zone may not be in monitoring_tasks)
          if (e.toString().contains('404')) {
            print('ℹ️ HTTP mode zone $zoneId not in Python monitoring tasks (using external stream, this is OK)');
          } else {
            print('⚠️ Error stopping Python service: $e');
          }
        }
        
        // Check if using external camera server and stop it if no other zones are using it
        // IMPORTANT: Don't stop external camera server immediately - it will be stopped
        // by Python service's stop_monitoring endpoint if no zones are using it
        // This prevents issues with rapid deactivate/activate cycles
        if (AIService.isExternalCameraServerUrl(zone.cameraUrl)) {
          try {
            // Check if any other zones are using external camera server
            // Check both Firebase and Python service status
            final activeZones = await FirebaseMonitoringService.getActiveZones();
            final otherZonesUsingExternal = activeZones.where((id) => id != zoneId).toList();
            
            // Also check Python service for active monitoring tasks
            final pythonStatus = await AIService.getStatus();
            final pythonActiveZones = pythonStatus?['active_zones'] as List<dynamic>? ?? [];
            final pythonOtherZones = pythonActiveZones.where((id) => id.toString() != zoneId).toList();
            
            if (otherZonesUsingExternal.isEmpty && pythonOtherZones.isEmpty) {
              // No other zones using external camera server, stop it
              // But wait a bit to ensure monitoring task is fully stopped
              await Future.delayed(const Duration(milliseconds: 500));
              print('🛑 Stopping external camera server as no other zones are using it');
              await AIService.stopExternalCameraServer();
            } else {
              print('ℹ️ Other zones are using external camera server, keeping it running');
              print('   Firebase active zones: $otherZonesUsingExternal');
              print('   Python active zones: $pythonOtherZones');
            }
          } catch (e) {
            print('⚠️ Error checking/stopping external camera server: $e');
            // Don't fail deactivation if external camera server check fails
          }
        }
        
        await FirebaseMonitoringService.setMonitoringStatus(zoneId, false);
      }
      
      // Remove only this specific zone from active cameras
      ref.read(activeCameraProvider.notifier).removeActiveCamera(zoneId);
      
      // Update monitoring status immediately
      setState(() {
        _zoneMonitoringStatus[zoneId] = false;
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Camera deactivated successfully'),
            backgroundColor: Colors.green,
          ),
        );
        // Reload to refresh status from API
        _loadZones();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error deactivating camera: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _deleteCamera(String zoneId, String zoneName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Camera'),
        content: Text('Are you sure you want to delete "$zoneName"? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              try {
                final user = AuthService.getCurrentUser();
                if (user == null) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('User not logged in'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                  return;
                }

                // Stop AI service first
                await AIService.stopZoneMonitoring(zoneId);
                
                // Delete zone from database
                await DataService.deleteZone(user.uid, zoneId);
                
                // If this was an active camera, remove it
                final activeCameras = ref.read(activeCameraProvider);
                if (activeCameras.contains(zoneId)) {
                  ref.read(activeCameraProvider.notifier).removeActiveCamera(zoneId);
                }
                
                // Immediately remove from local list for instant UI update
                if (mounted) {
                  setState(() {
                    _zones.removeWhere((zone) => zone.id == zoneId);
                    _zoneMonitoringStatus.remove(zoneId);
                  });
                }
                
                // Then reload from database to ensure consistency
                if (mounted) {
                  await _loadZones();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Camera deleted successfully'),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error deleting camera: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                  // Reload zones on error to ensure UI is in sync
                  await _loadZones();
                }
              }
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  String _getConnectionTypeDisplay(ZoneData zone) {
    if (zone.cameraUrl == 'local') {
      return 'Local Camera';
    } else if (zone.cameraUrl != null && zone.cameraUrl!.startsWith('http')) {
      return 'HTTP Stream';
    }
    return 'Unknown';
  }

  @override
  Widget build(BuildContext context) {
    final activeCameras = ref.watch(activeCameraProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Camera Setup'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              // If no route to pop, navigate to dashboard
              context.go('/');
            }
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () async {
              final result = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const CameraSetupPage(),
                ),
              );
              if (result == true) {
                _loadZones();
              }
            },
            tooltip: 'Add Camera',
          ),
        ],
      ),
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
                          Icon(Icons.videocam_off, size: 64, color: AppTheme.mutedForeground),
                          const SizedBox(height: 16),
                          Text(
                            'No Cameras Setup',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.foreground,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Add your first camera to start monitoring',
                            style: TextStyle(color: AppTheme.mutedForeground),
                          ),
                          const SizedBox(height: 24),
                          ElevatedButton.icon(
                            onPressed: () async {
                              final result = await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => const CameraSetupPage(),
                                ),
                              );
                              if (result == true) {
                                _loadZones();
                              }
                            },
                            icon: const Icon(Icons.add),
                            label: const Text('Add Camera'),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _loadZones,
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          // Active cameras indicator (show if any are active)
                          if (activeCameras.isNotEmpty)
                            Container(
                              margin: const EdgeInsets.only(bottom: 16),
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.green.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.green),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.check_circle, color: Colors.green),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${activeCameras.length} Active Camera${activeCameras.length > 1 ? 's' : ''}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: Colors.green,
                                          ),
                                        ),
                                        Text(
                                          activeCameras.map((id) {
                                            try {
                                              return _zones.firstWhere((z) => z.id == id).name;
                                            } catch (e) {
                                              return id;
                                            }
                                          }).join(', '),
                                          style: TextStyle(
                                            fontSize: 14,
                                            color: AppTheme.mutedForeground,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          // Camera list - use monitoring status from API for each zone
                          ..._zones.map((zone) {
                            final isActive = _zoneMonitoringStatus[zone.id] ?? false;
                            return _buildCameraCard(zone, isActive);
                          }),
                        ],
                      ),
                    ),
      bottomNavigationBar: const BottomNav(currentIndex: 3),
    );
  }

  Widget _buildCameraCard(ZoneData zone, bool isActive) {
    final connectionType = _getConnectionTypeDisplay(zone);

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: isActive ? AppTheme.primary.withValues(alpha: 0.05) : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              zone.name,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: isActive ? AppTheme.primary : AppTheme.foreground,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isActive) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.green,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'ACTIVE',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),
                      _buildDetailRow(Icons.videocam, 'Connection', connectionType),
                      _buildDetailRow(Icons.tune, 'Thresholds', 'Low: ${zone.thresholds.low}, Med: ${zone.thresholds.medium}, High: ${zone.thresholds.high}, Critical: ${zone.thresholds.critical}'),
                      _buildDetailRow(Icons.speed, 'Service Speed', '${zone.averageServiceSpeed ?? 2.0} min/person'),
                      _buildDetailRow(
                        Icons.access_time, 
                        'Last Updated', 
                        _getLastUpdatedDisplay(zone),
                      ),
                      if (zone.peopleCount > 0)
                        _buildDetailRow(Icons.people, 'Current Count', '${zone.peopleCount}'),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                if (isActive)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _deactivateCamera(zone.id),
                      icon: const Icon(Icons.stop),
                      label: const Text('Deactivate'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.destructive,
                        side: BorderSide(color: AppTheme.destructive),
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _activateCamera(zone),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Activate'),
                    ),
                  ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.edit),
                  onPressed: () async {
                    final result = await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => CameraSetupPage(zoneId: zone.id),
                      ),
                    );
                    if (result == true) {
                      _loadZones();
                    }
                  },
                  tooltip: 'Edit',
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _deleteCamera(zone.id, zone.name),
                  tooltip: 'Delete',
                  color: AppTheme.destructive,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppTheme.mutedForeground),
          const SizedBox(width: 8),
          Text(
            '$label: ',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppTheme.mutedForeground,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _getLastUpdatedDisplay(ZoneData zone) {
    // Check monitoring status from API
    final isMonitoring = _zoneMonitoringStatus[zone.id] ?? false;
    
    // If not monitoring, show "Never"
    if (!isMonitoring) {
      return 'Never';
    }
    
    // If monitoring but lastUpdated is 0, show "Never"
    if (zone.lastUpdated == 0) {
      return 'Never';
    }
    
    // Otherwise show formatted time
    return _formatTime(zone.lastUpdated);
  }

  String _formatTime(int timestamp) {
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
    } else {
      return '${difference.inDays}d ago';
    }
  }
}

