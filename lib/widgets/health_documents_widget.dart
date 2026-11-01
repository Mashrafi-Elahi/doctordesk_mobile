import 'dart:async';
import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_constants.dart';
import '../services/document_service.dart';

class HealthDocumentsWidget extends StatefulWidget {
  final bool isPickerMode;
  final void Function(HealthDocument doc)? onSelectDocument;

  const HealthDocumentsWidget({
    super.key,
    this.isPickerMode = false,
    this.onSelectDocument,
  });

  @override
  State<HealthDocumentsWidget> createState() => _HealthDocumentsWidgetState();
}

class _HealthDocumentsWidgetState extends State<HealthDocumentsWidget> {
  List<HealthFolder> _folders = [];
  List<HealthDocument> _docs = [];
  bool _loading = true;
  String _searchQuery = '';
  String? _selectedFolderId;

  StreamSubscription<User?>? _authSub;
  String? _loadedUid;

  @override
  void initState() {
    super.initState();
    _loadedUid = FirebaseAuth.instance.currentUser?.uid;
    _loadData();
    // Documents are stored per account. Profile keeps this widget alive across
    // sign-in/out, so clear and reload when the account changes; otherwise the
    // next user would see the previous user's health records.
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user?.uid == _loadedUid) return;
      _loadedUid = user?.uid;
      if (mounted) {
        setState(() {
          _folders = [];
          _docs = [];
          _selectedFolderId = null;
          _loading = true;
        });
      }
      _loadData();
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  Future<void> _loadData() async {
    final folders = await DocumentService.loadFolders();
    final docs = await DocumentService.loadLocalDocuments();
    if (mounted) {
      setState(() {
        _folders = folders;
        _docs = docs;
        _loading = false;
      });
    }
  }

