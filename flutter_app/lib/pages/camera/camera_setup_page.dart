import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/ai_service.dart';
import '../../theme/app_theme.dart';

class CameraSetupPage extends StatefulWidget {
  final String? zoneId; // If provided, load and edit existing zone
  
  const CameraSetupPage({super.key, this.zoneId});

  @override
  State<CameraSetupPage> createState() => _CameraSetupPageState();
}

class _CameraSetupPageState extends State<CameraSetupPage> {
  final _formKey = GlobalKey<FormState>();
  final _zoneNameController = TextEditingController();
  final _cameraUrlController = TextEditingController();
  final _rtspUrlController = TextEditingController();
  final _lowThresholdController = TextEditingController(text: '20');
  final _mediumThresholdController = TextEditingController(text: '50');
  final _highThresholdController = TextEditingController(text: '80');
  final _criticalThresholdController = TextEditingController(text: '120');
  final _serviceSpeedController = TextEditingController(text: '2.0');

  String _connectionType = 'http'; // 'http', 'rtsp', or 'direct'
  bool _isLoading = false;
  bool _isLoadingZone = true;
  String? _errorMessage;
  String? _successMessage;

  @override
  void initState() {
    super.initState();
    if (widget.zoneId != null) {
      _loadZone(widget.zoneId!);
    } else {
      _isLoadingZone = false;
    }
  }

  @override
  void dispose() {
    _zoneNameController.dispose();
    _cameraUrlController.dispose();
    _rtspUrlController.dispose();
    _lowThresholdController.dispose();
    _mediumThresholdController.dispose();
    _highThresholdController.dispose();
    _criticalThresholdController.dispose();
    _serviceSpeedController.dispose();
    super.dispose();
  }

