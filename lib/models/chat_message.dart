import 'package:cloud_firestore/cloud_firestore.dart';

class ChatMessage {
  final String id;
  final String senderUid;
  final String text;
  final DateTime createdAt;
  final Map<String, dynamic>? attachment;

  ChatMessage({
    required this.id,
    required this.senderUid,
    required this.text,
    required this.createdAt,
    this.attachment,
  });

  bool get hasAttachment => attachment != null;
  bool get isRevoked => attachment?['isRevoked'] == true;
  String? get fileUrl => attachment?['fileUrl']?.toString();
  /// Set for photos stored in chats/{id}/attachments (no Cloud Storage).
  String? get inlineId => attachment?['inlineId']?.toString();
  String? get storagePath => attachment?['storagePath']?.toString();
  String? get fileName => attachment?['fileName']?.toString() ?? attachment?['title']?.toString();
  String? get fileCategory => attachment?['fileCategory']?.toString() ?? attachment?['category']?.toString();
  String? get mimeType => attachment?['mimeType']?.toString();
  int? get sizeBytes => (attachment?['sizeBytes'] as num?)?.toInt();
  DateTime? get shareExpiresAt {
    final exp = attachment?['expiresAt'];
    if (exp is Timestamp) return exp.toDate();
    if (exp is String) return DateTime.tryParse(exp);
    return null;
  }
  bool get isShareExpired => shareExpiresAt != null && DateTime.now().isAfter(shareExpiresAt!);

  factory ChatMessage.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    final ts = data['createdAt'];
    return ChatMessage(
      id: doc.id,
      senderUid: (data['senderUid'] ?? '').toString(),
      text: (data['text'] ?? '').toString(),
      createdAt: ts is Timestamp ? ts.toDate() : DateTime.now(),
      attachment: data['attachment'] is Map ? Map<String, dynamic>.from(data['attachment'] as Map) : null,
    );
  }

  Map<String, dynamic> toMap() => {
    'senderUid': senderUid,
    'text': text,
    'createdAt': FieldValue.serverTimestamp(),
    if (attachment != null) 'attachment': attachment,
  };
}

class ChatSession {
  final String id;
  final List<String> participants;
  final Map<String, String> participantRoles;
  final Map<String, String> participantNames;
  final String patientUid;
  final String doctorUid;
  final String? operatorUid;
  final String? appointmentId;
  final String? chamberId;
  final String? doctorId;
  final String lastMessage;
  final DateTime updatedAt;
  final String doctorName;
  final String patientName;
  final String status; // 'active' | 'expired' | 'closed'
  final DateTime? expiresAt;
  final int messageLimit;
  final int messageCount;
  final String? unlockedBy;

  ChatSession({
    required this.id,
    required this.participants,
    this.participantRoles = const {},
    this.participantNames = const {},
    required this.patientUid,
    required this.doctorUid,
    this.operatorUid,
    this.appointmentId,
    this.chamberId,
    this.doctorId,
    required this.lastMessage,
    required this.updatedAt,
    required this.doctorName,
    required this.patientName,
    this.status = 'active',
    this.expiresAt,
    this.messageLimit = 20,
    this.messageCount = 0,
    this.unlockedBy,
  });

  bool get isExpired => expiresAt != null && DateTime.now().isAfter(expiresAt!);
  bool get isLimitReached => messageCount >= messageLimit;
  bool get canSendMessage => status == 'active' && !isExpired && !isLimitReached;

  String otherParticipantName(String myUid) {
    final others = participants.where((p) => p != myUid).toList();
    if (others.isNotEmpty) {
      final otherUid = others.first;
      if (participantNames.containsKey(otherUid) && participantNames[otherUid]!.isNotEmpty) {
        return participantNames[otherUid]!;
      }
    }
    if (myUid == patientUid) return doctorName;
    return patientName;
  }

  String otherParticipantRole(String myUid) {
    final others = participants.where((p) => p != myUid).toList();
    if (others.isNotEmpty) {
      final otherUid = others.first;
      if (participantRoles.containsKey(otherUid) && participantRoles[otherUid]!.isNotEmpty) {
        return participantRoles[otherUid]!;
      }
    }
    if (myUid == patientUid) return 'Doctor';
    return 'Patient';
  }

  factory ChatSession.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    final ts = data['updatedAt'];
    final expTs = data['expiresAt'];
    final pUid = (data['patientUid'] ?? '').toString();
    final dUid = (data['doctorUid'] ?? '').toString();
    final opUid = data['operatorUid']?.toString();
    final rawParts = data['participants'];
    final parts = rawParts is List
        ? rawParts.map((e) => e.toString()).toList()
        : [pUid, dUid];

    Map<String, String> roles = {};
    if (data['participantRoles'] is Map) {
      roles = (data['participantRoles'] as Map).map((k, v) => MapEntry(k.toString(), v.toString()));
    } else {
      roles[pUid] = 'Patient';
      roles[dUid] = 'Doctor';
      if (opUid != null && opUid.isNotEmpty) {
        roles[opUid] = 'Clinic Desk Operator';
      }
    }

    Map<String, String> names = {};
    if (data['participantNames'] is Map) {
      names = (data['participantNames'] as Map).map((k, v) => MapEntry(k.toString(), v.toString()));
    } else {
      names[pUid] = (data['patientName'] ?? 'Patient').toString();
      names[dUid] = (data['doctorName'] ?? 'Doctor').toString();
      if (opUid != null && opUid.isNotEmpty && data['operatorName'] != null) {
        names[opUid] = data['operatorName'].toString();
      }
    }

    return ChatSession(
      id: doc.id,
      participants: parts,
      participantRoles: roles,
      participantNames: names,
      patientUid: pUid,
      doctorUid: dUid,
      operatorUid: opUid,
      appointmentId: data['appointmentId'] as String?,
      chamberId: data['chamberId'] as String?,
      doctorId: data['doctorId'] as String?,
      lastMessage: (data['lastMessage'] ?? '').toString(),
      updatedAt: ts is Timestamp ? ts.toDate() : DateTime.now(),
      doctorName: (data['doctorName'] ?? 'Doctor').toString(),
      patientName: (data['patientName'] ?? 'Patient').toString(),
      status: (data['status'] ?? 'active').toString(),
      expiresAt: expTs is Timestamp ? expTs.toDate() : null,
      messageLimit: (data['messageLimit'] as num?)?.toInt() ?? 20,
      messageCount: (data['messageCount'] as num?)?.toInt() ?? 0,
      unlockedBy: data['unlockedBy'] as String?,
    );
  }
}
