# SCAN

Scanner de documents pour Android : gratuit, sans filigrane, sans pub, sans compte.
Tout est traité **sur le téléphone, hors ligne**. Aucune donnée ne sort de l'appareil.

## Fonctionnalités

- **Scan** multi-pages avec détection automatique des bords (ML Kit), import depuis la galerie
- **Retouche non destructive** : recadrage avec correction de perspective, rotation, filtres
  (original, amélioré, niveaux de gris, noir & blanc, tableau blanc)
- **Modes spéciaux** : carte d'identité (recto + verso sur une page A4), livre (double page coupée au pli)
- **Bibliothèque** : dossiers, tri, recherche dans les titres et le texte OCR (sans accents ni casse)
- **Export** : PDF (A4 ou taille d'origine, 3 niveaux de qualité, mot de passe AES-256,
  calque texte cherchable, filigrane personnel optionnel), JPG, TXT, Word (.docx)
- **Outils PDF** : import (y compris protégé), fusion, extraction et suppression de pages
- **Signature et annotations** : stylo, surligneur, texte, placés sur la page sans l'altérer
- **OCR** hors ligne en tâche de fond, **traduction** hors ligne du texte extrait
- **QR codes et codes-barres** (caméra ou image)
- **Partage** : « Ouvrir avec SCAN » depuis les autres apps, envoi vers WhatsApp, e-mail…
- **Sauvegarde / restauration** complète en ZIP

## Stack

Flutter (Dart 3.12) · Riverpod · go_router · drift (SQLite) · ML Kit (scanner, OCR, langue, traduction)
· syncfusion_flutter_pdf · pdfrx · mobile_scanner. Détails et choix techniques dans [PLAN.md](PLAN.md).

## Développement

```bash
flutter pub get
dart run build_runner build   # régénère lib/core/db/database.g.dart après un changement de schéma
flutter analyze
flutter test
flutter run
```

## APK release

```bash
flutter build apk --release --split-per-abi
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

La signature release lit `android/key.properties` (exclu de git) :

```properties
storePassword=…
keyPassword=…
keyAlias=scan
storeFile=/chemin/vers/scan-release.jks
```

Sans ce fichier, l'APK release est signé avec la clé de debug.
**Garder une copie du `.jks` et du mot de passe** : sans eux, impossible de mettre à jour
l'app installée sans la désinstaller (et perdre ses documents).

## Licences

`syncfusion_flutter_pdf` est utilisé sous la licence Community de Syncfusion (gratuite pour
un usage personnel ou une structure à moins d'un million de dollars de chiffre d'affaires).
