import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/video_service.dart';
import '../../theme/app_theme.dart';

class PlaybackPage extends StatefulWidget {
  const PlaybackPage({super.key});

  @override
  State<PlaybackPage> createState() => _PlaybackPageState();
}

class _PlaybackPageState extends State<PlaybackPage> {
  List<ZoneData> _zones = [];
  String? _selectedZoneId;
  bool _isLoading = true;
  bool _isLoadingVideos = false;
  String _sortOrder = 'latest'; // 'latest' or 'oldest'
  List<VideoInfo> _videos = [];
  StorageInfo? _storageInfo;
  Timer? _storageCheckTimer;
  Set<String> _downloadedVideos = {};
  Set<String> _selectedVideos = {}; // For multi-select
  bool _isSelectionMode = false;

  @override
  void initState() {
    super.initState();
    _loadZones();
    // Check storage every 30 seconds
    _storageCheckTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkStorageStatus();
    });
  }

  @override
  void dispose() {
    _storageCheckTimer?.cancel();
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
        setState(() {
          _zones = zones;
          if (zones.isNotEmpty) {
            _selectedZoneId = zones.first.id;
            _loadVideos();
            _checkStorageStatus();
          }
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _loadVideos() async {
    if (_selectedZoneId == null) return;

    setState(() {
      _isLoadingVideos = true;
    });

    try {
      print('📹 Loading videos for zone: $_selectedZoneId');
      
      // Get video list from backend first (don't wait for sync)
      final videos = await VideoService.getVideoList(_selectedZoneId!);
      print('✅ Loaded ${videos.length} videos from backend');
      
      // Get list of downloaded videos
      final downloaded = await VideoService.getDownloadedVideos(_selectedZoneId!);
      print('✅ Found ${downloaded.length} downloaded videos');
      
      setState(() {
        _videos = videos;
        _downloadedVideos = downloaded.toSet();
        _isLoadingVideos = false;
      });
      
      // Sync videos in background (don't block UI)
      VideoService.syncVideos(_selectedZoneId!).then((_) {
        print('✅ Video sync completed');
        // Refresh downloaded list after sync
        VideoService.getDownloadedVideos(_selectedZoneId!).then((downloaded) {
          if (mounted) {
            setState(() {
              _downloadedVideos = downloaded.toSet();
            });
          }
        });
      }).catchError((e) {
        print('⚠️ Video sync error (non-critical): $e');
      });
    } catch (e) {
      print('❌ Error loading videos: $e');
      if (mounted) {
        setState(() {
          _isLoadingVideos = false;
        });
        // Show error message to user
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load videos: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Retry',
              textColor: Colors.white,
              onPressed: () => _loadVideos(),
            ),
          ),
        );
      }
    }
  }

  Future<void> _checkStorageStatus() async {
    if (_selectedZoneId == null) return;

    try {
      // Check local device storage (not backend storage)
      final storageInfo = await VideoService.getLocalStorageInfo(_selectedZoneId!);
      setState(() {
        _storageInfo = storageInfo;
      });

      // Show alert if storage is full
      if (storageInfo.isFull && mounted) {
        _showStorageFullAlert();
      }
    } catch (e) {
      print('Error checking storage status: $e');
    }
  }

  void _showStorageFullAlert() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Storage Limit Reached'),
        content: const Text(
          'Local storage limit reached (5GB). Please clear old recordings from this device.',
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

  Future<void> _deleteVideo(VideoInfo video) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Video'),
        content: Text('Are you sure you want to delete "${video.filename}"?\n\nThis will delete the video from both the server and this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && _selectedZoneId != null) {
      try {
        // Delete from both backend and local storage
        final localDeleted = await VideoService.deleteLocalVideo(_selectedZoneId!, video.filename);
        final backendDeleted = await VideoService.deleteVideo(_selectedZoneId!, video.filename);
        
        if (mounted) {
          if (localDeleted || backendDeleted) {
            setState(() {
              _downloadedVideos.remove(video.filename);
              // Remove from video list
              _videos.removeWhere((v) => v.filename == video.filename);
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Video deleted successfully')),
            );
            _checkStorageStatus();
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Failed to delete video')),
            );
          }
        }
      } catch (e) {
        print('Error deleting video: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error deleting video: $e')),
          );
        }
      }
    }
  }

  List<VideoInfo> get _sortedVideos {
    var videos = List<VideoInfo>.from(_videos);
    
    // Sort by timestamp
    if (_sortOrder == 'latest') {
      // Newest first (default)
      videos.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    } else {
      // Oldest first
      videos.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    }
    
    return videos;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'View Playback',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 20),
        ),
        actions: [
          if (_storageInfo != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Local Storage',
                    style: TextStyle(
                      fontSize: 10,
                      color: AppTheme.mutedForeground,
                    ),
                  ),
                  Text(
                    '${_storageInfo!.totalSizeGb.toStringAsFixed(2)} / ${_storageInfo!.maxSizeGb.toStringAsFixed(2)} GB',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _storageInfo!.isFull ? Colors.red : null,
                    ),
                  ),
                ],
              ),
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) async {
              if (value == 'refresh') {
                _loadVideos();
                _checkStorageStatus();
              } else if (value == 'cleanup') {
                await _cleanupMetadata();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'refresh',
                child: Row(
                  children: [
                    Icon(Icons.refresh, size: 20),
                    SizedBox(width: 8),
                    Text('Refresh & Sync'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'cleanup',
                child: Row(
                  children: [
                    Icon(Icons.cleaning_services, size: 20),
                    SizedBox(width: 8),
                    Text('Clean Up Invalid Videos'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _zones.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.video_library_outlined,
                          size: 64, color: AppTheme.mutedForeground),
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
                    // Zone selector and search
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          // Local mode warning
                          if (_selectedZoneId != null && 
                              _zones.firstWhere((z) => z.id == _selectedZoneId).cameraUrl == 'local')
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
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      'Local Camera mode does not support cloud recording. Only real-time monitoring is available.',
                                      style: TextStyle(color: Colors.orange.shade900, fontSize: 13),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                          DropdownButtonFormField<String>(
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
                              _loadVideos();
                              _checkStorageStatus();
                            },
                          ),
                          const SizedBox(height: 12),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  value: _sortOrder,
                                  decoration: const InputDecoration(
                                    labelText: 'Sort By',
                                    border: OutlineInputBorder(),
                                    prefixIcon: Icon(Icons.sort),
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'latest',
                                      child: Row(
                                        children: [
                                          Icon(Icons.arrow_downward, size: 16),
                                          SizedBox(width: 8),
                                          Text('Latest First'),
                                        ],
                                      ),
                                    ),
                                    DropdownMenuItem(
                                      value: 'oldest',
                                      child: Row(
                                        children: [
                                          Icon(Icons.arrow_upward, size: 16),
                                          SizedBox(width: 8),
                                          Text('Oldest First'),
                                        ],
                                      ),
                                    ),
                                  ],
                                  onChanged: (value) {
                                    if (value != null) {
                                      setState(() {
                                        _sortOrder = value;
                                      });
                                    }
                                  },
                                ),
                              ),
                              const SizedBox(width: 12),
                              // Batch delete button
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    onPressed: () {
                                      setState(() {
                                        _isSelectionMode = !_isSelectionMode;
                                        if (!_isSelectionMode) {
                                          _selectedVideos.clear();
                                        }
                                      });
                                    },
                                    icon: Icon(
                                      _isSelectionMode ? Icons.checklist_rtl : Icons.checklist,
                                      color: _isSelectionMode ? AppTheme.primary : null,
                                    ),
                                    tooltip: _isSelectionMode ? 'Exit Selection Mode' : 'Select Videos',
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Batch Delete',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: AppTheme.mutedForeground,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          if (_isSelectionMode) ...[
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  '${_selectedVideos.length} video${_selectedVideos.length != 1 ? 's' : ''} selected',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: () => _selectAllVideos(),
                                  icon: Icon(_selectedVideos.length == _sortedVideos.length
                                      ? Icons.deselect
                                      : Icons.select_all),
                                  label: Text(_selectedVideos.length == _sortedVideos.length
                                      ? 'Deselect All'
                                      : 'Select All'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: _selectedVideos.isEmpty
                                    ? null
                                    : () => _deleteSelectedVideos(),
                                icon: const Icon(Icons.delete_outline),
                                label: Text(
                                  'Delete Selected (${_selectedVideos.length})',
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    // Video list
                    Expanded(
                      child: _isLoadingVideos
                          ? const Center(child: CircularProgressIndicator())
                          : _sortedVideos.isEmpty
                              ? Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.video_library_outlined,
                                          size: 64,
                                          color: AppTheme.mutedForeground),
                                      const SizedBox(height: 16),
                                      Text(
                                        'No Videos Found',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: AppTheme.foreground,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        'Videos will appear here when triggers occur',
                                        style:
                                            TextStyle(color: AppTheme.mutedForeground),
                                      ),
                                    ],
                                  ),
                                )
                              : RefreshIndicator(
                                  onRefresh: _loadVideos,
                                  child: ListView.builder(
                                    padding: const EdgeInsets.all(16),
                                    itemCount: _sortedVideos.length,
                                    itemBuilder: (context, index) {
                                      final video = _sortedVideos[index];
                                      return _buildVideoItem(video);
                                    },
                                  ),
                                ),
                    ),
                  ],
                ),
    );
  }

  Widget _buildVideoItem(VideoInfo video) {
    final isDownloaded = _downloadedVideos.contains(video.filename);
    final isSelected = _selectedVideos.contains(video.filename);
    
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: isSelected ? AppTheme.primary.withValues(alpha: 0.1) : null,
      child: Column(
        children: [
          Stack(
            children: [
              // Video thumbnail - clickable to play
              InkWell(
                onTap: _isSelectionMode
                    ? () {
                        setState(() {
                          if (isSelected) {
                            _selectedVideos.remove(video.filename);
                          } else {
                            _selectedVideos.add(video.filename);
                          }
                        });
                      }
                    : () => _showVideoPlayer(video),
                child: Container(
                  width: double.infinity,
                  height: 200,
                  decoration: BoxDecoration(
                    color: AppTheme.muted,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Stack(
                    children: [
                      // Video thumbnail placeholder
                      Center(
                        child: Icon(
                          Icons.play_circle_outline,
                          size: 64,
                          color: AppTheme.mutedForeground,
                        ),
                      ),
                      // Selection checkbox (if in selection mode)
                      if (_isSelectionMode)
                        Positioned(
                          top: 8,
                          left: 8,
                          child: Checkbox(
                            value: isSelected,
                            onChanged: (value) {
                              setState(() {
                                if (value == true) {
                                  _selectedVideos.add(video.filename);
                                } else {
                                  _selectedVideos.remove(video.filename);
                                }
                              });
                            },
                          ),
                        ),
                      // Downloaded indicator (only show if not in selection mode and not showing delete button)
                      if (isDownloaded && !_isSelectionMode)
                        Positioned(
                          top: 8,
                          left: 8,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: const BoxDecoration(
                              color: Colors.green,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.check,
                              size: 16,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // Delete button (only show if not in selection mode)
              if (!_isSelectionMode)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => _deleteVideo(video),
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.9),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.delete_outline,
                          size: 20,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          // Video filename
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              video.filename,
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

  void _selectAllVideos() {
    setState(() {
      if (_selectedVideos.length == _sortedVideos.length) {
        // Deselect all
        _selectedVideos.clear();
      } else {
        // Select all
        _selectedVideos = _sortedVideos.map((v) => v.filename).toSet();
      }
    });
  }

  Future<void> _deleteSelectedVideos() async {
    if (_selectedVideos.isEmpty || _selectedZoneId == null) return;

    final count = _selectedVideos.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Videos'),
        content: Text(
          'Are you sure you want to delete $count video${count != 1 ? 's' : ''}?\n\nThis will delete the videos from both the server and this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      int successCount = 0;
      int failCount = 0;

      for (final filename in _selectedVideos) {
        try {
          // Delete from both backend and local storage
          final localDeleted = await VideoService.deleteLocalVideo(_selectedZoneId!, filename);
          final backendDeleted = await VideoService.deleteVideo(_selectedZoneId!, filename);
          
          if (localDeleted || backendDeleted) {
            successCount++;
            _downloadedVideos.remove(filename);
            _videos.removeWhere((v) => v.filename == filename);
          } else {
            failCount++;
          }
        } catch (e) {
          print('Error deleting video $filename: $e');
          failCount++;
        }
      }

      if (mounted) {
        setState(() {
          _selectedVideos.clear();
          _isSelectionMode = false;
        });

        String message;
        if (failCount == 0) {
          message = 'Successfully deleted $successCount video${successCount != 1 ? 's' : ''}';
        } else {
          message = 'Deleted $successCount video${successCount != 1 ? 's' : ''}, failed to delete $failCount';
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );

        _checkStorageStatus();
      }
    }
  }

  void _showVideoPlayer(VideoInfo video) {
    // Check if video exists before showing player
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => VideoPlayerDialog(video: video),
    );
  }

  Future<void> _cleanupMetadata() async {
    if (_selectedZoneId == null) return;

    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(),
      ),
    );

    try {
      final result = await VideoService.cleanupVideoMetadata(_selectedZoneId!);
      
      if (mounted) {
        Navigator.of(context).pop(); // Close loading dialog
        
        if (result != null) {
          final removedCount = result['removed_count'] ?? 0;
          final remainingCount = result['remaining_count'] ?? 0;
          
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                removedCount > 0
                    ? 'Cleaned up $removedCount invalid video${removedCount != 1 ? 's' : ''}. $remainingCount video${remainingCount != 1 ? 's' : ''} remaining.'
                    : 'No invalid videos found. All videos are valid.',
              ),
              duration: const Duration(seconds: 3),
            ),
          );
          
          // Reload videos to reflect cleanup
          _loadVideos();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to cleanup metadata'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // Close loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error cleaning up metadata: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

}

class VideoPlayerDialog extends StatefulWidget {
  final VideoInfo video;

  const VideoPlayerDialog({super.key, required this.video});

  @override
  State<VideoPlayerDialog> createState() => _VideoPlayerDialogState();
}

class _VideoPlayerDialogState extends State<VideoPlayerDialog> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    try {
      // First, try to get local file path
      String? localPath = await VideoService.getLocalVideoPath(
        widget.video.zoneId,
        widget.video.filename,
      );

      // If not downloaded locally, download it first
      if (localPath == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Downloading video...')),
          );
        }
        localPath = await VideoService.downloadVideo(
          widget.video.zoneId,
          widget.video.filename,
        );
      }

      if (localPath == null) {
        throw Exception('Failed to get video file. Please check your connection and try again.');
      }

      // Use local file or network URL for video player
      if (localPath.startsWith('http://') || localPath.startsWith('https://')) {
        // Network URL (fallback when path_provider fails)
        print('Loading video from URL: $localPath');
        _controller = VideoPlayerController.networkUrl(
          Uri.parse(localPath),
        );
      } else {
        // Mobile platform with local file
        print('Loading video from file: $localPath');
        final file = File(localPath);
        if (!await file.exists()) {
          throw Exception('Video file not found. Please try downloading again.');
        }
        _controller = VideoPlayerController.file(file);
      }

      // Initialize with timeout
      await _controller!.initialize().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw Exception('Video loading timeout. The video format may not be supported.');
        },
      );
      
      _controller!.addListener(_videoListener);

      if (mounted) {
        setState(() {
          _isInitialized = true;
          _duration = _controller!.value.duration;
          _isPlaying = _controller!.value.isPlaying;
        });
      }
    } catch (e) {
      print('Error initializing video player: $e');
      if (mounted) {
        // Close dialog and show error
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading video: ${e.toString()}'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  void _videoListener() {
    if (_controller != null && mounted) {
      setState(() {
        _position = _controller!.value.position;
        _isPlaying = _controller!.value.isPlaying;
      });
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_videoListener);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.8,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.video.filename,
                      style: const TextStyle(color: Colors.white),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            // Video player
            Expanded(
              child: _isInitialized && _controller != null
                  ? Center(
                      child: AspectRatio(
                        aspectRatio: _controller!.value.aspectRatio,
                        child: VideoPlayer(_controller!),
                      ),
                    )
                  : const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
            ),
            // Controls
            if (_isInitialized && _controller != null) ...[
              // Progress bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: VideoProgressIndicator(
                  _controller!,
                  allowScrubbing: true,
                  colors: const VideoProgressColors(
                    playedColor: Colors.blue,
                    bufferedColor: Colors.grey,
                    backgroundColor: Colors.white24,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // Control buttons
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: Icon(
                        _isPlaying ? Icons.pause : Icons.play_arrow,
                        color: Colors.white,
                        size: 48,
                      ),
                      onPressed: () {
                        if (_isPlaying) {
                          _controller!.pause();
                        } else {
                          _controller!.play();
                        }
                      },
                    ),
                    const SizedBox(width: 16),
                    Text(
                      '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }
}
