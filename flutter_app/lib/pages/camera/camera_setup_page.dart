import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
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
  final _lowThresholdController = TextEditingController(text: '20');
  final _mediumThresholdController = TextEditingController(text: '50');
  final _highThresholdController = TextEditingController(text: '80');
  final _criticalThresholdController = TextEditingController(text: '120');
  final _serviceSpeedController = TextEditingController(text: '2.0');

  String _connectionType = 'local'; // 'local' or 'http'
  bool _isLoading = false;
  bool _isLoadingZone = true;
  String? _errorMessage;
  String? _successMessage;
  String? _zonePermission; // 'view', 'edit', or null (owner)
  bool _isReadOnly = false;

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
      final user = AuthService.getCurrentUser();
      final zone = await DataService.getZone(zoneId, userId: user?.uid);
      if (zone != null) {
        // Check permission
        if (user != null) {
          _zonePermission = await DataService.getZonePermission(user.uid, zoneId);
          _isReadOnly = _zonePermission == 'view'; // Read-only if view permission
        }
        
        setState(() {
          _zoneNameController.text = zone.name;
          _lowThresholdController.text = zone.thresholds.low.toString();
          _mediumThresholdController.text = zone.thresholds.medium.toString();
          _highThresholdController.text = zone.thresholds.high.toString();
          _criticalThresholdController.text = zone.thresholds.critical.toString();
          _serviceSpeedController.text = (zone.averageServiceSpeed ?? 2.0).toString();

          // Load zone configuration
          if (zone.cameraUrl == 'local') {
            _connectionType = 'local';
          } else if (zone.cameraUrl != null && zone.cameraUrl!.startsWith('http')) {
            _connectionType = 'http';
            _cameraUrlController.text = zone.cameraUrl!;
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

    // Check permission for editing
    if (_isReadOnly) {
      setState(() {
        _errorMessage = 'You only have view permission. You cannot edit this camera setup.';
      });
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
      
      // Double-check permission before updating
      if (widget.zoneId != null) {
        final permission = await DataService.getZonePermission(user.uid, widget.zoneId!);
        if (permission == 'view') {
          setState(() {
            _errorMessage = 'You only have view permission. You cannot edit this camera setup.';
            _isLoading = false;
          });
          return;
        }
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

      // Set camera URL based on connection type
      if (_connectionType == 'http' && _cameraUrlController.text.trim().isNotEmpty) {
        // HTTP mode - use external camera server
        zoneData['cameraUrl'] = _cameraUrlController.text.trim();
      } else {
        // Local mode - use device camera
        zoneData['cameraUrl'] = 'local';
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
        await DataService.createZone(user.uid, zoneData);
        setState(() {
          _successMessage = 'Camera setup completed successfully!';
          _isLoading = false;
        });

        // Request camera permission for local mode
        _requestCameraPermission().catchError((error) {
          print('⚠️ Could not request camera permission: $error');
        });
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

  Future<void> _requestCameraPermission() async {
    // Request camera permission for local mode
    final status = await Permission.camera.request();
    
    if (!mounted) return;

    if (status.isDenied) {
      if (mounted) {
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Camera Permission Required'),
            content: const Text(
              'CrowdSense needs camera access to use local camera mode. '
              'Please allow camera access in your device settings.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } else if (status.isPermanentlyDenied) {
      if (mounted) {
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Camera Permission Required'),
            content: const Text(
              'Camera permission is permanently denied. Please enable it in settings.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
              TextButton(
                onPressed: () {
                  openAppSettings();
                  Navigator.of(context).pop();
                },
                child: const Text('Open Settings'),
              ),
            ],
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
              // Permission warning for view-only users
              if (_isReadOnly && widget.zoneId != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    border: Border.all(color: Colors.orange.shade300),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.orange.shade700),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'You have view-only permission. You cannot edit this camera setup.',
                          style: TextStyle(color: Colors.orange.shade900),
                        ),
                      ),
                    ],
                  ),
                ),
              // Zone Name
              TextFormField(
                controller: _zoneNameController,
                readOnly: _isReadOnly,
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
              // Connection Type Selection
              Text(
                'Camera Connection Type *',
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
                    value: 'local',
                    label: Text('Local'),
                    icon: Icon(Icons.camera_alt),
                  ),
                  ButtonSegment(
                    value: 'http',
                    label: Text('HTTP'),
                    icon: Icon(Icons.http),
                  ),
                ],
                selected: {_connectionType},
                onSelectionChanged: _isReadOnly ? null : (Set<String> newSelection) {
                  setState(() {
                    _connectionType = newSelection.first;
                  });
                },
              ),
              const SizedBox(height: 16),
              // HTTP Camera URL
              if (_connectionType == 'http')
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      controller: _cameraUrlController,
                      readOnly: _isReadOnly,
                      decoration: const InputDecoration(
                        labelText: 'HTTP Camera URL *',
                        hintText: 'http://192.168.1.100:8080/video',
                        border: OutlineInputBorder(),
                        helperText: 'Enter the HTTP streaming URL from external camera server (e.g., python main.py --enable-external-camera)',
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
                      readOnly: _isReadOnly,
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
                      readOnly: _isReadOnly,
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
                      readOnly: _isReadOnly,
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
                      readOnly: _isReadOnly,
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
                readOnly: _isReadOnly,
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
                  onPressed: (_isLoading || _isReadOnly) ? null : _handleSubmit,
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

