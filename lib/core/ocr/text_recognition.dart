import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;

import 'ocr_line.dart';

class OcrResult {
  const OcrResult(this.text, this.lines);

  final String text;
  final List<OcrLine> lines;
}

/// Recognises text in a page image, on the device (ML Kit, Latin script).
abstract interface class TextRecognition {
  Future<OcrResult> recognize(String imagePath);
}

class MlKitTextRecognition implements TextRecognition {
  TextRecognizer? _recognizer;

  @override
  Future<OcrResult> recognize(String imagePath) async {
    final size = _imageSize(imagePath);
    final recognizer = _recognizer ??= TextRecognizer(
      script: TextRecognitionScript.latin,
    );
    final result = await recognizer.processImage(
      InputImage.fromFilePath(imagePath),
    );
    final lines = <OcrLine>[];
    final paragraphs = <String>[];
    for (final block in result.blocks) {
      paragraphs.add(block.lines.map((l) => l.text).join('\n'));
      for (final line in block.lines) {
        final box = line.boundingBox;
        lines.add(
          OcrLine(
            text: line.text,
            left: box.left / size.$1,
            top: box.top / size.$2,
            width: box.width / size.$1,
            height: box.height / size.$2,
          ),
        );
      }
    }
    return OcrResult(paragraphs.join('\n\n'), lines);
  }

  /// Reads the dimensions from the JPEG header without decoding pixels.
  (double, double) _imageSize(String path) {
    final info = img.JpegDecoder().startDecode(File(path).readAsBytesSync());
    if (info == null) throw FormatException('Image illisible', path);
    return (info.width.toDouble(), info.height.toDouble());
  }

  Future<void> close() async => _recognizer?.close();
}
