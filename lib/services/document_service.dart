import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'chat_service.dart';

class HealthFolder {
  final String id;
  final String name;
  final String category; // 'Prescriptions', 'Lab reports', 'Scans', 'Bills', 'Other'
  final DateTime createdAt;

  HealthFolder({
    required this.id,
    required this.name,
    required this.category,
    required this.createdAt,
  });

  factory HealthFolder.fromJson(Map<String, dynamic> json) => HealthFolder(
    id: json['id'] as String,
    name: json['name'] as String,
    category: json['category'] as String? ?? 'Other',
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'category': category,
    'createdAt': createdAt.toIso8601String(),
  };
}

class HealthDocument {
  final String id;
  final String? folderId;
  final String title;
  final String category; // 'Prescriptions', 'Lab reports', 'Scans', 'Bills', 'Other'
  final DateTime date;
  final String localPath;
  final String mimeType;
  final int sizeBytes;

  HealthDocument({
    required this.id,
    this.folderId,
    required this.title,
    required this.category,
    required this.date,
    required this.localPath,
    this.mimeType = 'image/jpeg',
    this.sizeBytes = 0,
  });

  factory HealthDocument.fromJson(Map<String, dynamic> json) => HealthDocument(
    id: json['id'] as String,
    folderId: json['folderId'] as String?,
    title: json['title'] as String,
    category: json['category'] as String? ?? 'Other',
    date: DateTime.tryParse(json['date'] as String? ?? '') ?? DateTime.now(),
    localPath: json['localPath'] as String,
    mimeType: json['mimeType'] as String? ?? 'image/jpeg',
    sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    if (folderId != null) 'folderId': folderId,
    'title': title,
    'category': category,
    'date': date.toIso8601String(),
    'localPath': localPath,
    'mimeType': mimeType,
    'sizeBytes': sizeBytes,
  };
}

class DocumentService {
  static const List<String> categories = [
    'Prescriptions',
    'Lab reports',
    'Scans',
    'Bills',
    'Other',
  ];

  static String get _foldersKey {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'guest';
    return 'health_folders_$uid';
  }

  static String get _docsKey {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'guest';
    return 'health_documents_$uid';
  }

  static final ImagePicker _picker = ImagePicker();

