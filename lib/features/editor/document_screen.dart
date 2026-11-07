import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:reorderable_grid/reorderable_grid.dart';

import '../../app/dialogs.dart';
import '../../app/providers.dart';
import '../../app/selection_mark.dart';
import '../../core/db/database.dart';
import '../export/export_sheet.dart';
import '../library/folder_actions.dart';
import '../scan/scan_actions.dart';

class DocumentScreen extends ConsumerStatefulWidget {
  const DocumentScreen({super.key, required this.documentId});

  final int documentId;

  @override
  ConsumerState<DocumentScreen> createState() => _DocumentScreenState();
}

class _DocumentScreenState extends ConsumerState<DocumentScreen> {
  /// Selected page ids, or `null` outside selection mode.
  Set<int>? _selection;

  int get _documentId => widget.documentId;

  Future<void> _rename(Document doc) async {
    final title = await promptText(
      context,
      title: 'Renommer',
      initial: doc.title,
    );
    if (title != null) await ref.read(repositoryProvider).rename(doc.id, title);
  }

  Future<void> _delete(Document doc) async {
    if (!await confirm(
      context,
      title: 'Supprimer ?',
      message: '« ${doc.title} » sera définitivement supprimé.',
    )) {
      return;
    }
    await ref.read(repositoryProvider).deleteDocument(doc.id);
    if (mounted) context.pop();
  }

  void _toggle(int pageId) => setState(() {
    final selection = _selection!;
    if (!selection.remove(pageId)) selection.add(pageId);
  });

  /// Selected pages in document order.
  List<DocPage> _selectedPages(List<DocPage> pages) => [
    for (final p in pages)
      if (_selection!.contains(p.id)) p,
  ];

  Future<void> _extract(List<DocPage> pages) async {
    final selected = _selectedPages(pages);
    final id = await runWithProgress(
      context,
      'Extraction…',
      () => ref.read(repositoryProvider).extractPages(_documentId, [
        for (final p in selected) p.id,
      ]),
    );
    if (id == null || !mounted) return;
    setState(() => _selection = null);
    context.push('/doc/$id');
  }

  Future<void> _deleteSelected(List<DocPage> pages) async {
    final selected = _selectedPages(pages);
    final count = selected.length;
    if (!await confirm(
      context,
      title: 'Supprimer $count page${count > 1 ? 's' : ''} ?',
      message: 'Elles seront retirées du document.',
    )) {
      return;
    }
    await ref.read(repositoryProvider).deletePages(_documentId, selected);
    if (mounted) setState(() => _selection = null);
  }

