import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:scan/core/backup.dart';
import 'package:scan/core/db/database.dart';
import 'package:scan/core/document_repository.dart';
import 'package:scan/core/export/docx.dart';
import 'package:scan/core/imaging/crop_quad.dart';
import 'package:scan/core/imaging/page_overlay.dart';
import 'package:scan/core/imaging/page_renderer.dart';
import 'package:scan/core/ocr/ocr_line.dart';
import 'package:scan/core/ocr/text_recognition.dart';
import 'package:scan/core/pdf/exporter.dart';
import 'package:scan/core/storage/file_store.dart';

/// A grey, unevenly lit "paper" with a dark block of "text".
String _fakeScan(Directory dir, {int w = 1200, int h = 1600}) {
  final image = img.Image(width: w, height: h);
  for (final px in image) {
    final light = 150 + 80 * px.x / w;
    final ink = px.x > 200 && px.x < 1000 && px.y > 300 && px.y < 340;
    final v = ink ? light * 0.3 : light;
    px.setRgb(v, v, v * 0.95);
  }
  final path = p.join(dir.path, 'scan_${dir.listSync().length}.jpg');
  File(path).writeAsBytesSync(img.encodeJpg(image));
  return path;
}

void main() {
  group('phase 2', phase2Tests);
  group('phase 3', phase3Tests);
  group('phase 4', phase4Tests);
  group('phase 5', phase5Tests);
  group('phase 6', phase6Tests);

  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('scan_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('filters whiten the paper and keep the ink dark', () async {
    final source = _fakeScan(tmp);
    for (final filter in PageFilter.values) {
      final target = p.join(tmp.path, '${filter.name}.jpg');
      await renderPage(
        PageRenderJob(
          source: source,
          target: target,
          thumb: p.join(tmp.path, '${filter.name}_t.jpg'),
          quarterTurns: 1,
          filter: filter,
        ),
      );
      final out = img.decodeJpg(File(target).readAsBytesSync())!;
      expect(out.width, 1600, reason: 'rotated a quarter turn');
      if (filter == PageFilter.enhanced || filter == PageFilter.blackWhite) {
        // Paper on the dark left edge of the original (now the top).
        expect(out.getPixel(800, 100).luminance, greaterThan(230));
        // Ink row y=320 becomes column x = h - 1 - 320.
        expect(out.getPixel(1600 - 1 - 320, 600).luminance, lessThan(80));
      }
    }
  });

  test('PDF has one page per image and no foreign branding', () async {
    final images = [_fakeScan(tmp), _fakeScan(tmp, w: 1600, h: 1200)];
    final pdf = await exportPdf(
      images: images,
      outputPath: p.join(tmp.path, 'out.pdf'),
      title: 'Test',
      quality: ExportQuality.medium,
      layout: PageLayout.a4,
    );
    final raw = String.fromCharCodes(pdf.readAsBytesSync());
    expect(RegExp(r'/Type\s*/Page\b').allMatches(raw).length, 2);
    expect(raw.toLowerCase(), isNot(contains('evaluation')));
  });

  test('repository keeps pages ordered and cleans files', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final files = FileStore(
      Directory(p.join(tmp.path, 'root'))..createSync(),
      tmp,
    );
    final repo = DocumentRepository(db, files);
    final id = await repo.createDocument([_fakeScan(tmp), _fakeScan(tmp)]);
    await repo.addPages(id, [_fakeScan(tmp)]);

    var pages = await db.getPages(id);
    expect(pages.map((p) => p.position), [0, 1, 2]);

    await repo.reorderPages(id, [pages[2].id, pages[0].id, pages[1].id]);
    await repo.deletePage((await db.getPages(id)).first);
    pages = await db.getPages(id);
    expect(pages.map((p) => p.position), [0, 1]);

    await repo.setFilter(pages.first, PageFilter.blackWhite);
    final docDir = Directory(files.abs(files.documentDir(id)));
    // 2 pages × (original + processed + thumbnail), nothing left behind.
    expect(docDir.listSync().length, 6);

    await repo.deleteDocument(id);
    expect(docDir.existsSync(), isFalse);
    await db.close();
  });
}