  Future<void> _loadZone(String zoneId) async {
    setState(() {
      _isLoadingZone = true;
    });

    try {
      final zone = await DataService.getZone(zoneId);
      if (zone != null) {
        setState(() {
          _zoneNameController.text = zone.name;
          _lowThresholdController.text = zone.thresholds.low.toString();
          _mediumThresholdController.text = zone.thresholds.medium.toString();
          _highThresholdController.text = zone.thresholds.high.toString();
          _criticalThresholdController.text = zone.thresholds.critical.toString();
          _serviceSpeedController.text = (zone.averageServiceSpeed ?? 2.0).toString();

          // Determine connection type
          if (zone.cameraUrl != null && zone.cameraUrl != 'direct') {
            _connectionType = 'http';
            _cameraUrlController.text = zone.cameraUrl!;
          } else if (zone.rtspUrl != null) {
            _connectionType = 'rtsp';
            _rtspUrlController.text = zone.rtspUrl!;
          } else if (zone.cameraUrl == 'direct') {
            _connectionType = 'direct';
          }

          _isLoadingZone = false;
        });
      } else {
        setState(() {
          _errorMessage = 'Zone not found';
          _isLoadingZone = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to load zone: $e';
        _isLoadingZone = false;
      });
    }
  }

  Future<void> _handleSubmit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      final user = AuthService.getCurrentUser();
      if (user == null) {
        setState(() {
          _errorMessage = 'Please login first';
          _isLoading = false;
        });
        return;
      }

      // Build zone data
      final zoneData = <String, dynamic>{
        'name': _zoneNameController.text.trim(),
        'thresholds': {
          'low': int.tryParse(_lowThresholdController.text) ?? 20,
          'medium': int.tryParse(_mediumThresholdController.text) ?? 50,
          'high': int.tryParse(_highThresholdController.text) ?? 80,
          'critical': int.tryParse(_criticalThresholdController.text) ?? 120,
        },
        'averageServiceSpeed': double.tryParse(_serviceSpeedController.text) ?? 2.0,
      };

      // Add camera URL based on connection type
      if (_connectionType == 'http' && _cameraUrlController.text.trim().isNotEmpty) {
        zoneData['cameraUrl'] = _cameraUrlController.text.trim();
      } else if (_connectionType == 'rtsp' && _rtspUrlController.text.trim().isNotEmpty) {
        zoneData['rtspUrl'] = _rtspUrlController.text.trim();
      } else if (_connectionType == 'direct') {
        // Direct camera access - no URL needed
        zoneData['cameraUrl'] = 'direct';
      }

      // Update or create zone
      if (widget.zoneId != null) {
        // Update existing zone
        await DataService.updateZone(widget.zoneId!, zoneData);
        setState(() {
          _successMessage = 'Camera setup updated successfully!';
          _isLoading = false;
        });
      } else {
        // Create new zone
        final zoneId = await DataService.createZone(user.uid, zoneData);
        setState(() {
          _successMessage = 'Camera setup completed successfully!';
          _isLoading = false;
        });

        // Request camera permission and start AI service if direct camera
        // Note: This is optional - camera setup can complete even if AI service fails
        if (_connectionType == 'direct') {
          // Run in background - don't block the success message
          _requestCameraPermissionAndStart(zoneId, zoneData).catchError((error) {
            print('⚠️ Could not start AI service: $error');
            // Don't show error to user here - camera setup was successful
          });
        }
      }

      // Navigate back after showing success message (both create and update)
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) {
          // Always navigate back to camera list page
          // Pass true to indicate success so the list page can refresh
          Navigator.of(context).pop(true);
        }
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to setup camera: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _requestCameraPermissionAndStart(String zoneId, Map<String, dynamic> zoneData) async {
    // Request camera permission
    final status = await Permission.camera.request();
    
    if (!mounted) return;

    if (status.isDenied) {
      // User denied permission, show dialog
      final shouldRequest = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Camera Permission Required'),
          content: const Text(
            'CrowdSense needs camera access to monitor the zone. '
            'Please allow camera access in your device settings to continue.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );

      if (shouldRequest == true) {
        await openAppSettings();
      }
      return;
    }

    if (status.isPermanentlyDenied) {
      // Permission permanently denied, open settings
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Camera permission is permanently denied. Please enable it in settings.'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Open Settings',
            onPressed: openAppSettings,
          ),
        ),
      );
      return;
    }

    if (status.isGranted) {
      // Permission granted, start AI service
      await _startAIService(zoneId, zoneData);
    }
  }

  Future<void> _startAIService(String zoneId, Map<String, dynamic> zoneData) async {
    // Load the zone and start AI service
    try {
      final zone = await DataService.getZone(zoneId);
      if (zone != null && _connectionType == 'direct') {
        // Show loading indicator
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
                      Text('Starting camera and AI service...'),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        final started = await AIService.startZoneMonitoring(zoneId, zone);
        
        if (!mounted) return;
        
        // Dismiss loading dialog
        if (mounted) {
          Navigator.of(context).pop();
        }

        if (started) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('✅ Camera activated! AI service started successfully. Monitoring has begun.'),
                backgroundColor: Colors.green,
                duration: Duration(seconds: 3),
              ),
            );
          }
        } else {
          // Show warning but don't block - camera setup was successful
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('⚠️ Warning: Could not start AI service. Make sure the Python service is running. Camera setup completed but monitoring not active. You can start monitoring later from the dashboard.'),
                backgroundColor: Colors.orange,
                duration: const Duration(seconds: 6),
                action: SnackBarAction(
                  label: 'OK',
                  textColor: Colors.white,
                  onPressed: () {},
                ),
              ),
            );
          }
        }
      }
    } catch (e) {
      print('⚠️ Failed to start AI service: $e');
      if (mounted) {
        // Dismiss loading dialog if still showing
        try {
          Navigator.of(context).pop();
        } catch (_) {
          // Dialog might already be dismissed
        }
        // Show warning but don't block - camera setup was successful
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⚠️ Warning: Could not start AI service: $e. Camera setup completed but monitoring not active. Make sure the Python AI service is running at http://localhost:8000'),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 6),
            action: SnackBarAction(
              label: 'OK',
              textColor: Colors.white,
              onPressed: () {},
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingZone) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.zoneId != null ? 'Edit Camera Setup' : 'Camera Setup'),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.zoneId != null ? 'Edit Camera Setup' : 'Camera Setup'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Instructions
              Card(
                color: AppTheme.primary.withValues(alpha: 0.05),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.info_outline, color: AppTheme.primary),
                          const SizedBox(width: 8),
                          const Text(
                            'Camera Setup',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Configure your camera connection to monitor a zone. You can use HTTP streaming, RTSP, or direct camera access.',
                        style: TextStyle(fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              // Zone Name
              TextFormField(
                controller: _zoneNameController,
                decoration: const InputDecoration(
                  labelText: 'Zone Name *',
                  hintText: 'e.g., Main Entrance, Checkout Area',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a zone name';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              // Connection Type
              Text(
                'Connection Type *',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.foreground,
                ),
              ),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'http',
                    label: Text('HTTP'),
                    icon: Icon(Icons.http),
                  ),
                  ButtonSegment(
                    value: 'rtsp',
                    label: Text('RTSP'),
                    icon: Icon(Icons.video_call),
                  ),
                  ButtonSegment(
                    value: 'direct',
                    label: Text('Direct'),
                    icon: Icon(Icons.camera_alt),
                  ),
                ],
                selected: {_connectionType},
                onSelectionChanged: (Set<String> newSelection) {
                  setState(() {
                    _connectionType = newSelection.first;
                  });
                },
              ),
              const SizedBox(height: 16),
              // Camera URL (for HTTP)
              if (_connectionType == 'http')
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      controller: _cameraUrlController,
                      decoration: const InputDecoration(
                        labelText: 'Camera URL *',
                        hintText: 'http://192.168.1.100:8080/video',
                        border: OutlineInputBorder(),
                        helperText: 'Enter the HTTP streaming URL of your camera or external camera',
                      ),
                  validator: (value) {
                    if (_connectionType == 'http' && (value == null || value.trim().isEmpty)) {
                      return 'Please enter a camera URL';
                    }
                    if (value != null && value.trim().isNotEmpty) {
                      if (!value.startsWith('http://') && !value.startsWith('https://')) {
                        return 'URL must start with http:// or https://';
                      }
                    }
                    return null;
                  },
                    ),
                  ],
                ),
              // RTSP URL (for RTSP)
              if (_connectionType == 'rtsp')
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      controller: _rtspUrlController,
                      decoration: const InputDecoration(
                        labelText: 'RTSP URL *',
                        hintText: 'rtsp://192.168.1.100:554/stream',
                        border: OutlineInputBorder(),
                        helperText: 'Enter the RTSP streaming URL of your camera or external camera',
                      ),
                  validator: (value) {
                    if (_connectionType == 'rtsp' && (value == null || value.trim().isEmpty)) {
                      return 'Please enter an RTSP URL';
                    }
                    if (value != null && value.trim().isNotEmpty) {
                      if (!value.startsWith('rtsp://')) {
                        return 'URL must start with rtsp://';
                      }
                    }
                    return null;
                  },
                    ),
                  ],
                ),
              // Direct camera info
              if (_connectionType == 'direct')
                Card(
                  color: AppTheme.muted.withValues(alpha: 0.3),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.info, size: 20, color: AppTheme.primary),
                            const SizedBox(width: 8),
                            const Text(
                              'Direct Camera Access',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'The app will use the device\'s default camera. Make sure camera permissions are granted.',
                          style: TextStyle(fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              // Thresholds Section
              Text(
                'Congestion Thresholds',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.foreground,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Set the people count thresholds for different congestion levels',
                style: TextStyle(fontSize: 12, color: AppTheme.mutedForeground),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _lowThresholdController,
                      decoration: const InputDecoration(
                        labelText: 'Low',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Required';
                        }
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: _mediumThresholdController,
                      decoration: const InputDecoration(
                        labelText: 'Medium',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Required';
                        }
                        return null;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _highThresholdController,
                      decoration: const InputDecoration(
                        labelText: 'High',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Required';
                        }
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: _criticalThresholdController,
                      decoration: const InputDecoration(
                        labelText: 'Critical',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Required';
                        }
                        return null;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Service Speed
              TextFormField(
                controller: _serviceSpeedController,
                decoration: const InputDecoration(
                  labelText: 'Average Service Speed (minutes/person)',
                  hintText: '2.0',
                  border: OutlineInputBorder(),
                  helperText: 'Average number of people served per minute',
                ),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}')),
                ],
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter service speed';
                  }
                  final speed = double.tryParse(value);
                  if (speed == null || speed <= 0) {
                    return 'Must be a positive number';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 24),
              // Error/Success Messages
              if (_errorMessage != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.destructive.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.destructive),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: AppTheme.destructive),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(color: AppTheme.destructive),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_successMessage != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.green),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle, color: Colors.green),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _successMessage!,
                          style: const TextStyle(color: Colors.green),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 16),
              // Submit Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _handleSubmit,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(widget.zoneId != null ? 'Update Camera Setup' : 'Save Camera Setup'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