  static Future<Directory> _getLocalDocsDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final docsDir = Directory('${appDir.path}/health_documents');
    if (!docsDir.existsSync()) {
      docsDir.createSync(recursive: true);
    }
    return docsDir;
  }

  // ── Folders Management ─────────────────────────────────────────────────────

  static Future<List<HealthFolder>> loadFolders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_foldersKey);
      if (raw == null || raw.isEmpty) return [];
      final List<dynamic> list = jsonDecode(raw);
      return list
          .map((e) => HealthFolder.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
    } catch (e) {
      debugPrint('[DocumentService] Error loading folders: $e');
      return [];
    }
  }

  static Future<void> _saveFolders(List<HealthFolder> folders) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _foldersKey,
      jsonEncode(folders.map((f) => f.toJson()).toList()),
    );
  }

  static Future<HealthFolder> createFolder({
    required String name,
    required String category,
  }) async {
    final id = 'folder_${DateTime.now().millisecondsSinceEpoch}';
    final folder = HealthFolder(
      id: id,
      name: name.trim(),
      category: categories.contains(category) ? category : 'Other',
      createdAt: DateTime.now(),
    );
    final list = await loadFolders();
    list.add(folder);
    await _saveFolders(list);
    return folder;
  }

  static Future<void> renameFolder({
    required String folderId,
    required String newName,
  }) async {
    final list = await loadFolders();
    final idx = list.indexWhere((f) => f.id == folderId);
    if (idx != -1) {
      final f = list[idx];
      list[idx] = HealthFolder(
        id: f.id,
        name: newName.trim(),
        category: f.category,
        createdAt: f.createdAt,
      );
      await _saveFolders(list);
    }
  }

  static Future<void> deleteFolder({required String folderId}) async {
    // Delete folder and move its files to root (folderId: null)
    final folders = await loadFolders();
    folders.removeWhere((f) => f.id == folderId);
    await _saveFolders(folders);

    final docs = await loadLocalDocuments();
    bool changed = false;
    for (int i = 0; i < docs.length; i++) {
      if (docs[i].folderId == folderId) {
        docs[i] = HealthDocument(
          id: docs[i].id,
          folderId: null,
          title: docs[i].title,
          category: docs[i].category,
          date: docs[i].date,
          localPath: docs[i].localPath,
          mimeType: docs[i].mimeType,
          sizeBytes: docs[i].sizeBytes,
        );
        changed = true;
      }
    }
    if (changed) {
      await _saveDocuments(docs);
    }
  }

  // ── Documents Management ───────────────────────────────────────────────────

  static Future<List<HealthDocument>> loadLocalDocuments() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_docsKey);
      if (raw == null || raw.isEmpty) return [];
      final List<dynamic> list = jsonDecode(raw);
      return list
          .map((e) => HealthDocument.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.date.compareTo(a.date));
    } catch (e) {
      debugPrint('[DocumentService] Error loading local documents: $e');
      return [];
    }
  }

  static Future<void> _saveDocuments(List<HealthDocument> docs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _docsKey,
      jsonEncode(docs.map((d) => d.toJson()).toList()),
    );
  }

  /// Saves a picked file into local app documents directory
  static Future<HealthDocument> saveLocalDocument({
    required String title,
    required String category,
    required DateTime date,
    required String sourcePath,
    String? folderId,
  }) async {
    final sourceFile = File(sourcePath);
    if (!sourceFile.existsSync()) {
      throw StateError('Source file does not exist.');
    }

    final id = 'doc_${DateTime.now().millisecondsSinceEpoch}';
    final ext = sourcePath.contains('.') ? sourcePath.split('.').last.toLowerCase() : 'jpg';
    final mimeType = ext == 'pdf'
        ? 'application/pdf'
        : (ext == 'png' ? 'image/png' : 'image/jpeg');

    final docsDir = await _getLocalDocsDirectory();
    final localFilePath = '${docsDir.path}/$id.$ext';
    await sourceFile.copy(localFilePath);
    final sizeBytes = await sourceFile.length();

    final doc = HealthDocument(
      id: id,
      folderId: folderId,
      title: title.trim(),
      category: categories.contains(category) ? category : 'Other',
      date: date,
      localPath: localFilePath,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
    );

    final list = await loadLocalDocuments();
    list.insert(0, doc);
    await _saveDocuments(list);
    return doc;
  }

  static Future<HealthDocument?> pickAndSaveImage({
    required String title,
    required String category,
    required DateTime date,
    bool fromCamera = false,
    String? folderId,
  }) async {
    final XFile? file = fromCamera
        ? await _picker.pickImage(source: ImageSource.camera, maxWidth: 1600, maxHeight: 1600, imageQuality: 85)
        : await _picker.pickImage(source: ImageSource.gallery, maxWidth: 1600, maxHeight: 1600, imageQuality: 85);

    if (file == null) return null;
    return saveLocalDocument(
      title: title.isEmpty ? file.name : title,
      category: category,
      date: date,
      sourcePath: file.path,
      folderId: folderId,
    );
  }

  static Future<void> moveDocument({
    required String documentId,
    required String? newFolderId,
  }) async {
    final docs = await loadLocalDocuments();
    final idx = docs.indexWhere((d) => d.id == documentId);
    if (idx != -1) {
      final d = docs[idx];
      docs[idx] = HealthDocument(
        id: d.id,
        folderId: newFolderId,
        title: d.title,
        category: d.category,
        date: d.date,
        localPath: d.localPath,
        mimeType: d.mimeType,
        sizeBytes: d.sizeBytes,
      );
      await _saveDocuments(docs);
    }
  }

  static Future<void> deleteLocalDocument(String documentId) async {
    final docs = await loadLocalDocuments();
    final idx = docs.indexWhere((d) => d.id == documentId);
    if (idx != -1) {
      final doc = docs[idx];
      try {
        final f = File(doc.localPath);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
      docs.removeAt(idx);
      await _saveDocuments(docs);
    }
  }

  // ── Chat File Sharing ──────────────────────────────────────────────────────

  /// Explicit user attachment to a chat.
  /// Uploads to Firebase Storage under `chat_files/{chatId}/...`.
  /// Max 10 MB, allowed types: pdf, jpg, png. Expiry: 30 days.
  static Future<void> attachFileToChat({
    required String chatId,
    required String senderUid,
    required String senderName,
    required String otherUid,
    required HealthDocument doc,
  }) async {
    final file = File(doc.localPath);
    if (!file.existsSync()) {
      throw StateError('File not found on device.');
    }

    final fileSize = await file.length();
    if (fileSize > 10 * 1024 * 1024) {
      throw StateError('File size exceeds the 10 MB limit.');
    }

    final ext = doc.localPath.split('.').last.toLowerCase();
    if (ext == 'pdf') {
      throw StateError(
          "PDFs can't be sent yet. Send a photo of the page instead.");
    }
    if (ext != 'jpg' && ext != 'jpeg' && ext != 'png') {
      throw StateError('Only JPG and PNG photos can be sent.');
    }

    // No Cloud Storage on the free plan: the photo is compressed and stored
    // in Firestore next to the message (see docs/adr/ADR-001).
    final jpeg = await ChatService.compressForChat(await file.readAsBytes());

    final attachmentData = <String, dynamic>{
      'title': doc.title,
      'fileName': doc.title,
      'category': doc.category,
      'fileCategory': doc.category,
      'mimeType': 'image/jpeg',
      'sharedAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(DateTime.now().add(const Duration(days: 30))),
      'isRevoked': false,
      'sharedByUid': senderUid,
    };

    await ChatService.sendMessage(
      chatId: chatId,
      senderUid: senderUid,
      otherUid: otherUid,
      text: '📎 Shared ${doc.category}: ${doc.title}',
      senderName: senderName,
      attachment: attachmentData,
      inlineImage: jpeg,
    );
  }
}
