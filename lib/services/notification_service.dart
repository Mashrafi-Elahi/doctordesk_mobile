// notification_service.dart
//
// In-app notifications service managing notifications in Firestore
// and persisting offline/guest notifications locally via SharedPreferences.

import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppNotification {
  final String id;
  final String userId;
  final String title;
  final String body;
  final String type; // 'comment', 'appointment', 'review', 'system'
  final DateTime timestamp;
  final bool isRead;
  final String? relatedId;
  final DateTime? expiresAt;

  AppNotification({
    required this.id,
    required this.userId,
    required this.title,
    required this.body,
    required this.type,
    required this.timestamp,
    this.isRead = false,
    this.relatedId,
    this.expiresAt,
  });

  factory AppNotification.fromJson(Map<String, dynamic> json, [String? docId]) {
    DateTime parsedTime;
    final rawTime = json['timestamp'];
    if (rawTime is Timestamp) {
      parsedTime = rawTime.toDate();
    } else if (rawTime is String) {
      parsedTime = DateTime.tryParse(rawTime) ?? DateTime.now();
    } else if (rawTime is int) {
      parsedTime = DateTime.fromMillisecondsSinceEpoch(rawTime);
    } else {
      parsedTime = DateTime.now();
    }

    return AppNotification(
      id: docId ?? json['id']?.toString() ?? '',
      userId: json['userId']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Notification',
      body: json['body']?.toString() ?? '',
      type: json['type']?.toString() ?? 'system',
      timestamp: parsedTime,
      isRead: json['isRead'] == true,
      relatedId: json['relatedId']?.toString(),
      expiresAt: _dateFromValue(json['expiresAt']),
    );
  }

  static DateTime? _dateFromValue(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is String) return DateTime.tryParse(value);
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    return null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'userId': userId,
        'title': title,
        'body': body,
        'type': type,
        'timestamp': timestamp.toIso8601String(),
        'isRead': isRead,
        if (relatedId != null) 'relatedId': relatedId,
        if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
      };
}

class NotificationService {
  static const String _prefsKeyPrefix = 'local_notifications_';
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static String get currentUserId =>
      FirebaseAuth.instance.currentUser?.uid ?? 'guest';

  /// Sends a notification to a specific user (or guest)
  static Future<void> createNotification({
    required String userId,
    required String title,
    required String body,
    required String type,
    String? relatedId,
  }) async {
    try {
      final now = DateTime.now();
      final notificationData = {
        'userId': userId,
        'recipientId': userId,
        'title': title,
        'body': body,
        'type': type,
        'isRead': false,
        'relatedId': relatedId,
        'timestamp': FieldValue.serverTimestamp(),
        'expiresAt': Timestamp.fromDate(now.add(const Duration(days: 30))),
      };

      // Also record in Firestore
      if (userId != 'guest') {
        try {
          await _db.collection('notifications').add(notificationData);
        } catch (e) {
          debugPrint('Firestore notification error: $e');
        }
      }

      // Always save to local SharedPreferences so it shows instantly even offline
      await _saveLocalNotification(
        userId: userId,
        notification: AppNotification(
          id: '${userId}_${now.millisecondsSinceEpoch}',
          userId: userId,
          title: title,
          body: body,
          type: type,
          timestamp: now,
          isRead: false,
          relatedId: relatedId,
          expiresAt: now.add(const Duration(days: 30)),
        ),
      );
    } catch (e) {
      debugPrint('Error creating notification: $e');
    }
  }

  /// Real-time stream of notifications for the current user
  static Stream<List<AppNotification>> notificationsStream(String userId) {
    if (userId.isEmpty || userId == 'guest' || _db.app.options.projectId.isEmpty || FirebaseAuth.instance.currentUser == null) {
      return Stream.fromFuture(loadLocalNotifications(userId));
    }

    return _db
        .collection('notifications')
        .where('userId', isEqualTo: userId)
        .limit(50)
        .snapshots()
        .map((snapshot) {
      final now = DateTime.now();
      final firestoreList = snapshot.docs
          .map((doc) => AppNotification.fromJson(doc.data(), doc.id))
          .where((notification) =>
              notification.expiresAt == null || notification.expiresAt!.isAfter(now))
          .toList();
      firestoreList.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return firestoreList;
    }).handleError((e) {
      debugPrint('Notification stream error, falling back to local: $e');
      return loadLocalNotifications(userId);
    });
  }

  /// Load local notifications from SharedPreferences
  static Future<List<AppNotification>> loadLocalNotifications(
      String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_prefsKeyPrefix$userId');
      if (raw == null || raw.isEmpty) return [];
      final List decoded = jsonDecode(raw);
      final list = decoded
          .map((j) => AppNotification.fromJson(j as Map<String, dynamic>))
          .where((notification) =>
              notification.expiresAt == null || notification.expiresAt!.isAfter(DateTime.now()))
          .toList();
      list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return list;
    } catch (e) {
      debugPrint('Error loading local notifications: $e');
      return [];
    }
  }

  static Future<void> _saveLocalNotification({
    required String userId,
    required AppNotification notification,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final current = await loadLocalNotifications(userId);
      current.insert(0, notification);
      if (current.length > 50) current.removeLast();
      await prefs.setString(
        '$_prefsKeyPrefix$userId',
        jsonEncode(current.map((n) => n.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('Error saving local notification: $e');
    }
  }

  /// Marks a notification as read
  static Future<void> markAsRead(String id, String userId) async {
    try {
      if (userId != 'guest') {
        try {
          await _db.collection('notifications').doc(id).update({'isRead': true});
        } catch (_) {}
      }
      final prefs = await SharedPreferences.getInstance();
      final current = await loadLocalNotifications(userId);
      for (var i = 0; i < current.length; i++) {
        if (current[i].id == id) {
          current[i] = AppNotification(
            id: current[i].id,
            userId: current[i].userId,
            title: current[i].title,
            body: current[i].body,
            type: current[i].type,
            timestamp: current[i].timestamp,
            isRead: true,
            relatedId: current[i].relatedId,
            expiresAt: current[i].expiresAt,
          );
        }
      }
      await prefs.setString(
        '$_prefsKeyPrefix$userId',
        jsonEncode(current.map((n) => n.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('Error marking notification as read: $e');
    }
  }

  /// Removes one notification from both the signed-in user's remote list and
  /// the offline mirror. The rules remain the authority for remote deletion.
  static Future<void> deleteNotification(String id, String userId) async {
    try {
      if (userId != 'guest') {
        await _db.collection('notifications').doc(id).delete();
      }
      final prefs = await SharedPreferences.getInstance();
      final current = await loadLocalNotifications(userId);
      current.removeWhere((notification) => notification.id == id);
      await prefs.setString(
        '$_prefsKeyPrefix$userId',
        jsonEncode(current.map((notification) => notification.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('Error deleting notification: $e');
    }
  }

  /// Clears all notifications for user
  static Future<void> clearAll(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_prefsKeyPrefix$userId');

      if (userId != 'guest') {
        final snap = await _db
            .collection('notifications')
            .where('userId', isEqualTo: userId)
            .get();
        final batch = _db.batch();
        for (final doc in snap.docs) {
          batch.delete(doc.reference);
        }
        await batch.commit();
      }
    } catch (e) {
      debugPrint('Error clearing notifications: $e');
    }
  }
}
