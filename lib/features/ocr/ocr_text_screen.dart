import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/dialogs.dart';
import '../../app/providers.dart';
import 'translate_screen.dart';

/// Recognised text of one page ([pageId]) or of the whole document. Runs
/// recognition first for pages that have none yet.
class OcrTextScreen extends ConsumerStatefulWidget {
  const OcrTextScreen({super.key, required this.documentId, this.pageId});

  final int documentId;
  final int? pageId;

  @override
  ConsumerState<OcrTextScreen> createState() => _OcrTextScreenState();
}

class _OcrTextScreenState extends ConsumerState<OcrTextScreen> {
  String? _text;
  String? _error;
  String _progress = '';
  var _running = false;

  @override
  void initState() {
    super.initState();
    _load(force: false);
  }

  Future<void> _load({required bool force}) async {
    setState(() {
      _running = true;
      _error = null;
      _progress = '';
    });
    final repository = ref.read(repositoryProvider);
    final db = ref.read(databaseProvider);
    try {
      final String text;
      if (widget.pageId case final pageId?) {
        final page = (await db.getPagesById([pageId])).single;
        if (force || page.ocrText == null) await repository.recognizePage(page);
        text = (await db.getPagesById([pageId])).single.ocrText ?? '';
      } else {
        await repository.recognizeDocument(
          widget.documentId,
          force: force,
          onProgress: (done, total) {
            if (mounted) {
              setState(() => _progress = 'Page ${done + 1} / $total');
            }
          },
        );
        text = await repository.documentText(widget.documentId);
      }
      if (mounted) setState(() => _text = text.trim());
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    final hasText = text != null && text.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.pageId == null ? 'Texte du document' : 'Texte de la page',
        ),
        actions: [
          IconButton(
            tooltip: 'Copier',
            icon: const Icon(Icons.copy),
            onPressed: !hasText
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: text));
                    if (context.mounted) showMessage(context, 'Texte copié');
                  },
          ),
          IconButton(
            tooltip: 'Traduire',
            icon: const Icon(Icons.translate),
            onPressed: !hasText
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => TranslateScreen(text: text),
                    ),
                  ),
          ),
          IconButton(
            tooltip: 'Partager',
            icon: const Icon(Icons.share),
            onPressed: !hasText
                ? null
                : () => SharePlus.instance.share(ShareParams(text: text)),
          ),
          PopupMenuButton<String>(
            enabled: !_running,
            onSelected: (_) => _load(force: true),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'redo',
                child: Text('Relancer la reconnaissance'),
              ),
            ],
          ),
        ],
      ),
      body: _running
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text('Reconnaissance du texte… $_progress'),
                ],
              ),
            )
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Erreur : $_error', textAlign: TextAlign.center),
              ),
            )
          : !hasText
          ? const Center(child: Text('Aucun texte détecté.'))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                text,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
    );
  }
}