void phase2Tests() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('scan_test2'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('v1 database is migrated without losing documents', () async {
    final file = File(p.join(tmp.path, 'v1.sqlite'));
    final raw = sqlite3.open(file.path);
    raw.execute('''
      CREATE TABLE documents (id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL, created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL);
      CREATE TABLE pages (id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        document_id INTEGER NOT NULL REFERENCES documents (id) ON DELETE CASCADE,
        position INTEGER NOT NULL, original_path TEXT NOT NULL,
        processed_path TEXT NOT NULL, thumb_path TEXT NOT NULL,
        rotation INTEGER NOT NULL DEFAULT 0, filter INTEGER NOT NULL);
      INSERT INTO documents (title, created_at, updated_at) VALUES ('Ancien', 1, 1);
      PRAGMA user_version = 1;
    ''');
    raw.close();

    final db = AppDatabase(NativeDatabase(file));
    final docs = await db.watchDocuments().first;
    expect(docs.single.document.title, 'Ancien');
    expect(docs.single.document.folderId, isNull);
    expect(await db.getFolders(), isEmpty);
    await db.close();
  });

  test('folders, search and sort', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final folder = await db.createFolder('Factures');
    await db.createDocument('Zèbre');
    await db.createDocument('abc 100%', folderId: folder);
    await db.createDocument('Avis', folderId: folder);

    final root = await db.watchDocuments().first;
    expect(root.map((d) => d.document.title), ['Zèbre']);

    final inFolder = await db
        .watchDocuments(folderId: folder, sort: DocumentSort.title)
        .first;
    expect(inFolder.map((d) => d.document.title), ['abc 100%', 'Avis']);

    // Search spans every folder and treats % literally.
    expect((await db.watchDocuments(search: '0%').first).length, 1);
    expect((await db.watchDocuments(search: 'a').first).length, 2);

    final folders = await db.watchFolders().first;
    expect(folders.single.documentCount, 2);

    await db.deleteFolder(folder);
    expect((await db.watchDocuments().first).length, 3);
    await db.close();
  });

  test('backup then restore brings the library back', () async {
    final root = Directory(p.join(tmp.path, 'scan'))..createSync();
    final files = FileStore(root, tmp);
    final db = AppDatabase(NativeDatabase(File(files.databasePath)));
    final repo = DocumentRepository(db, files);
    final backup = BackupService(db, files);

    final folder = await db.createFolder('Perso');
    final id = await repo.createDocument([
      _fakeScan(tmp),
      _fakeScan(tmp),
    ], folderId: folder);
    final zip = await backup.create();
    final saved = File(p.join(tmp.path, 'saved.zip'));
    await zip.copy(saved.path);

    await repo.deleteDocument(id);
    await db.deleteFolder(folder);
    await repo.createDocument([_fakeScan(tmp)]);

    await backup.restore(saved.path);
    final docs = await db.watchDocuments(folderId: folder).first;
    expect(docs.single.pageCount, 2);
    for (final page in await db.getPages(id)) {
      expect(File(files.abs(page.processedPath)).existsSync(), isTrue);
    }
    expect((await db.watchDocuments().first), isEmpty);
    await db.close();
  });
}

/// A black 200×100 "signature" on a transparent background.
String _fakeSignature(Directory dir) {
  final image = img.Image(width: 200, height: 100, numChannels: 4);
  img.fillRect(
    image,
    x1: 20,
    y1: 40,
    x2: 180,
    y2: 60,
    color: img.ColorRgba8(0, 0, 0, 255),
  );
  final path = p.join(dir.path, 'sig.png');
  File(path).writeAsBytesSync(img.encodePng(image));
  return path;
}

