import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'dart:ui' show Offset;

import 'package:image/image.dart' as img;

import '../db/database.dart';
import 'crop_quad.dart';
import 'page_overlay.dart';

/// Longest side kept for a processed page: A4 at 300 dpi.
const _maxSide = 3508;
const _thumbSide = 480;

class PageRenderJob {
  const PageRenderJob({
    required this.source,
    required this.target,
    required this.thumb,
    required this.quarterTurns,
    required this.filter,
    this.overlays = const [],
    this.crop,
  });

  final String source;
  final String target;
  final String thumb;
  final int quarterTurns;
  final PageFilter filter;

  /// With absolute image paths.
  final List<PageOverlay> overlays;

  final CropQuad? crop;
}

/// Renders the original image with its rotation and filter into [target] and
/// a small preview into [thumb], off the UI isolate.
Future<void> renderPage(PageRenderJob job) => Isolate.run(() => _render(job));

void _render(PageRenderJob job) {
  var image = img.decodeImage(File(job.source).readAsBytesSync());
  if (image == null) throw FormatException('Image illisible', job.source);
  image = img.bakeOrientation(image);
  if (job.crop case final crop?) {
    // Shrink first: straightening a 12 MP photo pixel by pixel is slow.
    image = _straighten(_limit(image, _maxSide + 1000), crop);
  }
  image = _limit(image, _maxSide);
  if (image.numChannels != 3 || image.bitsPerChannel != 8) {
    image = image.convert(numChannels: 3, format: img.Format.uint8);
  }
  final turns = job.quarterTurns % 4;
  if (turns != 0) image = img.copyRotate(image, angle: 90 * turns);
  image = applyFilter(image, job.filter);
  for (final overlay in job.overlays) {
    _drawOverlay(image, overlay);
  }

  File(job.target).writeAsBytesSync(img.encodeJpg(image, quality: 90));
  File(
    job.thumb,
  ).writeAsBytesSync(img.encodeJpg(_limit(image, _thumbSide), quality: 80));
}

/// Maps the [crop] quadrilateral onto an upright rectangle whose size is the
/// average length of its opposite edges.
img.Image _straighten(img.Image image, CropQuad crop) {
  img.Point px(Offset o) => img.Point(o.dx * image.width, o.dy * image.height);
  final tl = px(crop.topLeft), tr = px(crop.topRight);
  final br = px(crop.bottomRight), bl = px(crop.bottomLeft);
  double dist(img.Point a, img.Point b) =>
      math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));
  final width = ((dist(tl, tr) + dist(bl, br)) / 2).round();
  final height = ((dist(tl, bl) + dist(tr, br)) / 2).round();
  if (width < 8 || height < 8) return image;
  return img.copyRectify(
    image,
    topLeft: tl,
    topRight: tr,
    bottomLeft: bl,
    bottomRight: br,
    interpolation: img.Interpolation.linear,
    toImage: img.Image(
      width: width,
      height: height,
      numChannels: image.numChannels,
    ),
  );
}

void _drawOverlay(img.Image page, PageOverlay overlay) {
  final source = img.decodeImage(File(overlay.imagePath).readAsBytesSync());
  if (source == null) return;
  final w = (overlay.width * page.width).round();
  final h = (overlay.height * page.height).round();
  if (w <= 0 || h <= 0) return;
  img.compositeImage(
    page,
    img.copyResize(
      source,
      width: w,
      height: h,
      interpolation: img.Interpolation.cubic,
    ),
    dstX: (overlay.left * page.width).round(),
    dstY: (overlay.top * page.height).round(),
  );
}

img.Image _limit(img.Image image, int maxSide) {
  if (math.max(image.width, image.height) <= maxSide) return image;
  return image.width >= image.height
      ? img.copyResize(
          image,
          width: maxSide,
          interpolation: img.Interpolation.average,
        )
      : img.copyResize(
          image,
          height: maxSide,
          interpolation: img.Interpolation.average,
        );
}

/// Expects an 8-bit RGB image.
img.Image applyFilter(img.Image image, PageFilter filter) {
  switch (filter) {
    case PageFilter.original:
      return image;
    case PageFilter.grayscale:
      return img.grayscale(image);
    case PageFilter.enhanced:
      return _mapPixels(image, _enhance);
    case PageFilter.blackWhite:
      return _mapPixels(image, _blackWhite);
    case PageFilter.whiteboard:
      return _mapPixels(image, _whiteboard);
  }
}

typedef _PixelOp =
    void Function(Uint8List src, Uint8List dst, int i, double background);

/// Divides every pixel by an estimate of the paper brightness around it, which
/// removes shadows and uneven lighting before the filter-specific step.
img.Image _mapPixels(img.Image image, _PixelOp op) {
  final w = image.width, h = image.height;
  final src = image.getBytes(order: img.ChannelOrder.rgb);
  final dst = Uint8List(src.length);
  final bg = _PaperBackground(src, w, h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      op(src, dst, (y * w + x) * 3, bg.at(x, y));
    }
  }
  return img.Image.fromBytes(
    width: w,
    height: h,
    bytes: dst.buffer,
    numChannels: 3,
  );
}

