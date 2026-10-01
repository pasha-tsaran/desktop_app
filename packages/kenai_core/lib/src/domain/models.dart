enum VpnProtocol { wireGuard, amneziaWg, vlessReality }

enum VpnConnectionPhase {
  disconnected,
  validating,
  connecting,
  connected,
  reconnecting,
  disconnecting,
  blockedBySubscription,
  noNetwork,
  serverUnavailable,
  error,
}

extension VpnConnectionPhaseProperties on VpnConnectionPhase {
  bool get isBusy => switch (this) {
        VpnConnectionPhase.validating ||
        VpnConnectionPhase.connecting ||
        VpnConnectionPhase.reconnecting ||
        VpnConnectionPhase.disconnecting =>
          true,
        _ => false,
      };

  bool get isFailure => switch (this) {
        VpnConnectionPhase.blockedBySubscription ||
        VpnConnectionPhase.noNetwork ||
        VpnConnectionPhase.serverUnavailable ||
        VpnConnectionPhase.error =>
          true,
        _ => false,
      };
}

enum SubscriptionStatus { active, expired, suspended }

enum AccountApiFailure {
  invalidKey,
  noNetwork,
  rateLimited,
  deviceLimit,
  server,
}

enum PaymentPhase {
  idle,
  creatingOrder,
  awaitingPayment,
  paid,
  cancelled,
  failed,
  subscriptionUpdating,
}

enum PaymentFailure { backendUnavailable, orderCreation, confirmation }

enum ServerOperationalStatus {
  operational,
  degraded,
  maintenance,
  offline,
  unknown,
}

enum InternetReachability { reachable, unreachable, unknown }

enum DevicePlatform { windows, android, ios, macos }

enum DiagnosticSeverity { debug, info, warning, error }

enum DiagnosticCategory {
  application,
  wireGuard,
  amneziaWg,
  xray,
  systemService,
  network,
}

enum ThemePreference { system, light, dark }

enum ProtocolPreference { automatic, wireGuard, amneziaWg, vlessReality }

enum AutoConnectMode { disabled, recommendedServer, selectedServer }

enum DnsPreference { automatic, system }

enum SleepBehavior { reconnect, disconnect }

enum SpeedTestPhase {
  idle,
  pinging,
  downloading,
  uploading,
  completed,
  cancelled,
  failed,
}

enum UpdateStatus { unavailable, upToDate, available, failed }

enum ServerSort { recommended, latency, name, country }

enum ApiMethod { get, post, put, patch, delete }

enum ApiTransportFailure {
  noNetwork,
  timeout,
  tls,
  malformedResponse,
  unavailable,
}

final class Account {
  const Account({
    required this.id,
    this.email,
    this.telegramUsername,
    this.phoneNumber,
  });

  final String id;
  final String? email;
  final String? telegramUsername;
  final String? phoneNumber;
}

final class ActivationKey {
  ActivationKey.parse(String input) : value = input.trim() {
    if (!RegExp(r'^\d{12}$').hasMatch(value)) {
      throw const FormatException('Activation key must contain 12 digits');
    }
  }

  final String value;

  String get masked => '•••• •••• ${value.substring(8)}';

  @override
  String toString() => masked;
}

final class Subscription {
  const Subscription({
    required this.status,
    required this.planName,
    required this.expiresAt,
    required this.deviceLimit,
    this.lastVerifiedAt,
  });

  final SubscriptionStatus status;
  final String planName;
  final DateTime? expiresAt;
  final int deviceLimit;
  final DateTime? lastVerifiedAt;
}

final class AccountSession {
  const AccountSession({
    required this.account,
    required this.subscription,
    required this.activationKeyMask,
  });

  final Account account;
  final Subscription subscription;
  final String activationKeyMask;
}

final class ActivationResult {
  const ActivationResult({
    required this.account,
    required this.subscription,
    required this.vpnCredentials,
    this.locationVlessCredentials = const <String, String>{},
    this.locationAmneziaWgCredentials = const <String, String>{},
  });

  final Account account;
  final Subscription subscription;
  final Map<VpnProtocol, String> vpnCredentials;
  final Map<String, String> locationVlessCredentials;
  final Map<String, String> locationAmneziaWgCredentials;
}

final class AccountApiException implements Exception {
  const AccountApiException(this.failure);

  final AccountApiFailure failure;

  @override
  String toString() => 'Account API request failed: ${failure.name}';
}

final class ApiClientException implements Exception {
  const ApiClientException(this.failure);

  final ApiTransportFailure failure;

  @override
  String toString() => 'API transport failed: ${failure.name}';
}

