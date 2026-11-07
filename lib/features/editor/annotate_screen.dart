import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/dialogs.dart';

enum _Tool { pen, highlighter, text }

/// A drawn mark or a text label, in fractions of the page.
sealed class _Mark {
  const _Mark(this.color);

  final Color color;
}

class _Stroke extends _Mark {
  _Stroke(super.color, this.width, this.points);

  /// Fraction of the page width.
  final double width;
  final List<Offset> points;
}

class _Label extends _Mark {
  const _Label(super.color, this.text, this.position);

  final String text;
  final Offset position;
}

const _penColors = [Color(0xFFD32F2F), Color(0xFF1A3FA8), Color(0xFF111111)];
const _highlighterColors = [Color(0x66FFEB3B), Color(0x5566BB6A)];
const _labelSize = 0.035;

/// Draws, highlights and writes over [pageImage]. Pops the path of a
/// transparent PNG the size of the page, or `null` if nothing was added.
class AnnotateScreen extends StatefulWidget {
  const AnnotateScreen({
    super.key,
    required this.pageImage,
    required this.tempDir,
  });

  final String pageImage;
  final String tempDir;

  @override
  State<AnnotateScreen> createState() => _AnnotateScreenState();
}

class _AnnotateScreenState extends State<AnnotateScreen> {
  final _marks = <_Mark>[];
  var _tool = _Tool.pen;
  var _penColor = _penColors.first;
  var _highlighterColor = _highlighterColors.first;
  Size? _pageSize;
  var _saving = false;

  @override
  void initState() {
    super.initState();
    FileImage(File(widget.pageImage))
        .resolve(ImageConfiguration.empty)
        .addListener(
          ImageStreamListener((info, _) {
            if (mounted) {
              setState(
                () => _pageSize = Size(
                  info.image.width.toDouble(),
                  info.image.height.toDouble(),
                ),
              );
            }
          }),
        );
  }

  Color get _color =>
      _tool == _Tool.highlighter ? _highlighterColor : _penColor;

  Offset _normalize(Offset local, Size area) =>
      Offset(local.dx / area.width, local.dy / area.height);

  Future<void> _addLabel(Offset position) async {
    final text = await promptText(
      context,
      title: 'Ajouter du texte',
      initial: '',
      confirmLabel: 'Ajouter',
    );
    if (text != null) {
      setState(() => _marks.add(_Label(_penColor, text, position)));
    }
  }

