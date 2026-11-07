import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/providers.dart';

const _inks = [Color(0xFF111111), Color(0xFF1A3FA8)];
const _strokeWidth = 3.0;

/// Exported at this multiple of the on-screen size so the signature stays
/// sharp on a full-resolution page.
const _exportScale = 4.0;

/// Draws a new signature, saves it as a transparent PNG and pops its path.
class SignaturePadScreen extends ConsumerStatefulWidget {
  const SignaturePadScreen({super.key});

  @override
  ConsumerState<SignaturePadScreen> createState() => _SignaturePadScreenState();
}

class _SignaturePadScreenState extends ConsumerState<SignaturePadScreen> {
  final _strokes = <List<Offset>>[];
  var _ink = _inks.first;

  Future<void> _save() async {
    final points = _strokes.expand((s) => s);
    if (points.isEmpty) return;
    const pad = _strokeWidth * 2;
    final bounds = Rect.fromLTRB(
      points.map((o) => o.dx).reduce(math.min) - pad,
      points.map((o) => o.dy).reduce(math.min) - pad,
      points.map((o) => o.dx).reduce(math.max) + pad,
      points.map((o) => o.dy).reduce(math.max) + pad,
    );
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
      ..scale(_exportScale)
      ..translate(-bounds.left, -bounds.top)
      ..drawPath(_path(_strokes), _paint(_ink));
    final image = await recorder.endRecording().toImage(
      (bounds.width * _exportScale).ceil(),
      (bounds.height * _exportScale).ceil(),
    );
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (png == null) return;

    final dir = ref.read(fileStoreProvider).signaturesDir;
    await dir.create(recursive: true);
    final file = File(
      p.join(dir.path, '${DateTime.now().millisecondsSinceEpoch}.png'),
    );
    await file.writeAsBytes(png.buffer.asUint8List());
    if (mounted) Navigator.pop(context, file.path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nouvelle signature'),
        actions: [
          IconButton(
            tooltip: 'Annuler le dernier trait',
            icon: const Icon(Icons.undo),
            onPressed: _strokes.isEmpty
                ? null
                : () => setState(_strokes.removeLast),
          ),
          IconButton(
            tooltip: 'Effacer',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _strokes.isEmpty ? null : () => setState(_strokes.clear),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              clipBehavior: Clip.antiAlias,
              child: GestureDetector(
                onPanStart: (d) =>
                    setState(() => _strokes.add([d.localPosition])),
                onPanUpdate: (d) =>
                    setState(() => _strokes.last.add(d.localPosition)),
                child: CustomPaint(
                  painter: _StrokesPainter(_strokes, _ink),
                  child: _strokes.isEmpty
                      ? const Center(
                          child: Text(
                            'Signe ici',
                            style: TextStyle(
                              color: Colors.black38,
                              fontSize: 20,
                            ),
                          ),
                        )
                      : const SizedBox.expand(),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  for (final ink in _inks)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => setState(() => _ink = ink),
                        child: CircleAvatar(
                          radius: 18,
                          backgroundColor: ink,
                          child: ink == _ink
                              ? const Icon(Icons.check, color: Colors.white)
                              : null,
                        ),
                      ),
                    ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _strokes.isEmpty ? null : _save,
                    icon: const Icon(Icons.check),
                    label: const Text('Enregistrer'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Paint _paint(Color ink) => Paint()
  ..color = ink
  ..style = PaintingStyle.stroke
  ..strokeWidth = _strokeWidth
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round
  ..isAntiAlias = true;

/// Smooths each stroke with quadratic curves through the segment midpoints.
Path _path(List<List<Offset>> strokes) {
  final path = Path();
  for (final stroke in strokes) {
    path.moveTo(stroke.first.dx, stroke.first.dy);
    if (stroke.length == 1) {
      path.lineTo(stroke.first.dx + 0.1, stroke.first.dy);
      continue;
    }
    for (var i = 1; i < stroke.length - 1; i++) {
      final mid = (stroke[i] + stroke[i + 1]) / 2;
      path.quadraticBezierTo(stroke[i].dx, stroke[i].dy, mid.dx, mid.dy);
    }
    path.lineTo(stroke.last.dx, stroke.last.dy);
  }
  return path;
}

class _StrokesPainter extends CustomPainter {
  _StrokesPainter(this.strokes, this.ink);

  final List<List<Offset>> strokes;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) =>
      canvas.drawPath(_path(strokes), _paint(ink));

  // Strokes are mutated in place, so always repaint.
  @override
  bool shouldRepaint(_StrokesPainter oldDelegate) => true;
}
