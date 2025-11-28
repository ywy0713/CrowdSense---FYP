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
    for (var controller in _webViewControllers.values) {
      // WebView controllers don't need explicit disposal
    }
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
    
    // Note: AI service monitoring continues in background
    super.dispose();
  }

  // Note: Direct camera uses Python service stream, no local camera initialization needed

  Future<void> _loadZones() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final user = AuthService.getCurrentUser();
      if (user != null) {
        final zones = await DataService.getUserZones(user.uid);
        
        // Check for active cameras
        final activeCameras = ref.read(activeCameraProvider);
        
        // Check which zones are actually active in Python service
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
        
        setState(() {
          _zones = zones;
          if (zones.isNotEmpty) {
            // Only select from actually active zones
            if (actuallyActiveZones.isNotEmpty) {
              // Prefer active camera from provider if available and actually active
              if (activeCameras.isNotEmpty) {
                final firstActive = activeCameras.first;
                if (actuallyActiveZones.contains(firstActive) && zones.any((z) => z.id == firstActive)) {
                  _selectedZoneId = firstActive;
                } else if (actuallyActiveZones.isNotEmpty) {
                  // Use first actually active zone
                  _selectedZoneId = actuallyActiveZones.first;
                } else {
                  _selectedZoneId = null;
                }
              } else if (actuallyActiveZones.isNotEmpty) {
                _selectedZoneId = actuallyActiveZones.first;
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
        
        // Subscribe to real-time people count updates for active zones only
        for (var zoneId in actuallyActiveZones) {
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
      final status = await AIService.getStatus();
      if (status != null) {
        return (status['active_zones'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList();
      }
    } catch (e) {
      print('⚠️ Failed to get active zones: $e');
    }
    return [];
  }

  Future<void> _deactivateCamera(String zoneId) async {
    try {
      // Stop AI service monitoring
      await AIService.stopZoneMonitoring(zoneId);
      
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

    try {
      // Check if controller already exists for this zone
      if (_webViewControllers.containsKey(zoneId)) {
        print('✅ WebView controller already exists for zone $zoneId');
        setState(() {
          _streamingStatus[zoneId] = true;
        });
        return;
      }

      // Verify Python service is running and zone is active
      // DO NOT activate here - activation must be done from Camera Setup page
      try {
        final status = await AIService.getStatus();
        if (status == null) {
          throw Exception('Python AI service is not running. Please start it first.');
        }
        final activeZones = (status['active_zones'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList();
        if (!activeZones.contains(zoneId)) {
          // Zone is not active - show error and redirect to camera setup
          print('⚠️ Zone $zoneId is not active. Please activate it from Camera Setup page first.');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Camera is not active. Please activate it from Camera Setup page first.'),
                backgroundColor: Colors.orange,
                duration: const Duration(seconds: 5),
                action: SnackBarAction(
                  label: 'Go to Setup',
                  textColor: Colors.white,
                  onPressed: () {
                    // Use microtask to ensure SnackBar closes before navigation
                    Future.microtask(() {
                      if (mounted) {
                        context.go('/camera-setup');
                      }
                    });
                  },
                ),
              ),
            );
          }
          return;
        }
        print('✅ Python AI service is running for zone: $zoneId');
      } catch (e) {
        print('❌ Error checking Python service: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error: Python AI service not available. Please ensure it is running at ${AIService.baseUrl}'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return;
      }

      // Wait a bit for Python service to initialize camera (if not already started)
      print('⏳ Waiting for Python AI service to initialize camera...');
      await Future.delayed(const Duration(seconds: 1));

      if (zone.cameraUrl == 'direct' || (zone.cameraUrl != null && zone.cameraUrl!.isNotEmpty)) {
        // For direct camera, use Python service's video stream to avoid camera conflict
        // Python service handles the camera access and provides MJPEG stream
        // Wait a bit for Python service to start camera (if not already started)
        print('⏳ Waiting for Python AI service to initialize camera...');
        await Future.delayed(const Duration(seconds: 2));
        
        // Verify Python service is running and zone is already active
        // NOTE: This page can only VIEW streams, not activate cameras
        // Camera activation must be done from Camera Setup page
        try {
          final status = await AIService.getStatus();
          if (status == null) {
            throw Exception('Python AI service is not running. Please start it first.');
          }
          final activeZones = status['active_zones'] as List<dynamic>? ?? [];
          if (!activeZones.contains(zone.id)) {
            // Zone is not active - show error and redirect to camera setup
            print('⚠️ Zone ${zone.id} is not active. Please activate it from Camera Setup page first.');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('Camera is not active. Please activate it from Camera Setup page first.'),
                  backgroundColor: Colors.orange,
                  duration: const Duration(seconds: 5),
                  action: SnackBarAction(
                    label: 'Go to Setup',
                    textColor: Colors.white,
                    onPressed: () {
                      // Use microtask to ensure SnackBar closes before navigation
                      Future.microtask(() {
                        if (mounted) {
                          context.go('/camera-setup');
                        }
                      });
                    },
                  ),
                ),
              );
            }
            return;
          }
          print('✅ Python AI service is running for zone: ${zone.id}');
        } catch (e) {
          print('❌ Error checking Python service: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error: Python AI service not available. Please ensure it is running at ${AIService.baseUrl}'),
                backgroundColor: Colors.red,
                duration: const Duration(seconds: 5),
              ),
            );
          }
          return;
        }
        
        // Use unified HTML page approach for Mobile
        // Python service provides /zones/{zone_id}/view endpoint with HTML page
        final baseUrl = AIService.baseUrl;
        final viewUrl = '$baseUrl/zones/$zoneId/view';
        
        // Mobile: Use WebView to display HTML page with MJPEG stream
        print('📱 Setting up video stream via WebView for zone $zoneId: $viewUrl');
        try {
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
                  // Only show error for critical failures (not 404s or network timeouts that might be transient)
                  if (mounted && error.errorCode != -2 && error.errorCode != -6) {
                    // Avoid showing multiple error messages
                    if (!_hasShownStreamError) {
                      _hasShownStreamError = true;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Failed to load video stream for ${zone.name}: ${error.description}'),
                          backgroundColor: Colors.red,
                          duration: const Duration(seconds: 5),
                        ),
                      );
                      // Reset flag after 10 seconds to allow showing error again if needed
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
            ..loadRequest(Uri.parse(viewUrl));
          
          // Store controller for this zone
          _webViewControllers[zoneId] = webViewController;
          
          if (mounted) {
            setState(() {
              _streamingStatus[zoneId] = true;
            });
          }
          print('✅ Video stream initialized with WebView for zone $zoneId');
        } catch (e) {
          print('❌ Failed to initialize WebView for zone $zoneId: $e');
          
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to initialize video stream for ${zone.name}: $e'),
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
        throw Exception('No camera URL configured');
      }
    } catch (e) {
      print('Error starting stream: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start stream: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Real-Time Video Surveillance'),
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
                          // Video stream area
                          Expanded(
                            child: Container(
                              margin: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: AppTheme.muted,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: AppTheme.border),
                              ),
                              child: _selectedZoneId != null && _streamingStatus[_selectedZoneId] == true
                                  ? Stack(
                                      children: [
                                        _buildVideoView(),
                                        // People count overlay
                                        Positioned(
                                          top: 16,
                                          left: 16,
                                          child: Container(
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
                                                  'People detected: ${_peopleCounts[_selectedZoneId] ?? 0}',
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 16,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        // Zone name overlay
                                        Positioned(
                                          top: 16,
                                          right: 16,
                                          child: Container(
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
                                            ),
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
                          // Camera switcher (horizontal scrollable tabs) - only show active cameras
                          FutureBuilder<List<String>>(
                            future: _getActiveZones(),
                            builder: (context, snapshot) {
                              final activeZones = snapshot.data ?? [];
                              final activeZonesList = _zones.where((z) => activeZones.contains(z.id)).toList();
                              
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
    
    // Use WebView for mobile platforms (preferred method)
    if (_webViewControllers.containsKey(_selectedZoneId)) {
      return WebViewWidget(controller: _webViewControllers[_selectedZoneId]!);
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
    
    // Fallback: Use CameraPreview (if available)
    if (_cameraControllers.containsKey(_selectedZoneId)) {
      final controller = _cameraControllers[_selectedZoneId]!;
      if (controller.value.isInitialized) {
        return CameraPreview(controller);
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
            'Initializing stream for ${_zones.firstWhere((z) => z.id == _selectedZoneId, orElse: () => _zones.first).name}...',
            style: TextStyle(color: AppTheme.foreground),
          ),
        ],
      ),
    );
  }
}

