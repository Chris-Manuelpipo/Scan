import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:image_picker/image_picker.dart';

/// Opens the document scanner (camera, with gallery import available inside
/// it). Returns the cropped page images, or `null` if the user cancelled.
Future<List<String>?> scanPages({int maxPages = 100}) =>
    CunningDocumentScanner.getPictures(
      noOfPages: maxPages,
      scannerSource: ScannerSource.cameraAndGallery,
    );

/// Picks plain images from the gallery, without edge detection.
Future<List<String>?> pickImages() async {
  final files = await ImagePicker().pickMultiImage();
  return files.isEmpty ? null : [for (final f in files) f.path];
}
