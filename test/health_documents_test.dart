import 'dart:convert';

import 'package:doctordesk/services/document_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const root = DocumentService.rootFolderId;

HealthFolder folder(String id, {String? parentId}) => HealthFolder(
      id: id,
      name: id,
      category: 'Other',
      createdAt: DateTime(2026),
      parentId: parentId,
    );

HealthDocument doc(String id, {String? folderId}) => HealthDocument(
      id: id,
      folderId: folderId,
      title: id,
      category: 'Other',
      date: DateTime(2026),
      localPath: '/tmp/$id.jpg',
    );

void main() {
  group('normalizeTree', () {
    test('creates the root folder on first use', () {
      final t = DocumentService.normalizeTree([], []);
      expect(t.folders.single.id, root);
      expect(t.folders.single.name, 'My Health Records');
      expect(t.folders.single.parentId, isNull);
      expect(t.foldersChanged, isTrue);
      expect(t.docsChanged, isFalse);
    });

    test('moves old top-level folders and loose documents into the root', () {
      final t = DocumentService.normalizeTree(
        [folder('a'), folder('b', parentId: 'a')],
        [doc('d1'), doc('d2', folderId: 'b'), doc('d3', folderId: 'gone')],
      );
      final byId = {for (final f in t.folders) f.id: f};
      expect(byId['a']!.parentId, root);
      expect(byId['b']!.parentId, 'a');
      final docs = {for (final d in t.docs) d.id: d.folderId};
      expect(docs, {'d1': root, 'd2': 'b', 'd3': root});
      expect(t.docsChanged, isTrue);
    });

    test('leaves a valid tree unchanged', () {
      final t = DocumentService.normalizeTree(
        [folder(root), folder('a', parentId: root)],
        [doc('d', folderId: 'a')],
      );
      expect(t.foldersChanged, isFalse);
      expect(t.docsChanged, isFalse);
    });

    test('breaks parent cycles by moving into the root', () {
      final t = DocumentService.normalizeTree(
        [folder(root), folder('a', parentId: 'b'), folder('b', parentId: 'a')],
        [],
      );
      final ids = DocumentService.subtreeIds(root, t.folders);
      expect(ids, containsAll(['a', 'b']));
    });
  });

  test('pathTo and subtreeIds follow parentId', () {
    final folders = [
      folder(root),
      folder('a', parentId: root),
      folder('b', parentId: 'a'),
      folder('c', parentId: root),
    ];
    expect(DocumentService.pathTo('b', folders).map((f) => f.id), [root, 'a', 'b']);
    expect(DocumentService.subtreeIds('a', folders), {'a', 'b'});
  });

  group('storage', () {
    setUp(() {
      DocumentService.debugUid = 'u1';
    });

    test('createFolder nests under the given parent', () async {
      SharedPreferences.setMockInitialValues({});
      final a = await DocumentService.createFolder(name: 'A', category: 'Scans');
      final b = await DocumentService.createFolder(name: 'B', category: 'Scans', parentId: a.id);
      expect(a.parentId, root);
      expect(b.parentId, a.id);
      final folders = await DocumentService.loadFolders();
      expect(folders.map((f) => f.id), containsAll([root, a.id, b.id]));
    });

    test('deleteFolder moves contents to its parent; root cannot be deleted', () async {
      SharedPreferences.setMockInitialValues({
        'health_folders_u1': jsonEncode([
          folder(root).toJson(),
          folder('a', parentId: root).toJson(),
          folder('b', parentId: 'a').toJson(),
          folder('c', parentId: 'b').toJson(),
        ]),
        'health_documents_u1': jsonEncode([doc('d', folderId: 'b').toJson()]),
      });

      await DocumentService.deleteFolder(folderId: 'b');
      final folders = await DocumentService.loadFolders();
      final docs = await DocumentService.loadLocalDocuments();
      expect(folders.map((f) => f.id), isNot(contains('b')));
      expect(folders.firstWhere((f) => f.id == 'c').parentId, 'a');
      expect(docs.single.folderId, 'a');

      await DocumentService.deleteFolder(folderId: root);
      expect((await DocumentService.loadFolders()).any((f) => f.id == root), isTrue);
    });

    test('loadFolders migrates data saved before folders could nest', () async {
      SharedPreferences.setMockInitialValues({
        'health_folders_u1': jsonEncode([folder('old').toJson()]),
        'health_documents_u1': jsonEncode([doc('loose').toJson()]),
      });
      final folders = await DocumentService.loadFolders();
      final docs = await DocumentService.loadLocalDocuments();
      expect(folders.firstWhere((f) => f.id == 'old').parentId, root);
      expect(docs.single.folderId, root);
    });
  });
}
