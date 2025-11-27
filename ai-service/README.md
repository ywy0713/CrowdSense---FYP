# CrowdSense AI Service

Python backend service for real-time people detection using YOLOv8.

## 🚀 Quick Start (All-in-One)

**All Python functionality is now integrated into `main.py`:**

```bash
# Basic: AI service only
cd ai-service
python main.py

# Full: AI service + External camera server
python main.py --enable-external-camera
```

See [QUICK_START.md](QUICK_START.md) for detailed instructions.

## Features

- Real-time people detection from camera streams (RTSP/HTTP)
- Updates Firebase Realtime Database every 2 seconds
- Automatic alert triggering when thresholds are exceeded
- Analytics data logging (every 5 minutes)
- Screenshot capture for alerts

## Setup

### Prerequisites

- Python 3.8+
- Firebase project with Realtime Database enabled
- Firebase Admin SDK service account key

### Installation

```bash
# Install dependencies
pip install -r requirements.txt

# For GPU support (optional, recommended for production)
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu118
```

### Configuration

1. **Get Firebase Service Account Key**
   - Go to Firebase Console → Project Settings → Service Accounts
   - Click "Generate new private key"
   - Save as `serviceAccountKey.json` in `ai-service/` directory

2. **Set Environment Variables**

   ```bash
   export FIREBASE_CREDENTIALS_PATH=serviceAccountKey.json
   export FIREBASE_DATABASE_URL=https://your-project-default-rtdb.firebaseio.com
   ```

   Or create a `.env` file:
   ```
   FIREBASE_CREDENTIALS_PATH=serviceAccountKey.json
   FIREBASE_DATABASE_URL=https://your-project-default-rtdb.firebaseio.com
   ```

### Running the Service

```bash
# Development mode
python main.py

# Production mode (using uvicorn)
uvicorn main:app --host 0.0.0.0 --port 8000
```

## API Endpoints

### `GET /`
Health check endpoint.

### `POST /zones/start`
Start monitoring a zone.

**Request Body:**
```json
{
  "zone_id": "zone123",
  "name": "Main Entrance",
  "camera_url": "rtsp://camera-url",
  "thresholds": {
    "low": 20,
    "medium": 50,
    "high": 80,
    "critical": 120
  },
  "average_service_speed": 1.0
}
```

### `POST /zones/{zone_id}/stop`
Stop monitoring a zone.

### `GET /zones/status`
Get status of all monitored zones.

### `POST /detect`
Perform a single detection (for testing).

## Usage Example

```python
import requests

# Start monitoring a zone
response = requests.post("http://localhost:8000/zones/start", json={
    "zone_id": "zone123",
    "name": "Main Entrance",
    "camera_url": "http://camera-stream-url",
    "thresholds": {"low": 20, "medium": 50, "high": 80, "critical": 120},
    "average_service_speed": 1.0
})

print(response.json())
```

## Model Options

The service uses YOLOv8 (via Ultralytics) which is compatible with YOLOv5:

- `yolov8n.pt` - Nano (fastest, less accurate) - Default
- `yolov8s.pt` - Small (balanced)
- `yolov8m.pt` - Medium (more accurate)
- `yolov8l.pt` - Large (very accurate, slower)

To use a different model, modify `people_detector.py`:

```python
detector = PeopleDetector(model_path="yolov8s.pt")
```

## Mock Mode

If the YOLO model cannot be loaded, the service will automatically fall back to mock detection mode. This is useful for testing without GPU or model files.

## Firebase Integration

The service:
1. Reads zone configurations from Firebase
2. Updates people count every 2 seconds
3. Logs alerts when thresholds are exceeded
4. Logs analytics data every 5 minutes

## Error Handling

- Camera connection errors: Service will retry every 2 seconds
- Model loading errors: Falls back to mock detection
- Firebase errors: Logged to console, monitoring continues

## Deployment

### Docker (Recommended)

```dockerfile
FROM python:3.10-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

### Systemd Service

Create `/etc/systemd/system/crowdsense-ai.service`:

```ini
[Unit]
Description=CrowdSense AI Service
After=network.target

[Service]
Type=simple
User=your-user
WorkingDirectory=/path/to/ai-service
Environment="FIREBASE_CREDENTIALS_PATH=/path/to/serviceAccountKey.json"
Environment="FIREBASE_DATABASE_URL=https://your-project.firebaseio.com"
ExecStart=/usr/bin/python3 main.py
Restart=always

[Install]
WantedBy=multi-user.target
```

## Troubleshooting

### Model Not Loading
- Check if PyTorch is installed correctly
- Verify model file exists
- Service will use mock mode if model fails

### Camera Connection Issues
- Verify camera URL is accessible
- Check network connectivity
- RTSP streams may require authentication

### Firebase Connection Issues
- Verify service account key is valid
- Check database URL is correct
- Ensure Firebase Realtime Database is enabled

## Performance Tips

1. **Use GPU**: Install CUDA-enabled PyTorch for faster inference
2. **Optimize Model**: Use smaller model (yolov8n) for faster detection
3. **Reduce Resolution**: Resize camera frames before detection
4. **Batch Processing**: Process multiple zones in parallel (future enhancement)

## License

Part of CrowdSense FYP project.