final _enhanceCurve = Uint8List.fromList([
  for (var v = 0; v < 256; v++) (255 * math.pow(v / 255, 1.6)).round(),
]);

void _enhance(Uint8List src, Uint8List dst, int i, double background) {
  final gain = 255 / math.max(background, 24);
  for (var c = 0; c < 3; c++) {
    final v = (src[i + c] * gain).clamp(0, 255).toInt();
    dst[i + c] = _enhanceCurve[v];
  }
}

/// White board or slide: paper/board pushed to pure white, marker colours
/// saturated so they stay readable.
void _whiteboard(Uint8List src, Uint8List dst, int i, double background) {
  final gain = 255 / math.max(background, 24);
  final r = src[i] * gain, g = src[i + 1] * gain, b = src[i + 2] * gain;
  final lum = 0.299 * r + 0.587 * g + 0.114 * b;
  if (lum > 225) {
    dst[i] = dst[i + 1] = dst[i + 2] = 255;
    return;
  }
  for (final (c, v) in [(0, r), (1, g), (2, b)]) {
    final saturated = (lum + (v - lum) * 1.8).clamp(0, 255).toInt();
    dst[i + c] = _enhanceCurve[saturated];
  }
}

void _blackWhite(Uint8List src, Uint8List dst, int i, double background) {
  final lum = 0.299 * src[i] + 0.587 * src[i + 1] + 0.114 * src[i + 2];
  final ratio = lum / math.max(background, 24);
  // Soft threshold keeps glyph edges smooth instead of jagged.
  final t = ((ratio - 0.72) / 0.14).clamp(0.0, 1.0);
  final v = (255 * t * t * (3 - 2 * t)).round();
  dst[i] = v;
  dst[i + 1] = v;
  dst[i + 2] = v;
}

/// Low-resolution luminance map of the page with text removed (max filter)
/// and smoothed, sampled with bilinear interpolation.
class _PaperBackground {
  _PaperBackground(Uint8List rgb, int width, int height)
    : _scale = math.max(1, math.max(width, height) ~/ 400) {
    _w = (width + _scale - 1) ~/ _scale;
    _h = (height + _scale - 1) ~/ _scale;
    var map = Float32List(_w * _h);
    final counts = Int32List(_w * _h);
    for (var y = 0; y < height; y++) {
      final row = (y ~/ _scale) * _w;
      for (var x = 0; x < width; x++) {
        final i = (y * width + x) * 3;
        final cell = row + x ~/ _scale;
        map[cell] += 0.299 * rgb[i] + 0.587 * rgb[i + 1] + 0.114 * rgb[i + 2];
        counts[cell]++;
      }
    }
    for (var i = 0; i < map.length; i++) {
      map[i] /= counts[i];
    }
    map = _maxFilter(map, 3);
    map = _boxBlur(_boxBlur(map, 4), 4);
    _map = map;
  }

  final int _scale;
  late final int _w;
  late final int _h;
  late final Float32List _map;

  double at(int x, int y) {
    final fx = ((x + 0.5) / _scale - 0.5).clamp(0.0, _w - 1.0);
    final fy = ((y + 0.5) / _scale - 0.5).clamp(0.0, _h - 1.0);
    final x0 = fx.floor(), y0 = fy.floor();
    final x1 = math.min(x0 + 1, _w - 1), y1 = math.min(y0 + 1, _h - 1);
    final ax = fx - x0, ay = fy - y0;
    final top = _map[y0 * _w + x0] * (1 - ax) + _map[y0 * _w + x1] * ax;
    final bottom = _map[y1 * _w + x0] * (1 - ax) + _map[y1 * _w + x1] * ax;
    return top * (1 - ay) + bottom * ay;
  }

  Float32List _maxFilter(Float32List src, int r) =>
      _separable(src, r, (a, b) => math.max(a, b), (acc, n) => acc);

  Float32List _boxBlur(Float32List src, int r) =>
      _separable(src, r, (a, b) => a + b, (acc, n) => acc / n, seed: 0);

  Float32List _separable(
    Float32List src,
    int r,
    double Function(double, double) combine,
    double Function(double acc, int n) finish, {
    double seed = 0,
  }) {
    final tmp = Float32List(src.length);
    final out = Float32List(src.length);
    for (var y = 0; y < _h; y++) {
      for (var x = 0; x < _w; x++) {
        var acc = seed;
        var n = 0;
        for (var k = math.max(0, x - r); k <= math.min(_w - 1, x + r); k++) {
          acc = combine(acc, src[y * _w + k]);
          n++;
        }
        tmp[y * _w + x] = finish(acc, n);
      }
    }
    for (var y = 0; y < _h; y++) {
      for (var x = 0; x < _w; x++) {
        var acc = seed;
        var n = 0;
        for (var k = math.max(0, y - r); k <= math.min(_h - 1, y + r); k++) {
          acc = combine(acc, tmp[k * _w + x]);
          n++;
        }
        out[y * _w + x] = finish(acc, n);
      }
    }
    return out;
  }
}
