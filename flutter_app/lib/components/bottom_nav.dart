import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';

class BottomNav extends StatelessWidget {
  final int currentIndex;

  const BottomNav({super.key, required this.currentIndex});

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none, // Allow center button to extend beyond bounds
      children: [
        Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 10,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: SafeArea(
            child: Container(
              height: 75,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  // 1. Dashboard
                  _buildNavItem(
                    context: context,
                    icon: Icons.dashboard_outlined,
                    selectedIcon: Icons.dashboard,
                    label: 'Dashboard',
                    index: 0,
                    onTap: () => context.go('/'),
                  ),
                  // 2. Analytics
                  _buildNavItem(
                    context: context,
                    icon: Icons.analytics_outlined,
                    selectedIcon: Icons.analytics,
                    label: 'Analytics',
                    index: 1,
                    onTap: () => context.go('/analytics'),
                  ),
                  // Placeholder for center button (to maintain spacing)
                  Expanded(child: Container()),
                  // 4. Camera Setup
                  _buildNavItem(
                    context: context,
                    icon: Icons.videocam_outlined,
                    selectedIcon: Icons.videocam,
                    label: 'Camera Setup',
                    index: 3,
                    onTap: () => context.go('/camera-setup'),
                  ),
                  // 5. Profile
                  _buildNavItem(
                    context: context,
                    icon: Icons.person_outline,
                    selectedIcon: Icons.person,
                    label: 'Profile',
                    index: 4,
                    onTap: () => context.go('/profile'),
                  ),
                ],
              ),
            ),
          ),
        ),
        // Center button positioned absolutely in the center of navigation bar, protruding upwards
        // Navigation bar height is 75, button should protrude 50px above center
        // Using bottom: 25 to position button so it protrudes 50px above navigation bar center
        Positioned(
          left: 0,
          right: 0,
          bottom:
              25, // Position button so it protrudes 50px above navigation bar center
          child: Center(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                print('🎬 Center button tapped - navigating to /surveillance');
                Future.microtask(() {
                  if (context.mounted) {
                    try {
                      context.go('/surveillance');
                    } catch (e) {
                      print('❌ Navigation error: $e');
                    }
                  }
                });
              },
              child: _buildCenterButtonContent(context),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNavItem({
    required BuildContext context,
    required IconData icon,
    required IconData selectedIcon,
    required String label,
    required int index,
    required VoidCallback onTap,
  }) {
    final isSelected = currentIndex == index;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isSelected ? selectedIcon : icon,
              color: isSelected ? AppTheme.primary : AppTheme.mutedForeground,
              size: 22,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: isSelected ? AppTheme.primary : AppTheme.mutedForeground,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCenterButtonContent(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          print('🎬 InkWell tapped - navigating to /surveillance');
          // Use Future.microtask to ensure navigation happens after current frame
          Future.microtask(() {
            if (context.mounted) {
              try {
                context.go('/surveillance');
              } catch (e) {
                print('❌ Navigation error: $e');
              }
            }
          });
        },
        borderRadius: BorderRadius.circular(32), // Match circle radius
        splashColor: AppTheme.primaryForeground.withValues(alpha: 0.2),
        highlightColor: AppTheme.primaryForeground.withValues(alpha: 0.1),
        child: Container(
          width: 64, // Larger circle size
          height: 64, // Larger circle size
          decoration: BoxDecoration(
            color: AppTheme.primary,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: AppTheme.primary.withValues(alpha: 0.4),
                blurRadius: 16,
                offset: const Offset(0, 6),
                spreadRadius: 2,
              ),
            ],
          ),
          child: Icon(
            Icons.tv, // TV/Monitor icon for video surveillance
            color: AppTheme.primaryForeground,
            size: 32, // Larger icon to match bigger circle
          ),
        ),
      ),
    );
  }
}
