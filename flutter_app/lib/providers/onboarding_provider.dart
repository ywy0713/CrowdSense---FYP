import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OnboardingState {
  final bool hasCompletedOnboarding;
  final bool hasLinkedCamera;
  final int currentStep;

  OnboardingState({
    required this.hasCompletedOnboarding,
    required this.hasLinkedCamera,
    required this.currentStep,
  });

  OnboardingState copyWith({
    bool? hasCompletedOnboarding,
    bool? hasLinkedCamera,
    int? currentStep,
  }) {
    return OnboardingState(
      hasCompletedOnboarding: hasCompletedOnboarding ?? this.hasCompletedOnboarding,
      hasLinkedCamera: hasLinkedCamera ?? this.hasLinkedCamera,
      currentStep: currentStep ?? this.currentStep,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'hasCompletedOnboarding': hasCompletedOnboarding,
      'hasLinkedCamera': hasLinkedCamera,
      'currentStep': currentStep,
    };
  }

  factory OnboardingState.fromMap(Map<String, dynamic> map) {
    return OnboardingState(
      hasCompletedOnboarding: map['hasCompletedOnboarding'] ?? false,
      hasLinkedCamera: map['hasLinkedCamera'] ?? false,
      currentStep: map['currentStep'] ?? 0,
    );
  }
}

class OnboardingNotifier extends StateNotifier<AsyncValue<OnboardingState>> {
  FirebaseFirestore? _firestore;
  FirebaseAuth? _auth;
  static const String _storageKey = 'crowdsense.onboarding';
  
  // Lazy getter for FirebaseAuth to ensure Firebase is initialized
  FirebaseAuth get auth {
    if (_auth == null) {
      try {
        // Check if Firebase is initialized
        Firebase.app();
        _auth = FirebaseAuth.instance;
      } catch (e) {
        print('⚠️ Firebase not initialized when accessing Auth: $e');
        // Try to get instance anyway - will throw if not initialized
        _auth = FirebaseAuth.instance;
      }
    }
    return _auth!;
  }
  
  // Lazy getter for Firestore to ensure Firebase is initialized
  FirebaseFirestore get firestore {
    if (_firestore == null) {
      try {
        // Check if Firebase is initialized
        Firebase.app();
        _firestore = FirebaseFirestore.instance;
      } catch (e) {
        print('⚠️ Firebase not initialized when accessing Firestore: $e');
        // Return a dummy instance - operations will fail gracefully
        _firestore = FirebaseFirestore.instance;
      }
    }
    return _firestore!;
  }
  static OnboardingState get _defaultState => OnboardingState(
    hasCompletedOnboarding: false,
    hasLinkedCamera: false,
    currentStep: 0,
  );

  OnboardingNotifier() : super(AsyncValue.data(_defaultState)) {
    // Load state asynchronously to avoid blocking main thread
    // Wait for Firebase to be ready before accessing auth
    Future.microtask(() async {
      // Wait for Firebase to initialize (with timeout)
      int retries = 0;
      const maxRetries = 50; // 5 seconds max wait
      bool firebaseReady = false;
      
      while (retries < maxRetries) {
        try {
          Firebase.app();
          firebaseReady = true;
          break; // Firebase is initialized
        } catch (e) {
          await Future.delayed(const Duration(milliseconds: 100));
          retries++;
        }
      }
      
      // Load state (will use SharedPreferences if Firebase not ready)
      _loadState();
      
      // Set up auth listener only if Firebase is ready
      if (firebaseReady) {
        try {
          auth.authStateChanges().listen((user) {
            _loadState();
          });
        } catch (e) {
          print('⚠️ Failed to set up auth state listener: $e');
        }
      } else {
        print('⚠️ Firebase not ready, skipping auth state listener setup');
      }
    });
  }

