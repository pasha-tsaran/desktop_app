import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kenai_core/kenai_core.dart';
import 'package:kenai_vpn_desktop/bootstrap.dart';
import 'package:kenai_vpn_desktop/src/infrastructure/windows_profile_provisioner.dart';

void main() {
  testWidgets('validates the key locally before calling the API', (
    WidgetTester tester,
  ) async {
    final _AccountFixture fixture = _fixture();
    await _openAccount(tester, fixture.dependencies);

    final EditableText field = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('activation-key-input')),
        matching: find.byType(EditableText),
      ),
    );
    expect(field.obscureText, isTrue);
    await tester.tap(find.byKey(const Key('activation-key-input')));
    await tester.pump();
    expect(field.controller.text, isEmpty);
    expect(find.text('12 цифр'), findsNothing);

    await tester.enterText(
      find.byKey(const Key('activation-key-input')),
      '12abc',
    );
    await tester.tap(find.byKey(const Key('activate-account')));
    await tester.pump();

    expect(find.text('Ключ должен содержать ровно 12 цифр.'), findsOneWidget);
    expect(fixture.api.requestCount, 0);
  });

  testWidgets('activates, masks, reveals, copies and clears the account', (
    WidgetTester tester,
  ) async {
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final _AccountFixture fixture = _fixture();
    await _openAccount(tester, fixture.dependencies);
    final String key = _testActivationKey();

    await tester.enterText(find.byKey(const Key('activation-key-input')), key);
    await tester.tap(find.byKey(const Key('activate-account')));
    await tester.pumpAndSettle();

    expect(find.text('•••• •••• 9012'), findsOneWidget);
    expect(find.text(key), findsNothing);
    expect(find.text('Активна'), findsWidgets);
    expect(find.text('Действует до'), findsOneWidget);
    expect(await fixture.storage.read('vpn.wireguard'), isNotNull);

    await tester.tap(find.byKey(const Key('reveal-stored-key')));
    await tester.pump();
    expect(find.text(key), findsOneWidget);

    await tester.tap(find.byKey(const Key('copy-stored-key')));
    await tester.pump();
    expect(copiedText, key);

    await tester.tap(find.byKey(const Key('sign-out')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-sign-out')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('activation-key-input')), findsOneWidget);
    expect(await fixture.storage.read('account.activation_key'), isNull);
    expect(await fixture.storage.read('vpn.wireguard'), isNull);
    expect(await fixture.storage.read('account.session'), isNull);
  });

  testWidgets('shows expired and suspended subscription states', (
    WidgetTester tester,
  ) async {
    for (final ({MockActivationScenario scenario, String label}) entry
        in <({MockActivationScenario scenario, String label})>[
      (
        scenario: MockActivationScenario.expired,
        label: 'Истекла',
      ),
      (
        scenario: MockActivationScenario.suspended,
        label: 'Приостановлена',
      ),
    ]) {
      final _AccountFixture fixture = _fixture(scenario: entry.scenario);
      await fixture.repository.activate(
        ActivationKey.parse(_testActivationKey()),
      );
      await _openAccount(tester, fixture.dependencies);

      expect(find.text(entry.label), findsWidgets);
      expect(find.text('Действует до'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });

  testWidgets('shows safe network and API errors without echoing the key', (
    WidgetTester tester,
  ) async {
    final _AccountFixture fixture = _fixture(
      scenario: MockActivationScenario.noNetwork,
    );
    await _openAccount(tester, fixture.dependencies);
    final String key = _testActivationKey();

    await tester.enterText(find.byKey(const Key('activation-key-input')), key);
    await tester.tap(find.byKey(const Key('activate-account')));
    await tester.pumpAndSettle();

    expect(
      find.text(
          'Нет подключения к интернету. Проверьте сеть и повторите попытку.'),
      findsOneWidget,
    );
    expect(find.textContaining(key), findsNothing);

    fixture.api.scenario = MockActivationScenario.serverError;
    await tester.enterText(find.byKey(const Key('activation-key-input')), key);
    await tester.tap(find.byKey(const Key('activate-account')));
    await tester.pumpAndSettle();

    expect(
      find.text('Сервис активации временно недоступен. Повторите позже.'),
      findsOneWidget,
    );
    expect(find.textContaining(key), findsNothing);
  });

  testWidgets('names a stopped profile service without exposing the key', (
    WidgetTester tester,
  ) async {
    final _AccountFixture fixture = _fixture(
      profileProvisioner: _UnavailableProfileProvisioner(),
    );
    await _openAccount(tester, fixture.dependencies);
    final String key = _testActivationKey();

    await tester.enterText(find.byKey(const Key('activation-key-input')), key);
    await tester.tap(find.byKey(const Key('activate-account')));
    await tester.pumpAndSettle();

    expect(
      find.text(
          'Служба Kenai VPN не отвечает. Перезагрузите компьютер и повторите попытку.'),
      findsOneWidget,
    );
    expect(find.textContaining(key), findsNothing);
    expect(await fixture.storage.read('account.activation_key'), isNull);
  });

  testWidgets('keeps account data when VPN stop cannot be confirmed', (
    WidgetTester tester,
  ) async {
    final UnavailableVpnEngine unavailable = UnavailableVpnEngine();
    final _AccountFixture fixture = _fixture(vpnEngine: unavailable);
    await fixture.repository.activate(
      ActivationKey.parse(_testActivationKey()),
    );
    await unavailable.connect(
      const ConnectionRequest(
        operationId: 'connect-before-sign-out',
        profile: VpnProfile(
          id: 'profile-1',
          deviceId: 'device-1',
          serverId: 'armenia-1',
          protocol: VpnProtocol.wireGuard,
        ),
        killSwitch: false,
      ),
    );
    await _openAccount(tester, fixture.dependencies);

    await tester.tap(find.byKey(const Key('sign-out')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-sign-out')));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Не удалось безопасно остановить VPN. Данные аккаунта сохранены; повторите выход.',
      ),
      findsOneWidget,
    );
    expect(await fixture.storage.read('account.activation_key'), isNotNull);
  });
}

final class _AccountFixture {
  const _AccountFixture({
    required this.dependencies,
    required this.api,
    required this.storage,
    required this.repository,
  });

  final AppDependencies dependencies;
  final MockActivationApiClient api;
  final InMemorySecureStorage storage;
  final SecureAccountRepository repository;
}

_AccountFixture _fixture({
  MockActivationScenario scenario = MockActivationScenario.active,
  VpnEngine? vpnEngine,
  VpnProfileProvisioner? profileProvisioner,
}) {
  final MockApiClient apiClient = MockApiClient();
  final MockActivationApiClient activationApi = MockActivationApiClient(
    scenario: scenario,
  );
  final InMemorySecureStorage storage = InMemorySecureStorage();
  final SecureAccountRepository repository = SecureAccountRepository(
    apiClient: activationApi,
    secureStorage: storage,
    profileProvisioner: profileProvisioner,
  );
  return _AccountFixture(
    api: activationApi,
    storage: storage,
    repository: repository,
    dependencies: AppDependencies(
      apiClient: apiClient,
      secureStorage: storage,
      accountRepository: repository,
      vpnEngine: vpnEngine ?? MockVpnEngine(),
      serverRepository: MockServerRepository(apiClient: apiClient),
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
      diagnosticLogger: RedactingDiagnostics(
        store: InMemoryDiagnosticLogStore(),
      ),
      diagnosticExporter: MockDiagnosticExporter(),
      diagnosticArchiveSaver: InMemoryDiagnosticArchiveSaver(),
    ),
  );
}

final class _UnavailableProfileProvisioner implements VpnProfileProvisioner {
  @override
  Future<String> provisionWireGuard(String configuration) async =>
      throw const ProfileProvisioningException('SERVICE_UNAVAILABLE');

  @override
  Future<String> provisionAmneziaWg(String configuration) async =>
      throw const ProfileProvisioningException('SERVICE_UNAVAILABLE');

  @override
  Future<String> provisionVlessReality(String configuration) async =>
      throw const ProfileProvisioningException('SERVICE_UNAVAILABLE');

  @override
  Future<void> deleteProfile(String profileId) async {}
}

Future<void> _openAccount(
  WidgetTester tester,
  AppDependencies dependencies,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 850);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(buildKenaiApp(dependencies: dependencies));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('nav-account')));
  await tester.pumpAndSettle();
}

String _testActivationKey() => <String>[
      '1234',
      '5678',
      '9012',
    ].join();
