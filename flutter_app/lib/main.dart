import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import 'theme/app_theme.dart';
import 'core/config/firebase_config.dart';
import 'pages/onboarding/onboarding_flow.dart';
import 'pages/dashboard/dashboard_page.dart';
import 'pages/analytics/analytics_page.dart';
import 'pages/notifications/notifications_page.dart';
import 'pages/profile/profile_page.dart';
import 'pages/surveillance/video_surveillance_page.dart';
import 'pages/camera/camera_list_page.dart';
import 'providers/onboarding_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize Firebase asynchronously to avoid blocking UI
  unawaited(_initializeFirebase());
  
  // Start app immediately, don't wait for Firebase
  runApp(const ProviderScope(child: CrowdSenseApp()));
}

Future<void> _initializeFirebase() async {
  try {
    // Check if Firebase is already initialized
    try {
      Firebase.app(); // This will throw if Firebase is not initialized
      print('✅ Firebase already initialized');
    } catch (e) {
      // Firebase is not initialized, initialize it now
      print('🔵 Initializing Firebase...');
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
      print('✅ Firebase initialized successfully');
    }
  } catch (e) {
    // Check if error is about duplicate app (can be ignored during hot restart)
    if (e.toString().contains('duplicate-app') || e.toString().contains('already exists')) {
      print('ℹ️ Firebase already initialized (hot restart detected)');
    } else {
      print('❌ Firebase initialization failed: $e');
    }
  }
}

// Helper function to avoid await warning
void unawaited(Future<void> future) {
  future.catchError((error) {
    // Silently handle errors
  });
}

class CrowdSenseApp extends ConsumerWidget {
  const CrowdSenseApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = _createRouter(ref);

    return MaterialApp.router(
      title: 'CrowdSense',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }

  GoRouter _createRouter(WidgetRef ref) {
    return GoRouter(
      initialLocation: '/onboarding',
      routes: [
        GoRoute(
          path: '/onboarding',
          builder: (BuildContext context, GoRouterState state) {
            return const OnboardingFlow();
          },
        ),
        GoRoute(
          path: '/',
          builder: (BuildContext context, GoRouterState state) {
            return const DashboardPage();
          },
        ),
        GoRoute(
          path: '/analytics',
          builder: (BuildContext context, GoRouterState state) {
            return const AnalyticsPage();
          },
        ),
        GoRoute(
          path: '/surveillance',
          builder: (BuildContext context, GoRouterState state) {
            return const VideoSurveillancePage();
          },
        ),
        GoRoute(
          path: '/camera-setup',
          builder: (BuildContext context, GoRouterState state) {
            return const CameraListPage();
          },
        ),
        GoRoute(
          path: '/notifications',
          builder: (BuildContext context, GoRouterState state) {
            return const NotificationsPage();
          },
        ),
        GoRoute(
          path: '/profile',
          builder: (BuildContext context, GoRouterState state) {
            return const ProfilePage();
          },
        ),
      ],
      redirect: (context, state) {
        // Simplified redirect logic - only check Firebase Auth
        // Allow onboarding flow to complete even if user is logged in (for post-registration welcome screens)
        try {
          final currentUser = FirebaseAuth.instance.currentUser;
          // Don't redirect from onboarding if user just registered - let them see welcome screens
          // Only redirect if user is not logged in and trying to access dashboard
          if (currentUser == null && state.uri.path == '/') {
            return '/onboarding';
          }
        } catch (e) {
          // Firebase might not be ready yet, allow navigation
        }
        return null;
      },
      refreshListenable: _OnboardingNotifierListenable(ref),
    );
  }
}

class _OnboardingNotifierListenable extends ChangeNotifier {
  final WidgetRef ref;

  _OnboardingNotifierListenable(this.ref) {
    ref.listen(onboardingProvider, (previous, next) {
      notifyListeners();
    });
  }
}
