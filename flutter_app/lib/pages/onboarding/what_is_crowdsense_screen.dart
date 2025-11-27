import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';

class WhatIsCrowdSenseScreen extends StatelessWidget {
  final VoidCallback onNext;
  final VoidCallback onBack;

  const WhatIsCrowdSenseScreen({
    super.key,
    required this.onNext,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: onBack,
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'What is CrowdSense?',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.foreground,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'CrowdSense is an intelligent crowd management solution that uses AI-powered people counting to help organizations monitor, analyze, and optimize queue management in real-time.',
                style: TextStyle(
                  fontSize: 16,
                  color: AppTheme.mutedForeground,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 32),
              _buildFeatureItem(
                icon: Icons.sensors,
                title: 'Real-Time Monitoring',
                description: 'Live people count tracking with instant updates',
              ),
              const SizedBox(height: 16),
              _buildFeatureItem(
                icon: Icons.psychology,
                title: 'AI-Powered Detection',
                description: 'Advanced computer vision for accurate counting',
              ),
              const SizedBox(height: 16),
              _buildFeatureItem(
                icon: Icons.analytics,
                title: 'Smart Analytics',
                description: 'Data-driven insights for better decision making',
              ),
              const SizedBox(height: 16),
              _buildFeatureItem(
                icon: Icons.notifications_active,
                title: 'Instant Alerts',
                description: 'Get notified when congestion levels change',
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: onNext,
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Next'),
                      SizedBox(width: 8),
                      Icon(Icons.arrow_forward, size: 20),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFeatureItem({
    required IconData icon,
    required String title,
    required String description,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: AppTheme.primary, size: 24),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.foreground,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                style: const TextStyle(
                  fontSize: 14,
                  color: AppTheme.mutedForeground,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
