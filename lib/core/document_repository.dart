import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import 'db/database.dart';
import 'imaging/compose.dart';
import 'imaging/crop_quad.dart';
import 'imaging/page_overlay.dart';
import 'imaging/page_renderer.dart';
import 'ocr/ocr_line.dart';
import 'ocr/search_text.dart';
import 'ocr/text_recognition.dart';
import 'pdf/pdf_import.dart';
import 'storage/file_store.dart';

/// Keeps the database rows and the page files on disk in sync.
class DocumentRepository {
  DocumentRepository(this._db, this._files, [this._ocr]);

  final AppDatabase _db;
  final FileStore _files;
  final TextRecognition? _ocr;

  /// Serialises background recognition so pages are processed one at a time.
  Future<void> _ocrQueue = Future.value();

  static String defaultTitle() =>
      'Scan ${DateFormat('yyyy-MM-dd HH.mm').format(DateTime.now())}';

  Future<int> createDocument(
    List<String> sourceImages, {
    PageFilter filter = PageFilter.original,
    int? folderId,
    String? title,
  }) async {
    final id = await _db.createDocument(
      title ?? defaultTitle(),
      folderId: folderId,
    );
    await addPages(id, sourceImages, filter: filter);
    return id;
  }

  /// Creates a document from images and PDFs (each PDF page becomes a page).
  /// A single PDF gives its name to the document. [askPassword] is called for
  /// protected PDFs until it returns the right password or `null`.
  Future<int> importFiles(
    List<String> paths, {
    PageFilter filter = PageFilter.original,
    int? folderId,
    FutureOr<String?> Function(String fileName)? askPassword,
  }) async {
    final scratch = await _files.freshExportDir();
    final images = <String>[];
    for (final (i, path) in paths.indexed) {
      if (isPdf(path)) {
        final dir = await Directory(p.join(scratch.path, '$i')).create();
        images.addAll(
          await rasterizePdf(
            path,
            dir.path,
            askPassword: askPassword == null
                ? null
                : () => askPassword(p.basename(path)),
          ),
        );
      } else {
        images.add(path);
      }
    }
    if (images.isEmpty) throw StateError('Aucune page à importer');
    final pdfs = paths.where(isPdf).toList();
    return createDocument(
      images,
      filter: filter,
      folderId: folderId,
      title: paths.length == 1 && pdfs.length == 1
          ? p.basenameWithoutExtension(pdfs.single)
          : null,
    );
  }

  static bool isPdf(String path) => p.extension(path).toLowerCase() == '.pdf';

  static String _dated(String label) =>
      '$label ${DateFormat('yyyy-MM-dd HH.mm').format(DateTime.now())}';

  /// One A4 page with the front (and back) of a card at real size.
  Future<int> createIdCardDocument(
    List<String> sides, {
    PageFilter filter = PageFilter.original,
    int? folderId,
  }) async {
    final scratch = await _files.freshExportDir();
    final target = p.join(scratch.path, 'carte.jpg');
    await composeIdCard(
      front: sides.first,
      back: sides.elementAtOrNull(1),
      target: target,
    );
    return createDocument(
      [target],
      filter: filter,
      folderId: folderId,
      title: _dated('Carte'),
    );
  }

  /// Each photo of an open book becomes its left and right pages.
  Future<int> createBookDocument(
    List<String> spreads, {
    PageFilter filter = PageFilter.original,
    int? folderId,
  }) async {
    final scratch = await _files.freshExportDir();
    final pages = <String>[];
    for (final (i, spread) in spreads.indexed) {
      pages.addAll(await splitSpread(spread, scratch.path, 'p$i'));
    }
    return createDocument(
      pages,
      filter: filter,
      folderId: folderId,
      title: _dated('Livre'),
    );
  }

  Future<void> addPages(
    int documentId,
    List<String> sourceImages, {
    PageFilter filter = PageFilter.original,
  }) async {
    await _files.ensureDocumentDir(documentId);
    var position = await _db.nextPosition(documentId);
    for (final source in sourceImages) {
      final stem = _newStem();
      final original = p.join(
        _files.documentDir(documentId),
        '${stem}_orig${p.extension(source).toLowerCase()}',
      );
      await File(source).copy(_files.abs(original));
      final rendered = await _render(
        documentId: documentId,
        original: original,
        stem: stem,
        rotation: 0,
        filter: filter,
        overlays: const [],
      );
      await _db.insertPage(
        PagesCompanion.insert(
          documentId: documentId,
          position: position++,
          originalPath: original,
          processedPath: rendered.$1,
          thumbPath: rendered.$2,
          filter: filter,
        ),
      );
    }
    await _db.touchDocument(documentId);
  }

