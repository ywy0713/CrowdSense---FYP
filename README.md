# CrowdSense - Intelligent Crowd Monitoring System

## Overview
CrowdSense is a comprehensive crowd monitoring solution that uses computer vision to detect and count people in real-time. It consists of a Flutter mobile application for monitoring and management, and a Python-based AI service for processing video feeds.

## Features
- **Real-time People Counting**: Accurate detection using YOLOv8/HOG models.
- **Multiple Camera Support**: 
  - **Local Camera**: Use the smartphone's built-in camera.
  - **HTTP Camera**: Stream from external cameras via HTTP (MJPEG).
- **Device Sharing**: Share camera access with other users via 8-digit codes with View/Edit permissions.
- **Zone Management**: Create and configure multiple monitoring zones with custom thresholds.
- **Smart Alerts**: Receive notifications when crowd density exceeds defined thresholds (Low, Medium, High, Critical).
- **Analytics**: View historical data and trends for crowd activity.

## Project Structure
- `flutter_app/`: The mobile application built with Flutter.
- `ai-service/`: The backend service built with Python and FastAPI.

## Setup Instructions

### Prerequisites
- Flutter SDK (Latest Stable)
- Python 3.8+
- Android Studio / Xcode (for mobile app)
- Firebase Account

### Firebase Configuration
1. Create a Firebase project.
2. Enable **Authentication** (Email/Password).
3. Enable **Realtime Database**.
4. Set the following **Security Rules** in Realtime Database:

```json
{
  "rules": {
    "users": {
      "$uid": {
        ".read": "auth != null && auth.uid == $uid",
        ".write": "auth != null && auth.uid == $uid"
      }
    },
    "zones": {
      "$zoneId": {
        ".read": "auth != null && (root.child('users').child(auth.uid).child('zones').child($zoneId).exists() || root.child('zones').child($zoneId).child('sharedUsers').child(auth.uid).exists())",
        ".write": "auth != null && (root.child('users').child(auth.uid).child('zones').child($zoneId).exists() || (root.child('zones').child($zoneId).child('sharedUsers').child(auth.uid).exists() && root.child('zones').child($zoneId).child('sharedUsers').child(auth.uid).child('permission').val() == 'edit'))",
        "sharedUsers": {
             ".write": "auth != null && root.child('users').child(auth.uid).child('zones').child($zoneId).exists()"
        }
      }
    },
    "sharingCodes": {
      ".read": "auth != null",
      "$code": {
         ".write": "auth != null && (!data.exists() || root.child('users').child(auth.uid).child('zones').child(newData.child('zoneId').val()).exists())"
      }
    },
    "alerts": {
      "$zoneId": {
        ".read": "auth != null && (root.child('users').child(auth.uid).child('zones').child($zoneId).exists() || root.child('zones').child($zoneId).child('sharedUsers').child(auth.uid).exists())",
        ".write": "auth != null && (root.child('users').child(auth.uid).child('zones').child($zoneId).exists() || root.child('zones').child($zoneId).child('sharedUsers').child(auth.uid).child('permission').val() == 'edit')"
      }
    },
    "analytics": {
      "$zoneId": {
        ".read": "auth != null && (root.child('users').child(auth.uid).child('zones').child($zoneId).exists() || root.child('zones').child($zoneId).child('sharedUsers').child(auth.uid).exists())",
        ".write": "auth != null && (root.child('users').child(auth.uid).child('zones').child($zoneId).exists() || root.child('zones').child($zoneId).child('sharedUsers').child(auth.uid).child('permission').val() == 'edit')"
      }
    }
  }
}
```

### Running the App
1. **Python AI Service**:
   ```bash
   cd ai-service
   pip install -r requirements.txt
   python main.py
   ```
   
2. **Flutter App**:
   ```bash
   cd flutter_app
   flutter pub get
   flutter run
   ```

## Development Notes
- **HTTP Mode**: Ensure the Python service and the mobile device are on the same network. The app will automatically try to connect to the Python service.
- **Permissions**: The app requires Camera and Microphone permissions.
- **Device Sharing**: To share a device, go to **Profile > Camera Device Sharing**, select a zone, and generate a code. The other user enters this code to gain access.

