import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// A4 at 300 dpi.
const _a4Width = 2480, _a4Height = 3508;

/// ID-1 card (ID, bank or health card): 85.6 mm wide at 300 dpi.
const _cardWidth = 1011;

/// Lays the front and back of a card out at real size on one A4 page, like a
/// photocopy, and writes it to [target].
Future<void> composeIdCard({
  required String front,
  String? back,
  required String target,
}) {
  return Isolate.run(() {
    final page = img.Image(width: _a4Width, height: _a4Height)
      ..clear(img.ColorRgb8(255, 255, 255));
    final sides = [front, ?back];
    for (final (i, path) in sides.indexed) {
      var card = img.bakeOrientation(
        img.decodeImage(File(path).readAsBytesSync()) ??
            (throw FormatException('Image illisible', path)),
      );
      // Cards are landscape: a portrait photo was taken sideways.
      if (card.height > card.width) card = img.copyRotate(card, angle: -90);
      card = img.copyResize(
        card,
        width: _cardWidth,
        interpolation: img.Interpolation.average,
      );
      final centreY = sides.length == 1
          ? _a4Height * 0.3
          : _a4Height * (i == 0 ? 0.27 : 0.62);
      img.compositeImage(
        page,
        card,
        dstX: (_a4Width - card.width) ~/ 2,
        dstY: (centreY - card.height / 2).round(),
      );
    }
    File(target).writeAsBytesSync(img.encodeJpg(page, quality: 92));
  });
}

/// Cuts a photo of an open book into its left and right pages, along the
/// darkest column near the middle (the gutter). Returns the two image paths.
Future<List<String>> splitSpread(String source, String outputDir, String stem) {
  return Isolate.run(() {
    final image = img.bakeOrientation(
      img.decodeImage(File(source).readAsBytesSync()) ??
          (throw FormatException('Image illisible', source)),
    );
    final cut = _gutter(image);
    final left = img.copyCrop(
      image,
      x: 0,
      y: 0,
      width: cut,
      height: image.height,
    );
    final right = img.copyCrop(
      image,
      x: cut,
      y: 0,
      width: image.width - cut,
      height: image.height,
    );
    final outputs = <String>[];
    for (final (suffix, half) in [('g', left), ('d', right)]) {
      final path = p.join(outputDir, '${stem}_$suffix.jpg');
      File(path).writeAsBytesSync(img.encodeJpg(half, quality: 92));
      outputs.add(path);
    }
    return outputs;
  });
}

int _gutter(img.Image image) {
  final small = img.grayscale(
    img.copyResize(image, width: 400, interpolation: img.Interpolation.average),
  );
  final means = <double>[];
  for (var x = 0; x < small.width; x++) {
    var sum = 0.0;
    for (var y = 0; y < small.height; y++) {
      sum += small.getPixel(x, y).r;
    }
    means.add(sum / small.height);
  }
  final from = (small.width * 0.4).round(), to = (small.width * 0.6).round();
  var best = small.width ~/ 2;
  for (var x = from; x < to; x++) {
    if (means[x] < means[best]) best = x;
  }
  // No visible fold: fall back to the middle.
  final median = ([...means]..sort())[means.length ~/ 2];
  if (means[best] > median * 0.92) best = small.width ~/ 2;
  return math.max(1, (best * image.width / small.width).round());
}