  Future<void> setFilter(DocPage page, PageFilter filter) =>
      _rerender(page, filter: filter);

  Future<void> rotate(DocPage page, int quarterTurns) =>
      _rerender(page, rotation: (page.rotation + quarterTurns) % 4);

  /// Straightens [crop] of the original image; `null` restores the full image.
  Future<void> setCrop(DocPage page, CropQuad? crop) =>
      _rerender(page, crop: CropQuad.encode(crop), cropChanged: true);

  /// Places a copy of [imagePath] (a signature) over the page.
  Future<void> addOverlay(DocPage page, PageOverlay overlay) async {
    final copy = p.join(
      _files.documentDir(page.documentId),
      '${_newStem()}_sig${p.extension(overlay.imagePath)}',
    );
    await File(overlay.imagePath).copy(_files.abs(copy));
    await _rerender(
      page,
      overlays: [...PageOverlay.decode(page.overlays), overlay.withImage(copy)],
    );
  }

  Future<void> clearOverlays(DocPage page) async {
    final overlays = PageOverlay.decode(page.overlays);
    await _rerender(page, overlays: const []);
    await _files.deleteFiles([for (final o in overlays) o.imagePath]);
  }

  Future<void> _rerender(
    DocPage page, {
    int? rotation,
    PageFilter? filter,
    List<PageOverlay>? overlays,
    String? crop,
    bool cropChanged = false,
  }) async {
    rotation ??= page.rotation;
    filter ??= page.filter;
    overlays ??= PageOverlay.decode(page.overlays);
    if (!cropChanged) crop = page.crop;
    final rendered = await _render(
      documentId: page.documentId,
      original: page.originalPath,
      stem: _newStem(),
      rotation: rotation,
      filter: filter,
      overlays: overlays,
      crop: crop,
    );
    // Line positions are only valid for the geometry they were read in.
    final moved = rotation != page.rotation || crop != page.crop;
    await _db.updatePage(
      page.id,
      PagesCompanion(
        rotation: Value(rotation),
        filter: Value(filter),
        overlays: Value(PageOverlay.encode(overlays)),
        crop: Value(crop),
        processedPath: Value(rendered.$1),
        thumbPath: Value(rendered.$2),
        ocrText: moved ? const Value(null) : const Value.absent(),
        ocrLines: moved ? const Value(null) : const Value.absent(),
        searchText: moved ? const Value(null) : const Value.absent(),
      ),
    );
    await _db.touchDocument(page.documentId);
    await _files.deleteFiles([page.processedPath, page.thumbPath]);
  }

  Future<void> deletePage(DocPage page) => deletePages(page.documentId, [page]);

  Future<void> deletePages(int documentId, List<DocPage> pages) async {
    for (final page in pages) {
      await _db.deletePage(page.id);
    }
    final remaining = await _db.getPages(documentId);
    await _db.reorderPages([for (final p in remaining) p.id]);
    await _db.touchDocument(documentId);
    await _files.deleteFiles([for (final page in pages) ..._filesOf(page)]);
  }

  Future<void> reorderPages(int documentId, List<int> orderedIds) async {
    await _db.reorderPages(orderedIds);
    await _db.touchDocument(documentId);
  }

  /// Copies [pageIds] (in that order) into a new document and returns its id.
  Future<int> extractPages(int documentId, List<int> pageIds) async {
    final source = await _db.getDocument(documentId);
    final id = await _db.createDocument(
      '${source?.title ?? defaultTitle()} (extrait)',
      folderId: source?.folderId,
    );
    await _copyPages(await _db.getPagesById(pageIds), id);
    return id;
  }

  /// Concatenates the pages of [documentIds] into a new document placed in
  /// the folder of the first one.
  Future<int> mergeDocuments(
    List<int> documentIds, {
    bool deleteSources = false,
  }) async {
    final first = await _db.getDocument(documentIds.first);
    final id = await _db.createDocument(
      '${first?.title ?? defaultTitle()} (fusion)',
      folderId: first?.folderId,
    );
    for (final documentId in documentIds) {
      await _copyPages(await _db.getPages(documentId), id);
    }
    if (deleteSources) {
      for (final documentId in documentIds) {
        await deleteDocument(documentId);
      }
    }
    return id;
  }

