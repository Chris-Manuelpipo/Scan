import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/imaging/crop_quad.dart';

/// Lets the user drag the four corners of the area to keep on the original
/// image. Pops the new [CropQuad] (or [CropQuad.full] to remove the crop).
class CropScreen extends StatefulWidget {
  const CropScreen({
    super.key,
    required this.original,
    required this.quarterTurns,
    this.initial,
  });

  final String original;

  /// Page rotation, so the image is shown the way the page looks.
  final int quarterTurns;
  final CropQuad? initial;

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  late final ImageProvider _image = ResizeImage(
    FileImage(File(widget.original)),
    width: 1600,
    policy: ResizeImagePolicy.fit,
  );
  late List<Offset> _corners = (widget.initial ?? CropQuad.full).corners;
  double? _aspect;
  int? _active;

  @override
  void initState() {
    super.initState();
    _image
        .resolve(ImageConfiguration.empty)
        .addListener(
          ImageStreamListener((info, _) {
            if (mounted) {
              setState(() => _aspect = info.image.width / info.image.height);
            }
          }),
        );
  }

  Rect _fit(Size area) {
    const margin = 24.0;
    final w = area.width - 2 * margin, h = area.height - 2 * margin;
    final scale = math.min(w / _aspect!, h);
    final size = Size(scale * _aspect!, scale);
    return Rect.fromLTWH(
      (area.width - size.width) / 2,
      (area.height - size.height) / 2,
      size.width,
      size.height,
    );
  }

  void _drag(Offset local, Rect image) {
    final active = _active;
    if (active == null) return;
    final p = Offset(
      ((local.dx - image.left) / image.width).clamp(0.0, 1.0),
      ((local.dy - image.top) / image.height).clamp(0.0, 1.0),
    );
    setState(() => _corners = [..._corners]..[active] = p);
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Recadrer'),
        actions: [
          TextButton(
            onPressed: () => setState(() => _corners = CropQuad.full.corners),
            child: const Text('Tout'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, CropQuad.fromCorners(_corners)),
            child: const Text('Valider'),
          ),
        ],
      ),
      body: _aspect == null
          ? const Center(child: CircularProgressIndicator())
          : RotatedBox(
              quarterTurns: widget.quarterTurns,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final image = _fit(constraints.biggest);
                  // Inside the RotatedBox, so positions are in image space.
                  return GestureDetector(
                    onPanStart: (d) {
                      final points = [
                        for (final c in _corners)
                          image.topLeft +
                              Offset(c.dx * image.width, c.dy * image.height),
                      ];
                      var nearest = 0;
                      for (var i = 1; i < 4; i++) {
                        if ((points[i] - d.localPosition).distance <
                            (points[nearest] - d.localPosition).distance) {
                          nearest = i;
                        }
                      }
                      _active = nearest;
                    },
                    onPanUpdate: (d) => _drag(d.localPosition, image),
                    onPanEnd: (_) => setState(() => _active = null),
                    child: Stack(
                      children: [
                        Positioned.fromRect(
                          rect: image,
                          child: Image(image: _image, fit: BoxFit.fill),
                        ),
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _QuadPainter(
                              image: image,
                              corners: _corners,
                              active: _active,
                              color: primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
      bottomNavigationBar: const SafeArea(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Fais glisser les coins sur les bords du document. '
            'La zone sera redressée.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70),
          ),
        ),
      ),
    );
  }
}

class _QuadPainter extends CustomPainter {
  _QuadPainter({
    required this.image,
    required this.corners,
    required this.active,
    required this.color,
  });

  final Rect image;
  final List<Offset> corners;
  final int? active;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final points = [
      for (final c in corners)
        image.topLeft + Offset(c.dx * image.width, c.dy * image.height),
    ];
    final quad = Path()..addPolygon(points, true);
    // Dim everything outside the kept area.
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(image), quad),
      Paint()..color = Colors.black54,
    );
    canvas.drawPath(
      quad,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    for (final (i, point) in points.indexed) {
      canvas
        ..drawCircle(point, i == active ? 16 : 12, Paint()..color = color)
        ..drawCircle(
          point,
          i == active ? 16 : 12,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
    }
  }

  @override
  bool shouldRepaint(_QuadPainter old) =>
      old.corners != corners || old.active != active || old.image != image;
}