  Future<void> _loadState() async {
    state = const AsyncValue.loading();

    try {
      // Ensure Firebase is initialized before accessing auth
      try {
        Firebase.app();
      } catch (e) {
        print('⚠️ Firebase not initialized, using SharedPreferences fallback');
        // Use SharedPreferences fallback
        final prefs = await SharedPreferences.getInstance();
        final stored = prefs.getString(_storageKey);
        if (stored != null) {
          state = AsyncValue.data(OnboardingState.fromMap(
            Map<String, dynamic>.from(
              Uri.splitQueryString(stored.replaceAll('{', '').replaceAll('}', ''))
            ),
          ));
        } else {
          state = AsyncValue.data(_defaultState);
        }
        return;
      }
      
      final user = auth.currentUser;
      OnboardingState onboardingState;

      if (user == null) {
        // No user, check SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        final stored = prefs.getString(_storageKey);
        if (stored != null) {
          onboardingState = OnboardingState.fromMap(
            Map<String, dynamic>.from(
              Uri.splitQueryString(stored.replaceAll('{', '').replaceAll('}', ''))
            ),
          );
        } else {
          onboardingState = _defaultState;
        }
      } else {
        // Try to load from Firestore
        try {
          // Ensure Firebase is initialized before accessing Firestore
          try {
            Firebase.app();
          } catch (e) {
            print('⚠️ Firebase not initialized, using SharedPreferences fallback');
            throw Exception('Firebase not initialized');
          }
          
          final userDoc = await firestore.collection('users').doc(user.uid).get();
          if (userDoc.exists && userDoc.data() != null) {
            final data = userDoc.data()!;
            onboardingState = OnboardingState(
              hasCompletedOnboarding: data['hasCompletedOnboarding'] ?? false,
              hasLinkedCamera: data['hasLinkedCamera'] ?? false,
              currentStep: data['onboardingStep'] ?? 0,
            );
            // Sync to SharedPreferences
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString(_storageKey, onboardingState.toMap().toString());
          } else {
            onboardingState = _defaultState;
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString(_storageKey, onboardingState.toMap().toString());
          }
        } catch (e) {
          // Fallback to SharedPreferences
          final prefs = await SharedPreferences.getInstance();
          final stored = prefs.getString(_storageKey);
          if (stored != null) {
            onboardingState = OnboardingState.fromMap(
              Map<String, dynamic>.from(
                Uri.splitQueryString(stored.replaceAll('{', '').replaceAll('}', ''))
              ),
            );
          } else {
            onboardingState = _defaultState;
          }
        }
      }

      state = AsyncValue.data(onboardingState);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> completeOnboarding() async {
    final currentState = state.valueOrNull;
    if (currentState == null) return;

    final newState = currentState.copyWith(hasCompletedOnboarding: true);
    await _saveState(newState);
    state = AsyncValue.data(newState);
  }

  Future<void> setCameraLinked(bool linked) async {
    final currentState = state.valueOrNull;
    if (currentState == null) return;

    final newState = currentState.copyWith(hasLinkedCamera: linked);
    await _saveState(newState);
    state = AsyncValue.data(newState);
  }

  void setCurrentStep(int step) {
    final currentState = state.valueOrNull;
    if (currentState == null) return;

    final newState = currentState.copyWith(currentStep: step);
    state = AsyncValue.data(newState);
  }

  Future<void> resetOnboarding() async {
    await _saveState(_defaultState);
    state = AsyncValue.data(_defaultState);
  }

  Future<void> _saveState(OnboardingState onboardingState) async {
    // Ensure Firebase is initialized before accessing auth
    try {
      Firebase.app();
    } catch (e) {
      print('⚠️ Firebase not initialized, saving to SharedPreferences only');
      // Just save to SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, onboardingState.toMap().toString());
      return;
    }
    
    final user = auth.currentUser;
    final prefs = await SharedPreferences.getInstance();

    // Save to SharedPreferences
    await prefs.setString(_storageKey, onboardingState.toMap().toString());

    // Save to Firestore if user is logged in
    if (user != null) {
      try {
        // Ensure Firebase is initialized before accessing Firestore
        try {
          Firebase.app();
        } catch (e) {
          print('⚠️ Firebase not initialized, skipping Firestore save');
          return; // Just save to SharedPreferences
        }
        
        await firestore.collection('users').doc(user.uid).update({
          'hasCompletedOnboarding': onboardingState.hasCompletedOnboarding,
          'hasLinkedCamera': onboardingState.hasLinkedCamera,
          'onboardingStep': onboardingState.currentStep,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        });
      } catch (e) {
        // If update fails, create the document
        try {
          await firestore.collection('users').doc(user.uid).set({
          'hasCompletedOnboarding': onboardingState.hasCompletedOnboarding,
          'hasLinkedCamera': onboardingState.hasLinkedCamera,
          'onboardingStep': onboardingState.currentStep,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        }, SetOptions(merge: true));
        } catch (e2) {
          print('⚠️ Failed to save onboarding state to Firestore: $e2');
          // Continue - at least we saved to SharedPreferences
        }
      }
    }
  }
}

final onboardingProvider = StateNotifierProvider<OnboardingNotifier, AsyncValue<OnboardingState>>((ref) {
  return OnboardingNotifier();
});
