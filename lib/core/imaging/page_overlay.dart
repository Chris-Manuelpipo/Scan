import 'dart:convert';

/// An image (a signature for now) drawn over a page. The rectangle is
/// expressed as fractions of the rendered page, so it stays in place whatever
/// the export resolution.
class PageOverlay {
  const PageOverlay({
    required this.imagePath,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  factory PageOverlay.fromJson(Map<String, dynamic> json) => PageOverlay(
    imagePath: json['image'] as String,
    left: (json['x'] as num).toDouble(),
    top: (json['y'] as num).toDouble(),
    width: (json['w'] as num).toDouble(),
    height: (json['h'] as num).toDouble(),
  );

  /// Relative to the file store root when stored, absolute when rendering.
  final String imagePath;
  final double left;
  final double top;
  final double width;
  final double height;

  PageOverlay withImage(String path) => PageOverlay(
    imagePath: path,
    left: left,
    top: top,
    width: width,
    height: height,
  );

  Map<String, dynamic> toJson() => {
    'image': imagePath,
    'x': left,
    'y': top,
    'w': width,
    'h': height,
  };

  static List<PageOverlay> decode(String? json) => json == null
      ? const []
      : [
          for (final item in jsonDecode(json) as List)
            PageOverlay.fromJson(item as Map<String, dynamic>),
        ];

  static String? encode(List<PageOverlay> overlays) => overlays.isEmpty
      ? null
      : jsonEncode([for (final o in overlays) o.toJson()]);
}
