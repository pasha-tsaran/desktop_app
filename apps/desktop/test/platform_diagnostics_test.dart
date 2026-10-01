import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kenai_core/kenai_core.dart';
import 'package:kenai_vpn_desktop/src/infrastructure/platform_diagnostics.dart';

void main() {
  test('file log and saved ZIP never contain a submitted secret', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'kenai-diagnostics-test-',
    );
    addTearDown(() async {
      final String resolved = directory.absolute.path;
      if (resolved.contains('kenai-diagnostics-test-') &&
          await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final File logFile =
        File('${directory.path}${Platform.pathSeparator}log.jsonl');
    final JsonLinesDiagnosticLogStore store = JsonLinesDiagnosticLogStore(
      file: logFile,
    );
    final RedactingDiagnostics diagnostics = RedactingDiagnostics(store: store);
    final String secret = <String>['9876', '5432', '1098'].join();

    await diagnostics.log(
      DiagnosticLogInput(
        category: DiagnosticCategory.application,
        level: DiagnosticSeverity.info,
        code: 'TEST_EVENT',
        message: 'activation_key=$secret',
      ),
    );
    final String persisted = await logFile.readAsString();
    expect(persisted, isNot(contains(secret)));
    expect(persisted, contains(SecretRedactor.replacement));

    final DiagnosticArchive archive = await diagnostics.createArchive();
    final DownloadsDiagnosticArchiveSaver saver =
        DownloadsDiagnosticArchiveSaver(directory: directory);
    final DiagnosticArchiveLocation location = await saver.save(archive);
    final List<int> saved = await File(location.path).readAsBytes();

    expect(saved, archive.bytes);
    expect(String.fromCharCodes(saved), isNot(contains(secret)));
    await diagnostics.dispose();
  });

  test('archive saver rejects a caller-selected path', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'kenai-diagnostics-name-test-',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final DownloadsDiagnosticArchiveSaver saver =
        DownloadsDiagnosticArchiveSaver(directory: directory);

    await expectLater(
      saver.save(
        const DiagnosticArchive(
          fileName: '../outside.zip',
          bytes: <int>[1, 2, 3],
        ),
      ),
      throwsFormatException,
    );
  });
}
