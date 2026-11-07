import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../app/dialogs.dart';
import '../../app/providers.dart';
import '../../core/db/database.dart';
import '../../core/export/docx.dart';
import '../../core/ocr/ocr_line.dart';
import '../../core/pdf/exporter.dart';

enum ExportFormat {
  pdf('.pdf', 'application/pdf'),
  jpg('.jpg', 'image/jpeg'),
  txt('.txt', 'text/plain'),
  docx(
    '.docx',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  );

  const ExportFormat(this.extension, this.mimeType);

  /// Built from the recognised text rather than the page images.
  bool get isText => this == txt || this == docx;

  final String extension;
  final String mimeType;
}

Future<void> showExportSheet(BuildContext context, Document document) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ExportSheet(document: document),
  );
}

class _ExportSheet extends ConsumerStatefulWidget {
  const _ExportSheet({required this.document});

  final Document document;

  @override
  ConsumerState<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends ConsumerState<_ExportSheet> {
  late final _name = TextEditingController(text: widget.document.title);
  var _format = ExportFormat.pdf;
  var _layout = PageLayout.a4;
  var _quality = ExportQuality.high;
  final _password = TextEditingController();
  final _watermark = TextEditingController();
  var _protect = false;
  var _addWatermark = false;
  var _searchable = true;
  var _showPassword = false;

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    _watermark.dispose();
    super.dispose();
  }

  bool get _canExport =>
      _format != ExportFormat.pdf || !_protect || _password.text.isNotEmpty;

  String get _baseName => sanitizeFileName(_name.text);

  Future<List<File>> _build() async {
    final title = _name.text.trim();
    final repository = ref.read(repositoryProvider);
    if (title.isNotEmpty && title != widget.document.title) {
      await repository.rename(widget.document.id, title);
    }
    final id = widget.document.id;
    final files = ref.read(fileStoreProvider);
    if (_format.isText || (_format == ExportFormat.pdf && _searchable)) {
      await repository.recognizeDocument(id);
    }
    final pages = await repository.pages(id);
    if (pages.isEmpty) throw StateError('Le document est vide');
    final images = [for (final page in pages) files.abs(page.processedPath)];
    final dir = await files.freshExportDir();
    switch (_format) {
      case ExportFormat.txt:
        return [
          await File(
            p.join(dir.path, '$_baseName.txt'),
          ).writeAsString(await repository.documentText(id)),
        ];
      case ExportFormat.docx:
        return [
          await writeDocx(
            path: p.join(dir.path, '$_baseName.docx'),
            title: title,
            pages: [
              for (final page in pages)
                if (page.ocrText?.trim().isNotEmpty ?? false) page.ocrText!,
            ],
          ),
        ];
      case ExportFormat.pdf:
        return [
          await exportPdf(
            images: images,
            textLayers: _searchable
                ? [for (final page in pages) OcrLine.decode(page.ocrLines)]
                : null,
            outputPath: p.join(dir.path, '$_baseName.pdf'),
            title: title,
            quality: _quality,
            layout: _layout,
            password: _protect ? _password.text : null,
            watermark: _addWatermark ? _watermark.text : null,
          ),
        ];
      case ExportFormat.jpg:
        return exportJpegs(
          images: images,
          outputDir: dir.path,
          baseName: _baseName,
          quality: _quality,
        );
    }
  }

  String get _mimeType => _format.mimeType;

  Future<void> _share() async {
    final files = await runWithProgress(context, 'Préparation…', _build);
    if (files == null) return;
    await SharePlus.instance.share(
      ShareParams(
        files: [for (final f in files) XFile(f.path, mimeType: _mimeType)],
        title: _name.text.trim(),
      ),
    );
  }

  Future<void> _save() async {
    final files = await runWithProgress(context, 'Préparation…', _build);
    if (files == null) return;
    var saved = 0;
    for (final file in files) {
      final uri = await FilePicker.saveFile(
        fileName: p.basename(file.path),
        bytes: await file.readAsBytes(),
        mimeType: _mimeType,
      );
      if (uri == null) break;
      saved++;
    }
    if (!mounted || saved == 0) return;
    Navigator.pop(context);
    showMessage(
      context,
      saved == 1 ? 'Fichier enregistré' : '$saved fichiers enregistrés',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Exporter', style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            decoration: InputDecoration(
              labelText: 'Nom du fichier',
              suffixText: _format.extension,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          _label('Format'),
          SegmentedButton<ExportFormat>(
            segments: const [
              ButtonSegment(
                value: ExportFormat.pdf,
                label: Text('PDF'),
                icon: Icon(Icons.picture_as_pdf_outlined),
              ),
              ButtonSegment(
                value: ExportFormat.jpg,
                label: Text('JPG'),
                icon: Icon(Icons.image_outlined),
              ),
              ButtonSegment(
                value: ExportFormat.txt,
                label: Text('Texte'),
                icon: Icon(Icons.text_snippet_outlined),
              ),
              ButtonSegment(
                value: ExportFormat.docx,
                label: Text('Word'),
                icon: Icon(Icons.description_outlined),
              ),
            ],
            showSelectedIcon: false,
            selected: {_format},
            onSelectionChanged: (s) => setState(() => _format = s.first),
          ),
          if (_format == ExportFormat.pdf) ...[
            const SizedBox(height: 12),
            _label('Taille des pages'),
            SegmentedButton<PageLayout>(
              segments: const [
                ButtonSegment(value: PageLayout.a4, label: Text('A4')),
                ButtonSegment(
                  value: PageLayout.fitImage,
                  label: Text('Taille de l\'image'),
                ),
              ],
              selected: {_layout},
              onSelectionChanged: (s) => setState(() => _layout = s.first),
            ),
          ],
          if (!_format.isText) ...[
            const SizedBox(height: 12),
            _label('Qualité'),
            SegmentedButton<ExportQuality>(
              segments: const [
                ButtonSegment(value: ExportQuality.high, label: Text('Haute')),
                ButtonSegment(
                  value: ExportQuality.medium,
                  label: Text('Moyenne'),
                ),
                ButtonSegment(value: ExportQuality.low, label: Text('Légère')),
              ],
              selected: {_quality},
              onSelectionChanged: (s) => setState(() => _quality = s.first),
            ),
          ],
          if (_format == ExportFormat.pdf) ...[
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Texte cherchable (OCR)'),
              subtitle: const Text(
                'Permet de chercher et copier le texte dans le PDF',
              ),
              value: _searchable,
              onChanged: (v) => setState(() => _searchable = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Protéger par mot de passe'),
              value: _protect,
              onChanged: (v) => setState(() => _protect = v),
            ),
            if (_protect)
              TextField(
                controller: _password,
                obscureText: !_showPassword,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Mot de passe',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _showPassword ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () =>
                        setState(() => _showPassword = !_showPassword),
                  ),
                ),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Ajouter un filigrane'),
              subtitle: const Text('Ton propre texte, en travers des pages'),
              value: _addWatermark,
              onChanged: (v) => setState(() => _addWatermark = v),
            ),
            if (_addWatermark)
              TextField(
                controller: _watermark,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Texte du filigrane',
                  hintText: 'Ex. : Copie conforme',
                  border: OutlineInputBorder(),
                ),
              ),
          ],
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _canExport ? _save : null,
                  icon: const Icon(Icons.save_alt),
                  label: const Text('Enregistrer'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _canExport ? _share : null,
                  icon: const Icon(Icons.share),
                  label: const Text('Partager'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: Theme.of(context).textTheme.labelLarge),
  );
}
