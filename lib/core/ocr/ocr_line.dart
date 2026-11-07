import 'dart:convert';

/// One recognised line of text. The box is expressed as fractions of the
/// rendered page, like [PageOverlay], so it maps onto any export size.
class OcrLine {
  const OcrLine({
    required this.text,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  factory OcrLine.fromJson(Map<String, dynamic> json) => OcrLine(
    text: json['t'] as String,
    left: (json['x'] as num).toDouble(),
    top: (json['y'] as num).toDouble(),
    width: (json['w'] as num).toDouble(),
    height: (json['h'] as num).toDouble(),
  );

  final String text;
  final double left;
  final double top;
  final double width;
  final double height;

  Map<String, dynamic> toJson() => {
    't': text,
    'x': left,
    'y': top,
    'w': width,
    'h': height,
  };

  static List<OcrLine> decode(String? json) => json == null
      ? const []
      : [
          for (final item in jsonDecode(json) as List)
            OcrLine.fromJson(item as Map<String, dynamic>),
        ];

  static String encode(List<OcrLine> lines) =>
      jsonEncode([for (final l in lines) l.toJson()]);
}