void phase3Tests() {
  late Directory tmp;
  late AppDatabase db;
  late FileStore files;
  late DocumentRepository repo;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('scan_test3');
    db = AppDatabase(NativeDatabase.memory());
    files = FileStore(Directory(p.join(tmp.path, 'root'))..createSync(), tmp);
    repo = DocumentRepository(db, files);
  });
  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  test('signature is drawn on the page and survives a filter change', () async {
    final id = await repo.createDocument([_fakeScan(tmp)]);
    var page = (await db.getPages(id)).single;
    await repo.addOverlay(
      page,
      PageOverlay(
        imagePath: _fakeSignature(tmp),
        left: 0.5,
        top: 0.8,
        width: 0.4,
        height: 0.4 * 1200 / 1600 / 2,
      ),
    );
    page = (await db.getPages(id)).single;
    await repo.setFilter(page, PageFilter.enhanced);
    page = (await db.getPages(id)).single;
    expect(PageOverlay.decode(page.overlays), hasLength(1));

    final out = img.decodeJpg(
      File(files.abs(page.processedPath)).readAsBytesSync(),
    )!;
    // Centre of the ink bar: x = 0.5 + 0.4 * 100/200, y = 0.8 + h * 50/100.
    final ink = out.getPixel(
      (0.7 * 1200).round(),
      (0.8 * 1600 + 0.15 * 1600 * 0.5).round(),
    );
    expect(ink.luminance, lessThan(60));

    await repo.clearOverlays(page);
    page = (await db.getPages(id)).single;
    expect(page.overlays, isNull);
    // original + processed + thumbnail, signature copy removed.
    expect(
      Directory(files.abs(files.documentDir(id))).listSync(),
      hasLength(3),
    );
  });

  test('merge and extract copy pages with their files', () async {
    final a = await repo.createDocument([_fakeScan(tmp), _fakeScan(tmp)]);
    final b = await repo.createDocument([_fakeScan(tmp)]);
    final merged = await repo.mergeDocuments([b, a]);
    final pages = await db.getPages(merged);
    expect(pages, hasLength(3));
    expect(pages.map((p) => p.position), [0, 1, 2]);

    final extracted = await repo.extractPages(merged, [
      pages[2].id,
      pages[0].id,
    ]);
    expect(await db.getPages(extracted), hasLength(2));
    expect((await db.getDocument(extracted))!.title, endsWith('(extrait)'));

    // Sources are untouched, then can be removed with the merge.
    await repo.mergeDocuments([a, b], deleteSources: true);
    expect(await db.getDocument(a), isNull);
    expect(Directory(files.abs(files.documentDir(a))).existsSync(), isFalse);
    for (final page in await db.getPages(extracted)) {
      expect(File(files.abs(page.processedPath)).existsSync(), isTrue);
    }
  });

  test('PDF can be encrypted and watermarked', () async {
    final pdf = await exportPdf(
      images: [_fakeScan(tmp)],
      outputPath: p.join(tmp.path, 'secret.pdf'),
      title: 'Secret',
      quality: ExportQuality.low,
      layout: PageLayout.a4,
      password: '1234',
      watermark: 'Copie conforme',
    );
    final raw = String.fromCharCodes(pdf.readAsBytesSync());
    expect(raw, contains('/Encrypt'));
  });
}

class _FakeOcr implements TextRecognition {
  var calls = 0;

  @override
  Future<OcrResult> recognize(String imagePath) async {
    calls++;
    return const OcrResult('Réunion de l\'Équipe\nBudget 2026', [
      OcrLine(
        text: 'Réunion de l\'Équipe',
        left: 0.1,
        top: 0.1,
        width: 0.6,
        height: 0.03,
      ),
      OcrLine(
        text: 'Budget 2026',
        left: 0.1,
        top: 0.2,
        width: 0.3,
        height: 0.03,
      ),
    ]);
  }
}

