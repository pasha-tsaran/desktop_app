import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kenai_core/kenai_core.dart';
import 'package:kenai_vpn_desktop/bootstrap.dart';

void main() {
  testWidgets('full speed test starts only after traffic confirmation', (
    WidgetTester tester,
  ) async {
    final _Fixture fixture = _fixture(includeTestServers: true);
    addTearDown(fixture.dispose);
    await _open(tester, fixture.dependencies, 'speedTest');

    expect(
        find.text('Ожидаемый расход полного теста: до 40 МБ.'), findsOneWidget);
    expect(find.byKey(const Key('speed-server-list')), findsOneWidget);
    expect(_phase(tester), 'Готов к запуску');

    await tester.tap(find.byKey(const Key('start-speed-test')));
    await tester.pumpAndSettle();
    expect(find.textContaining('до 40 МБ трафика'), findsOneWidget);
    expect(fixture.speed.currentState.phase, SpeedTestPhase.idle);
    await tester.tap(find.byKey(const Key('confirm-speed-test')));
    await tester.pump();
    expect(fixture.speed.currentState.phase, SpeedTestPhase.pinging);
    await tester.pump(const Duration(milliseconds: 400));

    expect(_phase(tester), 'Тест завершён');
    expect(find.text('37 мс'), findsOneWidget);
    expect(find.text('41 мс'), findsOneWidget);
    expect(find.text('86.4 Мбит/с'), findsOneWidget);
    expect(find.text('31.7 Мбит/с'), findsOneWidget);
  });

  testWidgets('running speed test can be stopped', (
    WidgetTester tester,
  ) async {
    final _Fixture fixture = _fixture();
    addTearDown(fixture.dispose);
    await _open(tester, fixture.dependencies, 'speedTest');
    await tester.tap(find.byKey(const Key('start-speed-test')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-speed-test')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('stop-speed-test')));
    await tester.pump(const Duration(milliseconds: 150));

    expect(_phase(tester), 'Тест остановлен');
  });

  testWidgets('application settings persist theme and diagnostic consent', (
    WidgetTester tester,
  ) async {
    final _Fixture fixture = _fixture();
    addTearDown(fixture.dispose);
    await _open(tester, fixture.dependencies, 'settings');

    expect(find.text('0.1.0 (1)'), findsOneWidget);
    expect(find.text('Русский'), findsOneWidget);
    expect(
      _switch(tester, 'automatic-updates').onChanged,
      isNull,
    );
    expect(_switch(tester, 'tray-setting').onChanged, isNull);

    await tester.ensureVisible(find.byKey(const Key('diagnostic-consent')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('diagnostic-consent')));
    await tester.pump();
    expect((await fixture.settings.load()).sendDiagnostics, isTrue);

    await tester.ensureVisible(find.byKey(const Key('theme-setting')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('theme-setting')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Тёмная').last);
    await tester.pumpAndSettle();
    expect((await fixture.settings.load()).theme, ThemePreference.dark);
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark);

    await tester.scrollUntilVisible(
      find.byKey(const Key('check-for-updates')),
      -300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('check-for-updates')));
    await tester.pumpAndSettle();
    expect(find.text('Установлена актуальная версия.'), findsOneWidget);
  });

  testWidgets('release fallbacks do not show fake speed or safe auto-update', (
    WidgetTester tester,
  ) async {
    final _Fixture fixture = _fixture(releaseFallbacks: true);
    addTearDown(fixture.dispose);
    await _open(tester, fixture.dependencies, 'speedTest');
    expect(find.byKey(const Key('speed-test-unavailable')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('start-speed-test')))
          .onPressed,
      isNull,
    );

    await tester.ensureVisible(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();
    expect(_switch(tester, 'automatic-updates').onChanged, isNull);
    expect(find.textContaining('подписанного update-провайдера'), findsWidgets);
  });
}

final class _Fixture {
  const _Fixture({
    required this.dependencies,
    required this.speed,
    required this.settings,
  });

  final AppDependencies dependencies;
  final SpeedTestEngine speed;
  final MockSettingsRepository settings;

  Future<void> dispose() async {
    if (speed is MockSpeedTestEngine) {
      await (speed as MockSpeedTestEngine).dispose();
    } else if (speed is UnavailableSpeedTestEngine) {
      await (speed as UnavailableSpeedTestEngine).dispose();
    }
    await settings.dispose();
  }
}

_Fixture _fixture({
  bool includeTestServers = false,
  bool releaseFallbacks = false,
}) {
  final MockApiClient api = MockApiClient(
    includeTestServers: includeTestServers,
  );
  final InMemorySecureStorage storage = InMemorySecureStorage();
  final MockSettingsRepository settings = MockSettingsRepository();
  final SpeedTestEngine speed =
      releaseFallbacks ? UnavailableSpeedTestEngine() : MockSpeedTestEngine();
  final RedactingDiagnostics diagnostics = RedactingDiagnostics(
    store: InMemoryDiagnosticLogStore(),
  );
  return _Fixture(
    speed: speed,
    settings: settings,
    dependencies: AppDependencies(
      apiClient: api,
      secureStorage: storage,
      accountRepository: SecureAccountRepository(
        apiClient: MockActivationApiClient(),
        secureStorage: storage,
      ),
      vpnEngine: MockVpnEngine(),
      serverRepository: MockServerRepository(apiClient: api),
      settingsRepository: settings,
      platformCapabilities: const ClientPlatformCapabilities.unavailable(),
      subscriptionRepository: MockSubscriptionRepository(),
      paymentProvider: MockPaymentProvider(),
      speedTestEngine: speed,
      updateProvider: releaseFallbacks
          ? UnavailableUpdateProvider(currentVersion: '0.1.0')
          : MockUpdateProvider(),
      buildInfo: const ClientBuildInfo(
        version: '0.1.0',
        buildNumber: '1',
        platform: DevicePlatform.windows,
      ),
      diagnosticLogger: diagnostics,
      diagnosticExporter: diagnostics,
      diagnosticArchiveSaver: InMemoryDiagnosticArchiveSaver(),
    ),
  );
}

Future<void> _open(
  WidgetTester tester,
  AppDependencies dependencies,
  String destination,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1440, 1000);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(buildKenaiApp(dependencies: dependencies));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(Key('nav-$destination')),
    150,
    scrollable: find.descendant(
      of: find.byKey(const Key('sidebar-navigation')),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('nav-$destination')));
  await tester.pumpAndSettle();
}

String? _phase(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('speed-test-phase'))).data;

SwitchListTile _switch(WidgetTester tester, String key) =>
    tester.widget<SwitchListTile>(
      find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(SwitchListTile),
      ),
    );
