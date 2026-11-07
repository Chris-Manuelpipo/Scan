import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

const _dpi = 200;
const _maxSide = 3000;

/// Renders every page of [pdfPath] to a JPEG in [outputDir], in page order.
/// [askPassword] is called again after each wrong password; returning `null`
/// aborts with a [PdfPasswordException].
Future<List<String>> rasterizePdf(
  String pdfPath,
  String outputDir, {
  PdfPasswordProvider? askPassword,
}) async {
  await pdfrxFlutterInitialize();
  final document = await PdfDocument.openFile(
    pdfPath,
    passwordProvider: askPassword,
  );
  try {
    final outputs = <String>[];
    for (final page in document.pages) {
      var scale = _dpi / 72;
      scale = math.min(scale, _maxSide / math.max(page.width, page.height));
      final w = (page.width * scale).round(), h = (page.height * scale).round();
      final rendered = await page.render(
        width: w,
        height: h,
        fullWidth: w.toDouble(),
        fullHeight: h.toDouble(),
        backgroundColor: 0xFFFFFFFF,
      );
      if (rendered == null) continue;
      final pixels = Uint8List.fromList(rendered.pixels);
      final width = rendered.width, height = rendered.height;
      rendered.dispose();

      final target = p.join(
        outputDir,
        'pdf_${page.pageNumber.toString().padLeft(4, '0')}.jpg',
      );
      await Isolate.run(() {
        final image = img.Image.fromBytes(
          width: width,
          height: height,
          bytes: pixels.buffer,
          numChannels: 4,
          order: img.ChannelOrder.bgra,
        );
        File(target).writeAsBytesSync(img.encodeJpg(image, quality: 92));
      });
      outputs.add(target);
    }
    return outputs;
  } finally {
    await document.dispose();
  }
}
