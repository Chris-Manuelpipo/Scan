import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../ocr/ocr_line.dart';

enum ExportQuality {
  high(3000, 90),
  medium(2000, 80),
  low(1400, 65);

  const ExportQuality(this.maxSide, this.jpegQuality);

  final int maxSide;
  final int jpegQuality;
}

enum PageLayout { a4, fitImage }

const _a4 = Size(595.28, 841.89);

/// Builds a PDF with one image per page. Runs entirely off the UI isolate.
Future<File> exportPdf({
  required List<String> images,
  required String outputPath,
  required String title,
  required ExportQuality quality,
  required PageLayout layout,
  String? password,
  String? watermark,
  List<List<OcrLine>>? textLayers,
}) {
  return Isolate.run(() {
    final document = PdfDocument()..compressionLevel = PdfCompressionLevel.best;
    if (password != null && password.isNotEmpty) {
      document.security
        ..algorithm = PdfEncryptionAlgorithm.aesx256Bit
        ..userPassword = password;
    }
    document.documentInformation
      ..title = title
      ..creator = 'SCAN'
      ..producer = 'SCAN';

    for (final (index, path) in images.indexed) {
      final jpeg = _compress(path, quality);
      final bitmap = PdfBitmap(jpeg.bytes);
      final pageSize = _pageSize(jpeg.width, jpeg.height, layout);

      final section = document.sections!.add();
      section.pageSettings
        ..margins.all = 0
        ..size = pageSize;
      final page = section.pages.add();

      final scale = math.min(
        pageSize.width / jpeg.width,
        pageSize.height / jpeg.height,
      );
      final w = jpeg.width * scale, h = jpeg.height * scale;
      page.graphics.drawImage(
        bitmap,
        Rect.fromLTWH(
          (pageSize.width - w) / 2,
          (pageSize.height - h) / 2,
          w,
          h,
        ),
      );
      final lines = textLayers?.elementAtOrNull(index);
      if (lines != null && lines.isNotEmpty) {
        _drawInvisibleText(
          page.graphics,
          Rect.fromLTWH(
            (pageSize.width - w) / 2,
            (pageSize.height - h) / 2,
            w,
            h,
          ),
          lines,
        );
      }
      if (watermark != null && watermark.trim().isNotEmpty) {
        _drawWatermark(page.graphics, pageSize, watermark.trim());
      }
    }

    final file = File(outputPath)..writeAsBytesSync(document.saveSync());
    document.dispose();
    return file;
  });
}

/// Writes each page as `<baseName>_01.jpg`, `<baseName>_02.jpg`… (or a single
/// `<baseName>.jpg`) into [outputDir].
Future<List<File>> exportJpegs({
  required List<String> images,
  required String outputDir,
  required String baseName,
  required ExportQuality quality,
}) {
  return Isolate.run(() {
    final digits = images.length.toString().length.clamp(2, 4);
    return [
      for (var i = 0; i < images.length; i++)
        File(
          p.join(
            outputDir,
            images.length == 1
                ? '$baseName.jpg'
                : '${baseName}_${(i + 1).toString().padLeft(digits, '0')}.jpg',
          ),
        )..writeAsBytesSync(_compress(images[i], quality).bytes),
    ];
  });
}

/// Writes the OCR lines as fully transparent text over the image, so PDF
/// readers can search, select and copy it.
void _drawInvisibleText(PdfGraphics graphics, Rect image, List<OcrLine> lines) {
  final state = graphics.save();
  graphics.setTransparency(0);
  for (final line in lines) {
    final text = _pdfSafe(line.text);
    final box = Rect.fromLTWH(
      image.left + line.left * image.width,
      image.top + line.top * image.height,
      line.width * image.width,
      line.height * image.height,
    );
    if (text.trim().isEmpty || box.width <= 0 || box.height <= 0) continue;
    // Size the font so the line spans the recognised box (capped by its
    // height), which keeps text selection aligned with the scanned words.
    const probeSize = 10.0;
    final probe = PdfStandardFont(PdfFontFamily.helvetica, probeSize);
    final probeWidth = probe.measureString(text).width;
    if (probeWidth <= 0) continue;
    final size = math.min(box.height * 0.9, probeSize * box.width / probeWidth);
    graphics.drawString(
      text,
      PdfStandardFont(PdfFontFamily.helvetica, size),
      brush: PdfBrushes.black,
      // Zero size: no clipping nor wrapping, the font size does the fitting.
      bounds: Rect.fromLTWH(box.left, box.top, 0, 0),
    );
  }
  graphics.restore(state);
}

