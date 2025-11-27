import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ai_service.dart';

class VideoInfo {
  final String filename;
  final String path;
  final int timestamp;
  final String triggerReason;
  final String zoneId;
  final int durationSeconds;

  VideoInfo({
    required this.filename,
    required this.path,
    required this.timestamp,
    required this.triggerReason,
    required this.zoneId,
    required this.durationSeconds,
  });

  factory VideoInfo.fromMap(Map<String, dynamic> map) {
    // Convert seconds timestamp to milliseconds if needed
    // Handle both int and double types from JSON
    dynamic timestampValue = map['timestamp'] ?? 0;
    int timestamp = 0;
    if (timestampValue != null) {
      if (timestampValue is double) {
        timestamp = timestampValue.toInt();
      } else if (timestampValue is int) {
        timestamp = timestampValue;
      } else {
        timestamp = int.tryParse(timestampValue.toString()) ?? 0;
      }
    }
    
    // If timestamp is less than 1e12, it's likely in seconds, convert to milliseconds
    if (timestamp > 0 && timestamp < 1000000000000) {
      timestamp = timestamp * 1000;
    }
    
    // Handle duration_seconds which might be double
    dynamic durationValue = map['duration_seconds'] ?? 10;
    int durationSeconds = 10;
    if (durationValue != null) {
      if (durationValue is double) {
        durationSeconds = durationValue.toInt();
      } else if (durationValue is int) {
        durationSeconds = durationValue;
      } else {
        durationSeconds = int.tryParse(durationValue.toString()) ?? 10;
      }
    }
    
    return VideoInfo(
      filename: map['filename'] ?? '',
      path: map['path'] ?? '',
      timestamp: timestamp,
      triggerReason: map['trigger_reason'] ?? '',
      zoneId: map['zone_id'] ?? '',
      durationSeconds: durationSeconds,
    );
  }
}

class StorageInfo {
  final String zoneId;
  final int totalSizeBytes;
  final double totalSizeGb;
  final int maxSizeBytes;
  final double maxSizeGb;
  final double usagePercent;
  final bool isFull;
  final int videoCount;

  StorageInfo({
    required this.zoneId,
    required this.totalSizeBytes,
    required this.totalSizeGb,
    required this.maxSizeBytes,
    required this.maxSizeGb,
    required this.usagePercent,
    required this.isFull,
    required this.videoCount,
  });

  factory StorageInfo.fromMap(Map<String, dynamic> map) {
    return StorageInfo(
      zoneId: map['zone_id'] ?? '',
      totalSizeBytes: map['total_size_bytes'] ?? 0,
      totalSizeGb: (map['total_size_gb'] ?? 0.0).toDouble(),
      maxSizeBytes: map['max_size_bytes'] ?? 0,
      maxSizeGb: (map['max_size_gb'] ?? 0.0).toDouble(),
      usagePercent: (map['usage_percent'] ?? 0.0).toDouble(),
      isFull: map['is_full'] ?? false,
      videoCount: map['video_count'] ?? 0,
    );
  }
}

class VideoService {
  // Use the same baseUrl as AIService for consistency
  static String get baseUrl => AIService.baseUrl;
  static const String _downloadedVideosKey = 'downloaded_videos';

