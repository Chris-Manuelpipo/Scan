import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../app/dialogs.dart';
import '../../app/providers.dart';
import '../../core/db/database.dart';
import '../editor/page_screen.dart' show filterLabels;

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _backup(BuildContext context, WidgetRef ref, bool share) async {
    final file = await runWithProgress(
      context,
      'Création de la sauvegarde…',
      () => ref.read(backupProvider).create(),
    );
    if (file == null) return;
    if (share) {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path, mimeType: 'application/zip')]),
      );
      return;
    }
    final uri = await FilePicker.saveFile(
      fileName: p.basename(file.path),
      bytes: await file.readAsBytes(),
      mimeType: 'application/zip',
    );
    if (uri != null && context.mounted) {
      showMessage(context, 'Sauvegarde enregistrée');
    }
  }

  Future<void> _restore(BuildContext context, WidgetRef ref) async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    final path = picked.firstOrNull?.path;
    if (path == null || !context.mounted) return;
    if (!await confirm(
      context,
      title: 'Restaurer ?',
      message:
          'Tous les documents actuels seront remplacés par ceux de la '
          'sauvegarde. Cette action est irréversible.',
      confirmLabel: 'Restaurer',
    )) {
      return;
    }
    if (!context.mounted) return;
    final done = await runWithProgress(context, 'Restauration…', () async {
      await ref.read(backupProvider).restore(path);
      return true;
    });
    if (done == true && context.mounted) {
      showMessage(context, 'Sauvegarde restaurée');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final defaultFilter = ref.watch(defaultFilterProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Réglages')),
      body: ListView(
        children: [
          _Header('Scan'),
          ListTile(
            leading: const Icon(Icons.auto_fix_high_outlined),
            title: const Text('Filtre par défaut'),
            subtitle: Text(filterLabels[defaultFilter]!),
            onTap: () async {
              final choice = await showDialog<PageFilter>(
                context: context,
                builder: (context) => SimpleDialog(
                  title: const Text('Filtre par défaut'),
                  children: [
                    RadioGroup<PageFilter>(
                      groupValue: defaultFilter,
                      onChanged: (value) => Navigator.pop(context, value),
                      child: Column(
                        children: [
                          for (final filter in PageFilter.values)
                            RadioListTile<PageFilter>(
                              value: filter,
                              title: Text(filterLabels[filter]!),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
              if (choice != null) {
                ref.read(defaultFilterProvider.notifier).set(choice);
              }
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.text_fields),
            title: const Text('Reconnaître le texte automatiquement'),
            subtitle: const Text(
              'Après chaque scan, pour la recherche et les PDF cherchables',
            ),
            value: ref.watch(autoOcrProvider),
            onChanged: ref.read(autoOcrProvider.notifier).set,
          ),
          _Header('Sauvegarde'),
          ListTile(
            leading: const Icon(Icons.save_alt),
            title: const Text('Enregistrer une sauvegarde'),
            subtitle: const Text('Fichier ZIP avec tous les documents'),
            onTap: () => _backup(context, ref, false),
          ),
          ListTile(
            leading: const Icon(Icons.cloud_upload_outlined),
            title: const Text('Partager une sauvegarde'),
            subtitle: const Text('Vers Drive, e-mail…'),
            onTap: () => _backup(context, ref, true),
          ),
          ListTile(
            leading: const Icon(Icons.restore),
            title: const Text('Restaurer une sauvegarde'),
            subtitle: const Text('Remplace la bibliothèque actuelle'),
            onTap: () => _restore(context, ref),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              'SCAN · hors ligne, sans filigrane',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}
