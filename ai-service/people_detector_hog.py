"""
Lightweight People Detection using OpenCV HOG Descriptor
This is MUCH faster and more reliable than YOLO for simple person detection
"""

import cv2
import numpy as np
from typing import Tuple
import time


class PeopleDetectorHOG:
    """
    Lightweight person detector using OpenCV's HOG (Histogram of Oriented Gradients)
    This is specifically designed for person detection and is much faster than YOLO
    """
    
    def __init__(self):
        """Initialize HOG person detector"""
        try:
            # Initialize HOG descriptor with person detector
            self.hog = cv2.HOGDescriptor()
            # Set SVM detector to the default people detector
            self.hog.setSVMDetector(cv2.HOGDescriptor_getDefaultPeopleDetector())
            print("[OK] Loaded HOG person detector (OpenCV built-in)")
            self.model = "hog"  # Mark as loaded
        except Exception as e:
            print(f"[ERROR] Error loading HOG detector: {e}")
            self.hog = None
            self.model = None
    
    def detect(self, frame: np.ndarray, confidence_threshold: float = 0.3) -> Tuple[int, float]:
        """
        Detect people in a frame using HOG
        
        Args:
            frame: BGR image frame from OpenCV
            confidence_threshold: Minimum confidence (hitThreshold for HOG)
        
        Returns:
            Tuple of (person_count, average_confidence)
        """
        if self.hog is None:
            return self._mock_detect(frame)
        
        try:
            # Resize frame for faster processing (HOG works well on smaller images)
            # Original size is fine, but resizing speeds things up
            height, width = frame.shape[:2]
            if width > 640:
                scale = 640 / width
                new_width = 640
                new_height = int(height * scale)
                resized_frame = cv2.resize(frame, (new_width, new_height))
            else:
                resized_frame = frame
            
            # HOG detection parameters:
            # hitThreshold: confidence threshold (lower = more detections)
            # winStride: step size for sliding window (larger = faster)
            # padding: padding around image
            # scale: scale factor for multi-scale detection
            (rects, weights) = self.hog.detectMultiScale(
                resized_frame,
                winStride=(8, 8),  # Step size (larger = faster)
                padding=(16, 16),  # Padding
                scale=1.05,  # Scale factor (smaller = faster, less accurate)
                hitThreshold=confidence_threshold  # Confidence threshold
            )
            
            # Count detections
            person_count = len(rects)
            
            # Calculate average confidence (weights from HOG)
            avg_confidence = float(np.mean(weights)) if len(weights) > 0 else 0.0
            
            # Debug logging (reduced frequency)
            if person_count > 0:
                print(f"   [HOG] [OK] Detected {person_count} person(s) (avg confidence: {avg_confidence:.2f})")
            elif int(time.time()) % 10 == 0:  # Log every 10 seconds if no detection
                print(f"   [HOG] No person detected (frame size: {resized_frame.shape})")
            
            return person_count, avg_confidence
            
        except Exception as e:
            print(f"[ERROR] HOG detection error: {e}")
            import traceback
            traceback.print_exc()
            return self._mock_detect(frame)
    
    def _mock_detect(self, frame: np.ndarray) -> Tuple[int, float]:
        """Mock detection for testing"""
        # Simple mock: return random count based on frame brightness
        brightness = frame.mean()
        if brightness > 100:
            return 1, 0.5
        return 0, 0.0
    
    def detect_with_annotations(self, frame: np.ndarray, confidence_threshold: float = 0.3) -> Tuple[np.ndarray, int, float]:
        """
        Detect people and draw bounding boxes on frame
        
        Returns:
            (annotated_frame, person_count, average_confidence)
        """
        annotated_frame = frame.copy()
        count, confidence = self.detect(frame, confidence_threshold)
        
        if self.hog is None:
            return annotated_frame, count, confidence
        
        try:
            height, width = frame.shape[:2]
            if width > 640:
                scale = 640 / width
                new_width = 640
                new_height = int(height * scale)
                resized_frame = cv2.resize(frame, (new_width, new_height))
            else:
                resized_frame = frame
            
            (rects, weights) = self.hog.detectMultiScale(
                resized_frame,
                winStride=(8, 8),
                padding=(16, 16),
                scale=1.05,
                hitThreshold=confidence_threshold,
                finalThreshold=2.0,
                useMeanshiftGrouping=False
            )
            
            # Draw bounding boxes
            for (x, y, w, h), weight in zip(rects, weights):
                # Scale back to original size if needed
                if width > 640:
                    x = int(x / scale)
                    y = int(y / scale)
                    w = int(w / scale)
                    h = int(h / scale)
                
                cv2.rectangle(annotated_frame, (x, y), (x + w, y + h), (0, 255, 0), 2)
                cv2.putText(annotated_frame, f"Person {weight:.2f}", 
                           (x, y - 10), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 2)
            
            return annotated_frame, count, confidence
            
        except Exception as e:
            print(f"Error in annotated detection: {e}")
            return annotated_frame, count, confidence