  List<HealthDocument> get _filteredDocs {
    return _docs.where((d) {
      if (_selectedFolderId != null && d.folderId != _selectedFolderId) {
        return false;
      }
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final matchTitle = d.title.toLowerCase().contains(q);
        final matchCat = d.category.toLowerCase().contains(q);
        return matchTitle || matchCat;
      }
      return true;
    }).toList();
  }

  List<HealthFolder> get _filteredFolders {
    if (_selectedFolderId != null) return [];
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      return _folders.where((f) => f.name.toLowerCase().contains(q) || f.category.toLowerCase().contains(q)).toList();
    }
    return _folders;
  }

  Future<void> _showCreateFolderDialog() async {
    final nameCtrl = TextEditingController();
    String selectedCategory = DocumentService.categories.first;

    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Create Folder'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Folder Name',
                  hintText: 'e.g. Heart Checkup 2026',
                ),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: selectedCategory,
                decoration: const InputDecoration(labelText: 'Category'),
                items: DocumentService.categories
                    .map((cat) => DropdownMenuItem(value: cat, child: Text(cat)))
                    .toList(),
                onChanged: (val) {
                  if (val != null) setDialogState(() => selectedCategory = val);
                },
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (nameCtrl.text.trim().isNotEmpty) Navigator.pop(ctx, true);
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );

    if (created == true && nameCtrl.text.trim().isNotEmpty) {
      await DocumentService.createFolder(name: nameCtrl.text.trim(), category: selectedCategory);
      await _loadData();
    }
  }

  Future<void> _showRenameFolderDialog(HealthFolder folder) async {
    final nameCtrl = TextEditingController(text: folder.name);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Folder'),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(labelText: 'Folder Name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (nameCtrl.text.trim().isNotEmpty) Navigator.pop(ctx, true);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (confirmed == true && nameCtrl.text.trim().isNotEmpty) {
      await DocumentService.renameFolder(folderId: folder.id, newName: nameCtrl.text.trim());
      await _loadData();
    }
  }

  Future<void> _confirmDeleteFolder(HealthFolder folder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Folder?'),
        content: Text('Are you sure you want to delete folder "${folder.name}"? Documents inside will be kept in the main list.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      if (_selectedFolderId == folder.id) _selectedFolderId = null;
      await DocumentService.deleteFolder(folderId: folder.id);
      await _loadData();
    }
  }

  Future<void> _showAddDocumentDialog() async {
    final titleCtrl = TextEditingController();
    String selectedCategory = DocumentService.categories.first;
    DateTime selectedDate = DateTime.now();
    bool fromCamera = false;

    final picked = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Add Health Document'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Document Title',
                    hintText: 'e.g. Blood Test Report',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selectedCategory,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: DocumentService.categories
                      .map((cat) => DropdownMenuItem(value: cat, child: Text(cat)))
                      .toList(),
                  onChanged: (val) {
                    if (val != null) setDialogState(() => selectedCategory = val);
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text('Date: ${selectedDate.day}/${selectedDate.month}/${selectedDate.year}'),
                    const Spacer(),
                    TextButton(
                      onPressed: () async {
                        final d = await showDatePicker(
                          context: ctx,
                          initialDate: selectedDate,
                          firstDate: DateTime(2000),
                          lastDate: DateTime.now(),
                        );
                        if (d != null) setDialogState(() => selectedDate = d);
                      },
                      child: const Text('Change Date'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text('Source:', style: TextStyle(fontWeight: FontWeight.w600)),
                Row(
                  children: [
                    ChoiceChip(
                      label: const Text('Gallery'),
                      selected: !fromCamera,
                      onSelected: (val) => setDialogState(() => fromCamera = false),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('Camera'),
                      selected: fromCamera,
                      onSelected: (val) => setDialogState(() => fromCamera = true),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (titleCtrl.text.trim().isNotEmpty) Navigator.pop(ctx, true);
              },
              child: const Text('Select File'),
            ),
          ],
        ),
      ),
    );

    if (picked == true && titleCtrl.text.trim().isNotEmpty) {
      final doc = await DocumentService.pickAndSaveImage(
        title: titleCtrl.text.trim(),
        category: selectedCategory,
        date: selectedDate,
        fromCamera: fromCamera,
        folderId: _selectedFolderId,
      );
      if (doc != null) {
        await _loadData();
      }
    }
  }

  Future<void> _confirmDeleteDocument(HealthDocument doc) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Document?'),
        content: Text('Delete "${doc.title}" from this device? This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await DocumentService.deleteLocalDocument(doc.id);
      await _loadData();
    }
  }

  Future<void> _moveDocument(HealthDocument doc) async {
    String? targetFolderId = doc.folderId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Move to Folder'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  targetFolderId == null ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  color: Theme.of(ctx).colorScheme.primary,
                ),
                title: const Text('Root (No Folder)'),
                onTap: () => setDialogState(() => targetFolderId = null),
              ),
              ..._folders.map(
                (f) => ListTile(
                  leading: Icon(
                    targetFolderId == f.id ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    color: Theme.of(ctx).colorScheme.primary,
                  ),
                  title: Text(f.name),
                  subtitle: Text(f.category, style: const TextStyle(fontSize: 11)),
                  onTap: () => setDialogState(() => targetFolderId = f.id),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Move'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      await DocumentService.moveDocument(documentId: doc.id, newFolderId: targetFolderId);
      await _loadData();
    }
  }

  void _viewDocument(HealthDocument doc) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppBar(
              title: Text(doc.title, style: const TextStyle(fontSize: 14)),
              automaticallyImplyLeading: false,
              actions: [
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
              ],
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 400),
              child: Image.file(
                File(doc.localPath),
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('Document preview not available')),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Category: ${doc.category}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text('Date: ${doc.date.day}/${doc.date.month}/${doc.date.year}'),
                  Text('Size: ${(doc.sizeBytes / 1024).toStringAsFixed(1)} KB'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedFolder = _selectedFolderId == null
        ? null
        : _folders.cast<HealthFolder?>().firstWhere((f) => f?.id == _selectedFolderId, orElse: () => null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Search & Controls Bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    hintText: 'Search health records...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onChanged: (val) => setState(() => _searchQuery = val.trim()),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                icon: const Icon(Icons.create_new_folder_outlined),
                tooltip: 'New Folder',
                onPressed: _showCreateFolderDialog,
              ),
              const SizedBox(width: 4),
              IconButton.filled(
                icon: const Icon(Icons.add_photo_alternate_outlined),
                tooltip: 'Add Document',
                onPressed: _showAddDocumentDialog,
              ),
            ],
          ),
        ),

        // Folder Path Breadcrumb
        if (selectedFolder != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, size: 18),
                  onPressed: () => setState(() => _selectedFolderId = null),
                ),
                Text(
                  selectedFolder.name,
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 8),
                Chip(
                  label: Text(selectedFolder.category, style: const TextStyle(fontSize: 10)),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),

        // Body Content
        if (_loading)
          const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
        else if (_filteredFolders.isEmpty && _filteredDocs.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              children: [
                Icon(Icons.folder_open_outlined, size: 48, color: Colors.grey[400]),
                const SizedBox(height: 8),
                Text(
                  _searchQuery.isNotEmpty ? 'No records match search' : 'No health records yet',
                  style: TextStyle(color: Colors.grey[600]),
                ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Folders Section
                if (_filteredFolders.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('Folders', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  ),
                  ..._filteredFolders.map((f) {
                    final count = _docs.where((d) => d.folderId == f.id).length;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 6),
                      child: ListTile(
                        leading: const Icon(Icons.folder, color: Colors.amber),
                        title: Text(f.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text('${f.category} • $count items', style: const TextStyle(fontSize: 12)),
                        trailing: PopupMenuButton<String>(
                          onSelected: (val) {
                            if (val == 'rename') _showRenameFolderDialog(f);
                            if (val == 'delete') _confirmDeleteFolder(f);
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(value: 'rename', child: Text('Rename')),
                            const PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(color: Colors.red))),
                          ],
                        ),
                        onTap: () => setState(() => _selectedFolderId = f.id),
                      ),
                    );
                  }),
                ],

                // Documents Section
                if (_filteredDocs.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      selectedFolder != null ? 'Documents in Folder' : 'Files',
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                  ),
                  ..._filteredDocs.map((doc) {
                    final isPdf = doc.mimeType == 'application/pdf';
                    final dateStr = '${doc.date.day}/${doc.date.month}/${doc.date.year}';
                    return Card(
                      margin: const EdgeInsets.only(bottom: 6),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: theme.colorScheme.primaryContainer,
                          child: Icon(isPdf ? Icons.picture_as_pdf : Icons.image, size: 20),
                        ),
                        title: Text(doc.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text('${doc.category} • $dateStr • ${(doc.sizeBytes / 1024).toStringAsFixed(0)} KB'),
                        trailing: widget.isPickerMode
                            ? FilledButton.tonal(
                                onPressed: () => widget.onSelectDocument?.call(doc),
                                child: const Text('Attach'),
                              )
                            : PopupMenuButton<String>(
                                onSelected: (val) {
                                  if (val == 'view') _viewDocument(doc);
                                  if (val == 'move') _moveDocument(doc);
                                  if (val == 'delete') _confirmDeleteDocument(doc);
                                },
                                itemBuilder: (_) => [
                                  const PopupMenuItem(value: 'view', child: Text('View / Preview')),
                                  const PopupMenuItem(value: 'move', child: Text('Move to Folder')),
                                  const PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(color: Colors.red))),
                                ],
                              ),
                        onTap: () {
                          if (widget.isPickerMode) {
                            widget.onSelectDocument?.call(doc);
                          } else {
                            _viewDocument(doc);
                          }
                        },
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),
      ],
    );
  }
}
