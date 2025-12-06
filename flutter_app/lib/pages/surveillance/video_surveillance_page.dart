import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:camera/camera.dart';
import 'package:video_player/video_player.dart';
import 'dart:async' show StreamSubscription, TimeoutException;
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/ai_service.dart';
import '../../services/local_camera_service.dart';
import '../../services/local_ai_service.dart';
import '../../services/firebase_monitoring_service.dart';
import '../../theme/app_theme.dart';
import '../../components/bottom_nav.dart';
import '../../providers/active_camera_provider.dart';

// WebView for mobile platforms
import 'package:webview_flutter/webview_flutter.dart';

class VideoSurveillancePage extends ConsumerStatefulWidget {
  const VideoSurveillancePage({super.key});

  @override
  ConsumerState<VideoSurveillancePage> createState() => _VideoSurveillancePageState();
}

class _VideoSurveillancePageState extends ConsumerState<VideoSurveillancePage> {
  List<ZoneData> _zones = [];
  String? _selectedZoneId;
  bool _isLoading = true;
  bool _hasShownStreamError = false; // Track if we've shown stream error to avoid spam
  
  // Multiple camera support - maintain controllers for each zone
  Map<String, WebViewController> _webViewControllers = {};
  Map<String, VideoPlayerController> _videoPlayerControllers = {};
  Map<String, CameraController> _cameraControllers = {};
  Map<String, bool> _streamingStatus = {}; // Track streaming status per zone
  
  // Real-time people count per zone
  Map<String, int> _peopleCounts = {};
  Map<String, StreamSubscription<ZoneData?>> _zoneSubscriptions = {};
  Map<String, StreamSubscription<Map<String, dynamic>?>> _apiPollingSubscriptions = {};

  @override
  void initState() {
    super.initState();
    _loadZones();
    // Note: Streaming will be started after zones are loaded in _loadZones()
  }

  @override
  void dispose() {
    // Dispose all controllers
    _webViewControllers.clear(); // WebView controllers don't need explicit disposal
    for (var controller in _videoPlayerControllers.values) {
      controller.dispose();
    }
    for (var controller in _cameraControllers.values) {
      controller.dispose();
    }
    
    // Cancel all subscriptions
    for (var subscription in _zoneSubscriptions.values) {
      subscription.cancel();
    }
    for (var subscription in _apiPollingSubscriptions.values) {
      subscription.cancel();
    }
    
    _webViewControllers.clear();
    _videoPlayerControllers.clear();
    _cameraControllers.clear();
    _zoneSubscriptions.clear();
    _apiPollingSubscriptions.clear();
    
    // Dispose local services
    LocalCameraService.dispose();
    LocalAIService.dispose();
    
    // Note: AI service monitoring continues in background
    super.dispose();
  }