final class VpnServer {
  const VpnServer({
    required this.id,
    required this.countryCode,
    required this.countryName,
    required this.city,
    required this.name,
    required this.protocols,
    required this.status,
    this.isRecommended = false,
    this.isFavorite = false,
    this.isTest = false,
  });

  final String id;
  final String countryCode;
  final String countryName;
  final String city;
  final String name;
  final Set<VpnProtocol> protocols;
  final ServerStatus status;
  final bool isRecommended;
  final bool isFavorite;
  final bool isTest;

  bool get isAvailable => status.isAvailable;

  /// An unknown health state permits a connection attempt, but a known outage
  /// or maintenance window does not. This is not a health claim.
  bool get canAttemptConnection =>
      status.operational != ServerOperationalStatus.offline &&
      status.operational != ServerOperationalStatus.maintenance &&
      status.internetReachability != InternetReachability.unreachable;

  VpnServer copyWith({ServerStatus? status, bool? isFavorite}) => VpnServer(
        id: id,
        countryCode: countryCode,
        countryName: countryName,
        city: city,
        name: name,
        protocols: protocols,
        status: status ?? this.status,
        isRecommended: isRecommended,
        isFavorite: isFavorite ?? this.isFavorite,
        isTest: isTest,
      );
}

final class ServerStatus {
  const ServerStatus({
    required this.operational,
    required this.internetReachability,
    required this.lastUpdatedAt,
    this.latency,
    this.loadPercent,
  });

  final ServerOperationalStatus operational;
  final InternetReachability internetReachability;
  final DateTime lastUpdatedAt;
  final Duration? latency;
  final int? loadPercent;

  bool get isAvailable =>
      (operational == ServerOperationalStatus.operational ||
          operational == ServerOperationalStatus.degraded) &&
      internetReachability == InternetReachability.reachable;

  ServerStatus copyWith({Duration? latency}) => ServerStatus(
        operational: operational,
        internetReachability: internetReachability,
        lastUpdatedAt: DateTime.now().toUtc(),
        latency: latency ?? this.latency,
        loadPercent: loadPercent,
      );
}

final class Device {
  const Device({
    required this.id,
    required this.displayName,
    required this.platform,
    required this.isCurrent,
  });

  final String id;
  final String displayName;
  final DevicePlatform platform;
  final bool isCurrent;
}

/// A non-secret handle to credentials stored by SecureStorage.
final class VpnProfile {
  const VpnProfile({
    required this.id,
    required this.deviceId,
    required this.serverId,
    required this.protocol,
  });

  final String id;
  final String deviceId;
  final String serverId;
  final VpnProtocol protocol;
}

final class ConnectionRequest {
  const ConnectionRequest({
    required this.operationId,
    required this.profile,
    required this.killSwitch,
  });

  final String operationId;
  final VpnProfile profile;
  final bool killSwitch;
}

final class VpnConnectionState {
  const VpnConnectionState({
    required this.phase,
    this.serverId,
    this.protocol,
    this.connectedAt,
    this.killSwitchActive = false,
    this.errorCode,
  });

  const VpnConnectionState.disconnected()
      : phase = VpnConnectionPhase.disconnected,
        serverId = null,
        protocol = null,
        connectedAt = null,
        killSwitchActive = false,
        errorCode = null;

  final VpnConnectionPhase phase;
  final String? serverId;
  final VpnProtocol? protocol;
  final DateTime? connectedAt;
  final bool killSwitchActive;
  final String? errorCode;
}

final class ConnectionSession {
  const ConnectionSession({
    required this.serverId,
    required this.protocol,
    required this.connectedAt,
    required this.bytesReceived,
    required this.bytesSent,
    this.externalIp,
  });

  final String serverId;
  final VpnProtocol protocol;
  final DateTime connectedAt;
  final int bytesReceived;
  final int bytesSent;
  final String? externalIp;
}

final class VpnStatistics {
  const VpnStatistics({
    required this.bytesReceived,
    required this.bytesSent,
    required this.measuredAt,
  });

  final int bytesReceived;
  final int bytesSent;
  final DateTime measuredAt;
}

final class ProfileValidation {
  const ProfileValidation({required this.isValid, this.errorCode});

  final bool isValid;
  final String? errorCode;
}

final class VpnAdapterCapabilities {
  const VpnAdapterCapabilities({
    required this.protocol,
    required this.isMock,
    required this.supportsKillSwitch,
    required this.supportsDns,
    required this.supportsNetworkChangeReconnect,
    required this.supportsSleepRecovery,
  });

  final VpnProtocol protocol;
  final bool isMock;
  final bool supportsKillSwitch;
  final bool supportsDns;
  final bool supportsNetworkChangeReconnect;
  final bool supportsSleepRecovery;
}

