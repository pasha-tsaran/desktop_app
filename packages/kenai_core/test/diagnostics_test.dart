import 'dart:convert';

import 'package:kenai_core/kenai_core.dart';
import 'package:test/test.dart';

void main() {
  group('central diagnostic redaction', () {
    test('removes every secret before storage, display and ZIP export',
        () async {
      final InMemoryDiagnosticLogStore store = InMemoryDiagnosticLogStore();
      final RedactingDiagnostics diagnostics = RedactingDiagnostics(
        store: store,
        clock: () => DateTime.utc(2026, 9, 5, 12),
      );
      final Map<String, String> secrets = _testSecrets();

      await diagnostics.log(
        DiagnosticLogInput(
          category: DiagnosticCategory.xray,
          level: DiagnosticSeverity.error,
          code: 'AUTH_FAILURE',
          message: <String>[
            'activation_key=${secrets['activation']}',
            'uuid=${secrets['uuid']}',
            'Authorization: Bearer ${secrets['token']}',
            'Cookie: session=${secrets['cookie']}',
            'password=${secrets['password']}',
            secrets['vless']!,
            secrets['privateKey']!,
          ].join(' '),
          fields: <String, Object?>{
            'private_key': secrets['privateKey'],
            'access_token': secrets['token'],
            'headers': <String, String>{
              'Set-Cookie': secrets['cookie']!,
              'Proxy-Authorization': secrets['token']!,
            },
            'vpn_configuration': secrets['configuration'],
          },
        ),
      );

      final DiagnosticLogEntry storedEntry = (await store.readAll()).single;
      final DiagnosticLogEntry displayedEntry =
          (await diagnostics.query()).single;
      final String stored = '${storedEntry.code} ${storedEntry.message} '
          '${storedEntry.fields}';
      final String displayed = '${displayedEntry.code} '
          '${displayedEntry.message} ${displayedEntry.fields}';
      final DiagnosticArchive archive = await diagnostics.createArchive();
      final String zippedBytes = String.fromCharCodes(archive.bytes);

      for (final String secret in secrets.values) {
        expect(stored, isNot(contains(secret)), reason: 'stored file boundary');
        expect(displayed, isNot(contains(secret)), reason: 'UI boundary');
        expect(zippedBytes, isNot(contains(secret)), reason: 'ZIP boundary');
      }
      expect(stored, contains(SecretRedactor.replacement));
      expect(zippedBytes, contains('logs.jsonl'));
      expect(zippedBytes, contains('report.json'));
      expect(archive.fileName, endsWith('.zip'));
      await diagnostics.dispose();
    });

    test('redacts complete WireGuard and Xray profiles as one value', () {
      final SecretRedactor redactor = SecretRedactor();
      final String wireGuard = <String>[
        '[Interface]',
        'PrivateKey = ${_testSecrets()['privateKey']}',
        '[Peer]',
        'Endpoint = vpn.invalid:51820',
        'AllowedIPs = 0.0.0.0/0',
      ].join('\n');
      final String xray = jsonEncode(<String, Object?>{
        'outbounds': <Object?>[],
        'realitySettings': <String, String>{'privateKey': 'secret'},
      });

      expect(redactor.redactText(wireGuard), '[REDACTED VPN CONFIGURATION]');
      expect(redactor.redactText(xray), '[REDACTED VPN CONFIGURATION]');
    });
  });

  test('filters, summarizes and clears sanitized events', () async {
    final InMemoryDiagnosticLogStore store = InMemoryDiagnosticLogStore();
    final RedactingDiagnostics diagnostics = RedactingDiagnostics(store: store);
    for (final DiagnosticCategory category in DiagnosticCategory.values) {
      await diagnostics.log(
        DiagnosticLogInput(
          category: category,
          level: category == DiagnosticCategory.network
              ? DiagnosticSeverity.warning
              : DiagnosticSeverity.info,
          code: 'EVENT_${category.name}',
          message: 'Safe diagnostic event',
        ),
      );
    }

    final List<DiagnosticLogEntry> network = await diagnostics.query(
      const DiagnosticFilter(
        categories: <DiagnosticCategory>{DiagnosticCategory.network},
        levels: <DiagnosticSeverity>{DiagnosticSeverity.warning},
        query: 'safe',
      ),
    );
    final DiagnosticSummary summary = await diagnostics.summary();

    expect(network, hasLength(1));
    expect(summary.totalEvents, DiagnosticCategory.values.length);
    expect(summary.warningCount, 1);
    expect(
      summary.categoryCounts.keys.toSet(),
      DiagnosticCategory.values.toSet(),
    );
    await diagnostics.clear();
    expect(await diagnostics.query(), isEmpty);
    await diagnostics.dispose();
  });
}

Map<String, String> _testSecrets() => <String, String>{
      'activation': <String>['1234', '5678', '9012'].join(),
      'privateKey': <String>[
        'AAAAAAAAAA',
        'AAAAAAAAAA',
        'AAAAAAAAAA',
        'AAAAAAAAAAAAA=',
      ].join(),
      'uuid': <String>['550e8400', 'e29b', '41d4', 'a716', '446655440000']
          .join('-'),
      'token': <String>['eyJhbGciOiJIUzI1NiIs', 'mock-signature'].join('.'),
      'cookie': <String>['session', 'private', 'value'].join('-'),
      'password': <String>['correct', 'horse', 'battery'].join('-'),
      'vless': <String>[
        'vless:/',
        '/550e8400-e29b-41d4-a716-446655440000@vpn.invalid:443',
        '?security=reality',
      ].join(),
      'configuration': <String>[
        '[Interface]',
        'PrivateKey=hidden',
        '[Peer]',
        'Endpoint=vpn.invalid:51820',
      ].join('\n'),
    };
