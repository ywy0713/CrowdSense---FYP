import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_core/firebase_core.dart';
import '../core/config/firebase_config.dart';

/// Service for managing monitoring status in Firebase
/// This allows the app to work independently without Python service
class FirebaseMonitoringService {
  static DatabaseReference get _database {
    final database = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: FirebaseConfig.databaseURL,
    );
    return database.ref();
  }

  /// Set monitoring status for a zone
  static Future<void> setMonitoringStatus(String zoneId, bool isMonitoring) async {
    try {
      await _database.child('zones/$zoneId').update({
        'isMonitoring': isMonitoring,
        'monitoringStatusUpdated': DateTime.now().millisecondsSinceEpoch,
      });
      print('✅ Updated monitoring status for zone $zoneId: $isMonitoring');
    } catch (e) {
      print('❌ Error updating monitoring status: $e');
      rethrow;
    }
  }

  /// Get monitoring status for a zone
  static Future<bool> getMonitoringStatus(String zoneId) async {
    try {
      final snapshot = await _database.child('zones/$zoneId/isMonitoring').get();
      if (snapshot.exists) {
        return snapshot.value as bool? ?? false;
      }
      return false;
    } catch (e) {
      print('❌ Error getting monitoring status: $e');
      return false;
    }
  }

  /// Subscribe to monitoring status changes
  static Stream<bool> subscribeToMonitoringStatus(String zoneId) {
    return _database
        .child('zones/$zoneId/isMonitoring')
        .onValue
        .map((event) {
      if (event.snapshot.exists) {
        return event.snapshot.value as bool? ?? false;
      }
      return false;
    });
  }

  /// Get all active zones (zones with isMonitoring = true)
  static Future<List<String>> getActiveZones() async {
    try {
      final snapshot = await _database.child('zones').get();
      if (!snapshot.exists) return [];

      final zones = Map<String, dynamic>.from(snapshot.value as Map);
      final activeZones = <String>[];

      for (final entry in zones.entries) {
        final zoneData = Map<String, dynamic>.from(entry.value as Map);
        if (zoneData['isMonitoring'] == true) {
          activeZones.add(entry.key);
        }
      }

      return activeZones;
    } catch (e) {
      print('❌ Error getting active zones: $e');
      return [];
    }
  }

  /// Subscribe to all active zones
  static Stream<List<String>> subscribeToActiveZones() {
    return _database
        .child('zones')
        .onValue
        .map((event) {
      if (!event.snapshot.exists) return <String>[];

      final zones = Map<String, dynamic>.from(event.snapshot.value as Map);
      final activeZones = <String>[];

      for (final entry in zones.entries) {
        final zoneData = Map<String, dynamic>.from(entry.value as Map);
        if (zoneData['isMonitoring'] == true) {
          activeZones.add(entry.key);
        }
      }

      return activeZones;
    });
  }

  /// Update people count and last updated time
  static Future<void> updatePeopleCount(String zoneId, int count, {int? timestamp}) async {
    try {
      final updateData = {
        'peopleCount': count,
        'lastUpdated': timestamp ?? DateTime.now().millisecondsSinceEpoch,
      };
      
      await _database.child('zones/$zoneId').update(updateData);
      
      // Also log to analytics
      await _database.child('analytics/$zoneId/counts').push().set({
        'timestamp': timestamp ?? DateTime.now().millisecondsSinceEpoch,
        'count': count,
      });
      
      print('✅ Updated people count for zone $zoneId: $count');
    } catch (e) {
      print('❌ Error updating people count: $e');
      rethrow;
    }
  }

  /// Get current people count for a zone
  static Future<Map<String, dynamic>?> getZoneCount(String zoneId) async {
    try {
      final snapshot = await _database.child('zones/$zoneId').get();
      if (!snapshot.exists) return null;

      final data = Map<String, dynamic>.from(snapshot.value as Map);
      return {
        'peopleCount': data['peopleCount'] ?? 0,
        'lastUpdated': data['lastUpdated'] ?? DateTime.now().millisecondsSinceEpoch,
        'isMonitoring': data['isMonitoring'] ?? false,
      };
    } catch (e) {
      print('❌ Error getting zone count: $e');
      return null;
    }
  }

  /// Subscribe to zone count changes
  static Stream<Map<String, dynamic>?> subscribeToZoneCount(String zoneId) {
    return _database
        .child('zones/$zoneId')
        .onValue
        .map((event) {
      if (!event.snapshot.exists) return null;

      final data = Map<String, dynamic>.from(event.snapshot.value as Map);
      return {
        'peopleCount': data['peopleCount'] ?? 0,
        'lastUpdated': data['lastUpdated'] ?? DateTime.now().millisecondsSinceEpoch,
        'isMonitoring': data['isMonitoring'] ?? false,
      };
    });
  }
}

