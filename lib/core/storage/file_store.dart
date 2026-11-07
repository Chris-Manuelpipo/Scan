import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Owns every file SCAN writes. Page images live under `root/docs/<docId>/`,
/// exports are written to a scratch folder that is wiped before each export.
class FileStore {
  FileStore(this.root, this.tempRoot);

  final Directory root;
  final Directory tempRoot;

  static Future<FileStore> open() async {
    final docs = await getApplicationDocumentsDirectory();
    final temp = await getTemporaryDirectory();
    final root = Directory(p.join(docs.path, 'scan'));
    await root.create(recursive: true);
    return FileStore(root, temp);
  }

  /// Kept next to [root], where drift_flutter put it in earlier versions.
  String get databasePath => p.join(p.dirname(root.path), 'scan.sqlite');

  String abs(String relative) => p.join(root.path, relative);

  /// Saved signatures, reusable on any page.
  Directory get signaturesDir => Directory(abs('signatures'));

  String documentDir(int documentId) => p.join('docs', '$documentId');

  Future<void> ensureDocumentDir(int documentId) =>
      Directory(abs(documentDir(documentId))).create(recursive: true);

  Future<void> deleteDocumentFiles(int documentId) async {
    final dir = Directory(abs(documentDir(documentId)));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<void> deleteFiles(Iterable<String> relatives) async {
    for (final relative in relatives.toSet()) {
      final file = File(abs(relative));
      if (await file.exists()) await file.delete();
    }
  }

  Future<Directory> freshExportDir() async {
    final dir = Directory(p.join(tempRoot.path, 'exports'));
    if (await dir.exists()) await dir.delete(recursive: true);
    return dir.create(recursive: true);
  }
}
