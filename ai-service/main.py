"""
CrowdSense AI Service - People Detection Backend
Detects people from camera streams and provides data via API
Flutter app handles Firebase storage for analytics

All-in-one service: Includes AI detection, video streaming, and external camera server
"""

import asyncio
import os
import time
import argparse
import socket
from datetime import datetime
from typing import Dict, List, Optional, Tuple
from threading import Thread
from http.server import HTTPServer, BaseHTTPRequestHandler
# Firebase removed - Flutter app handles Firebase storage
# import firebase_admin
# from firebase_admin import credentials, db
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
import cv2
import numpy as np
from people_detector import PeopleDetector
from people_detector_simple import SimplePeopleDetector
from video_recorder import VideoRecorder

app = FastAPI(title="CrowdSense AI Service")

# Add CORS middleware for Flutter Web
# IMPORTANT: Must be added BEFORE other routes
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Allow all origins for development
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS", "HEAD"],
    allow_headers=["*"],
    expose_headers=["*"],
    max_age=3600,
)

# Firebase removed - Flutter app handles all Firebase operations
# Python service only provides detection data via API

# Global detector instance - Use YOLOv8 for better accuracy
detector: Optional[PeopleDetector] = None

# Active zone monitoring tasks
monitoring_tasks: Dict[str, asyncio.Task] = {}

# Store video capture objects and frames for streaming
zone_captures: Dict[str, cv2.VideoCapture] = {}
zone_frames: Dict[str, bytes] = {}
zone_frame_locks: Dict[str, asyncio.Lock] = {}

# Shared frame buffer for zones using the same camera
# Key: camera identifier (camera_index or camera_url), Value: (frame, timestamp, lock)
shared_frames: Dict[str, Tuple[Optional[np.ndarray], float, asyncio.Lock]] = {}
shared_frame_locks: Dict[str, asyncio.Lock] = {}

# Store current people counts for each zone (for API access without Firebase)
zone_people_counts: Dict[str, int] = {}
zone_last_updated: Dict[str, int] = {}

# Store video recorders for each zone
zone_video_recorders: Dict[str, VideoRecorder] = {}

# External camera server (for streaming local camera to other computers)
_external_camera_server: Optional[HTTPServer] = None
_external_camera: Optional[cv2.VideoCapture] = None


# HTTP Stream Handler removed - using OpenCV VideoCapture directly (like old version)
# OpenCV can handle HTTP MJPEG streams, though with some limitations

class ZoneConfig(BaseModel):
    zone_id: str
    name: str
    camera_url: str  # RTSP or HTTP stream URL
    rtsp_url: Optional[str] = None
    thresholds: Dict[str, int]
    average_service_speed: float = 2.0  # minutes per person
    enabled: bool = True


class DetectionResult(BaseModel):
    zone_id: str
    count: int
    timestamp: int
    confidence: float


def get_level(count: int, thresholds: Dict[str, int]) -> str:
    """Determine congestion level based on count and thresholds"""
    if count <= thresholds.get('low', 20):
        return 'low'
    elif count <= thresholds.get('medium', 50):
        return 'medium'
    elif count <= thresholds.get('high', 80):
        return 'high'
    else:
        return 'critical'


def calculate_waiting_time(count: int, service_speed: float) -> float:
    """Calculate estimated waiting time in minutes
    service_speed is in minutes/person (not people/min)
    waiting_time = count * service_speed (e.g., 10 people * 2 min/person = 20 minutes)
    """
    return max(0, count * service_speed) if service_speed > 0 else 0