void phase4Tests() {
  late Directory tmp;
  late AppDatabase db;
  late FileStore files;
  late _FakeOcr ocr;
  late DocumentRepository repo;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('scan_test4');
    db = AppDatabase(NativeDatabase.memory());
    files = FileStore(Directory(p.join(tmp.path, 'root'))..createSync(), tmp);
    ocr = _FakeOcr();
    repo = DocumentRepository(db, files, ocr);
  });
  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  test('recognised text is searchable without accents or case', () async {
    final id = await repo.createDocument([
      _fakeScan(tmp),
      _fakeScan(tmp),
    ], title: 'Notes');
    await repo.createDocument([_fakeScan(tmp)], title: 'Autre');
    await repo.recognizeDocument(id);
    expect(ocr.calls, 2);

    // Already recognised pages are skipped.
    await repo.recognizeDocument(id);
    expect(ocr.calls, 2);

    final hits = await db.watchDocuments(search: 'EQUIPE').first;
    expect(hits.single.document.id, id);
    expect(await repo.documentText(id), contains('— Page 2 —'));
  });

  test('rotation invalidates OCR, filters and copies keep it', () async {
    final id = await repo.createDocument([_fakeScan(tmp)]);
    await repo.recognizeDocument(id);
    var page = (await db.getPages(id)).single;

    await repo.setFilter(page, PageFilter.grayscale);
    page = (await db.getPages(id)).single;
    expect(page.ocrText, isNotNull);

    final copy = await repo.extractPages(id, [page.id]);
    expect((await db.getPages(copy)).single.ocrLines, page.ocrLines);

    await repo.rotate(page, 1);
    page = (await db.getPages(id)).single;
    expect(page.ocrText, isNull);
    expect(page.searchText, isNull);
  });

  test(
    'exported PDF carries a selectable text layer',
    () async {
      final pdf = await exportPdf(
        images: [_fakeScan(tmp)],
        outputPath: p.join(tmp.path, 'ocr.pdf'),
        title: 'OCR',
        quality: ExportQuality.low,
        layout: PageLayout.a4,
        textLayers: [(await ocr.recognize('')).lines],
      );
      final result = await Process.run('pdftotext', [pdf.path, '-']);
      expect(result.stdout as String, contains('Budget 2026'));
      expect(result.stdout as String, contains('Réunion'));
    },
    skip: Process.runSync('which', ['pdftotext']).exitCode != 0,
  );
}

