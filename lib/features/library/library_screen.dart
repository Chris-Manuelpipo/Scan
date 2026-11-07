import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/dialogs.dart';
import '../../app/providers.dart';
import '../../app/selection_mark.dart';
import '../../core/db/database.dart';
import '../export/export_sheet.dart';
import '../scan/scan_actions.dart';
import 'folder_actions.dart';

const _sortLabels = {
  DocumentSort.updated: 'Date de modification',
  DocumentSort.created: 'Date de création',
  DocumentSort.title: 'Nom',
};

/// The root of the library when [folderId] is `null`, otherwise one folder.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key, this.folderId});

  final int? folderId;

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  final _search = TextEditingController();
  var _searching = false;

  /// Selected document ids, in selection order (used as merge order).
  final _selected = <int>{};

  bool get _selecting => _selected.isNotEmpty;

  void _toggle(int id) => setState(() {
    if (!_selected.remove(id)) _selected.add(id);
  });

  Future<void> _mergeSelected() async {
    var deleteSources = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Fusionner ${_selected.length} documents ?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Un nouveau document est créé avec toutes les pages, '
                'dans l\'ordre de sélection.',
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: deleteSources,
                onChanged: (v) => setDialogState(() => deleteSources = v!),
                title: const Text('Supprimer les documents d\'origine'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Fusionner'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final ids = _selected.toList();
    final id = await runWithProgress(
      context,
      'Fusion…',
      () => ref
          .read(repositoryProvider)
          .mergeDocuments(ids, deleteSources: deleteSources),
    );
    if (id == null || !mounted) return;
    setState(_selected.clear);
    context.push('/doc/$id');
  }

  Future<void> _moveSelected() async {
    if (await moveDocuments(
          context,
          ref,
          _selected.toList(),
          from: widget.folderId,
        ) &&
        mounted) {
      setState(_selected.clear);
    }
  }

  Future<void> _deleteSelected() async {
    final count = _selected.length;
    if (!await confirm(
      context,
      title: 'Supprimer $count document${count > 1 ? 's' : ''} ?',
      message: 'Cette action est définitive.',
    )) {
      return;
    }
    final repository = ref.read(repositoryProvider);
    for (final id in _selected.toList()) {
      await repository.deleteDocument(id);
    }
    if (mounted) setState(_selected.clear);
  }

  bool get _isRoot => widget.folderId == null;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _create(PageSource source) async {
    final id = await createDocumentFrom(
      context,
      ref,
      source,
      folderId: widget.folderId,
    );
    if (id != null && mounted) context.push('/doc/$id');
  }

  Future<void> _showImportChoices() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: const Text('Carte d\'identité'),
              subtitle: const Text('Recto et verso sur une page A4'),
              onTap: () => Navigator.pop(context, 'idcard'),
            ),
            ListTile(
              leading: const Icon(Icons.menu_book_outlined),
              title: const Text('Livre'),
              subtitle: const Text('Une photo par double page, coupée en deux'),
              onTap: () => Navigator.pop(context, 'book'),
            ),
            ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: const Text('QR code / code-barres'),
              onTap: () => Navigator.pop(context, 'barcode'),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Images de la galerie'),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.picture_as_pdf_outlined),
              title: const Text('Fichiers (PDF ou images)'),
              onTap: () => Navigator.pop(context, 'files'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'idcard':
        final id = await createIdCardFrom(
          context,
          ref,
          folderId: widget.folderId,
        );
        if (id != null && mounted) context.push('/doc/$id');
      case 'book':
        final id = await createBookFrom(
          context,
          ref,
          folderId: widget.folderId,
        );
        if (id != null && mounted) context.push('/doc/$id');
      case 'barcode':
        await context.push('/barcode');
      case 'gallery':
        await _create(PageSource.gallery);
      case 'files':
        final picked = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png', 'webp'],
        );
        final paths = [
          for (final f in picked)
            if (f.path != null) f.path!,
        ];
        if (paths.isEmpty || !mounted) return;
        final id = await importFiles(
          context,
          ref,
          paths,
          folderId: widget.folderId,
        );
        if (id != null && mounted) context.push('/doc/$id');
    }
  }

  void _closeSearch() => setState(() {
    _searching = false;
    _search.clear();
  });

  PreferredSizeWidget _appBar(Folder? folder) {
    if (_selecting) {
      final count = _selected.length;
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => setState(_selected.clear),
        ),
        title: Text('$count sélectionné${count > 1 ? 's' : ''}'),
        actions: [
          IconButton(
            tooltip: 'Fusionner',
            icon: const Icon(Icons.merge_type),
            onPressed: count < 2 ? null : _mergeSelected,
          ),
          IconButton(
            tooltip: 'Déplacer',
            icon: const Icon(Icons.drive_file_move_outlined),
            onPressed: _moveSelected,
          ),
          IconButton(
            tooltip: 'Supprimer',
            icon: const Icon(Icons.delete_outline),
            onPressed: _deleteSelected,
          ),
        ],
      );
    }
    if (_searching) {
      return AppBar(
        leading: BackButton(onPressed: _closeSearch),
        title: TextField(
          controller: _search,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Titre ou texte du document',
            border: InputBorder.none,
          ),
          onChanged: (_) => setState(() {}),
        ),
        actions: [
          if (_search.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () => setState(_search.clear),
            ),
        ],
      );
    }
    final sort = ref.watch(sortProvider);
    return AppBar(
      title: Text(_isRoot ? 'SCAN' : folder?.name ?? ''),
      actions: [
        IconButton(
          tooltip: 'Rechercher',
          icon: const Icon(Icons.search),
          onPressed: () => setState(() => _searching = true),
        ),
        PopupMenuButton<DocumentSort>(
          tooltip: 'Trier',
          icon: const Icon(Icons.sort),
          onSelected: ref.read(sortProvider.notifier).set,
          itemBuilder: (_) => [
            for (final entry in _sortLabels.entries)
              CheckedPopupMenuItem(
                value: entry.key,
                checked: entry.key == sort,
                child: Text(entry.value),
              ),
          ],
        ),
        if (_isRoot) ...[
          IconButton(
            tooltip: 'Nouveau dossier',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: () => createFolder(context, ref),
          ),
          IconButton(
            tooltip: 'Réglages',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
          ),
        ] else if (folder != null)
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'rename') {
                await renameFolder(context, ref, folder);
              } else if (await deleteFolder(context, ref, folder) && mounted) {
                context.pop();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('Renommer')),
              PopupMenuItem(value: 'delete', child: Text('Supprimer')),
            ],
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final folder = _isRoot
        ? null
        : ref.watch(folderProvider(widget.folderId!)).value;
    final search = _searching ? _search.text : '';
    final documents = ref.watch(
      documentsProvider((folderId: widget.folderId, search: search)),
    );
    final folders = _isRoot && search.isEmpty
        ? ref.watch(foldersProvider).value ?? const <FolderSummary>[]
        : const <FolderSummary>[];

    return PopScope(
      canPop: !_searching && !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selecting) {
          setState(_selected.clear);
        } else {
          _closeSearch();
        }
      },
      child: Scaffold(
        appBar: _appBar(folder),
        body: documents.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Erreur : $e')),
          data: (items) => items.isEmpty && folders.isEmpty
              ? _EmptyLibrary(
                  message: search.isNotEmpty
                      ? 'Aucun document ne correspond à « $search ».'
                      : _isRoot
                      ? 'Appuie sur « Scanner » pour numériser ton premier document.'
                      : 'Ce dossier est vide.',
                )
              : CustomScrollView(
                  slivers: [
                    SliverList.list(
                      children: [
                        for (final f in folders) _FolderTile(summary: f),
                        if (folders.isNotEmpty) const Divider(),
                      ],
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 160),
                      sliver: SliverGrid.builder(
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 220,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 12,
                              childAspectRatio: 0.66,
                            ),
                        itemCount: items.length,
                        itemBuilder: (context, i) => _DocumentCard(
                          summary: items[i],
                          selecting: _selecting,
                          selected: _selected.contains(items[i].document.id),
                          onToggle: () => _toggle(items[i].document.id),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
        floatingActionButton: _searching || _selecting
            ? null
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  FloatingActionButton.small(
                    heroTag: 'import',
                    tooltip: 'Autres modes et import',
                    onPressed: _showImportChoices,
                    child: const Icon(Icons.apps),
                  ),
                  const SizedBox(height: 12),
                  FloatingActionButton.extended(
                    heroTag: 'scan',
                    onPressed: () => _create(PageSource.scanner),
                    icon: const Icon(Icons.document_scanner_outlined),
                    label: const Text('Scanner'),
                  ),
                ],
              ),
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.document_scanner_outlined,
              size: 72,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text('Aucun document', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _FolderTile extends ConsumerWidget {
  const _FolderTile({required this.summary});

  final FolderSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folder = summary.folder;
    final count = summary.documentCount;
    return ListTile(
      leading: Icon(Icons.folder, color: Theme.of(context).colorScheme.primary),
      title: Text(folder.name),
      subtitle: Text('$count document${count > 1 ? 's' : ''}'),
      onTap: () => context.push('/folder/${folder.id}'),
      trailing: PopupMenuButton<String>(
        onSelected: (value) => value == 'rename'
            ? renameFolder(context, ref, folder)
            : deleteFolder(context, ref, folder),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: Text('Renommer')),
          PopupMenuItem(value: 'delete', child: Text('Supprimer')),
        ],
      ),
    );
  }
}

