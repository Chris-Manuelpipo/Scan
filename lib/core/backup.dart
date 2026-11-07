import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import 'db/database.dart';
import 'storage/file_store.dart';

const _dbEntry = 'scan.sqlite';
const _docsEntry = 'docs';

/// A backup is a ZIP holding the SQLite file and the `docs/` folder of page
/// images, so it can be restored on another phone.
class BackupService {
  BackupService(this._db, this._files);

  final AppDatabase _db;
  final FileStore _files;

  Future<File> create() async {
    await _db.checkpoint();
    final dir = await _files.freshExportDir();
    final name =
        'SCAN_sauvegarde_${DateFormat('yyyy-MM-dd_HH.mm').format(DateTime.now())}.zip';
    final path = p.join(dir.path, name);
    final docs = Directory(_files.abs(_docsEntry));

    // Page images are already JPEG: storing them uncompressed is much faster.
    final encoder = ZipFileEncoder()..create(path, level: 0);
    await encoder.addFile(File(_files.databasePath), _dbEntry);
    if (await docs.exists()) await encoder.addDirectory(docs);
    await encoder.close();
    return File(path);
  }

  /// Replaces the whole library with the content of [zipPath].
  ///
  /// The rows are copied into the open database (instead of swapping the
  /// file) so the app keeps running on the same connection.
  Future<void> restore(String zipPath) async {
    final staging = Directory(_files.abs('.restore'));
    if (await staging.exists()) await staging.delete(recursive: true);
    await extractFileToDisk(zipPath, staging.path);
    try {
      final backupDb = File(p.join(staging.path, _dbEntry));
      if (!await backupDb.exists()) {
        throw const FormatException(
          'Ce fichier n\'est pas une sauvegarde SCAN',
        );
      }
      await _importRows(backupDb.path);

      final docs = Directory(_files.abs(_docsEntry));
      final restoredDocs = Directory(p.join(staging.path, _docsEntry));
      if (await docs.exists()) await docs.delete(recursive: true);
      if (await restoredDocs.exists()) {
        await restoredDocs.rename(docs.path);
      }
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  Future<void> _importRows(String backupPath) async {
    await _db.customStatement('ATTACH DATABASE ? AS bak', [backupPath]);
    try {
      final tables = await _db
          .customSelect(
            "SELECT name FROM bak.sqlite_master WHERE type = 'table'",
          )
          .get();
      final names = {for (final t in tables) t.read<String>('name')};
      if (!names.containsAll(['documents', 'pages'])) {
        throw const FormatException('Sauvegarde incomplète');
      }
      // Parents first so foreign keys resolve. Columns added by later schema
      // versions are absent from older backups and keep their defaults.
      final tablesToCopy = [
        for (final table in ['folders', 'documents', 'pages'])
          if (names.contains(table)) table,
      ];
      final columns = {
        for (final table in tablesToCopy) table: await _commonColumns(table),
      };

      await _db.transaction(() async {
        await _db.customStatement('DELETE FROM pages');
        await _db.customStatement('DELETE FROM documents');
        await _db.customStatement('DELETE FROM folders');
        for (final table in tablesToCopy) {
          final list = columns[table]!.join(', ');
          await _db.customStatement(
            'INSERT INTO $table ($list) SELECT $list FROM bak.$table',
          );
        }
      });
    } finally {
      await _db.customStatement('DETACH DATABASE bak');
    }
    _db.markTablesUpdated([_db.folders, _db.documents, _db.pages]);
  }

  Future<List<String>> _commonColumns(String table) async {
    Future<Set<String>> namesIn(String schema) async => {
      for (final row
          in await _db.customSelect('PRAGMA $schema.table_info($table)').get())
        row.read<String>('name'),
    };
    final current = await namesIn('main');
    return (await namesIn('bak')).where(current.contains).toList();
  }
}
