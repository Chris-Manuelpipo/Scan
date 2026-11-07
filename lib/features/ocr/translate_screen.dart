import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/dialogs.dart';
import '../../app/providers.dart';
import '../../core/ocr/translation.dart';

/// Translates recognised [text] on the device.
class TranslateScreen extends ConsumerStatefulWidget {
  const TranslateScreen({super.key, required this.text});

  final String text;

  @override
  ConsumerState<TranslateScreen> createState() => _TranslateScreenState();
}

class _TranslateScreenState extends ConsumerState<TranslateScreen> {
  TranslateLanguage? _from;
  late TranslateLanguage _to;
  String? _result;
  String? _status;

  @override
  void initState() {
    super.initState();
    final saved = ref.read(preferencesProvider).getString('translateTo');
    _to = languageFromCode(saved ?? 'fr') ?? TranslateLanguage.french;
    _detect();
  }

  Future<void> _detect() async {
    setState(() => _status = 'Détection de la langue…');
    final detected = await ref
        .read(translationProvider)
        .detect(widget.text)
        .catchError((Object _) => null);
    if (!mounted) return;
    setState(() {
      _from = detected ?? TranslateLanguage.english;
      if (_from == _to) {
        _to = _to == TranslateLanguage.french
            ? TranslateLanguage.english
            : TranslateLanguage.french;
      }
      _status = null;
    });
  }

  Future<void> _translate() async {
    final from = _from;
    if (from == null) return;
    final service = ref.read(translationProvider);
    ref.read(preferencesProvider).setString('translateTo', _to.bcpCode);
    try {
      final missing = await service.missingModels([from, _to]);
      if (missing.isNotEmpty) {
        if (!mounted) return;
        final names = missing.map(languageName).join(' et ');
        if (!await confirm(
          context,
          title: 'Télécharger la langue ?',
          message:
              'Le modèle $names (environ 30 Mo par langue) doit être '
              'téléchargé une seule fois. Ensuite, la traduction fonctionne '
              'sans connexion.',
          confirmLabel: 'Télécharger',
        )) {
          return;
        }
        for (final language in missing) {
          setState(
            () => _status = 'Téléchargement : ${languageName(language)}…',
          );
          await service.download(language);
        }
      }
      setState(() => _status = 'Traduction…');
      final result = await service.translate(widget.text, from: from, to: _to);
      if (mounted) setState(() => _result = result);
    } catch (e) {
      if (mounted) showMessage(context, 'Erreur : $e');
    } finally {
      if (mounted) setState(() => _status = null);
    }
  }

  Widget _languagePicker(
    String label,
    TranslateLanguage? value,
    ValueChanged<TranslateLanguage> onChanged,
  ) {
    return Expanded(
      child: DropdownButtonFormField<TranslateLanguage>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        items: [
          for (final language in translateLanguages)
            DropdownMenuItem(
              value: language,
              child: Text(languageName(language)),
            ),
        ],
        onChanged: _status != null
            ? null
            : (v) {
                if (v != null) setState(() => onChanged(v));
              },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Traduire'),
        actions: [
          IconButton(
            tooltip: 'Copier',
            icon: const Icon(Icons.copy),
            onPressed: result == null
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: result));
                    if (context.mounted) {
                      showMessage(context, 'Traduction copiée');
                    }
                  },
          ),
          IconButton(
            tooltip: 'Partager',
            icon: const Icon(Icons.share),
            onPressed: result == null
                ? null
                : () => SharePlus.instance.share(ShareParams(text: result)),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                // Rebuilt once the language is detected.
                KeyedSubtree(
                  key: ValueKey(_from),
                  child: _languagePicker('De', _from, (v) => _from = v),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.arrow_forward),
                ),
                KeyedSubtree(
                  key: ValueKey(_to),
                  child: _languagePicker('Vers', _to, (v) => _to = v),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
              onPressed: _status != null || _from == null ? null : _translate,
              icon: const Icon(Icons.translate),
              label: const Text('Traduire'),
            ),
          ),
          if (_status case final status?)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(status)),
                ],
              ),
            ),
          const Divider(height: 32),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: SelectableText(
                result ?? widget.text,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: result == null
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
