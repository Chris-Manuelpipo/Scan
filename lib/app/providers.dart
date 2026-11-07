import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/backup.dart';
import '../core/db/database.dart';
import '../core/document_repository.dart';
import '../core/ocr/text_recognition.dart';
import '../core/ocr/translation.dart';
import '../core/storage/file_store.dart';

/// Overridden in `main` once the directories are resolved.
final fileStoreProvider = Provider<FileStore>(
  (ref) => throw UnimplementedError('fileStoreProvider not overridden'),
);

/// Overridden in `main` once loaded.
final preferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('preferencesProvider not overridden'),
);

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase.open(ref.watch(fileStoreProvider).databasePath);
  ref.onDispose(db.close);
  return db;
});

final textRecognitionProvider = Provider<TextRecognition>((ref) {
  final recognition = MlKitTextRecognition();
  ref.onDispose(recognition.close);
  return recognition;
});

final translationProvider = Provider<TranslationService>(
  (ref) => TranslationService(),
);

final repositoryProvider = Provider<DocumentRepository>(
  (ref) => DocumentRepository(
    ref.watch(databaseProvider),
    ref.watch(fileStoreProvider),
    ref.watch(textRecognitionProvider),
  ),
);

final backupProvider = Provider<BackupService>(
  (ref) =>
      BackupService(ref.watch(databaseProvider), ref.watch(fileStoreProvider)),
);

/// An enum stored in the preferences under [key] by name.
class EnumPreference<T extends Enum> extends Notifier<T> {
  EnumPreference(this.key, this.values, this.fallback);

  final String key;
  final List<T> values;
  final T fallback;

  @override
  T build() {
    final name = ref.watch(preferencesProvider).getString(key);
    return values.where((v) => v.name == name).firstOrNull ?? fallback;
  }

  void set(T value) {
    state = value;
    ref.read(preferencesProvider).setString(key, value.name);
  }
}

class BoolPreference extends Notifier<bool> {
  BoolPreference(this.key, this.fallback);

  final String key;
  final bool fallback;

  @override
  bool build() => ref.watch(preferencesProvider).getBool(key) ?? fallback;

  void set(bool value) {
    state = value;
    ref.read(preferencesProvider).setBool(key, value);
  }
}

/// Recognise text in the background after each scan or import.
final autoOcrProvider = NotifierProvider<BoolPreference, bool>(
  () => BoolPreference('autoOcr', true),
);

final sortProvider =
    NotifierProvider<EnumPreference<DocumentSort>, DocumentSort>(
      () => EnumPreference('sort', DocumentSort.values, DocumentSort.updated),
    );

final defaultFilterProvider =
    NotifierProvider<EnumPreference<PageFilter>, PageFilter>(
      () => EnumPreference(
        'defaultFilter',
        PageFilter.values,
        PageFilter.original,
      ),
    );

typedef DocumentQuery = ({int? folderId, String search});

final documentsProvider =
    StreamProvider.family<List<DocumentSummary>, DocumentQuery>(
      (ref, query) => ref
          .watch(databaseProvider)
          .watchDocuments(
            folderId: query.folderId,
            search: query.search,
            sort: ref.watch(sortProvider),
          ),
    );

final foldersProvider = StreamProvider<List<FolderSummary>>(
  (ref) => ref.watch(databaseProvider).watchFolders(),
);

final folderProvider = StreamProvider.family<Folder?, int>(
  (ref, id) => ref.watch(databaseProvider).watchFolder(id),
);

final documentProvider = StreamProvider.family<Document?, int>(
  (ref, id) => ref.watch(databaseProvider).watchDocument(id),
);

final pagesProvider = StreamProvider.family<List<DocPage>, int>(
  (ref, documentId) => ref.watch(databaseProvider).watchPages(documentId),
);
