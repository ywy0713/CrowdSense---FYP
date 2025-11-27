/// Firebase Configuration for CrowdSense Flutter App
///
/// SETUP INSTRUCTIONS:
/// 1. Go to Firebase Console: https://console.firebase.google.com/
/// 2. Select your CrowdSense project (same one used for React app)
/// 3. Project Settings → Copy the firebaseConfig values
/// 4. Replace the values below with your actual credentials
///
/// Alternative: Use --dart-define flags when running:
/// flutter run --dart-define=FIREBASE_API_KEY=your-key --dart-define=FIREBASE_PROJECT_ID=your-id
class FirebaseConfig {
  // Firebase configuration - should be set from environment or .env file
  // In Flutter, we'll use flutter_dotenv or hardcode for now
  static const String apiKey = String.fromEnvironment(
    'FIREBASE_API_KEY',
    defaultValue: 'AIzaSyAwhj4q6T6adYwEgNwOK90ucw-xPKQz9QU',
  );

  static const String authDomain = String.fromEnvironment(
    'FIREBASE_AUTH_DOMAIN',
    defaultValue: 'crowdsense-caf2e.firebaseapp.com',
  );

  static const String databaseURL = String.fromEnvironment(
    'FIREBASE_DATABASE_URL',
    defaultValue: 'https://crowdsense-caf2e-default-rtdb.asia-southeast1.firebasedatabase.app',
  );

  static const String projectId = String.fromEnvironment(
    'FIREBASE_PROJECT_ID',
    defaultValue: 'crowdsense-caf2e',
  );

  static const String storageBucket = String.fromEnvironment(
    'FIREBASE_STORAGE_BUCKET',
    defaultValue: 'crowdsense-caf2e.firebasestorage.app',
  );

  static const String messagingSenderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
    defaultValue: '934250132493',
  );

  static const String appId = String.fromEnvironment(
    'FIREBASE_APP_ID',
    defaultValue: '1:934250132493:web:5641e7a804b9ceaabdd144',
  );

  static const String measurementId = String.fromEnvironment(
    'FIREBASE_MEASUREMENT_ID',
    defaultValue: 'G-6E5HRMPEWX',
  );

  static const String vapidKey = String.fromEnvironment(
    'FIREBASE_VAPID_KEY',
    defaultValue: '',
  );

  // Initialize from Map (useful for reading from assets or runtime config)
  static Map<String, String> toMap() {
    return {
      'apiKey': apiKey,
      'authDomain': authDomain,
      'databaseURL': databaseURL,
      'projectId': projectId,
      'storageBucket': storageBucket,
      'messagingSenderId': messagingSenderId,
      'appId': appId,
      if (measurementId.isNotEmpty) 'measurementId': measurementId,
    };
  }
}
