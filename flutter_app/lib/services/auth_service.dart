import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import '../core/config/firebase_config.dart';

class UserProfile {
  final String uid;
  final String email;
  final String displayName;
  final String? organization;
  final int createdAt;
  final int updatedAt;

  UserProfile({
    required this.uid,
    required this.email,
    required this.displayName,
    this.organization,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'email': email,
      'displayName': displayName,
      'organization': organization,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
    };
  }

  factory UserProfile.fromMap(Map<String, dynamic> map) {
    return UserProfile(
      uid: map['uid'] ?? '',
      email: map['email'] ?? '',
      displayName: map['displayName'] ?? '',
      organization: map['organization'],
      createdAt: map['createdAt'] ?? 0,
      updatedAt: map['updatedAt'] ?? 0,
    );
  }
}

class ValidationResult {
  final bool valid;
  final Map<String, String> errors;

  ValidationResult({required this.valid, required this.errors});
}

class AuthService {
  // Ensure Firebase is initialized before use
  static Future<void> _ensureFirebaseInitialized() async {
    try {
      // Try to access Firebase app - this will throw if not initialized
      Firebase.app();
    } catch (e) {
      // Firebase not initialized, initialize it now
      print('⏳ Firebase not initialized, initializing now...');
      try {
        await Firebase.initializeApp(
          options: FirebaseOptions(
            apiKey: FirebaseConfig.apiKey,
            appId: FirebaseConfig.appId,
            messagingSenderId: FirebaseConfig.messagingSenderId,
            projectId: FirebaseConfig.projectId,
            authDomain: FirebaseConfig.authDomain,
            databaseURL: FirebaseConfig.databaseURL,
            storageBucket: FirebaseConfig.storageBucket,
          ),
        );
        print('✅ Firebase initialized successfully in AuthService');
      } catch (initError) {
        // Check if error is about duplicate app (can be ignored during hot restart)
        if (initError.toString().contains('duplicate-app') || 
            initError.toString().contains('already exists')) {
          print('ℹ️ Firebase already initialized (hot restart detected)');
        } else {
          print('❌ Firebase initialization failed: $initError');
          throw Exception('Firebase initialization failed. Please check your network connection and configuration.');
        }
      }
    }
  }

  // Lazy initialization to avoid Firebase not initialized errors
  static FirebaseAuth get _auth {
    try {
      // Check if Firebase is initialized first
      Firebase.app();
      return FirebaseAuth.instance;
    } catch (e) {
      // Firebase not initialized - this should not happen if _ensureFirebaseInitialized is called first
      print('⚠️ Firebase Auth accessed before initialization: $e');
      throw Exception('Firebase not initialized. Please wait and try again.');
    }
  }
  
  static FirebaseFirestore get _firestore {
    try {
      // Check if Firebase is initialized first
      Firebase.app();
      return FirebaseFirestore.instance;
    } catch (e) {
      // Firebase not initialized - this should not happen if _ensureFirebaseInitialized is called first
      print('⚠️ Firebase Firestore accessed before initialization: $e');
      throw Exception('Firebase not initialized. Please wait and try again.');
    }
  }

  // Validation helpers
  static ValidationResult _validateEmail(String email) {
    if (email.trim().isEmpty) {
      return ValidationResult(valid: false, errors: {'email': 'Email is required'});
    }
    final emailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
    if (!emailRegex.hasMatch(email)) {
      return ValidationResult(valid: false, errors: {'email': 'Please enter a valid email address'});
    }
    return ValidationResult(valid: true, errors: {});
  }

  static ValidationResult _validatePassword(String password) {
    if (password.isEmpty) {
      return ValidationResult(valid: false, errors: {'password': 'Password is required'});
    }
    if (password.length < 6) {
      return ValidationResult(valid: false, errors: {'password': 'Password must be at least 6 characters'});
    }
    return ValidationResult(valid: true, errors: {});
  }

  static ValidationResult _validateDisplayName(String name) {
    if (name.trim().isEmpty) {
      return ValidationResult(valid: false, errors: {'displayName': 'Name is required'});
    }
    if (name.trim().length < 2) {
      return ValidationResult(valid: false, errors: {'displayName': 'Name must be at least 2 characters'});
    }
    return ValidationResult(valid: true, errors: {});
  }

  // Validate registration inputs
  static ValidationResult validateRegistration(String email, String password, String displayName) {
    final errors = <String, String>{};

    final emailCheck = _validateEmail(email);
    if (!emailCheck.valid) {
      errors.addAll(emailCheck.errors);
    }

    final passwordCheck = _validatePassword(password);
    if (!passwordCheck.valid) {
      errors.addAll(passwordCheck.errors);
    }

    final nameCheck = _validateDisplayName(displayName);
    if (!nameCheck.valid) {
      errors.addAll(nameCheck.errors);
    }

    return ValidationResult(valid: errors.isEmpty, errors: errors);
  }

  // Validate login inputs
  static ValidationResult validateLogin(String email, String password) {
    final errors = <String, String>{};

    final emailCheck = _validateEmail(email);
    if (!emailCheck.valid) {
      errors.addAll(emailCheck.errors);
    }

    if (password.isEmpty) {
      errors['password'] = 'Password is required';
    }

    return ValidationResult(valid: errors.isEmpty, errors: errors);
  }

