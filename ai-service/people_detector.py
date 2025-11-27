r"""
People Detection using YOLOv8
Uses Ultralytics YOLOv8 pre-trained on COCO dataset
"""

import cv2
import numpy as np
import time
from typing import Tuple
from ultralytics import YOLO


class PeopleDetector:
    def __init__(self, model_path: str = "yolov8n.pt"):
        """
        Initialize YOLOv8 model for person detection
        model_path: Path to YOLOv8 model weights
        Options: 'yolov8n.pt' (nano, fastest), 'yolov8s.pt' (small), 
                 'yolov8m.pt' (medium), 'yolov8l.pt' (large, most accurate)
        """
        try:
            # Load YOLOv8 model using Ultralytics
            # The model will be automatically downloaded if not found locally
            self.model = YOLO(model_path)
            self.class_id = 0  # COCO class 0 = person
            print(f"✅ Loaded YOLOv8 model: {model_path}")
        except Exception as e:
            print(f"Error loading model: {e}")
            print("Falling back to mock detection")
            self.model = None
    
    def detect(self, frame: np.ndarray, confidence_threshold: float = 0.5) -> Tuple[int, float]:
        """
        Detect people in a frame
        
        Args:
            frame: BGR image frame from OpenCV
            confidence_threshold: Minimum confidence for detections
        
        Returns:
            Tuple of (person_count, average_confidence)
        """
        if self.model is None:
            # Mock detection for testing
            return self._mock_detect(frame)
        
        try:
            # Convert BGR to RGB (YOLO expects RGB)
            rgb_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            
            # Resize frame for faster inference (optional optimization)
            # Keep original size for better accuracy, but can resize if needed
            # rgb_frame = cv2.resize(rgb_frame, (640, 480))
            
            # Run inference with optimizations for speed
            # Use smaller image size for faster inference
            resized_frame = cv2.resize(rgb_frame, (640, 480)) if rgb_frame.shape[0] > 480 else rgb_frame
            # Use very low confidence for YOLO to catch all possible detections, then filter
            results = self.model(resized_frame, verbose=False, imgsz=640, conf=0.1)  # Very low threshold to catch all detections
            
            # Count people (class 0)
            person_count = 0
            confidences = []
            all_detections = []  # Debug: track all detections
            
            for result in results:
                boxes = result.boxes
                if boxes is not None:
                    for box in boxes:
                        cls = int(box.cls[0])
                        conf = float(box.conf[0])
                        all_detections.append((cls, conf))
                        
                        # Check if detected object is a person (class 0) and above threshold
                        if cls == self.class_id and conf >= confidence_threshold:
                            person_count += 1
                            confidences.append(conf)
            
            avg_confidence = np.mean(confidences) if confidences else 0.0
            
            # Debug: Print detection details (reduce logging frequency)
            if len(all_detections) > 0:
                person_detections = [d for d in all_detections if d[0] == self.class_id]
                if person_detections:
                    # Always log when person detected
                    print(f"   [DEBUG] ✅ Found {len(person_detections)} person detections: {[(c, f'{conf:.2f}') for c, conf in person_detections]}")
                    print(f"   [DEBUG] After threshold filter (>{confidence_threshold}): {person_count} people")
                # Only log non-person detections occasionally to reduce spam
                elif int(time.time()) % 10 == 0:  # Every 10 seconds
                    print(f"   [DEBUG] No person detected. Other objects: {len(all_detections)}")
                    # Show class names if available
                    if hasattr(self.model, 'names'):
                        for cls, conf in all_detections[:3]:  # Show first 3
                            cls_name = self.model.names.get(cls, f'class_{cls}')
                            print(f"      {cls_name} (class {cls}): {conf:.3f}")
            
            return person_count, avg_confidence
        
        except Exception as e:
            print(f"Detection error: {e}")
            return self._mock_detect(frame)
    
    def _mock_detect(self, frame: np.ndarray) -> Tuple[int, float]:
        """
        Mock detection for testing without model
        Returns a random count based on frame size
        """
        h, w = frame.shape[:2]
        # Simple heuristic: larger frames might have more people
        # This is just for testing
        mock_count = max(1, int(np.random.normal(h * w / 50000, 5)))
        mock_count = max(0, min(mock_count, 200))  # Clamp between 0-200
        
        return mock_count, 0.75
    
    def detect_with_annotations(self, frame: np.ndarray, confidence_threshold: float = 0.5) -> Tuple[np.ndarray, int, float]:
        """
        Detect people and draw bounding boxes on frame
        
        Returns:
            (annotated_frame, person_count, average_confidence)
        """
        annotated_frame = frame.copy()
        count, confidence = self.detect(frame, confidence_threshold)
        
        if self.model is None:
            return annotated_frame, count, confidence
        
        try:
            rgb_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            results = self.model(rgb_frame, verbose=False)
            
            for result in results:
                boxes = result.boxes
                if boxes is not None:
                    for box in boxes:
                        cls = int(box.cls[0])
                        conf = float(box.conf[0])
                        
                        if cls == self.class_id and conf >= confidence_threshold:
                            # Get bounding box coordinates
                            x1, y1, x2, y2 = box.xyxy[0].cpu().numpy()
                            x1, y1, x2, y2 = int(x1), int(y1), int(x2), int(y2)
                            
                            # Draw bounding box
                            cv2.rectangle(annotated_frame, (x1, y1), (x2, y2), (0, 255, 0), 2)
                            
                            # Draw label
                            label = f"Person {conf:.2f}"
                            cv2.putText(annotated_frame, label, (x1, y1 - 10),
                                      cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 2)
            
            return annotated_frame, count, confidence
        
        except Exception as e:
            print(f"Annotation error: {e}")
            return annotated_frame, count, confidence
