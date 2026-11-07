import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/dialogs.dart';

const _openableSchemes = {
  'http',
  'https',
  'tel',
  'mailto',
  'geo',
  'sms',
  'smsto',
};

/// Reads QR codes and barcodes from the camera or a gallery image.
class BarcodeScreen extends StatefulWidget {
  const BarcodeScreen({super.key});

  @override
  State<BarcodeScreen> createState() => _BarcodeScreenState();
}

class _BarcodeScreenState extends State<BarcodeScreen> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  var _showingResult = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    final barcode = capture.barcodes.firstOrNull;
    if (barcode?.rawValue == null || _showingResult) return;
    _showingResult = true;
    await _controller.stop();
    if (mounted) await _showResult(barcode!);
    _showingResult = false;
    if (mounted) await _controller.start();
  }

  Future<void> _fromGallery() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final capture = await _controller.analyzeImage(file.path);
    if (!mounted) return;
    if (capture == null || capture.barcodes.isEmpty) {
      showMessage(context, 'Aucun code trouvé dans cette image');
      return;
    }
    await _onDetect(capture);
  }

  Future<void> _showResult(Barcode barcode) {
    final value = barcode.rawValue!;
    final uri = Uri.tryParse(value);
    final openable = uri != null && _openableSchemes.contains(uri.scheme);
    final wifi = barcode.wifi;
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _typeLabel(barcode),
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 8),
              if (wifi != null) ...[
                SelectableText('Réseau : ${wifi.ssid ?? ''}'),
                SelectableText('Mot de passe : ${wifi.password ?? ''}'),
              ] else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      value,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (openable)
                    FilledButton.icon(
                      onPressed: () =>
                          launchUrl(uri, mode: LaunchMode.externalApplication),
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Ouvrir'),
                    ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: wifi?.password ?? value),
                      );
                      if (context.mounted) {
                        showMessage(
                          context,
                          wifi != null ? 'Mot de passe copié' : 'Copié',
                        );
                      }
                    },
                    icon: const Icon(Icons.copy),
                    label: Text(
                      wifi != null ? 'Copier le mot de passe' : 'Copier',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () =>
                        SharePlus.instance.share(ShareParams(text: value)),
                    icon: const Icon(Icons.share),
                    label: const Text('Partager'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _typeLabel(Barcode barcode) => switch (barcode.type) {
    BarcodeType.url => 'Lien',
    BarcodeType.wifi => 'Wi-Fi',
    BarcodeType.email => 'E-mail',
    BarcodeType.phone => 'Téléphone',
    BarcodeType.sms => 'SMS',
    BarcodeType.geo => 'Position',
    BarcodeType.contactInfo => 'Contact',
    BarcodeType.calendarEvent => 'Événement',
    BarcodeType.isbn => 'ISBN (livre)',
    BarcodeType.product => 'Produit',
    _ => barcode.format == BarcodeFormat.qrCode ? 'QR code' : 'Code-barres',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('QR code / code-barres'),
        actions: [
          IconButton(
            tooltip: 'Lampe',
            icon: const Icon(Icons.flashlight_on_outlined),
            onPressed: _controller.toggleTorch,
          ),
          IconButton(
            tooltip: 'Depuis la galerie',
            icon: const Icon(Icons.photo_library_outlined),
            onPressed: _fromGallery,
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 32,
            child: Text(
              'Vise un QR code ou un code-barres',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}