  // Register user
  static Future<UserCredential> register(
    String email,
    String password,
    String displayName,
    String? organization,
  ) async {
    // Ensure Firebase is initialized first
    await _ensureFirebaseInitialized();
    
    // Validate inputs
    final validation = validateRegistration(email, password, displayName);
    if (!validation.valid) {
      final firstError = validation.errors.values.first;
      throw Exception(firstError);
    }

    UserCredential? userCredential;

    try {
      print('🔵 Creating Firebase Auth user...');
      // Create user
      userCredential = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      print('✅ Firebase Auth user created: ${userCredential.user?.uid}');

      // Update display name
      try {
        await userCredential.user?.updateDisplayName(displayName.trim());
        print('✅ Display name updated');
      } catch (e) {
        print('⚠️ Failed to update display name: $e');
        // Continue even if display name update fails
      }

      // Create user profile in Firestore
      try {
        print('🔵 Creating user profile in Firestore...');
        final profile = UserProfile(
          uid: userCredential.user!.uid,
          email: email.trim(),
          displayName: displayName.trim(),
          organization: organization?.trim(),
          createdAt: DateTime.now().millisecondsSinceEpoch,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        );

        await _firestore.collection('users').doc(userCredential.user!.uid).set(profile.toMap());
        print('✅ User profile created in Firestore');
      } on FirebaseException catch (firestoreError) {
        print('❌ Firestore error: ${firestoreError.code} - ${firestoreError.message}');
        if (firestoreError.code == 'permission-denied') {
          throw Exception('Permission denied. Please check Firestore security rules to ensure users can create their own profiles.');
        } else if (firestoreError.code == 'unavailable') {
          throw Exception('Database unavailable. Please check your network connection.');
        } else {
          throw Exception('Failed to save user profile: ${firestoreError.message ?? firestoreError.code}');
        }
      } catch (e) {
        print('❌ Firestore error: $e');
        throw Exception('Failed to save user profile: $e');
      }

      return userCredential;
    } on FirebaseAuthException catch (e) {
      print('❌ Firebase Auth error: ${e.code} - ${e.message}');
      if (e.code == 'email-already-in-use') {
        throw Exception('This email is already registered. Please use the login function.');
      } else if (e.code == 'invalid-email') {
        throw Exception('Invalid email address format.');
      } else if (e.code == 'weak-password') {
        throw Exception('Password is too weak. Please use a password with at least 6 characters.');
      } else if (e.code == 'network-request-failed') {
        throw Exception('Network error. Please check your network connection.');
      } else if (e.code == 'too-many-requests') {
        throw Exception('Too many requests. Please try again later.');
      } else if (e.code == 'configuration-not-found') {
        throw Exception('Firebase configuration error. Please check: 1) Firebase Console → Authentication → Sign-in method has Email/Password enabled; 2) Firebase configuration is correct.');
      } else if (e.code == 'operation-not-allowed') {
        throw Exception('Email/Password authentication is not enabled. Please enable it in Firebase Console → Authentication → Sign-in method.');
      }
      throw Exception('Registration failed: ${e.code} - ${e.message ?? "Unknown error"}');
    } catch (e) {
      print('❌ Unknown error: $e');
      throw Exception('Registration failed: $e');
    }
  }

  // Login user
  static Future<UserCredential> login(String email, String password) async {
    // Ensure Firebase is initialized first
    await _ensureFirebaseInitialized();
    
    // Validate inputs
    final validation = validateLogin(email, password);
    if (!validation.valid) {
      final firstError = validation.errors.values.first;
      throw Exception(firstError);
    }

    try {
      print('🔵 Attempting to login with email: ${email.trim()}');
      final userCredential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      print('✅ Login successful: ${userCredential.user?.uid}');
      return userCredential;
    } on FirebaseAuthException catch (e) {
      print('❌ Firebase Auth error: ${e.code} - ${e.message}');
      if (e.code == 'user-not-found') {
        throw Exception('No account found with this email. Please check the email address or register first.');
      } else if (e.code == 'wrong-password') {
        throw Exception('Incorrect password. Please try again.');
      } else if (e.code == 'invalid-email') {
        throw Exception('Invalid email address format.');
      } else if (e.code == 'user-disabled') {
        throw Exception('This account has been disabled. Please contact administrator.');
      } else if (e.code == 'too-many-requests') {
        throw Exception('Too many login attempts. Please try again later.');
      } else if (e.code == 'network-request-failed') {
        throw Exception('Network error. Please check your network connection.');
      } else if (e.code == 'invalid-credential') {
        throw Exception('Email or password is incorrect. Please check and try again.');
      } else if (e.code == 'operation-not-allowed') {
        throw Exception('Email/Password authentication is not enabled. Please enable it in Firebase Console → Authentication → Sign-in method.');
      }
      throw Exception('Login failed: ${e.code} - ${e.message ?? "Unknown error"}');
    } catch (e) {
      print('❌ Unknown login error: $e');
      if (e is Exception) {
        rethrow;
      }
      throw Exception('Login failed: $e');
    }
  }

  // Logout user
  static Future<void> logout() async {
    await _auth.signOut();
  }

  // Get current user
  static User? getCurrentUser() {
    return _auth.currentUser;
  }

  // Get user profile
  static Future<UserProfile?> getUserProfile(String uid) async {
    try {
      final doc = await _firestore.collection('users').doc(uid).get();
      if (doc.exists) {
        return UserProfile.fromMap(doc.data()!);
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  // Update user profile
  static Future<void> updateUserProfile(String uid, Map<String, dynamic> updates) async {
    updates['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
    await _firestore.collection('users').doc(uid).update(updates);
  }

  // Auth state stream
  static Stream<User?> get authStateChanges => _auth.authStateChanges();
}
