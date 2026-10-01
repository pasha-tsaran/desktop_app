import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kenai_core/kenai_core.dart';
import 'package:kenai_vpn_desktop/bootstrap.dart';

void main() {
  testWidgets('shows sanitized logs, filters and copies only safe text', (
    WidgetTester tester,
  ) async {
    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
      MethodCall call,
    ) async {
      if (call.method == 'Clipboard.setData') {
        copiedText =
            (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final _DiagnosticsFixture fixture = await _fixture();
    addTearDown(fixture.dispose);
    await _openLogs(tester, fixture.dependencies);

    expect(find.text('Логи и диагностика'), findsOneWidget);
    expect(find.textContaining(fixture.secret), findsNothing);
    expect(find.textContaining(SecretRedactor.replacement), findsWidgets);
    expect(find.byKey(const Key('diagnostic-summary')), findsOneWidget);

    await tester.tap(find.byKey(const Key('diagnostics-category')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сеть').last);
    await tester.pumpAndSettle();
    expect(find.text('Соединение восстановлено'), findsOneWidget);
    expect(find.text('Ошибка авторизации'), findsNothing);

    await tester.tap(find.byKey(const Key('copy-diagnostics')));
    await tester.pump();
    expect(copiedText, contains('Соединение восстановлено'));
    expect(copiedText, isNot(contains(fixture.secret)));
    expect(find.text('Отфильтрованные записи скопированы.'), findsOneWidget);
  });

  testWidgets('exports ZIP and clears logs only after explicit confirmation', (
    WidgetTester tester,
  ) async {
    final _DiagnosticsFixture fixture = await _fixture();
    addTearDown(fixture.dispose);
    await _openLogs(tester, fixture.dependencies);

    await tester.tap(find.byKey(const Key('export-diagnostics')));
    await tester.pumpAndSettle();
    expect(find.textContaining('никуда не отправляется автоматически'),
        findsOneWidget);
    expect(fixture.saver.lastArchive, isNull);
    await tester.tap(find.byKey(const Key('confirm-export-diagnostics')));
    await tester.pumpAndSettle();

    final DiagnosticArchive archive = fixture.saver.lastArchive!;
    expect(archive.fileName, endsWith('.zip'));
    expect(
        String.fromCharCodes(archive.bytes), isNot(contains(fixture.secret)));

    await tester.tap(find.byKey(const Key('clear-diagnostics')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-clear-diagnostics')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('diagnostics-empty')), findsOneWidget);
  });
}

final class _DiagnosticsFixture {
  const _DiagnosticsFixture({
    required this.dependencies,
    required this.diagnostics,
    required this.saver,
    required this.secret,
  });

  final AppDependencies dependencies;
  final RedactingDiagnostics diagnostics;
  final InMemoryDiagnosticArchiveSaver saver;
  final String secret;

  Future<void> dispose() async => diagnostics.dispose();
}

Future<_DiagnosticsFixture> _fixture() async {
  final InMemorySecureStorage storage = InMemorySecureStorage();
  final MockApiClient api = MockApiClient();
  final RedactingDiagnostics diagnostics = RedactingDiagnostics(
    store: InMemoryDiagnosticLogStore(),
  );
  final InMemoryDiagnosticArchiveSaver saver = InMemoryDiagnosticArchiveSaver();
  final String secret = <String>['1234', '5678', '9012'].join();
  await diagnostics.log(
    DiagnosticLogInput(
      category: DiagnosticCategory.xray,
      level: DiagnosticSeverity.error,
      code: 'AUTH_FAILURE',
      message: 'Ошибка авторизации: activation_key=$secret',
    ),
  );
  await diagnostics.log(
    const DiagnosticLogInput(
      category: DiagnosticCategory.network,
      level: DiagnosticSeverity.info,
      code: 'NETWORK_RESTORED',
      message: 'Соединение восстановлено',
    ),
  );
  return _DiagnosticsFixture(
    diagnostics: diagnostics,
    saver: saver,
    secret: secret,
    dependencies: AppDependencies(
      apiClient: api,
      secureStorage: storage,
      accountRepository: SecureAccountRepository(
        apiClient: MockActivationApiClient(),
        secureStorage: storage,
      ),
      vpnEngine: MockVpnEngine(),
      serverRepository: MockServerRepository(apiClient: api),
      settingsRepository: MockSettingsRepository(),
      platformCapabilities: const ClientPlatformCapabilities.unavailable(),
      subscriptionRepository: MockSubscriptionRepository(),
      paymentProvider: MockPaymentProvider(),
      speedTestEngine: MockSpeedTestEngine(),
      updateProvider: MockUpdateProvider(),
      buildInfo: const ClientBuildInfo(
        version: '0.1.0',
        buildNumber: '1',
        platform: DevicePlatform.windows,
      ),
      diagnosticLogger: diagnostics,
      diagnosticExporter: diagnostics,
      diagnosticArchiveSaver: saver,
    ),
  );
}

Future<void> _openLogs(
  WidgetTester tester,
  AppDependencies dependencies,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1440, 900);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(buildKenaiApp(dependencies: dependencies));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('nav-logs')));
  await tester.pumpAndSettle();
}
