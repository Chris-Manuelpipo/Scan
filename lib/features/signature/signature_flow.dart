import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dialogs.dart';
import '../../app/providers.dart';
import '../../core/imaging/page_overlay.dart';
import 'signature_pad_screen.dart';

/// Lets the user pick (or draw) a signature, then place it on [pageImage].
/// Returns the overlay with an absolute signature path, or `null`.
Future<PageOverlay?> pickAndPlaceSignature(
  BuildContext context,
  WidgetRef ref,
  String pageImage,
) async {
  final signature = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _SignaturePicker(),
  );
  if (signature == null || !context.mounted) return null;
  return Navigator.of(context).push<PageOverlay>(
    MaterialPageRoute(
      builder: (_) =>
          _PlaceSignatureScreen(pageImage: pageImage, signature: signature),
    ),
  );
}

class _SignaturePicker extends ConsumerStatefulWidget {
  const _SignaturePicker();

  @override
  ConsumerState<_SignaturePicker> createState() => _SignaturePickerState();
}

class _SignaturePickerState extends ConsumerState<_SignaturePicker> {
  List<File> _signatures() {
    final dir = ref.read(fileStoreProvider).signaturesDir;
    if (!dir.existsSync()) return [];
    return dir.listSync().whereType<File>().toList()
      ..sort((a, b) => b.path.compareTo(a.path));
  }

  Future<void> _draw() async {
    final path = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const SignaturePadScreen()),
    );
    if (path != null && mounted) Navigator.pop(context, path);
  }

  Future<void> _delete(File file) async {
    if (await confirm(
      context,
      title: 'Supprimer cette signature ?',
      message: 'Les pages déjà signées ne changent pas.',
    )) {
      await file.delete();
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final signatures = _signatures();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Signer', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            if (signatures.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: GridView.count(
                  shrinkWrap: true,
                  crossAxisCount: 2,
                  childAspectRatio: 2,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  children: [
                    for (final file in signatures)
                      Material(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => Navigator.pop(context, file.path),
                          onLongPress: () => _delete(file),
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Image.file(file),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (signatures.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Appui long sur une signature pour la supprimer.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _draw,
              icon: const Icon(Icons.draw_outlined),
              label: const Text('Nouvelle signature'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaceSignatureScreen extends StatefulWidget {
  const _PlaceSignatureScreen({
    required this.pageImage,
    required this.signature,
  });

  final String pageImage;
  final String signature;

  @override
  State<_PlaceSignatureScreen> createState() => _PlaceSignatureScreenState();
}

class _PlaceSignatureScreenState extends State<_PlaceSignatureScreen> {
  Size? _pageSize;
  Size? _signatureSize;

  /// Signature rectangle as fractions of the page.
  var _left = 0.5, _top = 0.75, _width = 0.35;

  @override
  void initState() {
    super.initState();
    _resolveSize(widget.pageImage, (s) => _pageSize = s);
    _resolveSize(widget.signature, (s) => _signatureSize = s);
  }

  void _resolveSize(String path, void Function(Size) assign) {
    FileImage(File(path))
        .resolve(ImageConfiguration.empty)
        .addListener(
          ImageStreamListener((info, _) {
            if (!mounted) return;
            setState(
              () => assign(
                Size(info.image.width.toDouble(), info.image.height.toDouble()),
              ),
            );
          }),
        );
  }

  /// Height as a fraction of the page height, keeping the signature ratio.
  double get _height =>
      _width *
      _pageSize!.width /
      _pageSize!.height *
      _signatureSize!.height /
      _signatureSize!.width;

  void _clamp() {
    _width = _width.clamp(0.05, 1.0);
    if (_height > 1) _width = _width / _height;
    _left = _left.clamp(0.0, 1 - _width);
    _top = _top.clamp(0.0, 1 - _height);
  }

  @override
  Widget build(BuildContext context) {
    final ready = _pageSize != null && _signatureSize != null;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Placer la signature'),
        actions: [
          TextButton(
            onPressed: !ready
                ? null
                : () => Navigator.pop(
                    context,
                    PageOverlay(
                      imagePath: widget.signature,
                      left: _left,
                      top: _top,
                      width: _width,
                      height: _height,
                    ),
                  ),
            child: const Text('Valider'),
          ),
        ],
      ),
      body: !ready
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, constraints) {
                final page = _fit(_pageSize!, constraints.biggest);
                _clamp();
                final box = Rect.fromLTWH(
                  page.left + _left * page.width,
                  page.top + _top * page.height,
                  _width * page.width,
                  _height * page.height,
                );
                return Stack(
                  children: [
                    Positioned.fromRect(
                      rect: page,
                      child: Image.file(File(widget.pageImage)),
                    ),
                    Positioned.fromRect(
                      rect: box,
                      child: GestureDetector(
                        onPanUpdate: (d) => setState(() {
                          _left += d.delta.dx / page.width;
                          _top += d.delta.dy / page.height;
                        }),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Theme.of(context).colorScheme.primary,
                              width: 1.5,
                            ),
                          ),
                          child: Image.file(
                            File(widget.signature),
                            fit: BoxFit.fill,
                          ),
                        ),
                      ),
                    ),
                    // Resize handle on the bottom-right corner.
                    Positioned(
                      left: box.right - 18,
                      top: box.bottom - 18,
                      child: GestureDetector(
                        onPanUpdate: (d) =>
                            setState(() => _width += d.delta.dx / page.width),
                        child: CircleAvatar(
                          radius: 18,
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.primary,
                          child: const Icon(
                            Icons.open_in_full,
                            size: 18,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
      bottomNavigationBar: const SafeArea(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Fais glisser la signature pour la placer, '
            'et le rond pour la redimensionner.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70),
          ),
        ),
      ),
    );
  }

  Rect _fit(Size image, Size area) {
    final scale = math.min(
      area.width / image.width,
      area.height / image.height,
    );
    final w = image.width * scale, h = image.height * scale;
    return Rect.fromLTWH((area.width - w) / 2, (area.height - h) / 2, w, h);
  }
}