async def monitor_zone(config: ZoneConfig):
    """
    Continuously monitor a zone and detect people
    Detection results are available via API endpoint /zones/{zone_id}/count
    Flutter app handles Firebase storage for analytics
    """
    # Yield control immediately to avoid blocking the caller
    await asyncio.sleep(0)
    
    global detector, _external_camera, _external_camera_server
    
    # Wait for detector to be initialized (with timeout)
    max_wait = 30  # Maximum 30 seconds
    wait_count = 0
    while not detector and wait_count < max_wait:
        await asyncio.sleep(0.5)
        wait_count += 0.5
        if wait_count % 5 == 0:
            print(f"⏳ Waiting for detector initialization... ({wait_count:.0f}s)")
    
    if not detector:
        print("[WARN] Detector not initialized after waiting, initializing YOLOv8...")
        try:
            detector = PeopleDetector()  # Use YOLOv8 for better accuracy
            print("[OK] YOLOv8 detector initialized successfully")
        except Exception as e:
            print(f"[ERROR] YOLOv8 initialization failed: {e}")
            print("[WARN] Falling back to SimplePeopleDetector...")
            try:
                detector = SimplePeopleDetector()
                print("[OK] SimplePeopleDetector initialized as fallback")
            except Exception as e2:
                print(f"[ERROR] SimplePeopleDetector also failed: {e2}")
                detector = None
    
    print(f"Starting monitoring for zone: {config.name} ({config.zone_id})")
    
    # Handle camera URL - convert "0" string to integer for direct camera access
    camera_url = config.camera_url or config.rtsp_url
    print(f"Attempting to open camera: {camera_url}")
    
    cap = None
    is_shared_camera = False
    camera_id = None
    try:
        # Try to convert to integer if it's a numeric string (for direct camera)
        camera_index = int(camera_url)
        print(f"Opening camera with index: {camera_index}")
        
        # Create camera identifier for this direct camera
        camera_id = f"direct_camera_{camera_index}"
        
        # Check if external_camera_server is using this camera
        if _external_camera is not None and _external_camera.isOpened():
            # External camera server is active - check if it's using the same camera index
            # We'll assume it's using camera 0 by default (can be configured)
            # If user wants to use direct camera 0, we should share with external_camera
            if camera_index == 0:  # Default camera index
                print(f"[INFO] External camera server detected. Sharing camera {camera_index} with external camera server.")
                cap = _external_camera
                is_shared_camera = True
                camera_id = "external_camera_shared"
                # Initialize shared frame buffer if not exists
                if camera_id not in shared_frame_locks:
                    shared_frame_locks[camera_id] = asyncio.Lock()
                    shared_frames[camera_id] = (None, 0.0, asyncio.Lock())
            else:
                print(f"[WARN] External camera server is active, but using different camera index.")
                print(f"[WARN] Attempting to open camera {camera_index} directly...")
                cap = cv2.VideoCapture(camera_index)
        else:
            # Check if another zone is already using this camera (direct camera)
            existing_cap = None
            for zone_id, existing_cap_obj in zone_captures.items():
                if zone_id != config.zone_id:
                    # Check if this is a direct camera capture (not HTTP stream, not external_camera)
                    if isinstance(existing_cap_obj, cv2.VideoCapture) and existing_cap_obj is not _external_camera:
                        # Check if it's likely the same camera index by checking if it's opened
                        # We'll assume if it's a direct camera VideoCapture, it might be the same
                        # In practice, we can't easily check the camera index, so we'll be conservative
                        # Only share if we're sure it's safe (e.g., both are camera 0)
                        if camera_index == 0:  # Only share camera 0 for safety
                            existing_cap = existing_cap_obj
                            print(f"[INFO] Found existing direct camera capture for camera {camera_index}, will attempt to share")
                            break
            
            if existing_cap is not None and existing_cap.isOpened():
                # Another zone is already using a direct camera - share the VideoCapture object
                print(f"[INFO] Sharing VideoCapture object for camera {camera_index} with another zone")
                cap = existing_cap
                is_shared_camera = True
                # Initialize shared frame buffer if not exists
                if camera_id not in shared_frame_locks:
                    shared_frame_locks[camera_id] = asyncio.Lock()
                    shared_frames[camera_id] = (None, 0.0, asyncio.Lock())
            else:
                # No existing capture, open new one
                cap = cv2.VideoCapture(camera_index)
        
        # Set camera properties only if not shared (shared camera already has properties set)
        if not is_shared_camera:
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)  # Normal resolution
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)  # Normal resolution
            cap.set(cv2.CAP_PROP_FPS, 30)  # 30 FPS
            
            # Verify settings were applied
            actual_width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
            actual_height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
            actual_fps = cap.get(cv2.CAP_PROP_FPS)
            print(f"Camera settings: Requested 640x480@30fps, Got {actual_width}x{actual_height}@{actual_fps}fps")
            
            # Try to open camera with retries
            if not cap.isOpened():
                print(f"First attempt failed, retrying camera {camera_index}...")
                cap.release()
                await asyncio.sleep(0.5)
                cap = cv2.VideoCapture(camera_index)
        else:
            print(f"[INFO] Using shared camera, skipping property setup")
            
    except (ValueError, TypeError) as e:
        # Use as string URL for RTSP/HTTP streams
        print(f"Using camera as URL string: {camera_url}")
        
        # Check if this is an external camera server URL
        is_external_camera_url = False
        if camera_url.startswith('http://') or camera_url.startswith('https://'):
            try:
                from urllib.parse import urlparse
                parsed = urlparse(camera_url)
                # Check if it's localhost or local IP
                is_localhost = parsed.hostname in ['localhost', '127.0.0.1', '0.0.0.0'] or \
                               parsed.hostname is None or \
                               parsed.hostname.startswith('192.168.') or \
                               parsed.hostname.startswith('10.') or \
                               parsed.hostname.startswith('172.')
                # Check if path is /video (external camera server endpoint)
                is_video_path = parsed.path == '/video' or parsed.path.endswith('/video')
                # Check if port is 8080 (default) or matches external camera server port
                is_port_8080 = parsed.port == 8080 or (parsed.port is None and ':8080' in camera_url)
                
                if is_localhost and is_video_path and is_port_8080:
                    is_external_camera_url = True
                    print(f"[INFO] Detected external camera server URL: {camera_url}")
            except Exception as parse_error:
                print(f"[WARN] Could not parse URL: {parse_error}")
        
        # If it's external camera server URL, use shared camera
        if is_external_camera_url:
            # Check if external camera server is already running and working
            # Need to verify both server and camera are actually functional
            external_camera_available = False
            if _external_camera_server is not None and _external_camera is not None:
                # Verify camera is actually opened and can read frames
                if _external_camera.isOpened():
                    # Try to read a test frame to verify it's working
                    test_ret, test_frame = _external_camera.read()
                    if test_ret and test_frame is not None:
                        external_camera_available = True
                        print(f"[INFO] ✅ External camera server is already running and working, reusing it")
                    else:
                        print(f"[INFO] ⚠️ External camera server exists but cannot read frames, will restart")
                        # Clean up broken external camera server
                        try:
                            if _external_camera:
                                _external_camera.release()
                            _external_camera = None
                            _external_camera_server = None
                        except Exception as e:
                            print(f"[WARN] Error cleaning up broken external camera: {e}")
                else:
                    print(f"[INFO] ⚠️ External camera server exists but camera is not opened, will restart")
                    # Clean up broken external camera server
                    _external_camera = None
                    _external_camera_server = None
            
            if external_camera_available:
                cap = _external_camera
                is_shared_camera = True
                camera_id = "external_camera_shared"
                # Initialize shared frame buffer if not exists
                if camera_id not in shared_frame_locks:
                    shared_frame_locks[camera_id] = asyncio.Lock()
                    shared_frames[camera_id] = (None, 0.0, asyncio.Lock())
            else:
                # Try to find an available camera index
                print(f"[INFO] External camera server not running, starting it...")
                camera_index = 0
                camera_found = False
                
                # Try camera indices 0-3 to find an available camera
                for idx in range(4):
                    print(f"[INFO] Trying to open camera index {idx}...")
                    test_cap = cv2.VideoCapture(idx)
                    if test_cap.isOpened():
                        # Test reading a frame
                        ret, frame = test_cap.read()
                        if ret and frame is not None:
                            print(f"[INFO] ✅ Camera index {idx} is available and working")
                            test_cap.release()
                            camera_index = idx
                            camera_found = True
                            break
                        else:
                            test_cap.release()
                    else:
                        test_cap.release()
                
                if not camera_found:
                    print(f"[ERROR] ❌ No available camera found (tried indices 0-3)")
                    print(f"[ERROR] Please check:")
                    print(f"[ERROR]   1. Camera is connected")
                    print(f"[ERROR]   2. Camera is not being used by another application")
                    print(f"[ERROR]   3. Camera permissions are granted")
                    cap = None
                else:
                    # Start external camera server with the found camera index
                    print(f"[INFO] Starting external camera server with camera index {camera_index}...")
                    
                    # Wait a bit before starting to ensure previous camera resources are fully released
                    # This is important after deactivate/activate cycle
                    await asyncio.sleep(1.0)
                    print(f"[INFO] Waiting period completed, starting external camera server...")
                    
                    thread = start_external_camera_server(8080, camera_index)
                    # Wait for server to start and camera to open (with retries)
                    max_wait = 15  # Maximum 15 seconds (increased for resource release)
                    wait_count = 0
                    while wait_count < max_wait:
                        await asyncio.sleep(0.5)
                        wait_count += 0.5
                        if _external_camera is not None and _external_camera.isOpened():
                            # Test reading a frame to verify it's actually working
                            test_ret, test_frame = _external_camera.read()
                            if test_ret and test_frame is not None:
                                print(f"[INFO] ✅ External camera server started successfully after {wait_count:.1f}s")
                                break
                            else:
                                # Camera opened but can't read frames yet, keep waiting
                                if wait_count % 2 == 0:
                                    print(f"[INFO] Camera opened but cannot read frames yet, waiting... ({wait_count:.0f}s)")
                        if wait_count % 2 == 0:
                            print(f"[INFO] Waiting for external camera server to start... ({wait_count:.0f}s)")
                    
                    # Check again if external camera is available
                    if _external_camera is not None and _external_camera.isOpened():
                        # Final verification - test reading a frame
                        test_ret, test_frame = _external_camera.read()
                        if test_ret and test_frame is not None:
                            print(f"[INFO] ✅ External camera server is running and camera is opened")
                            print(f"[INFO] Using shared VideoCapture from external camera server")
                            print(f"[INFO] ✅ External camera frame read test successful: {test_frame.shape}")
                            
                            cap = _external_camera
                            is_shared_camera = True
                            camera_id = "external_camera_shared"
                            # Initialize shared frame buffer if not exists
                            if camera_id not in shared_frame_locks:
                                shared_frame_locks[camera_id] = asyncio.Lock()
                                shared_frames[camera_id] = (None, 0.0, asyncio.Lock())
                        else:
                            print(f"[WARN] ⚠️ External camera opened but failed to read test frame")
                            print(f"[WARN] This might be temporary - will continue trying")
                            # Still use it, but log the warning
                            cap = _external_camera
                            is_shared_camera = True
                            camera_id = "external_camera_shared"
                            if camera_id not in shared_frame_locks:
                                shared_frame_locks[camera_id] = asyncio.Lock()
                                shared_frames[camera_id] = (None, 0.0, asyncio.Lock())
                    else:
                        print(f"[ERROR] ❌ Failed to start external camera server or camera not available")
                        print(f"[ERROR] Debug info:")
                        print(f"[ERROR]   _external_camera_server is None: {_external_camera_server is None}")
                        print(f"[ERROR]   _external_camera is None: {_external_camera is None}")
                        if _external_camera is not None:
                            print(f"[ERROR]   _external_camera.isOpened(): {_external_camera.isOpened()}")
                        print(f"[ERROR] Possible reasons:")
                        print(f"[ERROR]   1. Camera resource not fully released from previous session")
                        print(f"[ERROR]   2. Camera is being used by another application")
                        print(f"[ERROR]   3. Camera permissions not granted")
                        print(f"[ERROR] Zone {config.zone_id} will use placeholder frame")
                        cap = None
        else:
            # For other HTTP/RTSP URLs, use OpenCV directly
            print(f"[INFO] Opening HTTP/RTSP stream: {camera_url}")
            cap = cv2.VideoCapture(camera_url)
            # Set buffer size to reduce latency
            cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
            
            # Wait a bit for connection to establish (especially for HTTP streams)
            await asyncio.sleep(0.5)
            
            # Try to read a test frame to verify connection
            if cap.isOpened():
                print(f"[INFO] Stream opened, testing frame read...")
                test_ret, test_frame = cap.read()
                if test_ret and test_frame is not None:
                    print(f"✅ HTTP/RTSP stream connection verified: {test_frame.shape}")
                else:
                    print(f"⚠️ Warning: HTTP/RTSP stream opened but failed to read test frame")
                    print(f"   This might be normal for some streams - will continue trying")
            else:
                print(f"❌ Failed to open HTTP/RTSP stream: {camera_url}")
    except Exception as e:
        print(f"Error creating VideoCapture: {e}")
        cap = None
    
    if cap is None or not cap.isOpened():
        error_msg = f"❌ ERROR: Could not open camera stream for {config.zone_id}"
        print(error_msg)
        print(f"Camera URL/index: {camera_url}")
        print("Please check:")
        print("  1. Camera is connected and not used by another application")
        print("  2. Camera permissions are granted")
        print("  3. Camera index is correct (try 0, 1, 2, etc.)")
        
        # Still create frame lock and placeholder frame to allow stream endpoint to work
        zone_frame_locks[config.zone_id] = asyncio.Lock()
        # Create a placeholder black frame with error message
        black_frame = np.zeros((480, 640, 3), dtype=np.uint8)
        cv2.putText(black_frame, "Camera Not Available", (50, 220), 
                   cv2.FONT_HERSHEY_SIMPLEX, 1, (255, 255, 255), 2)
        cv2.putText(black_frame, f"Camera: {camera_url}", (50, 260), 
                   cv2.FONT_HERSHEY_SIMPLEX, 0.7, (200, 200, 200), 2)
        _, buffer = cv2.imencode('.jpg', black_frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
        zone_frames[config.zone_id] = buffer.tobytes()
        
        # Keep the task running so stream endpoint works, but don't try to read frames
        print(f"⚠️ Zone {config.zone_id} monitoring task will continue with placeholder frame")
        # Wait indefinitely to keep task alive
        try:
            while config.zone_id in monitoring_tasks:
                await asyncio.sleep(5)
                # Update placeholder frame timestamp
                _, buffer = cv2.imencode('.jpg', black_frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
                zone_frames[config.zone_id] = buffer.tobytes()
        except asyncio.CancelledError:
            pass
        return
    
    print(f"✅ Camera opened successfully for zone: {config.zone_id}")
    print(f"   Resolution: {int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))}x{int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))}")
    print(f"   FPS: {cap.get(cv2.CAP_PROP_FPS)}")
    
    # Store capture object and create lock for frame access
    zone_captures[config.zone_id] = cap
    zone_frame_locks[config.zone_id] = asyncio.Lock()
    
    # Initialize video recorder for this zone
    video_recorder = VideoRecorder(config.zone_id)
    zone_video_recorders[config.zone_id] = video_recorder
    
    # Test reading a frame immediately to verify it works
    # Use lock if shared camera
    print(f"🔍 Testing frame read for {config.zone_id}...")
    if is_shared_camera and camera_id in shared_frame_locks:
        lock = shared_frame_locks[camera_id]
        async with lock:
            test_ret, test_frame = cap.read()
    else:
        test_ret, test_frame = cap.read()
    
    if test_ret and test_frame is not None:
        frame_mean = test_frame.mean()
        print(f"✅ Test frame read successfully: {test_frame.shape}, brightness={frame_mean:.2f}")
        if frame_mean < 5:
            print(f"⚠️ WARNING: Frame appears to be black (mean={frame_mean:.2f})")
            print(f"   This might indicate:")
            print(f"   - Camera lens cover is on")
            print(f"   - Camera is in a dark environment")
            print(f"   - Camera hardware issue")
        # Store initial frame
        _, buffer = cv2.imencode('.jpg', test_frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
        if buffer is not None:
            zone_frames[config.zone_id] = buffer.tobytes()
            print(f"✅ Initial frame stored for streaming")
        # Update shared frame if using shared camera
        if is_shared_camera and camera_id in shared_frame_locks:
            shared_frames[camera_id] = (test_frame.copy(), time.time(), shared_frame_locks[camera_id])
    else:
        print(f"⚠️ Warning: Test frame read failed, but continuing...")
    
    print(f"✅ Camera opened successfully for zone: {config.zone_id}")
    if not is_shared_camera:
        print(f"   Resolution: {int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))}x{int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))}")
        print(f"   FPS: {cap.get(cv2.CAP_PROP_FPS)}")
    else:
        print(f"   Using shared camera (camera_id: {camera_id})")
    
    try:
        # Keep monitoring even if config.enabled changes (only stop when task is cancelled)
        while True:
            # Check if task was cancelled
            if config.zone_id not in monitoring_tasks:
                print(f"Monitoring task cancelled for {config.zone_id}")
                break
                
            # Read frame synchronously (OpenCV operations are fast enough)
            # If using shared camera (external_camera), use lock to prevent concurrent reads
            if is_shared_camera and camera_id in shared_frame_locks:
                # Use shared frame lock to prevent concurrent reads from same camera
                lock = shared_frame_locks[camera_id]
                async with lock:
                    ret, frame = cap.read()
                    # Update shared frame buffer for other zones using same camera
                    if ret and frame is not None:
                        shared_frames[camera_id] = (frame.copy(), time.time(), lock)
            else:
                # Normal read for non-shared cameras
                ret, frame = cap.read()
            
            # Resize frame for detection if too large (but keep reasonable size for Haar Cascade)
            if frame is not None:
                h, w = frame.shape[:2]
                # Resize only if significantly larger than 320x240
                if w > 640 or h > 480:
                    # Scale down but keep aspect ratio, target max 640x480
                    scale = min(640/w, 480/h)
                    new_w, new_h = int(w * scale), int(h * scale)
                    frame = cv2.resize(frame, (new_w, new_h))
                    print(f"[RESIZE] Resized frame from {w}x{h} to {new_w}x{new_h}")
            
            if not ret:
                print(f"⚠️ Failed to read frame from {config.zone_id}, retrying...")
                # Check if camera is still opened
                if not cap.isOpened():
                    print(f"❌ Camera closed unexpectedly for {config.zone_id}, attempting to reopen...")
                    try:
                        camera_url = config.camera_url or config.rtsp_url
                        if cap is not None:
                            cap.release()
                        await asyncio.sleep(0.5)
                        
                        # Use the same logic as initial camera opening
                        try:
                            # Try to convert to integer if it's a numeric string (for direct camera)
                            camera_index = int(camera_url)
                            print(f"Reopening camera with index: {camera_index}")
                            cap = cv2.VideoCapture(camera_index)
                            cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
                            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
                            cap.set(cv2.CAP_PROP_FPS, 30)
                        except (ValueError, TypeError):
                            # Use as string URL for RTSP/HTTP streams
                            print(f"Reopening camera as URL string: {camera_url}")
                            cap = cv2.VideoCapture(camera_url)
                            cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
                            await asyncio.sleep(0.5)  # Wait for connection
                        
                        if cap is not None and cap.isOpened():
                            zone_captures[config.zone_id] = cap
                            print(f"✅ Camera reopened successfully for {config.zone_id}")
                        else:
                            print(f"❌ Failed to reopen camera for {config.zone_id}")
                    except Exception as e:
                        print(f"❌ Error reopening camera: {e}")
                # Keep trying to read frames
                await asyncio.sleep(0.2)  # Slightly longer sleep to reduce CPU usage
                continue
            
            # Add frame to video recorder buffer (always at 30 FPS)
            if config.zone_id in zone_video_recorders:
                try:
                    timestamp = time.time()
                    zone_video_recorders[config.zone_id].add_frame(frame, timestamp)
                except Exception as e:
                    print(f"[ERROR] Error adding frame to video recorder: {e}")
            
            # Store frame for video streaming (encode as JPEG every 3 frames for better performance)
            if not hasattr(monitor_zone, '_encode_counter'):
                monitor_zone._encode_counter = {}
            if config.zone_id not in monitor_zone._encode_counter:
                monitor_zone._encode_counter[config.zone_id] = 0
            
            monitor_zone._encode_counter[config.zone_id] += 1
            if monitor_zone._encode_counter[config.zone_id] % 2 == 0:  # Encode every 2nd frame (~15 FPS for stream, camera runs at 30 FPS)
                try:
                    async with zone_frame_locks[config.zone_id]:
                        # Resize frame for streaming to reduce bandwidth
                        h, w = frame.shape[:2]
                        if w > 640 or h > 480:
                            small_frame = cv2.resize(frame, (640, 480))
                        else:
                            small_frame = frame
                        _, buffer = cv2.imencode('.jpg', small_frame, [cv2.IMWRITE_JPEG_QUALITY, 75])  # Good quality
                        if buffer is not None and len(buffer) > 0:
                            zone_frames[config.zone_id] = buffer.tobytes()
                except Exception as e:
                    print(f"[ERROR] Error storing frame for {config.zone_id}: {e}")
            
            # Detect people every 5 seconds (optimized for performance)
            # Use frame counter instead of time-based to avoid missing detections
            if not hasattr(monitor_zone, '_detection_counter'):
                monitor_zone._detection_counter = {}
            if config.zone_id not in monitor_zone._detection_counter:
                monitor_zone._detection_counter[config.zone_id] = 0
            
            monitor_zone._detection_counter[config.zone_id] += 1
            detection_interval = 30  # Detect every 30 frames (~1 second at 30 FPS)
            
            if monitor_zone._detection_counter[config.zone_id] % detection_interval == 0:
                # Perform detection
                if detector:
                    try:
                        # Use appropriate threshold based on detector type
                        if isinstance(detector, PeopleDetector):
                            # YOLOv8 - use lower threshold for better detection
                            count, confidence = detector.detect(frame, confidence_threshold=0.25)
                            detector_type = "YOLOv8"
                        else:
                            # SimplePeopleDetector (Haar Cascade/MediaPipe)
                            count, confidence = detector.detect(frame, confidence_threshold=0.2)
                            detector_type = "Simple"
                        
                        print(f"[DETECT] [{config.zone_id}] Detection: {count} people (confidence: {confidence:.2f}, detector: {detector_type})")
                    except Exception as e:
                        print(f"[ERROR] Detection error: {e}")
                        count, confidence = 0, 0.0
                else:
                    # Initialize detector if not ready
                    try:
                        detector = PeopleDetector()  # Try YOLOv8 first
                        count, confidence = detector.detect(frame, confidence_threshold=0.25)
                        print(f"[OK] YOLOv8 detector initialized, detected {count} people")
                    except Exception as e:
                        print(f"[WARN] YOLOv8 failed, trying SimplePeopleDetector: {e}")
                        try:
                            detector = SimplePeopleDetector()
                            count, confidence = detector.detect(frame, confidence_threshold=0.2)
                            print(f"[OK] SimplePeopleDetector initialized, detected {count} people")
                        except Exception as e2:
                            print(f"[ERROR] All detectors failed: {e2}")
                            count, confidence = 0, 0.0
                
                # Store detection results locally (available via API)
                timestamp = int(time.time() * 1000)
                previous_count = zone_people_counts.get(config.zone_id, 0)
                zone_people_counts[config.zone_id] = count
                zone_last_updated[config.zone_id] = timestamp
                
                # Check for recording triggers
                if config.zone_id in zone_video_recorders:
                    try:
                        should_record, trigger_reason = zone_video_recorders[config.zone_id].check_triggers(
                            count, config.thresholds
                        )
                        if should_record:
                            # Pass current frame to start recording immediately (no pre-buffer)
                            success = zone_video_recorders[config.zone_id].start_recording(trigger_reason, current_frame=frame)
                            if not success:
                                print(f"[WARN] Failed to start recording for zone {config.zone_id} (storage full?)")
                    except Exception as e:
                        print(f"[ERROR] Error checking recording triggers: {e}")
                
                print(f"[UPDATE] Zone {config.zone_id}: count={count} (available via API)")
            else:
                # Use last known count (don't update Firebase every frame)
                count = monitor_zone._detection_counter.get(f'{config.zone_id}_last_count', 0)
                confidence = 0.0
            
            # Store last count for next iteration
            monitor_zone._detection_counter[f'{config.zone_id}_last_count'] = count
            
            # Alert and analytics are handled by Flutter app
            # Python service only provides detection data via API
            
            # Sleep for next frame
            await asyncio.sleep(0.033)  # ~30 FPS
    
    except asyncio.CancelledError:
        print(f"Monitoring cancelled for zone: {config.name}")
    except Exception as e:
        print(f"Error monitoring zone {config.zone_id}: {e}")
    finally:
        # Only release if cap exists and was opened
        # But don't release if it's shared with external_camera_server
        if 'cap' in locals() and cap is not None:
            # Check if this is the shared external camera
            is_shared_camera = (cap is _external_camera and _external_camera is not None)
            
            if not is_shared_camera:
                try:
                    cap.release()
                    print(f"Camera released for zone: {config.zone_id}")
                except Exception as e:
                    print(f"Error releasing camera: {e}")
            else:
                print(f"Camera for zone {config.zone_id} is shared with external camera server, not releasing")
        
        # Cleanup zone resources
        if config.zone_id in zone_captures:
            del zone_captures[config.zone_id]
        if config.zone_id in zone_frames:
            del zone_frames[config.zone_id]
        if config.zone_id in zone_frame_locks:
            del zone_frame_locks[config.zone_id]
        if config.zone_id in zone_video_recorders:
            zone_video_recorders[config.zone_id].cleanup()
            del zone_video_recorders[config.zone_id]
        print(f"Stopped monitoring zone: {config.name}")


@app.get("/")
async def root():
    return {"message": "CrowdSense AI Service", "status": "running"}


@app.post("/zones/start")
async def start_monitoring(config: ZoneConfig):
    """Start monitoring a zone - returns immediately, initialization happens in background"""
    if config.zone_id in monitoring_tasks:
        return {"message": "Zone already being monitored", "zone_id": config.zone_id}
    
    # Create placeholder frame immediately so stream endpoint works right away
    # Do this in executor to avoid blocking
    loop = asyncio.get_event_loop()
    def create_placeholder():
        zone_frame_locks[config.zone_id] = asyncio.Lock()
        placeholder_frame = np.zeros((480, 640, 3), dtype=np.uint8)
        cv2.putText(placeholder_frame, "Initializing...", (200, 240), 
                   cv2.FONT_HERSHEY_SIMPLEX, 1, (255, 255, 255), 2)
        _, buffer = cv2.imencode('.jpg', placeholder_frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
        zone_frames[config.zone_id] = buffer.tobytes()
    
    # Run synchronously but quickly (OpenCV operations are fast)
    create_placeholder()
    
    # Start monitoring task - yield control first to ensure non-blocking
    async def start_monitor():
        await asyncio.sleep(0)  # Yield control immediately
        await monitor_zone(config)
    
    task = asyncio.create_task(start_monitor())
    monitoring_tasks[config.zone_id] = task
    
    # Return immediately without waiting
    return {"message": "Monitoring started", "zone_id": config.zone_id, "status": "initializing"}


@app.post("/zones/{zone_id}/stop")
async def stop_monitoring(zone_id: str):
    """Stop monitoring a zone"""
    if zone_id not in monitoring_tasks:
        # Check if zone is using external camera server
        # If so, we should still return success (external camera server is independent)
        print(f"[INFO] Zone {zone_id} not in monitoring_tasks, may be using external camera server")
        # Check if any other zones are using external_camera
        zones_using_external = []
        for other_zone_id, other_task in monitoring_tasks.items():
            if other_zone_id != zone_id:
                # Check if this zone is using external_camera (would be in zone_captures)
                if other_zone_id in zone_captures:
                    cap = zone_captures[other_zone_id]
                    if cap is _external_camera:
                        zones_using_external.append(other_zone_id)
        
        if not zones_using_external and _external_camera is not None and _external_camera_server is not None:
            # No other zones using external camera, but external camera server is running
            # This means the zone was using external camera server directly (not via Python monitoring)
            # We can't stop external camera server here as it's independent
            print(f"[INFO] Zone {zone_id} was using external camera server, but external camera server is independent")
            print(f"[INFO] External camera server will continue running until manually stopped")
        
        return {"message": "Zone not in monitoring tasks (may be using external stream)", "zone_id": zone_id}
    
    task = monitoring_tasks[zone_id]
    
    # Check if this zone is using external_camera before cancelling
    is_using_external = False
    if zone_id in zone_captures:
        cap = zone_captures[zone_id]
        if cap is _external_camera:
            is_using_external = True
    
    task.cancel()
    
    # Wait for task to finish cleanup
    try:
        await task
    except asyncio.CancelledError:
        pass
    
    del monitoring_tasks[zone_id]
    
    # Check if external_camera should be released
    # Only release if no other zones are using it
    if is_using_external:
        other_zones_using_external = []
        for other_zone_id, other_task in monitoring_tasks.items():
            if other_zone_id in zone_captures:
                other_cap = zone_captures[other_zone_id]
                if other_cap is _external_camera:
                    other_zones_using_external.append(other_zone_id)
        
        if not other_zones_using_external:
            print(f"[INFO] No other zones using external camera, but external camera server is independent")
            print(f"[INFO] External camera server will continue running until manually stopped")
            # Note: We don't stop external_camera_server here because it's independent
            # The user should stop it manually if needed
    
    # Zone status updates are handled by Flutter app
    
    print(f"[INFO] Monitoring stopped for zone {zone_id}, camera resources released")
    return {"message": "Monitoring stopped", "zone_id": zone_id}


@app.get("/zones/{zone_id}/stream")
async def stream_video(zone_id: str):
    """Stream video from a zone's camera as MJPEG"""
    async def generate():
        # Create a placeholder black frame if no frame is available
        import io
        black_frame = np.zeros((480, 640, 3), dtype=np.uint8)
        _, placeholder_buffer = cv2.imencode('.jpg', black_frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
        placeholder_bytes = placeholder_buffer.tobytes()
        
        while zone_id in monitoring_tasks:
            frame_bytes = None
            if zone_id in zone_frames:
                lock = zone_frame_locks.get(zone_id)
                if lock:
                    async with lock:
                        frame_bytes = zone_frames.get(zone_id)
            
            # Use actual frame if available, otherwise use placeholder
            if frame_bytes and len(frame_bytes) > 0:
                yield (b'--frame\r\n'
                       b'Content-Type: image/jpeg\r\n\r\n' + frame_bytes + b'\r\n')
            else:
                # Send placeholder frame to keep stream alive
                yield (b'--frame\r\n'
                       b'Content-Type: image/jpeg\r\n\r\n' + placeholder_bytes + b'\r\n')
            await asyncio.sleep(0.033)  # ~30 FPS for smoother stream
    
    return StreamingResponse(generate(), media_type="multipart/x-mixed-replace; boundary=frame")


@app.get("/zones/{zone_id}/view")
async def stream_view_page(zone_id: str):
    """HTML page to display MJPEG stream - works in both browser and mobile WebView"""
    from fastapi.responses import HTMLResponse
    
    # Get the base URL (use request to determine host)
    # For simplicity, we'll use relative URL
    html_content = f"""
    <!DOCTYPE html>
    <html>
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <title>Camera Stream</title>
        <style>
            * {{
                margin: 0;
                padding: 0;
                box-sizing: border-box;
            }}
            body {{
                background-color: #000;
                display: flex;
                justify-content: center;
                align-items: center;
                height: 100vh;
                overflow: hidden;
            }}
            #stream-container {{
                width: 100%;
                height: 100%;
                display: flex;
                justify-content: center;
                align-items: center;
            }}
            #stream-img {{
                max-width: 100%;
                max-height: 100%;
                width: auto;
                height: auto;
                object-fit: contain;
            }}
            .error {{
                color: #fff;
                text-align: center;
                padding: 20px;
                font-family: Arial, sans-serif;
            }}
        </style>
    </head>
    <body>
        <div id="stream-container">
            <img id="stream-img" src="/zones/{zone_id}/stream" alt="Camera Stream" />
        </div>
        <script>
            const img = document.getElementById('stream-img');
            const container = document.getElementById('stream-container');
            
            // Handle image load
            img.onload = function() {{
                console.log('Stream image loaded');
            }};
            
            // Handle image errors with retry
            img.onerror = function() {{
                console.error('Stream image error, retrying...');
                // Retry loading with cache buster
                setTimeout(function() {{
                    img.src = '/zones/{zone_id}/stream?t=' + Date.now();
                }}, 1000);
            }};
            
            // Periodically refresh to ensure stream stays alive
            setInterval(function() {{
                if (img.src.indexOf('?t=') === -1) {{
                    img.src = '/zones/{zone_id}/stream?t=' + Date.now();
                }}
            }}, 30000); // Refresh every 30 seconds
        </script>
    </body>
    </html>
    """
    return HTMLResponse(content=html_content)


@app.get("/zones/status")
async def get_status():
    """Get status of all monitored zones"""
    active_zones = list(monitoring_tasks.keys())
    return {"active_zones": active_zones, "count": len(active_zones)}


@app.get("/zones/{zone_id}/count")
async def get_zone_count(zone_id: str):
    """Get current people count for a zone (works without Firebase)"""
    count = zone_people_counts.get(zone_id, 0)
    last_updated = zone_last_updated.get(zone_id, 0)
    is_monitoring = zone_id in monitoring_tasks
    
    # Return last known values even if not monitoring (preserves last update time)
    return {
        "zone_id": zone_id,
        "peopleCount": count,
        "lastUpdated": last_updated,  # Preserves last update time even when deactivated
        "is_monitoring": is_monitoring
    }


@app.post("/detect")
async def detect_once(config: ZoneConfig) -> DetectionResult:
    """Perform a single detection (for testing)"""
    global detector
    
    if not detector:
        detector = SimplePeopleDetector()
    
    # Handle camera URL - convert "0" string to integer for direct camera access
    camera_url = config.camera_url or config.rtsp_url
    try:
        # Try to convert to integer if it's a numeric string (for direct camera)
        camera_index = int(camera_url)
        cap = cv2.VideoCapture(camera_index)
    except (ValueError, TypeError):
        # Use as string URL for RTSP/HTTP streams
        cap = cv2.VideoCapture(camera_url)
    
    if not cap.isOpened():
        raise HTTPException(status_code=400, detail="Could not open camera stream")
    
    ret, frame = cap.read()
    cap.release()
    
    if not ret:
        raise HTTPException(status_code=400, detail="Failed to read frame")
    
    count, confidence = detector.detect(frame)
    
    return DetectionResult(
        zone_id=config.zone_id,
        count=count,
        timestamp=int(time.time() * 1000),
        confidence=confidence
    )


@app.get("/zones/{zone_id}/storage")
async def get_storage_info(zone_id: str):
    """Get storage information for a zone (works even if zone is not currently monitoring)"""
    from pathlib import Path
    import json
    
    # Try to get from active recorder first
    if zone_id in zone_video_recorders:
        return zone_video_recorders[zone_id].get_storage_info()
    else:
        # Zone not monitoring, calculate from disk
        recordings_path = Path("recordings") / zone_id
        metadata_path = recordings_path / "metadata.json"
        
        total_size = 0
        video_count = 0
        
        if recordings_path.exists():
            # Calculate total size of all MP4 files
            for video_file in recordings_path.glob("*.mp4"):
                if video_file.is_file():
                    total_size += video_file.stat().st_size
            
            # Get video count from metadata if available
            if metadata_path.exists():
                try:
                    with open(metadata_path, 'r') as f:
                        metadata = json.load(f)
                        video_count = len(metadata.get("videos", []))
                except:
                    pass
        
        max_size_bytes = 5 * 1024 * 1024 * 1024  # 5GB
        return {
            "zone_id": zone_id,
            "total_size_bytes": total_size,
            "total_size_gb": total_size / (1024 ** 3),
            "max_size_bytes": max_size_bytes,
            "max_size_gb": max_size_bytes / (1024 ** 3),
            "usage_percent": (total_size / max_size_bytes) * 100,
            "is_full": total_size >= max_size_bytes,
            "video_count": video_count,
        }


@app.get("/zones/{zone_id}/videos")
async def get_video_list(zone_id: str):
    """Get list of all recorded videos for a zone (works even if zone is not currently monitoring)"""
    from pathlib import Path
    import json
    
    # Try to get from active recorder first
    if zone_id in zone_video_recorders:
        videos = zone_video_recorders[zone_id].get_video_list()
        # Verify files exist for active recorder too
        storage_path = Path(zone_video_recorders[zone_id].storage_path)
        valid_videos = []
        for video in videos:
            video_filename = video.get("filename", "")
            video_path = storage_path / video_filename
            if video_path.exists():
                valid_videos.append(video)
            else:
                print(f"[WARN] Video file not found, removing from list: {video_filename}")
        videos = valid_videos
    else:
        # Zone not monitoring, but videos may still exist on disk
        # Try to load from metadata.json file
        recordings_path = Path("recordings") / zone_id / "metadata.json"
        video_dir = Path("recordings") / zone_id
        videos = []
        metadata_updated = False
        
        if recordings_path.exists():
            try:
                with open(recordings_path, 'r') as f:
                    metadata = json.load(f)
                    videos = metadata.get("videos", [])
            except Exception as e:
                print(f"[WARN] Failed to load metadata for zone {zone_id}: {e}")
                videos = []
        
        # Verify each video file exists, remove invalid entries
        valid_videos = []
        for video in videos:
            video_filename = video.get("filename", "")
            video_path = video_dir / video_filename
            if video_path.exists():
                valid_videos.append(video)
            else:
                print(f"[WARN] Video file not found, removing from list: {video_filename}")
                metadata_updated = True
        
        # Update metadata.json if we removed invalid entries
        if metadata_updated and recordings_path.exists():
            try:
                with open(recordings_path, 'r') as f:
                    metadata = json.load(f)
                metadata["videos"] = valid_videos
                with open(recordings_path, 'w') as f:
                    json.dump(metadata, f, indent=2)
                print(f"[INFO] Cleaned metadata.json for zone {zone_id}, removed {len(videos) - len(valid_videos)} invalid entries")
            except Exception as e:
                print(f"[ERROR] Failed to update metadata for zone {zone_id}: {e}")
        
        videos = valid_videos
    
    # Sort by timestamp (newest first)
    videos.sort(key=lambda x: x.get("timestamp", 0), reverse=True)
    return {"videos": videos}


@app.delete("/zones/{zone_id}/videos/{video_filename}")
async def delete_video(zone_id: str, video_filename: str):
    """Delete a video file (works even if zone is not currently monitoring)"""
    from pathlib import Path
    import json
    
    success = False
    metadata_updated = False
    
    # Try to delete using active recorder first
    if zone_id in zone_video_recorders:
        success = zone_video_recorders[zone_id].delete_video(video_filename)
    else:
        # Zone not monitoring, delete directly from disk and update metadata
        video_path = Path("recordings") / zone_id / video_filename
        metadata_path = Path("recordings") / zone_id / "metadata.json"
        
        # Try to delete file if it exists
        if video_path.exists():
            try:
                video_path.unlink()
                success = True
            except Exception as e:
                print(f"[ERROR] Failed to delete video file {video_filename}: {e}")
        
        # Always update metadata to remove the entry, even if file doesn't exist
        # This handles the case where metadata has stale entries
        if metadata_path.exists():
            try:
                with open(metadata_path, 'r') as f:
                    metadata = json.load(f)
                original_count = len(metadata.get("videos", []))
                metadata["videos"] = [
                    v for v in metadata.get("videos", [])
                    if v.get("filename") != video_filename
                ]
                if len(metadata["videos"]) < original_count:
                    with open(metadata_path, 'w') as f:
                        json.dump(metadata, f, indent=2)
                    metadata_updated = True
                    success = True  # Consider it success if we removed from metadata
                    print(f"[INFO] Removed {video_filename} from metadata (file may not have existed)")
            except Exception as e:
                print(f"[ERROR] Failed to update metadata for zone {zone_id}: {e}")
    
    if not success:
        raise HTTPException(status_code=404, detail="Video not found")
    
    return {"message": "Video deleted successfully", "filename": video_filename}


@app.post("/zones/{zone_id}/videos/cleanup")
async def cleanup_video_metadata(zone_id: str):
    """Clean up metadata.json by removing entries for videos that don't exist on disk"""
    from pathlib import Path
    import json
    
    metadata_path = Path("recordings") / zone_id / "metadata.json"
    
    if not metadata_path.exists():
        return {"message": "No metadata file found", "removed_count": 0}
    
    try:
        with open(metadata_path, 'r') as f:
            metadata = json.load(f)
        
        videos = metadata.get("videos", [])
        original_count = len(videos)
        
        # Determine video directory path
        if zone_id in zone_video_recorders:
            video_dir = Path(zone_video_recorders[zone_id].storage_path)
        else:
            video_dir = Path("recordings") / zone_id
        
        # Filter out videos that don't exist
        valid_videos = []
        for video in videos:
            video_filename = video.get("filename", "")
            video_path = video_dir / video_filename
            if video_path.exists():
                valid_videos.append(video)
        
        removed_count = original_count - len(valid_videos)
        
        # Update metadata
        metadata["videos"] = valid_videos
        with open(metadata_path, 'w') as f:
            json.dump(metadata, f, indent=2)
        
        return {
            "message": f"Cleaned up metadata for zone {zone_id}",
            "removed_count": removed_count,
            "remaining_count": len(valid_videos)
        }
    except Exception as e:
        print(f"[ERROR] Failed to cleanup metadata for zone {zone_id}: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to cleanup metadata: {str(e)}")


@app.get("/zones/{zone_id}/videos/{video_filename}/stream")
async def stream_video(zone_id: str, video_filename: str):
    """Stream a video file with proper headers for browser compatibility (works even if zone is not currently monitoring)"""
    from fastapi.responses import FileResponse, StreamingResponse
    from pathlib import Path
    import os
    
    # Get video path - try from recorder first, then from disk
    if zone_id in zone_video_recorders:
        recorder = zone_video_recorders[zone_id]
        video_path = Path(recorder.storage_path) / video_filename
    else:
        # Zone not monitoring, construct path directly
        video_path = Path("recordings") / zone_id / video_filename
    
    if not video_path.exists():
        raise HTTPException(status_code=404, detail="Video file not found")
    
    # Use FileResponse with proper headers for video streaming
    return FileResponse(
        path=str(video_path),
        media_type="video/mp4",
        filename=video_filename,
        headers={
            "Accept-Ranges": "bytes",
            "Content-Type": "video/mp4",
            "Cache-Control": "no-cache",
        }
    )


# ============================================================================
# External Camera Server (for streaming local camera to other computers)
# ============================================================================

class ExternalCameraStreamHandler(BaseHTTPRequestHandler):
    """HTTP handler for external camera streaming"""
    def do_GET(self):
        if self.path == '/video' or self.path == '/external-camera/video':
            self.send_response(200)
            self.send_header('Content-Type', 'multipart/x-mixed-replace; boundary=frame')
            self.end_headers()
            
            try:
                camera = self.server.camera
                while True:
                    ret, frame = camera.read()
                    if not ret:
                        break
                    
                    # Resize frame for better performance
                    frame = cv2.resize(frame, (640, 480))
                    
                    # Encode frame as JPEG
                    _, buffer = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
                    frame_bytes = buffer.tobytes()
                    
                    # Send frame
                    self.wfile.write(b'--frame\r\n')
                    self.send_header('Content-Type', 'image/jpeg')
                    self.send_header('Content-Length', len(frame_bytes))
                    self.end_headers()
                    self.wfile.write(frame_bytes)
                    self.wfile.write(b'\r\n')
                    
            except Exception as e:
                print(f"[External Camera] Streaming error: {e}")
        else:
            self.send_response(404)
            self.end_headers()
    
    def log_message(self, format, *args):
        # Suppress default logging
        pass


class ExternalCameraHTTPServer(HTTPServer):
    """HTTP server with camera access"""
    def __init__(self, server_address, RequestHandlerClass, camera):
        super().__init__(server_address, RequestHandlerClass)
        self.camera = camera


def get_local_ip():
    """Get the local IP address"""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def start_external_camera_server(port: int = 8080, camera_index: int = 0):
    """Start external camera HTTP stream server in background thread"""
    global _external_camera_server, _external_camera
    
    # If external camera server is already running, stop it first to avoid conflicts
    # This ensures clean restart after hot restart or deactivate/activate cycle
    if _external_camera_server is not None or _external_camera is not None:
        print(f"[INFO] External camera server already exists, cleaning up first...")
        try:
            # Release camera if exists
            if _external_camera is not None:
                try:
                    if _external_camera.isOpened():
                        _external_camera.release()
                        print(f"[INFO] Released existing camera")
                except Exception as e:
                    print(f"[WARN] Error releasing existing camera: {e}")
                _external_camera = None
            
            # Stop server if exists
            if _external_camera_server is not None:
                try:
                    import threading
                    def shutdown_server():
                        try:
                            _external_camera_server.shutdown()
                        except Exception as e:
                            print(f"[WARN] Error in shutdown: {e}")
                    
                    shutdown_thread = threading.Thread(target=shutdown_server, daemon=True)
                    shutdown_thread.start()
                    shutdown_thread.join(timeout=1.0)
                    
                    try:
                        _external_camera_server.server_close()
                    except Exception as e:
                        print(f"[WARN] Error closing server: {e}")
                    print(f"[INFO] Stopped existing server")
                except Exception as e:
                    print(f"[WARN] Error stopping existing server: {e}")
                
                _external_camera_server = None
            
            # Wait a bit for cleanup to complete (important for camera resource release)
            import time
            time.sleep(1.5)  # Increased wait time to ensure camera resource is fully released
            print(f"[INFO] Cleanup completed, starting new external camera server...")
        except Exception as e:
            print(f"[WARN] Error cleaning up existing external camera server: {e}")
    
    def run_server():
        global _external_camera_server, _external_camera
        
        try:
            # Open camera
            print(f"[External Camera] Opening camera {camera_index}...")
            camera = cv2.VideoCapture(camera_index)
            
            if not camera.isOpened():
                print(f"[External Camera] ⚠️  Warning: Could not open camera {camera_index}")
                print(f"[External Camera]    This is OK if you don't need external camera streaming")
                # Set global variables to None to indicate failure
                _external_camera = None
                _external_camera_server = None
                return
            
            # Set camera properties
            camera.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
            camera.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
            camera.set(cv2.CAP_PROP_FPS, 30)
            
            _external_camera = camera
            
            # Get local IP
            local_ip = get_local_ip()
            
            # Create server
            server = ExternalCameraHTTPServer(
                ('0.0.0.0', port),
                ExternalCameraStreamHandler,
                camera
            )
            _external_camera_server = server
            
            print("\n" + "="*60)
            print("🌐 External Camera Stream Server Started!")
            print("="*60)
            print(f"📹 Camera Index: {camera_index}")
            print(f"🌍 Local URL: http://localhost:{port}/video")
            print(f"🌐 Network URL: http://{local_ip}:{port}/video")
            print(f"\n💡 To use this camera from another computer:")
            print(f"   Enter this URL in CrowdSense Camera Setup:")
            print(f"   http://{local_ip}:{port}/video")
            print("="*60 + "\n")
            
            # Run server
            server.serve_forever()
            
        except Exception as e:
            print(f"[External Camera] ❌ Error: {e}")
        finally:
            if _external_camera:
                _external_camera.release()
                _external_camera = None
            if _external_camera_server:
                _external_camera_server.server_close()
                _external_camera_server = None
            print("[External Camera] Server stopped")
    
    # Start in background thread
    thread = Thread(target=run_server, daemon=True)
    thread.start()
    return thread


@app.get("/external-camera/status")
async def get_external_camera_status():
    """Get status of external camera server"""
    global _external_camera_server, _external_camera
    
    is_running = _external_camera_server is not None and _external_camera is not None
    local_ip = get_local_ip()
    
    return {
        "running": is_running,
        "local_url": f"http://localhost:8080/video" if is_running else None,
        "network_url": f"http://{local_ip}:8080/video" if is_running else None,
        "camera_available": _external_camera is not None and _external_camera.isOpened() if _external_camera else False
    }


@app.post("/external-camera/stop")
async def stop_external_camera():
    """Stop external camera server and release camera"""
    global _external_camera_server, _external_camera
    
    # Check if any zones are using external_camera
    zones_using_external = []
    for zone_id in monitoring_tasks.keys():
        if zone_id in zone_captures:
            cap = zone_captures[zone_id]
            if cap is _external_camera:
                zones_using_external.append(zone_id)
    
    if zones_using_external:
        raise HTTPException(
            status_code=400, 
            detail=f"Cannot stop external camera server: zones {zones_using_external} are still using it"
        )
    
    if _external_camera_server is None:
        return {"message": "External camera server is not running", "stopped": False}
    
    try:
        # Stop the server
        # Note: HTTPServer.shutdown() must be called from a different thread
        # We'll use a simple approach: set a flag and let the server thread handle it
        server_to_stop = _external_camera_server
        
        # Release camera first (before stopping server)
        if _external_camera is not None:
            try:
                _external_camera.release()
                print("[INFO] External camera released")
            except Exception as e:
                print(f"[ERROR] Error releasing camera: {e}")
            _external_camera = None
        
        # Stop the server
        if server_to_stop is not None:
            try:
                # Shutdown must be called from another thread
                import threading
                def shutdown_server():
                    try:
                        server_to_stop.shutdown()
                    except Exception as e:
                        print(f"[ERROR] Error in shutdown: {e}")
                
                shutdown_thread = threading.Thread(target=shutdown_server, daemon=True)
                shutdown_thread.start()
                shutdown_thread.join(timeout=1.0)
                
                try:
                    server_to_stop.server_close()
                except Exception as e:
                    print(f"[ERROR] Error closing server: {e}")
                
                print("[INFO] External camera server stopped")
            except Exception as e:
                print(f"[ERROR] Error stopping server: {e}")
        
        _external_camera_server = None
        
        print("[INFO] External camera server stopped and camera released")
        return {"message": "External camera server stopped", "stopped": True}
    except Exception as e:
        print(f"[ERROR] Error stopping external camera server: {e}")
        raise HTTPException(status_code=500, detail=f"Error stopping external camera server: {str(e)}")


# Pre-initialize detector on startup to avoid delays on first request
def preload_detector():
    """Pre-load detector in background thread"""
    global detector
    if not detector:
        print("Pre-loading detector on startup...")
        try:
            detector = PeopleDetector()  # Use YOLOv8 for better accuracy
            print("[OK] YOLOv8 detector pre-loaded successfully")
        except Exception as e:
            print(f"[WARN] YOLOv8 pre-load failed: {e}, will try SimplePeopleDetector on first request")
            detector = None

if __name__ == "__main__":
    import uvicorn
    import threading
    
    # Parse command line arguments
    parser = argparse.ArgumentParser(description='CrowdSense AI Service - All-in-one')
    parser.add_argument('--port', type=int, default=8000, help='Port for AI service API (default: 8000)')
    parser.add_argument('--external-camera-port', type=int, default=8080, help='Port for external camera stream server (default: 8080, set to 0 to disable)')
    parser.add_argument('--external-camera-index', type=int, default=0, help='Camera index for external camera server (default: 0)')
    parser.add_argument('--enable-external-camera', action='store_true', help='Enable external camera streaming server')
    args = parser.parse_args()
    
    print("="*60)
    print("🚀 CrowdSense AI Service - Starting...")
    print("="*60)
    
    # Start detector pre-loading in background
    detector_thread = threading.Thread(target=preload_detector, daemon=True)
    detector_thread.start()
    
    # Start external camera server if enabled
    if args.enable_external_camera and args.external_camera_port > 0:
        print(f"\n📹 Starting external camera server on port {args.external_camera_port}...")
        start_external_camera_server(args.external_camera_port, args.external_camera_index)
    elif args.external_camera_port > 0:
        # Show what URL would be available if external camera server is enabled
        local_ip = get_local_ip()
        print(f"\n💡 External Camera Server (not started)")
        print(f"   To enable: Use --enable-external-camera flag")
        print(f"   If enabled, URLs would be:")
        print(f"   - Local: http://localhost:{args.external_camera_port}/video")
        print(f"   - Network: http://{local_ip}:{args.external_camera_port}/video")
    
    print(f"\n🌐 Starting AI service API on http://0.0.0.0:{args.port}")
    print("="*60 + "\n")
    
    try:
        uvicorn.run(app, host="0.0.0.0", port=args.port)
    except KeyboardInterrupt:
        print("\n\n🛑 Shutting down...")
        # Cleanup
        if _external_camera:
            _external_camera.release()
        if _external_camera_server:
            _external_camera_server.server_close()
        print("✅ Shutdown complete")
