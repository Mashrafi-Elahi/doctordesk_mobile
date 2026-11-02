// notification_service.dart
//
// In-app notifications service managing notifications in Firestore
// and persisting offline/guest notifications locally via SharedPreferences.
// While the app is open (or recently backgrounded) it also shows new docs as
// Android heads-up notifications. True push when the app is closed would need
// FCM, which needs Cloud Functions (Blaze plan).

import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
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
  static const String _permissionAskedKey = 'notification_permission_asked';
  static const String _channelId = 'doctordesk_alerts';
  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static final FlutterLocalNotificationsPlugin _popups =
      FlutterLocalNotificationsPlugin();

  static void Function(AppNotification)? _onPopupTap;
  static StreamSubscription<User?>? _authSub;
  static StreamSubscription<List<AppNotification>>? _popupSub;
  static String? _popupUid;
  static DateTime _popupSince = DateTime.now();
  static final Set<String> _seenIds = {};

  /// Sets up heads-up popups (Android only) and starts following the
  /// signed-in user's notifications. [onTap] runs when a popup is tapped,
  /// including one that launched the app from the tray.
  static Future<void> initPopups({
    required void Function(AppNotification notification) onTap,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _onPopupTap = onTap;
    try {
      await _popups.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_stat_notify'),
        ),
        onDidReceiveNotificationResponse: (response) =>
            _handlePopupTap(response.payload),
      );
      final launch = await _popups.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) {
        final payload = launch!.notificationResponse?.payload;
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _handlePopupTap(payload));
      }
      await _authSub?.cancel();
      _authSub = FirebaseAuth.instance.authStateChanges().listen(_followUser);
    } catch (e) {
      debugPrint('Notification popup init error: $e');
    }
  }

  static void _handlePopupTap(String? payload) {
    if (payload == null || payload.isEmpty) return;
    try {
      final notification = AppNotification.fromJson(
          jsonDecode(payload) as Map<String, dynamic>);
      _onPopupTap?.call(notification);
    } catch (e) {
      debugPrint('Notification popup tap error: $e');
    }
  }

  static Future<void> _followUser(User? user) async {
    final uid = user?.uid;
    if (uid == _popupUid) return;
    await _popupSub?.cancel();
    _popupSub = null;
    _seenIds.clear();
    _popupUid = uid;
    if (uid == null) return;

    unawaited(_requestPermissionOnce());
    // The first snapshot is the backlog: remember it but don't pop it up.
    // The time check also guards against a cache-first snapshot followed by
    // older docs arriving from the server.
    _popupSince = DateTime.now().subtract(const Duration(minutes: 1));
    var primed = false;
    _popupSub = notificationsStream(uid).listen((list) {
      if (!primed) {
        primed = true;
        _seenIds.addAll(list.map((n) => n.id));
        return;
      }
      for (final notification in list) {
        if (!_seenIds.add(notification.id)) continue;
        if (notification.isRead ||
            notification.timestamp.isBefore(_popupSince)) {
          continue;
        }
        unawaited(_showPopup(notification));
      }
    }, onError: (Object e) => debugPrint('Notification popup stream error: $e'));
  }

  static Future<void> _requestPermissionOnce() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_permissionAskedKey) == true) return;
      await prefs.setBool(_permissionAskedKey, true);
      await _popups
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('Notification permission request error: $e');
    }
  }

  static Future<void> _showPopup(AppNotification notification) async {
    try {
      await _popups.show(
        id: notification.id.hashCode & 0x7fffffff,
        title: notification.title,
        body: notification.body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'DoctorDesk alerts',
            channelDescription:
                'Appointments, queue updates, messages and replies',
            importance: Importance.high,
            priority: Priority.high,
            styleInformation: BigTextStyleInformation(notification.body),
          ),
        ),
        payload: jsonEncode(notification.toJson()),
      );
    } catch (e) {
      debugPrint('Notification popup error: $e');
    }
  }

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
