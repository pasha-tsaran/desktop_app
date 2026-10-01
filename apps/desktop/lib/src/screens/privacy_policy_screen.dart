import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

const privacyPolicyAsset = 'assets/legal/privacy-policy-ru.pdf';

/// A bundled PDF, rendered locally; no browser or remote document service.
final class PrivacyPolicyScreen extends StatefulWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  State<PrivacyPolicyScreen> createState() => _PrivacyPolicyScreenState();
}

final class _PrivacyPolicyScreenState extends State<PrivacyPolicyScreen> {
  final _controller = PdfViewerController();
  int _page = 1;
  int _pages = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
        key: const Key('privacy-policy-screen'),
        appBar: AppBar(
          title: const Text('Политика конфиденциальности'),
          actions: [
            Center(child: Text(_pages == 0 ? 'PDF' : '$_page / $_pages')),
            IconButton(
              tooltip: 'Уменьшить',
              onPressed: _pages == 0 ? null : () => _controller.zoomDown(),
              icon: const Icon(Icons.zoom_out),
            ),
            IconButton(
              tooltip: 'Увеличить',
              onPressed: _pages == 0 ? null : () => _controller.zoomUp(),
              icon: const Icon(Icons.zoom_in),
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: PdfViewer.asset(
          privacyPolicyAsset,
          key: const Key('privacy-pdf-viewer'),
          controller: _controller,
          params: PdfViewerParams(
            onViewerReady: (document, controller) {
              if (mounted) setState(() => _pages = document.pages.length);
            },
            onPageChanged: (page) {
              if (mounted && page != null) setState(() => _page = page);
            },
            errorBannerBuilder: (context, error, stackTrace, documentRef) =>
                const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Не удалось открыть PDF. Вернитесь назад и '
                    'попробуйте снова. Если ошибка повторяется, '
                    'переустановите приложение.'),
              ),
            ),
          ),
        ),
      );
}
