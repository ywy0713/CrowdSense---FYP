import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:math';
import '../core/config/firebase_config.dart';

/// Service for managing device sharing functionality
class SharingService {
  static DatabaseReference get _database {
    final database = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: FirebaseConfig.databaseURL,
    );
    return database.ref();
  }

  /// Generate a unique 8-digit sharing code
  static String _generateSharingCode() {
    final random = Random();
    // Generate 8-digit code (10000000 to 99999999)
    final code = (10000000 + random.nextInt(90000000)).toString();
    return code;
  }

  /// Generate and save a sharing code for a zone
  static Future<String?> generateSharingCode({
    required String zoneId,
    required String permission, // 'view' or 'edit'
    int? expiresInDays, // Optional expiration in days
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        print('❌ No user logged in');
        return null;
      }

      // Generate unique code (check for collisions)
      String? code;
      bool isUnique = false;
      int attempts = 0;
      while (!isUnique && attempts < 10) {
        code = _generateSharingCode();
        final snapshot = await _database.child('sharingCodes/$code').get();
        if (!snapshot.exists) {
          isUnique = true;
        } else {
          attempts++;
        }
      }

      if (!isUnique || code == null) {
        print('❌ Failed to generate unique sharing code after 10 attempts');
        return null;
      }

      final codeData = {
        'zoneId': zoneId,
        'ownerId': user.uid,
        'permission': permission,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'isActive': true,
        if (expiresInDays != null)
          'expiresAt': DateTime.now()
              .add(Duration(days: expiresInDays))
              .millisecondsSinceEpoch,
      };

      await _database.child('sharingCodes/$code').set(codeData);
      print('✅ Sharing code generated: $code for zone $zoneId');
      return code;
    } catch (e) {
      print('❌ Error generating sharing code: $e');
      return null;
    }
  }

  /// Get sharing code for a zone (if exists)
  static Future<String?> getSharingCode(String zoneId) async {
    try {
      final snapshot = await _database
          .child('sharingCodes')
          .orderByChild('zoneId')
          .equalTo(zoneId)
          .limitToFirst(1)
          .get();

      if (snapshot.exists && snapshot.value != null) {
        final codes = snapshot.value as Map;
        for (final entry in codes.entries) {
          final codeData = entry.value as Map;
          if (codeData['isActive'] == true) {
            // Check expiration
            if (codeData['expiresAt'] != null) {
              final expiresAt = codeData['expiresAt'] as int;
              if (DateTime.now().millisecondsSinceEpoch > expiresAt) {
                continue; // Code expired
              }
            }
            return entry.key as String;
          }
        }
      }
      return null;
    } catch (e) {
      print('❌ Error getting sharing code: $e');
      return null;
    }
  }

  /// Validate and redeem a sharing code
  static Future<Map<String, dynamic>?> validateSharingCode(String code) async {
    try {
      final snapshot = await _database.child('sharingCodes/$code').get();
      if (!snapshot.exists) {
        return {'valid': false, 'error': 'Invalid sharing code'};
      }

      final codeData = Map<String, dynamic>.from(
        snapshot.value as Map,
      );

      // Check if code is active
      if (codeData['isActive'] != true) {
        return {'valid': false, 'error': 'Sharing code is not active'};
      }

      // Check expiration
      if (codeData['expiresAt'] != null) {
        final expiresAt = codeData['expiresAt'] as int;
        if (DateTime.now().millisecondsSinceEpoch > expiresAt) {
          return {'valid': false, 'error': 'Sharing code has expired'};
        }
      }

      return {
        'valid': true,
        'zoneId': codeData['zoneId'],
        'permission': codeData['permission'] ?? 'view',
        'ownerId': codeData['ownerId'],
      };
    } catch (e) {
      print('❌ Error validating sharing code: $e');
      return {'valid': false, 'error': 'Error validating code: $e'};
    }
  }

  /// Join a zone using a sharing code
  static Future<Map<String, dynamic>> joinZoneWithCode(String code) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        print('❌ No user logged in');
        return {'success': false, 'error': 'No user logged in'};
      }

      // Validate code
      final validation = await validateSharingCode(code);
      if (validation == null || validation['valid'] != true) {
        print('❌ Invalid sharing code: ${validation?['error']}');
        return {'success': false, 'error': validation?['error'] ?? 'Invalid sharing code'};
      }

      final zoneId = validation['zoneId'] as String;
      final ownerId = validation['ownerId'] as String;
      final permission = validation['permission'] as String? ?? 'view';

      // Check if user is trying to join their own zone
      if (ownerId == user.uid) {
        print('❌ User cannot join their own zone');
        return {'success': false, 'error': 'You cannot share a device with yourself'};
      }

      // Check if user is already the owner of this zone
      final userZoneSnapshot = await _database.child('users/${user.uid}/zones/$zoneId').get();
      if (userZoneSnapshot.exists) {
        print('❌ User is already the owner of this zone');
        return {'success': false, 'error': 'You are already the owner of this zone'};
      }

      // Check if user is already a shared user
      final sharedUserSnapshot = await _database.child('zones/$zoneId/sharedUsers/${user.uid}').get();
      if (sharedUserSnapshot.exists) {
        print('ℹ️ User is already a shared user of this zone');
        return {'success': false, 'error': 'You already have access to this zone'};
      }

      // Get user profile
      final userProfile = await _getUserProfile(user.uid);
      final userName = userProfile['displayName'] ?? user.email ?? 'Unknown';
      final userEmail = user.email ?? '';

      // Add user to zone's shared users
      await _database.child('zones/$zoneId/sharedUsers/${user.uid}').set({
        'userId': user.uid,
        'email': userEmail,
        'name': userName,
        'permission': permission,
        'sharedAt': DateTime.now().millisecondsSinceEpoch,
        'sharedBy': ownerId,
      });

      // Add zone to user's shared zones
      await _database.child('users/${user.uid}/sharedZones/$zoneId').set({
        'zoneId': zoneId,
        'permission': permission,
        'sharedAt': DateTime.now().millisecondsSinceEpoch,
      });

      print('✅ User ${user.uid} joined zone $zoneId with permission $permission');
      return {'success': true};
    } catch (e) {
      print('❌ Error joining zone with code: $e');
      return {'success': false, 'error': 'Error joining zone: $e'};
    }
  }

  /// Get shared users for a zone
  static Future<List<SharedUser>> getSharedUsers(String zoneId) async {
    try {
      final snapshot = await _database.child('zones/$zoneId/sharedUsers').get();
      if (!snapshot.exists) {
        return [];
      }

      final users = <SharedUser>[];
      final usersData = snapshot.value as Map;

      for (final entry in usersData.entries) {
        final userData = Map<String, dynamic>.from(entry.value as Map);
        users.add(SharedUser(
          id: userData['userId'] ?? entry.key,
          email: userData['email'] ?? '',
          name: userData['name'] ?? 'Unknown',
          sharedAt: userData['sharedAt'] ?? DateTime.now().millisecondsSinceEpoch,
          permission: userData['permission'] ?? 'view',
        ));
      }

      // Sort by sharedAt (newest first)
      users.sort((a, b) => b.sharedAt.compareTo(a.sharedAt));
      return users;
    } catch (e) {
      print('❌ Error getting shared users: $e');
      return [];
    }
  }

  /// Subscribe to shared users for a zone (real-time updates)
  static Stream<List<SharedUser>> subscribeToSharedUsers(String zoneId) {
    return _database
        .child('zones/$zoneId/sharedUsers')
        .onValue
        .map((event) {
      if (!event.snapshot.exists) {
        return <SharedUser>[];
      }

      final users = <SharedUser>[];
      final usersData = event.snapshot.value as Map?;

      if (usersData != null) {
        for (final entry in usersData.entries) {
          final userData = Map<String, dynamic>.from(entry.value as Map);
          users.add(SharedUser(
            id: userData['userId'] ?? entry.key,
            email: userData['email'] ?? '',
            name: userData['name'] ?? 'Unknown',
            sharedAt: userData['sharedAt'] ?? DateTime.now().millisecondsSinceEpoch,
            permission: userData['permission'] ?? 'view',
          ));
        }
      }

      // Sort by sharedAt (newest first)
      users.sort((a, b) => b.sharedAt.compareTo(a.sharedAt));
      return users;
    });
  }

  /// Remove a shared user from a zone
  static Future<bool> removeSharedUser(String zoneId, String userId) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        print('❌ No user logged in');
        return false;
      }

      // Check if current user is the zone owner
      // Check if zone exists in user's zones list
      final userZoneSnapshot = await _database.child('users/${user.uid}/zones/$zoneId').get();
      if (!userZoneSnapshot.exists) {
        print('❌ Zone not found or user is not the owner');
        return false;
      }

      // Remove from zone's shared users
      await _database.child('zones/$zoneId/sharedUsers/$userId').remove();

      // Remove from user's shared zones
      await _database.child('users/$userId/sharedZones/$zoneId').remove();

      print('✅ Removed shared user $userId from zone $zoneId');
      return true;
    } catch (e) {
      print('❌ Error removing shared user: $e');
      return false;
    }
  }

  /// Revoke/deactivate a sharing code
  static Future<bool> revokeSharingCode(String code) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        print('❌ No user logged in');
        return false;
      }

      final snapshot = await _database.child('sharingCodes/$code').get();
      if (!snapshot.exists) {
        print('❌ Sharing code not found');
        return false;
      }

      final codeData = Map<String, dynamic>.from(snapshot.value as Map);
      if (codeData['ownerId'] != user.uid) {
        print('❌ Only code owner can revoke sharing code');
        return false;
      }

      await _database.child('sharingCodes/$code/isActive').set(false);
      print('✅ Sharing code revoked: $code');
      return true;
    } catch (e) {
      print('❌ Error revoking sharing code: $e');
      return false;
    }
  }

  /// Get zones shared with current user
  static Future<List<String>> getSharedZones() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        return [];
      }

      final snapshot = await _database.child('users/${user.uid}/sharedZones').get();
      if (!snapshot.exists) {
        return [];
      }

      final zones = <String>[];
      final zonesData = snapshot.value as Map;
      for (final entry in zonesData.entries) {
        zones.add(entry.key as String);
      }

      return zones;
    } catch (e) {
      print('❌ Error getting shared zones: $e');
      return [];
    }
  }

  /// Helper: Get user profile
  static Future<Map<String, dynamic>> _getUserProfile(String userId) async {
    try {
      final snapshot = await _database.child('users/$userId/profile').get();
      if (snapshot.exists) {
        return Map<String, dynamic>.from(snapshot.value as Map);
      }
      return {};
    } catch (e) {
      print('⚠️ Error getting user profile: $e');
      return {};
    }
  }
}

/// Shared user model
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

