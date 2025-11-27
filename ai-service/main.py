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
import requests
from datetime import datetime
from typing import Dict, List, Optional
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

# Store current people counts for each zone (for API access without Firebase)
zone_people_counts: Dict[str, int] = {}
zone_last_updated: Dict[str, int] = {}

# Store video recorders for each zone
zone_video_recorders: Dict[str, VideoRecorder] = {}

# External camera server (for streaming local camera to other computers)
_external_camera_server: Optional[HTTPServer] = None
_external_camera: Optional[cv2.VideoCapture] = None


# ============================================================================
# HTTP Stream Handler for MJPEG streams
# ============================================================================

class HTTPStreamCapture:
    """Custom capture class for HTTP MJPEG streams"""
    def __init__(self, url: str):
        self.url = url
        self.stream = None
        self.current_frame = None
        self._opened = False
        self._connect()
    
    def _connect(self):
        """Connect to HTTP stream"""
        try:
            print(f"[HTTP Stream] Connecting to {self.url}...")
            response = requests.get(self.url, stream=True, timeout=10)
            if response.status_code == 200:
                self.stream = response.iter_content(chunk_size=1024)
                self._opened = True
                print(f"[HTTP Stream] ✅ Connected successfully")
            else:
                print(f"[HTTP Stream] ❌ Failed: HTTP {response.status_code}")
                self._opened = False
        except Exception as e:
            print(f"[HTTP Stream] ❌ Connection error: {e}")
            self._opened = False
    
    def read(self):
        """Read a frame from the stream"""
        if not self._opened:
            # Try to reconnect
            self._connect()
            if not self._opened:
                return False, None
        
        try:
            # Reconnect if stream is None
            if self.stream is None:
                self._connect()
                if self.stream is None:
                    return False, None
            
            # Read MJPEG stream - look for JPEG markers
            jpeg_data = b''
            in_frame = False
            max_iterations = 1000  # Prevent infinite loop
            iteration = 0
            
            for chunk in self.stream:
                iteration += 1
                if iteration > max_iterations:
                    print(f"[HTTP Stream] Max iterations reached, reconnecting...")
                    self._connect()
                    return False, None
                
                if not chunk:
                    continue
                
                jpeg_data += chunk
                
                # Look for JPEG start marker (0xFF 0xD8)
                if b'\xff\xd8' in jpeg_data:
                    start_idx = jpeg_data.find(b'\xff\xd8')
                    jpeg_data = jpeg_data[start_idx:]
                    in_frame = True
                
                # Look for JPEG end marker (0xFF 0xD9)
                if in_frame and b'\xff\xd9' in jpeg_data:
                    end_idx = jpeg_data.find(b'\xff\xd9') + 2
                    frame_data = jpeg_data[:end_idx]
                    jpeg_data = jpeg_data[end_idx:]
                    
                    # Decode JPEG
                    try:
                        frame_array = np.frombuffer(frame_data, dtype=np.uint8)
                        frame = cv2.imdecode(frame_array, cv2.IMREAD_COLOR)
                        if frame is not None:
                            self.current_frame = frame
                            return True, frame
                    except Exception as e:
                        print(f"[HTTP Stream] Decode error: {e}")
                        continue
                
                # Limit buffer size to prevent memory issues
                if len(jpeg_data) > 1024 * 1024:  # 1MB limit
                    jpeg_data = b''
                    in_frame = False
                    print(f"[HTTP Stream] Buffer limit reached, resetting...")
            
            # Stream ended, reconnect
            print(f"[HTTP Stream] Stream ended, reconnecting...")
            self._connect()
            return False, None
        except Exception as e:
            print(f"[HTTP Stream] Read error: {e}, reconnecting...")
            self._connect()
            return False, None
    
    def isOpened(self):
        return self._opened
    
    def release(self):
        self._opened = False
        self.stream = None
        self.current_frame = None
    
    def get(self, prop):
        """Return default values for compatibility"""
        if prop == cv2.CAP_PROP_FRAME_WIDTH:
            return 640
        elif prop == cv2.CAP_PROP_FRAME_HEIGHT:
            return 480
        elif prop == cv2.CAP_PROP_FPS:
            return 30
        return 0


