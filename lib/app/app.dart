import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../features/editor/document_screen.dart';
import '../features/editor/page_screen.dart';
import '../features/library/library_screen.dart';
import '../features/ocr/ocr_text_screen.dart';
import '../features/scan/barcode_screen.dart';
import '../features/scan/scan_actions.dart';
import '../features/settings/settings_screen.dart';

final _navigatorKey = GlobalKey<NavigatorState>();

final _router = GoRouter(
  navigatorKey: _navigatorKey,
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const LibraryScreen(),
      routes: [
        GoRoute(
          path: 'folder/:id',
          builder: (context, state) =>
              LibraryScreen(folderId: int.parse(state.pathParameters['id']!)),
        ),
        GoRoute(
          path: 'barcode',
          builder: (context, state) => const BarcodeScreen(),
        ),
        GoRoute(
          path: 'settings',
          builder: (context, state) => const SettingsScreen(),
        ),
        GoRoute(
          path: 'doc/:id',
          builder: (context, state) => DocumentScreen(
            documentId: int.parse(state.pathParameters['id']!),
          ),
          routes: [
            GoRoute(
              path: 'text',
              builder: (context, state) => OcrTextScreen(
                documentId: int.parse(state.pathParameters['id']!),
                pageId: int.tryParse(state.uri.queryParameters['page'] ?? ''),
              ),
            ),
            GoRoute(
              path: 'page/:index',
              builder: (context, state) => PageScreen(
                documentId: int.parse(state.pathParameters['id']!),
                initialIndex: int.parse(state.pathParameters['index']!),
              ),
            ),
          ],
        ),
      ],
    ),
  ],
);

class ScanApp extends StatelessWidget {
  const ScanApp({super.key});

  static const _seed = Color(0xFF0F766E);

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'SCAN',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: _seed),
      darkTheme: ThemeData(colorSchemeSeed: _seed, brightness: Brightness.dark),
      routerConfig: _router,
      builder: (context, child) => _SharedFilesListener(child: child!),
    );
  }
}

const _importableExtensions = {'.pdf', '.jpg', '.jpeg', '.png', '.webp'};

/// Turns images and PDFs shared to SCAN ("Partager" / "Ouvrir avec") into a
/// new document.
class _SharedFilesListener extends ConsumerStatefulWidget {
  const _SharedFilesListener({required this.child});

  final Widget child;

  @override
  ConsumerState<_SharedFilesListener> createState() =>
      _SharedFilesListenerState();
}

class _SharedFilesListenerState extends ConsumerState<_SharedFilesListener> {
  StreamSubscription<List<SharedMediaFile>>? _subscription;

  @override
  void initState() {
    super.initState();
    final intents = ReceiveSharingIntent.instance;
    _subscription = intents.getMediaStream().listen(_import);
    intents.getInitialMedia().then((files) {
      intents.reset();
      // Wait for the first route so the progress dialog has a navigator.
      WidgetsBinding.instance.addPostFrameCallback((_) => _import(files));
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _import(List<SharedMediaFile> files) async {
    final paths = [
      for (final f in files)
        if (_importableExtensions.contains(p.extension(f.path).toLowerCase()))
          f.path,
    ];
    final context = _navigatorKey.currentContext;
    if (paths.isEmpty || context == null) return;
    final id = await importFiles(context, ref, paths);
    if (id != null) _router.push('/doc/$id');
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
