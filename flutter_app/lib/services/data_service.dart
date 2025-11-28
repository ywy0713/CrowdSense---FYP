import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_core/firebase_core.dart';
import '../core/config/firebase_config.dart';

class ZoneData {
  final String id;
  final String name;
  final int peopleCount;
  final int lastUpdated;
  final ZoneThresholds thresholds;
  final String? cameraUrl;
  final String? rtspUrl;
  final double? averageServiceSpeed;

  ZoneData({
    required this.id,
    required this.name,
    required this.peopleCount,
    required this.lastUpdated,
    required this.thresholds,
    this.cameraUrl,
    this.rtspUrl,
    this.averageServiceSpeed,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'peopleCount': peopleCount,
      'lastUpdated': lastUpdated,
      'thresholds': thresholds.toMap(),
      if (cameraUrl != null) 'cameraUrl': cameraUrl,
      if (rtspUrl != null) 'rtspUrl': rtspUrl,
      if (averageServiceSpeed != null) 'averageServiceSpeed': averageServiceSpeed,
    };
  }

  factory ZoneData.fromMap(String id, Map<dynamic, dynamic> map) {
    return ZoneData(
      id: id,
      name: map['name'] ?? '',
      peopleCount: map['peopleCount'] ?? 0,
      lastUpdated: map['lastUpdated'] ?? 0,
      thresholds: ZoneThresholds.fromMap(map['thresholds'] ?? {}),
      cameraUrl: map['cameraUrl'],
      rtspUrl: map['rtspUrl'],
      averageServiceSpeed: map['averageServiceSpeed']?.toDouble(),
    );
  }
}

class ZoneThresholds {
  final int low;
  final int medium;
  final int high;
  final int critical;

  ZoneThresholds({
    required this.low,
    required this.medium,
    required this.high,
    required this.critical,
  });

  Map<String, dynamic> toMap() {
    return {
      'low': low,
      'medium': medium,
      'high': high,
      'critical': critical,
    };
  }

  factory ZoneThresholds.fromMap(Map<dynamic, dynamic> map) {
    return ZoneThresholds(
      low: map['low'] ?? 20,
      medium: map['medium'] ?? 50,
      high: map['high'] ?? 80,
      critical: map['critical'] ?? 120,
    );
  }
}

class CountSnapshot {
  final int timestamp;
  final int count;
  final String zoneId;

  CountSnapshot({
    required this.timestamp,
    required this.count,
    required this.zoneId,
  });

  Map<String, dynamic> toMap() {
    return {
      'timestamp': timestamp,
      'count': count,
      'zoneId': zoneId,
    };
  }

  factory CountSnapshot.fromMap(String zoneId, Map<dynamic, dynamic> map) {
    return CountSnapshot(
      timestamp: map['timestamp'] ?? 0,
      count: map['count'] ?? 0,
      zoneId: zoneId,
    );
  }
}

class AlertLog {
  final String id;
  final String zoneId;
  final String zoneName;
  final int timestamp;
  final int peopleCount;
  final String level; // 'low' | 'medium' | 'high' | 'critical'
  final int waitingTimeMin;
  final String message; // Notification message text
  final String? screenshotUrl;
  final String? screenshotBase64;

  AlertLog({
    required this.id,
    required this.zoneId,
    required this.zoneName,
    required this.timestamp,
    required this.peopleCount,
    required this.level,
    required this.waitingTimeMin,
    required this.message,
    this.screenshotUrl,
    this.screenshotBase64,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'zoneId': zoneId,
      'zoneName': zoneName,
      'timestamp': timestamp,
      'peopleCount': peopleCount,
      'level': level,
      'waitingTimeMin': waitingTimeMin,
      'message': message,
      if (screenshotUrl != null) 'screenshotUrl': screenshotUrl,
      if (screenshotBase64 != null) 'screenshotBase64': screenshotBase64,
    };
  }

