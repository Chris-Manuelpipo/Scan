import 'dart:convert';
import 'dart:ui' show Offset;

/// Four corners of a manual crop, as fractions of the original image (after
/// EXIF orientation, before the page rotation). The area is straightened into
/// a rectangle when the page is rendered.
class CropQuad {
  const CropQuad(
    this.topLeft,
    this.topRight,
    this.bottomRight,
    this.bottomLeft,
  );

  static const full = CropQuad(
    Offset(0, 0),
    Offset(1, 0),
    Offset(1, 1),
    Offset(0, 1),
  );

  final Offset topLeft;
  final Offset topRight;
  final Offset bottomRight;
  final Offset bottomLeft;

  List<Offset> get corners => [topLeft, topRight, bottomRight, bottomLeft];

  bool get isFull =>
      corners.indexed.every((e) => (e.$2 - full.corners[e.$1]).distance < 1e-3);

  static CropQuad fromCorners(List<Offset> c) =>
      CropQuad(c[0], c[1], c[2], c[3]);

  static CropQuad? decode(String? json) {
    if (json == null) return null;
    final v = [for (final n in jsonDecode(json) as List) (n as num).toDouble()];
    return fromCorners([for (var i = 0; i < 8; i += 2) Offset(v[i], v[i + 1])]);
  }

  /// `null` for a full-image crop, which is the same as no crop.
  static String? encode(CropQuad? quad) => quad == null || quad.isFull
      ? null
      : jsonEncode([
          for (final c in quad.corners) ...[c.dx, c.dy],
        ]);
}