  PreferredSizeWidget _appBar(Document? document, List<DocPage> pages) {
    final selection = _selection;
    if (selection != null) {
      final count = selection.length;
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => setState(() => _selection = null),
        ),
        title: Text('$count page${count > 1 ? 's' : ''}'),
        actions: [
          TextButton(
            onPressed: () => setState(
              () => _selection = count == pages.length
                  ? {}
                  : {for (final p in pages) p.id},
            ),
            child: Text(count == pages.length ? 'Aucune' : 'Toutes'),
          ),
        ],
      );
    }
    return AppBar(
      title: GestureDetector(
        onTap: document == null ? null : () => _rename(document),
        child: Text(document?.title ?? ''),
      ),
      actions: [
        if (document != null)
          PopupMenuButton<String>(
            onSelected: (value) => switch (value) {
              'select' => setState(() => _selection = {}),
              'text' => context.push('/doc/$_documentId/text'),
              'rename' => _rename(document),
              'move' => moveDocument(context, ref, document),
              _ => _delete(document),
            },
            itemBuilder: (_) => [
              if (pages.isNotEmpty)
                const PopupMenuItem(
                  value: 'select',
                  child: Text('Sélectionner des pages'),
                ),
              if (pages.isNotEmpty)
                const PopupMenuItem(value: 'text', child: Text('Texte (OCR)')),
              const PopupMenuItem(value: 'rename', child: Text('Renommer')),
              const PopupMenuItem(value: 'move', child: Text('Déplacer')),
              const PopupMenuItem(value: 'delete', child: Text('Supprimer')),
            ],
          ),
      ],
    );
  }

  Widget _bottomBar(Document? document, List<DocPage> pages) {
    if (_selection case final selection?) {
      final none = selection.isEmpty;
      return BottomAppBar(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            TextButton.icon(
              onPressed: none ? null : () => _extract(pages),
              icon: const Icon(Icons.call_split),
              label: const Text('Extraire'),
            ),
            TextButton.icon(
              onPressed: none ? null : () => _deleteSelected(pages),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Supprimer'),
            ),
          ],
        ),
      );
    }
    return BottomAppBar(
      child: Row(
        children: [
          IconButton(
            tooltip: 'Scanner des pages',
            icon: const Icon(Icons.add_a_photo_outlined),
            onPressed: () =>
                addPagesFrom(context, ref, _documentId, PageSource.scanner),
          ),
          IconButton(
            tooltip: 'Importer des images',
            icon: const Icon(Icons.add_photo_alternate_outlined),
            onPressed: () =>
                addPagesFrom(context, ref, _documentId, PageSource.gallery),
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: document == null || pages.isEmpty
                ? null
                : () => showExportSheet(context, document),
            icon: const Icon(Icons.ios_share),
            label: const Text('Exporter'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final document = ref.watch(documentProvider(_documentId)).value;
    final pages = ref.watch(pagesProvider(_documentId));
    final items = pages.value ?? const <DocPage>[];

    return PopScope(
      canPop: _selection == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _selection = null);
      },
      child: Scaffold(
        appBar: _appBar(document, items),
        body: pages.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Erreur : $e')),
          data: (items) => items.isEmpty
              ? const Center(child: Text('Aucune page'))
              : _PageGrid(
                  documentId: _documentId,
                  pages: items,
                  selection: _selection,
                  onToggle: _toggle,
                ),
        ),
        bottomNavigationBar: _bottomBar(document, items),
      ),
    );
  }
}

class _PageGrid extends ConsumerWidget {
  const _PageGrid({
    required this.documentId,
    required this.pages,
    required this.selection,
    required this.onToggle,
  });

  final int documentId;
  final List<DocPage> pages;
  final Set<int>? selection;
  final void Function(int pageId) onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final files = ref.watch(fileStoreProvider);
    final theme = Theme.of(context);
    final selection = this.selection;

    Widget tile(int i) {
      final page = pages[i];
      return Card(
        key: ValueKey(page.id),
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        child: InkWell(
          onTap: selection != null
              ? () => onToggle(page.id)
              : () => context.push('/doc/$documentId/page/$i'),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.file(File(files.abs(page.thumbPath)), fit: BoxFit.contain),
              Positioned(
                left: 6,
                bottom: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    child: Text(
                      '${i + 1}',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onPrimary,
                      ),
                    ),
                  ),
                ),
              ),
              if (selection != null)
                SelectionMark(selected: selection.contains(page.id)),
            ],
          ),
        ),
      );
    }

    const gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 180,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 0.72,
    );
    const padding = EdgeInsets.all(12);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            selection != null
                ? 'Touche les pages à sélectionner'
                : '${pages.length} page${pages.length > 1 ? 's' : ''} · '
                      'appui long pour déplacer',
            style: theme.textTheme.bodySmall,
          ),
        ),
        Expanded(
          // Dragging is disabled while selecting so taps stay unambiguous.
          child: selection != null
              ? GridView.builder(
                  padding: padding,
                  gridDelegate: gridDelegate,
                  itemCount: pages.length,
                  itemBuilder: (context, i) => tile(i),
                )
              : ReorderableGridView.builder(
                  padding: padding,
                  gridDelegate: gridDelegate,
                  itemCount: pages.length,
                  onReorder: (from, to) {
                    final ids = [for (final p in pages) p.id];
                    ids.insert(to, ids.removeAt(from));
                    ref.read(repositoryProvider).reorderPages(documentId, ids);
                  },
                  itemBuilder: (context, i) => tile(i),
                ),
        ),
      ],
    );
  }
}