/// The standard PDF fonts only cover Windows-1252: replace anything else.
String _pdfSafe(String text) => String.fromCharCodes(
  text.runes.map((c) => c < 0x100 || _cp1252Extras.contains(c) ? c : 0x3F),
);

const _cp1252Extras = {
  0x20AC,
  0x201A,
  0x0192,
  0x201E,
  0x2026,
  0x2020,
  0x2021,
  0x02C6,
  0x2030,
  0x0160,
  0x2039,
  0x0152,
  0x017D,
  0x2018,
  0x2019,
  0x201C,
  0x201D,
  0x2022,
  0x2013,
  0x2014,
  0x02DC,
  0x2122,
  0x0161,
  0x203A,
  0x0153,
  0x017E,
  0x0178,
};

/// Large grey text across the page diagonal.
void _drawWatermark(PdfGraphics graphics, Size page, String text) {
  final diagonal = math.sqrt(
    page.width * page.width + page.height * page.height,
  );
  const probeSize = 40.0;
  final probe = PdfStandardFont(PdfFontFamily.helvetica, probeSize);
  final fontSize =
      (probeSize * diagonal * 0.6 / probe.measureString(text).width).clamp(
        14.0,
        110.0,
      );
  final font = PdfStandardFont(
    PdfFontFamily.helvetica,
    fontSize,
    style: PdfFontStyle.bold,
  );
  final size = font.measureString(text);
  final state = graphics.save();
  graphics
    ..setTransparency(0.22)
    ..translateTransform(page.width / 2, page.height / 2)
    ..rotateTransform(-math.atan2(page.height, page.width) * 180 / math.pi)
    ..drawString(
      text,
      font,
      brush: PdfSolidBrush(PdfColor(110, 110, 110)),
      bounds: Rect.fromLTWH(
        -size.width / 2,
        -size.height / 2,
        size.width,
        size.height,
      ),
    );
  graphics.restore(state);
}

Size _pageSize(int width, int height, PageLayout layout) {
  final landscape = width > height;
  switch (layout) {
    case PageLayout.a4:
      return landscape ? Size(_a4.height, _a4.width) : _a4;
    case PageLayout.fitImage:
      // Keep the image's aspect ratio, with the short side as wide as A4.
      return landscape
          ? Size(_a4.width * width / height, _a4.width)
          : Size(_a4.width, _a4.width * height / width);
  }
}

class _Jpeg {
  const _Jpeg(this.bytes, this.width, this.height);

  final Uint8List bytes;
  final int width;
  final int height;
}

_Jpeg _compress(String path, ExportQuality quality) {
  var image = img.decodeImage(File(path).readAsBytesSync());
  if (image == null) throw FormatException('Image illisible', path);
  if (math.max(image.width, image.height) > quality.maxSide) {
    image = image.width >= image.height
        ? img.copyResize(
            image,
            width: quality.maxSide,
            interpolation: img.Interpolation.average,
          )
        : img.copyResize(
            image,
            height: quality.maxSide,
            interpolation: img.Interpolation.average,
          );
  }
  return _Jpeg(
    img.encodeJpg(image, quality: quality.jpegQuality),
    image.width,
    image.height,
  );
}

/// Characters Android and most file systems reject in a file name.
String sanitizeFileName(String name) {
  final cleaned = name
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .trim()
      .replaceAll(RegExp(r'\.+$'), '');
  return cleaned.isEmpty ? 'Scan' : cleaned;
}
