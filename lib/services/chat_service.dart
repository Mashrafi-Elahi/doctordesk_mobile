import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image/image.dart' as img;
import '../models/chat_message.dart';
import 'notification_service.dart';

class ChatService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Inline chat images live in Firestore (no Cloud Storage on the free
  /// plan). Must stay under the 1 MiB document limit; firestore.rules
  /// enforces the same cap.
  static const maxInlineImageBytes = 700 * 1024;

  /// Longest side at most 1024 px, JPEG, stepping quality and size down until
  /// it fits [maxInlineImageBytes]. Runs off the UI isolate.
  static Future<Uint8List> compressForChat(Uint8List input) => compute(_compressForChat, input);

  static Uint8List _compressForChat(Uint8List input) {
    final decoded = img.decodeImage(input);
    if (decoded == null) throw StateError('This file is not a readable image.');
    final upright = img.bakeOrientation(decoded);
    for (final side in const [1024, 800, 640]) {
      final resized = upright.width <= side && upright.height <= side
          ? upright
          : (upright.width >= upright.height
              ? img.copyResize(upright, width: side)
              : img.copyResize(upright, height: side));
      for (final quality in const [70, 55, 40]) {
        final out = img.encodeJpg(resized, quality: quality);
        if (out.length <= maxInlineImageBytes) return out;
      }
    }
    throw StateError('This photo is too detailed to send. Try a closer, cropped photo.');
  }

  static final Map<String, Uint8List> _inlineCache = {};

  /// Bytes of an inline image attachment, cached for the session. Null when
  /// it was revoked or is not readable.
  static Future<Uint8List?> loadInlineImage(String chatId, String attachmentId) async {
    final key = '$chatId/$attachmentId';
    final cached = _inlineCache[key];
    if (cached != null) return cached;
    final snap = await _db.collection('chats').doc(chatId).collection('attachments').doc(attachmentId).get();
    final blob = snap.data()?['bytes'];
    if (blob is! Blob) return null;
    if (_inlineCache.length >= 40) _inlineCache.remove(_inlineCache.keys.first);
    return _inlineCache[key] = blob.bytes;
  }

  static String generateChatId(String uid1, String uid2) {
    return uid1.compareTo(uid2) < 0 ? '${uid1}_$uid2' : '${uid2}_$uid1';
  }

  /// Unlocks follow-up chat session for a patient and doctor following care.
  static Future<String> unlockChatForCare({
    required String doctorUid,
    required String patientUid,
    required String doctorName,
    required String patientName,
    String? doctorId,
    required String unlockedBy,
    String? chamberId,
    int followupDays = 7,
    int followupMaxMessages = 20,
  }) async {
    final chatId = generateChatId(patientUid, doctorUid);
    final chatRef = _db.collection('chats').doc(chatId);
    final expiresAt = DateTime.now().add(Duration(days: followupDays));

    await chatRef.set({
      'participants': [patientUid, doctorUid],
      'participantRoles': {
        patientUid: 'Patient',
        doctorUid: 'Doctor',
      },
      'participantNames': {
        patientUid: patientName,
        doctorUid: doctorName,
      },
      'doctorUid': doctorUid,
      'patientUid': patientUid,
      'doctorName': doctorName,
      'patientName': patientName,
      if (doctorId != null) 'doctorId': doctorId,
      'status': 'active',
      'expiresAt': Timestamp.fromDate(expiresAt),
      'messageLimit': followupMaxMessages,
      'messageCount': 0,
      'unlockedBy': unlockedBy,
      // Lets the rules check an operator is assigned to this doctor's chamber.
      if (chamberId != null && chamberId.isNotEmpty) 'unlockChamberId': chamberId,
      'lastMessage': 'Consultation completed. Follow-up chat unlocked for $followupDays days.',
      'unlockedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    try {
      await NotificationService.createNotification(
        userId: patientUid,
        title: 'Follow-up Chat Unlocked 💬',
        body: '${doctorName.toLowerCase().startsWith('dr') ? doctorName : 'Dr. $doctorName'} '
            'has unlocked follow-up chat for $followupDays days.',
        type: 'chat_unlock',
        relatedId: chatId,
      );
    } catch (_) {}

    return chatId;
  }

  /// Backward-compatible alias
  static Future<String> getOrCreateChat({
    required String doctorUid,
    required String patientUid,
    required String doctorName,
    required String patientName,
    String? doctorId,
    String? unlockedBy,
    int followupDays = 7,
    int followupMaxMessages = 20,
  }) async {
    return unlockChatForCare(
      doctorUid: doctorUid,
      patientUid: patientUid,
      doctorName: doctorName,
      patientName: patientName,
      doctorId: doctorId,
      unlockedBy: unlockedBy ?? 'consultation',
      followupDays: followupDays,
      followupMaxMessages: followupMaxMessages,
    );
  }

  static Future<ChatSession?> getUnlockedChatForDoctorAndPatient({
    required String doctorUid,
    required String patientUid,
  }) async {
    final chatId = generateChatId(patientUid, doctorUid);
    final snap = await _db.collection('chats').doc(chatId).get();
    if (!snap.exists) return null;
    final session = ChatSession.fromFirestore(snap);
    if (session.status == 'active' && !session.isExpired) {
      return session;
    }
    return null;
  }

  /// Closes an active chat early (Doctor or Operator only).
  static Future<void> closeChat(String chatId) async {
    await _db.collection('chats').doc(chatId).update({
      'status': 'closed',
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  static Stream<ChatSession?> streamChatSession(String chatId) {
    return _db.collection('chats').doc(chatId).snapshots().map((snap) {
      if (!snap.exists) return null;
      return ChatSession.fromFirestore(snap);
    });
  }

  static Stream<List<ChatMessage>> streamMessages(String chatId) {
    return _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs.map((d) => ChatMessage.fromFirestore(d)).toList());
  }

  static Stream<List<ChatSession>> streamUserChats(String uid) {
    if (uid.isEmpty || FirebaseAuth.instance.currentUser == null) {
      return const Stream.empty();
    }
    return _db
        .collection('chats')
        .where('participants', arrayContains: uid)
        .snapshots()
        .map((snap) {
      final list = snap.docs.map((d) => ChatSession.fromFirestore(d)).toList();
      list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return list;
    }).handleError((e) {
      debugPrint('[ChatService] streamUserChats error: $e');
      return <ChatSession>[];
    });
  }

  static Future<void> sendMessage({
    required String chatId,
    required String senderUid,
    required String otherUid,
    required String text,
    required String senderName,
    Map<String, dynamic>? attachment,
    Uint8List? inlineImage,
  }) async {
    assert(inlineImage == null || attachment != null);
    final cleanText = text.trim();
    if (cleanText.isEmpty && attachment == null) return;

    final chatRef = _db.collection('chats').doc(chatId);
    final chatSnap = await chatRef.get();
    if (chatSnap.exists) {
      final session = ChatSession.fromFirestore(chatSnap);
      if (!session.canSendMessage) {
        throw StateError(
          session.status == 'closed'
              ? 'This consultation chat has been closed.'
              : (session.isExpired
                  ? 'This consultation follow-up window has expired.'
                  : 'Message limit (${session.messageLimit}) reached for this consultation.'),
        );
      }
    }

    final msgRef = chatRef.collection('messages').doc();
    final batch = _db.batch();

    // The image and the message that points at it are written together.
    if (inlineImage != null) {
      final attachRef = chatRef.collection('attachments').doc();
      batch.set(attachRef, {
        'bytes': Blob(inlineImage),
        'mimeType': 'image/jpeg',
        'senderUid': senderUid,
        'createdAt': FieldValue.serverTimestamp(),
      });
      attachment = {...attachment!, 'inlineId': attachRef.id, 'sizeBytes': inlineImage.length};
    }

    final msgData = <String, dynamic>{
      'senderUid': senderUid,
      'text': cleanText.isNotEmpty ? cleanText : (attachment != null ? '📎 Shared a file' : ''),
      'createdAt': FieldValue.serverTimestamp(),
      if (attachment != null) 'attachment': attachment,
    };

    batch.set(msgRef, msgData);

    final displayLastMessage = cleanText.isNotEmpty
        ? cleanText
        : (attachment != null ? '📎 ${attachment['title'] ?? 'Shared a file'}' : '');

    batch.update(chatRef, {
      'lastMessage': displayLastMessage,
      'messageCount': FieldValue.increment(1),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    await batch.commit();

    try {
      await NotificationService.createNotification(
        userId: otherUid,
        title: 'New message from $senderName',
        body: displayLastMessage,
        type: 'chat_message',
        relatedId: chatId,
      );
    } catch (_) {}
  }

  /// Patient revokes a shared file attachment
  static Future<void> revokeAttachment({
    required String chatId,
    required String messageId,
  }) async {
    final msgRef = _db.collection('chats').doc(chatId).collection('messages').doc(messageId);
    final msgSnap = await msgRef.get();
    if (!msgSnap.exists) return;

    final attachment = msgSnap.data()?['attachment'] as Map<String, dynamic>?;
    if (attachment != null) {
      final updatedAttachment = Map<String, dynamic>.from(attachment);
      updatedAttachment['isRevoked'] = true;
      updatedAttachment['revokedAt'] = FieldValue.serverTimestamp();

      final batch = _db.batch();
      batch.update(msgRef, {
        'attachment': updatedAttachment,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      // Revoking an inline image deletes the bytes, not just the link.
      final inlineId = attachment['inlineId']?.toString();
      if (inlineId != null && inlineId.isNotEmpty) {
        batch.delete(_db.collection('chats').doc(chatId).collection('attachments').doc(inlineId));
        _inlineCache.remove('$chatId/$inlineId');
      }
      await batch.commit();
    }
  }
}
