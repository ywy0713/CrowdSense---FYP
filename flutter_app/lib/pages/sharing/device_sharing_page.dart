import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/auth_service.dart';
import '../../services/data_service.dart';
import '../../services/sharing_service.dart';
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
  StreamSubscription? _sharedUsersSubscription;
  String _selectedPermission = 'view'; // Default permission

  @override
  void initState() {
    super.initState();
    _loadZones();
  }

  @override
  void dispose() {
    _sharedUsersSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadZones() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final user = AuthService.getCurrentUser();
      if (user != null) {
        // Only show owned zones for sharing code generation
        final allZones = await DataService.getUserZones(user.uid);
        final ownedZones = allZones.where((zone) => !zone.isShared).toList();
        setState(() {
          _zones = ownedZones;
          if (ownedZones.isNotEmpty) {
            _selectedZoneId = ownedZones.first.id;
            _loadSharingCode();
            _subscribeToSharedUsers();
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

  Future<void> _loadSharingCode() async {
    if (_selectedZoneId == null) return;
    try {
      final code = await SharingService.getSharingCode(_selectedZoneId!);
      if (mounted) {
      setState(() {
          _sharingCode = code;
      });
      }
    } catch (e) {
      print('Error loading sharing code: $e');
    }
  }

  void _subscribeToSharedUsers() {
    if (_selectedZoneId == null) return;

    // Cancel previous subscription
    _sharedUsersSubscription?.cancel();

    // Subscribe to real-time updates
    _sharedUsersSubscription = SharingService.subscribeToSharedUsers(_selectedZoneId!)
        .listen((users) {
      if (mounted) {
        setState(() {
          _sharedUsers = users;
        });
      }
    }, onError: (error) {
      print('Error subscribing to shared users: $error');
    });
  }

  Future<void> _generateSharingCode() async {
    if (_selectedZoneId == null) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final code = await SharingService.generateSharingCode(
        zoneId: _selectedZoneId!,
        permission: _selectedPermission,
      );

      if (code != null && mounted) {
    setState(() {
      _sharingCode = code;
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sharing code generated successfully'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to generate sharing code'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _copySharingCode() {
    if (_sharingCode != null) {
      Clipboard.setData(ClipboardData(text: _sharingCode!));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sharing code copied to clipboard')),
      );
    }
  }

  Future<void> _removeSharedUser(String userId) async {
    if (_selectedZoneId == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove User'),
        content: const Text('Are you sure you want to remove this user? They will lose access to this zone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final success = await SharingService.removeSharedUser(_selectedZoneId!, userId);
        if (mounted) {
          if (success) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('User removed successfully'),
                backgroundColor: Colors.green,
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Failed to remove user'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  void _showJoinZoneDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => _JoinZoneDialog(),
    );
    
    // If zone was successfully joined, refresh zones list
    if (result == true && mounted) {
      _loadZones();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Camera Device Sharing'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  // Zone selector (only show if user has zones)
                  if (_zones.isNotEmpty) ...[
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
                        _loadSharingCode();
                        _subscribeToSharedUsers();
                        },
                      ),
                      const SizedBox(height: 24),
                    // Generate sharing code section (only show if user has zones)
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
                            // Permission selector
                            DropdownButtonFormField<String>(
                              value: _selectedPermission,
                              decoration: const InputDecoration(
                                labelText: 'Permission Level',
                                border: OutlineInputBorder(),
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'view',
                                  child: Text('View Only'),
                                ),
                                DropdownMenuItem(
                                  value: 'edit',
                                  child: Text('Edit'),
                                ),
                              ],
                              onChanged: (value) {
                                if (value != null) {
                                  setState(() {
                                    _selectedPermission = value;
                                    _sharingCode = null; // Reset code if permission changes
                                  });
                                }
                              },
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
                    // Shared users section (only show if user has zones)
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
                                
                                // Logic to ensure we display a proper name
                                String displayName = user.name;
                                // If name is an email, extract the username part
                                if (displayName.contains('@')) {
                                  displayName = displayName.split('@')[0];
                                  // Capitalize first letter
                                  if (displayName.isNotEmpty) {
                                    displayName = displayName[0].toUpperCase() + displayName.substring(1);
                                  }
                                }
                                
                                return Card(
                                  margin: const EdgeInsets.only(bottom: 12),
                                  child: ListTile(
                                    leading: CircleAvatar(
                                      backgroundColor: AppTheme.primary,
                                      child: Text(
                                        displayName.isNotEmpty ? displayName[0].toUpperCase() : 'U',
                                        style: TextStyle(
                                          color: AppTheme.primaryForeground,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    title: Text(
                                      displayName,
                                      style: const TextStyle(fontWeight: FontWeight.bold),
                                    ),
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
                  // Join zone section (always show, even if no zones)
                  const SizedBox(height: 24),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Join Zone',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: _showJoinZoneDialog,
                              icon: const Icon(Icons.add_circle_outline),
                              label: const Text('Enter Sharing Code'),
                            ),
                          ),
                        ],
                      ),
                    ),
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

/// Dialog for joining a zone with a sharing code
class _JoinZoneDialog extends StatefulWidget {
  @override
  State<_JoinZoneDialog> createState() => _JoinZoneDialogState();
}

class _JoinZoneDialogState extends State<_JoinZoneDialog> {
  final _codeController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _joinZone() async {
    final code = _codeController.text.trim();
    if (code.isEmpty || code.length != 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid 8-digit sharing code'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final result = await SharingService.joinZoneWithCode(code);
      if (mounted) {
        setState(() {
          _isLoading = false;
        });

        if (result['success'] == true) {
          Navigator.of(context).pop(true); // Return true to indicate success
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Successfully joined zone! The zone will appear in your camera list.'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 3),
            ),
          );
        } else {
          final errorMessage = result['error'] ?? 'Invalid or expired sharing code';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(errorMessage),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Join Zone'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Enter the 8-digit sharing code to join a zone:'),
          const SizedBox(height: 16),
          TextField(
            controller: _codeController,
            keyboardType: TextInputType.number,
            maxLength: 8,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              letterSpacing: 4,
            ),
            decoration: InputDecoration(
              hintText: '12345678',
              hintStyle: TextStyle(
                color: Colors.grey.shade400, // Light grey for placeholder
                fontSize: 24,
                fontWeight: FontWeight.bold,
                letterSpacing: 4,
              ),
              border: const OutlineInputBorder(),
              counterText: '',
            ),
            onSubmitted: (_) => _joinZone(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _joinZone,
          child: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Join'),
        ),
      ],
    );
  }
}

