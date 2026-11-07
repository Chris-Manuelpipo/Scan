import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dialogs.dart';
import '../../app/providers.dart';
import '../../core/db/database.dart';
import '../../core/document_repository.dart';
import 'image_sources.dart';

enum PageSource { scanner, gallery }

Future<List<String>?> _acquire(BuildContext context, PageSource source) async {
  try {
    return switch (source) {
      PageSource.scanner => await scanPages(),
      PageSource.gallery => await pickImages(),
    };
  } on CunningDocumentScannerException catch (e) {
    if (context.mounted) {
      showMessage(context, 'Scanner indisponible : ${e.message}');
    }
    return null;
  }
}

/// Scans or imports pages into a new document and returns its id.
Future<int?> createDocumentFrom(
  BuildContext context,
  WidgetRef ref,
  PageSource source, {
  int? folderId,
}) async {
  final recognize = _autoRecognizer(ref);
  final images = await _acquire(context, source);
  if (images == null || !context.mounted) return null;
  final id = await runWithProgress(
    context,
    'Traitement des pages…',
    () => ref
        .read(repositoryProvider)
        .createDocument(
          images,
          filter: ref.read(defaultFilterProvider),
          folderId: folderId,
        ),
  );
  if (id != null) recognize(id);
  return id;
}

Future<void> addPagesFrom(
  BuildContext context,
  WidgetRef ref,
  int documentId,
  PageSource source,
) async {
  final recognize = _autoRecognizer(ref);
  final images = await _acquire(context, source);
  if (images == null || !context.mounted) return;
  await runWithProgress(
    context,
    'Traitement des pages…',
    () => ref
        .read(repositoryProvider)
        .addPages(documentId, images, filter: ref.read(defaultFilterProvider)),
  );
  recognize(documentId);
}

/// Creates a document from images and PDFs (picked or shared from another
/// app).
Future<int?> importFiles(
  BuildContext context,
  WidgetRef ref,
  List<String> paths, {
  int? folderId,
}) async {
  final recognize = _autoRecognizer(ref);
  final id = await runWithProgress(
    context,
    'Import en cours…',
    () => ref
        .read(repositoryProvider)
        .importFiles(
          paths,
          filter: ref.read(defaultFilterProvider),
          folderId: folderId,
          askPassword: (fileName) => context.mounted
              ? promptText(
                  context,
                  title: 'Mot de passe de « $fileName »',
                  initial: '',
                  obscure: true,
                )
              : null,
        ),
  );
  if (id != null) recognize(id);
  return id;
}

/// Scans the front and back of a card onto one A4 page.
Future<int?> createIdCardFrom(
  BuildContext context,
  WidgetRef ref, {
  int? folderId,
}) => _createFromScan(
  context,
  ref,
  maxPages: 2,
  create: (repository, images, filter) => repository.createIdCardDocument(
    images,
    filter: filter,
    folderId: folderId,
  ),
);

/// Scans photos of an open book; each one is split into two pages.
Future<int?> createBookFrom(
  BuildContext context,
  WidgetRef ref, {
  int? folderId,
}) => _createFromScan(
  context,
  ref,
  create: (repository, images, filter) =>
      repository.createBookDocument(images, filter: filter, folderId: folderId),
);

Future<int?> _createFromScan(
  BuildContext context,
  WidgetRef ref, {
  int maxPages = 100,
  required Future<int> Function(
    DocumentRepository repository,
    List<String> images,
    PageFilter filter,
  )
  create,
}) async {
  final recognize = _autoRecognizer(ref);
  final repository = ref.read(repositoryProvider);
  final filter = ref.read(defaultFilterProvider);
  List<String>? images;
  try {
    images = await scanPages(maxPages: maxPages);
  } on CunningDocumentScannerException catch (e) {
    if (context.mounted) {
      showMessage(context, 'Scanner indisponible : ${e.message}');
    }
  }
  if (images == null || !context.mounted) return null;
  final id = await runWithProgress(
    context,
    'Traitement des pages…',
    () => create(repository, images!, filter),
  );
  if (id != null) recognize(id);
  return id;
}

/// Read up front: the calling widget may be gone once the pages are ready.
void Function(int documentId) _autoRecognizer(WidgetRef ref) {
  final repository = ref.read(repositoryProvider);
  final enabled = ref.read(autoOcrProvider);
  return (id) {
    if (enabled) repository.recognizeInBackground(id);
  };
}
