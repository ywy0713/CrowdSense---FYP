import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../theme/app_theme.dart';

class DeviceSharingPage extends StatefulWidget {
  const DeviceSharingPage({super.key});

  @override
  State<DeviceSharingPage> createState() => _DeviceSharingPageState();
}

class _DeviceSharingPageState extends State<DeviceSharingPage> {
  List<ZoneData> _zones = [];
  String? _selectedZoneId;
  bool _isLoading = true;
  String? _sharingCode;
  List<SharedUser> _sharedUsers = [];

  @override
  void initState() {
    super.initState();
    _loadZones();
    _loadSharedUsers();
  }

  Future<void> _loadZones() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final user = AuthService.getCurrentUser();
      if (user != null) {
        final zones = await DataService.getUserZones(user.uid);
        setState(() {
          _zones = zones;
          if (zones.isNotEmpty) {
            _selectedZoneId = zones.first.id;
          }
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _loadSharedUsers() async {
    if (_selectedZoneId == null) return;

    try {
      // TODO: Load shared users from database
      setState(() {
        _sharedUsers = [
          SharedUser(
            id: '1',
            email: 'user1@example.com',
            name: 'John Doe',
            sharedAt: DateTime.now().subtract(const Duration(days: 2)).millisecondsSinceEpoch,
            permission: 'view',
          ),
          SharedUser(
            id: '2',
            email: 'user2@example.com',
            name: 'Jane Smith',
            sharedAt: DateTime.now().subtract(const Duration(days: 5)).millisecondsSinceEpoch,
            permission: 'edit',
          ),
        ];
      });
    } catch (e) {
      print('Error loading shared users: $e');
    }
  }

  void _generateSharingCode() {
    // Generate a random 6-digit code
    final code = (100000 + (DateTime.now().millisecondsSinceEpoch % 900000)).toString();
    setState(() {
      _sharingCode = code;
    });
    // TODO: Save sharing code to database with zone association
  }

  void _copySharingCode() {
    if (_sharingCode != null) {
      Clipboard.setData(ClipboardData(text: _sharingCode!));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sharing code copied to clipboard')),
      );
    }
  }

  void _removeSharedUser(String userId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove User'),
        content: const Text('Are you sure you want to remove this user?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _sharedUsers.removeWhere((user) => user.id == userId);
              });
              Navigator.of(context).pop();
              // TODO: Remove from database
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('User removed successfully')),
              );
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Device Sharing'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _zones.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.share_location, size: 64, color: AppTheme.mutedForeground),
                      const SizedBox(height: 16),
                      Text(
                        'No Zones Available',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.foreground,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Please create zones first',
                        style: TextStyle(color: AppTheme.mutedForeground),
                      ),
                    ],
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Zone selector
                      DropdownButtonFormField<String>(
                        value: _selectedZoneId,
                        decoration: const InputDecoration(
                          labelText: 'Select Zone',
                          border: OutlineInputBorder(),
                        ),
                        items: _zones.map((zone) {
                          return DropdownMenuItem(
                            value: zone.id,
                            child: Text(zone.name),
                          );
                        }).toList(),
                        onChanged: (value) {
                          setState(() {
                            _selectedZoneId = value;
                            _sharingCode = null;
                          });
                          _loadSharedUsers();
                        },
                      ),
                      const SizedBox(height: 24),
                      // Generate sharing code section
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Generate Sharing Code',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 16),
                              if (_sharingCode != null) ...[
                                Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: AppTheme.muted.withValues(alpha: 0.3),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: AppTheme.border),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          _sharingCode!,
                                          style: TextStyle(
                                            fontSize: 24,
                                            fontWeight: FontWeight.bold,
                                            letterSpacing: 4,
                                            color: AppTheme.primary,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.copy),
                                        onPressed: _copySharingCode,
                                        tooltip: 'Copy code',
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'Share this code with others to grant access to this zone.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.mutedForeground,
                                  ),
                                ),
                              ] else
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton.icon(
                                    onPressed: _generateSharingCode,
                                    icon: const Icon(Icons.qr_code),
                                    label: const Text('Generate Sharing Code'),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      // Shared users section
                      const Text(
                        'Shared Users',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _sharedUsers.isEmpty
                          ? Card(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Center(
                                  child: Column(
                                    children: [
                                      Icon(Icons.people_outline, size: 48, color: AppTheme.mutedForeground),
                                      const SizedBox(height: 16),
                                      Text(
                                        'No Shared Users',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: AppTheme.foreground,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        'Users who have access will appear here',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: AppTheme.mutedForeground,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: _sharedUsers.length,
                              itemBuilder: (context, index) {
                                final user = _sharedUsers[index];
                                return Card(
                                  margin: const EdgeInsets.only(bottom: 12),
                                  child: ListTile(
                                    leading: CircleAvatar(
                                      backgroundColor: AppTheme.primary,
                                      child: Text(
                                        user.name[0].toUpperCase(),
                                        style: TextStyle(
                                          color: AppTheme.primaryForeground,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    title: Text(user.name),
                                    subtitle: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(user.email),
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                              decoration: BoxDecoration(
                                                color: AppTheme.muted,
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                user.permission.toUpperCase(),
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.bold,
                                                  color: AppTheme.mutedForeground,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              'Shared ${_formatTime(user.sharedAt)}',
                                              style: TextStyle(
                                                fontSize: 10,
                                                color: AppTheme.mutedForeground,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                    trailing: IconButton(
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: () => _removeSharedUser(user.id),
                                      tooltip: 'Remove user',
                                    ),
                                  ),
                                );
                              },
                            ),
                    ],
                  ),
                ),
    );
  }

  String _formatTime(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays > 0) {
      return '${difference.inDays} day${difference.inDays > 1 ? 's' : ''} ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours} hour${difference.inHours > 1 ? 's' : ''} ago';
    } else {
      return '${difference.inMinutes} minute${difference.inMinutes > 1 ? 's' : ''} ago';
    }
  }
}

class SharedUser {
  final String id;
  final String email;
  final String name;
  final int sharedAt;
  final String permission; // 'view' or 'edit'

  SharedUser({
    required this.id,
    required this.email,
    required this.name,
    required this.sharedAt,
    required this.permission,
  });
}