  Future<void> _loadZones() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final user = AuthService.getCurrentUser();
      if (user != null) {
        final zones = await DataService.getUserZones(user.uid);
        
        // Check for active cameras from provider (includes local and HTTP modes)
        final activeCameras = ref.read(activeCameraProvider);
        
        // Check which zones are actually active in Python service (for HTTP mode only)
        List<String> actuallyActiveZones = [];
        try {
          final status = await AIService.getStatus();
          if (status != null) {
            actuallyActiveZones = (status['active_zones'] as List<dynamic>? ?? [])
                .map((e) => e.toString())
                .toList();
          }
        } catch (e) {
          print('⚠️ Failed to check active zones: $e');
        }
        
        // Also check Firebase monitoring status for all zones (includes local mode)
        Set<String> firebaseActiveZones = {};
        for (var zone in zones) {
          try {
            final isMonitoring = await FirebaseMonitoringService.getMonitoringStatus(zone.id);
            if (isMonitoring) {
              firebaseActiveZones.add(zone.id);
            }
          } catch (e) {
            print('⚠️ Failed to check Firebase monitoring status for ${zone.id}: $e');
          }
        }
        
        // Combine active zones: from provider, Firebase, and Python service
        final allActiveZones = activeCameras.union(firebaseActiveZones).union(actuallyActiveZones.toSet());
        
        setState(() {
          _zones = zones;
          if (zones.isNotEmpty) {
            // Select from all active zones (local, HTTP, or Python service)
            if (allActiveZones.isNotEmpty) {
              // Prefer active camera from provider if available
              if (activeCameras.isNotEmpty) {
                final firstActive = activeCameras.first;
                if (allActiveZones.contains(firstActive) && zones.any((z) => z.id == firstActive)) {
                  _selectedZoneId = firstActive;
                } else if (allActiveZones.isNotEmpty) {
                  // Use first active zone from any source
                  _selectedZoneId = allActiveZones.first;
                } else {
                  _selectedZoneId = null;
                }
              } else if (allActiveZones.isNotEmpty) {
                _selectedZoneId = allActiveZones.first;
              } else {
                _selectedZoneId = null;
              }
            } else {
              // No active zones
              _selectedZoneId = null;
            }
            
            // Start streaming for selected zone if it's active
            // Use a small delay to ensure UI is ready
            if (_selectedZoneId != null) {
              Future.delayed(const Duration(milliseconds: 500), () {
                if (mounted && _selectedZoneId != null) {
                  _startStreaming(_selectedZoneId!);
                }
              });
            }
          }
          _isLoading = false;
        });
        
        // Subscribe to real-time people count updates for all active zones
        for (var zoneId in allActiveZones) {
          _subscribeToPeopleCount(zoneId);
        }
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<List<String>> _getActiveZones() async {
    try {
      // Get active zones from Firebase (includes local and HTTP modes)
      final firebaseActiveZones = await FirebaseMonitoringService.getActiveZones();
      
      // Also get active zones from Python service (for HTTP mode)
      List<String> pythonActiveZones = [];
    try {
      final status = await AIService.getStatus();
      if (status != null) {
          pythonActiveZones = (status['active_zones'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList();
      }
      } catch (e) {
        print('⚠️ Failed to get Python active zones: $e');
      }
      
      // Combine both sources
      return firebaseActiveZones.toSet().union(pythonActiveZones.toSet()).toList();
    } catch (e) {
      print('⚠️ Failed to get active zones: $e');
    }
    return [];
  }

  Future<void> _deactivateCamera(String zoneId) async {
    try {
      // Get zone to check if it's local mode
      final zone = _zones.firstWhere((z) => z.id == zoneId, orElse: () => _zones.first);
      final isLocalMode = zone.cameraUrl == 'local';
      final isHttpMode = zone.cameraUrl != null && zone.cameraUrl!.startsWith('http');
      
      if (isLocalMode) {
        // Local mode - stop camera preview and dispose resources
        await LocalCameraService.stopPreview();
        await LocalCameraService.dispose();
        LocalAIService.dispose();
        // Update Firebase monitoring status
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
        
        // Update Firebase monitoring status
        await FirebaseMonitoringService.setMonitoringStatus(zoneId, false);
      }
      
      // Remove from active cameras
      ref.read(activeCameraProvider.notifier).removeActiveCamera(zoneId);
      
      // Dispose controllers for this zone
      _webViewControllers.remove(zoneId);
      _videoPlayerControllers[zoneId]?.dispose();
      _videoPlayerControllers.remove(zoneId);
      _cameraControllers[zoneId]?.dispose();
      _cameraControllers.remove(zoneId);
      
      // Update streaming status
      setState(() {
        _streamingStatus[zoneId] = false;
        // If this was the selected zone, clear selection
        if (_selectedZoneId == zoneId) {
          _selectedZoneId = null;
        }
      });
      
      // Reload zones to update active status
      _loadZones();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Camera deactivated successfully'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      print('❌ Error deactivating camera: $e');
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

  void _subscribeToPeopleCount(String zoneId) {
    // Cancel existing subscriptions for this zone
    _zoneSubscriptions[zoneId]?.cancel();
    _apiPollingSubscriptions[zoneId]?.cancel();
    
    print('📡 Subscribing to people count for zone: $zoneId (using API)');
    
    // Use API polling directly (Python service provides data via API)
    _startApiPolling(zoneId);
    
    // Also try Firebase subscription as backup (if Firebase is available)
    _zoneSubscriptions[zoneId] = DataService.subscribeToZone(zoneId).listen((zone) {
      if (zone != null && mounted) {
        print('📥 Received Firebase update for zone $zoneId: peopleCount=${zone.peopleCount}');
        setState(() {
          _peopleCounts[zoneId] = zone.peopleCount;
        });
      }
    }, onError: (error) {
      // Ignore Firebase errors - API polling is primary
      print('⚠️ Firebase subscription error for zone $zoneId (ignored, using API): $error');
    });
  }
  
  void _startApiPolling(String zoneId) {
    _apiPollingSubscriptions[zoneId]?.cancel();
    
    print('🔄 Starting API polling for zone: $zoneId');
    final baseUrl = AIService.baseUrl;
    print('🔍 Surveillance polling URL: $baseUrl/zones/$zoneId/count (baseUrl=$baseUrl)');
    
    // Poll API every 2 seconds (reduced frequency to avoid spam)
    _apiPollingSubscriptions[zoneId] = Stream.periodic(const Duration(seconds: 2)).asyncMap((_) async {
      try {
        final url = '$baseUrl/zones/$zoneId/count';
        
        final response = await http.get(
          Uri.parse(url),
        ).timeout(const Duration(seconds: 8)); // Increased timeout to handle slow responses
        
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final peopleCount = data['peopleCount'] as int? ?? 0;
          
          // Debug: Always log successful API response to verify connection
          final currentCount = _peopleCounts[zoneId] ?? 0;
          print('📥 Surveillance API success: zone=$zoneId, count=$peopleCount (current=$currentCount), response=${response.body}');
          
          // Always update data, regardless of monitoring status
          // (is_monitoring is just informational)
          
          return {'count': peopleCount};
        } else {
          print('⚠️ Surveillance API returned status ${response.statusCode}: ${response.body}');
        }
      } catch (e) {
        // Suppress timeout errors - they're common and not critical
        // The next poll will retry automatically
        if (e.toString().contains('TimeoutException')) {
          // Timeout errors are silently ignored - they'll be retried on next poll
          return null;
        } else if (e.toString().contains('Connection refused') || e.toString().contains('SocketException')) {
          // Connection errors - log at least once to help debug
          print('❌ Surveillance connection error (will retry silently): $e');
          print('   Make sure Python service is running at $baseUrl');
          return null;
        } else {
          // Only log other errors (not timeout or connection refused)
          print('⚠️ Surveillance API polling error: $e');
        }
      }
      return null;
    }).listen((result) {
      print('🔔 Surveillance API listener received for zone $zoneId: result=$result, mounted=$mounted');
      if (result != null && mounted) {
        final count = result['count'] as int;
        final previousCount = _peopleCounts[zoneId] ?? 0;
        
        // Always log when we receive data
        print('✅ Surveillance updating zone $zoneId: count=$count (was $previousCount)');
        
        // Always update UI, even if count is the same (to ensure UI is in sync)
        setState(() {
          _peopleCounts[zoneId] = count;
        });
        print('✅ Surveillance UI updated: _peopleCounts[$zoneId]=$count');
        
        // Save to Firebase for analytics (every 5 minutes or when count changes significantly)
        if (count != previousCount) {
          _savePeopleCountToFirebase(zoneId, count, previousCount);
        }
      }
      // Removed excessive logging for null result (timeouts are expected)
    }, onError: (error) {
      print('❌ API polling stream error for zone $zoneId: $error');
    });
  }
  
  DateTime? _lastSaveTime;
  
  void _savePeopleCountToFirebase(String zoneId, int count, int previousCount) async {
    final now = DateTime.now();
    
    // Save conditions:
    // 1. Every 5 minutes (for analytics)
    // 2. When count changes significantly (difference >= 2)
    final shouldSave = _lastSaveTime == null || 
                      now.difference(_lastSaveTime!).inMinutes >= 5 ||
                      (previousCount != count && (count - previousCount).abs() >= 2);
    
    if (shouldSave) {
      try {
        await DataService.updatePeopleCount(zoneId, count);
        _lastSaveTime = now;
        print('💾 Saved people count to Firebase: $count (for analytics)');
      } catch (e) {
        print('⚠️ Failed to save people count to Firebase: $e');
      }
    }
  }

  Future<void> _startStreaming(String zoneId) async {
    // Check if already streaming for this zone
    if (_streamingStatus[zoneId] == true) {
      print('⚠️ Streaming already active for zone $zoneId, skipping...');
      return;
    }

    final zone = _zones.firstWhere((z) => z.id == zoneId, orElse: () => _zones.first);
    
    // Simplified: No permission check needed
    // Python service handles camera access directly on the backend
    // Flutter just displays the MJPEG stream from Python service
    // Python service runs on host machine, not on device

    // Check if using local mode or HTTP mode
    // Check camera mode: local uses Flutter camera, HTTP uses Python service
    final isLocalMode = zone.cameraUrl == 'local';
    final isHttpMode = zone.cameraUrl != null && zone.cameraUrl!.startsWith('http');
    
    if (isLocalMode) {
      // Local mode - use device camera directly
      print('📱 Setting up local camera for zone $zoneId');
      try {
        // Check if controller already exists
        if (_cameraControllers.containsKey(zoneId)) {
          print('✅ Camera controller already exists for zone $zoneId');
        setState(() {
          _streamingStatus[zoneId] = true;
        });
        return;
      }

        // Initialize local camera if not already initialized
        if (!LocalCameraService.isInitialized) {
          final initialized = await LocalCameraService.initialize();
          if (!initialized) {
            throw Exception('Failed to initialize local camera');
        }
        }
        
        // Start preview
        final previewStarted = await LocalCameraService.startPreview();
        if (!previewStarted) {
          throw Exception('Failed to start camera preview');
        }
        
        // Initialize local AI service
        await LocalAIService.initialize();
        
        // Variables for throttling Firebase updates
        int? lastCount;
        DateTime? lastUpdateTime;
        DateTime? lastUiUpdateTime;
        
        // Set up detection callback
        LocalAIService.setDetectionCallback((count, confidence) {
          if (!mounted) return;
          
          // 1. Throttle UI updates (setState) to avoid overwhelming the UI thread
          // Only update UI every 200ms or if count changed
          final now = DateTime.now();
          final shouldUpdateUi = _peopleCounts[zoneId] != count || 
                                lastUiUpdateTime == null || 
                                now.difference(lastUiUpdateTime!).inMilliseconds >= 200;
                                
          if (shouldUpdateUi) {
            lastUiUpdateTime = now;
            setState(() {
              _peopleCounts[zoneId] = count;
            });
          }
          
          // 2. Throttle Firebase updates
          // Update if count changed OR if it's been > 5 seconds (heartbeat to keep "Online" status)
          final shouldUpdateFirebase = lastCount != count || 
                              lastUpdateTime == null || 
                              now.difference(lastUpdateTime!).inSeconds >= 5;
                              
          if (shouldUpdateFirebase) {
            lastCount = count;
            lastUpdateTime = now;
            
            // Update Firebase
            FirebaseMonitoringService.updatePeopleCount(zoneId, count).catchError((e) {
              print('❌ Error updating people count to Firebase: $e');
            });
            
            // Also update DataService for analytics persistence
            // IMPORTANT: FirebaseMonitoringService updates 'zones/ID', but DataService also logs to 'analytics/ID'
            // We need BOTH to ensure data appears in Analytics page
            if (count > 0 || lastCount != 0) { // Only log analytics if relevant (avoid flooding 0s)
               DataService.updatePeopleCount(zoneId, count).catchError((e) {
                 print('❌ Error updating analytics: $e');
               });
            }
          }
        });
        
        // Set image callback for processing
        LocalCameraService.setImageCallback((image) {
          LocalAIService.processImage(image);
        });
        
        // Store camera controller reference
        final cameraController = LocalCameraService.controller;
        if (cameraController != null) {
          _cameraControllers[zoneId] = cameraController;
        }
        
            if (mounted) {
          setState(() {
            _streamingStatus[zoneId] = true;
          });
          }
        print('✅ Local camera initialized for zone $zoneId');
        } catch (e) {
        print('❌ Failed to initialize local camera for zone $zoneId: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
              content: Text('Failed to initialize local camera: $e'),
                backgroundColor: Colors.red,
                duration: const Duration(seconds: 5),
              ),
            );
          }
        return;
      }
    } else if (isHttpMode) {
      // HTTP mode - use Python service stream
      try {
        // Check if controller already exists for this zone
        if (_webViewControllers.containsKey(zoneId)) {
          print('✅ WebView controller already exists for zone $zoneId');
          setState(() {
            _streamingStatus[zoneId] = true;
          });
          return;
        }
        
        // For HTTP mode, use Python service's stream endpoint instead of direct URL
        // This ensures proper MJPEG streaming and frame availability
        final streamUrl = AIService.getStreamUrl(zoneId);
        print('📱 Setting up HTTP stream via WebView for zone $zoneId');
        print('   Using Python service stream: $streamUrl');
        print('   Original camera URL: ${zone.cameraUrl}');
        
        // Create HTML wrapper for MJPEG stream
        // Escape the URL properly for HTML
        final escapedUrl = streamUrl.replaceAll("'", "\\'").replaceAll('"', '&quot;');
        final htmlContent = '''
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>Camera Stream</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        body {
            background-color: #000;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            overflow: hidden;
        }
        #stream-container {
            width: 100%;
            height: 100%;
            display: flex;
            justify-content: center;
            align-items: center;
        }
        #stream-img {
            max-width: 100%;
            max-height: 100%;
            width: auto;
            height: auto;
            object-fit: contain;
        }
        .error {
            color: #fff;
            text-align: center;
            padding: 20px;
            font-family: Arial, sans-serif;
        }
    </style>
</head>
<body>
    <div id="stream-container">
        <img id="stream-img" src="$escapedUrl" alt="Camera Stream" />
    </div>
    <script>
        const img = document.getElementById('stream-img');
        const container = document.getElementById('stream-container');
        const streamUrl = '$escapedUrl';
        
        // Handle image load
        img.onload = function() {
            console.log('Stream image loaded');
        };
        
        // Handle image errors with retry
        img.onerror = function() {
            console.error('Stream image error, retrying...');
            // Retry loading with cache buster
            setTimeout(function() {
                img.src = streamUrl + (streamUrl.indexOf('?') === -1 ? '?' : '&') + 't=' + Date.now();
            }, 1000);
        };
        
        // Periodically refresh to ensure stream stays alive
        setInterval(function() {
            img.src = streamUrl + (streamUrl.indexOf('?') === -1 ? '?' : '&') + 't=' + Date.now();
        }, 30000); // Refresh every 30 seconds
    </script>
</body>
</html>
''';
        
          final webViewController = WebViewController()
            ..setJavaScriptMode(JavaScriptMode.unrestricted)
            ..setBackgroundColor(Colors.black)
            ..setNavigationDelegate(
              NavigationDelegate(
                onPageStarted: (String url) {
                  print('📱 WebView page started for zone $zoneId: $url');
                },
                onPageFinished: (String url) {
                  print('✅ WebView page finished for zone $zoneId: $url');
                },
                onWebResourceError: (WebResourceError error) {
                  print('❌ WebView error for zone $zoneId: ${error.description} (code: ${error.errorCode})');
                  if (mounted && error.errorCode != -2 && error.errorCode != -6) {
                    if (!_hasShownStreamError) {
                      _hasShownStreamError = true;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                        content: Text('Failed to load HTTP stream for ${zone.name}: ${error.description}'),
                          backgroundColor: Colors.red,
                          duration: const Duration(seconds: 5),
                        ),
                      );
                      Future.delayed(const Duration(seconds: 10), () {
                        if (mounted) {
                          _hasShownStreamError = false;
                        }
                      });
                    }
                  }
                },
              ),
            )
          ..loadHtmlString(htmlContent, baseUrl: streamUrl);
          
          _webViewControllers[zoneId] = webViewController;
          
          if (mounted) {
            setState(() {
              _streamingStatus[zoneId] = true;
            });
          }
        print('✅ HTTP stream initialized with WebView for zone $zoneId');
        } catch (e) {
        print('❌ Error setting up HTTP stream: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
              content: Text('Failed to setup HTTP stream: $e'),
                backgroundColor: Colors.red,
                duration: const Duration(seconds: 5),
              ),
            );
          }
          return;
        }
      } else if (zone.rtspUrl != null && zone.rtspUrl!.isNotEmpty && 
                 !zone.rtspUrl!.startsWith('http://') && !zone.rtspUrl!.startsWith('https://')) {
        // Use RTSP stream (only if it's actually RTSP, not HTTP)
        print('📹 Setting up RTSP stream via VideoPlayer for zone $zoneId: ${zone.rtspUrl}');
        try {
          final videoPlayerController = VideoPlayerController.networkUrl(
            Uri.parse(zone.rtspUrl!),
            videoPlayerOptions: VideoPlayerOptions(
              allowBackgroundPlayback: false,
            ),
          );
          await videoPlayerController.initialize().timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              throw TimeoutException('Video player initialization timeout');
            },
          );
          videoPlayerController.setLooping(true);
          videoPlayerController.play();
          
          // Store controller for this zone
          _videoPlayerControllers[zoneId] = videoPlayerController;
          
          if (mounted) {
            setState(() {
              _streamingStatus[zoneId] = true;
            });
          }
          print('✅ RTSP stream initialized with VideoPlayer for zone $zoneId');
        } catch (e) {
          print('❌ Failed to initialize RTSP stream for zone $zoneId: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to start RTSP stream for ${zone.name}: $e'),
                backgroundColor: Colors.red,
                duration: const Duration(seconds: 5),
              ),
            );
          }
          return;
        }
      } else {
      // No valid camera configuration
        throw Exception('No camera URL configured');
    }
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Real-Time Surveillance',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 20),
        ),
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
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _zones.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.videocam_off, size: 64, color: AppTheme.mutedForeground),
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
                        'Please create zones first',
                        style: TextStyle(color: AppTheme.mutedForeground),
                      ),
                    ],
                  ),
                )
              : _selectedZoneId == null
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.videocam_off, size: 64, color: AppTheme.mutedForeground),
                          const SizedBox(height: 16),
                          Text(
                            'No Active Cameras',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.foreground,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Please activate cameras from Camera Setup page',
                            style: TextStyle(color: AppTheme.mutedForeground),
                          ),
                          const SizedBox(height: 24),
                          ElevatedButton.icon(
                            onPressed: () {
                              context.go('/camera-setup');
                            },
                            icon: const Icon(Icons.settings),
                            label: const Text('Go to Camera Setup'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.primary,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            ),
                          ),
                        ],
                      ),
                    )
                  : SafeArea(
                      child: Column(
                        children: [
                          // Video stream area - use Flexible instead of Expanded to allow tab bar to be visible
                          Flexible(
                            flex: 3,
                            child: Container(
                              margin: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: AppTheme.muted,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: AppTheme.border),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                              child: _selectedZoneId != null && _streamingStatus[_selectedZoneId] == true
                                  ? Stack(
                                      children: [
                                        _buildVideoView(),
                                          // Top overlay: People count and Zone name
                                        Positioned(
                                          top: 16,
                                          left: 16,
                                            right: 16,
                                            child: Row(
                                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                              children: [
                                                // People count badge
                                                Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                            decoration: BoxDecoration(
                                              color: Colors.black.withValues(alpha: 0.7),
                                              borderRadius: BorderRadius.circular(8),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(
                                                  Icons.people,
                                                  color: Colors.white,
                                                  size: 20,
                                                ),
                                                const SizedBox(width: 8),
                                                Text(
                                                        '${_peopleCounts[_selectedZoneId] ?? 0}',
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 16,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                                // Zone name badge
                                                Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                            decoration: BoxDecoration(
                                              color: Colors.black.withValues(alpha: 0.7),
                                              borderRadius: BorderRadius.circular(8),
                                            ),
                                            child: Text(
                                              _zones.firstWhere((z) => z.id == _selectedZoneId, orElse: () => _zones.first).name,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 16,
                                                fontWeight: FontWeight.bold,
                                              ),
                                                    overflow: TextOverflow.ellipsis,
                                            ),
                                                ),
                                              ],
                                          ),
                                        ),
                                        // Deactivate button overlay (bottom right)
                                        if (_selectedZoneId != null)
                                          Positioned(
                                            bottom: 16,
                                            right: 16,
                                            child: ElevatedButton.icon(
                                              onPressed: () => _deactivateCamera(_selectedZoneId!),
                                              icon: const Icon(Icons.stop, size: 18),
                                              label: const Text('Deactivate'),
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: AppTheme.destructive,
                                                foregroundColor: Colors.white,
                                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                              ),
                                            ),
                                          ),
                                      ],
                                    )
                                  : Center(
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          const CircularProgressIndicator(),
                                          const SizedBox(height: 16),
                                          Text(
                                            'Initializing stream...',
                                            style: TextStyle(
                                              fontSize: 16,
                                              color: AppTheme.foreground,
                                            ),
                                          ),
                                        ],
                                        ),
                                      ),
                                    ),
                            ),
                          ),
                          // Camera switcher (horizontal scrollable tabs) - only show active cameras
                          FutureBuilder<List<String>>(
                            future: _getActiveZones(),
                            builder: (context, snapshot) {
                              // Get active zones from multiple sources
                              final pythonActiveZones = snapshot.data ?? [];
                              final activeCameras = ref.read(activeCameraProvider);
                              final allActiveZones = pythonActiveZones.toSet().union(activeCameras);
                              
                              final activeZonesList = _zones.where((z) => allActiveZones.contains(z.id)).toList();
                              
                              if (activeZonesList.isEmpty) {
                                return const SizedBox.shrink();
                              }
                              
                              return Container(
                                height: 80,
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                child: ListView.builder(
                                  scrollDirection: Axis.horizontal,
                                  padding: const EdgeInsets.symmetric(horizontal: 8),
                                  itemCount: activeZonesList.length,
                                  itemBuilder: (context, index) {
                                    final zone = activeZonesList[index];
                                    final isSelected = zone.id == _selectedZoneId;
                                    final isStreaming = _streamingStatus[zone.id] == true;
                                    final peopleCount = _peopleCounts[zone.id] ?? 0;
                                    
                                    return GestureDetector(
                                      onTap: () {
                                        setState(() {
                                          _selectedZoneId = zone.id;
                                        });
                                        // Start streaming if not already started
                                        if (!isStreaming) {
                                          _startStreaming(zone.id);
                                        }
                                      },
                                      child: Container(
                                        width: 120,
                                        margin: const EdgeInsets.symmetric(horizontal: 4),
                                        decoration: BoxDecoration(
                                          color: isSelected ? AppTheme.primary : AppTheme.muted,
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(
                                            color: isSelected ? AppTheme.primary : AppTheme.border,
                                            width: isSelected ? 2 : 1,
                                          ),
                                        ),
                                        child: Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Icon(
                                              isStreaming ? Icons.videocam : Icons.videocam_off,
                                              color: isSelected ? Colors.white : AppTheme.foreground,
                                              size: 24,
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              zone.name,
                                              style: TextStyle(
                                                color: isSelected ? Colors.white : AppTheme.foreground,
                                                fontSize: 12,
                                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                              ),
                                              textAlign: TextAlign.center,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            if (isStreaming)
                                              Text(
                                                '$peopleCount people',
                                                style: TextStyle(
                                                  color: isSelected ? Colors.white70 : AppTheme.mutedForeground,
                                                  fontSize: 10,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
      bottomNavigationBar: const BottomNav(currentIndex: 2),
    );
  }

  Widget _buildVideoView() {
    if (_selectedZoneId == null) {
      return const Center(child: CircularProgressIndicator());
    }
    
    final zone = _zones.firstWhere(
      (z) => z.id == _selectedZoneId,
      orElse: () => _zones.first,
    );
    
    // Check if using local mode
    final isLocalMode = zone.cameraUrl == 'local';
    
    // Use CameraPreview for local mode
    if (isLocalMode && _cameraControllers.containsKey(_selectedZoneId)) {
      final controller = _cameraControllers[_selectedZoneId]!;
      if (controller.value.isInitialized) {
        // Correct aspect ratio for portrait mode
        // Camera controller usually returns landscape aspect ratio (e.g. 4:3)
        // But in portrait mode we want the inverse (3:4) to fill the container correctly
        // without stretching
        var aspectRatio = controller.value.aspectRatio;
        
        // Check if we are in portrait mode and the aspect ratio is landscape (> 1)
        // This is typical for mobile cameras which are landscape sensors
        if (MediaQuery.of(context).orientation == Orientation.portrait) {
           // Force 1/aspectRatio to match portrait view
           // But be careful, CameraPreview handles rotation internally.
           // The issue is usually the container size vs preview size.
           // A safe bet for full-screen-ish preview is often 1 / controller.value.aspectRatio
           aspectRatio = 1 / aspectRatio;
        }
        
        return Center(
          child: AspectRatio(
            aspectRatio: aspectRatio,
            child: CameraPreview(controller),
          ),
        );
      }
    }
    
    // Use WebView for remote streams (preferred method)
    if (_webViewControllers.containsKey(_selectedZoneId)) {
      return SizedBox.expand(
        child: WebViewWidget(controller: _webViewControllers[_selectedZoneId]!),
      );
    }
    
    // Fallback: Use VideoPlayer for RTSP streams
    if (_videoPlayerControllers.containsKey(_selectedZoneId)) {
      final controller = _videoPlayerControllers[_selectedZoneId]!;
      if (controller.value.isInitialized) {
        return AspectRatio(
          aspectRatio: controller.value.aspectRatio,
          child: VideoPlayer(controller),
        );
      }
    }
    
    // Loading state
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            'Initializing stream for ${zone.name}...',
            style: TextStyle(color: AppTheme.foreground),
          ),
        ],
      ),
    );
  }
}