  factory AlertLog.fromMap(String id, Map<dynamic, dynamic> map) {
    // Get peopleCount - support both 'peopleCount' and 'count' for backward compatibility
    final peopleCount = map['peopleCount'] ?? map['count'] ?? 0;
    
    // Get waitingTimeMin - if not present, default to 0
    final waitingTimeMin = map['waitingTimeMin'] ?? 0;
    
    // Get message - if not present, generate a default message based on level
    String message = map['message'] ?? '';
    if (message.isEmpty) {
      final level = map['level'] ?? 'threshold';
      final levelText = level == 'critical' ? 'Critical' : (level == 'high' ? 'High' : (level == 'medium' ? 'Medium' : (level == 'low' ? 'Low' : level)));
      message = 'People count has reached $levelText threshold!';
    }
    
    return AlertLog(
      id: id,
      zoneId: map['zoneId'] ?? '',
      zoneName: map['zoneName'] ?? '',
      timestamp: map['timestamp'] ?? 0,
      peopleCount: peopleCount,
      level: map['level'] ?? 'low',
      waitingTimeMin: waitingTimeMin,
      message: message,
      screenshotUrl: map['screenshotUrl'],
      screenshotBase64: map['screenshotBase64'],
    );
  }
}

class DataService {
  static DatabaseReference get _database {
    // Get FirebaseDatabase instance with the correct database URL
    final database = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: FirebaseConfig.databaseURL,
    );
    return database.ref();
  }

  // Zone management
  static Future<ZoneData?> getZone(String zoneId) async {
    try {
      final snapshot = await _database.child('zones/$zoneId').get();
      if (snapshot.exists) {
        return ZoneData.fromMap(zoneId, Map<String, dynamic>.from(snapshot.value as Map));
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  static Future<List<ZoneData>> getUserZones(String userId) async {
    try {
      final snapshot = await _database.child('users/$userId/zones').get();
      if (!snapshot.exists) return [];

      final zoneIds = Map<String, dynamic>.from(snapshot.value as Map).keys.toList();
      final zones = <ZoneData>[];

      for (final zoneId in zoneIds) {
        final zone = await getZone(zoneId);
        if (zone != null) zones.add(zone);
      }

      return zones;
    } catch (e) {
      return [];
    }
  }

  static Future<String> createZone(String userId, Map<String, dynamic> zoneData) async {
    final zonesRef = _database.child('zones');
    final newZoneRef = zonesRef.push();
    final zoneId = newZoneRef.key!;

    final fullZoneData = {
      ...zoneData,
      'id': zoneId,
      'peopleCount': 0,
      'lastUpdated': DateTime.now().millisecondsSinceEpoch,
    };

    await newZoneRef.set(fullZoneData);

    // Link zone to user
    await _database.child('users/$userId/zones/$zoneId').set(true);

    return zoneId;
  }

  static Future<void> updateZone(String zoneId, Map<String, dynamic> updates) async {
    await _database.child('zones/$zoneId').update({
      ...updates,
      'id': zoneId,
    });
  }

  static Future<void> deleteZone(String userId, String zoneId) async {
    try {
      // Delete zone from zones collection
      await _database.child('zones/$zoneId').remove();
      
      // Remove zone reference from user
      await _database.child('users/$userId/zones/$zoneId').remove();
      
      // Delete associated alerts
      await _database.child('alerts/$zoneId').remove();
      
      // Delete associated analytics
      await _database.child('analytics/$zoneId').remove();
    } catch (e) {
      throw Exception('Failed to delete zone: $e');
    }
  }

  // Real-time people count subscription
  static Stream<Map<String, dynamic>?> subscribeToZoneCount(String zoneId) {
    return _database
        .child('zones/$zoneId')
        .onValue
        .map((event) {
      if (event.snapshot.exists) {
        final data = Map<String, dynamic>.from(event.snapshot.value as Map);
        return {
          'count': data['peopleCount'] ?? 0,
          'lastUpdated': data['lastUpdated'] ?? DateTime.now().millisecondsSinceEpoch,
        };
      }
      return null;
    });
  }

  // Subscribe to zone data (count + thresholds)
  static Stream<ZoneData?> subscribeToZone(String zoneId) {
    return _database
        .child('zones/$zoneId')
        .onValue
        .map((event) {
      if (event.snapshot.exists) {
        return ZoneData.fromMap(zoneId, Map<String, dynamic>.from(event.snapshot.value as Map));
      }
      return null;
    });
  }

  // Update people count
  static Future<void> updatePeopleCount(String zoneId, int count) async {
    await _database.child('zones/$zoneId').update({
      'peopleCount': count,
      'lastUpdated': DateTime.now().millisecondsSinceEpoch,
    });

    // Log count for analytics
    await _database.child('analytics/$zoneId/counts').push().set({
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'count': count,
    });
  }

  // Get analytics data
  static Future<List<CountSnapshot>> getAnalyticsData(
    String zoneId,
    int startTime,
    int endTime,
  ) async {
    try {
      final snapshot = await _database.child('analytics/$zoneId/counts').get();
      if (!snapshot.exists) return [];

      final allCounts = Map<String, dynamic>.from(snapshot.value as Map);
      final filtered = <CountSnapshot>[];

      for (final entry in allCounts.entries) {
        final data = Map<String, dynamic>.from(entry.value as Map);
        final timestamp = data['timestamp'] as int? ?? 0;
        if (timestamp >= startTime && timestamp <= endTime) {
          filtered.add(CountSnapshot(
            timestamp: timestamp,
            count: data['count'] ?? 0,
            zoneId: zoneId,
          ));
        }
      }

      filtered.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return filtered;
    } catch (e) {
      return [];
    }
  }

  // Log alert
  static Future<String> logAlert(AlertLog alert) async {
    final alertsRef = _database.child('alerts/${alert.zoneId}');
    final newAlertRef = alertsRef.push();
    final alertId = newAlertRef.key!;

    await newAlertRef.set({
      ...alert.toMap(),
      'id': alertId,
    });

    return alertId;
  }

  // Get alerts
  static Stream<List<AlertLog>> subscribeToAlerts(String zoneId) {
    return _database
        .child('alerts/$zoneId')
        .orderByChild('timestamp')
        .limitToLast(50)
        .onValue
        .map((event) {
      if (!event.snapshot.exists) return [];

      final alerts = Map<String, dynamic>.from(event.snapshot.value as Map);
      return alerts.entries.map((entry) {
        return AlertLog.fromMap(entry.key, Map<String, dynamic>.from(entry.value as Map));
      }).toList()
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    });
  }

  // Mark alert as read
  static Future<void> markAlertAsRead(String zoneId, String alertId) async {
    try {
      await _database.child('alerts/$zoneId/$alertId').update({
        'read': true,
      });
      print('✅ Alert marked as read: zone=$zoneId, alert=$alertId');
    } catch (e) {
      print('⚠️ Failed to mark alert as read: $e');
    }
  }

  // Mark all alerts as read for a zone
  static Future<void> markAllAlertsAsRead(String zoneId) async {
    try {
      final snapshot = await _database.child('alerts/$zoneId').get();
      if (snapshot.exists) {
        final alerts = Map<String, dynamic>.from(snapshot.value as Map);
        final updates = <String, dynamic>{};
        for (var alertId in alerts.keys) {
          updates['alerts/$zoneId/$alertId/read'] = true;
        }
        if (updates.isNotEmpty) {
          await _database.update(updates);
          print('✅ All alerts marked as read for zone: $zoneId (${updates.length} alerts)');
        }
      }
    } catch (e) {
      print('⚠️ Failed to mark all alerts as read: $e');
    }
  }

  // Mark all alerts as read for all zones of a user
  static Future<void> markAllAlertsAsReadForUser(String userId) async {
    try {
      final zones = await getUserZones(userId);
      for (var zone in zones) {
        await markAllAlertsAsRead(zone.id);
      }
      print('✅ All alerts marked as read for user: $userId');
    } catch (e) {
      print('⚠️ Failed to mark all alerts as read for user: $e');
    }
  }

  // Get alerts for a specific time range
  static Future<List<AlertLog>> getAlertsInRange(
    String zoneId,
    int startTime,
    int endTime,
  ) async {
    try {
      final snapshot = await _database.child('alerts/$zoneId').get();
      if (!snapshot.exists) return [];

      final alerts = Map<String, dynamic>.from(snapshot.value as Map);
      final filtered = <AlertLog>[];

      for (final entry in alerts.entries) {
        final alertData = Map<String, dynamic>.from(entry.value as Map);
        final timestamp = alertData['timestamp'] as int? ?? 0;
        if (timestamp >= startTime && timestamp <= endTime) {
          filtered.add(AlertLog.fromMap(entry.key, alertData));
        }
      }

      filtered.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return filtered;
    } catch (e) {
      print('⚠️ Failed to get alerts in range: $e');
      return [];
    }
  }
}
