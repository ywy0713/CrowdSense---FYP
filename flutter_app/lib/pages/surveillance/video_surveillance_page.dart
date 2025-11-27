import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:camera/camera.dart';
import 'package:video_player/video_player.dart';
import 'dart:async' show StreamSubscription;
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
  bool _isStreaming = false;
  bool _hasShownStreamError = false; // Track if we've shown stream error to avoid spam
  
  // Video streaming
  CameraController? _cameraController;
  VideoPlayerController? _videoPlayerController;
  // List<CameraDescription>? _cameras; // Not needed - direct camera uses Python service stream
  
  // WebView controller for mobile platforms
  WebViewController? _webViewController;
  
  // Real-time people count
  int _currentPeopleCount = 0;
  StreamSubscription<ZoneData?>? _zoneSubscription;
  StreamSubscription<Map<String, dynamic>?>? _apiPollingSubscription;

  @override
  void initState() {
    super.initState();
    _loadZones();
    // Note: Streaming will be started after zones are loaded in _loadZones()
  }

  @override
  void dispose() {
    // Only stop video display, NOT the AI service
    // AI service continues running in background for dashboard updates
    // Python AI service uses its own OpenCV VideoCapture, independent of Flutter's camera controller
    // DO NOT call stopZoneMonitoring here - let it run in background for dashboard
    _cameraController?.dispose();
    _videoPlayerController?.dispose();
    _zoneSubscription?.cancel();
    _apiPollingSubscription?.cancel();
    _cameraController = null;
    _videoPlayerController = null;
    _webViewController = null;
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
        
        // Check for active camera
        final activeCameraId = ref.read(activeCameraProvider);
        
        setState(() {
          _zones = zones;
          if (zones.isNotEmpty) {
            // Prefer active camera if available, otherwise use first zone
            if (activeCameraId != null && zones.any((z) => z.id == activeCameraId)) {
              _selectedZoneId = activeCameraId;
            } else {
              _selectedZoneId = zones.first.id;
            }
            // Auto-start streaming when zone is selected (for both cases)
            // Use a small delay to ensure UI is ready
            Future.delayed(const Duration(milliseconds: 500), () {
              if (mounted && !_isStreaming && _selectedZoneId != null) {
                _startStreaming();
              }
            });
          }
          _isLoading = false;
        });
        
        // Subscribe to real-time people count updates
        if (_selectedZoneId != null) {
          _subscribeToPeopleCount(_selectedZoneId!);
        }
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _subscribeToPeopleCount(String zoneId) {
    // Cancel existing subscriptions
    _zoneSubscription?.cancel();
    _apiPollingSubscription?.cancel();
    
    print('📡 Subscribing to people count for zone: $zoneId (using API)');
    
    // Use API polling directly (Python service provides data via API)
    _startApiPolling(zoneId);
    
    // Also try Firebase subscription as backup (if Firebase is available)
    _zoneSubscription = DataService.subscribeToZone(zoneId).listen((zone) {
      if (zone != null && mounted) {
        print('📥 Received Firebase update: peopleCount=${zone.peopleCount}');
        setState(() {
          _currentPeopleCount = zone.peopleCount;
        });
      }
    }, onError: (error) {
      // Ignore Firebase errors - API polling is primary
      print('⚠️ Firebase subscription error (ignored, using API): $error');
    });
  }
  
  void _startApiPolling(String zoneId) {
    _apiPollingSubscription?.cancel();
    
    print('🔄 Starting API polling for zone: $zoneId');
    final baseUrl = AIService.baseUrl;
    print('🔍 Surveillance polling URL: $baseUrl/zones/$zoneId/count (baseUrl=$baseUrl)');
    
    // Poll API every 2 seconds (reduced frequency to avoid spam)
    _apiPollingSubscription = Stream.periodic(const Duration(seconds: 2)).asyncMap((_) async {
      try {
        final url = '$baseUrl/zones/$zoneId/count';
        
        final response = await http.get(
          Uri.parse(url),
        ).timeout(const Duration(seconds: 8)); // Increased timeout to handle slow responses
        
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final peopleCount = data['peopleCount'] as int? ?? 0;
          
          // Debug: Always log successful API response to verify connection
          print('📥 Surveillance API success: zone=$zoneId, count=$peopleCount (current=$_currentPeopleCount), response=${response.body}');
          
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
      print('🔔 Surveillance API listener received: result=$result, mounted=$mounted');
      if (result != null && mounted) {
        final count = result['count'] as int;
        final previousCount = _currentPeopleCount;
        
        // Always log when we receive data
        print('✅ Surveillance updating zone $zoneId: count=$count (was $previousCount)');
        
        // Always update UI, even if count is the same (to ensure UI is in sync)
        setState(() {
          _currentPeopleCount = count;
        });
        print('✅ Surveillance UI updated: _currentPeopleCount=$_currentPeopleCount');
        
        // Save to Firebase for analytics (every 5 minutes or when count changes significantly)
        if (count != previousCount) {
          _savePeopleCountToFirebase(zoneId, count, previousCount);
        }
      }
      // Removed excessive logging for null result (timeouts are expected)
    }, onError: (error) {
      print('❌ API polling stream error: $error');
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

  Future<void> _startStreaming() async {
    if (_selectedZoneId == null) return;
    
    // Prevent multiple simultaneous calls
    if (_isStreaming) {
      print('⚠️ Streaming already in progress, skipping...');
      return;
    }

    final zone = _zones.firstWhere((z) => z.id == _selectedZoneId, orElse: () => _zones.first);
    
    // Simplified: No permission check needed
    // Python service handles camera access directly on the backend
    // Flutter just displays the MJPEG stream from Python service
    // Python service runs on host machine, not on device

    try {
      // Stop any existing video display (but keep AI service running)
      await _cameraController?.dispose();
      await _videoPlayerController?.dispose();
      _cameraController = null;
      _videoPlayerController = null;
      _webViewController = null;

      if (zone.cameraUrl == 'direct') {
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
        final viewUrl = '$baseUrl/zones/${zone.id}/view';
        
        // Mobile: Use WebView to display HTML page with MJPEG stream
        print('📱 Setting up mobile video stream via WebView: $viewUrl');
        try {
          _webViewController = WebViewController()
            ..setJavaScriptMode(JavaScriptMode.unrestricted)
            ..setBackgroundColor(Colors.black)
            ..setNavigationDelegate(
              NavigationDelegate(
                onPageStarted: (String url) {
                  print('📱 WebView page started: $url');
                },
                onPageFinished: (String url) {
                  print('✅ WebView page finished: $url');
                },
                onWebResourceError: (WebResourceError error) {
                  print('❌ WebView error: ${error.description} (code: ${error.errorCode})');
                  // Only show error for critical failures (not 404s or network timeouts that might be transient)
                  if (mounted && error.errorCode != -2 && error.errorCode != -6) {
                    // Avoid showing multiple error messages
                    if (!_hasShownStreamError) {
                      _hasShownStreamError = true;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Failed to load video stream: ${error.description}'),
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
          
          if (mounted) {
            setState(() {
              _isStreaming = true;
            });
          }
          print('✅ Mobile video stream initialized with WebView');
        } catch (e) {
          print('❌ Failed to initialize WebView: $e');
          _webViewController = null;
          
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to initialize video stream: $e'),
                backgroundColor: Colors.red,
                duration: const Duration(seconds: 5),
              ),
            );
          }
          return;
        }
      } else if (zone.cameraUrl != null && zone.cameraUrl!.isNotEmpty) {
        // For HTTP streams (including external cameras), use Python service stream endpoint
        // Python service reads from external URL and streams it via /zones/{zone_id}/stream
        final baseUrl = AIService.baseUrl;
        final viewUrl = '$baseUrl/zones/${zone.id}/view';
        
        // Use WebView to display the stream from Python service
        print('📱 Setting up HTTP video stream via WebView: $viewUrl');
        try {
          _webViewController = WebViewController()
            ..setJavaScriptMode(JavaScriptMode.unrestricted)
            ..setBackgroundColor(Colors.black)
            ..setNavigationDelegate(
              NavigationDelegate(
                onPageStarted: (String url) {
                  print('📱 WebView page started: $url');
                },
                onPageFinished: (String url) {
                  print('✅ WebView page finished: $url');
                },
                onWebResourceError: (WebResourceError error) {
                  print('❌ WebView error: ${error.description} (code: ${error.errorCode})');
                },
              ),
            )
            ..loadRequest(Uri.parse(viewUrl));
          
          if (mounted) {
            setState(() {
              _isStreaming = true;
            });
          }
          print('✅ HTTP video stream initialized with WebView');
        } catch (e) {
          print('❌ Failed to initialize WebView: $e');
          _webViewController = null;
          
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to initialize video stream: $e'),
                backgroundColor: Colors.red,
                duration: const Duration(seconds: 5),
              ),
            );
          }
          return;
        }
      } else if (zone.rtspUrl != null && zone.rtspUrl!.isNotEmpty) {
        // Use RTSP stream
        _videoPlayerController = VideoPlayerController.networkUrl(
          Uri.parse(zone.rtspUrl!),
        );
        await _videoPlayerController!.initialize();
        _videoPlayerController!.setLooping(true);
        _videoPlayerController!.play();
        if (mounted) {
          setState(() {
            _isStreaming = true;
          });
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

  Future<void> _deactivateCamera() async {
    if (_selectedZoneId == null) return;
    
    try {
      // Stop video stream display only
      // DO NOT stop AI service - it should continue running in background for dashboard
      await _cameraController?.dispose();
      await _videoPlayerController?.dispose();
      _cameraController = null;
      _videoPlayerController = null;
      _webViewController = null;
      
      // Note: AI service monitoring continues in background for dashboard updates
      // Only stop if user explicitly wants to stop monitoring (not when leaving page)
      
      // Clear active camera
      ref.read(activeCameraProvider.notifier).clearActiveCamera();
      
      if (mounted) {
        setState(() {
          _isStreaming = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Camera deactivated successfully'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      print('Error deactivating camera: $e');
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
              : Column(
                  children: [
                    // Zone selector
                    Padding(
                      padding: const EdgeInsets.all(16),
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
                          // Subscribe to new zone's people count
                          if (value != null) {
                            _subscribeToPeopleCount(value);
                          }
                          // Stop current stream and start new one if streaming
                          if (_isStreaming) {
                            _deactivateCamera().then((_) {
                              _startStreaming();
                            });
                          }
                        },
                      ),
                    ),
                    // Video stream area
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppTheme.muted,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppTheme.border),
                        ),
                        child: _isStreaming
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
                                            'People detected: $_currentPeopleCount',
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
                                ],
                              )
                            : Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.videocam_off, size: 64, color: AppTheme.mutedForeground),
                                    const SizedBox(height: 16),
                                    Text(
                                      'Stream Not Active',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: AppTheme.foreground,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                      ),
                    ),
                    // Controls
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          // Deactivate button (only show if camera is active)
                          if (_isStreaming)
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: _deactivateCamera,
                                icon: const Icon(Icons.stop),
                                label: const Text('Deactivate Camera'),
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 16),
                                  backgroundColor: AppTheme.destructive,
                                  foregroundColor: Colors.white,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
      bottomNavigationBar: const BottomNav(currentIndex: 2),
    );
  }

  Widget _buildVideoView() {
    // Use WebView for mobile platforms
    if (_webViewController != null) {
      return WebViewWidget(controller: _webViewController!);
    }
    // Fallback: Use CameraPreview or VideoPlayer (for non-direct camera streams)
    else if (_cameraController != null && _cameraController!.value.isInitialized) {
      return CameraPreview(_cameraController!);
    } else if (_videoPlayerController != null && _videoPlayerController!.value.isInitialized) {
      return AspectRatio(
        aspectRatio: _videoPlayerController!.value.aspectRatio,
        child: VideoPlayer(_videoPlayerController!),
      );
    } else {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            const Text('Initializing stream...'),
          ],
        ),
      );
    }
  }
}