def _create_http_stream_capture(url: str):
    """Create a capture object for HTTP MJPEG stream"""
    try:
        return HTTPStreamCapture(url)
    except Exception as e:
        print(f"[ERROR] Failed to create HTTP stream capture: {e}")
        return None


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
    
    global detector
    
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
    try:
        # Try to convert to integer if it's a numeric string (for direct camera)
        camera_index = int(camera_url)
        print(f"Opening camera with index: {camera_index}")
        cap = cv2.VideoCapture(camera_index)
        
        # Set camera properties - Use normal resolution
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
            
    except (ValueError, TypeError) as e:
        # Use as string URL for RTSP/HTTP streams
        print(f"Using camera as URL string: {camera_url}")
        
        # Check if it's an HTTP URL - OpenCV has issues with HTTP MJPEG streams
        if camera_url.startswith('http://') or camera_url.startswith('https://'):
            print(f"[INFO] HTTP stream detected, using requests for better compatibility")
            # For HTTP streams, we'll use a custom reader that handles MJPEG properly
            cap = _create_http_stream_capture(camera_url)
        else:
            # RTSP or other protocols - use OpenCV directly
            cap = cv2.VideoCapture(camera_url)
            # Set buffer size to reduce latency
            cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
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
    
    # Test reading a frame immediately to verify it works
    print(f"🔍 Testing frame read for {config.zone_id}...")
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
    else:
        print(f"❌ ERROR: Test frame read failed! ret={test_ret}, frame is None: {test_frame is None}")
    
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
    test_ret, test_frame = cap.read()
    if test_ret and test_frame is not None:
        print(f"✅ Test frame read successfully: {test_frame.shape}")
        # Store initial frame
        _, buffer = cv2.imencode('.jpg', test_frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
        if buffer is not None:
            zone_frames[config.zone_id] = buffer.tobytes()
            print(f"✅ Initial frame stored for streaming")
    else:
        print(f"⚠️ Warning: Test frame read failed, but continuing...")
    
    try:
        # Keep monitoring even if config.enabled changes (only stop when task is cancelled)
        while True:
            # Check if task was cancelled
            if config.zone_id not in monitoring_tasks:
                print(f"Monitoring task cancelled for {config.zone_id}")
                break
                
            # Read frame synchronously
            # Handle both OpenCV VideoCapture and custom HTTPStreamCapture
            if isinstance(cap, HTTPStreamCapture):
                ret, frame = cap.read()
            else:
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
                        camera_index = int(camera_url)
                        cap.release()
                        await asyncio.sleep(0.5)
                        cap = cv2.VideoCapture(camera_index)
                        cap.set(cv2.CAP_PROP_FRAME_WIDTH, 160)  # Very low resolution for maximum performance
                        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 120)
                        cap.set(cv2.CAP_PROP_FPS, 30)
                        if cap.isOpened():
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
                        import traceback
                        traceback.print_exc()
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
                            success = zone_video_recorders[config.zone_id].start_recording(trigger_reason)
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
        import traceback
        traceback.print_exc()
    finally:
        # Only release if cap exists and was opened
        if 'cap' in locals() and cap is not None:
            try:
                cap.release()
                print(f"Camera released for zone: {config.zone_id}")
            except Exception as e:
                print(f"Error releasing camera: {e}")
        
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
        raise HTTPException(status_code=404, detail="Zone not being monitored")
    
    task = monitoring_tasks[zone_id]
    task.cancel()
    
    # Wait for task to finish cleanup
    try:
        await task
    except asyncio.CancelledError:
        pass
    
    del monitoring_tasks[zone_id]
    
    # Zone status updates are handled by Flutter app
    
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
    else:
        # Zone not monitoring, but videos may still exist on disk
        # Try to load from metadata.json file
        recordings_path = Path("recordings") / zone_id / "metadata.json"
        if recordings_path.exists():
            try:
                with open(recordings_path, 'r') as f:
                    metadata = json.load(f)
                    videos = metadata.get("videos", [])
            except Exception as e:
                print(f"[WARN] Failed to load metadata for zone {zone_id}: {e}")
                videos = []
        else:
            videos = []
    
    # Sort by timestamp (newest first)
    videos.sort(key=lambda x: x.get("timestamp", 0), reverse=True)
    return {"videos": videos}


@app.delete("/zones/{zone_id}/videos/{video_filename}")
async def delete_video(zone_id: str, video_filename: str):
    """Delete a video file (works even if zone is not currently monitoring)"""
    from pathlib import Path
    import json
    
    # Try to delete using active recorder first
    if zone_id in zone_video_recorders:
        success = zone_video_recorders[zone_id].delete_video(video_filename)
    else:
        # Zone not monitoring, delete directly from disk and update metadata
        video_path = Path("recordings") / zone_id / video_filename
        metadata_path = Path("recordings") / zone_id / "metadata.json"
        
        success = False
        if video_path.exists():
            try:
                video_path.unlink()
                # Update metadata if it exists
                if metadata_path.exists():
                    with open(metadata_path, 'r') as f:
                        metadata = json.load(f)
                    metadata["videos"] = [
                        v for v in metadata.get("videos", [])
                        if v.get("filename") != video_filename
                    ]
                    with open(metadata_path, 'w') as f:
                        json.dump(metadata, f, indent=2)
                success = True
            except Exception as e:
                print(f"[ERROR] Failed to delete video {video_filename}: {e}")
    
    if not success:
        raise HTTPException(status_code=404, detail="Video not found")
    
    return {"message": "Video deleted successfully", "filename": video_filename}


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
    
    def run_server():
        global _external_camera_server, _external_camera
        
        try:
            # Open camera
            print(f"[External Camera] Opening camera {camera_index}...")
            camera = cv2.VideoCapture(camera_index)
            
            if not camera.isOpened():
                print(f"[External Camera] ⚠️  Warning: Could not open camera {camera_index}")
                print(f"[External Camera]    This is OK if you don't need external camera streaming")
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
        print(f"\n💡 Tip: Use --enable-external-camera to start external camera streaming server")
    
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
