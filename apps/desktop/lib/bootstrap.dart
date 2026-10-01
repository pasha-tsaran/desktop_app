import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:kenai_core/kenai_core.dart';

import 'src/app.dart';
import 'src/app_version.dart';
import 'src/infrastructure/dart_io_public_ip_probe.dart';
import 'src/infrastructure/dart_io_server_latency_probe.dart';
import 'src/infrastructure/desktop_platform.dart';
import 'src/infrastructure/platform_diagnostics.dart';
import 'src/infrastructure/platform_secure_storage.dart';
import 'src/infrastructure/production_api.dart';
import 'src/infrastructure/support_repository.dart';
import 'src/infrastructure/system_settings_repository.dart';
import 'src/infrastructure/windows_profile_provisioner.dart';
import 'src/infrastructure/windows_vpn_engine.dart';
import 'src/vpn_automation.dart';

const bool _testServersFromEnvironment = bool.fromEnvironment(
  'KENAI_ENABLE_TEST_SERVERS',
);
const String _productionApiUrl = String.fromEnvironment(
  'KENAI_API_BASE_URL',
);

Widget buildKenaiApp({
  bool? includeTestServers,
  AppDependencies? dependencies,
}) {
  if (dependencies != null) return KenaiApp(dependencies: dependencies);
  final bool testServersRequested =
      includeTestServers ?? _testServersFromEnvironment;
  final bool testServersEnabled = !kReleaseMode && testServersRequested;
  final SecureStorage secureStorage = PlatformSecureStorage();
  final ApiClient apiClient;
  final ActivationApiClient activationApiClient;
  final VpnEngine vpnEngine;
  final ServerRepository serverRepository;
  final SubscriptionRepository subscriptionRepository;
  if (kReleaseMode) {
    final Uri? baseUri = validatedProductionApiBaseUri(_productionApiUrl);
    apiClient = baseUri == null
        ? const UnavailableApiClient()
        : DartIoApiClient(baseUri: baseUri);
    activationApiClient = ProductionActivationApiClient(
      apiClient: apiClient,
      secureStorage: secureStorage,
    );
    vpnEngine = WindowsVpnEngine(secureStorage: secureStorage);
    serverRepository = ArmeniaMvpServerRepository(
      latencyProbe:
          const DartIoServerLatencyProbe(host: '88.218.94.3', port: 443),
      netherlandsLatencyProbe:
          const DartIoServerLatencyProbe(host: '147.45.231.194', port: 443),
    );
    subscriptionRepository = const UnavailableSubscriptionRepository();
  } else {
    final MockApiClient mockApiClient = MockApiClient(
      includeTestServers: testServersEnabled,
    );
    apiClient = mockApiClient;
    activationApiClient = MockActivationApiClient();
    vpnEngine = MockVpnEngine();
    serverRepository = MockServerRepository(apiClient: mockApiClient);
    subscriptionRepository = MockSubscriptionRepository();
  }
  final PaymentProvider paymentProvider =
      kReleaseMode ? UnavailablePaymentProvider() : MockPaymentProvider();
  final SpeedTestEngine speedTestEngine =
      kReleaseMode ? UnavailableSpeedTestEngine() : MockSpeedTestEngine();
  final UpdateProvider updateProvider = kReleaseMode
      ? UnavailableUpdateProvider(currentVersion: clientVersion)
      : MockUpdateProvider();
  final RedactingDiagnostics diagnostics = RedactingDiagnostics(
    store: JsonLinesDiagnosticLogStore.forCurrentUser(),
  );
  final account = SecureAccountRepository(
    apiClient: activationApiClient,
    secureStorage: secureStorage,
    profileProvisioner: kReleaseMode ? WindowsVpnProfileProvisioner() : null,
  );
  final platform = kReleaseMode ? WindowsDesktopPlatform() : null;
  final storedSettings = StoredSettingsRepository(secureStorage: secureStorage);
  final SettingsRepository settings = platform == null
      ? storedSettings
      : SystemSettingsRepository(
          storedSettings, platform, vpnEngine as SystemVpnEngine);
  final automation = platform == null
      ? null
      : VpnAutomation(
          engine: vpnEngine,
          servers: serverRepository,
          settings: settings,
          account: account,
          platform: platform,
        );
  unawaited(
    diagnostics
        .log(
          const DiagnosticLogInput(
            category: DiagnosticCategory.application,
            level: DiagnosticSeverity.info,
            code: 'APP_STARTED',
            message: 'Kenai VPN client started.',
          ),
        )
        .onError((Object _, StackTrace __) {}),
  );
  return KenaiApp(
    dependencies: AppDependencies(
      publicIpProbe: kReleaseMode
          ? const DartIoPublicIpProbe()
          : const UnavailablePublicIpProbe(),
      apiClient: apiClient,
      secureStorage: secureStorage,
      accountRepository: account,
      supportRepository: kReleaseMode
          ? ApiSupportRepository(
              api: apiClient,
              storage: secureStorage,
              build: const ClientBuildInfo(
                  version: clientVersion,
                  buildNumber: clientBuildNumber,
                  platform: DevicePlatform.windows))
          : MockSupportRepository(),
      vpnEngine: vpnEngine,
      serverRepository: serverRepository,
      settingsRepository: settings,
      automation: automation,
      platformCapabilities: const ClientPlatformCapabilities(
        supportsAutoConnect: kReleaseMode,
        supportsLaunchAtLogin: kReleaseMode,
        supportsMinimizeAfterConnect: kReleaseMode,
        supportsTray: kReleaseMode,
      ),
      subscriptionRepository: subscriptionRepository,
      paymentProvider: paymentProvider,
      speedTestEngine: speedTestEngine,
      updateProvider: updateProvider,
      buildInfo: const ClientBuildInfo(
        version: clientVersion,
        buildNumber: clientBuildNumber,
        platform: DevicePlatform.windows,
      ),
      diagnosticLogger: diagnostics,
      diagnosticExporter: diagnostics,
      diagnosticArchiveSaver: DownloadsDiagnosticArchiveSaver(),
      minimalMvpMode: kReleaseMode,
    ),
  );
}

final class AppDependencies {
  const AppDependencies({
    required this.apiClient,
    required this.secureStorage,
    required this.accountRepository,
    required this.vpnEngine,
    required this.serverRepository,
    required this.settingsRepository,
    required this.platformCapabilities,
    required this.subscriptionRepository,
    required this.paymentProvider,
    required this.speedTestEngine,
    required this.updateProvider,
    required this.buildInfo,
    required this.diagnosticLogger,
    required this.diagnosticExporter,
    required this.diagnosticArchiveSaver,
    this.minimalMvpMode = false,
    this.publicIpProbe = const UnavailablePublicIpProbe(),
    this.automation,
    this.supportRepository = const UnavailableSupportRepository(),
  });

  final ApiClient apiClient;
  final SecureStorage secureStorage;
  final AccountRepository accountRepository;
  final VpnEngine vpnEngine;
  final ServerRepository serverRepository;
  final SettingsRepository settingsRepository;
  final ClientPlatformCapabilities platformCapabilities;
  final SubscriptionRepository subscriptionRepository;
  final PaymentProvider paymentProvider;
  final SpeedTestEngine speedTestEngine;
  final UpdateProvider updateProvider;
  final ClientBuildInfo buildInfo;
  final DiagnosticLogger diagnosticLogger;
  final DiagnosticExporter diagnosticExporter;
  final DiagnosticArchiveSaver diagnosticArchiveSaver;
  final bool minimalMvpMode;
  final PublicIpProbe publicIpProbe;
  final VpnAutomation? automation;
  final SupportRepository supportRepository;
}
