import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kenai_vpn_desktop/src/screens/privacy_policy_screen.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  testWidgets(
      'bundled policy opens locally, contains owner, and renders both pages',
      (tester) async {
    await tester.runAsync(() async {
      // Avoid a path-provider platform channel in the test runner only.
      Pdfrx.cacheDirectoryPath = Directory.systemTemp.path;
      await pdfrxFlutterInitialize();
      final bytes = await rootBundle.load(privacyPolicyAsset);
      final document = await PdfDocument.openData(bytes.buffer.asUint8List());
      try {
        expect(document.pages, hasLength(2));
        expect((await document.pages.first.loadText())?.fullText,
            contains('Царан Павел Андреевич'));
        for (final page in document.pages) {
          final image = await page.render(fullWidth: 420, fullHeight: 594);
          expect(image, isNotNull);
          expect(image!.pixels, isNotEmpty);
          image.dispose();
        }
      } finally {
        await document.dispose();
      }
    });
    await tester.pumpWidget(const MaterialApp(home: PrivacyPolicyScreen()));
    expect(find.byType(PdfViewer), findsOneWidget);
    // Let real native document I/O finish outside the fake widget-test clock.
    for (var i = 0; i < 30 && find.text('1 / 2').evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.textContaining('Не удалось открыть PDF'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    // pdfrx yields between background pages with a 100 ms timer. Advance
    // the fake clock so its already-scheduled loop can observe disposal.
    await tester.pump(const Duration(seconds: 1));
  });
}
