import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kenai_core/kenai_core.dart';
import 'package:kenai_vpn_desktop/bootstrap.dart';

void main() {
  testWidgets('stores protocol and default server preferences', (
    WidgetTester tester,
  ) async {
    final _SettingsFixture fixture = _fixture(includeTestServers: true);
    addTearDown(fixture.dispose);
    await _openSettings(tester, fixture.dependencies);

    await tester.tap(find.byKey(const Key('protocol-preference')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AmneziaWG').last);
    await tester.pumpAndSettle();

    expect(
      (await fixture.settings.load()).protocol,
      ProtocolPreference.amneziaWg,
    );

    await tester.tap(find.byKey(const Key('default-server')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Германия').last);
    await tester.pumpAndSettle();

    expect(
      (await fixture.settings.load()).defaultServerId,
      'de-fra-test-01',
    );
    expect(
      (await fixture.dependencies.serverRepository.getSelectedServer())?.id,
      'de-fra-test-01',
    );
  });

  testWidgets('does not present unsupported mock features as working', (
    WidgetTester tester,
  ) async {
    final _SettingsFixture fixture = _fixture();
    addTearDown(fixture.dispose);
    await _openSettings(tester, fixture.dependencies);

    for (final String key in <String>[
      'kill-switch-setting',
      'network-reconnect-setting',
      'launch-at-login-setting',
      'minimize-after-connect-setting',
    ]) {
      final SwitchListTile tile = _switchTile(tester, key);
      expect(tile.onChanged, isNull, reason: key);
    }
    expect(
      tester.widget<ListTile>(find.byKey(const Key('dns-setting'))).enabled,
      isFalse,
    );
    expect(
      tester
          .widget<ListTile>(find.byKey(const Key('auto-connect-setting')))
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<ListTile>(find.byKey(const Key('sleep-behavior-setting')))
          .enabled,
      isFalse,
    );
    expect(find.textContaining('Недоступно:'), findsWidgets);
  });

  testWidgets('enables controls only when capabilities explicitly allow them', (
    WidgetTester tester,
  ) async {
    final _CapableAdapter adapter = _CapableAdapter();
    final _SettingsFixture fixture = _fixture(
      adapters: <VpnProtocolAdapter>[adapter],
      platformCapabilities: const ClientPlatformCapabilities(
        supportsAutoConnect: true,
        supportsLaunchAtLogin: true,
        supportsMinimizeAfterConnect: true,
      ),
    );
    addTearDown(fixture.dispose);
    await _openSettings(tester, fixture.dependencies);

    final SwitchListTile killSwitch =
        _switchTile(tester, 'kill-switch-setting');
    expect(killSwitch.onChanged, isNotNull);
    expect(
      tester.widget<ListTile>(find.byKey(const Key('dns-setting'))).enabled,
      isTrue,
    );
    expect(
      tester
          .widget<ListTile>(find.byKey(const Key('auto-connect-setting')))
          .enabled,
      isTrue,
    );

    await tester.tap(find.byKey(const Key('kill-switch-setting')));
    await tester.pump();
    expect((await fixture.settings.load()).killSwitch, isTrue);
  });
}

final class _SettingsFixture {
  const _SettingsFixture({
    required this.dependencies,
    required this.settings,
    required this.engine,
  });

  final AppDependencies dependencies;
  final MockSettingsRepository settings;
  final MockVpnEngine engine;

  Future<void> dispose() async {
    await settings.dispose();
    await engine.dispose();
  }
}

_SettingsFixture _fixture({
  bool includeTestServers = false,
  List<VpnProtocolAdapter>? adapters,
  ClientPlatformCapabilities platformCapabilities =
      const ClientPlatformCapabilities.unavailable(),
}) {
  final MockApiClient api = MockApiClient(
    includeTestServers: includeTestServers,
  );
  final InMemorySecureStorage storage = InMemorySecureStorage();
  final MockSettingsRepository settings = MockSettingsRepository();
  final MockVpnEngine engine = MockVpnEngine(adapters: adapters);
  return _SettingsFixture(
    settings: settings,
    engine: engine,
    dependencies: AppDependencies(
      apiClient: api,
      secureStorage: storage,
      accountRepository: SecureAccountRepository(
        apiClient: MockActivationApiClient(),
        secureStorage: storage,
      ),
      vpnEngine: engine,
      serverRepository: MockServerRepository(apiClient: api),
      settingsRepository: settings,
      platformCapabilities: platformCapabilities,
      subscriptionRepository: MockSubscriptionRepository(),
      paymentProvider: MockPaymentProvider(),
      speedTestEngine: MockSpeedTestEngine(),
      updateProvider: MockUpdateProvider(),
      buildInfo: const ClientBuildInfo(
        version: '0.1.0',
        buildNumber: '1',
        platform: DevicePlatform.windows,
      ),
      diagnosticLogger: RedactingDiagnostics(
        store: InMemoryDiagnosticLogStore(),
      ),
      diagnosticExporter: MockDiagnosticExporter(),
      diagnosticArchiveSaver: InMemoryDiagnosticArchiveSaver(),
    ),
  );
}

Future<void> _openSettings(
  WidgetTester tester,
  AppDependencies dependencies,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 900);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(buildKenaiApp(dependencies: dependencies));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('nav-vpnSettings')));
  await tester.pumpAndSettle();
}

SwitchListTile _switchTile(WidgetTester tester, String key) =>
    tester.widget<SwitchListTile>(
      find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(SwitchListTile),
      ),
    );

final class _CapableAdapter implements VpnProtocolAdapter {
  @override
  VpnAdapterCapabilities get capabilities => const VpnAdapterCapabilities(
        protocol: VpnProtocol.wireGuard,
        isMock: true,
        supportsKillSwitch: true,
        supportsDns: true,
        supportsNetworkChangeReconnect: true,
        supportsSleepRecovery: true,
      );

  @override
  VpnProtocol get protocol => VpnProtocol.wireGuard;

  @override
  Future<void> start(VpnProfile profile) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<ProfileValidation> validate(VpnProfile profile) async =>
      const ProfileValidation(isValid: true);
}