  Future<void> _save() async {
    final page = _pageSize!;
    if (_marks.isEmpty) {
      Navigator.pop(context);
      return;
    }
    setState(() => _saving = true);
    // Rendered at most 2400 px wide: the renderer scales it to the page.
    final scale = math.min(1.0, 2400 / page.width);
    final size = Size(page.width * scale, page.height * scale);
    final recorder = ui.PictureRecorder();
    _paintMarks(Canvas(recorder), size, _marks);
    final image = await recorder.endRecording().toImage(
      size.width.round(),
      size.height.round(),
    );
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final file = File(
      '${widget.tempDir}/annot_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(png!.buffer.asUint8List());
    if (mounted) Navigator.pop(context, file.path);
  }

  Rect _fit(Size page, Size area) {
    final scale = math.min(area.width / page.width, area.height / page.height);
    final w = page.width * scale, h = page.height * scale;
    return Rect.fromLTWH((area.width - w) / 2, (area.height - h) / 2, w, h);
  }

  @override
  Widget build(BuildContext context) {
    final pageSize = _pageSize;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Annoter'),
        actions: [
          IconButton(
            tooltip: 'Annuler',
            icon: const Icon(Icons.undo),
            onPressed: _marks.isEmpty
                ? null
                : () => setState(_marks.removeLast),
          ),
          TextButton(
            onPressed: pageSize == null || _saving ? null : _save,
            child: const Text('Valider'),
          ),
        ],
      ),
      body: pageSize == null
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, constraints) {
                final rect = _fit(pageSize, constraints.biggest);
                return Stack(
                  children: [
                    Positioned.fromRect(
                      rect: rect,
                      child: GestureDetector(
                        onTapUp: _tool == _Tool.text
                            ? (d) => _addLabel(
                                _normalize(d.localPosition, rect.size),
                              )
                            : null,
                        onPanStart: _tool == _Tool.text
                            ? null
                            : (d) => setState(
                                () => _marks.add(
                                  _Stroke(
                                    _color,
                                    _tool == _Tool.highlighter ? 0.03 : 0.004,
                                    [_normalize(d.localPosition, rect.size)],
                                  ),
                                ),
                              ),
                        onPanUpdate: _tool == _Tool.text
                            ? null
                            : (d) => setState(
                                () => (_marks.last as _Stroke).points.add(
                                  _normalize(d.localPosition, rect.size),
                                ),
                              ),
                        child: CustomPaint(
                          foregroundPainter: _MarksPainter(_marks),
                          child: Image.file(
                            File(widget.pageImage),
                            fit: BoxFit.fill,
                          ),
                        ),
                      ),
                    ),
                    if (_saving)
                      const Center(child: CircularProgressIndicator()),
                  ],
                );
              },
            ),
      bottomNavigationBar: Material(
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<_Tool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: _Tool.pen,
                      icon: Icon(Icons.edit),
                      label: Text('Stylo'),
                    ),
                    ButtonSegment(
                      value: _Tool.highlighter,
                      icon: Icon(Icons.border_color),
                      label: Text('Surligner'),
                    ),
                    ButtonSegment(
                      value: _Tool.text,
                      icon: Icon(Icons.title),
                      label: Text('Texte'),
                    ),
                  ],
                  selected: {_tool},
                  onSelectionChanged: (s) => setState(() => _tool = s.first),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final color
                        in _tool == _Tool.highlighter
                            ? _highlighterColors
                            : _penColors)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => setState(() {
                            if (_tool == _Tool.highlighter) {
                              _highlighterColor = color;
                            } else {
                              _penColor = color;
                            }
                          }),
                          child: CircleAvatar(
                            radius: 16,
                            backgroundColor: color.withValues(alpha: 1),
                            child: color == _color
                                ? const Icon(
                                    Icons.check,
                                    size: 18,
                                    color: Colors.white,
                                  )
                                : null,
                          ),
                        ),
                      ),
                  ],
                ),
                if (_tool == _Tool.text)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text('Touche la page à l\'endroit du texte'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared by the live preview and the exported PNG so both look the same.
void _paintMarks(Canvas canvas, Size size, List<_Mark> marks) {
  for (final mark in marks) {
    switch (mark) {
      case _Stroke(:final points, :final width, :final color):
        final path = Path();
        final first = points.first;
        path.moveTo(first.dx * size.width, first.dy * size.height);
        if (points.length == 1) {
          path.lineTo(first.dx * size.width + 0.1, first.dy * size.height);
        }
        for (final point in points.skip(1)) {
          path.lineTo(point.dx * size.width, point.dy * size.height);
        }
        canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = width * size.width
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
      case _Label(:final text, :final position, :final color):
        final painter = TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(
              color: color,
              fontSize: _labelSize * size.width,
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: size.width * (1 - position.dx));
        painter.paint(
          canvas,
          Offset(position.dx * size.width, position.dy * size.height) -
              Offset(0, painter.height / 2),
        );
        painter.dispose();
    }
  }
}

class _MarksPainter extends CustomPainter {
  _MarksPainter(this.marks);

  final List<_Mark> marks;

  @override
  void paint(Canvas canvas, Size size) => _paintMarks(canvas, size, marks);

  // Marks are mutated in place while drawing.
  @override
  bool shouldRepaint(_MarksPainter oldDelegate) => true;
}
