import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/dialogs.dart';
import '../../app/providers.dart';
import '../../core/db/database.dart';
import '../../core/imaging/crop_quad.dart';
import '../signature/signature_flow.dart';
import '../../core/imaging/page_overlay.dart';
import 'annotate_screen.dart';
import 'crop_screen.dart';

const filterLabels = {
  PageFilter.original: 'Original',
  PageFilter.enhanced: 'Amélioré',
  PageFilter.grayscale: 'Gris',
  PageFilter.blackWhite: 'Noir & blanc',
  PageFilter.whiteboard: 'Tableau blanc',
};

class PageScreen extends ConsumerStatefulWidget {
  const PageScreen({
    super.key,
    required this.documentId,
    required this.initialIndex,
  });

  final int documentId;
  final int initialIndex;

  @override
  ConsumerState<PageScreen> createState() => _PageScreenState();
}

class _PageScreenState extends ConsumerState<PageScreen> {
  late final _controller = PageController(initialPage: widget.initialIndex);
  late var _index = widget.initialIndex;
  var _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _edit(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) showMessage(context, 'Erreur : $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sign(DocPage page) async {
    final overlay = await pickAndPlaceSignature(
      context,
      ref,
      ref.read(fileStoreProvider).abs(page.processedPath),
    );
    if (overlay != null) {
      await _edit(() => ref.read(repositoryProvider).addOverlay(page, overlay));
    }
  }

  Future<void> _annotate(DocPage page) async {
    final files = ref.read(fileStoreProvider);
    final png = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => AnnotateScreen(
          pageImage: files.abs(page.processedPath),
          tempDir: files.tempRoot.path,
        ),
      ),
    );
    if (png == null) return;
    await _edit(
      () => ref
          .read(repositoryProvider)
          .addOverlay(
            page,
            PageOverlay(imagePath: png, left: 0, top: 0, width: 1, height: 1),
          ),
    );
    // addOverlay keeps its own copy in the document folder.
    await File(png).delete();
  }

  Future<void> _clearOverlays(DocPage page) async {
    if (await confirm(
      context,
      title: 'Retirer les ajouts ?',
      message: 'Les signatures et annotations de cette page seront retirées.',
      confirmLabel: 'Retirer',
    )) {
      await _edit(() => ref.read(repositoryProvider).clearOverlays(page));
    }
  }

  Future<void> _crop(DocPage page) async {
    final crop = await Navigator.of(context).push<CropQuad>(
      MaterialPageRoute(
        builder: (_) => CropScreen(
          original: ref.read(fileStoreProvider).abs(page.originalPath),
          quarterTurns: page.rotation,
          initial: CropQuad.decode(page.crop),
        ),
      ),
    );
    if (crop != null && CropQuad.encode(crop) != page.crop) {
      await _edit(() => ref.read(repositoryProvider).setCrop(page, crop));
    }
  }

  Future<void> _delete(DocPage page, int count) async {
    if (!await confirm(
      context,
      title: 'Supprimer la page ?',
      message: 'Cette page sera retirée du document.',
    )) {
      return;
    }
    await _edit(() => ref.read(repositoryProvider).deletePage(page));
    if (mounted && count == 1) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final pages = ref.watch(pagesProvider(widget.documentId)).value ?? const [];
    final files = ref.watch(fileStoreProvider);
    final repository = ref.read(repositoryProvider);
    if (pages.isEmpty) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final index = _index.clamp(0, pages.length - 1);
    final page = pages[index];

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('Page ${index + 1} / ${pages.length}'),
        actions: [
          IconButton(
            tooltip: 'Texte de la page',
            icon: const Icon(Icons.text_snippet_outlined),
            onPressed: () =>
                context.push('/doc/${widget.documentId}/text?page=${page.id}'),
          ),
          IconButton(
            tooltip: 'Supprimer la page',
            icon: const Icon(Icons.delete_outline),
            onPressed: _busy ? null : () => _delete(page, pages.length),
          ),
        ],
      ),
      body: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            itemCount: pages.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) => InteractiveViewer(
              maxScale: 5,
              child: Center(
                child: Image.file(
                  File(files.abs(pages[i].processedPath)),
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
              ),
            ),
          ),
          if (_busy)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(),
            ),
        ],
      ),
      bottomNavigationBar: Material(
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      for (final filter in PageFilter.values)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(filterLabels[filter]!),
                            selected: page.filter == filter,
                            onSelected: _busy || page.filter == filter
                                ? null
                                : (_) => _edit(
                                    () => repository.setFilter(page, filter),
                                  ),
                          ),
                        ),
                    ],
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _Tool(
                      icon: Icons.rotate_right,
                      label: 'Pivoter',
                      onPressed: _busy
                          ? null
                          : () => _edit(() => repository.rotate(page, 1)),
                    ),
                    _Tool(
                      icon: Icons.crop,
                      label: 'Recadrer',
                      onPressed: _busy ? null : () => _crop(page),
                    ),
                    _Tool(
                      icon: Icons.draw_outlined,
                      label: 'Signer',
                      onPressed: _busy ? null : () => _sign(page),
                    ),
                    _Tool(
                      icon: Icons.edit_note,
                      label: 'Annoter',
                      onPressed: _busy ? null : () => _annotate(page),
                    ),
                    if (page.overlays != null)
                      _Tool(
                        icon: Icons.layers_clear_outlined,
                        label: 'Retirer',
                        onPressed: _busy ? null : () => _clearOverlays(page),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Tool extends StatelessWidget {
  const _Tool({required this.icon, required this.label, this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      minimumSize: const Size(56, 48),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon),
        const SizedBox(height: 2),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    ),
  );
}