final class ClientPlatformCapabilities {
  const ClientPlatformCapabilities({
    required this.supportsAutoConnect,
    required this.supportsLaunchAtLogin,
    required this.supportsMinimizeAfterConnect,
    this.supportsTray = false,
  });

  const ClientPlatformCapabilities.unavailable()
      : supportsAutoConnect = false,
        supportsLaunchAtLogin = false,
        supportsMinimizeAfterConnect = false,
        supportsTray = false;

  final bool supportsAutoConnect;
  final bool supportsLaunchAtLogin;
  final bool supportsMinimizeAfterConnect;
  final bool supportsTray;
}

final class SpeedTestState {
  const SpeedTestState({
    required this.phase,
    this.serverId,
    this.latencySamples = const <Duration>[],
    this.downloadMbps,
    this.uploadMbps,
    this.estimatedBytesUsed = 0,
    this.errorCode,
  });

  const SpeedTestState.idle()
      : phase = SpeedTestPhase.idle,
        serverId = null,
        latencySamples = const <Duration>[],
        downloadMbps = null,
        uploadMbps = null,
        estimatedBytesUsed = 0,
        errorCode = null;

  final SpeedTestPhase phase;
  final String? serverId;
  final List<Duration> latencySamples;
  final double? downloadMbps;
  final double? uploadMbps;
  final int estimatedBytesUsed;
  final String? errorCode;

  Duration? get averageLatency {
    if (latencySamples.isEmpty) return null;
    final int total = latencySamples.fold<int>(
      0,
      (int value, Duration sample) => value + sample.inMicroseconds,
    );
    return Duration(microseconds: total ~/ latencySamples.length);
  }

  Duration? get maximumLatency => latencySamples.isEmpty
      ? null
      : latencySamples.reduce(
          (Duration left, Duration right) => left > right ? left : right,
        );
}

final class UpdateCheckResult {
  const UpdateCheckResult({
    required this.status,
    required this.currentVersion,
    this.latestVersion,
    this.safeMessage,
  });

  final UpdateStatus status;
  final String currentVersion;
  final String? latestVersion;
  final String? safeMessage;
}

final class ClientBuildInfo {
  const ClientBuildInfo({
    required this.version,
    required this.buildNumber,
    required this.platform,
  });

  final String version;
  final String buildNumber;
  final DevicePlatform platform;
}

final class EngineDiagnostics {
  const EngineDiagnostics({
    required this.phase,
    required this.serviceAvailable,
    required this.networkAvailable,
    required this.codes,
  });

  final VpnConnectionPhase phase;
  final bool serviceAvailable;
  final bool networkAvailable;
  final List<String> codes;
}

final class DiagnosticEvent {
  const DiagnosticEvent({
    required this.occurredAt,
    required this.source,
    required this.level,
    required this.code,
  });

  final DateTime occurredAt;
  final String source;
  final DiagnosticSeverity level;
  final String code;
}

final class DiagnosticLogEntry {
  const DiagnosticLogEntry({
    required this.occurredAt,
    required this.category,
    required this.level,
    required this.code,
    required this.message,
    this.fields = const <String, Object?>{},
  });

  final DateTime occurredAt;
  final DiagnosticCategory category;
  final DiagnosticSeverity level;
  final String code;
  final String message;
  final Map<String, Object?> fields;

  DiagnosticLogEntry copyWith({
    String? code,
    String? message,
    Map<String, Object?>? fields,
  }) =>
      DiagnosticLogEntry(
        occurredAt: occurredAt,
        category: category,
        level: level,
        code: code ?? this.code,
        message: message ?? this.message,
        fields: fields ?? this.fields,
      );
}

final class DiagnosticLogInput {
  const DiagnosticLogInput({
    required this.category,
    required this.level,
    required this.code,
    required this.message,
    this.fields = const <String, Object?>{},
  });

  final DiagnosticCategory category;
  final DiagnosticSeverity level;
  final String code;
  final String message;
  final Map<String, Object?> fields;
}

final class DiagnosticFilter {
  const DiagnosticFilter({
    this.categories = const <DiagnosticCategory>{},
    this.levels = const <DiagnosticSeverity>{},
    this.query = '',
  });

  final Set<DiagnosticCategory> categories;
  final Set<DiagnosticSeverity> levels;
  final String query;
}

final class DiagnosticSummary {
  const DiagnosticSummary({
    required this.generatedAt,
    required this.totalEvents,
    required this.warningCount,
    required this.errorCount,
    required this.categoryCounts,
  });

  final DateTime generatedAt;
  final int totalEvents;
  final int warningCount;
  final int errorCount;
  final Map<DiagnosticCategory, int> categoryCounts;
}

