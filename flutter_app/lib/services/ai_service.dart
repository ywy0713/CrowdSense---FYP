import 'dart:convert';
import 'package:http/http.dart' as http;
import 'dart:io' show Platform;
import '../services/data_service.dart';

class AIService {
  // Get base URL based on platform (Mobile only)
  // Android Emulator: 10.0.2.2 (special IP to access host machine)
  // iOS Simulator: localhost
  // Physical Android Device: Use your computer's IP address (e.g., 192.168.1.100)
  static String get baseUrl {
    if (Platform.isAndroid) {
      // Android emulator uses 10.0.2.2 to access host machine's localhost
      // For physical Android device, replace with your computer's IP
      return 'http://10.0.2.2:8000';
    } else if (Platform.isIOS) {
      // iOS simulator can use localhost
      return 'http://localhost:8000';
    } else {
      // Default for other mobile platforms
      return 'http://10.0.2.2:8000';
    }
  }
  
  // Helper method to get stream URL (same logic as baseUrl)
  static String getStreamUrl(String zoneId) {
    final base = baseUrl;
    return '$base/zones/$zoneId/stream';
  }

  /// Start monitoring a zone
  static Future<bool> startZoneMonitoring(String zoneId, ZoneData zone) async {
    try {
      // Get camera URL
      String cameraUrl = zone.cameraUrl ?? '';

      // Get base URL for current platform
      final serviceBaseUrl = baseUrl;
      
      // First check if service is reachable
      try {
        print('🔍 Checking AI service health at $serviceBaseUrl...');
        final healthCheck = await http.get(
          Uri.parse('$serviceBaseUrl/'),
        ).timeout(const Duration(seconds: 5));
        print('✅ Health check response: ${healthCheck.statusCode}');
        if (healthCheck.statusCode != 200) {
          throw Exception('Service returned status ${healthCheck.statusCode}');
        }
        print('✅ AI service is reachable');
      } catch (e) {
        print('❌ Cannot reach AI service at $serviceBaseUrl');
        print('   Error type: ${e.runtimeType}');
        print('   Error message: $e');
        rethrow;
      }

      print('📤 Sending start monitoring request for zone: $zoneId');
      final requestBody = {
        'zone_id': zoneId,
        'name': zone.name,
        'camera_url': cameraUrl.isEmpty ? (zone.rtspUrl ?? '0') : cameraUrl,
        'rtsp_url': zone.rtspUrl,
        'thresholds': {
          'low': zone.thresholds.low,
          'medium': zone.thresholds.medium,
          'high': zone.thresholds.high,
          'critical': zone.thresholds.critical,
        },
        'average_service_speed': zone.averageServiceSpeed ?? 2.0,
        'enabled': true,
      };
      print('📦 Request body: ${jsonEncode(requestBody)}');
      
      final response = await http.post(
        Uri.parse('$serviceBaseUrl/zones/start'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(requestBody),
      ).timeout(const Duration(seconds: 5)); // Reduced timeout since endpoint returns immediately
      
      print('📥 Response status: ${response.statusCode}');
      print('📥 Response body: ${response.body}');

      if (response.statusCode == 200) {
        print('✅ AI service started for zone: $zoneId');
        return true;
      } else {
        print('❌ Failed to start AI service: ${response.statusCode} - ${response.body}');
        return false;
      }
    } catch (e) {
      print('⚠️ Error starting AI service:');
      print('   Error type: ${e.runtimeType}');
      print('   Error message: $e');
      if (e.toString().contains('TimeoutException') || e.toString().contains('timeout')) {
        print('   ⚠️ Request timed out. The service may be slow to respond.');
      } else if (e.toString().contains('SocketException') || e.toString().contains('Failed host lookup')) {
        print('   ⚠️ Cannot connect to service. Is it running?');
      }
      print('   Note: Make sure the Python AI service is running at ${baseUrl}');
      rethrow; // Re-throw to let caller handle the error
    }
  }

  /// Stop monitoring a zone
  static Future<bool> stopZoneMonitoring(String zoneId) async {
    try {
      final response = await http.post(
        Uri.parse('${baseUrl}/zones/$zoneId/stop'),
        headers: {'Content-Type': 'application/json'},
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        print('✅ AI service stopped for zone: $zoneId');
        return true;
      } else if (response.statusCode == 404) {
        // Zone not in monitoring tasks - this is OK for HTTP mode using external streams
        print('ℹ️ Zone $zoneId not in monitoring tasks (may be using external stream)');
        return false; // Return false but don't treat as error
      } else {
        print('❌ Failed to stop AI service: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      // Re-throw to let caller handle (especially 404 for HTTP mode)
      print('⚠️ Error stopping AI service: $e');
      rethrow;
    }
  }

  /// Get status of all monitored zones
  static Future<Map<String, dynamic>?> getStatus() async {
    try {
      final response = await http.get(Uri.parse('${baseUrl}/zones/status'));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      print('⚠️ Error getting AI service status: $e');
      return null;
    }
  }

  /// Stop external camera server
  static Future<bool> stopExternalCameraServer() async {
    try {
      final response = await http.post(
        Uri.parse('${baseUrl}/external-camera/stop'),
        headers: {'Content-Type': 'application/json'},
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        print('✅ External camera server stopped');
        return true;
      } else {
        print('❌ Failed to stop external camera server: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      print('⚠️ Error stopping external camera server: $e');
      return false;
    }
  }

  /// Check if HTTP URL is from external camera server
  static bool isExternalCameraServerUrl(String? url) {
    if (url == null || !url.startsWith('http')) return false;
    try {
      final uri = Uri.parse(url);
      final isLocalhost = uri.host == 'localhost' || 
                         uri.host == '127.0.0.1' || 
                         uri.host == '0.0.0.0' ||
                         uri.host.startsWith('192.168.') ||
                         uri.host.startsWith('10.') ||
                         uri.host.startsWith('172.');
      final isVideoPath = uri.path == '/video' || uri.path.endsWith('/video');
      final isPort8080 = uri.port == 8080;
      return isLocalhost && isVideoPath && isPort8080;
    } catch (e) {
      return false;
    }
  }
}
