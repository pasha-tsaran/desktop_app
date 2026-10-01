import '../domain/models.dart';

abstract interface class ApiClient {
  Future<ApiResponse> send(ApiRequest request);
}

abstract interface class ActivationApiClient {
  bool get isMock;
  Future<ActivationResult> activate(ActivationKey activationKey);
}

abstract interface class SecureStorage {
  Future<void> write({required String key, required String value});
  Future<String?> read(String key);
  Future<void> delete(String key);
  Future<void> clear();
}

abstract interface class VpnProfileProvisioner {
  Future<String> provisionWireGuard(String configuration);
  Future<String> provisionAmneziaWg(String configuration);
  Future<String> provisionVlessReality(String configuration);
  Future<void> deleteProfile(String profileId);
}

abstract interface class VpnEngine {
  bool get isMock;
  Stream<VpnConnectionState> get states;
  Future<void> connect(ConnectionRequest request);
  Future<void> disconnect({required String operationId});
  Future<VpnConnectionState> status();
  Future<VpnStatistics> statistics();
  Future<ProfileValidation> validateProfile(VpnProfile profile);
  Future<EngineDiagnostics> collectDiagnostics();
  Set<VpnProtocol> get supportedProtocols;
  VpnAdapterCapabilities capabilitiesFor(VpnProtocol protocol);
}

/// Supports an explicit disconnect while a connect request is still pending.
abstract interface class CancellableVpnEngine {
  Future<void> cancelConnection({required String operationId});
}

abstract interface class SystemVpnEngine {
  Future<void> configureKillSwitch(bool enabled);
}

abstract interface class VpnProtocolAdapter {
  VpnProtocol get protocol;
  VpnAdapterCapabilities get capabilities;
  Future<ProfileValidation> validate(VpnProfile profile);
  Future<void> start(VpnProfile profile);
  Future<void> stop();
}

abstract interface class WireGuardAdapter implements VpnProtocolAdapter {}

abstract interface class AmneziaWgAdapter implements VpnProtocolAdapter {}

abstract interface class XrayRealityAdapter implements VpnProtocolAdapter {}

abstract interface class SettingsRepository {
  Stream<AppSettings> get changes;
  Future<AppSettings> load();
  Future<void> save(AppSettings settings);
}

abstract interface class ServerRepository {
  bool get isMock;
  Future<List<VpnServer>> getServers({
    String query = '',
    ServerSort sort = ServerSort.recommended,
    String? countryCode,
    bool favoritesOnly = false,
  });
  Future<VpnServer?> getSelectedServer();
  Future<void> selectServer(String serverId);
  Future<void> toggleFavorite(String serverId);
  Future<Duration?> ping(String serverId);
}

/// Measures current network latency to a known, application-owned server.
abstract interface class ServerLatencyProbe {
  Future<Duration?> measure();
}

abstract interface class SubscriptionRepository {
  Future<Subscription> getSubscription();
}

abstract interface class AccountRepository {
  bool get isMock;
  Future<AccountSession> activate(ActivationKey activationKey);
  Future<AccountSession?> restoreSession();
  Future<bool> ensureProtocolProfile(VpnProtocol protocol,
      {String serverId = 'armenia-1'});
  Future<String?> revealActivationKey();
  Future<void> signOut();
}

abstract interface class PaymentProvider {
  bool get isAvailable;
  bool get isMock;
  PaymentState get currentState;
  Stream<PaymentState> get states;
  Future<PaymentSession> createCheckout({required String planId});
  Future<bool> confirm(String sessionId);
  Future<void> cancel(String sessionId);
}

abstract interface class DiagnosticExporter {
  Future<DiagnosticPreview> preview();
  Future<DiagnosticArchive> createArchive();
}

abstract interface class DiagnosticLogger {
  Stream<List<DiagnosticLogEntry>> get changes;
  Future<void> log(DiagnosticLogInput input);
  Future<List<DiagnosticLogEntry>> query([
    DiagnosticFilter filter = const DiagnosticFilter(),
  ]);
  Future<DiagnosticSummary> summary();
  Future<void> clear();
}

/// Storage is deliberately kept behind [DiagnosticLogger] so callers cannot
/// bypass the redaction boundary.
abstract interface class DiagnosticLogStore {
  Future<void> append(DiagnosticLogEntry entry);
  Future<List<DiagnosticLogEntry>> readAll();
  Future<void> clear();
}

abstract interface class DiagnosticArchiveSaver {
  Future<DiagnosticArchiveLocation> save(DiagnosticArchive archive);
}

abstract interface class SpeedTestEngine {
  Stream<SpeedTestState> get states;
  SpeedTestState get currentState;
  bool get isAvailable;
  bool get isMock;
  Future<void> start({required String serverId});
  Future<void> stop();
}

abstract interface class UpdateProvider {
  bool get isAvailable;
  bool get isMock;
  bool get verifiesSignatures;
  Future<UpdateCheckResult> checkForUpdates();
}
