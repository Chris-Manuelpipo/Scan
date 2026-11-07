import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../ocr/search_text.dart';

part 'database.g.dart';

/// Stored by index: only ever append new values.
enum PageFilter { original, enhanced, grayscale, blackWhite, whiteboard }

enum DocumentSort { updated, created, title }

class Folders extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  DateTimeColumn get createdAt => dateTime()();
}

class Documents extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text()();

  /// `null` means the document sits at the root of the library.
  IntColumn get folderId => integer().nullable().references(
    Folders,
    #id,
    onDelete: KeyAction.setNull,
  )();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}

/// Paths are relative to [FileStore.root] so the database survives a change
/// of the app's documents directory.
@DataClassName('DocPage')
class Pages extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get documentId =>
      integer().references(Documents, #id, onDelete: KeyAction.cascade)();
  IntColumn get position => integer()();
  TextColumn get originalPath => text()();
  TextColumn get processedPath => text()();
  TextColumn get thumbPath => text()();

  /// Clockwise quarter turns applied to the original.
  IntColumn get rotation => integer().withDefault(const Constant(0))();
  IntColumn get filter => intEnum<PageFilter>()();

  /// JSON list of images (signatures…) drawn over the page, see
  /// [PageOverlay].
  TextColumn get overlays => text().nullable()();

  /// Recognised text (OCR), `null` until recognition has run.
  TextColumn get ocrText => text().nullable()();

  /// JSON list of recognised lines with their position, see [OcrLine].
  TextColumn get ocrLines => text().nullable()();

  /// [ocrText] lowercased without accents, matched by the library search.
  TextColumn get searchText => text().nullable()();

  /// Manual crop as a JSON [CropQuad] on the original image, `null` = none.
  TextColumn get crop => text().nullable()();
}

class DocumentSummary {
  const DocumentSummary({
    required this.document,
    required this.pageCount,
    this.coverPath,
  });

  final Document document;
  final int pageCount;
  final String? coverPath;
}

class FolderSummary {
  const FolderSummary({required this.folder, required this.documentCount});

  final Folder folder;
  final int documentCount;
}

