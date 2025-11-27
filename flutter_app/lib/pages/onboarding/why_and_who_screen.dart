import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../theme/app_theme.dart';
import '../../providers/onboarding_provider.dart';

class WhyAndWhoScreen extends ConsumerWidget {
  final VoidCallback onNext;
  final VoidCallback onBack;

  const WhyAndWhoScreen({
    super.key,
    required this.onNext,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: onBack,
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Why & Who Uses CrowdSense',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.foreground,
                ),
              ),
              const SizedBox(height: 32),
              _buildSection(
                title: 'Who Can Use CrowdSense',
                items: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      'CrowdSense is perfect for any public space or organization with waiting zones, queues, or crowd areas. Here are some examples:',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppTheme.mutedForeground,
                        height: 1.5,
                      ),
                    ),
                  ),
                  _buildAudienceItem(Icons.shopping_cart, 'Supermarkets & Retail', 'Checkout waiting areas'),
                  _buildAudienceItem(Icons.local_hospital, 'Hospitals & Clinics', 'Patient waiting zones'),
                  _buildAudienceItem(Icons.business, 'Government Offices', 'Service queue areas'),
                  _buildAudienceItem(Icons.school, 'Schools & Universities', 'Cafeteria and event queues'),
                  _buildAudienceItem(Icons.music_note, 'Concert Venues & Events', 'Ticket queues and entry lines'),
                  _buildAudienceItem(Icons.restaurant, 'Restaurants & Cafes', 'Waiting areas and dining queues'),
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'And many more! If you have a space with waiting zones or queues, CrowdSense can help you manage it better.',
                      style: TextStyle(
                        fontSize: 13,
                        fontStyle: FontStyle.italic,
                        color: AppTheme.mutedForeground,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              _buildSection(
                title: 'Why',
                items: [
                  _buildTextItem('Reduce congestion'),
                  _buildTextItem('Predict waiting times'),
                  _buildTextItem('Improve service efficiency'),
                  _buildTextItem('Data-driven staff allocation'),
                ],
              ),
              const SizedBox(height: 32),
              _buildSection(
                title: 'Usage Guidelines',
                items: [
                  _buildTextItem('Install and position camera correctly (monitor waiting zone)'),
                  _buildTextItem('Ensure proper angle and lighting'),
                  _buildTextItem('Connect camera to network'),
                  _buildTextItem('Use dashboard to monitor live count & alerts'),
                ],
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: onNext, // Use onNext callback which will handle entering app
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Enter App'),
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

  Widget _buildSection({required String title, required List<Widget> items}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: AppTheme.foreground,
          ),
        ),
        const SizedBox(height: 16),
        ...items,
      ],
    );
  }

  Widget _buildAudienceItem(IconData icon, String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.primary),
          const SizedBox(width: 12),
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
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 14,
                    color: AppTheme.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextItem(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.check_circle, color: AppTheme.primary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 14,
                color: AppTheme.foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
