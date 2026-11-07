import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dialogs.dart';
import '../../app/providers.dart';
import '../../core/db/database.dart';

Future<int?> createFolder(BuildContext context, WidgetRef ref) async {
  final name = await promptText(
    context,
    title: 'Nouveau dossier',
    initial: '',
    confirmLabel: 'Créer',
  );
  if (name == null) return null;
  return ref.read(repositoryProvider).createFolder(name);
}

Future<void> renameFolder(
  BuildContext context,
  WidgetRef ref,
  Folder folder,
) async {
  final name = await promptText(
    context,
    title: 'Renommer le dossier',
    initial: folder.name,
  );
  if (name != null) {
    await ref.read(repositoryProvider).renameFolder(folder.id, name);
  }
}

/// Returns `true` if the folder was deleted.
Future<bool> deleteFolder(
  BuildContext context,
  WidgetRef ref,
  Folder folder,
) async {
  if (!await confirm(
    context,
    title: 'Supprimer le dossier ?',
    message:
        'Le dossier « ${folder.name} » sera supprimé. '
        'Ses documents seront déplacés à la racine.',
  )) {
    return false;
  }
  await ref.read(repositoryProvider).deleteFolder(folder.id);
  return true;
}

const _root = -1;

/// Lets the user pick a destination folder (or the root) for [document].
Future<void> moveDocument(
  BuildContext context,
  WidgetRef ref,
  Document document,
) => moveDocuments(context, ref, [document.id], from: document.folderId);

/// Returns `true` once the documents have been moved.
Future<bool> moveDocuments(
  BuildContext context,
  WidgetRef ref,
  List<int> documentIds, {
  int? from,
}) async {
  final folders = await ref.read(databaseProvider).getFolders();
  if (!context.mounted) return false;
  final choice = await showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('Déplacer vers…')),
          ListTile(
            leading: const Icon(Icons.home_outlined),
            title: const Text('Racine'),
            selected: from == null,
            onTap: () => Navigator.pop(context, _root),
          ),
          for (final folder in folders)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(folder.name),
              selected: from == folder.id,
              onTap: () => Navigator.pop(context, folder.id),
            ),
          ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('Nouveau dossier…'),
            onTap: () => Navigator.pop(context, 0),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return false;
  final target = switch (choice) {
    _root => null,
    0 => await createFolder(context, ref),
    final id => id,
  };
  if (choice == 0 && target == null) return false;
  for (final id in documentIds) {
    await ref.read(repositoryProvider).move(id, target);
  }
  return true;
}
