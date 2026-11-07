import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

/// French names for the languages most likely to be scanned; the others are
/// shown by their code.
const languageNames = {
  'fr': 'Français',
  'en': 'Anglais',
  'es': 'Espagnol',
  'de': 'Allemand',
  'it': 'Italien',
  'pt': 'Portugais',
  'nl': 'Néerlandais',
  'ar': 'Arabe',
  'zh': 'Chinois',
  'ja': 'Japonais',
  'ko': 'Coréen',
  'ru': 'Russe',
  'tr': 'Turc',
  'pl': 'Polonais',
  'sw': 'Swahili',
  'hi': 'Hindi',
};

TranslateLanguage? languageFromCode(String code) =>
    TranslateLanguage.values.where((l) => l.bcpCode == code).firstOrNull;

String languageName(TranslateLanguage language) =>
    languageNames[language.bcpCode] ?? language.bcpCode.toUpperCase();

/// Every supported language, the named ones first in alphabetical order.
final List<TranslateLanguage> translateLanguages = [...TranslateLanguage.values]
  ..sort((a, b) {
    int rank(TranslateLanguage l) =>
        languageNames.containsKey(l.bcpCode) ? 0 : 1;
    final byRank = rank(a) - rank(b);
    return byRank != 0 ? byRank : languageName(a).compareTo(languageName(b));
  });

/// On-device language detection and translation (ML Kit). Each language
/// model (~30 MB) is downloaded once, then everything works offline.
class TranslationService {
  final _models = OnDeviceTranslatorModelManager();

  /// `null` when the language cannot be determined or is not translatable.
  Future<TranslateLanguage?> detect(String text) async {
    final identifier = LanguageIdentifier(confidenceThreshold: 0.5);
    try {
      final sample = text.length > 2000 ? text.substring(0, 2000) : text;
      final code = await identifier.identifyLanguage(sample);
      return languageFromCode(code);
    } finally {
      await identifier.close();
    }
  }

  /// Languages among [languages] whose model is not on the device yet.
  Future<List<TranslateLanguage>> missingModels(
    Iterable<TranslateLanguage> languages,
  ) async => [
    for (final language in languages.toSet())
      if (!await _models.isModelDownloaded(language.bcpCode)) language,
  ];

  Future<void> download(TranslateLanguage language) async {
    final ok = await _models.downloadModel(
      language.bcpCode,
      isWifiRequired: false,
    );
    if (!ok) {
      throw StateError(
        'Téléchargement de ${languageName(language)} impossible',
      );
    }
  }

  /// Translates paragraph by paragraph, keeping the blank lines between them.
  Future<String> translate(
    String text, {
    required TranslateLanguage from,
    required TranslateLanguage to,
  }) async {
    if (from == to) return text;
    final translator = OnDeviceTranslator(
      sourceLanguage: from,
      targetLanguage: to,
    );
    try {
      final out = <String>[];
      for (final paragraph in text.split('\n\n')) {
        out.add(
          paragraph.trim().isEmpty
              ? paragraph
              : await translator.translateText(paragraph),
        );
      }
      return out.join('\n\n');
    } finally {
      await translator.close();
    }
  }
}