final class Tariff {
  const Tariff({
    required this.id,
    required this.months,
    required this.priceRubles,
  });

  final String id;
  final int months;
  final int priceRubles;
}

final class AppSettings {
  const AppSettings({
    required this.theme,
    required this.locale,
    required this.protocol,
    required this.dns,
    required this.autoConnect,
    required this.defaultServerId,
    required this.killSwitch,
    required this.reconnectOnNetworkChange,
    required this.sleepBehavior,
    required this.launchAtLogin,
    required this.minimizeAfterConnect,
    required this.autoUpdate,
    required this.trayEnabled,
    required this.sendDiagnostics,
  });

  const AppSettings.defaults()
      : theme = ThemePreference.system,
        locale = 'ru',
        protocol = ProtocolPreference.automatic,
        dns = DnsPreference.automatic,
        autoConnect = AutoConnectMode.disabled,
        defaultServerId = 'am-evn-01',
        killSwitch = false,
        reconnectOnNetworkChange = false,
        sleepBehavior = SleepBehavior.disconnect,
        launchAtLogin = false,
        minimizeAfterConnect = false,
        autoUpdate = false,
        trayEnabled = false,
        sendDiagnostics = false;

  final ThemePreference theme;
  final String locale;
  final ProtocolPreference protocol;
  final DnsPreference dns;
  final AutoConnectMode autoConnect;
  final String? defaultServerId;
  final bool killSwitch;
  final bool reconnectOnNetworkChange;
  final SleepBehavior sleepBehavior;
  final bool launchAtLogin;
  final bool minimizeAfterConnect;
  final bool autoUpdate;
  final bool trayEnabled;
  final bool sendDiagnostics;

  AppSettings copyWith({
    ThemePreference? theme,
    String? locale,
    ProtocolPreference? protocol,
    DnsPreference? dns,
    AutoConnectMode? autoConnect,
    String? defaultServerId,
    bool? killSwitch,
    bool? reconnectOnNetworkChange,
    SleepBehavior? sleepBehavior,
    bool? launchAtLogin,
    bool? minimizeAfterConnect,
    bool? autoUpdate,
    bool? trayEnabled,
    bool? sendDiagnostics,
  }) =>
      AppSettings(
        theme: theme ?? this.theme,
        locale: locale ?? this.locale,
        protocol: protocol ?? this.protocol,
        dns: dns ?? this.dns,
        autoConnect: autoConnect ?? this.autoConnect,
        defaultServerId: defaultServerId ?? this.defaultServerId,
        killSwitch: killSwitch ?? this.killSwitch,
        reconnectOnNetworkChange:
            reconnectOnNetworkChange ?? this.reconnectOnNetworkChange,
        sleepBehavior: sleepBehavior ?? this.sleepBehavior,
        launchAtLogin: launchAtLogin ?? this.launchAtLogin,
        minimizeAfterConnect: minimizeAfterConnect ?? this.minimizeAfterConnect,
        autoUpdate: autoUpdate ?? this.autoUpdate,
        trayEnabled: trayEnabled ?? this.trayEnabled,
        sendDiagnostics: sendDiagnostics ?? this.sendDiagnostics,
      );
}

final class ApiRequest {
  const ApiRequest({
    required this.method,
    required this.path,
    this.headers = const <String, String>{},
    this.query = const <String, String>{},
    this.body = const <String, Object?>{},
  });

  final ApiMethod method;
  final String path;
  final Map<String, String> headers;
  final Map<String, String> query;
  final Map<String, Object?> body;
}

final class ApiResponse {
  const ApiResponse({required this.statusCode, required this.body});

  final int statusCode;
  final Map<String, Object?> body;
}

final class PaymentSession {
  const PaymentSession({required this.id, required this.checkoutUri});

  final String id;
  final Uri checkoutUri;
}

final class PaymentState {
  const PaymentState({required this.phase, this.session, this.failure});

  const PaymentState.idle()
      : phase = PaymentPhase.idle,
        session = null,
        failure = null;

  final PaymentPhase phase;
  final PaymentSession? session;
  final PaymentFailure? failure;
}

final class PaymentException implements Exception {
  const PaymentException(this.failure);

  final PaymentFailure failure;

  @override
  String toString() => 'Payment operation failed: ${failure.name}';
}

final class DiagnosticPreview {
  const DiagnosticPreview({required this.categories, required this.redactions});

  final List<String> categories;
  final List<String> redactions;
}

final class DiagnosticArchive {
  const DiagnosticArchive({required this.fileName, required this.bytes});

  final String fileName;
  final List<int> bytes;
}

final class DiagnosticArchiveLocation {
  const DiagnosticArchiveLocation({required this.path});

  final String path;
}