  Future<void> _copyPages(List<DocPage> pages, int targetId) async {
    await _files.ensureDocumentDir(targetId);
    final dir = _files.documentDir(targetId);
    var position = await _db.nextPosition(targetId);
    Future<String> copy(String relative) async {
      final target = p.join(dir, '${_newStem()}_${p.basename(relative)}');
      await File(_files.abs(relative)).copy(_files.abs(target));
      return target;
    }

    for (final page in pages) {
      final overlays = [
        for (final o in PageOverlay.decode(page.overlays))
          o.withImage(await copy(o.imagePath)),
      ];
      await _db.insertPage(
        PagesCompanion.insert(
          documentId: targetId,
          position: position++,
          originalPath: await copy(page.originalPath),
          processedPath: await copy(page.processedPath),
          thumbPath: await copy(page.thumbPath),
          rotation: Value(page.rotation),
          filter: page.filter,
          overlays: Value(PageOverlay.encode(overlays)),
          ocrText: Value(page.ocrText),
          ocrLines: Value(page.ocrLines),
          searchText: Value(page.searchText),
          crop: Value(page.crop),
        ),
      );
    }
    await _db.touchDocument(targetId);
  }

  Future<void> rename(int documentId, String title) =>
      _db.renameDocument(documentId, title);

  Future<void> move(int documentId, int? folderId) =>
      _db.moveDocument(documentId, folderId);

  Future<int> createFolder(String name) => _db.createFolder(name);

  Future<void> renameFolder(int folderId, String name) =>
      _db.renameFolder(folderId, name);

  Future<void> deleteFolder(int folderId) => _db.deleteFolder(folderId);

  Future<void> deleteDocument(int documentId) async {
    await _db.deleteDocument(documentId);
    await _files.deleteDocumentFiles(documentId);
  }

  Future<List<DocPage>> pages(int documentId) => _db.getPages(documentId);

  /// Recognises the text of [page] and stores it with the line positions.
  Future<void> recognizePage(DocPage page) async {
    final ocr = _ocr;
    if (ocr == null) throw StateError('Reconnaissance de texte indisponible');
    final result = await ocr.recognize(_files.abs(page.processedPath));
    // Skip the write if the page was re-rendered (rotated…) meanwhile.
    final current = (await _db.getPagesById([page.id])).firstOrNull;
    if (current == null || current.processedPath != page.processedPath) return;
    await _db.updatePage(
      page.id,
      PagesCompanion(
        ocrText: Value(result.text),
        ocrLines: Value(OcrLine.encode(result.lines)),
        searchText: Value(normalizeForSearch(result.text)),
      ),
    );
  }

  /// Recognises every page that has no text yet (all pages with [force]).
  Future<void> recognizeDocument(
    int documentId, {
    bool force = false,
    void Function(int done, int total)? onProgress,
  }) async {
    final todo = [
      for (final page in await _db.getPages(documentId))
        if (force || page.ocrText == null) page,
    ];
    for (final (i, page) in todo.indexed) {
      onProgress?.call(i, todo.length);
      await recognizePage(page);
    }
  }

  /// Queues [recognizeDocument] without waiting for it; failures are ignored
  /// since the user can run recognition again by hand.
  void recognizeInBackground(int documentId) {
    if (_ocr == null) return;
    _ocrQueue = _ocrQueue
        .then((_) => recognizeDocument(documentId))
        .catchError((Object _) {});
  }

  /// Text of every page, separated by page headings.
  Future<String> documentText(int documentId) async {
    final pages = await _db.getPages(documentId);
    return [
      for (final (i, page) in pages.indexed)
        if (page.ocrText?.trim().isNotEmpty ?? false)
          '— Page ${i + 1} —\n${page.ocrText!.trim()}',
    ].join('\n\n');
  }

  Iterable<String> _filesOf(DocPage page) => [
    page.originalPath,
    page.processedPath,
    page.thumbPath,
    for (final o in PageOverlay.decode(page.overlays)) o.imagePath,
  ];

  Future<(String, String)> _render({
    required int documentId,
    required String original,
    required String stem,
    required int rotation,
    required PageFilter filter,
    required List<PageOverlay> overlays,
    String? crop,
  }) async {
    final dir = _files.documentDir(documentId);
    final processed = p.join(dir, '$stem.jpg');
    final thumb = p.join(dir, '${stem}_t.jpg');
    await renderPage(
      PageRenderJob(
        source: _files.abs(original),
        target: _files.abs(processed),
        thumb: _files.abs(thumb),
        quarterTurns: rotation,
        filter: filter,
        overlays: [
          for (final o in overlays) o.withImage(_files.abs(o.imagePath)),
        ],
        crop: CropQuad.decode(crop),
      ),
    );
    return (processed, thumb);
  }

  var _stemCounter = 0;

  /// Unique per render so a changed page never hits Flutter's image cache.
  String _newStem() =>
      '${DateTime.now().microsecondsSinceEpoch}_${_stemCounter++}';
}
