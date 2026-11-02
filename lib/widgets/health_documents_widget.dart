import 'dart:async';
import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_constants.dart';
import '../services/document_service.dart';

/// Browses the on-device health records as a folder tree that starts at the
/// account's root folder ("My Health Records"). Each view shows only the
/// folders and files directly inside the open folder; Back goes up a level.
///
/// Works both inside a scrolling parent (Profile) and in a fixed-height box
/// (the chat attach picker), where it scrolls its own list.
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
  String _currentFolderId = DocumentService.rootFolderId;
  final _searchCtrl = TextEditingController();

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
          _currentFolderId = DocumentService.rootFolderId;
          _searchQuery = '';
          _searchCtrl.clear();
          _loading = true;
        });
      }
      _loadData();
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    // Folders first: loading them moves loose documents into the root folder.
    final folders = await DocumentService.loadFolders();
    final docs = await DocumentService.loadLocalDocuments();
    if (mounted) {
      setState(() {
        _folders = folders;
        _docs = docs;
        if (!folders.any((f) => f.id == _currentFolderId)) {
          _currentFolderId = DocumentService.rootFolderId;
        }
        _loading = false;
      });
    }
  }

  bool get _atRoot => _currentFolderId == DocumentService.rootFolderId;

  HealthFolder? _folderById(String? id) {
    for (final f in _folders) {
      if (f.id == id) return f;
    }
    return null;
  }

  String _folderName(String? id) =>
      _folderById(id)?.name ?? DocumentService.rootFolderName;

  void _openFolder(String folderId) {
    setState(() {
      _currentFolderId = folderId;
      _searchQuery = '';
      _searchCtrl.clear();
    });
  }

  void _goUp() {
    if (_atRoot) return;
    _openFolder(_folderById(_currentFolderId)?.parentId ?? DocumentService.rootFolderId);
  }

  bool _matches(String a, String b) {
    final q = _searchQuery.toLowerCase();
    return a.toLowerCase().contains(q) || b.toLowerCase().contains(q);
  }

  /// Search looks through the open folder and everything nested under it.
  Set<String> get _searchScope =>
      DocumentService.subtreeIds(_currentFolderId, _folders);

  List<HealthFolder> get _visibleFolders {
    if (_searchQuery.isEmpty) {
      return _folders.where((f) => f.parentId == _currentFolderId).toList();
    }
    final scope = _searchScope;
    return _folders
        .where((f) => f.id != _currentFolderId && scope.contains(f.id) && _matches(f.name, f.category))
        .toList();
  }

  List<HealthDocument> get _visibleDocs {
    if (_searchQuery.isEmpty) {
      return _docs.where((d) => d.folderId == _currentFolderId).toList();
    }
    final scope = _searchScope;
    return _docs
        .where((d) => scope.contains(d.folderId) && _matches(d.title, d.category))
        .toList();
  }

  int _itemCount(String folderId) =>
      _folders.where((f) => f.parentId == folderId).length +
      _docs.where((d) => d.folderId == folderId).length;

  Future<void> _showCreateFolderDialog() async {
    final nameCtrl = TextEditingController();
    String selectedCategory = DocumentService.categories.first;
    final parentId = _currentFolderId;

    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('New Folder'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Inside "${_folderName(parentId)}"', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                const SizedBox(height: 8),
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
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
      await DocumentService.createFolder(
        name: nameCtrl.text.trim(),
        category: selectedCategory,
        parentId: parentId,
      );
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
    final parentName = _folderName(folder.parentId);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Folder?'),
        content: Text('Delete folder "${folder.name}"? Its files and folders will move to "$parentName".'),
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
      await DocumentService.deleteFolder(folderId: folder.id);
      await _loadData();
    }
  }

  Future<void> _showAddDocumentDialog() async {
    final titleCtrl = TextEditingController();
    String selectedCategory = DocumentService.categories.first;
    DateTime selectedDate = DateTime.now();
    bool fromCamera = false;
    final folderId = _currentFolderId;

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
                Text('Saves to "${_folderName(folderId)}"', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                const SizedBox(height: 8),
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
        folderId: folderId,
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

  /// All folders in tree order, each with its depth, for the Move dialog.
  List<(HealthFolder, int)> _folderTree() {
    final out = <(HealthFolder, int)>[];
    void walk(String id, int depth) {
      final f = _folderById(id);
      if (f == null) return;
      out.add((f, depth));
      for (final child in _folders.where((c) => c.parentId == id)) {
        walk(child.id, depth + 1);
      }
    }
    walk(DocumentService.rootFolderId, 0);
    return out;
  }

  Future<void> _moveDocument(HealthDocument doc) async {
    String targetFolderId = doc.folderId ?? DocumentService.rootFolderId;
    final tree = _folderTree();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Move to Folder'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final (f, depth) in tree)
                  ListTile(
                    contentPadding: EdgeInsets.only(left: 8.0 + depth * 16, right: 8),
                    dense: true,
                    leading: Icon(
                      targetFolderId == f.id ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      color: Theme.of(ctx).colorScheme.primary,
                    ),
                    title: Text(f.name),
                    onTap: () => setDialogState(() => targetFolderId = f.id),
                  ),
              ],
            ),
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

  Widget _buildBreadcrumb(ThemeData theme) {
    final path = DocumentService.pathTo(_currentFolderId, _folders);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: Row(
        children: [
          if (!_atRoot)
            IconButton(
              icon: const Icon(Icons.arrow_back, size: 18),
              tooltip: 'Up one folder',
              visualDensity: VisualDensity.compact,
              onPressed: _goUp,
            )
          else
            const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.folder_special, size: 18, color: Colors.amber),
            ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                children: [
                  for (var i = 0; i < path.length; i++) ...[
                    if (i > 0) Icon(Icons.chevron_right, size: 16, color: Colors.grey[600]),
                    if (i == path.length - 1)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                        child: Text(
                          path[i].name,
                          style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                      )
                    else
                      InkWell(
                        onTap: () => _openFolder(path[i].id),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                          child: Text(
                            path[i].name,
                            style: TextStyle(fontSize: 13, color: theme.colorScheme.primary),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildBody(ThemeData theme) {
    if (_loading) {
      return const [Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))];
    }
    final folders = _visibleFolders;
    final docs = _visibleDocs;
    if (folders.isEmpty && docs.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            children: [
              Icon(Icons.folder_open_outlined, size: 48, color: Colors.grey[400]),
              const SizedBox(height: 8),
              Text(
                _searchQuery.isNotEmpty ? 'No records match search' : 'This folder is empty',
                style: TextStyle(color: Colors.grey[600]),
              ),
              if (_searchQuery.isEmpty && !widget.isPickerMode) ...[
                const SizedBox(height: 4),
                Text(
                  'Add a photo or create a folder here.',
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ];
    }

    // During search, results can come from nested folders: say where.
    String? locationOf(String? parentId) =>
        _searchQuery.isNotEmpty && parentId != _currentFolderId ? _folderName(parentId) : null;

    return [
      // Folders Section
      if (folders.isNotEmpty) ...[
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('Folders', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        ),
        ...folders.map((f) {
          final count = _itemCount(f.id);
          final where = locationOf(f.parentId);
          return Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              leading: const Icon(Icons.folder, color: Colors.amber),
              title: Text(f.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(
                '${f.category} • $count ${count == 1 ? 'item' : 'items'}${where != null ? ' • in $where' : ''}',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: widget.isPickerMode
                  ? const Icon(Icons.chevron_right)
                  : PopupMenuButton<String>(
                      onSelected: (val) {
                        if (val == 'rename') _showRenameFolderDialog(f);
                        if (val == 'delete') _confirmDeleteFolder(f);
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'rename', child: Text('Rename')),
                        const PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(color: Colors.red))),
                      ],
                    ),
              onTap: () => _openFolder(f.id),
            ),
          );
        }),
      ],

      // Documents Section
      if (docs.isNotEmpty) ...[
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('Files', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        ),
        ...docs.map((doc) {
          final isPdf = doc.mimeType == 'application/pdf';
          final dateStr = '${doc.date.day}/${doc.date.month}/${doc.date.year}';
          final where = locationOf(doc.folderId);
          return Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(isPdf ? Icons.picture_as_pdf : Icons.image, size: 20),
              ),
              title: Text(doc.title, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(
                '${doc.category} • $dateStr • ${(doc.sizeBytes / 1024).toStringAsFixed(0)} KB${where != null ? ' • in $where' : ''}',
              ),
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
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Profile sits in an IndexedStack, which keeps this widget alive (with
    // tickers off) while another tab shows. Only take over Back when visible.
    final visible = TickerMode.valuesOf(context).enabled;

    final header = <Widget>[
      // Search & Controls Bar
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  hintText: 'Search in ${_folderName(_currentFolderId)}...',
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
              onPressed: _loading ? null : _showCreateFolderDialog,
            ),
            const SizedBox(width: 4),
            IconButton.filled(
              icon: const Icon(Icons.add_photo_alternate_outlined),
              tooltip: 'Add Document',
              onPressed: _loading ? null : _showAddDocumentDialog,
            ),
          ],
        ),
      ),
      _buildBreadcrumb(theme),
    ];

    final body = _buildBody(theme);

    return PopScope(
      canPop: _atRoot || !visible,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && visible) _goUp();
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.hasBoundedHeight) {
            // Fixed-height host (chat picker): scroll our own list.
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...header,
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: body,
                  ),
                ),
              ],
            );
          }
          // Inside a scrolling parent (Profile): grow with the content.
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ...header,
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: body,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
