# SCAN — Plan de développement

Application mobile de scan de documents, gratuite, sans filigrane, sans pub, sans compte.
Usage personnel d'abord. Tout est traité **sur le téléphone, hors ligne**.

## Décisions

| Sujet | Choix | Pourquoi |
|---|---|---|
| Framework | Flutter (Dart 3.12) | Une base de code, Android d'abord, iOS possible plus tard |
| Plateforme cible v1 | Android | Usage perso, tests sur ton téléphone via `adb` |
| Backend / comptes | Aucun | Pas de coût, pas de données qui sortent du téléphone |
| Fonctions IA cloud (chat avec doc, maths) | Hors périmètre | Nécessitent un serveur payant |
| Sauvegarde | Export manuel (ZIP / dossier partagé) puis WebDAV/Drive en option | Pas de backend à maintenir |
| Retouche d'image | Non destructive | On garde l'original, on stocke recadrage + filtre + rotation → on peut tout refaire |

## Stack technique

| Besoin | Paquet | Remarque |
|---|---|---|
| Scanner (détection bords, perspective, multi-pages) | `cunning_document_scanner` | ML Kit sur Android, VisionKit sur iOS |
| Traitement d'image avancé (filtres, modes ID/livre, caméra perso) | `opencv_dart` | Phase 5 |
| Filtres simples | `image` | Luminosité, contraste, N&B, niveaux de gris |
| OCR | `google_mlkit_text_recognition` | Hors ligne, alphabet latin (FR/EN) |
| Traduction hors ligne | `google_mlkit_translation` | Phase 6 |
| Création + manipulation PDF | `syncfusion_flutter_pdf` | Fusion, division, mot de passe, compression, calque texte OCR. Licence Community gratuite (usage perso / < 1 M$ de CA), à enregistrer |
| Import PDF | `pdfrx` | PDFium : chaque page du PDF rendue en image |
| Signature, annotations | maison (`CustomPainter`) | Dessin au doigt → PNG transparent haute résolution |
| QR / codes-barres | `mobile_scanner` | Phase 5 |
| Base de données | `drift` (SQLite) | Métadonnées, recherche dans le texte OCR (sans accents) |
| État | `flutter_riverpod` | |
| Navigation | `go_router` | |
| Import / partage | `file_picker`, `share_plus`, `receive_sharing_intent` | Recevoir des images/PDF depuis d'autres apps |
| Fichiers | `path_provider` | Stockage dans le dossier privé de l'app |

## Architecture

```
lib/
  main.dart
  app/                  # thème, router, providers globaux
  core/
    db/                 # drift : tables, DAO
    storage/            # chemins fichiers, copie, nettoyage
    pdf/                # génération / manipulation PDF (service)
    imaging/            # filtres, rotation, recadrage
    ocr/                # service OCR
  features/
    library/            # accueil : liste docs, dossiers, recherche
    scan/               # capture + import galerie
    editor/             # pages d'un doc : recadrer, filtre, réordonner
    export/             # PDF / JPG / TXT, nom de fichier, partage
    pdf_tools/          # fusion, division, compression, mot de passe, signature, filigrane
    ocr/                # écran texte extrait
    settings/
```

### Modèle de données

- **Folder** : `id, name, parentId, createdAt`
- **Document** : `id, title, folderId, createdAt, updatedAt, tags`
- **Page** : `id, documentId, position, originalPath, processedPath, cropQuad, rotation, filter, ocrText`
- **PageFts** : table FTS5 sur `ocrText` + `title` pour la recherche

Fichiers sur disque : `<appDocs>/docs/<docId>/<pageId>_orig.jpg` et `<pageId>.jpg` (rendu traité).
Le PDF est **généré à l'export**, pas stocké en permanence (moins d'espace, toujours à jour).

## Phases

### Phase 0 — Mise en place ✅
- `flutter create` (org `com.<toi>.scan`, Android uniquement au début)
- Arborescence ci-dessus, lints stricts, thème clair/sombre
- Riverpod + go_router + drift branchés, écran d'accueil vide
- Lancement sur ton téléphone

### Phase 1 — MVP : remplacer CamScanner au quotidien ✅
Objectif : **scanner → PDF propre, sans filigrane, avec le nom que tu veux.**
- Scan multi-pages (détection auto des bords, recadrage manuel)
- Import d'images depuis la galerie → PDF
- Filtres : original, amélioré, niveaux de gris, noir & blanc
- Rotation, suppression, réordonnancement des pages (glisser-déposer)
- Bibliothèque : liste des documents avec miniature, renommer, supprimer
- Export PDF (taille A4 / taille d'origine, qualité réglable) et JPG
- Nom de fichier personnalisé (modèle par défaut : `Scan_AAAA-MM-JJ_HHhMM`)
- Partage (WhatsApp, e-mail…) et enregistrement dans Téléchargements

### Phase 2 — Organisation ✅
- Dossiers, déplacement de documents, tri (date, nom)
- Ajouter des pages à un document existant
- Recherche par titre
- Recevoir des images/PDF partagés depuis d'autres apps (« Ouvrir avec SCAN »)
- Sauvegarde / restauration complète en ZIP

### Phase 3 — Outils PDF ✅
- Import de PDF (chaque page devient une page éditable), y compris protégés par mot de passe
- Fusionner des documents, extraire / supprimer une sélection de pages
- Compresser : qualité Haute / Moyenne / Légère à l'export
- Protéger par mot de passe (AES-256)
- Signature : dessiner, enregistrer, placer et redimensionner sur une page (non destructif)
- Filigrane **à toi**, optionnel (texte, PDF uniquement)
- PDF → images : importer le PDF puis exporter en JPG

### Phase 4 — OCR ✅
- Extraction de texte d'une page ou d'un document (ML Kit, hors ligne), copier/partager, export TXT
- PDF « cherchable » (calque de texte invisible sous l'image)
- Recherche dans le titre et le texte de toute la bibliothèque, sans accents ni casse
- OCR en tâche de fond après chaque scan (réglage, activé par défaut)

### Phase 5 — Modes de scan avancés ✅
- Carte d'identité : recto + verso à taille réelle sur une page A4
- Livre : chaque photo de double page coupée au pli (détection de la reliure)
- Filtre « Tableau blanc » (fond blanchi, couleurs des feutres renforcées)
- QR codes et codes-barres (caméra ou image de la galerie, lien / Wi-Fi / texte)
- Recadrage manuel avec correction de perspective, sur n'importe quelle page
- Caméra personnalisée : abandonnée, le scanner ML Kit suffit

### Phase 6 — Bonus
- ✅ Traduction hors ligne du texte OCR (détection de la langue, modèle ~30 Mo téléchargé une fois par langue)
- ✅ Export Word (.docx) à partir du texte OCR
- ✅ Annotations : stylo, surligneur, texte (calque non destructif, comme les signatures)
- ⏸ Synchronisation WebDAV / Google Drive : la sauvegarde ZIP partagée vers Drive suffit pour l'instant
- ⏸ Version iOS : demande un Mac pour compiler (le code Flutter est prêt à 90 %)

## Hors périmètre (coût serveur ou trop complexe)
Chat IA avec les documents, résolution de maths, PDF → Word avec mise en page fidèle,
restauration de photos, détection de falsification, fax, impression cloud.

## Finitions
- ✅ Nom de l'app (`SCAN`, `com.chris.scan`)
- ✅ Signature release (clé hors dépôt, `android/key.properties`)
- ✅ README, dépôt git
- ⏳ Icône (propositions dans `design/icon/proposals/`)

## Prochaine étape
Retours d'usage sur le téléphone et corrections.
