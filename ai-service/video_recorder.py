"""
Video Recording Service for CrowdSense
Handles video recording with pre-trigger buffering and storage management
"""

import os
import cv2
import numpy as np
from datetime import datetime
from typing import Deque, Optional, Tuple
from collections import deque
import threading
import json
from pathlib import Path
import subprocess
import shutil


class VideoRecorder:
    """Manages video recording with frame buffering for pre-trigger capture"""
    
    # Storage limit: 5GB in bytes
    MAX_STORAGE_BYTES = 5 * 1024 * 1024 * 1024  # 5GB
    
    def __init__(self, zone_id: str, storage_path: str = "recordings"):
        self.zone_id = zone_id
        self.storage_path = Path(storage_path) / zone_id
        self.storage_path.mkdir(parents=True, exist_ok=True)
        
        # Frame buffer: stores frames for 3 seconds before trigger (90 frames at 30 FPS)
        self.frame_buffer: Deque[Tuple[np.ndarray, float]] = deque(maxlen=90)
        
        # Recording state
        self.is_recording = False
        self.current_video_writer: Optional[cv2.VideoWriter] = None
        self.recorded_frames_count = 0
        self.recording_start_time: Optional[float] = None
        
        # Thread lock for thread-safe operations
        self.lock = threading.Lock()
        
        # Track previous count for trigger detection
        self.previous_count = 0
        self.previous_threshold_crossed = set()  # Track which thresholds were crossed
        
        # Metadata file path
        self.metadata_file = self.storage_path / "metadata.json"
        self._load_metadata()
    
    def _load_metadata(self):
        """Load video metadata from file"""
        if self.metadata_file.exists():
            try:
                with open(self.metadata_file, 'r') as f:
                    self.metadata = json.load(f)
            except:
                self.metadata = {"videos": []}
        else:
            self.metadata = {"videos": []}
    
    def _save_metadata(self):
        """Save video metadata to file"""
        try:
            with open(self.metadata_file, 'w') as f:
                json.dump(self.metadata, f, indent=2)
        except Exception as e:
            print(f"[ERROR] Failed to save metadata: {e}")
    
    def add_frame(self, frame: np.ndarray, timestamp: float):
        """
        Add a frame to the buffer (always called at 30 FPS)
        This maintains a 3-second buffer of frames
        """
        with self.lock:
            # Always add frames to buffer (maxlen ensures only last 90 frames kept)
            self.frame_buffer.append((frame.copy(), timestamp))
            
            # If recording, write frame to video
            if self.is_recording and self.current_video_writer is not None:
                self.current_video_writer.write(frame)
                self.recorded_frames_count += 1
                
                # Stop recording after 7 seconds (210 frames at 30 FPS)
                if self.recorded_frames_count >= 210:
                    self._stop_recording()
    
    def check_triggers(self, current_count: int, thresholds: dict) -> Tuple[bool, str]:
        """
        Check if recording should be triggered
        Returns: (should_trigger, trigger_reason)
        """
        with self.lock:
            # Trigger 1: Count changes from 0 → 1
            if self.previous_count == 0 and current_count == 1:
                self.previous_count = current_count
                return True, "count_0_to_1"
            
            # Trigger 2: Count crosses threshold boundaries (e.g., 10, 20, 30...)
            # Get all threshold values
            threshold_values = [
                thresholds.get('low', 20),
                thresholds.get('medium', 50),
                thresholds.get('high', 80),
                thresholds.get('critical', 120),
            ]
            
            # Also check for common threshold increments (10, 20, 30, etc.)
            # This covers the requirement "when people count crosses each defined threshold"
            all_thresholds = set(threshold_values)
            # Add increments of 10 up to critical threshold
            max_threshold = max(threshold_values) if threshold_values else 120
            for i in range(10, max_threshold + 1, 10):
                all_thresholds.add(i)
            
            # Check if crossing any threshold upward
            for threshold in sorted(all_thresholds):
                if self.previous_count < threshold <= current_count:
                    # Only trigger if we haven't already crossed this threshold in this session
                    # or if we went below and crossed again
                    if threshold not in self.previous_threshold_crossed:
                        self.previous_threshold_crossed.add(threshold)
                        self.previous_count = current_count
                        return True, f"threshold_{threshold}"
            
            # Check if crossing any threshold downward (for resetting state)
            for threshold in sorted(all_thresholds):
                if self.previous_count >= threshold > current_count:
                    if threshold in self.previous_threshold_crossed:
                        self.previous_threshold_crossed.remove(threshold)
            
            self.previous_count = current_count
            return False, ""
    
    def start_recording(self, trigger_reason: str) -> bool:
        """
        Start recording a video clip
        Includes 3 seconds before trigger + 7 seconds after
        """
        with self.lock:
            if self.is_recording:
                return False  # Already recording
            
            # Check storage space
            if not self._check_storage_space():
                print(f"[WARN] Storage limit reached for zone {self.zone_id}")
                return False
            
            # Create video filename with timestamp
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            video_filename = f"recording_{timestamp}_{trigger_reason}.mp4"
            video_path = self.storage_path / video_filename
            
            # Get frame dimensions from buffer
            if not self.frame_buffer:
                print(f"[ERROR] No frames in buffer to start recording")
                return False
            
            first_frame, _ = self.frame_buffer[0]
            height, width = first_frame.shape[:2]
            
            # Use temporary file first, then convert to browser-compatible format
            temp_video_path = video_path.with_suffix('.tmp.mp4')
            fps = 30.0
            
            # Try to use ffmpeg for better browser compatibility
            use_ffmpeg = shutil.which('ffmpeg') is not None
            
            if use_ffmpeg:
                # Use ffmpeg for better H.264 encoding
                print(f"[RECORD] Using ffmpeg for video encoding (best browser compatibility)")
                # We'll write frames to a pipe or use OpenCV then convert
                # For now, use OpenCV with best available codec, then convert
                fourcc = cv2.VideoWriter_fourcc(*'mp4v')  # Temporary format
                video_writer = cv2.VideoWriter(
                    str(temp_video_path),
                    fourcc,
                    fps,
                    (width, height)
                )
                if not video_writer.isOpened():
                    print(f"[WARN] OpenCV writer failed, trying alternative codecs")
                    fourcc_options = [
                        cv2.VideoWriter_fourcc(*'XVID'),
                        cv2.VideoWriter_fourcc(*'MJPG'),
                    ]
                    for codec in fourcc_options:
                        video_writer = cv2.VideoWriter(
                            str(temp_video_path),
                            codec,
                            fps,
                            (width, height)
                        )
                        if video_writer.isOpened():
                            fourcc = codec
                            break
            else:
                # Fallback to OpenCV with browser-compatible codecs
                print(f"[RECORD] Using OpenCV VideoWriter (ffmpeg not available)")
                print(f"[WARN] For best browser compatibility, please install FFmpeg")
                print(f"[INFO] See INSTALL_FFMPEG_WINDOWS.md for installation instructions")
                
                # Try codecs that might work on Windows
                # Note: On Windows, OpenCV may not support H.264 directly
                # We'll try different codecs and hope one works
                fourcc_options = [
                    ('avc1', 'H.264 avc1'),
                    ('H264', 'H.264 H264'),
                    ('XVID', 'Xvid'),
                    ('MJPG', 'Motion JPEG'),
                    ('mp4v', 'MPEG-4'),
                ]
                
                fourcc = None
                video_writer = None
                codec_name = None
                
                # Try each codec until one works
                for codec_val, codec_desc in fourcc_options:
                    try:
                        test_writer = cv2.VideoWriter(
                            str(temp_video_path),
                            cv2.VideoWriter_fourcc(*codec_val),
                            fps,
                            (width, height)
                        )
                        if test_writer.isOpened():
                            fourcc = cv2.VideoWriter_fourcc(*codec_val)
                            video_writer = test_writer
                            codec_name = codec_desc
                            break
                        else:
                            test_writer.release()
                    except Exception as e:
                        print(f"[WARN] Codec {codec_val} failed: {e}")
                        continue
                
                if video_writer is None:
                    print(f"[ERROR] Failed to create video writer with any codec")
                    print(f"[ERROR] Please install FFmpeg for reliable video recording")
                    return False
                
                print(f"[RECORD] Using codec: {codec_name} (may not be browser-compatible)")
            
            print(f"[RECORD] Using codec: {fourcc} for temporary video")
            
            # Store paths for later conversion
            self._temp_video_path = temp_video_path
            self._final_video_path = video_path
            
            # Write buffered frames (3 seconds = 90 frames)
            for buffered_frame, _ in self.frame_buffer:
                video_writer.write(buffered_frame)
            
            # Start recording new frames
            self.current_video_writer = video_writer
            self.is_recording = True
            self.recorded_frames_count = len(self.frame_buffer)
            # Use UTC timestamp to ensure consistency across timezones
            self.recording_start_time = datetime.utcnow().timestamp()
            print(f"[RECORD] Started recording: {video_filename}")
            
            # Add to metadata
            # Convert to milliseconds (Unix timestamp in milliseconds)
            timestamp_ms = int(self.recording_start_time * 1000)
            video_info = {
                "filename": video_filename,
                "path": str(video_path),
                "timestamp": timestamp_ms,
                "trigger_reason": trigger_reason,
                "zone_id": self.zone_id,
                "duration_seconds": 10,  # 3 seconds pre + 7 seconds post
            }
            self.metadata["videos"].append(video_info)
            self._save_metadata()
            
            print(f"[RECORD] Started recording: {video_filename} (trigger: {trigger_reason})")
            return True
    
    def _stop_recording(self):
        """Stop the current recording and convert to browser-compatible format"""
        if self.current_video_writer is not None:
            self.current_video_writer.release()
            self.current_video_writer = None
        
        # Convert temporary video to browser-compatible format
        temp_path = getattr(self, '_temp_video_path', None)
        final_path = getattr(self, '_final_video_path', None)
        
        if temp_path and final_path:
            temp_file = Path(temp_path) if not isinstance(temp_path, Path) else temp_path
            final_file = Path(final_path) if not isinstance(final_path, Path) else final_path
            
            if temp_file.exists():
                try:
                    # Try to convert using ffmpeg if available
                    if shutil.which('ffmpeg'):
                        print(f"[RECORD] Converting video to H.264 format using ffmpeg...")
                        cmd = [
                            'ffmpeg', '-y', '-i', str(temp_file),
                            '-c:v', 'libx264',  # H.264 codec
                            '-preset', 'fast',  # Fast encoding
                            '-crf', '23',  # Good quality
                            '-c:a', 'aac',  # AAC audio
                            '-movflags', '+faststart',  # Web optimization
                            str(final_file)
                        ]
                        result = subprocess.run(
                            cmd,
                            capture_output=True,
                            text=True,
                            timeout=30
                        )
                        if result.returncode == 0:
                            print(f"[RECORD] ✅ Video converted successfully to H.264")
                            temp_file.unlink()  # Delete temporary file
                        else:
                            print(f"[WARN] FFmpeg conversion failed: {result.stderr}")
                            print(f"[INFO] Using original video format (may not be browser-compatible)")
                            # Fallback: rename temp file
                            temp_file.rename(final_file)
                    else:
                        # No ffmpeg, just rename temp file
                        print(f"[WARN] FFmpeg not available - video may not be browser-compatible")
                        print(f"[INFO] Install ffmpeg for best browser compatibility")
                        temp_file.rename(final_file)
                except Exception as e:
                    print(f"[ERROR] Error converting video: {e}")
                    import traceback
                    traceback.print_exc()
                    # Fallback: rename temp file
                    try:
                        if temp_file.exists():
                            temp_file.rename(final_file)
                    except Exception as e2:
                        print(f"[ERROR] Failed to rename temp file: {e2}")
        
        self.is_recording = False
        self.recorded_frames_count = 0
        self.recording_start_time = None
        if hasattr(self, '_temp_video_path'):
            delattr(self, '_temp_video_path')
        if hasattr(self, '_final_video_path'):
            delattr(self, '_final_video_path')
        print(f"[RECORD] Stopped recording for zone {self.zone_id}")
    
    def _check_storage_space(self) -> bool:
        """Check if there's enough storage space"""
        total_size = self._get_total_storage_size()
        return total_size < self.MAX_STORAGE_BYTES
    
    def _get_total_storage_size(self) -> int:
        """Calculate total size of all recordings for this zone"""
        total = 0
        try:
            for file_path in self.storage_path.glob("*.mp4"):
                if file_path.is_file():
                    total += file_path.stat().st_size
        except Exception as e:
            print(f"[ERROR] Failed to calculate storage size: {e}")
        return total
    
    def get_storage_info(self) -> dict:
        """Get storage information for this zone"""
        total_size = self._get_total_storage_size()
        return {
            "zone_id": self.zone_id,
            "total_size_bytes": total_size,
            "total_size_gb": total_size / (1024 ** 3),
            "max_size_bytes": self.MAX_STORAGE_BYTES,
            "max_size_gb": self.MAX_STORAGE_BYTES / (1024 ** 3),
            "usage_percent": (total_size / self.MAX_STORAGE_BYTES) * 100,
            "is_full": total_size >= self.MAX_STORAGE_BYTES,
            "video_count": len(self.metadata.get("videos", [])),
        }
    
    def get_video_list(self) -> list:
        """Get list of all recorded videos with metadata"""
        return self.metadata.get("videos", [])
    
    def delete_video(self, video_filename: str) -> bool:
        """Delete a video file and update metadata"""
        video_path = self.storage_path / video_filename
        if video_path.exists():
            try:
                video_path.unlink()
                # Remove from metadata
                self.metadata["videos"] = [
                    v for v in self.metadata["videos"]
                    if v.get("filename") != video_filename
                ]
                self._save_metadata()
                print(f"[DELETE] Deleted video: {video_filename}")
                return True
            except Exception as e:
                print(f"[ERROR] Failed to delete video {video_filename}: {e}")
                return False
        return False
    
    def cleanup_old_videos(self):
        """Delete oldest videos if storage is full"""
        if not self._check_storage_space():
            # Sort videos by timestamp (oldest first)
            videos = sorted(
                self.metadata.get("videos", []),
                key=lambda x: x.get("timestamp", 0)
            )
            
            # Delete oldest videos until under limit
            for video in videos:
                if self._check_storage_space():
                    break
                self.delete_video(video.get("filename", ""))
    
    def cleanup(self):
        """Cleanup resources"""
        with self.lock:
            self._stop_recording()
            self.frame_buffer.clear()