@DriftDatabase(tables: [Folders, Documents, Pages])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  AppDatabase.open(String path)
    : super(
        driftDatabase(
          name: 'scan',
          native: DriftNativeOptions(databasePath: () async => path),
        ),
      );

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(folders);
        await m.addColumn(documents, documents.folderId);
      }
      if (from < 3) {
        await m.addColumn(pages, pages.overlays);
      }
      if (from < 4) {
        await m.addColumn(pages, pages.ocrText);
        await m.addColumn(pages, pages.ocrLines);
        await m.addColumn(pages, pages.searchText);
      }
      if (from < 5) {
        await m.addColumn(pages, pages.crop);
      }
    },
    beforeOpen: (details) => customStatement('PRAGMA foreign_keys = ON'),
  );

  /// Documents of one folder (`null` = root), or of every folder when
  /// [search] is set.
  Stream<List<DocumentSummary>> watchDocuments({
    int? folderId,
    String search = '',
    DocumentSort sort = DocumentSort.updated,
  }) {
    final term = search.trim();
    final where = term.isNotEmpty
        ? "WHERE d.title LIKE ?1 ESCAPE '\\' OR EXISTS (SELECT 1 FROM pages sp "
              "WHERE sp.document_id = d.id AND sp.search_text LIKE ?2 ESCAPE '\\')"
        : folderId == null
        ? 'WHERE d.folder_id IS NULL'
        : 'WHERE d.folder_id = ?';
    final orderBy = switch (sort) {
      DocumentSort.updated => 'd.updated_at DESC',
      DocumentSort.created => 'd.created_at DESC',
      DocumentSort.title => 'd.title COLLATE NOCASE ASC',
    };
    return customSelect(
      'SELECT d.id, d.title, d.folder_id, d.created_at, d.updated_at, '
      'COUNT(p.id) AS page_count, '
      '(SELECT thumb_path FROM pages WHERE document_id = d.id '
      'ORDER BY position LIMIT 1) AS cover '
      'FROM documents d LEFT JOIN pages p ON p.document_id = d.id '
      '$where GROUP BY d.id ORDER BY $orderBy',
      variables: [
        if (term.isNotEmpty) ...[
          Variable.withString(_likePattern(term)),
          Variable.withString(_likePattern(normalizeForSearch(term))),
        ] else if (folderId != null)
          Variable.withInt(folderId),
      ],
      readsFrom: {documents, pages},
    ).watch().map(
      (rows) => [
        for (final row in rows)
          DocumentSummary(
            document: Document(
              id: row.read<int>('id'),
              title: row.read<String>('title'),
              folderId: row.readNullable<int>('folder_id'),
              createdAt: row.read<DateTime>('created_at'),
              updatedAt: row.read<DateTime>('updated_at'),
            ),
            pageCount: row.read<int>('page_count'),
            coverPath: row.readNullable<String>('cover'),
          ),
      ],
    );
  }

  static String _likePattern(String term) =>
      '%${term.replaceAllMapped(RegExp(r'[%_\\]'), (m) => '\\${m[0]}')}%';

  Stream<List<FolderSummary>> watchFolders() {
    final count = documents.id.count();
    final query =
        select(folders).join([
            leftOuterJoin(documents, documents.folderId.equalsExp(folders.id)),
          ])
          ..addColumns([count])
          ..groupBy([folders.id])
          ..orderBy([OrderingTerm.asc(folders.name.collate(Collate.noCase))]);
    return query.watch().map(
      (rows) => [
        for (final row in rows)
          FolderSummary(
            folder: row.readTable(folders),
            documentCount: row.read(count) ?? 0,
          ),
      ],
    );
  }

  Stream<Folder?> watchFolder(int id) =>
      (select(folders)..where((f) => f.id.equals(id))).watchSingleOrNull();

  Future<List<Folder>> getFolders() =>
      (select(folders)..orderBy([(f) => OrderingTerm.asc(f.name)])).get();

  Future<int> createFolder(String name) => into(
    folders,
  ).insert(FoldersCompanion.insert(name: name, createdAt: DateTime.now()));

  Future<void> renameFolder(int id, String name) => (update(
    folders,
  )..where((f) => f.id.equals(id))).write(FoldersCompanion(name: Value(name)));

  /// Documents inside fall back to the root (`ON DELETE SET NULL`).
  Future<void> deleteFolder(int id) =>
      (delete(folders)..where((f) => f.id.equals(id))).go();

  Future<void> moveDocument(int id, int? folderId) =>
      (update(documents)..where((d) => d.id.equals(id))).write(
        DocumentsCompanion(folderId: Value(folderId)),
      );

  /// Flushes the write-ahead log so the database file alone is a full copy.
  Future<void> checkpoint() =>
      customStatement('PRAGMA wal_checkpoint(TRUNCATE)');

  Stream<Document?> watchDocument(int id) =>
      (select(documents)..where((d) => d.id.equals(id))).watchSingleOrNull();

  Future<Document?> getDocument(int id) =>
      (select(documents)..where((d) => d.id.equals(id))).getSingleOrNull();

  SimpleSelectStatement<$PagesTable, DocPage> _pagesOf(int documentId) =>
      select(pages)
        ..where((p) => p.documentId.equals(documentId))
        ..orderBy([(p) => OrderingTerm.asc(p.position)]);

  Stream<List<DocPage>> watchPages(int documentId) =>
      _pagesOf(documentId).watch();

  Future<List<DocPage>> getPages(int documentId) => _pagesOf(documentId).get();

  Future<int> createDocument(String title, {int? folderId}) {
    final now = DateTime.now();
    return into(documents).insert(
      DocumentsCompanion.insert(
        title: title,
        folderId: Value(folderId),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  Future<void> touchDocument(int id) =>
      (update(documents)..where((d) => d.id.equals(id))).write(
        DocumentsCompanion(updatedAt: Value(DateTime.now())),
      );

  Future<void> renameDocument(int id, String title) =>
      (update(documents)..where((d) => d.id.equals(id))).write(
        DocumentsCompanion(
          title: Value(title),
          updatedAt: Value(DateTime.now()),
        ),
      );

  Future<void> deleteDocument(int id) =>
      (delete(documents)..where((d) => d.id.equals(id))).go();

  Future<int> nextPosition(int documentId) async {
    final max = pages.position.max();
    final row =
        await (selectOnly(pages)
              ..addColumns([max])
              ..where(pages.documentId.equals(documentId)))
            .getSingle();
    final current = row.read(max);
    return current == null ? 0 : current + 1;
  }

  Future<int> insertPage(PagesCompanion page) => into(pages).insert(page);

  Future<void> updatePage(int id, PagesCompanion page) =>
      (update(pages)..where((p) => p.id.equals(id))).write(page);

  Future<void> deletePage(int id) =>
      (delete(pages)..where((p) => p.id.equals(id))).go();

  Future<List<DocPage>> getPagesById(List<int> ids) async {
    final rows = await (select(pages)..where((p) => p.id.isIn(ids))).get();
    final byId = {for (final r in rows) r.id: r};
    return [for (final id in ids) ?byId[id]];
  }

  Future<void> reorderPages(List<int> orderedIds) => transaction(() async {
    for (var i = 0; i < orderedIds.length; i++) {
      await updatePage(orderedIds[i], PagesCompanion(position: Value(i)));
    }
  });
}