void phase5Tests() {
  late Directory tmp;
  late AppDatabase db;
  late FileStore files;
  late DocumentRepository repo;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('scan_test5');
    db = AppDatabase(NativeDatabase.memory());
    files = FileStore(Directory(p.join(tmp.path, 'root'))..createSync(), tmp);
    repo = DocumentRepository(db, files, _FakeOcr());
  });
  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  img.Image processed(DocPage page) =>
      img.decodeJpg(File(files.abs(page.processedPath)).readAsBytesSync())!;

  test('manual crop straightens the area and can be undone', () async {
    final id = await repo.createDocument([_fakeScan(tmp)]);
    await repo.recognizeDocument(id);
    var page = (await db.getPages(id)).single;

    await repo.setCrop(
      page,
      const CropQuad(
        Offset(0.1, 0.1),
        Offset(0.6, 0.12),
        Offset(0.6, 0.6),
        Offset(0.1, 0.6),
      ),
    );
    page = (await db.getPages(id)).single;
    expect(page.crop, isNotNull);
    expect(page.ocrText, isNull, reason: 'geometry changed');
    final cropped = processed(page);
    expect(cropped.width, closeTo(600, 5));
    expect(cropped.height, closeTo(790, 10));

    await repo.setCrop(page, CropQuad.full);
    page = (await db.getPages(id)).single;
    expect(page.crop, isNull);
    expect(processed(page).width, 1200);
  });

  test('ID card front and back land on one A4 page', () async {
    final front = _fakeScan(tmp, w: 1000, h: 640);
    final back = _fakeScan(tmp, w: 640, h: 1000); // taken sideways
    final id = await repo.createIdCardDocument([front, back]);
    final page = (await db.getPages(id)).single;
    final a4 = processed(page);
    expect([a4.width, a4.height], [2480, 3508]);
    // Margins stay white, both cards are printed.
    expect(a4.getPixel(100, 100).luminance, greaterThan(240));
    expect(a4.getPixel(1240, (3508 * 0.27).round()).luminance, lessThan(240));
    expect(a4.getPixel(1240, (3508 * 0.62).round()).luminance, lessThan(240));
  });

  test('book spread is cut at the gutter', () async {
    final spread = img.Image(width: 2000, height: 1400)
      ..clear(img.ColorRgb8(235, 235, 230));
    img.fillRect(
      spread,
      x1: 1080,
      y1: 0,
      x2: 1120,
      y2: 1399,
      color: img.ColorRgb8(60, 60, 60),
    );
    final path = p.join(tmp.path, 'spread.jpg');
    File(path).writeAsBytesSync(img.encodeJpg(spread));

    final id = await repo.createBookDocument([path]);
    final pages = await db.getPages(id);
    expect(pages, hasLength(2));
    expect(processed(pages[0]).width, closeTo(1100, 20));
    expect(processed(pages[1]).width, closeTo(900, 20));
  });

  test('whiteboard filter turns the board white', () async {
    final source = _fakeScan(tmp);
    final target = p.join(tmp.path, 'wb.jpg');
    await renderPage(
      PageRenderJob(
        source: source,
        target: target,
        thumb: p.join(tmp.path, 'wb_t.jpg'),
        quarterTurns: 0,
        filter: PageFilter.whiteboard,
      ),
    );
    final out = img.decodeJpg(File(target).readAsBytesSync())!;
    expect(out.getPixel(50, 800).luminance, greaterThan(245));
    expect(out.getPixel(600, 320).luminance, lessThan(100));
  });

  test('restore keeps OCR text and crop', () async {
    final root = Directory(p.join(tmp.path, 'lib'))..createSync();
    final store = FileStore(root, tmp);
    final fileDb = AppDatabase(NativeDatabase(File(store.databasePath)));
    final fileRepo = DocumentRepository(fileDb, store, _FakeOcr());
    final backup = BackupService(fileDb, store);

    final id = await fileRepo.createDocument([_fakeScan(tmp)]);
    var page = (await fileDb.getPages(id)).single;
    await fileRepo.setCrop(
      page,
      const CropQuad(
        Offset(0, 0),
        Offset(0.9, 0),
        Offset(0.9, 0.9),
        Offset(0, 0.9),
      ),
    );
    await fileRepo.recognizeDocument(id);
    final zip = await backup.create();
    final saved = await zip.copy(p.join(tmp.path, 'b.zip'));

    await fileRepo.deleteDocument(id);
    await backup.restore(saved.path);
    page = (await fileDb.getPages(id)).single;
    expect(page.crop, isNotNull);
    expect(page.ocrText, contains('Budget'));
    expect(
      (await fileDb.watchDocuments(search: 'equipe').first).single.document.id,
      id,
    );
    await fileDb.close();
  });
}

void phase6Tests() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('scan_test6'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test(
    'Word export opens in LibreOffice with all pages',
    () async {
      final docx = await writeDocx(
        path: p.join(tmp.path, 'Compte rendu.docx'),
        title: 'Compte rendu',
        pages: [
          'Réunion de l\'équipe\nligne 2\n\nSecond paragraphe <&>',
          'Page deux',
        ],
      );
      final result = await Process.run('soffice', [
        '--headless',
        '--convert-to',
        'txt:Text',
        '--outdir',
        tmp.path,
        docx.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final text = File(
        p.join(tmp.path, 'Compte rendu.txt'),
      ).readAsStringSync();
      expect(text, contains('Compte rendu'));
      expect(text, contains('Réunion de l\'équipe'));
      expect(text, contains('Second paragraphe <&>'));
      expect(text, contains('Page deux'));
    },
    skip: Process.runSync('which', ['soffice']).exitCode != 0,
  );
}
