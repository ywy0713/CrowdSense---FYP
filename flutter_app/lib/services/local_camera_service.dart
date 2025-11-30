import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Service for accessing local device camera using Flutter camera package
class LocalCameraService {
  static CameraController? _controller;
  static CameraDescription? _camera;
  static bool _isInitialized = false;
  static Function(CameraImage)? _onImageAvailable;

  /// Initialize camera service
  static Future<bool> initialize({int cameraIndex = 0}) async {
    try {
      // Request camera permission
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        debugPrint('❌ Camera permission denied');
        return false;
      }

      // Get available cameras
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        debugPrint('❌ No cameras available');
        return false;
      }

      // Select camera (default to first available)
      _camera = cameras.length > cameraIndex ? cameras[cameraIndex] : cameras.first;
      debugPrint('📹 Selected camera: ${_camera!.name}');

      // Initialize controller
      _controller = CameraController(
        _camera!,
        ResolutionPreset.medium, // 480p for better performance
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.yuv420
            : ImageFormatGroup.bgra8888,
      );

      await _controller!.initialize();
      _isInitialized = true;
      debugPrint('✅ Camera initialized successfully');
      return true;
    } catch (e) {
      debugPrint('❌ Error initializing camera: $e');
      _isInitialized = false;
      return false;
    }
  }

  /// Start camera preview
  static Future<bool> startPreview() async {
    if (!_isInitialized || _controller == null) {
      debugPrint('⚠️ Camera not initialized');
      return false;
    }

    try {
      await _controller!.startImageStream(_handleImage);
      debugPrint('✅ Camera preview started');
      return true;
    } catch (e) {
      debugPrint('❌ Error starting preview: $e');
      return false;
    }
  }

  /// Stop camera preview
  static Future<void> stopPreview() async {
    try {
      if (_controller != null && _controller!.value.isStreamingImages) {
        await _controller!.stopImageStream();
        debugPrint('✅ Camera preview stopped');
      }
    } catch (e) {
      debugPrint('❌ Error stopping preview: $e');
    }
  }

  /// Handle incoming camera images
  static void _handleImage(CameraImage image) {
    if (_onImageAvailable != null) {
      _onImageAvailable!(image);
    }
  }

  /// Set callback for image processing
  static void setImageCallback(Function(CameraImage) callback) {
    _onImageAvailable = callback;
  }

  /// Get camera controller (for preview widget)
  static CameraController? get controller => _controller;

  /// Check if camera is initialized
  static bool get isInitialized => _isInitialized;

  /// Get current camera
  static CameraDescription? get camera => _camera;

  /// Dispose camera service
  static Future<void> dispose() async {
    try {
      await stopPreview();
      if (_controller != null) {
        await _controller!.dispose();
        _controller = null;
      }
      _isInitialized = false;
      _camera = null;
      _onImageAvailable = null;
      debugPrint('✅ Camera service disposed');
    } catch (e) {
      debugPrint('❌ Error disposing camera: $e');
    }
  }

  /// Take a picture
  static Future<XFile?> takePicture() async {
    if (!_isInitialized || _controller == null) {
      return null;
    }

    try {
      final image = await _controller!.takePicture();
      return image;
    } catch (e) {
      debugPrint('❌ Error taking picture: $e');
      return null;
    }
  }

  /// Get available cameras
  static Future<List<CameraDescription>> getAvailableCameras() async {
    try {
      return await availableCameras();
    } catch (e) {
      debugPrint('❌ Error getting cameras: $e');
      return [];
    }
  }
}