class _DocumentCard extends ConsumerWidget {
  const _DocumentCard({
    required this.summary,
    required this.selecting,
    required this.selected,
    required this.onToggle,
  });

  final DocumentSummary summary;
  final bool selecting;
  final bool selected;
  final VoidCallback onToggle;

  Future<void> _showActions(BuildContext context, WidgetRef ref) async {
    final document = summary.document;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('Exporter'),
              onTap: () => Navigator.pop(context, 'export'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Renommer'),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outlined),
              title: const Text('Déplacer'),
              onTap: () => Navigator.pop(context, 'move'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Supprimer'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    final repository = ref.read(repositoryProvider);
    switch (action) {
      case 'export':
        await showExportSheet(context, document);
      case 'rename':
        final title = await promptText(
          context,
          title: 'Renommer',
          initial: document.title,
        );
        if (title != null) await repository.rename(document.id, title);
      case 'move':
        await moveDocument(context, ref, document);
      case 'delete':
        if (await confirm(
          context,
          title: 'Supprimer ?',
          message: '« ${document.title} » sera définitivement supprimé.',
        )) {
          await repository.deleteDocument(document.id);
        }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final files = ref.watch(fileStoreProvider);
    final cover = summary.coverPath;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: selecting
            ? onToggle
            : () => context.push('/doc/${summary.document.id}'),
        onLongPress: onToggle,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: cover == null
                        ? const Icon(Icons.description_outlined, size: 48)
                        : Image.file(
                            File(files.abs(cover)),
                            fit: BoxFit.cover,
                            alignment: Alignment.topCenter,
                          ),
                  ),
                  if (selecting) SelectionMark(selected: selected),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          summary.document.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                        Text(
                          '${summary.pageCount} p. · '
                          '${DateFormat('dd/MM/yy HH:mm').format(summary.document.updatedAt)}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.more_vert),
                    onPressed: selecting
                        ? null
                        : () => _showActions(context, ref),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
