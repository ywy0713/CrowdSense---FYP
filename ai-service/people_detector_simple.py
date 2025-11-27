"""
Simple and Fast People Detection
Uses OpenCV Haar Cascade (lightweight) + MediaPipe (if available) as fallback
Much faster than YOLO, suitable for real-time applications
"""

import cv2
import numpy as np
import time
from typing import Tuple
import os

class SimplePeopleDetector:
    """
    Lightweight people detector using OpenCV Haar Cascade
    Fast, reliable, and doesn't require heavy ML models
    """
    
    def __init__(self):
        """Initialize Haar Cascade detector"""
        self.cascade_path = None
        self.detector = None
        self.use_mediapipe = False
        self.mediapipe_pose = None
        
        # Try to load Haar Cascade (built into OpenCV)
        try:
            # Try different possible paths for Haar Cascade
            cascade_paths = [
                cv2.data.haarcascades + 'haarcascade_fullbody.xml',
                cv2.data.haarcascades + 'haarcascade_upperbody.xml',
                cv2.data.haarcascades + 'haarcascade_lowerbody.xml',
            ]
            
            for path in cascade_paths:
                if os.path.exists(path):
                    self.detector = cv2.CascadeClassifier(path)
                    if not self.detector.empty():
                        self.cascade_path = path
                        print(f"[OK] Loaded Haar Cascade: {os.path.basename(path)}")
                        break
            
            # If Haar Cascade failed, try MediaPipe
            if self.detector is None or self.detector.empty():
                try:
                    import mediapipe as mp
                    self.mp_pose = mp.solutions.pose
                    self.mediapipe_pose = self.mp_pose.Pose(
                        min_detection_confidence=0.3,
                        min_tracking_confidence=0.3,
                        model_complexity=0  # Fastest model
                    )
                    self.use_mediapipe = True
                    print("[OK] Using MediaPipe Pose Detection (faster than YOLO)")
                except ImportError:
                    print("[WARN] MediaPipe not available")
                    self.detector = None
            
        except Exception as e:
            print(f"[WARN] Error initializing detector: {e}")
            self.detector = None
        
        # If no detector available, raise error
        if self.detector is None or (hasattr(self.detector, 'empty') and self.detector.empty()):
            if not self.use_mediapipe:
                raise RuntimeError("No detector available: Haar Cascade and MediaPipe both failed")
    
    def detect(self, frame: np.ndarray, confidence_threshold: float = 0.3) -> Tuple[int, float]:
        """
        Detect people in frame using Haar Cascade or MediaPipe
        
        Args:
            frame: BGR image frame from OpenCV
            confidence_threshold: Not used for Haar Cascade, kept for compatibility
        
        Returns:
            Tuple of (person_count, average_confidence)
        """
        if frame is None or frame.size == 0:
            return 0, 0.0
        
        try:
            # Convert to grayscale for Haar Cascade
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            
            # Use MediaPipe if available (more accurate)
            if self.use_mediapipe and self.mediapipe_pose is not None:
                return self._detect_mediapipe(frame)
            
            # Use Haar Cascade if available
            if self.detector is not None and not self.detector.empty():
                return self._detect_haar_cascade(gray, frame)
            
            # No detector available
            print("[ERROR] No detector available (Haar Cascade or MediaPipe)")
            return 0, 0.0
            
        except Exception as e:
            print(f"Detection error: {e}")
            return 0, 0.0
    
    def _detect_mediapipe(self, frame: np.ndarray) -> Tuple[int, float]:
        """Detect people using MediaPipe Pose"""
        try:
            rgb_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            results = self.mediapipe_pose.process(rgb_frame)
            
            person_count = 0
            confidences = []
            
            if results.pose_landmarks:
                # Count unique people (MediaPipe detects one person at a time per frame)
                # But we can detect multiple by checking pose landmarks
                # For simplicity, count 1 person if landmarks detected
                person_count = 1
                # Estimate confidence from visibility of key landmarks
                if results.pose_landmarks.landmark:
                    visibilities = [lm.visibility for lm in results.pose_landmarks.landmark]
                    avg_confidence = np.mean(visibilities) if visibilities else 0.5
                    confidences.append(avg_confidence)
            
            avg_conf = np.mean(confidences) if confidences else 0.0
            
            # Note: MediaPipe processes one person at a time, but we can run multiple times
            # For now, return 0 or 1
            return person_count, avg_conf
            
        except Exception as e:
            print(f"MediaPipe detection error: {e}")
            return 0, 0.0
    
    def _detect_haar_cascade(self, gray: np.ndarray, frame: np.ndarray) -> Tuple[int, float]:
        """Detect people using Haar Cascade"""
        try:
            # Detect people with optimized parameters for speed
            # Scale factor: how much the image size is reduced at each scale
            # Min neighbors: how many neighbors each candidate rectangle should have
            # Min size: minimum possible object size
            
            # Resize for faster detection (optional)
            height, width = gray.shape
            if height > 480:
                scale = 480 / height
                new_width = int(width * scale)
                gray_resized = cv2.resize(gray, (new_width, 480))
            else:
                gray_resized = gray
            
            # Detect people with relaxed parameters for better detection
            # More aggressive settings to catch sitting people and various poses
            detections = self.detector.detectMultiScale(
                gray_resized,
                scaleFactor=1.05,  # Smaller = more scales checked (more accurate, slower)
                minNeighbors=2,   # Lower = more detections (catch more people, including sitting)
                minSize=(20, 20), # Smaller minimum size to catch people at distance or sitting
                maxSize=(gray_resized.shape[1], gray_resized.shape[0]),  # No max size limit
                flags=cv2.CASCADE_SCALE_IMAGE
            )
            
            # More lenient filtering - accept wider range of aspect ratios
            # Sitting people might have different aspect ratios
            valid_detections = []
            for (x, y, w, h) in detections:
                aspect_ratio = h / w if w > 0 else 0
                area = w * h
                # Accept if:
                # 1. Taller than wide (standing person) OR
                # 2. Reasonable size (not too small, not too large) OR
                # 3. Aspect ratio between 0.8 and 3.0 (covers sitting and standing)
                if (aspect_ratio > 0.8 and aspect_ratio < 3.0) and (area > 400 and area < 50000):
                    valid_detections.append((x, y, w, h))
            
            person_count = len(valid_detections)
            
            # Estimate confidence (Haar Cascade doesn't provide confidence scores)
            # Use detection count and size as proxy
            avg_confidence = 0.7 if person_count > 0 else 0.0
            
            # Always print detection results for debugging
            if person_count > 0:
                print(f"   [SIMPLE] [OK] Detected {person_count} person(s) using Haar Cascade")
                print(f"      Raw detections: {len(detections)}, Valid: {person_count}")
                for i, (x, y, w, h) in enumerate(valid_detections[:3]):  # Show first 3
                    aspect_ratio = h / w if w > 0 else 0
                    area = w * h
                    print(f"      Detection {i+1}: size={w}x{h}, area={area}, aspect={aspect_ratio:.2f}")
            else:
                if len(detections) > 0:
                    print(f"   [SIMPLE] [WARN] Found {len(detections)} raw detections but none passed filter")
                    for i, (x, y, w, h) in enumerate(detections[:2]):  # Show first 2
                        aspect_ratio = h / w if w > 0 else 0
                        area = w * h
                        print(f"      Raw {i+1}: size={w}x{h}, area={area}, aspect={aspect_ratio:.2f} (rejected)")
                else:
                    print(f"   [SIMPLE] [FAIL] No detections found")
            
            return person_count, avg_confidence
            
        except Exception as e:
            print(f"Haar Cascade detection error: {e}")
            return 0, 0.0
    
    def detect_with_annotations(self, frame: np.ndarray, confidence_threshold: float = 0.3) -> Tuple[np.ndarray, int, float]:
        """
        Detect people and draw bounding boxes on frame
        """
        annotated_frame = frame.copy()
        count, confidence = self.detect(frame, confidence_threshold)
        
        if count == 0:
            return annotated_frame, count, confidence
        
        try:
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            
            # Draw detections
            if self.detector is not None and not self.detector.empty():
                height, width = gray.shape
                if height > 480:
                    scale = 480 / height
                    new_width = int(width * scale)
                    gray_resized = cv2.resize(gray, (new_width, 480))
                else:
                    gray_resized = gray
                
                detections = self.detector.detectMultiScale(
                    gray_resized,
                    scaleFactor=1.1,
                    minNeighbors=3,
                    minSize=(30, 30)
                )
                
                # Scale back if resized
                if height > 480:
                    scale_factor = height / 480
                    detections = [(int(x * scale_factor), int(y * scale_factor), 
                                 int(w * scale_factor), int(h * scale_factor)) 
                                for (x, y, w, h) in detections]
                
                # Draw bounding boxes
                for (x, y, w, h) in detections:
                    aspect_ratio = h / w if w > 0 else 0
                    if aspect_ratio > 1.2:  # Only draw if person-like
                        cv2.rectangle(annotated_frame, (x, y), (x + w, y + h), (0, 255, 0), 2)
                        cv2.putText(annotated_frame, "Person", (x, y - 10),
                                  cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 2)
            
            return annotated_frame, count, confidence
            
        except Exception as e:
            print(f"Annotation error: {e}")
            return annotated_frame, count, confidence