  /// Get local storage directory for videos (Mobile only)
  static Future<Directory?> _getVideoDirectory(String zoneId) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final videoDir = Directory('${appDir.path}/videos/$zoneId');
      if (!await videoDir.exists()) {
        await videoDir.create(recursive: true);
      }
      return videoDir;
    } catch (e) {
      print('Error getting video directory: $e');
      return null;
    }
  }

  /// Get local file path for a video (Mobile only)
  static Future<String?> getLocalVideoPath(String zoneId, String filename) async {
    try {
      final videoDir = await _getVideoDirectory(zoneId);
      if (videoDir == null) {
        return null;
      }
      
      final file = File('${videoDir.path}/$filename');
      if (await file.exists()) {
        return file.path;
      }
      return null;
    } catch (e) {
      print('Error getting local video path: $e');
      return null;
    }
  }

  /// Download video from backend to local storage
  static Future<String?> downloadVideo(String zoneId, String filename) async {
    try {
      // Check if already downloaded
      final localPath = await getLocalVideoPath(zoneId, filename);
      if (localPath != null) {
        print('✅ Video already downloaded: $filename');
        return localPath;
      }

      // Download from backend
      final url = '$baseUrl/zones/$zoneId/videos/$filename/stream';
      print('📥 Downloading video from: $url');
      
      final response = await http.get(
        Uri.parse(url),
      ).timeout(const Duration(seconds: 60)); // Increased timeout for large files

      if (response.statusCode == 200) {
        // For mobile platforms, save to file system
        final videoDir = await _getVideoDirectory(zoneId);
        if (videoDir == null) {
          print('Cannot get video directory, path_provider may not be initialized');
          return null;
        }
        
        final file = File('${videoDir.path}/$filename');
        await file.writeAsBytes(response.bodyBytes);

        // Track downloaded video
        await _markVideoDownloaded(zoneId, filename);

        return file.path;
      }
    } catch (e) {
      print('Error downloading video: $e');
    }
    return null;
  }

  /// Mark video as downloaded
  static Future<void> _markVideoDownloaded(String zoneId, String filename) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '${_downloadedVideosKey}_$zoneId';
    final downloaded = prefs.getStringList(key) ?? [];
    if (!downloaded.contains(filename)) {
      downloaded.add(filename);
      await prefs.setStringList(key, downloaded);
    }
  }

  /// Get list of downloaded videos for a zone
  static Future<List<String>> getDownloadedVideos(String zoneId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '${_downloadedVideosKey}_$zoneId';
    return prefs.getStringList(key) ?? [];
  }

  /// Get storage information for a zone (local device storage - Mobile only)
  static Future<StorageInfo> getLocalStorageInfo(String zoneId) async {
    try {
      final videoDir = await _getVideoDirectory(zoneId);
      if (videoDir == null) {
        // path_provider not available, return default
        return StorageInfo(
          zoneId: zoneId,
          totalSizeBytes: 0,
          totalSizeGb: 0,
          maxSizeBytes: 5 * 1024 * 1024 * 1024,
          maxSizeGb: 5.0,
          usagePercent: 0,
          isFull: false,
          videoCount: 0,
        );
      }
      
      int totalSize = 0;
      int videoCount = 0;

      if (await videoDir.exists()) {
        await for (final entity in videoDir.list()) {
          if (entity is File && entity.path.endsWith('.mp4')) {
            totalSize += await entity.length();
            videoCount++;
          }
        }
      }

      const maxSizeBytes = 5 * 1024 * 1024 * 1024; // 5GB
      return StorageInfo(
        zoneId: zoneId,
        totalSizeBytes: totalSize,
        totalSizeGb: totalSize / (1024 * 1024 * 1024),
        maxSizeBytes: maxSizeBytes,
        maxSizeGb: 5.0,
        usagePercent: (totalSize / maxSizeBytes) * 100,
        isFull: totalSize >= maxSizeBytes,
        videoCount: videoCount,
      );
    } catch (e) {
      print('Error getting local storage info: $e');
      return StorageInfo(
        zoneId: zoneId,
        totalSizeBytes: 0,
        totalSizeGb: 0,
        maxSizeBytes: 5 * 1024 * 1024 * 1024,
        maxSizeGb: 5.0,
        usagePercent: 0,
        isFull: false,
        videoCount: 0,
      );
    }
  }

  /// Get storage information from backend (for reference)
  static Future<StorageInfo?> getStorageInfo(String zoneId) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/zones/$zoneId/storage'),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return StorageInfo.fromMap(data);
      }
    } catch (e) {
      print('Error getting storage info: $e');
    }
    return null;
  }

  /// Get list of videos for a zone (from backend)
  static Future<List<VideoInfo>> getVideoList(String zoneId) async {
    try {
      final url = '$baseUrl/zones/$zoneId/videos';
      print('📡 Fetching video list from: $url (baseUrl=$baseUrl)');
      
      final response = await http.get(
        Uri.parse(url),
      ).timeout(const Duration(seconds: 15)); // Increased timeout

      print('📥 Video list response status: ${response.statusCode}');
      print('📥 Video list response body: ${response.body.substring(0, response.body.length > 200 ? 200 : response.body.length)}');
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final videos = data['videos'] as List?;
        if (videos != null) {
          print('✅ Parsed ${videos.length} videos from response');
          return videos.map((v) => VideoInfo.fromMap(v)).toList();
        } else {
          print('⚠️ No videos array in response. Response keys: ${data.keys}');
        }
      } else {
        print('❌ API returned status ${response.statusCode}: ${response.body}');
        // Don't throw error for 404 - zone might not be monitoring but videos exist
        if (response.statusCode == 404) {
          print('⚠️ Zone not monitoring, but videos may exist on disk');
        }
      }
    } catch (e) {
      print('❌ Error getting video list: $e');
      print('   Error type: ${e.runtimeType}');
      // Don't rethrow - return empty list instead
      // This allows UI to show "No Videos Found" instead of error
    }
    return [];
  }

  /// Delete a video from local storage (Mobile only)
  static Future<bool> deleteLocalVideo(String zoneId, String filename) async {
    try {
      // Remove from downloaded list first
      final prefs = await SharedPreferences.getInstance();
      final downloadedKey = '${_downloadedVideosKey}_$zoneId';
      final downloaded = prefs.getStringList(downloadedKey) ?? [];
      
      // Try to delete file
      final localPath = await getLocalVideoPath(zoneId, filename);
      bool fileDeleted = false;
      
      if (localPath != null) {
        try {
          final file = File(localPath);
          if (await file.exists()) {
            await file.delete();
            fileDeleted = true;
          }
        } catch (e) {
          print('Error deleting file: $e');
        }
      }
      
      // Remove from downloaded list
      downloaded.remove(filename);
      await prefs.setStringList(downloadedKey, downloaded);
      
      return fileDeleted;
    } catch (e) {
      print('Error deleting local video: $e');
      return false;
    }
  }

  /// Delete a video from backend
  static Future<bool> deleteVideo(String zoneId, String videoFilename) async {
    try {
      final response = await http.delete(
        Uri.parse('$baseUrl/zones/$zoneId/videos/$videoFilename'),
      ).timeout(const Duration(seconds: 5));

      return response.statusCode == 200;
    } catch (e) {
      print('Error deleting video: $e');
      return false;
    }
  }

  /// Delete video from both local and backend
  static Future<bool> deleteVideoEverywhere(String zoneId, String videoFilename) async {
    final localDeleted = await deleteLocalVideo(zoneId, videoFilename);
    final backendDeleted = await deleteVideo(zoneId, videoFilename);
    return localDeleted || backendDeleted;
  }

  /// Sync videos: download new videos from backend
  static Future<void> syncVideos(String zoneId) async {
    try {
      final videos = await getVideoList(zoneId);
      final downloaded = await getDownloadedVideos(zoneId);
      
      for (final video in videos) {
        if (!downloaded.contains(video.filename)) {
          // Check local storage before downloading
          final storageInfo = await getLocalStorageInfo(zoneId);
          if (!storageInfo.isFull) {
            await downloadVideo(zoneId, video.filename);
          }
        }
      }
    } catch (e) {
      print('Error syncing videos: $e');
    }
  }

  /// Check if local storage is full
  static Future<bool> checkStorageFull(String zoneId) async {
    final storageInfo = await getLocalStorageInfo(zoneId);
    return storageInfo.isFull;
  }
}

