import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';

class WelcomeScreen extends StatelessWidget {
  final VoidCallback onNext;
  final VoidCallback? onBack;

  const WelcomeScreen({super.key, required this.onNext, this.onBack});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: onBack != null
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: onBack,
              ),
            )
          : null,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppTheme.primary.withValues(alpha: 0.05),
              AppTheme.background,
            ],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Spacer(),
                // Logo/Icon
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.people,
                    size: 48,
                    color: AppTheme.primary,
                  ),
                ),
                const SizedBox(height: 32),
                // Title
                const Text(
                  'Welcome to CrowdSense',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.foreground,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                // Description
                Text(
                  'A smart real-time crowd monitoring system to improve queue management and public experience.',
                  style: TextStyle(
                    fontSize: 16,
                    color: AppTheme.mutedForeground,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                const Spacer(),
                // Button
                Builder(
                  builder: (context) {
                    return SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        onPressed: () {
                          debugPrint('🔵 Get Started button pressed');
                          try {
                            onNext();
                          } catch (e, stackTrace) {
                            debugPrint('❌ Error in onNext: $e');
                            debugPrint('Stack trace: $stackTrace');
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: const Text(
                          'Get Started',
                          style: TextStyle(fontSize: 16),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
