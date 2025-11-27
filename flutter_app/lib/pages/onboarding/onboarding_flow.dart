import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../providers/onboarding_provider.dart';
import 'welcome_screen.dart';
import 'what_is_crowdsense_screen.dart';
import 'why_and_who_screen.dart';
import 'auth_screen.dart';
import 'auth_mode.dart';

class OnboardingFlow extends ConsumerStatefulWidget {
  const OnboardingFlow({super.key});

  @override
  ConsumerState<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends ConsumerState<OnboardingFlow> {
  // Default to login screen (index 3) - welcome screens only shown after successful registration
  int _currentScreen = 3;
  bool _isRegistering = false; // Track if user is in registration flow (not used for initial switch)

  @override
  void initState() {
    super.initState();
    // Wait for Firebase to initialize before checking account status
    _waitForFirebaseAndCheckAccount();
  }

  Future<void> _waitForFirebaseAndCheckAccount() async {
    // Wait for Firebase to be initialized (with timeout)
    int retries = 0;
    const maxRetries = 20; // 2 seconds max wait (20 * 100ms)
    
    while (retries < maxRetries) {
      try {
        // Try to access Firebase app to check if it's initialized
        Firebase.app();
        // If we get here, Firebase is initialized
        break;
      } catch (e) {
        // Firebase not initialized yet, wait and retry
        await Future.delayed(const Duration(milliseconds: 100));
        retries++;
      }
    }
    
    // Now check account status
    if (mounted) {
      await _checkAccountStatus();
    }
  }

  Future<void> _checkAccountStatus() async {
    // Check if user is already logged in (with error handling)
    // But don't auto-redirect - let onboarding flow handle it
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null) {
        // User is logged in, but don't redirect immediately
        // They might be in the middle of onboarding (post-registration welcome screens)
        print('ℹ️ User already logged in: ${currentUser.email}, but staying in onboarding flow');
        // Only redirect if we're on login screen and user is already logged in
        // This handles the case where user returns to app after already completing onboarding
        if (mounted && _currentScreen == 3) {
          // Check if onboarding is already completed
          final onboardingState = ref.read(onboardingProvider).valueOrNull;
          if (onboardingState?.hasCompletedOnboarding == true) {
            print('✅ Onboarding already completed, redirecting to dashboard');
            context.go('/');
            return;
          }
        }
        return;
      }
    } catch (e) {
      // Firebase not ready yet, continue with default flow
      print('⚠️ Firebase Auth not ready yet: $e');
    }

    // User is not logged in, show login screen
    // Always start at login screen (index 3)
    // Welcome screens (0-2) will only be shown after successful registration
    print('ℹ️ No user logged in, showing login screen');
    if (mounted) {
      setState(() {
        _currentScreen = 3; // Login screen
      });
    }
  }

  void _goToNext() {
    if (_currentScreen < 2) {
      // Move to next screen (0->1->2)
      setState(() {
        _currentScreen = _currentScreen + 1;
      });
    } else if (_currentScreen == 2) {
      // On last screen (WhyAndWhoScreen), entering app is handled by onNext callback
      // This should not be called from WhyAndWhoScreen, but handle it just in case
      _handleEnterApp();
    }
  }

  void _goToPrevious() {
    if (_currentScreen > 0) {
      setState(() {
        _currentScreen = _currentScreen - 1;
      });
    }
  }

  // Called when user clicks "Register now" from login screen
  void _startRegistrationFlow() {
    setState(() {
      _isRegistering = true;
      _currentScreen = 3; // Go directly to register screen (AuthScreen in register mode)
    });
  }

  // Called when user clicks back from welcome screens to return to login
  void _returnToLogin() {
    setState(() {
      _isRegistering = false;
      _currentScreen = 3; // Return to login screen
    });
  }

  void _handleLoginComplete() async {
    // Mark camera as linked and complete onboarding, then go to dashboard
    final onboardingNotifier = ref.read(onboardingProvider.notifier);
    await onboardingNotifier.setCameraLinked(true);
    await onboardingNotifier.completeOnboarding();
    if (mounted) {
      context.go('/');
    }
  }

  void _handleRegisterComplete() async {
    // After registration, show welcome screens and guidelines
    // Check if widget is still mounted before calling setState
    if (!mounted) return;
    
    // Set _isRegistering to true so back button works correctly
    setState(() {
      _isRegistering = true;
      _currentScreen = 0; // Show Welcome screen (Get Started)
    });
    
    print('✅ Registration complete, showing welcome screens (screen 0)');
  }

  Future<void> _handleEnterApp() async {
    // Mark camera as linked and complete onboarding, then go to dashboard
    // This is called when user clicks "Enter App" on the last welcome screen
    if (!mounted) return;
    
    final onboardingNotifier = ref.read(onboardingProvider.notifier);
    await onboardingNotifier.setCameraLinked(true);
    await onboardingNotifier.completeOnboarding();
    
    if (mounted) {
      print('✅ Completing onboarding and entering app');
      context.go('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Use IndexedStack instead of PageView to avoid PageController initialization issues
    return IndexedStack(
      index: _currentScreen,
      children: [
        WelcomeScreen(
          onNext: _goToNext,
          onBack: _isRegistering ? _returnToLogin : null,
        ),
        WhatIsCrowdSenseScreen(
          onNext: _goToNext,
          onBack: _goToPrevious,
        ),
        WhyAndWhoScreen(
          onNext: () {
            // Complete onboarding and enter app when user clicks "Enter App"
            _handleEnterApp();
          },
          onBack: _goToPrevious,
        ),
        AuthScreen(
          onLoginComplete: _handleLoginComplete,
          onRegisterComplete: _handleRegisterComplete,
          onBack: _isRegistering ? _returnToLogin : null,
          initialMode: _isRegistering ? AuthMode.register : AuthMode.login,
          onStartRegistration: null, // Don't use callback - switch mode directly in AuthScreen
        ),
      ],
    );
  }
}
